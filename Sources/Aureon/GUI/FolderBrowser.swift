import SwiftUI
import AppKit

// MARK: - Model

/// A row of the folder tree. Reference type so the outline view can keep its expansion state by identity across refreshes.
final class FolderNode: NSObject {
    var entry: FolderEntry
    weak var parent: FolderNode?
    /// nil until the folder has been read.
    var children: [FolderNode]?
    /// The children the filter lets through (folders always stay, so the tree can still be walked).
    var shown: [FolderNode] = []
    var loading = false
    var error: String?
    let isRoot: Bool
    /// A link back into one of its own ancestors: shown, never expanded.
    let isLoop: Bool
    /// Resolved paths of this folder and every folder above it (loop detection).
    let ancestry: [String]
    let folded: String
    lazy var placeholder = FolderNode(placeholderFor: self)
    let isPlaceholder: Bool

    init(entry: FolderEntry, parent: FolderNode?, isRoot: Bool = false) {
        self.entry = entry; self.parent = parent; self.isRoot = isRoot
        let mine = (entry.target ?? entry.url).standardizedFileURL.path
        isLoop = FolderScanner.isLoop(entry, ancestors: parent?.ancestry ?? [])
        ancestry = (parent?.ancestry ?? []) + [mine]
        folded = LibraryStore.fold(entry.name)
        isPlaceholder = false
    }

    private init(placeholderFor p: FolderNode) {
        entry = FolderEntry(url: p.entry.url.appendingPathComponent(".aureon-reading"), name: "Reading…", kind: .other, isSymlink: false, target: nil, size: 0, modified: nil)
        parent = p; isRoot = false; isLoop = false; ancestry = p.ancestry; folded = ""; isPlaceholder = true
    }

    var isFolder: Bool { entry.kind == .folder && !entry.isBroken }
    var canExpand: Bool { isFolder && !isLoop }
    /// The path the file system knows this folder by (a link's target).
    var resolvedPath: String { (entry.target ?? entry.url).standardizedFileURL.path }
    var displayed: [FolderNode] { loading && children == nil ? [placeholder] : shown }
}

/// The Folders page: roots the person chose (plus their library folders, ~/Music and any external drives), read lazily and off the main thread.
@MainActor
final class FolderBrowserModel: ObservableObject {
    static let shared = FolderBrowserModel()

    @Published private(set) var roots: [FolderNode] = []
    @Published var filter = "" { didSet { if filter != oldValue { scheduleFilter() } } }
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    /// Told whenever a node's children changed (nil = the roots), so the outline view can reload just that part.
    var onNodeChanged: (@MainActor (FolderNode?) -> Void)?

    private let io = DispatchQueue(label: "aureon.folders", qos: .userInitiated, attributes: .concurrent)
    private var generation: [ObjectIdentifier: Int] = [:]
    private var byPath: [String: FolderNode] = [:]          // loaded folders, by listed and by resolved path (FSEvents reports real paths)
    private var filterWork: DispatchWorkItem?
    private var bootstrapped = false
    private lazy var watcher = FolderWatcher { [weak self] paths in MainActor.assumeIsolated { self?.diskChanged(paths) } }
    private let defaults = UserDefaults.standard
    static let rootsKey = "aureon.folderRoots"

    /// Folders the person added themselves.
    private(set) var savedRoots: [String] = UserDefaults.standard.stringArray(forKey: FolderBrowserModel.rootsKey) ?? []

    func bootstrap(libraryFolders: [String]) {
        guard !bootstrapped else { return }
        bootstrapped = true
        rebuildRoots(libraryFolders: libraryFolders)
    }

    func rebuildRoots(libraryFolders: [String]) {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first?.path
        var paths: [String] = []
        for p in savedRoots + libraryFolders + [music].compactMap({ $0 }) where !paths.contains(p) { paths.append(p) }
        let old = Dictionary(roots.map { ($0.entry.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        busy = true
        io.async {
            // external drives are mounted folders in /Volumes; the start-up disk is only a link there
            let volumes = ((try? FolderScanner.list(URL(fileURLWithPath: "/Volumes"))) ?? []).filter { !$0.isSymlink && $0.kind == .folder }.map(\.url.path)
            var all = paths
            for v in volumes where !all.contains(v) { all.append(v) }
            let entries: [FolderEntry] = all.compactMap { p in
                var d: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &d), d.boolValue else { return nil }
                let u = URL(fileURLWithPath: p, isDirectory: true)
                return FolderEntry(url: u, name: Self.rootName(p), kind: .folder, isSymlink: false, target: realPath(u), size: 0, modified: nil)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.roots = entries.map { e in old[e.url.path] ?? FolderNode(entry: e, parent: nil, isRoot: true) }
                    for r in self.roots { r.shown = self.filtered(r.children ?? []) }
                    self.busy = false
                    self.watcher.watch(self.roots.map(\.resolvedPath))
                    self.onNodeChanged?(nil)
                }
            }
        }
    }

    nonisolated static func rootName(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "Home" }
        if path.hasPrefix("/Volumes/") { return (path as NSString).lastPathComponent }
        return (path as NSString).lastPathComponent
    }

    func addRoot(_ url: URL, libraryFolders: [String]) {
        let p = realPath(url).path
        guard !savedRoots.contains(p) else { return }
        savedRoots.append(p); defaults.set(savedRoots, forKey: Self.rootsKey)
        rebuildRoots(libraryFolders: libraryFolders)
    }

    func removeRoot(_ node: FolderNode, libraryFolders: [String]) {
        savedRoots.removeAll { $0 == node.entry.url.path || $0 == node.resolvedPath }
        defaults.set(savedRoots, forKey: Self.rootsKey)
        rebuildRoots(libraryFolders: libraryFolders)
    }

    func isSaved(_ node: FolderNode) -> Bool { savedRoots.contains(node.entry.url.path) }

    // MARK: reading

    /// Reads a folder's contents in the background. Calling again while a read is running is harmless: only the newest result is used.
    func load(_ node: FolderNode, force: Bool = false) {
        guard node.canExpand, force || node.children == nil else { return }
        let key = ObjectIdentifier(node)
        let gen = (generation[key] ?? 0) + 1
        generation[key] = gen
        node.loading = true
        if node.children == nil { onNodeChanged?(node) }          // shows "Reading…"
        updateStatus()
        let url = node.entry.url
        io.async { [weak self] in
            let started = Date()
            var entries: [FolderEntry] = [], failure: String?
            do { entries = try FolderScanner.list(url) } catch { failure = (error as NSError).localizedDescription }
            let took = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation[key] == gen else { return }
                    self.install(entries, into: node, error: failure, took: took)
                }
            }
        }
    }

    private func install(_ entries: [FolderEntry], into node: FolderNode, error: String?, took: Double) {
        // keep the nodes that are still there, so expanded folders stay expanded and loaded
        var old: [String: FolderNode] = [:]
        for c in node.children ?? [] { old[c.entry.url.path] = c }
        let fresh: [FolderNode] = entries.map { e in
            if let o = old[e.url.path], o.entry.kind == e.kind { o.entry = e; return o }
            return FolderNode(entry: e, parent: node)
        }
        for gone in (node.children ?? []) where !entries.contains(where: { $0.url.path == gone.entry.url.path }) { forget(gone) }
        node.children = fresh
        node.shown = filtered(fresh)
        node.loading = false
        node.error = error
        byPath[node.entry.url.standardizedFileURL.path] = node
        byPath[node.resolvedPath] = node
        let files = fresh.count - fresh.filter(\.isFolder).count
        status = error.map { "Could not read “\(node.entry.name)”: \($0)" } ?? "“\(node.entry.name)”: \(fresh.count - files) folders, \(files) files · read in \(Int(took * 1000)) ms"
        updateStatus()
        onNodeChanged?(node)
    }

    private func forget(_ n: FolderNode) {
        if byPath[n.entry.url.standardizedFileURL.path] === n { byPath[n.entry.url.standardizedFileURL.path] = nil }
        if byPath[n.resolvedPath] === n { byPath[n.resolvedPath] = nil }
        generation[ObjectIdentifier(n)] = nil
        for c in n.children ?? [] { forget(c) }
    }

    private func updateStatus() {
        busy = byPath.values.contains { $0.loading } || roots.contains { $0.loading }
    }

    /// Re-reads every folder that is open.
    func refreshAll() {
        for n in Set(byPath.values) { load(n, force: true) }
    }

    func refresh(_ node: FolderNode) { if node.children != nil { load(node, force: true) } }

    private func diskChanged(_ paths: [String]) {
        for p in Set(paths) {
            if let n = byPath[p] { load(n, force: true) }
        }
    }

    // MARK: filter

    private func scheduleFilter() {
        filterWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.applyFilter() } }
        filterWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func filtered(_ nodes: [FolderNode]) -> [FolderNode] {
        let f = LibraryStore.fold(filter.trimmingCharacters(in: .whitespaces))
        guard !f.isEmpty else { return nodes }
        return nodes.filter { $0.isFolder || $0.folded.contains(f) }
    }

    private func applyFilter() {
        func walk(_ n: FolderNode) { guard let c = n.children else { return }; n.shown = filtered(c); c.forEach(walk) }
        roots.forEach(walk)
        onNodeChanged?(nil)
    }

    // MARK: collecting files to play

    /// Playable files of a folder and everything under it, collected off the main thread.
    func collect(_ folder: URL, recursive: Bool = true) async -> [URL] {
        busy = true; status = "Collecting the files in “\(folder.lastPathComponent)”…"
        let files = await Task.detached(priority: .userInitiated) { FolderScanner.audioFiles(under: folder, recursive: recursive) }.value
        busy = false; status = files.isEmpty ? "No playable files in “\(folder.lastPathComponent)”" : "\(files.count) files from “\(folder.lastPathComponent)”"
        return files
    }
}

// MARK: - Page

struct FolderBrowserPage: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var model = FolderBrowserModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            FolderOutline(model: model, actions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel(radius: 16)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius(16), style: .continuous))
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status.isEmpty ? "Click ▶ to play a folder or a file at once. Right-click for tags, booklets and ABX." : model.status)
                    .font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
        .onAppear { model.bootstrap(libraryFolders: m.library.folders) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Folders").font(Typo.serif(26, .regular)).tracking(-0.4)
            Text("Straight from disk · no library scan").microLabel().foregroundStyle(Brand.inkSecondary)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary)
                TextField("Filter open folders", text: $model.filter).textFieldStyle(.plain).font(Typo.sans(12.5)).frame(width: 170)
                if !model.filter.isEmpty { Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.inkSecondary) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Metrics.radius(7), style: .continuous).fill(Brand.ink.opacity(0.08)))
            Button { addFolder() } label: { Image(systemName: "folder.badge.plus") }.help("Add a folder to browse")
            Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise") }.help("Read the open folders again")
        }
        .buttonStyle(IconButtonStyle())
    }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true; p.prompt = "Browse"
        DispatchQueue.main.async { if p.runModal() == .OK { for u in p.urls { model.addRoot(u, libraryFolders: m.library.folders) } } }
    }

    private var actions: FolderActions {
        let m = self.m
        return FolderActions(
            play: { files, start in
                guard !files.isEmpty else { return }
                if m.djMode { m.dj.loadDropped([start ?? files[0]]); return }
                m.clear()
                m.add(urls: files)
                let target = start.flatMap { s in m.items.first { $0.url == s } } ?? m.items.first
                if let t = target { m.play(t.id) }
            },
            enqueue: { files in m.add(urls: files) },
            playFolder: { folder in
                Task { @MainActor in
                    let files = await FolderBrowserModel.shared.collect(folder)
                    guard !files.isEmpty else { return }
                    m.clear(); m.add(urls: files, play: true)
                }
            },
            enqueueFolder: { folder in
                Task { @MainActor in let files = await FolderBrowserModel.shared.collect(folder); m.add(urls: files) }
            },
            editTags: { files in TagEditorWindow.open(paths: files.map(\.path), model: m) },
            editFolderTags: { folder in
                Task { @MainActor in
                    let files = await Task.detached { ((try? FolderScanner.list(folder)) ?? []).filter(\.isTaggable).map(\.url) }.value
                    guard !files.isEmpty else { return }
                    TagEditorWindow.open(paths: files.map(\.path), model: m)
                }
            },
            openBooklet: { url in BookletWindow.open(url: url, tracks: []) },
            abx: { url, slot in
                ABXModel.shared.load(url, into: slot)
                m.djMode = false; m.tab = .abx
            },
            removeRoot: { node in FolderBrowserModel.shared.removeRoot(node, libraryFolders: m.library.folders) },
            nowPlayingPath: { m.isActive ? m.current?.path : nil }
        )
    }
}

/// What the outline view asks the app to do.
struct FolderActions {
    var play: ([URL], URL?) -> Void
    var enqueue: ([URL]) -> Void
    var playFolder: (URL) -> Void
    var enqueueFolder: (URL) -> Void
    var editTags: ([URL]) -> Void
    var editFolderTags: (URL) -> Void
    var openBooklet: (URL) -> Void
    var abx: (URL, ABXSlot) -> Void
    var removeRoot: (FolderNode) -> Void
    var nowPlayingPath: () -> String?
}

// MARK: - Outline view

struct FolderOutline: NSViewRepresentable {
    let model: FolderBrowserModel
    let actions: FolderActions

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FolderOutlineView()
        let col = NSTableColumn(identifier: .init("main")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 28
        outline.indentationPerLevel = 16
        outline.backgroundColor = .clear
        outline.usesAlternatingRowBackgroundColors = false
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = true
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu(); menu.delegate = context.coordinator; outline.menu = menu
        outline.coordinator = context.coordinator
        context.coordinator.outline = outline
        context.coordinator.actions = actions

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        model.onNodeChanged = { [weak coordinator = context.coordinator] node in coordinator?.reload(node) }
        outline.reloadData()
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        context.coordinator.actions = actions
    }

    static func dismantleNSView(_ v: NSScrollView, coordinator: Coordinator) { coordinator.model.onNodeChanged = nil }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let model: FolderBrowserModel
        weak var outline: NSOutlineView?
        var actions: FolderActions?
        init(model: FolderBrowserModel) { self.model = model }

        func reload(_ node: FolderNode?) {
            guard let o = outline else { return }
            if let node { o.reloadItem(node, reloadChildren: true) } else { o.reloadData() }
        }

        // data source
        func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let n = item as? FolderNode else { return model.roots.count }
            return n.displayed.count
        }
        func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let n = item as? FolderNode else { return model.roots[index] }
            return n.displayed[index]
        }
        func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FolderNode)?.canExpand ?? false }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let n = notification.userInfo?["NSObject"] as? FolderNode else { return }
            model.load(n)
        }

        func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let n = item as? FolderNode, !n.isPlaceholder, !n.entry.isBroken else { return nil }
            return n.entry.url as NSURL
        }

        // views
        func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? FolderNode else { return nil }
            let cell = (o.makeView(withIdentifier: FolderCell.id, owner: nil) as? FolderCell) ?? FolderCell()
            cell.configure(n, playing: !n.isFolder && n.entry.url.path == actions?.nowPlayingPath())
            cell.onPlay = { [weak self] in self?.play(n) }
            return cell
        }

        func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { FolderRowView() }

        // actions
        private func siblings(of n: FolderNode) -> [URL] {
            (n.parent?.children ?? []).filter { $0.entry.isPlayable && !$0.entry.isBroken }.map(\.entry.url)
        }

        func play(_ n: FolderNode) {
            guard let a = actions, !n.isPlaceholder else { return }
            if n.isFolder { a.playFolder(n.entry.url) }
            else if n.entry.isPlayable { a.play(siblings(of: n), n.entry.url) }
            else if n.entry.kind == .booklet { a.openBooklet(n.entry.url) }
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let n = sender.item(atRow: row) as? FolderNode else { return }
            if n.isFolder { if sender.isItemExpanded(n) { sender.collapseItem(n) } else { sender.expandItem(n) } }
            else { play(n) }
        }

        fileprivate func playSelection() {
            guard let o = outline else { return }
            let nodes = o.selectedRowIndexes.compactMap { o.item(atRow: $0) as? FolderNode }
            if nodes.count == 1, let n = nodes.first { play(n); return }
            let files = nodes.filter { $0.entry.isPlayable }.map(\.entry.url)
            if !files.isEmpty { actions?.play(files, nil) }
        }

        fileprivate func editSelectionTags() {
            guard let o = outline else { return }
            let files = o.selectedRowIndexes.compactMap { o.item(atRow: $0) as? FolderNode }.filter { $0.entry.isTaggable }.map(\.entry.url)
            if !files.isEmpty { actions?.editTags(files) }
        }

        // context menu
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let o = outline, let a = actions else { return }
            let clicked = o.clickedRow
            guard clicked >= 0, let n = o.item(atRow: clicked) as? FolderNode, !n.isPlaceholder else { return }
            // a right-click inside the selection acts on the whole selection, outside it on the clicked row only
            let targets: [FolderNode] = o.selectedRowIndexes.contains(clicked) ? o.selectedRowIndexes.compactMap { o.item(atRow: $0) as? FolderNode } : [n]
            let files = targets.filter { $0.entry.isPlayable }.map(\.entry.url)
            let taggable = targets.filter { $0.entry.isTaggable }.map(\.entry.url)
            func add(_ title: String, _ symbol: String? = nil, _ run: @escaping () -> Void) {
                let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
                let box = MenuAction(run); item.target = box; item.representedObject = box
                if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(item)
            }
            if n.isFolder && targets.count == 1 {
                add("Play Folder", "play.fill") { a.playFolder(n.entry.url) }
                add("Add Folder to Queue", "text.badge.plus") { a.enqueueFolder(n.entry.url) }
                add("Edit Tags of Files Here…", "tag") { a.editFolderTags(n.entry.url) }
                if let pdf = n.children?.first(where: { $0.entry.kind == .booklet }) { add("Open Booklet", "book") { a.openBooklet(pdf.entry.url) } }
            } else {
                if !files.isEmpty {
                    add(files.count == 1 ? "Play" : "Play \(files.count) Files", "play.fill") { a.play(files.count == 1 ? self.siblings(of: n) : files, files.count == 1 ? files[0] : nil) }
                    add("Add to Queue", "text.badge.plus") { a.enqueue(files) }
                }
                if !taggable.isEmpty { add(taggable.count == 1 ? "Edit Tags…" : "Edit Tags of \(taggable.count) Files…", "tag") { a.editTags(taggable) } }
                if n.entry.kind == .booklet { add("Open Booklet", "book") { a.openBooklet(n.entry.url) } }
                if n.entry.isPlayable, targets.count == 1 {
                    menu.addItem(.separator())
                    add("Compare in ABX as A", "a.square") { a.abx(n.entry.url, .a) }
                    add("Compare in ABX as B", "b.square") { a.abx(n.entry.url, .b) }
                }
            }
            menu.addItem(.separator())
            add("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.entry.url)) }
            add("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(targets.map(\.entry.url.path).joined(separator: "\n"), forType: .string) }
            if n.isFolder { add("Read Again", "arrow.clockwise") { self.model.refresh(n) } }
            if n.isRoot, model.isSaved(n) { menu.addItem(.separator()); add("Remove from Folders") { a.removeRoot(n) } }
        }
    }
}

/// Holds a menu item's action (NSMenuItem keeps only a weak target, so the item keeps this alive as its represented object).
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

final class FolderOutlineView: NSOutlineView {
    weak var coordinator: FolderOutline.Coordinator?
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36 || e.keyCode == 76 { coordinator?.playSelection(); return }              // Return / Enter plays
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "i" { coordinator?.editSelectionTags(); return }
        super.keyDown(with: e)
    }
}

/// A soft rounded selection in the accent colour instead of the system's blue bar.
final class FolderRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor(Brand.accent).withAlphaComponent(isEmphasized ? 0.28 : 0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

/// Icon, name, a quiet detail column and a play button that appears on hover (always shown for the file that is playing).
final class FolderCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("folderCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { updatePlayButton() } }
    private var playable = false, playing = false
    var onPlay: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        name.font = .systemFont(ofSize: 13); name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular); detail.textColor = .secondaryLabelColor; detail.alignment = .right
        detail.setContentHuggingPriority(.required, for: .horizontal)
        playButton.bezelStyle = .regularSquare; playButton.isBordered = false
        playButton.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play")
        playButton.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        playButton.target = self; playButton.action = #selector(tapPlay)
        playButton.toolTip = "Play"
        for v in [icon, name, detail, playButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        textField = name; imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 10), detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.leadingAnchor.constraint(equalTo: detail.trailingAnchor, constant: 8), playButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor), playButton.widthAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func prepareForReuse() { super.prepareForReuse(); hovering = false; onPlay = nil }

    @objc private func tapPlay() { onPlay?() }

    private func updatePlayButton() {
        playButton.isHidden = !playable
        playButton.alphaValue = playing || hovering ? 1 : 0
        playButton.contentTintColor = NSColor(Brand.accent)
    }

    func configure(_ n: FolderNode, playing: Bool) {
        let e = n.entry
        name.stringValue = e.name
        self.playing = playing
        if n.isPlaceholder {
            icon.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil); icon.contentTintColor = .secondaryLabelColor
            name.textColor = .secondaryLabelColor; detail.stringValue = ""; playable = false; updatePlayButton(); return
        }
        let symbol: String
        switch e.kind {
        case .folder: symbol = n.isRoot ? (e.url.path.hasPrefix("/Volumes/") ? "externaldrive" : "folder.fill") : (n.isLoop ? "arrow.triangle.2.circlepath" : "folder.fill")
        case .audio: symbol = playing ? "speaker.wave.2.fill" : "music.note"
        case .booklet: symbol = "book.pages"
        case .image: symbol = "photo"
        case .other: symbol = "doc"
        }
        icon.image = NSImage(systemSymbolName: e.isSymlink ? (e.isBroken ? "link.badge.plus" : symbol) : symbol, accessibilityDescription: nil)
        icon.contentTintColor = e.kind == .folder || playing ? NSColor(Brand.accent) : (e.kind == .audio ? .labelColor : .secondaryLabelColor)
        name.textColor = e.isBroken ? .tertiaryLabelColor : (playing ? NSColor(Brand.accent) : (e.kind == .audio || e.kind == .folder ? .labelColor : .secondaryLabelColor))
        name.font = .systemFont(ofSize: 13, weight: playing || n.isRoot ? .semibold : .regular)
        var bits: [String] = []
        if e.isSymlink { bits.append(e.isBroken ? "broken link" : (n.isLoop ? "link · loop" : "link")) }
        if let err = n.error { bits.append(err) }
        if e.kind == .folder, let c = n.children { bits.append("\(c.count) item\(c.count == 1 ? "" : "s")") }
        if e.kind == .audio || e.kind == .booklet || e.kind == .image {
            bits.append(e.url.pathExtension.uppercased())
            bits.append(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
        }
        detail.stringValue = bits.joined(separator: "  ·  ")
        playable = (e.isPlayable || n.isFolder) && !e.isBroken && !n.isLoop
        toolTip = e.isSymlink ? "\(e.url.path) → \(e.target?.path ?? "missing")" : e.url.path
        updatePlayButton()
    }
}

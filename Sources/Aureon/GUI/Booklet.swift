import SwiftUI
import AppKit
import PDFKit
import CoreImage
import Combine

// The digital booklet: a PDF that came with an album, shown as two-page spreads on a dark stage, with jumps to the page each track
// starts on. It lives in Now Playing (following the playing track) and in its own window (from the Folders page or "Open in Window").

/// Moves a `PDFDocument` from the thread that opened it to the main thread. Nothing else touches it in between.
private final class PDFHandle: @unchecked Sendable {
    let document: PDFDocument
    init(_ d: PDFDocument) { document = d }
}

/// Set from the main thread when the booklet changes, read by the indexing thread so that it stops early.
private final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor
final class BookletModel: ObservableObject {
    /// The booklet in Now Playing: one per app, so the PDF is not read again every time the page is shown.
    static let nowPlaying = BookletModel()

    @Published private(set) var url: URL?
    @Published private(set) var document: PDFDocument?
    @Published private(set) var tracks: [BookletTrack] = []
    @Published private(set) var anchors: [BookletAnchor] = []
    @Published private(set) var loading = false
    @Published private(set) var indexing = false
    @Published private(set) var error: String?
    /// The visible page (the left page of a spread), zero-based.
    @Published private(set) var page = 0
    /// Other booklets in the same album folder, for the picker.
    @Published private(set) var alternatives: [URL] = []

    @Published var spreads: Bool { didSet { UserDefaults.standard.set(spreads, forKey: "aureon.booklet.spreads") } }
    @Published var darkPages: Bool { didSet { UserDefaults.standard.set(darkPages, forKey: "aureon.booklet.darkPages") } }
    @Published var follow: Bool { didSet { UserDefaults.standard.set(follow, forKey: "aureon.booklet.follow"); if follow { followPlaying() } } }

    var pageCount: Int { document?.pageCount ?? 0 }

    private weak var view: PDFView?
    private var token: CancelToken?
    private var playingPath: String?
    private var watch: AnyCancellable?
    /// Booklets found per album folder (nil = none), so moving between tracks of one album does not list the folder again.
    private var found: [String: [URL]] = [:]
    private var lookup = 0

    init() {
        let d = UserDefaults.standard
        spreads = d.object(forKey: "aureon.booklet.spreads") as? Bool ?? true
        darkPages = d.object(forKey: "aureon.booklet.darkPages") as? Bool ?? false
        follow = d.object(forKey: "aureon.booklet.follow") as? Bool ?? true
        watchPlayback()
    }

    // MARK: Loading

    /// Shows `url`. `tracks` nil: the album's tracks are found next to the booklet (titles from the library where it has them).
    func load(_ url: URL, tracks given: [BookletTrack]? = nil, store: LibraryStore? = nil) {
        guard url.standardizedFileURL != self.url?.standardizedFileURL || error != nil else { return }
        token?.cancel()
        let t = CancelToken(); token = t
        self.url = url
        document = nil; anchors = []; tracks = given ?? []; error = nil; page = 0
        loading = true; indexing = true
        let store = store ?? LibraryModelBridge.shared.model?.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The document for display.
            guard let doc = PDFDocument(url: url) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.failed(t, "This PDF could not be opened.") } }
                return
            }
            if doc.isLocked, !doc.unlock(withPassword: "") {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.failed(t, "This PDF is password protected.") } }
                return
            }
            let shown = PDFHandle(doc)
            let others = FolderScanner.booklets(in: BookletIndex.albumFolder(for: url))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !t.cancelled else { return }
                    self.document = shown.document; self.loading = false
                    self.alternatives = others.count > 1 ? others : []
                }
            }
            // The index, from a second copy so that the visible one is never read from two threads.
            let list = given ?? BookletIndex.tracks(forBooklet: url, store: store)
            var anchors: [BookletAnchor] = []
            if !t.cancelled, let copy = PDFDocument(url: url) {
                if copy.isLocked { _ = copy.unlock(withPassword: "") }
                let (texts, outline) = BookletIndex.extract(copy) { t.cancelled }
                anchors = BookletIndex.anchors(pageTexts: texts, outline: outline, tracks: list)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !t.cancelled else { return }
                    self.tracks = list; self.anchors = anchors; self.indexing = false
                    self.followPlaying()
                }
            }
        }
    }

    private func failed(_ t: CancelToken, _ message: String) {
        guard !t.cancelled else { return }
        error = message; loading = false; indexing = false
    }

    /// Clears the booklet (Now Playing moved to an album without one).
    func unload() {
        token?.cancel(); token = nil
        url = nil; document = nil; anchors = []; tracks = []; alternatives = []; error = nil; loading = false; indexing = false; page = 0
    }

    /// Now Playing: shows the booklet of the album `path` belongs to, or nothing. The folder is listed off the main thread.
    func show(forTrack path: String?) {
        guard let path, !path.contains("://") else { unload(); return }
        let folder = (path as NSString).deletingLastPathComponent
        if let known = found[folder] {
            if let first = known.first { if !known.contains(where: { $0.standardizedFileURL == url?.standardizedFileURL }) { load(first) } } else { unload() }
            return
        }
        lookup += 1
        let n = lookup
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = BookletIndex.booklets(forTrack: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, n == self.lookup else { return }
                    if self.found.count > 200 { self.found.removeAll() }
                    self.found[folder] = list
                    self.show(forTrack: path)
                }
            }
        }
    }

    // MARK: Navigation

    func attach(_ v: PDFView) { view = v }

    func pageChanged(_ v: PDFView) {
        guard v === view, let doc = v.document, let p = v.currentPage else { return }
        let i = doc.index(for: p)
        if i != NSNotFound, i != page { page = i }
    }

    func go(to index: Int) {
        guard let v = view, let doc = v.document, doc.pageCount > 0, let p = doc.page(at: min(max(index, 0), doc.pageCount - 1)) else { return }
        v.go(to: p)
    }

    func next() { view?.goToNextPage(nil) }
    func previous() { view?.goToPreviousPage(nil) }
    // read from the view whenever `page` changes, which redraws the toolbar
    var canGoNext: Bool { view?.canGoToNextPage ?? false }
    var canGoBack: Bool { view?.canGoToPreviousPage ?? false }

    /// The pages on screen: the cover alone, then facing pages (odd index on the left), as `displaysAsBook` lays them out.
    var visiblePages: [Int] {
        guard spreads, page > 0 else { return [page] }
        let left = page % 2 == 1 ? page : page - 1
        return left + 1 < pageCount ? [left, left + 1] : [left]
    }

    /// "Page 3", or "Pages 4–5" for a spread (the cover stands alone, as in a printed booklet).
    var pageLabel: String {
        guard pageCount > 0 else { return "" }
        let v = visiblePages
        return v.count == 2 ? "Pages \(v[0] + 1)–\(v[1] + 1) of \(pageCount)" : "Page \(v[0] + 1) of \(pageCount)"
    }

    var trackAnchors: [BookletAnchor] { anchors.filter { $0.trackIndex != nil }.sorted { $0.trackIndex! < $1.trackIndex! } }
    var chapters: [BookletAnchor] { anchors.filter { $0.trackIndex == nil } }

    func anchor(forPath path: String) -> BookletAnchor? {
        guard let i = tracks.firstIndex(where: { $0.path == path }) else { return nil }
        return anchors.first { $0.trackIndex == i }
    }

    /// The track whose anchor page is showing (highlighted in the jump list).
    var currentTrackIndex: Int? {
        let visible = visiblePages
        return trackAnchors.last { visible.contains($0.page) }?.trackIndex
    }

    // MARK: Following playback

    /// Every booklet follows the player: a track change turns to that track's page when "Follow Playback" is on.
    private func watchPlayback() {
        watch = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.follow, self.url != nil, let m = AppDelegate.model else { return }
                let p = m.isActive ? m.current?.path : nil
                if p != self.playingPath { self.playingPath = p; self.followPlaying() }
            }
        }
    }

    private func followPlaying() {
        guard follow, let p = playingPath, let a = anchor(forPath: p) else { return }
        if !visiblePages.contains(a.page) { go(to: a.page) }
    }
}

// MARK: - PDF view

/// PDFView on Aureon's dark stage. Embedded in a scrolling page it never keeps the wheel or the keyboard for itself: the page scrolls
/// over it, arrow keys keep driving the transport, and it always shows whole spreads (zooming is for the booklet window).
final class AureonPDFView: PDFView {
    var embedded = false

    override var acceptsFirstResponder: Bool { embedded ? false : super.acceptsFirstResponder }

    override func scrollWheel(with event: NSEvent) {
        if embedded, let outer = enclosingScrollView { outer.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) { if !embedded { super.magnify(with: event) } }
    override func smartMagnify(with event: NSEvent) { if !embedded { super.smartMagnify(with: event) } }
}

struct BookletPDFView: NSViewRepresentable {
    @ObservedObject var model: BookletModel
    var embedded: Bool

    final class Coordinator { var observer: NSObjectProtocol?; var shownDarkPages: Bool?; var mode: (PDFDisplayMode, Bool)? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AureonPDFView {
        let v = AureonPDFView()
        v.embedded = embedded
        v.autoScales = true
        v.displayDirection = .vertical
        v.displaysPageBreaks = true
        v.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        v.pageShadowsEnabled = true
        v.wantsLayer = true
        v.layerUsesCoreImageFilters = true
        let model = self.model
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak v] _ in
            MainActor.assumeIsolated { if let v { model.pageChanged(v) } }
        }
        model.attach(v)
        return v
    }

    func updateNSView(_ v: AureonPDFView, context: Context) {
        model.attach(v)
        if v.document !== model.document {
            v.document = model.document
            context.coordinator.mode = nil
        }
        let mode: PDFDisplayMode = embedded ? (model.spreads ? .twoUp : .singlePage) : (model.spreads ? .twoUpContinuous : .singlePageContinuous)
        if context.coordinator.mode.map({ $0.0 != mode || $0.1 != model.spreads }) ?? true {
            let at = v.currentPage
            v.displayMode = mode
            v.displaysAsBook = model.spreads         // the cover alone on the right, then facing pages
            v.autoScales = true
            if let at { v.go(to: at) }
            context.coordinator.mode = (mode, model.spreads)
        }
        if context.coordinator.shownDarkPages != model.darkPages {
            context.coordinator.shownDarkPages = model.darkPages
            // Dark pages: invert, then turn the hues back, so black text on white becomes light on dark and photos keep their colours.
            // The stage colour is inverted too, so it is set to its own inverse.
            let stage = embedded ? NSColor.clear : NSColor(white: 0.075, alpha: 1)
            if model.darkPages, let invert = CIFilter(name: "CIColorInvert"), let hue = CIFilter(name: "CIHueAdjust") {
                hue.setValue(Double.pi, forKey: kCIInputAngleKey)
                v.contentFilters = [invert, hue]
                v.backgroundColor = embedded ? .clear : NSColor(white: 0.925, alpha: 1)
            } else {
                v.contentFilters = []
                v.backgroundColor = stage
            }
        }
    }

    static func dismantleNSView(_ v: AureonPDFView, coordinator: Coordinator) {
        if let o = coordinator.observer { NotificationCenter.default.removeObserver(o) }
    }
}

// MARK: - Controls shared by Now Playing and the window

struct BookletToolbar: View {
    @ObservedObject var model: BookletModel
    var openWindow: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Button { model.previous() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack).help("Previous page")
            Text(model.pageLabel).font(Typo.readout).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 120)
            Button { model.next() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoNext).help("Next page")
            jumpMenu
            Spacer(minLength: 8)
            if model.indexing { ProgressView().controlSize(.small).help("Finding the pages each track starts on…") }
            if model.alternatives.count > 1 {
                Menu {
                    ForEach(model.alternatives, id: \.self) { u in
                        Button { model.load(u) } label: { Label(u.deletingPathExtension().lastPathComponent, systemImage: u == model.url ? "checkmark" : "doc") }
                    }
                } label: { Image(systemName: "doc.on.doc") }.menuStyle(.borderlessButton).fixedSize().help("Other booklets in this album")
            }
            Toggle(isOn: $model.spreads) { Image(systemName: "book") }.toggleStyle(.button).help("Two-page spreads")
            Toggle(isOn: $model.darkPages) { Image(systemName: "circle.lefthalf.filled") }.toggleStyle(.button).help("Dark pages")
            Toggle(isOn: $model.follow) { Image(systemName: "dot.radiowaves.forward") }.toggleStyle(.button).help("Follow playback: turn to the playing track's page")
            if let openWindow { Button(action: openWindow) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Open in a window") }
        }
        .buttonStyle(IconButtonStyle())
    }

    private var jumpMenu: some View {
        Menu {
            if model.trackAnchors.isEmpty && model.chapters.isEmpty {
                Text(model.indexing ? "Reading the booklet…" : "No track pages found")
            }
            if !model.trackAnchors.isEmpty {
                Section("Tracks") {
                    ForEach(model.trackAnchors) { a in
                        Button("\(label(a))  ·  p. \(a.page + 1)") { model.go(to: a.page) }
                    }
                }
            }
            if !model.chapters.isEmpty {
                Section("Contents") {
                    ForEach(model.chapters) { a in Button("\(a.title)  ·  p. \(a.page + 1)") { model.go(to: a.page) } }
                }
            }
        } label: {
            Label("Jump to", systemImage: "list.bullet").labelStyle(.titleAndIcon).font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(model.document == nil)
    }

    private func label(_ a: BookletAnchor) -> String {
        guard let i = a.trackIndex, i < model.tracks.count else { return a.title }
        return model.tracks[i].number.map { "\($0). \(a.title)" } ?? a.title
    }
}

/// The track jump list as a row of chips (Now Playing) or a column (window).
struct BookletTrackList: View {
    @ObservedObject var model: BookletModel
    var vertical = false

    var body: some View {
        let current = model.currentTrackIndex
        let playing = AppDelegate.model.flatMap { $0.isActive ? $0.current?.path : nil }
        let items = model.trackAnchors
        let chips = ForEach(items) { a in
            let t = a.trackIndex.flatMap { $0 < model.tracks.count ? model.tracks[$0] : nil }
            Button { model.go(to: a.page) } label: {
                HStack(spacing: 6) {
                    if let n = t?.number { Text("\(n)").font(Typo.readout).foregroundStyle(.secondary) }
                    if t?.path != nil && t?.path == playing { Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)).foregroundStyle(Brand.accent) }
                    Text(a.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if vertical { Spacer(minLength: 4) }
                    Text("p. \(a.page + 1)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(a.trackIndex == current ? Brand.accent.opacity(0.22) : Brand.ink.opacity(0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(a.source == .outline ? "From the booklet's table of contents" : "Found in the booklet's text")
        }
        if vertical {
            VStack(alignment: .leading, spacing: 4) { chips }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) { chips }
        }
    }
}

// MARK: - Now Playing

/// The booklet of the playing album, in Now Playing. Takes no room at all when the album has no PDF.
struct BookletSection: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var b = BookletModel.nowPlaying
    @AppStorage("aureon.booklet.expanded") private var expanded = true
    @AppStorage("aureon.booklet.showTracks") private var showTracks = true

    var body: some View {
        let path = m.focusItem.flatMap { $0.isStream ? nil : $0.path }
        Group {
            if b.url != nil {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if expanded {
                        BookletToolbar(model: b) { if let u = b.url { BookletWindow.open(url: u, tracks: b.tracks) } }
                        stage
                        if showTracks && !b.trackAnchors.isEmpty { BookletTrackList(model: b) }
                    }
                }
                .padding(16)
                .glassPanel(radius: 20)
                .transition(.opacity)
            }
        }
        .onAppear { b.show(forTrack: path) }
        .onChange(of: path) { _, p in b.show(forTrack: p) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.pages").foregroundStyle(Brand.accent)
            Text("Digital Booklet").kicker().foregroundStyle(.white.opacity(0.75))
            if let u = b.url { Text(u.deletingPathExtension().lastPathComponent).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
            Spacer()
            if expanded && !b.trackAnchors.isEmpty {
                Button(showTracks ? "Hide Tracks" : "Show Tracks") { showTracks.toggle() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Button { withAnimation(.smooth(duration: 0.25)) { expanded.toggle() } } label: {
                Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .buttonStyle(IconButtonStyle()).help(expanded ? "Collapse" : "Expand")
        }
    }

    @ViewBuilder private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.35))
            if let e = b.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if b.document == nil {
                ProgressView().controlSize(.small)
            } else {
                BookletPDFView(model: b, embedded: true).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(height: 440)
    }
}

// MARK: - Window

@MainActor
enum BookletWindow {
    private static var windows: [(NSWindow, BookletModel)] = []

    /// Opens `url` in its own window, or brings its window forward. `tracks` empty: found next to the booklet.
    static func open(url: URL, tracks: [BookletTrack]) {
        if let open = windows.first(where: { $0.1.url?.standardizedFileURL == url.standardizedFileURL }) { open.0.makeKeyAndOrderFront(nil); return }
        let model = BookletModel()
        model.load(url, tracks: tracks.isEmpty ? nil : tracks)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = url.deletingPathExtension().lastPathComponent
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 480)
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(white: 0.075, alpha: 1)
        w.contentView = NSHostingView(rootView: BookletWindowView(model: model).environment(\.colorScheme, .dark))
        w.setFrameAutosaveName("AureonBooklet")
        if !w.setFrameUsingName("AureonBooklet") { w.center() }
        w.makeKeyAndOrderFront(nil)
        windows.append((w, model))
        WindowClosing.whenClosed(w) { [weak w] in windows.removeAll { $0.0 === w } }
    }
}

struct BookletWindowView: View {
    @ObservedObject var model: BookletModel
    @AppStorage("aureon.booklet.sidebar") private var sidebar = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.smooth(duration: 0.2)) { sidebar.toggle() } } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(IconButtonStyle()).help("Tracks")
                BookletToolbar(model: model)
            }
            .padding(.leading, 78).padding(.trailing, 14).padding(.vertical, 8)
            .background(Color.black.opacity(0.25))
            HStack(spacing: 0) {
                if sidebar {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if !model.trackAnchors.isEmpty {
                                Text("Tracks").microLabel().foregroundStyle(.secondary)
                                BookletTrackList(model: model, vertical: true)
                            }
                            if !model.chapters.isEmpty {
                                Text("Contents").microLabel().foregroundStyle(.secondary)
                                ForEach(model.chapters) { a in
                                    Button { model.go(to: a.page) } label: {
                                        HStack { Text(a.title).lineLimit(2); Spacer(); Text("p. \(a.page + 1)").foregroundStyle(.tertiary) }.font(.system(size: 12)).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if model.trackAnchors.isEmpty && model.chapters.isEmpty {
                                Text(model.indexing ? "Reading the booklet…" : "This booklet names none of the album's tracks.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                    }
                    .frame(width: 250)
                    .background(Color.black.opacity(0.18))
                    .transition(.move(edge: .leading))
                }
                ZStack {
                    if let e = model.error {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else if model.document == nil {
                        ProgressView()
                    } else {
                        BookletPDFView(model: model, embedded: false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

import SwiftUI

// The library's folders as a page: each folder with where it stands (watched, scanning, not connected), how many songs came from it and a Rescan; beside
// them, Add music and the way into the disk browser. The folders themselves are the library model's (`lib.folders`); this page only shows and reads them.

/// How many songs each library folder holds, counted off the main thread whenever the library changes.
@MainActor
final class FolderStatsModel: ObservableObject {
    @Published private(set) var counts: [String: Int] = [:]
    private var stamp = ""
    private var task: Task<Void, Never>?

    func load(_ store: LibraryStore?, folders: [String], revision: Int64) {
        let key = folders.joined(separator: "\n") + "|\(revision)"
        guard let store, key != stamp else { return }
        stamp = key
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            var out: [String: Int] = [:]
            for f in folders { if Task.isCancelled { return }; out[f] = store.knownFiles(under: f).count }
            let result = out
            await MainActor.run { self?.counts = result }
        }
    }
}

/// What a folder's line says about it.
enum FolderStatus: Equatable {
    case watching, scanning(String), missing, idle
    var title: String {
        switch self { case .watching: "Watching for changes"; case .scanning(let s): s; case .missing: "Disk not connected"; case .idle: "Not watched" }
    }
    var detail: String {
        switch self { case .watching, .idle: "Up to date"; case .scanning: "Reading files"; case .missing: "Needs access" }
    }
    static func of(path: String, watching: Bool, importing: Bool, progress: String, exists: Bool) -> FolderStatus {
        if !exists { return .missing }
        if importing { return .scanning(progress.isEmpty ? "Scanning…" : progress) }
        return watching ? .watching : .idle
    }
}

struct LibraryFoldersPage: View {
    @EnvironmentObject var m: PlayerModel
    @Environment(\.chromeInset) private var inset
    @StateObject private var stats = FolderStatsModel()
    @StateObject private var browsing = Box(false)

    var body: some View {
        if browsing.v {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(Motion.touch) { browsing.v = false } } label: { Label("Library folders", systemImage: "chevron.left").font(Typo.sans(13, .medium)) }
                    .buttonStyle(.plain).foregroundStyle(Brand.accentText).padding(.horizontal, 28).padding(.top, 4)
                FolderBrowserPage()
            }
            .padding(.top, inset)
        } else {
            list
        }
    }

    private var list: some View {
        let lib = m.library
        let songs = stats.counts.values.reduce(0, +)
        return PageScaffold(title: "Library", subtitle: "\(lib.folders.count) folder\(lib.folders.count == 1 ? "" : "s") · \(songs.formatted()) songs", trailing: {
            HStack(spacing: 8) {
                Button("Rescan all") { lib.rescan() }.buttonStyle(.rule).disabled(lib.folders.isEmpty || lib.importing)
                Button { choose() } label: { Label("Add folder", systemImage: "folder.badge.plus") }.buttonStyle(.solid)
            }.fixedSize()
        }) {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    if lib.folders.isEmpty { emptyCard }
                    ForEach(lib.folders, id: \.self) { f in FolderCard(path: f, songs: stats.counts[f], lib: lib) }
                }.frame(maxWidth: .infinity)
                addPanel.frame(width: 320)
            }
        }
        .onAppear { stats.load(lib.store, folders: lib.folders, revision: lib.stats.revision) }
        .onChange(of: lib.folders) { _, f in stats.load(lib.store, folders: f, revision: lib.stats.revision) }
        .onChange(of: lib.stats.revision) { _, r in stats.load(lib.store, folders: lib.folders, revision: r) }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No folders yet").font(Typo.serif(16, .medium))
            Text("Add the folder your music lives in. Aureon reads it once, then keeps watching it. Your files are never changed.").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Brand.panel2))
    }

    private var addPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add music").font(Typo.sans(15, .medium))
            Button { choose() } label: { Text("Choose folder…").frame(maxWidth: .infinity) }.buttonStyle(.solid).controlSize(.large)
            Button { withAnimation(Motion.touch) { browsing.v = true } } label: { Text("Browse files on disk").font(Typo.sans(13, .medium)).frame(maxWidth: .infinity).frame(height: 44).background(Capsule().fill(Brand.panel)).contentShape(Capsule()) }.buttonStyle(.plain)
            Text("Or drop a folder anywhere on the window.").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.panel2))
    }

    private func choose() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = "Choose the folder(s) that contain your music"
        DispatchQueue.main.async { if p.runModal() == .OK { p.urls.forEach { m.library.addFolder($0) } } }
    }
}

/// One library folder: its icon, path and status, the songs it holds, and Rescan.
struct FolderCard: View {
    let path: String
    let songs: Int?
    @ObservedObject var lib: LibraryModel
    @StateObject private var hover = Box(false)

    private var exists: Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue }

    var body: some View {
        let status = FolderStatus.of(path: path, watching: lib.watcher != nil, importing: lib.importing, progress: lib.importProgress, exists: exists)
        HStack(spacing: 16) {
            Image(systemName: status == .missing ? "externaldrive.badge.exclamationmark" : "folder.fill").font(Typo.sans(18))
                .foregroundStyle(status == .missing ? Brand.caution : Brand.accentText)
                .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.panel))
            VStack(alignment: .leading, spacing: 3) {
                Text(path).font(Typo.sans(15)).lineLimit(1).truncationMode(.middle)
                Text(status.title).font(Typo.sans(12.5)).foregroundStyle(status == .missing ? Brand.caution : Brand.inkSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(songs.map { "\($0.formatted()) songs" } ?? "—").font(Typo.sans(15))
                Text(status.detail).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
            }
            Button(status == .missing ? "Reconnect" : "Rescan") { if status == .missing { reconnect() } else { lib.rescan(path) } }
                .buttonStyle(.rule).controlSize(.small).disabled(lib.importing && status != .missing)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(hover.v ? Brand.ink.opacity(0.1) : Brand.panel2))
        .onHover { hover.v = $0 }
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.disabled(!exists) }
    }

    private func reconnect() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        p.message = "Choose \(path) again to give Aureon access"
        DispatchQueue.main.async { if p.runModal() == .OK, let u = p.url { lib.addFolder(u) } }
    }
}

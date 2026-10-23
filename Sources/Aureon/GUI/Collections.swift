import SwiftUI
import AppKit

/// Liked songs and playlists: the state the hearts, menus and the two pages read.
@MainActor
final class CollectionsModel: ObservableObject {
    @Published private(set) var liked: Set<String> = []                  // file paths
    @Published private(set) var playlists: [PlaylistDTO] = []
    @Published private(set) var likedTracks: [TrackDTO] = []
    @Published var selected: String?                                     // the playlist being viewed
    @Published private(set) var selectedTracks: [TrackDTO] = []
    var store: LibraryStore?

    func attach(_ s: LibraryStore?) { store = s; refresh() }

    private var refreshing = false, again = false

    /// Reads likes and playlists on a background queue (they can hold thousands of songs) and publishes the result.
    func refresh() {
        guard let store else { return }
        if refreshing { again = true; return }
        refreshing = true
        let sel = selected
        Task.detached(priority: .userInitiated) {
            let l = store.likedPaths(), p = store.playlists(), lt = store.likedTracks()
            let st = sel.flatMap { id in p.contains { $0.id == id } ? store.playlistTracks(id: id) : nil }
            await MainActor.run {
                self.liked = l; self.playlists = p; self.likedTracks = lt
                if let id = self.selected { if let st, id == sel { self.selectedTracks = st } else if !p.contains(where: { $0.id == id }) { self.selected = nil; self.selectedTracks = [] } }
                self.refreshing = false
                if self.again { self.again = false; self.refresh() }
            }
        }
    }

    func isLiked(_ path: String) -> Bool { liked.contains(path) }

    func toggleLike(path: String) {
        guard let store else { return }
        let now = !liked.contains(path)
        withAnimation(Motion.glide) { if now { liked.insert(path) } else { liked.remove(path) } }      // the heart answers at once
        Task.detached(priority: .userInitiated) { store.setLiked(paths: [path], liked: now); await MainActor.run { self.refresh() } }
    }

    func setLiked(_ tracks: [TrackDTO], _ on: Bool) { store?.setLiked(paths: tracks.map(\.path), liked: on); refresh() }

    @discardableResult
    func create(name: String, with tracks: [TrackDTO] = []) -> PlaylistDTO? {
        let p = store?.createPlaylist(name: name, paths: tracks.map(\.path))
        refresh()
        return p
    }
    func rename(_ id: String, to name: String) { store?.renamePlaylist(id: id, name: name); refresh() }
    func delete(_ id: String) { store?.deletePlaylist(id: id); if selected == id { selected = nil }; refresh() }
    @discardableResult
    func add(_ tracks: [TrackDTO], to id: String) -> Int { let n = store?.addToPlaylist(id: id, paths: tracks.map(\.path)) ?? 0; refresh(); return n }
    func remove(_ tracks: [TrackDTO], from id: String) { store?.removeFromPlaylist(id: id, paths: tracks.map(\.path)); refresh() }
    func move(_ t: TrackDTO, in id: String, by delta: Int) {
        guard let i = selectedTracks.firstIndex(where: { $0.path == t.path }), selectedTracks.indices.contains(i + delta) else { return }
        store?.movePlaylistEntries(id: id, from: IndexSet(integer: i), to: delta > 0 ? i + 2 : i - 1)
        refresh()
    }
    func open(_ id: String) { selected = id; refresh() }
}

/// Asks for a line of text in a small system dialog.
@MainActor
func promptForText(title: String, message: String = "", placeholder: String = "", initial: String = "", confirm: String = "OK") -> String? {
    let a = NSAlert()
    a.messageText = title; a.informativeText = message
    a.addButton(withTitle: confirm); a.addButton(withTitle: "Cancel")
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    f.stringValue = initial; f.placeholderString = placeholder
    a.accessoryView = f
    a.window.initialFirstResponder = f
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

// MARK: - Controls

/// A heart that fills with a small bounce.
struct HeartButton: View {
    @EnvironmentObject var c: CollectionsModel
    let path: String?
    var size: CGFloat = 13
    var alwaysVisible = true
    /// Overrides the theme's ink where the surface is always dark (the player).
    var ink: Color? = nil
    @StateObject private var hover = Box(false)

    var body: some View {
        let on = path.map { c.isLiked($0) } ?? false
        Button { if let path { c.toggleLike(path: path) } } label: {
            Image(systemName: on ? "heart.fill" : "heart").font(Typo.sans(size, .light))
                .foregroundStyle(on ? AnyShapeStyle(Brand.accent) : AnyShapeStyle((ink ?? Brand.ink).opacity(hover.v ? 0.95 : 0.7)))
                
                .frame(width: size + 10, height: size + 10).contentShape(Rectangle())
                .opacity(on || alwaysVisible || hover.v ? 1 : 0)
        }
        .buttonStyle(.plain).disabled(path == nil).onHover { hover.v = $0 }
        .help(on ? "Remove from Liked Songs" : "Add to Liked Songs")
    }
}

/// The items every song's context menu shares: like, add to playlist, queue.
struct TrackMenu: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var c: CollectionsModel
    let tracks: [TrackDTO]
    var playlistID: String?

    var body: some View {
        if let first = tracks.first {
            let all = tracks.allSatisfy { c.isLiked($0.path) }
            Button(all ? "Remove from Liked Songs" : "Add to Liked Songs") { c.setLiked(tracks, !all) }
            Menu("Add to Playlist") {
                Button("New Playlist…") {
                    if let name = promptForText(title: "New Playlist", message: tracks.count == 1 ? "“\(first.title)” will be added to it." : "\(tracks.count) songs will be added to it.", placeholder: "Playlist name", confirm: "Create") { c.create(name: name, with: tracks) }
                }
                if !c.playlists.isEmpty { Divider() }
                ForEach(c.playlists) { p in Button(p.name) { c.add(tracks, to: p.id) } }
            }
            Divider()
            Button("Add to Queue") { m.library.onAdd?(tracks, false) }
            Button("Play Next") { m.playNext(tracks) }
            Divider()
            Button("Edit Tags…") { TagEditorWindow.open(paths: tracks.map(\.path), model: m) }
                .disabled(!tracks.contains { TagEditing.isEditable($0.path) })
            if let pid = playlistID {
                Divider()
                if tracks.count == 1 { Button("Move Up") { c.move(first, in: pid, by: -1) }; Button("Move Down") { c.move(first, in: pid, by: 1) } }
                Button("Remove from Playlist") { c.remove(tracks, from: pid) }
            }
        }
    }
}

// MARK: - Pages

struct LikedPage: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var c: CollectionsModel

    var body: some View {
        PageScaffold(title: "Liked Songs", subtitle: "\(c.likedTracks.count) songs", trailing: {
            if !c.likedTracks.isEmpty { actions }
        }) {
            if c.likedTracks.isEmpty {
                EmptyExplainer(icon: "heart", title: "No liked songs yet",
                               text: "Tap the heart next to any song, in the player or in a list, and it appears here. Liked songs are also favoured by Smart Shuffle.")
            } else { SongList(tracks: c.likedTracks) }
        }
        .onAppear { c.refresh() }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            RuleButton(title: "Play", symbol: "play.fill", filled: true) { m.play(tracks: c.likedTracks, at: 0) }
            RuleButton(title: "Shuffle", symbol: "shuffle") { m.play(tracks: c.likedTracks.shuffled(), at: 0) }
        }
    }
}

struct PlaylistsPage: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var c: CollectionsModel
    @StateObject private var describe = Box(false)

    var body: some View {
        if let id = c.selected, let p = c.playlists.first(where: { $0.id == id }) { PlaylistDetail(playlist: p) }
        else { list }
    }

    private var list: some View {
        PageScaffold(title: "Playlists", subtitle: "\(c.playlists.count)", trailing: {
            RuleButton(title: "Describe a Playlist", symbol: "text.badge.plus") { describe.v = true }
            RuleButton(title: "New Playlist", symbol: "plus", filled: true) { newPlaylist() }
        }) {
            if c.playlists.isEmpty {
                EmptyExplainer(icon: "music.note.list", title: "Make your first playlist",
                               text: "Playlists are lists of songs you choose and order. Create one here, or right-click any song and choose Add to Playlist.",
                               action: ("New Playlist", { newPlaylist() }))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 16, alignment: .top)], alignment: .leading, spacing: 24) {
                    ForEach(c.playlists) { p in PlaylistCard(playlist: p) }
                }
            }
        }
        .onAppear { c.refresh() }
        .sheet(isPresented: $describe.v) {
            NaturalPlaylistSheet(ai: IntelligenceCenter.shared, service: IntelligenceCenter.shared.playlists).environmentObject(m).environmentObject(c)
        }
    }

    private func newPlaylist() {
        if let name = promptForText(title: "New Playlist", placeholder: "Playlist name", confirm: "Create"), let p = c.create(name: name) { c.open(p.id) }
    }
}

struct PlaylistCard: View {
    @EnvironmentObject var c: CollectionsModel
    @EnvironmentObject var m: PlayerModel
    let playlist: PlaylistDTO
    @StateObject private var hover = Box(false)

    var body: some View {
        let pal = ArtPalette.fallback(seed: playlist.name)
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.radius(12), style: .continuous).fill(LinearGradient(colors: [pal.grid[0].color, pal.grid[8].color], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note.list").font(Typo.sans(34, .light)).foregroundStyle(Brand.inkSecondary)
            }
            .aspectRatio(1, contentMode: .fit)
            .hoverLift(hover.v, radius: 12, glow: pal.accent.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.name).font(Typo.sans(12.5, .semibold)).lineLimit(1)
                Text("\(playlist.trackCount) song\(playlist.trackCount == 1 ? "" : "s")").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { c.open(playlist.id) }
        .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hover.v = h } }
        .contextMenu {
            Button("Play") { m.play(tracks: m.library.store?.playlistTracks(id: playlist.id) ?? [], at: 0) }
            Button("Rename…") { if let n = promptForText(title: "Rename Playlist", initial: playlist.name, confirm: "Rename") { c.rename(playlist.id, to: n) } }
            Divider()
            Button("Delete Playlist", role: .destructive) { c.delete(playlist.id) }
        }
    }
}

struct PlaylistDetail: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var c: CollectionsModel
    let playlist: PlaylistDTO

    var body: some View {
        let tracks = c.selectedTracks
        let pal = ArtPalette.fallback(seed: playlist.name)
        PageScaffold(title: "", back: { c.selected = nil }, backTitle: "Playlists") {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 24) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous).fill(LinearGradient(colors: [pal.grid[0].color, pal.grid[8].color], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "music.note.list").font(Typo.sans(54, .light)).foregroundStyle(Brand.inkSecondary)
                    }.frame(width: 190, height: 190)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PLAYLIST").microLabel().foregroundStyle(Brand.cyan)
                        Text(playlist.name).font(Typo.serif(28, .regular)).tracking(-0.5).lineLimit(2)
                        Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")" + (tracks.isEmpty ? "" : " · \(Int((tracks.reduce(0) { $0 + $1.duration } / 60).rounded())) minutes")).microLabel().foregroundStyle(Brand.inkSecondary)
                        HStack(spacing: 8) {
                            RuleButton(title: "Play", symbol: "play.fill", filled: true) { m.play(tracks: tracks, at: 0) }
                            RuleButton(title: "Shuffle", symbol: "shuffle") { m.play(tracks: tracks.shuffled(), at: 0) }
                            RuleButton(title: "Add to Queue", symbol: "text.badge.plus") { m.library.onAdd?(tracks, false) }
                            RuleButton(title: "Rename", symbol: "pencil") { if let n = promptForText(title: "Rename Playlist", initial: playlist.name, confirm: "Rename") { c.rename(playlist.id, to: n) } }
                            RuleButton(title: "Delete", symbol: "trash") { confirmDelete() }
                        }.padding(.top, 12)
                    }
                    Spacer(minLength: 0)
                }
                if tracks.isEmpty {
                    EmptyExplainer(icon: "text.badge.plus", title: "This playlist is empty",
                                   text: "Right-click any song in your library and choose Add to Playlist → \(playlist.name), or add a whole album or artist from its page.")
                } else { SongList(tracks: tracks, playlistID: playlist.id) }
            }
        }
        .onAppear { c.refresh() }
    }

    private func confirmDelete() {
        let a = NSAlert()
        a.messageText = "Delete “\(playlist.name)”?"; a.informativeText = "The playlist is removed. The songs stay in your library."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel"); a.buttons[0].hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { c.delete(playlist.id) }
    }
}

/// What a page shows when it has nothing yet: what it is for and how to fill it.
struct EmptyExplainer: View {
    let icon: String
    let title: String
    let text: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(Typo.sans(40, .ultraLight)).foregroundStyle(Brand.inkSecondary)
            Text(title).font(Typo.t3.weight(.semibold))
            Text(text).multilineTextAlignment(.center).foregroundStyle(Brand.inkSecondary).frame(maxWidth: 440).font(Typo.callout)
            if let action { RuleButton(title: action.0, symbol: "plus", filled: true, action: action.1).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity).padding(.top, 64)
    }
}

// MARK: - Hover effect

extension View {
    /// Hover feedback for covers and portraits: a champagne hairline just outside the picture. Nothing grows or glows.
    func hoverLift(_ on: Bool, radius: CGFloat = 12, glow: Color = Brand.accent, scale: CGFloat = 1) -> some View {
        self
            .overlay(RoundedRectangle(cornerRadius: min(Metrics.radius(radius), 3), style: .continuous).strokeBorder(Brand.coachline, lineWidth: Metrics.hairline).padding(-3).opacity(on ? 1 : 0))
            .animation(Motion.touch, value: on)
    }
}

/// "Add the playing song to a playlist": a menu next to the heart in the player and the bar.
struct AddToPlaylistButton: View {
    @EnvironmentObject var c: CollectionsModel
    let path: String?
    var size: CGFloat = 13
    var ink: Color? = nil
    @StateObject private var added = Box<String?>(nil)
    @StateObject private var resolved = Box<(path: String, track: TrackDTO?)?>(nil)

    var body: some View {
        let track = lookup()
        Menu {
            if let track {
                Button("New Playlist…") {
                    if let name = promptForText(title: "New Playlist", message: "“\(track.title)” will be added to it.", placeholder: "Playlist name", confirm: "Create") {
                        if let p = c.create(name: name, with: [track]) { flash(p.name) }
                    }
                }
                if !c.playlists.isEmpty { Divider() }
                ForEach(c.playlists) { p in
                    Button(p.name) { let n = c.add([track], to: p.id); flash(n > 0 ? p.name : "\(p.name) (already there)") }
                }
            } else {
                Text("This song is not in your library")
            }
        } label: {
            Image(systemName: added.v != nil ? "checkmark" : "text.badge.plus").font(Typo.sans(size, .medium))
                .foregroundStyle(added.v != nil ? AnyShapeStyle(Brand.accent) : AnyShapeStyle((ink ?? Brand.ink).opacity(0.7)))
                .frame(width: size + 10, height: size + 10).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(path == nil)
        .help(added.v.map { "Added to \($0)" } ?? "Add to a playlist")
    }

    /// A database lookup, done once per song rather than on every redraw.
    private func lookup() -> TrackDTO? {
        guard let path else { return nil }
        if let c = resolved.v, c.path == path { return c.track }
        let t = c.store?.track(path: path)
        DispatchQueue.main.async { resolved.v = (path, t) }
        return t
    }

    private func flash(_ name: String) {
        added.v = name
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [added] in added.v = nil }
    }
}

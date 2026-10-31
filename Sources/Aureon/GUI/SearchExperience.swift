import SwiftUI
import AppKit

// Search as people expect it: a field in the top bar with a suggestions list under it while typing, a results page with filter chips and a Top result,
// and, with nothing typed, recent searches and a grid of genres to browse. The query language (fields, AND / OR, ranges) still works; it is explained
// in a small "Search tips" popover next to the field and is never shown inline.

// MARK: - Scopes, ranking, filtering, recents (plain code, tested)

enum SearchScope: String, CaseIterable, Identifiable {
    case all, songs, albums, artists, playlists, genres, podcasts
    var id: String { rawValue }
    var title: String { self == .all ? "All" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

struct SearchSuggestion: Identifiable, Equatable {
    enum Kind: Equatable { case completion, song, album, artist, playlist, genre }
    var kind: Kind
    /// Unique per row.
    var id: String
    var title: String
    var subtitle: String
    /// What a completion or genre row searches for; the path, release, party or playlist id of an entity row.
    var ref: String
    var typeLabel: String {
        switch kind { case .completion: "Search"; case .song: "Song"; case .album: "Album"; case .artist: "Artist"; case .playlist: "Playlist"; case .genre: "Genre" }
    }
}

enum SearchTop: Equatable {
    case artist(PartyDTO), album(ReleaseDTO), track(TrackDTO)
}

enum SearchRanking {
    /// How well `text` answers `query`: 100 the same, 80 starts with it, 60 a word starts with it, 40 contains it, 0 not at all. Ignores case and accents.
    static func score(_ text: String, query: String) -> Int {
        let t = LibraryStore.fold(text), q = LibraryStore.fold(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if t == q { return 100 }
        if t.hasPrefix(q) { return 80 }
        if t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 60 }
        return t.contains(q) ? 40 : 0
    }

    static let typeWeight: [SearchSuggestion.Kind: Double] = [.artist: 1.25, .album: 1.12, .song: 1.0, .playlist: 0.9, .genre: 0.85]

    /// The rows of the suggestions list: up to three ways to complete the query (recent searches first, then names in the library), then up to six things.
    static func suggestions(query: String, results: SearchResults?, playlists: [PlaylistDTO], genres: [String], recents: [String], entityLimit: Int = 6) -> [SearchSuggestion] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [SearchSuggestion] = []
        var seen = Set<String>([LibraryStore.fold(q)])
        func completion(_ text: String, _ note: String) {
            let key = LibraryStore.fold(text)
            guard out.filter({ $0.kind == .completion }).count < 3, !seen.contains(key) else { return }
            seen.insert(key)
            out.append(SearchSuggestion(kind: .completion, id: "c:" + key, title: text, subtitle: note, ref: text))
        }
        for r in recents where score(r, query: q) >= 80 { completion(r, "Recent") }
        var names: [(String, Int)] = []
        if let r = results {
            names += r.parties.map { ($0.name, score($0.name, query: q)) }
            names += r.releases.map { ($0.title, score($0.title, query: q)) }
            names += r.tracks.map { ($0.title, score($0.title, query: q)) }
        }
        for (n, s) in names.filter({ $0.1 >= 60 }).sorted(by: { $0.1 > $1.1 }) { completion(n, "") }

        var things: [(Double, SearchSuggestion)] = []
        func add(_ s: Int, _ k: SearchSuggestion.Kind, _ row: SearchSuggestion) { if s > 0 { things.append((Double(s) * (typeWeight[k] ?? 1), row)) } }
        if let r = results {
            for p in r.parties { add(score(p.name, query: q), .artist, SearchSuggestion(kind: .artist, id: "a:" + p.id, title: p.name, subtitle: p.kind == "group" ? "Ensemble" : "Artist", ref: p.id)) }
            for a in r.releases { add(score(a.title, query: q), .album, SearchSuggestion(kind: .album, id: "r:" + a.id, title: a.title, subtitle: "Album · " + (a.artistNames.first ?? ""), ref: a.id)) }
            for t in r.tracks { add(score(t.title, query: q), .song, SearchSuggestion(kind: .song, id: "t:" + t.id, title: t.title, subtitle: "Song · " + t.artistLine, ref: t.path)) }
        }
        for p in playlists { add(score(p.name, query: q), .playlist, SearchSuggestion(kind: .playlist, id: "p:" + p.id, title: p.name, subtitle: "Playlist · \(p.trackCount) songs", ref: p.id)) }
        for g in genres { add(score(g, query: q), .genre, SearchSuggestion(kind: .genre, id: "g:" + g, title: g, subtitle: "Genre", ref: g)) }
        // best first; equal scores keep the order they came in (stable)
        let ranked = things.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }.map(\.element.1)
        return out + ranked.prefix(entityLimit)
    }

    /// The card at the top of the results: the best match among artists, albums and songs; with no good match, the first song.
    static func topResult(query: String, results: SearchResults?) -> SearchTop? {
        guard let r = results else { return nil }
        var best: (Double, SearchTop)?
        func consider(_ s: Int, _ w: Double, _ t: SearchTop) { guard s > 0 else { return }; let v = Double(s) * w; if best == nil || v > best!.0 { best = (v, t) } }
        for p in r.parties { consider(score(p.name, query: query), 1.3, .artist(p)) }
        for a in r.releases { consider(score(a.title, query: query), 1.15, .album(a)) }
        for t in r.tracks { consider(score(t.title, query: query), 1.0, .track(t)) }
        return best?.1 ?? r.tracks.first.map { .track($0) }
    }

    /// What a filter chip shows: only that kind of result.
    static func filtered(_ r: SearchResults, scope: SearchScope) -> SearchResults {
        switch scope {
        case .all: return r
        case .songs: return SearchResults(tracks: r.tracks)
        case .albums: return SearchResults(releases: r.releases)
        case .artists: return SearchResults(parties: r.parties)
        case .playlists, .genres, .podcasts: return SearchResults()
        }
    }
}

/// The recent searches, kept between launches: newest first, no duplicates (ignoring case), at most ten.
struct SearchRecents: Equatable {
    static let key = "aureon.search.recents"
    static let limit = 10
    var items: [String] = []

    static func load(_ d: UserDefaults = .standard) -> SearchRecents { SearchRecents(items: (d.stringArray(forKey: key) ?? []).prefix(limit).map { $0 }) }
    func save(_ d: UserDefaults = .standard) { d.set(items, forKey: Self.key) }

    mutating func add(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.removeAll { LibraryStore.fold($0) == LibraryStore.fold(t) }
        items.insert(t, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }
    mutating func remove(_ q: String) { items.removeAll { $0 == q } }
    mutating func clear() { items = [] }
}

// MARK: - Pictures for the genre tiles

enum GenrePicker {
    /// Up to `count` albums from `pool`, chosen at random. The first pick is never the one shown last time when the pool has more than one album, and the
    /// whole choice differs from the last when that is possible, so a tile changes every time the page is opened.
    static func pick<G: RandomNumberGenerator>(_ pool: [String], previous: [String], count: Int, using rng: inout G) -> [String] {
        guard !pool.isEmpty, count > 0 else { return [] }
        var shuffled = pool.shuffled(using: &rng)
        if pool.count > 1, let last = previous.first, shuffled.first == last { shuffled.swapAt(0, 1 + Int.random(in: 0..<(shuffled.count - 1), using: &rng)) }
        return Array(shuffled.prefix(count))
    }
}

/// The albums behind each genre tile: which albums are in the genre (read once, off the main thread), and the few chosen to show this time.
@MainActor
final class GenreArt: ObservableObject {
    @Published private(set) var picks: [String: [ReleaseDTO]] = [:]
    private var pools: [String: [String]] = [:]
    private var last: [String: [String]] = [:]
    private var busy = Set<String>()
    /// Covers already on a tile in this round, so no cover repeats across the grid; a genre with none left of its own shows a colour tile.
    private var used = Set<String>()
    private var usedEpoch = -1

    /// Chooses new pictures for `node` (and loads them through the artwork cache). Called every time the Search page is opened, and once per launch at least.
    func refresh(_ node: TagTreeNode, store: LibraryStore?, art: AlbumArt, epoch: Int = 0) async {
        guard let store, !busy.contains(node.id) else { return }
        if epoch != usedEpoch { usedEpoch = epoch; used = [] }
        busy.insert(node.id); defer { busy.remove(node.id) }
        if pools[node.id] == nil {
            let query = node.query
            let pool: [String] = await Task.detached(priority: .utility) {
                guard let q = try? LibraryQuery(parsing: query) else { return [] }
                var seen = Set<String>(), out: [String] = []
                for t in store.tracks(matching: q, limit: 400) { if let r = t.releaseID, seen.insert(r).inserted { out.append(r) } }
                return Array(out.prefix(60))
            }.value
            pools[node.id] = pool
        }
        var rng = SystemRandomNumberGenerator()
        let free = (pools[node.id] ?? []).filter { !used.contains($0) }
        let chosen = GenrePicker.pick(free, previous: last[node.id] ?? [], count: 3, using: &rng)
        last[node.id] = chosen; used.formUnion(chosen)
        let releases: [ReleaseDTO] = await Task.detached(priority: .utility) { chosen.compactMap { store.release(id: $0) } }.value
        for r in releases { art.load(r) }
        picks[node.id] = releases
    }
}

// MARK: - The model behind the field

@MainActor
final class SearchModel: ObservableObject {
    @Published var scope = SearchScope.all
    @Published private(set) var recents = SearchRecents.load()
    @Published var dropdownOpen = false {
        didSet {
            guard dropdownOpen != oldValue else { return }
            if dropdownOpen, outsideMonitor == nil {
                // a click anywhere but the field and the list closes the list
                outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                    let loc = e.locationInWindow, height = e.window?.contentView?.bounds.height
                    MainActor.assumeIsolated {
                        guard let self, self.dropdownOpen, let height else { return }
                        let p = CGPoint(x: loc.x, y: height - loc.y)
                        if !self.fieldFrame.contains(p) && !self.dropFrame.contains(p) { self.dropdownOpen = false; self.highlight = -1; self.focused = false }
                    }
                    return e
                }
            } else if !dropdownOpen, let mon = outsideMonitor { NSEvent.removeMonitor(mon); outsideMonitor = nil }
        }
    }
    /// Where the field and the open list are in the window (set by the views), for the click-outside check.
    var fieldFrame = CGRect.zero, dropFrame = CGRect.zero
    private var outsideMonitor: Any?
    /// The highlighted row of the suggestions list, or -1 when none (Return then searches for the typed text).
    @Published var highlight = -1
    @Published var focused = false
    /// Pictures for the genre tiles, and a count of how often the empty Search page has been opened (a new count is a new pick).
    let genreArt = GenreArt()
    @Published var genreEpoch = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults; recents = SearchRecents.load(defaults) }

    func remember(_ q: String) { recents.add(q); recents.save(defaults) }
    func forget(_ q: String) { recents.remove(q); recents.save(defaults) }
    func clearRecents() { recents.clear(); recents.save(defaults) }
}

extension PlayerModel {
    /// The rows under the field for the text typed now.
    func searchSuggestions() -> [SearchSuggestion] {
        SearchRanking.suggestions(query: searchText, results: library.searchResults, playlists: collections.playlists,
                                  genres: SmartQueryModel.shared.tree.flatMap { [$0] + $0.children }.map(\.name), recents: search.recents.items)
    }

    /// Return in the field with nothing highlighted: keep the typed text, close the list and show the results page.
    func submitSearch() {
        let t = searchText.trimmingCharacters(in: .whitespaces)
        search.dropdownOpen = false; search.highlight = -1
        guard !t.isEmpty else { return }
        search.remember(t)
        if tab != .search { withAnimation(Motion.page) { go(.tab(.search)) } }
    }

    /// A click or Return on a row of the list.
    func activate(_ s: SearchSuggestion) {
        search.dropdownOpen = false; search.highlight = -1
        switch s.kind {
        case .completion: searchText = s.ref; submitSearch()
        case .genre: searchText = "tag:\"\(s.ref)\""; search.remember(s.ref); if tab != .search { go(.tab(.search)) }
        case .song:
            search.remember(searchText)
            if let t = library.searchResults?.tracks.first(where: { $0.path == s.ref }) { play(tracks: [t], at: 0) }
        case .album: search.remember(searchText); searchText = ""; tab = .albums; library.selectedID = s.ref
        case .artist: search.remember(searchText); searchText = ""; tab = .artists; library.selectedID = s.ref
        case .playlist: search.remember(searchText); searchText = ""; tab = .playlists; collections.open(s.ref)
        }
    }
}

// MARK: - The suggestions list under the field

struct SearchFieldAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// Placed over the whole window by the shell: the list sits right under the field it belongs to.
struct SearchDropdownHost: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject var s: SearchModel
    let anchor: Anchor<CGRect>?
    var body: some View {
        GeometryReader { g in
            if let anchor, s.dropdownOpen, !m.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                let r = g[anchor]
                let _ = { s.fieldFrame = r }()
                SearchDropdown(lib: m.library, s: s)
                    .background(GeometryReader { d in Color.clear.onAppear { s.dropFrame = d.frame(in: .global) }.onChange(of: d.frame(in: .global)) { s.dropFrame = $0 } })
                    .frame(width: max(360, r.width))
                    .offset(x: r.minX, y: r.maxY + 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(Motion.touch, value: s.dropdownOpen)
    }
}

struct SearchDropdown: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject var lib: LibraryModel
    @ObservedObject var s: SearchModel

    var body: some View {
        let rows = m.searchSuggestions()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                keycap("↑"); keycap("↓"); Text("Navigate").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary)
                Spacer()
                keycap("⏎"); Text("Search").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Rule(strength: 0.5)
            if rows.isEmpty {
                Text(lib.searchResults == nil ? "Searching…" : "No matches yet. Press Return to search for “\(m.searchText)”.")
                    .font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            SearchSuggestionRow(row: row, highlighted: s.highlight == i) { m.activate(row) }
                        }
                    }.padding(.vertical, 4)
                }
                .frame(maxHeight: 440)
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous).fill(Brand.panel))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous).strokeBorder(Brand.ink.opacity(0.10), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
    }

    private func keycap(_ t: String) -> some View {
        Text(t).font(Typo.mono(10.5, .medium)).foregroundStyle(Brand.inkSecondary).frame(width: 22, height: 20)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Brand.ink.opacity(0.22), lineWidth: 0.8))
    }
}

/// The small picture of an entity row, cached and loaded off the main thread.
struct SearchArt: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    @EnvironmentObject var artists: ArtistArt
    let kind: SearchSuggestion.Kind
    /// Release id for songs and albums, party id for artists.
    let id: String
    let name: String
    var size: CGFloat = 40

    var body: some View {
        let image: NSImage? = kind == .artist ? artists.info[id]?.image : art.info[id]?.image
        Group {
            switch kind {
            case .artist:
                CoverView(image: image, palette: ArtPalette.fallback(seed: name), corner: size / 2, symbol: "person.fill").clipShape(Circle())
            case .playlist:
                ZStack { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Brand.accent.opacity(0.25)); Image(systemName: "music.note.list").font(Typo.sans(size * 0.4)) }
            case .genre:
                ZStack { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SearchTile.color(for: name)); Image(systemName: "tag.fill").font(Typo.sans(size * 0.38)).foregroundStyle(.white.opacity(0.9)) }
            default:
                CoverView(image: image, palette: ArtPalette.fallback(seed: name), corner: 6, symbol: "music.note")
            }
        }
        .frame(width: size, height: size)
        .task(id: id) {
            guard let store = m.library.store else { return }
            if kind == .artist { artists.load(id: id, name: name) }
            else if (kind == .song || kind == .album), art.info[id] == nil {
                let rel = await Task.detached(priority: .userInitiated) { store.release(id: id) }.value
                if let rel { art.load(rel) }
            }
        }
    }
}

struct SearchSuggestionRow: View {
    @EnvironmentObject var m: PlayerModel
    let row: SearchSuggestion
    let highlighted: Bool
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if row.kind == .completion {
                    Image(systemName: row.subtitle == "Recent" ? "clock" : "magnifyingglass").font(Typo.sans(14)).foregroundStyle(Brand.inkSecondary).frame(width: 40, height: 28)
                    Text(row.title).font(Typo.sans(14.5)).lineLimit(1)
                } else {
                    SearchArt(kind: row.kind, id: releaseID, name: row.title)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(Typo.sans(14.5, .medium)).lineLimit(1)
                        Text(row.subtitle).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: row.kind == .completion ? 40 : 54)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink.opacity(highlighted ? 0.12 : hover.v ? 0.07 : 0)).padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .accessibilityLabel(row.kind == .completion ? "Search for \(row.title)" : "\(row.title), \(row.subtitle)")
    }

    /// Songs carry their release for the picture; the other kinds use their own id.
    private var releaseID: String {
        if row.kind == .song { return m.library.searchResults?.tracks.first(where: { $0.path == row.ref })?.releaseID ?? row.id }
        return row.ref
    }
}

// MARK: - The results page

struct SearchTile {
    /// A steady colour for a genre name, so a tile keeps its colour from one launch to the next.
    static let palette: [Color] = [
        Color(red: 0.86, green: 0.25, blue: 0.35), Color(red: 0.90, green: 0.45, blue: 0.20), Color(red: 0.80, green: 0.62, blue: 0.12), Color(red: 0.25, green: 0.62, blue: 0.42),
        Color(red: 0.12, green: 0.55, blue: 0.62), Color(red: 0.22, green: 0.45, blue: 0.80), Color(red: 0.40, green: 0.35, blue: 0.82), Color(red: 0.62, green: 0.30, blue: 0.75),
        Color(red: 0.80, green: 0.30, blue: 0.60), Color(red: 0.45, green: 0.50, blue: 0.58), Color(red: 0.55, green: 0.38, blue: 0.28), Color(red: 0.32, green: 0.56, blue: 0.20)]

    static func color(for name: String) -> Color {
        var h: UInt64 = 1469598103934665603
        for b in LibraryStore.fold(name).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return palette[Int(h % UInt64(palette.count))]
    }
}

struct SearchResultsPage: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject var s: SearchModel
    @ObservedObject var lib: LibraryModel
    @ObservedObject private var q = SmartQueryModel.shared

    var body: some View {
        PageScaffold(title: "", trailing: { EmptyView() }) {
            VStack(alignment: .leading, spacing: 22) {
                chips
                content
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases) { sc in
                    Button { withAnimation(Motion.touch) { s.scope = sc } } label: {
                        Text(sc.title).font(Typo.sans(13.5, .medium)).padding(.horizontal, 14).frame(height: 32)
                            .background(Capsule().fill(s.scope == sc ? AnyShapeStyle(Brand.ink) : AnyShapeStyle(Brand.panel2)))
                            .foregroundStyle(s.scope == sc ? Brand.canvas : Brand.ink)
                    }.buttonStyle(.plain).accessibilityAddTraits(s.scope == sc ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        let query = m.searchText.trimmingCharacters(in: .whitespaces)
        let genres = SearchGenres.matching(query, in: q.tree)
        let lists = m.collections.playlists.filter { SearchRanking.score($0.name, query: query) > 0 }
        if let all = lib.searchResults {
            let r = SearchRanking.filtered(all, scope: s.scope)
            switch s.scope {
            case .all: allView(all, query: query, playlists: lists, genres: genres)
            case .songs: if r.tracks.isEmpty { none(query) } else { SearchSongRows(tracks: r.tracks) }
            case .albums: if r.releases.isEmpty { none(query) } else { AlbumGrid(albums: r.releases, open: openAlbum, minimum: 150) }
            case .artists: if r.parties.isEmpty { none(query) } else { artistGrid(r.parties) }
            case .playlists: if lists.isEmpty { none(query) } else { playlistRows(lists) }
            case .genres: if genres.isEmpty { none(query) } else { genreGrid(genres) }
            case .podcasts: podcasts(query)
            }
        } else { ProgressView().padding(.top, 32) }
    }

    private func none(_ query: String) -> some View {
        VStack(spacing: 6) {
            Text("No results for “\(query)”").font(Typo.sans(18, .semibold))
            Text("Check the spelling, or try fewer words. Songs, albums, artists, playlists and genres in your library are searched.").font(Typo.sans(13.5)).foregroundStyle(Brand.inkSecondary)
        }.frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func allView(_ r: SearchResults, query: String, playlists: [PlaylistDTO], genres: [TagTreeNode]) -> some View {
        let empty = r.tracks.isEmpty && r.releases.isEmpty && r.parties.isEmpty && playlists.isEmpty && genres.isEmpty
        return Group {
            if empty { none(query) } else {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(alignment: .top, spacing: 24) {
                        if let top = SearchRanking.topResult(query: query, results: r) {
                            VStack(alignment: .leading, spacing: 10) { heading("Top result"); TopResultCard(top: top, results: r) }.frame(width: 380)
                        }
                        if !r.tracks.isEmpty {
                            VStack(alignment: .leading, spacing: 6) { heading("Songs"); SearchSongRows(tracks: Array(r.tracks.prefix(4)), queueSource: r.tracks) }.frame(maxWidth: .infinity)
                        }
                    }
                    if !r.parties.isEmpty { shelf("Artists") { ForEach(r.parties.prefix(14)) { p in ArtistTile(party: p) } } }
                    if !r.releases.isEmpty { shelf("Albums") { ForEach(r.releases.prefix(14)) { a in AlbumCard(album: a) { openAlbum(a) }.frame(width: 160) } } }
                    if !playlists.isEmpty { VStack(alignment: .leading, spacing: 8) { heading("Playlists"); playlistRows(Array(playlists.prefix(4))) } }
                    if !genres.isEmpty { VStack(alignment: .leading, spacing: 8) { heading("Genres"); genreGrid(Array(genres.prefix(6))) } }
                }
            }
        }
    }

    private func heading(_ t: String) -> some View { Text(t).font(Typo.sans(20, .semibold)).tracking(-0.2) }

    private func shelf<C: View>(_ title: String, @ViewBuilder _ items: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(title)
            ScrollView(.horizontal, showsIndicators: false) { LazyHStack(alignment: .top, spacing: 16) { items() }.padding(.bottom, 4) }
        }
    }

    private func openAlbum(_ a: ReleaseDTO) { m.searchText = ""; m.tab = .albums; m.library.selectedID = a.id }

    private func artistGrid(_ parties: [PartyDTO]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16, alignment: .top)], alignment: .leading, spacing: 22) { ForEach(parties) { ArtistTile(party: $0) } }
    }

    private func playlistRows(_ lists: [PlaylistDTO]) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(lists) { p in
                Button { m.searchText = ""; m.tab = .playlists; m.collections.open(p.id) } label: {
                    HStack(spacing: 12) {
                        SearchArt(kind: .playlist, id: p.id, name: p.name, size: 44)
                        VStack(alignment: .leading, spacing: 2) { Text(p.name).font(Typo.sans(14.5, .medium)); Text("Playlist · \(p.trackCount) songs").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary) }
                        Spacer()
                    }.padding(.horizontal, 8).frame(height: 56).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func genreGrid(_ genres: [TagTreeNode]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 14)], spacing: 14) {
            ForEach(genres) { g in GenreTile(node: g, genreArt: s.genreArt, epoch: s.genreEpoch) { m.searchText = g.query; m.search.remember(g.name) } }
        }
    }

    private func podcasts(_ query: String) -> some View {
        VStack(spacing: 10) {
            Text("Podcast shows are found on the Podcasts page").font(Typo.sans(16, .semibold))
            Button("Search Podcasts for “\(query)”") { m.go(.tab(.podcasts)) }.buttonStyle(.rule)
        }.frame(maxWidth: .infinity).padding(.top, 60)
    }
}

enum SearchGenres {
    /// The genres (every level of the tag tree) whose name matches the query.
    static func matching(_ query: String, in tree: [TagTreeNode]) -> [TagTreeNode] {
        func walk(_ nodes: [TagTreeNode]) -> [TagTreeNode] { nodes.flatMap { [$0] + walk($0.children) } }
        return walk(tree).filter { SearchRanking.score($0.name, query: query) > 0 }.sorted { SearchRanking.score($0.name, query: query) > SearchRanking.score($1.name, query: query) }
    }
}

struct TopResultCard: View {
    @EnvironmentObject var m: PlayerModel
    let top: SearchTop
    let results: SearchResults
    @StateObject private var hover = Box(false)

    var body: some View {
        let (kind, id, title, sub): (SearchSuggestion.Kind, String, String, String) = {
            switch top {
            case .artist(let p): return (.artist, p.id, p.name, p.kind == "group" ? "Ensemble" : "Artist")
            case .album(let a): return (.album, a.id, a.title, "Album · " + (a.artistNames.first ?? ""))
            case .track(let t): return (.song, t.releaseID ?? t.id, t.title, "Song · " + t.artistLine)
            }
        }()
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                SearchArt(kind: kind, id: id, name: title, size: 96)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Typo.sans(28, .bold)).tracking(-0.4).lineLimit(2)
                    Text(sub).font(Typo.sans(13.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.10 : 0.06)))
            .overlay(alignment: .bottomTrailing) {
                Button(action: play) { Image(systemName: "play.fill").font(Typo.sans(18)).foregroundStyle(Brand.onAccent).frame(width: 52, height: 52).background(Circle().fill(Brand.accent)) }
                    .buttonStyle(.plain).padding(16).opacity(hover.v ? 1 : 0.0001).offset(y: hover.v ? 0 : 6).accessibilityLabel("Play \(title)")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { h in withAnimation(Motion.touch) { hover.v = h } }
    }

    private func open() {
        switch top {
        case .artist(let p): m.searchText = ""; m.tab = .artists; m.library.selectedID = p.id
        case .album(let a): m.searchText = ""; m.tab = .albums; m.library.selectedID = a.id
        case .track(let t): if let i = results.tracks.firstIndex(of: t) { m.play(tracks: results.tracks, at: i) }
        }
    }

    private func play() {
        switch top {
        case .track(let t): if let i = results.tracks.firstIndex(of: t) { m.play(tracks: results.tracks, at: i) }
        case .album(let a): if let store = m.library.store { Task.detached { let t = store.tracks(releaseID: a.id); await MainActor.run { m.play(tracks: t, at: 0) } } }
        case .artist(let p): let t = results.tracks.filter { $0.artistLine.localizedCaseInsensitiveContains(p.name) }; if !t.isEmpty { m.play(tracks: t, at: 0) } else { open() }
        }
    }
}

struct ArtistTile: View {
    @EnvironmentObject var m: PlayerModel
    let party: PartyDTO
    var body: some View {
        Button { m.searchText = ""; m.tab = .artists; m.library.selectedID = party.id } label: {
            VStack(spacing: 8) {
                SearchArt(kind: .artist, id: party.id, name: party.name, size: 140)
                Text(party.name).font(Typo.sans(14, .medium)).lineLimit(1)
                Text(party.kind == "group" ? "Ensemble" : "Artist").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
            }.frame(width: 150)
        }.buttonStyle(.plain)
    }
}

struct GenreTile: View {
    let node: TagTreeNode
    @ObservedObject var genreArt: GenreArt
    let epoch: Int
    let action: () -> Void
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false
    @State private var pointer = CGSize.zero
    @FocusState private var focused: Bool

    var body: some View {
        let picks = genreArt.picks[node.id] ?? []
        let images = picks.compactMap { art.info[$0.id]?.image }
        let base = SearchTile.color(for: node.name)
        let lit = hover || focused
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                // the picture fills the tile; it zooms and drifts a little with the pointer
                LinearGradient(colors: [base, base.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let first = images.first {
                    Image(nsImage: first).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        .scaleEffect(lit && !reduceMotion ? 1.12 : 1.02)
                        .offset(x: lit && !reduceMotion ? -pointer.width * 7 : 0, y: lit && !reduceMotion ? -pointer.height * 5 : 0)
                        .transition(.opacity)
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.0), location: 0), .init(color: .black.opacity(0.35), location: 0.45), .init(color: .black.opacity(0.82), location: 1)], startPoint: .top, endPoint: .bottom)
                if images.count >= 3 { stack(Array(images.dropFirst().prefix(2))) }
            }
            .frame(maxWidth: .infinity).frame(height: 112).clipped()
            // the name and count sit over the picture inside the tile, never pushed past its edge
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(Typo.sans(17, .bold)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8).shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    Text("\(node.count) song\(node.count == 1 ? "" : "s")").font(Typo.sans(12, .medium)).foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 14).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.accent.opacity(lit ? 0.95 : 0), lineWidth: focused ? 2.5 : 1.8))
            .shadow(color: lit ? Brand.accent.opacity(0.35) : .black.opacity(0.18), radius: lit ? 16 : 5, y: lit ? 8 : 2)
            .scaleEffect(lit && !reduceMotion ? 1.04 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(GenreTilePress())
        .focused($focused).focusEffectDisabledCompat()
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = true; pointer = CGSize(width: max(-1, min(1, (p.x - 100) / 100)), height: max(-1, min(1, (p.y - 56) / 56)))
            case .ended: hover = false; pointer = .zero
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.18), value: lit)
        .animation(.easeOut(duration: 0.12), value: pointer)
        .animation(.easeInOut(duration: 0.35), value: images.count)
        .task(id: epoch) { await genreArt.refresh(node, store: m.library.store, art: art, epoch: epoch) }
        .accessibilityLabel("\(node.name), \(node.count) songs")
    }

    /// Two more covers, overlapping and turned, in the corner; they fan out a little under the pointer.
    private func stack(_ covers: [NSImage]) -> some View {
        let lit = hover || focused
        return ZStack {
            ForEach(Array(covers.enumerated()), id: \.offset) { i, img in
                Image(nsImage: img).resizable().scaledToFill().frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .rotationEffect(.degrees((i == 0 ? -9 : 8) * (lit && !reduceMotion ? 1.9 : 1)))
                    .offset(x: CGFloat(i) * (lit && !reduceMotion ? 24 : 15), y: CGFloat(i) * 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 12).padding(.trailing, 44)
    }
}

/// The press: a little smaller while the button is down.
private struct GenreTilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Song rows in the Spotify manner: picture, title and artist, the quality tag, the time, and on hover a play button over the picture, add to queue and the heart.
struct SearchSongRows: View {
    @EnvironmentObject var m: PlayerModel
    let tracks: [TrackDTO]
    /// The list the rows play from (the whole result when only the first few are shown).
    var queueSource: [TrackDTO]? = nil
    var body: some View {
        LazyVStack(spacing: 2) {
            ForEach(tracks) { t in SearchSongRow(track: t, source: queueSource ?? tracks).contextMenu { TrackMenu(tracks: [t], playlistID: nil) } }
        }
    }
}

struct SearchSongRow: View {
    @EnvironmentObject var m: PlayerModel
    let track: TrackDTO
    let source: [TrackDTO]
    @StateObject private var hover = Box(false)

    var body: some View {
        let playing = m.isActive && m.current?.path == track.path
        HStack(spacing: 12) {
            ZStack {
                SearchArt(kind: .song, id: track.releaseID ?? track.id, name: track.title, size: 44)
                if hover.v { Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)); Image(systemName: "play.fill").font(Typo.sans(15)).foregroundStyle(.white) }
                else if playing { Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)); EqualizerBars(active: m.status.state == .playing, color: Brand.accent).frame(width: 14, height: 12) }
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(Typo.sans(14.5, .medium)).foregroundStyle(playing ? Brand.accentText : Brand.ink).lineLimit(1)
                Text(track.artistLine).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if QualityMark.make(track: track) != nil { TinyQualityMark(track: track) }
            HStack(spacing: 6) {
                Button { m.library.onAdd?([track], false) } label: { Image(systemName: "text.badge.plus").font(Typo.sans(13)) }.buttonStyle(.plain).help("Add to queue").accessibilityLabel("Add to queue")
                HeartButton(path: track.path, size: 13, alwaysVisible: false)
            }.opacity(hover.v ? 1 : 0.0001)
            Text(fmtDuration(track.duration)).font(Typo.sans(13, .medium)).monospacedDigit().foregroundStyle(Brand.inkSecondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 8).frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover.v = h } }
        .onTapGesture { if let i = source.firstIndex(of: track) { m.play(tracks: source, at: i) } }
    }
}

// MARK: - Nothing typed yet

struct SearchEmptyState: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject var s: SearchModel
    @ObservedObject var lib: LibraryModel
    @ObservedObject private var q = SmartQueryModel.shared

    var body: some View {
        PageScaffold(title: "", trailing: { EmptyView() }) {
            VStack(alignment: .leading, spacing: 30) {
                if !s.recents.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Recent searches").font(Typo.sans(20, .semibold)); Spacer(); Button("Clear all") { withAnimation(Motion.touch) { s.clearRecents() } }.buttonStyle(.plain).font(Typo.sans(13, .medium)).foregroundStyle(Brand.inkSecondary) }
                        LazyVStack(spacing: 2) {
                            ForEach(s.recents.items, id: \.self) { r in
                                HStack(spacing: 12) {
                                    Button { m.searchText = r } label: {
                                        HStack(spacing: 12) { Image(systemName: "clock").foregroundStyle(Brand.inkSecondary).frame(width: 24); Text(r).font(Typo.sans(14.5)).lineLimit(1); Spacer() }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Button { withAnimation(Motion.touch) { s.forget(r) } } label: { Image(systemName: "xmark").font(Typo.sans(11, .semibold)).foregroundStyle(Brand.inkSecondary).frame(width: 28, height: 28) }
                                        .buttonStyle(.plain).help("Remove from recent searches").accessibilityLabel("Remove \(r)")
                                }.padding(.horizontal, 8).frame(height: 40)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Browse genres").font(Typo.sans(20, .semibold))
                    if q.tree.isEmpty {
                        Text(q.treeLoading ? "Loading…" : "Add a music folder and its genres show up here.").font(Typo.sans(13.5)).foregroundStyle(Brand.inkSecondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 14)], spacing: 14) {
                            ForEach(q.tree) { g in GenreTile(node: g, genreArt: s.genreArt, epoch: s.genreEpoch) { m.searchText = g.query; s.remember(g.name) } }
                        }
                    }
                }
            }
        }
        .onAppear { q.loadTree(store: m.library.store); s.genreEpoch += 1 }
        .onChangeCompat(of: lib.stats.revision) { q.loadTree(store: m.library.store) }
    }
}

// MARK: - Search tips

/// The query language, one click away from the field and nowhere else.
struct SearchTips: View {
    @EnvironmentObject var m: PlayerModel
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search tips").font(Typo.sans(16, .semibold))
            Text("Type a few words to find songs, albums and artists. To be exact, use fields and operators; click an example to try it.").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
            ScrollView(showsIndicators: false) { QueryHelp(insert: { m.searchText = $0; close() }) }.frame(maxHeight: 360)
        }
        .padding(16).frame(width: 560)
    }
}

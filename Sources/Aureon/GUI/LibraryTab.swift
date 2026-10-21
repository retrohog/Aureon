import SwiftUI
import AppKit

func fmtDuration(_ s: Double) -> String { let t = Int(s.rounded()); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60) }

func trackQuality(_ t: TrackDTO) -> String {
    t.bitDepth == 1 ? "DSD" : "\(t.codec) \(t.bitDepth)/\(formatRate(t.sampleRate).replacingOccurrences(of: " kHz", with: ""))"
}
func isHiRes(_ t: TrackDTO) -> Bool { t.bitDepth == 1 || t.sampleRate > 48_000 || t.bitDepth > 16 }

// MARK: - Page scaffold

/// Large title, optional back link and trailing controls above scrolling content, with room for the floating player bar.
struct PageScaffold<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var back: (() -> Void)? = nil
    var backTitle = "Back"
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let back {
                    Button(action: back) { Label(backTitle, systemImage: "chevron.left").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Brand.accent)
                }
                if !title.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(title).font(.system(size: 32, weight: .bold)).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
                        Spacer(minLength: 12)
                        trailing
                    }
                }
                content
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, back: (() -> Void)? = nil, backTitle: String = "Back", @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, back: back, backTitle: backTitle, trailing: { EmptyView() }, content: content)
    }
}

struct PillButton: View {
    let title: String
    var symbol: String?
    var filled = false
    let action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .background(Capsule().fill(filled ? Brand.accent.opacity(hover.v ? 0.88 : 1) : Color.white.opacity(hover.v ? 0.16 : 0.1)))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(.smooth(duration: 0.12), value: hover.v)
    }
}

// MARK: - Library pages

/// Albums as a cover grid, artists/composers/works/… as lists, songs as a table. One page type; the sidebar picks the category.
struct LibraryPage: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject var lib: LibraryModel
    let tab: Tab

    var body: some View {
        if lib.stats.tracks == 0 && !lib.importing { empty }
        else if lib.selectedID != nil, tab != .songs { detailPage }
        else { listPage }
    }

    // MARK: toolbar / empty

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter", text: $lib.search).textFieldStyle(.plain).font(.system(size: 13)).frame(width: 130)
            }
            .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.08)))
            Button { chooseFolder() } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(IconButtonStyle()).help("Add music folder…")
            Button { lib.rescan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(IconButtonStyle()).disabled(lib.folders.isEmpty || lib.importing).help("Rescan")
            if lib.importing { ProgressView().controlSize(.small) }
        }
    }

    private var subtitle: String {
        if lib.importing { return lib.importProgress }
        switch tab {
        case .albums: return "\(lib.albums.count) albums"
        case .songs: return "\(lib.songs.count) songs"
        default: return "\(lib.rows.count)"
        }
    }

    private var empty: some View {
        PageScaffold(title: tab.rawValue) {
            VStack(spacing: 14) {
                Image(systemName: "books.vertical").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(.secondary)
                Text("Your library is empty").font(.title3.weight(.semibold))
                Text("Add a folder of FLAC, ALAC, WAV or AIFF files. Aureon reads multiple artists per track and classical tags — composer, conductor, ensemble, soloists, work, movement and opus. Audio files are never modified.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
                PillButton(title: "Add Music Folder…", symbol: "folder.badge.plus", filled: true) { chooseFolder() }
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        }
    }

    // MARK: list level

    @ViewBuilder private var listPage: some View {
        PageScaffold(title: tab.rawValue, subtitle: subtitle, trailing: { toolbar }) {
            switch tab {
            case .albums: AlbumGrid(albums: lib.albums, open: { lib.selectedID = $0.id })
            case .songs: SongList(tracks: lib.songs)
            default: rowList
            }
        }
    }

    private var rowList: some View {
        LazyVStack(spacing: 2) {
            ForEach(lib.rows) { r in
                RowButton(title: r.title, subtitle: r.subtitle, count: r.count, symbol: tab.icon) { lib.selectedID = r.id }
            }
            if lib.rows.isEmpty { Text("Nothing here").foregroundStyle(.secondary).padding(.top, 30) }
        }
    }

    // MARK: detail level

    @ViewBuilder private var detailPage: some View {
        let back: () -> Void = { if lib.canGoBack { lib.goBack() } else { lib.selectedID = nil } }
        switch lib.detail {
        case .tracks(_, let tracks) where tab == .albums:
            if let album = lib.albums.first(where: { $0.id == lib.selectedID }) {
                AlbumDetail(album: album, tracks: tracks, back: back)
            } else { PageScaffold(title: tab.rawValue, back: back, backTitle: tab.rawValue) { SongList(tracks: tracks) } }
        case .tracks(let title, let tracks):
            let name = lib.rows.first { $0.id == lib.selectedID }?.title ?? title
            PageScaffold(title: name, subtitle: "\(tracks.count) songs", back: back, backTitle: tab.rawValue, trailing: { trackActions(tracks) }) { SongList(tracks: tracks) }
        case .works(let works):
            PageScaffold(title: lib.rows.first { $0.id == lib.selectedID }?.title ?? "Works", subtitle: "\(works.count) works", back: back, backTitle: tab.rawValue) { worksView(works) }
        case .recordings(let w, let groups):
            PageScaffold(title: w.title, subtitle: [w.composerName, w.catalog, w.key].compactMap { $0 }.joined(separator: " · "), back: back,
                         backTitle: lib.canGoBack ? "Works" : tab.rawValue) { recordingsView(groups) }
        default:
            PageScaffold(title: tab.rawValue, back: back, backTitle: tab.rawValue) { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
        }
    }

    private func trackActions(_ tracks: [TrackDTO]) -> some View {
        HStack(spacing: 8) {
            PillButton(title: "Play", symbol: "play.fill", filled: true) { lib.onReplace?(tracks) }
            PillButton(title: "Shuffle", symbol: "shuffle") { lib.onReplace?(tracks.shuffled()) }
            PillButton(title: "Add", symbol: "text.badge.plus") { lib.onAdd?(tracks, false) }
        }
    }

    private func worksView(_ works: [WorkDTO]) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(works) { w in
                RowButton(title: w.title, subtitle: [w.catalog, w.key, "\(w.recordingCount) recording" + (w.recordingCount == 1 ? "" : "s")].compactMap { $0 }.joined(separator: " · "),
                          count: w.trackCount, symbol: "book") { lib.open(work: w) }
            }
        }
    }

    private func recordingsView(_ groups: [RecordingGroupDTO]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.releaseTitle + (g.year.map { " (\($0))" } ?? "")).font(.system(size: 15, weight: .semibold))
                            performerLines(g)
                        }
                        Spacer()
                        PillButton(title: "Play", symbol: "play.fill", filled: true) { lib.onReplace?(g.tracks) }
                        PillButton(title: "Add", symbol: "text.badge.plus") { lib.onAdd?(g.tracks, false) }
                    }
                    ForEach(g.tracks) { t in
                        HStack(spacing: 8) {
                            Text(t.movementNumber.map { roman($0) } ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                            Text(t.movementTitle ?? t.title).lineLimit(1)
                            Spacer()
                            Text(fmtDuration(t.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3).contentShape(Rectangle()).onTapGesture(count: 2) { lib.onReplace?([t]) }
                    }
                }
                .padding(14).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
            }
        }
    }

    @ViewBuilder private func performerLines(_ g: RecordingGroupDTO) -> some View {
        let cond = g.performers.filter { $0.role == "conductor" }.map(\.name), ens = g.performers.filter { $0.role == "ensemble" }.map(\.name)
        let solo = g.performers.filter { $0.role == "soloist" || $0.role == "performer" }.map { c in c.instrument.map { i in "\(c.name) (\(i))" } ?? c.name }
        if !cond.isEmpty { Text("Conductor: " + cond.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
        if !ens.isEmpty { Text("Ensemble: " + ens.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
        if !solo.isEmpty { Text("Soloists: " + solo.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
    }

    private func roman(_ n: Int) -> String {
        let t = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var x = n, out = ""
        for (v, s) in t { while x >= v { out += s; x -= v } }
        return n > 0 && n < 40 ? out + "." : "\(n)"
    }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = "Choose the folder(s) that contain your music"
        if p.runModal() == .OK { p.urls.forEach { lib.addFolder($0) } }
    }
}

/// A list row with an avatar, title, subtitle and a count.
struct RowButton: View {
    let title: String
    let subtitle: String
    let count: Int
    let symbol: String
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [ArtPalette.fallback(seed: title).grid[0].color, ArtPalette.fallback(seed: title).grid[8].color], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(String(title.first.map { String($0) } ?? "·").uppercased()).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(.white.opacity(0.9))
                }.frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Text("\(count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover.v ? 0.07 : 0)))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(.smooth(duration: 0.12), value: hover.v)
    }
}

// MARK: - Albums

struct AlbumGrid: View {
    let albums: [ReleaseDTO]
    let open: (ReleaseDTO) -> Void
    var minimum: CGFloat = 170

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: 250), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
            ForEach(albums) { a in AlbumCard(album: a) { open(a) } }
        }
        .overlay { if albums.isEmpty { Text("No albums").foregroundStyle(.secondary).padding(.top, 60) } }
    }
}

struct AlbumCard: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    let album: ReleaseDTO
    let open: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let info = art.info[album.id]
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                CoverView(image: info?.image, palette: ArtPalette.fallback(seed: album.title), corner: 10, symbol: "music.note")
                    .shadow(color: .black.opacity(hover.v ? 0.5 : 0.3), radius: hover.v ? 16 : 8, y: hover.v ? 8 : 4)
                if hover.v {
                    Button { play() } label: { Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white).frame(width: 38, height: 38)
                        .background(Circle().fill(Brand.accent)) }
                        .buttonStyle(.plain).padding(10).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .scaleEffect(hover.v ? 1.02 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(([album.artistNames.first].compactMap { $0 } + [album.year.map(String.init)].compactMap { $0 }).joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if info?.hd == true { Text("HD").font(.system(size: 9, weight: .heavy)).tracking(0.5).padding(.horizontal, 4).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, lineWidth: 0.8)).foregroundStyle(.secondary) }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(.smooth(duration: 0.16)) { hover.v = h } }
        .onAppear { art.load(album) }
        .contextMenu {
            Button("Play") { play() }
            Button("Add to Queue") { if let s = m.library.store { m.library.onAdd?(s.tracks(releaseID: album.id), false) } }
        }
    }

    private func play() { if let s = m.library.store { m.library.onReplace?(s.tracks(releaseID: album.id)) } }
}

struct AlbumDetail: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    let album: ReleaseDTO
    let tracks: [TrackDTO]
    let back: () -> Void

    var body: some View {
        let info = art.info[album.id]
        PageScaffold(title: "", back: back, backTitle: "Albums") {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 28) {
                    CoverView(image: info?.image, palette: ArtPalette.fallback(seed: album.title), corner: 14).frame(width: 240, height: 240)
                        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title).font(.system(size: 30, weight: .bold)).lineLimit(3)
                        Text(album.artistNames.prefix(3).joined(separator: ", ")).font(.system(size: 20, weight: .medium)).foregroundStyle(Brand.accent).lineLimit(2)
                        Text(meta).font(.system(size: 12.5, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary).padding(.top, 2)
                        if let first = tracks.first, isHiRes(first) || tracks.contains(where: isHiRes) {
                            HWBadge(text: trackQuality(tracks.first { isHiRes($0) } ?? first).uppercased(), tone: .amber).padding(.top, 6)
                        }
                        HStack(spacing: 8) {
                            PillButton(title: "Play", symbol: "play.fill", filled: true) { m.library.onReplace?(tracks) }
                            PillButton(title: "Shuffle", symbol: "shuffle") { m.library.onReplace?(tracks.shuffled()) }
                            PillButton(title: "Add to Queue", symbol: "text.badge.plus") { m.library.onAdd?(tracks, false) }
                        }.padding(.top, 14)
                    }
                    Spacer(minLength: 0)
                }
                SongList(tracks: tracks, showArtist: Set(tracks.map(\.artistLine)).count > 1, numbered: true)
            }
        }
    }

    private var meta: String {
        let genres = tracks.first?.genres.first
        let total = tracks.reduce(0) { $0 + $1.duration }
        let length = total < 60 ? "\(Int(total.rounded())) seconds" : "\(Int((total / 60).rounded())) minutes"
        return [genres, album.year.map(String.init), "\(tracks.count) song\(tracks.count == 1 ? "" : "s"), \(length)"].compactMap { $0 }.joined(separator: " · ").uppercased()
    }
}

// MARK: - Songs

struct SongList: View {
    @EnvironmentObject var m: PlayerModel
    let tracks: [TrackDTO]
    var showArtist = true
    var numbered = false

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                SongRow(track: t, index: i + 1, showArtist: showArtist, numbered: numbered,
                        playing: m.isActive && m.current?.url.path == t.path)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { m.library.onReplace?(Array(tracks[i...])) }
                    .contextMenu {
                        Button("Play") { m.library.onReplace?(Array(tracks[i...])) }
                        Button("Add to Queue") { m.library.onAdd?([t], false) }
                    }
            }
            if tracks.isEmpty { Text("No songs").foregroundStyle(.secondary).padding(.top, 40) }
        }
    }
}

struct SongRow: View {
    let track: TrackDTO
    let index: Int
    let showArtist: Bool
    let numbered: Bool
    let playing: Bool
    @EnvironmentObject var m: PlayerModel
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if hover.v { Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(.primary) }
                else if playing { EqualizerBars(active: m.status.state == .playing, color: Brand.accent).frame(width: 14, height: 12) }
                else { Text(numbered ? "\(track.trackNumber ?? index)" : "").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary) }
            }.frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 13.5, weight: playing ? .semibold : .regular)).foregroundStyle(playing ? Brand.accent : .primary).lineLimit(1)
                if showArtist {
                    Text([track.artistLine, numbered ? nil : track.releaseTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isHiRes(track) { Text("HD").font(.system(size: 9, weight: .heavy)).tracking(0.5).padding(.horizontal, 4).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, lineWidth: 0.8)).foregroundStyle(.secondary) }
            Text(trackQuality(track)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            Text(fmtDuration(track.duration)).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover.v ? 0.08 : (index % 2 == 0 ? 0.025 : 0))))
        .onHover { hover.v = $0 }
    }
}

// MARK: - Search

struct SearchPage: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        let r = m.library.searchResults
        PageScaffold(title: "Search", subtitle: m.searchText.isEmpty ? nil : "“\(m.searchText)”") {
            if m.searchText.isEmpty {
                Text("Search your library for songs, albums, artists, composers and works.").foregroundStyle(.secondary).padding(.top, 20)
            } else if let r, r.tracks.isEmpty && r.releases.isEmpty && r.works.isEmpty && r.parties.isEmpty {
                Text("No results").foregroundStyle(.secondary).padding(.top, 20)
            } else if let r {
                VStack(alignment: .leading, spacing: 26) {
                    if !r.releases.isEmpty { section("Albums") { AlbumGrid(albums: r.releases, open: { a in m.tab = .albums; m.library.selectedID = a.id }, minimum: 150) } }
                    if !r.tracks.isEmpty { section("Songs") { SongList(tracks: r.tracks) } }
                    if !r.parties.isEmpty {
                        section("Artists & composers") {
                            LazyVStack(spacing: 2) { ForEach(r.parties) { p in RowButton(title: p.name, subtitle: p.kind == "group" ? "Ensemble" : "", count: p.count, symbol: "person") { m.searchText = ""; m.tab = .artists; m.library.selectedID = p.id } } }
                        }
                    }
                    if !r.works.isEmpty {
                        section("Works") { LazyVStack(spacing: 2) { ForEach(r.works) { w in RowButton(title: w.title, subtitle: [w.composerName, w.catalog].compactMap { $0 }.joined(separator: " · "), count: w.trackCount, symbol: "book") { m.searchText = ""; m.tab = .works; m.library.selectedID = w.id } } } }
                    }
                }
            } else { ProgressView().padding(.top, 30) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.system(size: 20, weight: .bold)); content() }
    }
}

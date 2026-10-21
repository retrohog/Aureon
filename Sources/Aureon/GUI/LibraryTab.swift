import SwiftUI
import AppKit

func fmtDuration(_ s: Double) -> String { let t = Int(s.rounded()); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60) }

func trackQuality(_ t: TrackDTO) -> String {
    t.bitDepth == 1 ? "DSD" : "\(t.codec) \(t.bitDepth)/\(formatRate(t.sampleRate).replacingOccurrences(of: " kHz", with: ""))"
}
func isHiRes(_ t: TrackDTO) -> Bool { t.bitDepth == 1 || t.sampleRate > 48_000 || t.bitDepth > 16 }

// MARK: - Page scaffold

/// A page: a toolbar band (back/forward live at its left, page controls at its right), a large title, then scrolling content with room for the player bar.
struct PageScaffold<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var back: (() -> Void)? = nil
    var backTitle = "Back"
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) { Spacer(minLength: 0); trailing }.frame(minHeight: 30).padding(.leading, 76).padding(.trailing, 92)
                if let back {
                    Button(action: back) { Label(backTitle, systemImage: "chevron.left").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Brand.cyan)
                }
                if !title.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.4).lineLimit(1)
                        if let subtitle { Text(subtitle).microLabel().foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                }
                content
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 110)
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
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .background(Capsule().fill(filled ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.white.opacity(hover.v ? 0.16 : 0.09))))
            .overlay(Capsule().strokeBorder(.white.opacity(filled ? 0 : 0.1), lineWidth: 0.8))
            .brightness(filled && hover.v ? 0.06 : 0)
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(.easeOut(duration: 0.12), value: hover.v)
    }
}

/// A compact toolbar control: icon + label, opens a menu.
struct ToolbarMenu<Content: View>: View {
    let label: String
    let icon: String
    var active = false
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: {
            HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 11, weight: .medium)); Text(label).font(.system(size: 12, weight: .medium)) }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(active ? AnyShapeStyle(Brand.accent.opacity(0.25)) : AnyShapeStyle(Color.white.opacity(0.07))))
                .foregroundStyle(active ? Brand.accent : Color.primary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

struct SearchPill: View {
    let prompt: String
    @Binding var text: String
    var width: CGFloat = 150
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12)).frame(width: width)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.07)))
    }
}

// MARK: - Library pages

/// Albums as a cover grid, artists as portraits, songs as a table, classical categories as lists. One page type; the sidebar picks the category.
struct LibraryPage: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject var lib: LibraryModel
    let tab: Tab

    private var opts: ViewOptions { m.options(for: tab) }
    private func update(_ f: (inout ViewOptions) -> Void) { var o = opts; f(&o); m.setOptions(o, for: tab) }

    var body: some View {
        if lib.stats.tracks == 0 && !lib.importing { empty }
        else if lib.selectedID != nil, tab != .songs { detailPage }
        else { listPage }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 7) {
            SearchPill(prompt: "Filter", text: $lib.search, width: 110)
            let sorts = ViewOptions.available(for: tab)
            ToolbarMenu(label: opts.sort.label, icon: opts.ascending ? "arrow.up" : "arrow.down") {
                Picker("Sort by", selection: Binding(get: { opts.sort }, set: { v in update { $0.sort = v } })) { ForEach(sorts) { Text($0.label).tag($0) } }.pickerStyle(.inline)
                Divider()
                Toggle("Ascending", isOn: Binding(get: { opts.ascending }, set: { v in update { $0.ascending = v } }))
                if tab != .albums { Toggle("Group under A–Z", isOn: Binding(get: { opts.letters }, set: { v in update { $0.letters = v } })) }
            }
            if tab == .albums || tab == .songs {
                ToolbarMenu(label: opts.quality.short, icon: "line.3.horizontal.decrease", active: opts.quality != .all) {
                    Picker("Quality", selection: Binding(get: { opts.quality }, set: { v in update { $0.quality = v } })) { ForEach(QualityFilter.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline)
                }
            }
            if tab == .albums || tab == .artists {
                HStack(spacing: 0) {
                    Button { update { $0.list = false } } label: { Image(systemName: "square.grid.2x2") }.foregroundStyle(opts.list ? Color.secondary : Brand.cyan)
                    Button { update { $0.list = true } } label: { Image(systemName: "list.bullet") }.foregroundStyle(opts.list ? Brand.cyan : Color.secondary)
                }.buttonStyle(IconButtonStyle()).padding(2).background(Capsule().fill(.white.opacity(0.08)))
                if !opts.list {
                    Slider(value: Binding(get: { opts.size }, set: { v in update { $0.size = v } }), in: 0...1).controlSize(.mini).frame(width: 70).help("Cover size")
                }
            }
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
                Image(systemName: "books.vertical").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.secondary)
                Text("Your library is empty").font(.title3.weight(.semibold))
                Text("Add a folder of FLAC, ALAC, WAV or AIFF files. Aureon reads multiple artists per track and classical tags — composer, conductor, ensemble, soloists, work, movement and opus. Audio files are never modified.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420).font(.callout)
                PillButton(title: "Add Music Folder…", symbol: "folder.badge.plus", filled: true) { chooseFolder() }
            }
            .frame(maxWidth: .infinity).padding(.top, 70)
        }
    }

    // MARK: list level

    @ViewBuilder private var listPage: some View {
        PageScaffold(title: tab.rawValue, subtitle: subtitle, trailing: { toolbar }) {
            switch tab {
            case .albums:
                let albums = LibraryOrdering.albums(lib.albums, opts)
                if opts.list { AlbumList(albums: albums, open: { lib.selectedID = $0.id }) }
                else { AlbumGrid(albums: albums, open: { lib.selectedID = $0.id }, minimum: 100 + CGFloat(opts.size) * 100) }
            case .songs: SongList(tracks: LibraryOrdering.songs(lib.songs, opts), numbered: false, letters: opts.letters && opts.sort == .title, sortHeader: true)
            case .artists: ArtistsView(rows: LibraryOrdering.rows(lib.rows, opts), opts: opts, open: { lib.selectedID = $0 })
            default: rowList
            }
        }
    }

    private var rowList: some View {
        let rows = LibraryOrdering.rows(lib.rows, opts)
        return LazyVStack(spacing: 1) {
            if opts.letters && opts.sort == .title {
                ForEach(LibraryOrdering.grouped(rows, title: \.title), id: \.letter) { g in
                    LetterHeader(letter: g.letter)
                    ForEach(g.items) { r in RowButton(title: r.title, subtitle: r.subtitle, count: r.count, symbol: tab.icon) { lib.selectedID = r.id } }
                }
            } else {
                ForEach(rows) { r in RowButton(title: r.title, subtitle: r.subtitle, count: r.count, symbol: tab.icon) { lib.selectedID = r.id } }
            }
            if rows.isEmpty { Text("Nothing here").foregroundStyle(.secondary).padding(.top, 30) }
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
        case .tracks(_, let tracks) where tab == .artists:
            let row = lib.rows.first { $0.id == lib.selectedID }
            ArtistDetail(id: lib.selectedID ?? "", name: row?.title ?? "Artist", tracks: tracks, albums: lib.artistAlbums, back: back)
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
        HStack(spacing: 6) {
            PillButton(title: "Play", symbol: "play.fill", filled: true) { lib.onReplace?(tracks) }
            PillButton(title: "Shuffle", symbol: "shuffle") { lib.onReplace?(tracks.shuffled()) }
            PillButton(title: "Add", symbol: "text.badge.plus") { lib.onAdd?(tracks, false) }
        }
    }

    private func worksView(_ works: [WorkDTO]) -> some View {
        LazyVStack(spacing: 1) {
            ForEach(works) { w in
                RowButton(title: w.title, subtitle: [w.catalog, w.key, "\(w.recordingCount) recording" + (w.recordingCount == 1 ? "" : "s")].compactMap { $0 }.joined(separator: " · "),
                          count: w.trackCount, symbol: "book") { lib.open(work: w) }
            }
        }
    }

    private func recordingsView(_ groups: [RecordingGroupDTO]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.releaseTitle + (g.year.map { " (\($0))" } ?? "")).font(.system(size: 14, weight: .semibold))
                            performerLines(g)
                        }
                        Spacer()
                        PillButton(title: "Play", symbol: "play.fill", filled: true) { lib.onReplace?(g.tracks) }
                        PillButton(title: "Add", symbol: "text.badge.plus") { lib.onAdd?(g.tracks, false) }
                    }
                    ForEach(g.tracks) { t in
                        HStack(spacing: 8) {
                            Text(t.movementNumber.map { roman($0) } ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                            Text(t.movementTitle ?? t.title).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            Text(fmtDuration(t.duration)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2).contentShape(Rectangle()).onTapGesture(count: 2) { lib.onReplace?([t]) }
                    }
                }
                .padding(12).panel(radius: 14)
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

struct LetterHeader: View {
    let letter: String
    var body: some View { Text(letter).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Brand.cyan.opacity(0.9)).padding(.top, 12).padding(.bottom, 3).padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading) }
}

/// A list row with an avatar, title, subtitle and a count.
struct RowButton: View {
    let title: String
    let subtitle: String
    let count: Int
    let symbol: String
    var image: NSImage? = nil
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Avatar(name: title, image: image, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Text("\(count)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9).padding(.vertical, 5).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover.v ? 0.07 : 0)))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(.easeOut(duration: 0.1), value: hover.v)
    }
}

/// A round picture: the artist's portrait or album mosaic, else initials on a generated gradient.
/// The soft shadow is its own blurred shape behind the picture rather than a layer shadow on the clipped image, and the size is a whole number
/// of points: a clipped photo with a layer shadow at a fractional position can smear its top edge into a visible line on some displays.
struct Avatar: View {
    let name: String
    var image: NSImage?
    var size: CGFloat
    var shadow = false
    var body: some View {
        let d = size.rounded()
        ZStack {
            if shadow { Circle().fill(.black.opacity(0.4)).frame(width: d - 6, height: d - 6).blur(radius: 6).offset(y: 4) }
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill).frame(width: d, height: d)
                } else {
                    let p = ArtPalette.fallback(seed: name)
                    ZStack {
                        Circle().fill(LinearGradient(colors: [p.grid[0].color, p.grid[8].color], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text(initials).font(.system(size: d * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.92))
                    }.frame(width: d, height: d)
                }
            }
            .mask(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.8))
        }
        .frame(width: d + (shadow ? 16 : 0), height: d + (shadow ? 16 : 0))
    }
    private var initials: String { name.split(separator: " ").prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined() }
}

// MARK: - Artists

struct ArtistsView: View {
    @EnvironmentObject var art: ArtistArt
    let rows: [LibraryModel.Row]
    let opts: ViewOptions
    let open: (String) -> Void

    var body: some View {
        if opts.list { list } else { grid }
    }

    private var grouped: Bool { opts.letters && opts.sort == .title }

    /// Portraits form one continuous grid; the A–Z headers belong to the list view.
    private var grid: some View {
        let cell = (84 + CGFloat(opts.size) * 70).rounded()
        let cols = [GridItem(.adaptive(minimum: cell + 16, maximum: cell + 16), spacing: 10, alignment: .top)]
        return VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: cols, alignment: .leading, spacing: 20) { ForEach(rows) { ArtistCard(row: $0, size: cell, open: open) } }
            if rows.isEmpty { Text("No artists").foregroundStyle(.secondary).padding(.top, 40) }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 1) {
            if grouped {
                ForEach(LibraryOrdering.grouped(rows, title: \.title), id: \.letter) { g in
                    LetterHeader(letter: g.letter)
                    ForEach(g.items) { r in row(r) }
                }
            } else { ForEach(rows) { r in row(r) } }
        }
    }

    private func row(_ r: LibraryModel.Row) -> some View {
        RowButton(title: r.title, subtitle: "\(r.count) songs", count: r.count, symbol: "person", image: art.info[r.id]?.image) { open(r.id) }
            .onAppear { art.load(id: r.id, name: r.title) }
    }
}

struct ArtistCard: View {
    @EnvironmentObject var art: ArtistArt
    let row: LibraryModel.Row
    let size: CGFloat
    let open: (String) -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        VStack(spacing: 8) {
            Avatar(name: row.title, image: art.info[row.id]?.image, size: size, shadow: true)
                .overlay { if hover.v { Circle().strokeBorder(Brand.gradient, lineWidth: 1.6).padding(8) } }
            VStack(spacing: 1) {
                Text(row.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text("\(row.count) songs").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size.rounded() + 16)
        .contentShape(Rectangle())
        .onTapGesture { open(row.id) }
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover.v = h } }
        .onAppear { art.load(id: row.id, name: row.title) }
    }
}

struct ArtistDetail: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: ArtistArt
    let id: String
    let name: String
    let tracks: [TrackDTO]
    let albums: [ReleaseDTO]
    let back: () -> Void

    var body: some View {
        PageScaffold(title: "", back: back, backTitle: "Artists") {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 22) {
                    Avatar(name: name, image: art.info[id]?.image, size: 132, shadow: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ARTIST").microLabel().foregroundStyle(Brand.cyan)
                        Text(name).font(.system(size: 32, weight: .bold)).tracking(-0.6).lineLimit(2)
                        Text("\(albums.count) album\(albums.count == 1 ? "" : "s") · \(tracks.count) songs").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            PillButton(title: "Play", symbol: "play.fill", filled: true) { m.library.onReplace?(tracks) }
                            PillButton(title: "Shuffle", symbol: "shuffle") { m.library.onReplace?(tracks.shuffled()) }
                            PillButton(title: "Add to Queue", symbol: "text.badge.plus") { m.library.onAdd?(tracks, false) }
                        }.padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                if !albums.isEmpty {
                    Text("Albums").font(.system(size: 17, weight: .semibold))
                    AlbumGrid(albums: albums, open: { a in m.tab = .albums; m.library.selectedID = a.id }, minimum: 130)
                }
                Text("Songs").font(.system(size: 17, weight: .semibold))
                SongList(tracks: tracks)
            }
        }
        .onAppear { art.load(id: id, name: name) }
    }
}

// MARK: - Albums

struct AlbumGrid: View {
    let albums: [ReleaseDTO]
    let open: (ReleaseDTO) -> Void
    var minimum: CGFloat = 150

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: minimum + 60), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
            ForEach(albums) { a in AlbumCard(album: a) { open(a) } }
        }
        .overlay { if albums.isEmpty { Text("No albums").foregroundStyle(.secondary).padding(.top, 60) } }
    }
}

struct AlbumList: View {
    @EnvironmentObject var art: AlbumArt
    let albums: [ReleaseDTO]
    let open: (ReleaseDTO) -> Void
    var body: some View {
        LazyVStack(spacing: 1) {
            ForEach(albums) { a in
                AlbumListRow(album: a) { open(a) }
            }
        }
    }
}

struct AlbumListRow: View {
    @EnvironmentObject var art: AlbumArt
    let album: ReleaseDTO
    let open: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        HStack(spacing: 12) {
            CoverView(image: art.info[album.id]?.image, palette: ArtPalette.fallback(seed: album.title), corner: 6).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(album.artistNames.first ?? "").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if album.isHiRes { HDMark() }
            Text([album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.tertiary)
            Text("\(album.trackCount)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 9).padding(.vertical, 5).contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover.v ? 0.07 : 0)))
        .onHover { hover.v = $0 }.onTapGesture(perform: open).onAppear { art.load(album) }
    }
}

struct HDMark: View {
    var body: some View { Text("HD").font(.system(size: 8.5, weight: .heavy)).tracking(0.5).padding(.horizontal, 4).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, lineWidth: 0.8)).foregroundStyle(.secondary) }
}

struct AlbumCard: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    let album: ReleaseDTO
    let open: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let info = art.info[album.id]
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                CoverView(image: info?.image, palette: ArtPalette.fallback(seed: album.title), corner: 10, symbol: "music.note")
                    .shadow(color: .black.opacity(hover.v ? 0.5 : 0.28), radius: hover.v ? 14 : 7, y: hover.v ? 7 : 3)
                if hover.v {
                    Button { play() } label: { Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 34, height: 34)
                        .background(Circle().fill(Brand.accent)) }
                        .buttonStyle(.plain).padding(8).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .scaleEffect(hover.v ? 1.02 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(([album.artistNames.first].compactMap { $0 } + [album.year.map(String.init)].compactMap { $0 }).joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if album.isHiRes || info?.hd == true { HDMark() }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover.v = h } }
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
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    CoverView(image: info?.image, palette: ArtPalette.fallback(seed: album.title), corner: 14).frame(width: 200, height: 200)
                        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ALBUM").microLabel().foregroundStyle(Brand.cyan)
                        Text(album.title).font(.system(size: 28, weight: .bold)).tracking(-0.5).lineLimit(3)
                        Text(album.artistNames.prefix(3).joined(separator: ", ")).font(.system(size: 17, weight: .medium)).foregroundStyle(Brand.accent).lineLimit(2)
                        Text(meta).microLabel().foregroundStyle(.secondary).padding(.top, 2)
                        if let best = tracks.first(where: { isHiRes($0) }) ?? tracks.first {
                            HStack(spacing: 6) {
                                if isHiRes(best) { HiResMark(compact: true) }
                                HWBadge(text: trackQuality(best).uppercased(), tone: isHiRes(best) ? .amber : .green, compact: true)
                            }.padding(.top, 4)
                        }
                        HStack(spacing: 6) {
                            PillButton(title: "Play", symbol: "play.fill", filled: true) { m.library.onReplace?(tracks) }
                            PillButton(title: "Shuffle", symbol: "shuffle") { m.library.onReplace?(tracks.shuffled()) }
                            PillButton(title: "Add to Queue", symbol: "text.badge.plus") { m.library.onAdd?(tracks, false) }
                        }.padding(.top, 10)
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
        return [genres, album.year.map(String.init), "\(tracks.count) song\(tracks.count == 1 ? "" : "s"), \(length)"].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Songs

struct SongList: View {
    @EnvironmentObject var m: PlayerModel
    let tracks: [TrackDTO]
    var showArtist = true
    var numbered = false
    var letters = false
    var sortHeader = false

    var body: some View {
        VStack(spacing: 0) {
            if sortHeader { header }
            LazyVStack(spacing: 0) {
                if letters {
                    ForEach(LibraryOrdering.grouped(tracks, title: \.title), id: \.letter) { g in
                        LetterHeader(letter: g.letter)
                        ForEach(Array(g.items.enumerated()), id: \.element.id) { i, t in row(t, index: i, all: g.items) }
                    }
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in row(t, index: i, all: tracks) }
                }
                if tracks.isEmpty { Text("No songs").foregroundStyle(.secondary).padding(.top, 40) }
            }
        }
    }

    private func row(_ t: TrackDTO, index i: Int, all: [TrackDTO]) -> some View {
        SongRow(track: t, index: i + 1, showArtist: showArtist, numbered: numbered, playing: m.isActive && m.current?.url.path == t.path)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { m.library.onReplace?(Array(all[i...])) }
            .contextMenu {
                Button("Play") { m.library.onReplace?(Array(all[i...])) }
                Button("Add to Queue") { m.library.onAdd?([t], false) }
            }
    }

    /// Column titles that sort the table when clicked.
    private var header: some View {
        let o = m.options(for: .songs)
        func col(_ title: String, _ key: SortKey, width: CGFloat? = nil, trailing: Bool = false) -> some View {
            Button {
                var n = o; if n.sort == key { n.ascending.toggle() } else { n.sort = key; n.ascending = true }; m.setOptions(n, for: .songs)
            } label: {
                HStack(spacing: 3) {
                    Text(title).microLabel()
                    if o.sort == key { Image(systemName: o.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
                }
                .foregroundStyle(o.sort == key ? Brand.cyan : Color.secondary)
                .frame(maxWidth: width == nil ? .infinity : width, alignment: trailing ? .trailing : .leading)
            }.buttonStyle(.plain)
        }
        return HStack(spacing: 12) {
            Color.clear.frame(width: 26, height: 1)
            col("Title", .title)
            col("Artist", .artist)
            col("Album", .album)
            col("Quality", .quality, width: 120, trailing: true)
            col("Time", .duration, width: 46, trailing: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.8) }
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
                if hover.v { Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(.primary) }
                else if playing { EqualizerBars(active: m.status.state == .playing, color: Brand.cyan).frame(width: 12, height: 10) }
                else { Text(numbered ? "\(track.trackNumber ?? index)" : "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary) }
            }.frame(width: 26)
            Text(track.title).font(.system(size: 12.5, weight: playing ? .semibold : .regular)).foregroundStyle(playing ? Brand.cyan : .primary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if showArtist && !numbered {
                Text(track.artistLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(track.releaseTitle ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            } else if showArtist {
                Text(track.artistLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 5) {
                if isHiRes(track) { HDMark() }
                Text(trackQuality(track)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }.frame(width: 120, alignment: .trailing)
            Text(fmtDuration(track.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover.v ? 0.08 : (index % 2 == 0 ? 0.022 : 0))))
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
                VStack(alignment: .leading, spacing: 24) {
                    if !r.releases.isEmpty { section("Albums") { AlbumGrid(albums: r.releases, open: { a in m.tab = .albums; m.library.selectedID = a.id }, minimum: 130) } }
                    if !r.tracks.isEmpty { section("Songs") { SongList(tracks: r.tracks) } }
                    if !r.parties.isEmpty {
                        section("Artists & composers") {
                            LazyVStack(spacing: 1) { ForEach(r.parties) { p in RowButton(title: p.name, subtitle: p.kind == "group" ? "Ensemble" : "", count: p.count, symbol: "person") { m.searchText = ""; m.tab = .artists; m.library.selectedID = p.id } } }
                        }
                    }
                    if !r.works.isEmpty {
                        section("Works") { LazyVStack(spacing: 1) { ForEach(r.works) { w in RowButton(title: w.title, subtitle: [w.composerName, w.catalog].compactMap { $0 }.joined(separator: " · "), count: w.trackCount, symbol: "book") { m.searchText = ""; m.tab = .works; m.library.selectedID = w.id } } } }
                    }
                }
            } else { ProgressView().padding(.top, 30) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 17, weight: .semibold)); content() }
    }
}

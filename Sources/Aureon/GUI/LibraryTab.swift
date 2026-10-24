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
    /// A hairline under the title; off for pages whose first section brings its own.
    var ruled = true
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @Environment(\.chromeInset) private var inset
    @EnvironmentObject private var chrome: ChromeState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if title.isEmpty { HStack(spacing: 8) { Spacer(minLength: 0); trailing }.frame(height: 40) }
                if let back {
                    Button(action: back) { Label(backTitle, systemImage: "chevron.left").font(Typo.sans(11, .regular)).tracking(1.2).textCase(.uppercase) }
                        .buttonStyle(.plain).foregroundStyle(Brand.accentText)
                }
                if !title.isEmpty {
                    // the title is set large, with air above it, a small tracked label over it and a hairline under it
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .lastTextBaseline, spacing: 24) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let subtitle { Text(subtitle).microLabel().foregroundStyle(Brand.inkTertiary).lineLimit(1) }
                                Text(title).font(Typo.title(40)).tracking(-0.8).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            trailing.padding(.bottom, 6)
                        }
                        if ruled { Rule() }
                    }
                    .padding(.top, 8)
                }
                content
            }
            .padding(.horizontal, 40).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .underChrome(chrome, inset: inset)
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, back: (() -> Void)? = nil, backTitle: String = "Back", ruled: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, back: back, backTitle: backTitle, ruled: ruled, trailing: { EmptyView() }, content: content)
    }
}

struct RuleButton: View {
    let title: String
    var symbol: String?
    var filled = false
    let action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(Typo.sans(11, .light)) }
                Text(title).font(Typo.sans(12, .medium)).tracking(0.4)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(filled ? Brand.onAccent : Brand.ink)
            .background(Rectangle().fill(filled ? Brand.accent : Brand.ink.opacity(hover.v ? 0.06 : 0)))
            .overlay(Rectangle().strokeBorder(filled ? Color.clear : (hover.v ? Brand.coachline : Brand.ink.opacity(0.28)), lineWidth: Metrics.hairline))
            .brightness(filled && hover.v ? 0.05 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
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
            HStack(spacing: 4) { Image(systemName: icon).font(Typo.sans(11, .medium)); Text(label).font(Typo.sans(12, .medium)) }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(Rectangle().strokeBorder(active ? Brand.coachline : Brand.ink.opacity(0.2), lineWidth: Metrics.hairline))
                .foregroundStyle(active ? Brand.accentText : Brand.ink)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var width: CGFloat = 150
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Typo.sans(12)).frame(width: width)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 8).padding(.vertical, 8).overlay(alignment: .bottom) { Rule() }
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
        if let focus = lib.focus { PersonFocusPage(graph: focus, lib: lib).id(focus.person.id) }
        else if lib.stats.tracks == 0 && !lib.importing { empty }
        else if lib.selectedID != nil, tab != .songs { detailPage }
        else { listPage }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            SearchField(prompt: "Filter", text: $lib.search, width: 110)
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
                    Button { update { $0.list = false } } label: { Image(systemName: "square.grid.2x2") }.foregroundStyle(opts.list ? Brand.inkSecondary : Brand.cyan)
                    Button { update { $0.list = true } } label: { Image(systemName: "list.bullet") }.foregroundStyle(opts.list ? Brand.cyan : Brand.inkSecondary)
                }.buttonStyle(IconButtonStyle()).overlay(Rectangle().strokeBorder(Brand.ink.opacity(0.2), lineWidth: Metrics.hairline))
                if !opts.list {
                    ValueSlider(value: Binding(get: { opts.size }, set: { v in update { $0.size = v } }), in: 0...1).controlSize(.mini).frame(width: 70).help("Cover size")
                }
            }
            Button { lib.scanDuplicates(prompt: false) } label: { Image(systemName: "square.on.square.dashed") }.buttonStyle(IconButtonStyle()).disabled(lib.scanningDuplicates).help("Find duplicate songs and albums")
            Button { chooseFolder() } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(IconButtonStyle()).help("Add music folder…")
            Button { lib.rescan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(IconButtonStyle()).disabled(lib.folders.isEmpty || lib.importing).help("Rescan")
            if lib.importing { ProgressView().controlSize(.small) }
        }
    }

    private var subtitle: String {
        if lib.importing { return lib.importProgress }
        switch tab {
        case .albums: return "\(lib.pager.total) albums"
        case .songs: return "\(lib.songs.count) songs"
        default: return "\(lib.rows.count)"
        }
    }

    private var empty: some View {
        PageScaffold(title: tab.rawValue) {
            VStack(spacing: 16) {
                Image(systemName: "books.vertical").font(Typo.sans(42, .ultraLight)).foregroundStyle(Brand.inkSecondary)
                Text("Your library is empty").font(Typo.t3.weight(.semibold))
                Text("Add a folder of FLAC, ALAC, WAV or AIFF files. Aureon reads multiple artists per track and classical tags — composer, conductor, ensemble, soloists, work, movement and opus. Audio files are never modified.")
                    .multilineTextAlignment(.center).foregroundStyle(Brand.inkSecondary).frame(maxWidth: 420).font(Typo.callout)
                RuleButton(title: "Add Music Folder…", symbol: "folder.badge.plus", filled: true) { chooseFolder() }
            }
            .frame(maxWidth: .infinity).padding(.top, 72)
        }
    }

    // MARK: list level

    @ViewBuilder private var listPage: some View {
        PageScaffold(title: tab.rawValue, subtitle: subtitle, trailing: { toolbar }) {
            DuplicateBanner(lib: lib)
            switch tab {
            case .albums:
                PagedAlbums(pager: lib.pager, query: AlbumQuery(opts, search: lib.search), list: opts.list, minimum: 168 + CGFloat(opts.size) * 120, open: { lib.selectedID = $0.id })
            case .songs: SongList(tracks: lib.orderedSongs(opts), numbered: false, letters: opts.letters && opts.sort == .title, sortHeader: true)
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
            if rows.isEmpty { categoryExplainer }
        }
    }

    /// Shown while a classical category has no data: what the page is for and which tags fill it.
    @ViewBuilder private var categoryExplainer: some View {
        switch tab {
        case .composers:
            EmptyExplainer(icon: "music.quarternote.3", title: "No composers yet",
                           text: "Composers lists everyone credited in the COMPOSER tag of your files — classical music, film scores and songwriters. Each composer opens to their works and songs. Tag your files with a composer, then rescan the library.")
        case .works:
            EmptyExplainer(icon: "book", title: "No works yet",
                           text: "Works groups songs into compositions, such as “Symphony No. 5”, with their movements and every recording you own. It is built from the WORK, MOVEMENT and OPUS tags, or from titles shaped like “Symphony No. 5: I. Allegro” when a composer is tagged.")
        case .conductors:
            EmptyExplainer(icon: "wand.and.rays", title: "No conductors yet",
                           text: "Conductors lists the people in the CONDUCTOR tag and the recordings they led. It fills up as you add orchestral and choral albums that carry that tag.")
        case .ensembles:
            EmptyExplainer(icon: "person.3", title: "No ensembles yet",
                           text: "Ensembles lists orchestras, choirs and quartets from the ENSEMBLE or ORCHESTRA tags — and names that clearly are groups, like “Berliner Philharmoniker”. Add classical albums with those tags to see them here.")
        default:
            Text("Nothing here").foregroundStyle(Brand.inkSecondary).padding(.top, 32)
        }
    }

    // MARK: detail level

    @ViewBuilder private var detailPage: some View {
        let back: () -> Void = { if lib.canGoBack { lib.goBack() } else { lib.selectedID = nil } }
        switch lib.detail {
        case .tracks(_, let tracks) where tab == .albums:
            if let album = lib.selectedAlbum, album.id == lib.selectedID {
                AlbumDetail(album: album, tracks: tracks, back: back)
            } else { PageScaffold(title: tab.rawValue, back: back, backTitle: tab.rawValue) { SongList(tracks: tracks) } }
        case .tracks(_, let tracks) where tab == .artists:
            let row = lib.rows.first { $0.id == lib.selectedID }
            ArtistDetail(id: lib.selectedID ?? "", name: row?.title ?? "Artist", tracks: tracks, albums: lib.artistAlbums, back: back)
        case .tracks(let title, let tracks):
            let name = lib.rows.first { $0.id == lib.selectedID }?.title ?? title
            PageScaffold(title: name, subtitle: "\(tracks.count) songs", back: back, backTitle: tab.rawValue, trailing: { trackActions(tracks) }) { SongList(tracks: tracks) }
        case .composer(let works, let tracks):
            let name = lib.rows.first { $0.id == lib.selectedID }?.title ?? "Composer"
            PageScaffold(title: name, subtitle: "\(works.count) work\(works.count == 1 ? "" : "s") · \(tracks.count) songs", back: back, backTitle: tab.rawValue, trailing: { if !tracks.isEmpty { trackActions(tracks) } }) {
                VStack(alignment: .leading, spacing: 24) {
                    if !works.isEmpty {
                        Text("Works").font(Typo.serif(17, .regular))
                        worksView(works)
                    }
                    if !tracks.isEmpty {
                        Text(works.isEmpty ? "Songs" : "All songs").font(Typo.serif(17, .regular))
                        SongList(tracks: tracks)
                    }
                    if works.isEmpty && tracks.isEmpty {
                        EmptyExplainer(icon: "music.quarternote.3", title: "Nothing credited yet", text: "This name appears as a composer in your tags, but no song currently carries the credit. Rescan the library to refresh it.")
                    }
                }
            }
        case .works(let works):
            PageScaffold(title: lib.rows.first { $0.id == lib.selectedID }?.title ?? "Works", subtitle: "\(works.count) works", back: back, backTitle: tab.rawValue) { worksView(works) }
        case .recordings(let w, let groups):
            PageScaffold(title: w.title, subtitle: [w.composerName, w.catalog, w.key].compactMap { $0 }.joined(separator: " · "), back: back,
                         backTitle: lib.canGoBack ? "Works" : tab.rawValue) { recordingsView(groups) }
        default:
            PageScaffold(title: tab.rawValue, back: back, backTitle: tab.rawValue) { ProgressView().frame(maxWidth: .infinity).padding(.top, 64) }
        }
    }

    private func trackActions(_ tracks: [TrackDTO]) -> some View {
        HStack(spacing: 8) {
            RuleButton(title: "Play", symbol: "play.fill", filled: true) { lib.onReplace?(tracks) }
            RuleButton(title: "Shuffle", symbol: "shuffle") { lib.onReplace?(tracks.shuffled()) }
            RuleButton(title: "Add", symbol: "text.badge.plus") { lib.onAdd?(tracks, false) }
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
                            Text(g.releaseTitle + (g.year.map { " (\($0))" } ?? "")).font(Typo.sans(14, .semibold))
                            performerLines(g)
                        }
                        Spacer()
                        RuleButton(title: "Play", symbol: "play.fill", filled: true) { lib.onReplace?(g.tracks) }
                        RuleButton(title: "Add", symbol: "text.badge.plus") { lib.onAdd?(g.tracks, false) }
                    }
                    ForEach(g.tracks) { t in
                        HStack(spacing: 8) {
                            Text(t.movementNumber.map { roman($0) } ?? "").font(Typo.mono(11.5)).foregroundStyle(Brand.inkSecondary).frame(width: 30, alignment: .trailing)
                            Text(t.movementTitle ?? t.title).font(Typo.sans(13)).lineLimit(1)
                            Spacer()
                            Text(fmtDuration(t.duration)).font(Typo.mono(11.5)).foregroundStyle(Brand.inkSecondary)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 4).contentShape(Rectangle()).onTapGesture { lib.onReplace?([t]) }
                    }
                }
                .padding(12).panel(radius: 14)
            }
        }
    }

    @ViewBuilder private func performerLines(_ g: RecordingGroupDTO) -> some View {
        let cond = g.performers.filter { $0.role == "conductor" }.map(\.name), ens = g.performers.filter { $0.role == "ensemble" }.map(\.name)
        let solo = g.performers.filter { $0.role == "soloist" || $0.role == "performer" }.map { c in c.instrument.map { i in "\(c.name) (\(i))" } ?? c.name }
        if !cond.isEmpty { Text("Conductor: " + cond.joined(separator: ", ")).font(Typo.caption).foregroundStyle(Brand.inkSecondary) }
        if !ens.isEmpty { Text("Ensemble: " + ens.joined(separator: ", ")).font(Typo.caption).foregroundStyle(Brand.inkSecondary) }
        if !solo.isEmpty { Text("Soloists: " + solo.joined(separator: ", ")).font(Typo.caption).foregroundStyle(Brand.inkSecondary) }
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
        DispatchQueue.main.async { if p.runModal() == .OK { p.urls.forEach { lib.addFolder($0) } } }
    }
}

struct LetterHeader: View {
    let letter: String
    var body: some View { Text(letter).font(Typo.serif(20, .regular)).foregroundStyle(Brand.accentText).padding(.top, 24).padding(.bottom, 8).padding(.leading, 8).frame(maxWidth: .infinity, alignment: .leading) }
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
            HStack(spacing: 12) {
                Avatar(name: title, image: image, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Typo.sans(13, .medium)).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1) }
                }
                Spacer()
                Text("\(count)").font(Typo.mono(11.5)).foregroundStyle(Brand.inkTertiary)
                Image(systemName: "chevron.right").font(Typo.sans(10, .semibold)).foregroundStyle(Brand.inkTertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
            .background(Rectangle().fill(Brand.ink.opacity(hover.v ? 0.05 : 0))).overlay(alignment: .bottom) { Rule(strength: 0.5) }
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
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill).frame(width: d, height: d)
                } else {
                    let p = ArtPalette.fallback(seed: name)
                    ZStack {
                        Circle().fill(p.grid[4].mixed(with: RGB(0.05, 0.05, 0.06), 0.45).color)
                        Text(initials).font(Typo.sans(d * 0.38, .semibold)).foregroundStyle(.white.opacity(0.92))
                    }.frame(width: d, height: d)
                }
            }
            .mask(Circle())
            .overlay(Circle().strokeBorder(Brand.ink.opacity(0.18), lineWidth: Metrics.hairline))
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
        let cols = [GridItem(.adaptive(minimum: cell + 16, maximum: cell + 16), spacing: 12, alignment: .top)]
        return VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: cols, alignment: .leading, spacing: 24) { ForEach(rows) { ArtistCard(row: $0, size: cell, open: open) } }
            if rows.isEmpty { Text("No artists").foregroundStyle(Brand.inkSecondary).padding(.top, 40) }
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
                .overlay { Circle().strokeBorder(Brand.coachline, lineWidth: Metrics.hairline).padding(4).opacity(hover.v ? 1 : 0) }
                .animation(Motion.glide, value: hover.v)
            VStack(spacing: 1) {
                Text(row.title).font(Typo.sans(12.5, .semibold)).lineLimit(1)
                Text("\(row.count) songs").font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary)
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
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    Avatar(name: name, image: art.info[id]?.image, size: 132, shadow: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ARTIST").microLabel().foregroundStyle(Brand.cyan)
                        Text(name).font(Typo.serif(32, .regular)).tracking(-0.6).lineLimit(2)
                        Text("\(albums.count) album\(albums.count == 1 ? "" : "s") · \(tracks.count) songs").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
                        HStack(spacing: 8) {
                            RuleButton(title: "Play", symbol: "play.fill", filled: true) { m.library.onReplace?(tracks) }
                            RuleButton(title: "Shuffle", symbol: "shuffle") { m.library.onReplace?(tracks.shuffled()) }
                            RuleButton(title: "Add to Queue", symbol: "text.badge.plus") { m.library.onAdd?(tracks, false) }
                            RuleButton(title: "Credits", symbol: "person.text.rectangle") { m.library.openPerson(id) }
                        }.padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                if !albums.isEmpty {
                    Text("Albums").font(Typo.serif(17, .regular))
                    AlbumGrid(albums: albums, open: { a in m.tab = .albums; m.library.selectedID = a.id }, minimum: 130)
                }
                Text("Songs").font(Typo.serif(17, .regular))
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: minimum + 60), spacing: 16, alignment: .top)], alignment: .leading, spacing: 24) {
            ForEach(albums) { a in AlbumCard(album: a) { open(a) } }
        }
        .overlay { if albums.isEmpty { Text("No albums").foregroundStyle(Brand.inkSecondary).padding(.top, 64) } }
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
                Text(album.title).font(Typo.sans(13, .medium)).lineLimit(1)
                Text(album.artistNames.first ?? "").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
            }
            Spacer()
            if album.isHiRes { HDMark() }
            Text([album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")).font(Typo.sans(11)).foregroundStyle(Brand.inkTertiary)
            Text("\(album.trackCount)").font(Typo.mono(11.5)).foregroundStyle(Brand.inkTertiary).frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
        .background(Rectangle().fill(Brand.ink.opacity(hover.v ? 0.05 : 0))).overlay(alignment: .bottom) { Rule(strength: 0.5) }
        .onHover { hover.v = $0 }.onTapGesture(perform: open).onAppear { art.load(album) }
    }
}

struct HDMark: View {
    var body: some View { QualityBadge(mark: QualityMark(kind: .hiRes, title: "HI-RES", spec: ""), size: .tiny) }
}

struct AlbumCard: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    let album: ReleaseDTO
    let open: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let info = art.info[album.id]
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                CoverView(image: info?.image, palette: ArtPalette.fallback(seed: album.title), corner: 0, symbol: "music.note")
                    .hoverLift(hover.v, radius: 0)
                if hover.v {
                    Button { play() } label: { Image(systemName: "play.fill").font(Typo.sans(12, .regular)).foregroundStyle(Brand.onAccent).frame(width: 40, height: 40)
                        .background(Rectangle().fill(Brand.accent)) }
                        .buttonStyle(.plain).padding(12).transition(.opacity)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(Typo.serif(15, .regular)).tracking(-0.1).lineLimit(1)
                HStack(spacing: 8) {
                    Text(([album.artistNames.first].compactMap { $0 } + [album.year.map(String.init)].compactMap { $0 }).joined(separator: " · ")).font(Typo.sans(11)).tracking(0.3).foregroundStyle(Brand.inkSecondary).lineLimit(1)
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
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 24) {
                    CoverView(image: info?.image, palette: ArtPalette.fallback(seed: album.title), corner: 14).frame(width: 200, height: 200)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ALBUM").microLabel().foregroundStyle(Brand.cyan)
                        Text(album.title).font(Typo.serif(28, .regular)).tracking(-0.5).lineLimit(3)
                        Text(album.artistNames.prefix(3).joined(separator: ", ")).font(Typo.sans(17, .medium)).foregroundStyle(Brand.accent).lineLimit(2)
                        Text(meta).microLabel().foregroundStyle(Brand.inkSecondary).padding(.top, 2)
                        if let best = tracks.first(where: { isHiRes($0) }) ?? tracks.first {
                            HStack(spacing: 8) {
                                if isHiRes(best) { HiResMark(compact: true) }
                                HWBadge(text: trackQuality(best).uppercased(), tone: isHiRes(best) ? .amber : .green, compact: true)
                            }.padding(.top, 4)
                        }
                        HStack(spacing: 8) {
                            RuleButton(title: "Play", symbol: "play.fill", filled: true) { m.library.onReplace?(tracks) }
                            RuleButton(title: "Shuffle", symbol: "shuffle") { m.library.onReplace?(tracks.shuffled()) }
                            RuleButton(title: "Add to Queue", symbol: "text.badge.plus") { m.library.onAdd?(tracks, false) }
                        }.padding(.top, 12)
                    }
                    Spacer(minLength: 0)
                }
                SongList(tracks: tracks, showArtist: Set(tracks.map(\.artistLine)).count > 1, numbered: true)
                AlbumPersonnel(tracks: tracks)
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
    /// Set when the list is a playlist: adds "Remove from Playlist" to the context menu.
    var playlistID: String? = nil
    /// The letter groups are expensive for a big library: computed once per list, not on every redraw (the player state redraws this view often).
    @StateObject private var groups = Box<(key: Int, value: [(letter: String, items: [TrackDTO])])?>(nil)

    private func grouped() -> [(letter: String, items: [TrackDTO])] {
        var h = Hasher(); h.combine(tracks.count); h.combine(tracks.first?.id); h.combine(tracks.last?.id); h.combine(tracks.dropFirst(tracks.count / 2).first?.id)
        let key = h.finalize()
        if let c = groups.v, c.key == key { return c.value }
        let g = LibraryOrdering.grouped(tracks, title: \.title)
        DispatchQueue.main.async { groups.v = (key, g) }
        return g
    }

    var body: some View {
        let nowPath = m.isActive ? m.current?.path : nil
        VStack(spacing: 0) {
            if sortHeader { header }
            LazyVStack(spacing: 0) {
                if letters {
                    ForEach(grouped(), id: \.letter) { g in
                        LetterHeader(letter: g.letter)
                        ForEach(Array(g.items.enumerated()), id: \.element.id) { i, t in row(t, shown: i, at: nil, playingPath: nowPath) }
                    }
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in row(t, shown: i, at: i, playingPath: nowPath) }
                }
                if tracks.isEmpty { Text("No songs").foregroundStyle(Brand.inkSecondary).padding(.top, 40) }
            }
        }
    }

    private func row(_ t: TrackDTO, shown i: Int, at known: Int?, playingPath: String?) -> some View {
        // the position in the whole list is only needed when something is clicked
        func index() -> Int { known ?? tracks.firstIndex { $0.id == t.id } ?? i }
        return SongRow(track: t, index: i + 1, showArtist: showArtist, numbered: numbered, playing: playingPath == t.path) { m.play(tracks: tracks, at: index()) }
            .contextMenu {
                Button("Play") { m.play(tracks: tracks, at: index()) }
                TrackMenu(tracks: [t], playlistID: playlistID)
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
                    if o.sort == key { Image(systemName: o.ascending ? "chevron.up" : "chevron.down").font(Typo.sans(8, .bold)) }
                }
                .foregroundStyle(o.sort == key ? Brand.cyan : Brand.inkSecondary)
                .frame(maxWidth: width == nil ? .infinity : width, alignment: trailing ? .trailing : .leading)
            }.buttonStyle(.plain)
        }
        return HStack(spacing: 12) {
            Color.clear.frame(width: 26, height: 1)
            col("Title", .title)
            col("Artist", .artist)
            col("Album", .album)
            Color.clear.frame(width: 24, height: 1)
            col("Quality", .quality, width: 150, trailing: true)
            col("Time", .duration, width: 46, trailing: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rule() }
    }
}

/// One song. The whole row is the button: a click anywhere on it plays the song, with a flash and a bounce so it is clear something happened.
struct SongRow: View {
    let track: TrackDTO
    let index: Int
    let showArtist: Bool
    let numbered: Bool
    let playing: Bool
    let onPlay: () -> Void
    @EnvironmentObject var m: PlayerModel
    @StateObject private var hover = Box(false)
    @StateObject private var flash = Box(0.0)

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if hover.v && !playing { Image(systemName: "play.fill").font(Typo.sans(11)).foregroundStyle(.primary).transition(.scale.combined(with: .opacity)) }
                else if playing { EqualizerBars(active: m.status.state == .playing, color: Brand.accent).frame(width: 12, height: 10) }
                else { Text(numbered ? "\(track.trackNumber ?? index)" : "").font(Typo.mono(11.5)).foregroundStyle(Brand.inkSecondary) }
            }
            .frame(width: 26)
            Text(track.title).font(Typo.sans(12.5, playing ? .semibold : .regular)).foregroundStyle(playing ? Brand.accent : .primary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if showArtist && !numbered {
                Text(track.artistLine).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(track.releaseTitle ?? "").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            } else if showArtist {
                Text(track.artistLine).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            HeartButton(path: track.path, size: 12, alwaysVisible: false).opacity(hover.v || playing ? 1 : 0.0001).overlay { }.frame(width: 24)
            HStack(spacing: 8) {
                // Hi-Res and Lossless carry the small plate; other formats keep their plain line
                if QualityMark.make(track: track) != nil { TinyQualityMark(track: track) }
                else { Text(trackQuality(track)).font(Typo.mono(10.5)).foregroundStyle(Brand.inkTertiary).lineLimit(1) }
            }.frame(width: 150, alignment: .trailing)
            Text(fmtDuration(track.duration)).font(Typo.mono(12)).foregroundStyle(Brand.inkSecondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            ZStack {
                Rectangle().fill(Brand.ink.opacity(hover.v ? 0.05 : 0))
                if playing { Rectangle().fill(Brand.accent.opacity(0.07)) }
                Rectangle().fill(Brand.accent.opacity(0.22 * flash.v))
            }
        }
        .overlay(alignment: .bottom) { Rule(strength: 0.5) }
        .overlay(alignment: .leading) { if playing { Rectangle().fill(Brand.gradientVertical).frame(width: 2).transition(.opacity) } }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover.v = h } }
        .onTapGesture {
            flash.v = 1
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.75)) { flash.v = 0 } }
            onPlay()
        }
        .animation(Motion.glide, value: playing)
    }
}

// MARK: - Search

struct SearchPage: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        let r = m.library.searchResults
        PageScaffold(title: "Search", subtitle: m.searchText.isEmpty ? nil : "“\(m.searchText)”") {
            if m.searchText.isEmpty {
                Text("Search your library for songs, albums, artists, composers and works.").foregroundStyle(Brand.inkSecondary).padding(.top, 24)
            } else if let r, r.tracks.isEmpty && r.releases.isEmpty && r.works.isEmpty && r.parties.isEmpty {
                Text("No results").foregroundStyle(Brand.inkSecondary).padding(.top, 24)
                SemanticMatchesSection().padding(.top, 12)
            } else if let r {
                VStack(alignment: .leading, spacing: 24) {
                    if !r.releases.isEmpty { section("Albums") { AlbumGrid(albums: r.releases, open: { a in m.tab = .albums; m.library.selectedID = a.id }, minimum: 130) } }
                    if !r.tracks.isEmpty { section("Songs") { SongList(tracks: r.tracks) } }
                    SemanticMatchesSection(exclude: Set(r.tracks.map(\.path)))
                    if !r.parties.isEmpty {
                        section("Artists & composers") {
                            LazyVStack(spacing: 1) { ForEach(r.parties) { p in RowButton(title: p.name, subtitle: p.kind == "group" ? "Ensemble" : "", count: p.count, symbol: "person") { m.searchText = ""; m.tab = .artists; m.library.selectedID = p.id } .contextMenu { Button("Show Credits") { m.searchText = ""; m.tab = .artists; m.library.openPerson(p.id) } } } }
                        }
                    }
                    if !r.works.isEmpty {
                        section("Works") { LazyVStack(spacing: 1) { ForEach(r.works) { w in RowButton(title: w.title, subtitle: [w.composerName, w.catalog].compactMap { $0 }.joined(separator: " · "), count: w.trackCount, symbol: "book") { m.searchText = ""; m.tab = .works; m.library.selectedID = w.id } } } }
                    }
                }
            } else { ProgressView().padding(.top, 32) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(Typo.serif(17, .regular)); content() }
    }
}

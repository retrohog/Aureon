import SwiftUI

/// The landing page: a greeting for the time of day, a mix made from the time and from what you play (a new one every launch), chips to narrow it, quick
/// picks and shelves of albums.
struct HomePage: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    @EnvironmentObject var radio: RadioModel
    @Environment(\.chromeInset) private var inset
    @EnvironmentObject private var chrome: ChromeState
    @StateObject private var home = HomeModel()

    var body: some View {
        let l = m.library
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if l.stats.tracks == 0 { empty } else { mixContent }
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .underChrome(chrome, inset: inset)
        .background(alignment: .top) {
            LinearGradient(colors: [m.hero.palette.accent.color.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom).frame(height: 300).allowsHitTesting(false)
        }
        .onAppear { home.load(l.store, tracks: l.stats.tracks) }
        .onChange(of: l.stats.tracks) { _, n in home.load(l.store, tracks: n) }
    }

    @ViewBuilder private var mixContent: some View {
        if let mix = home.mix {
            header(mix)
            HStack(spacing: 8) {
                ForEach(HomeFilter.allCases) { f in PillChip(title: f.title, on: home.filter == f) { withAnimation(Motion.touch) { home.filter = f } } }
            }.padding(.top, 18)
            let quick = Array(home.visibleQuick().prefix(8))
            if !quick.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(quick) { QuickTile(album: $0) }
                }.padding(.top, 18)
            }
            ForEach(home.visibleShelves(), id: \.shelf.id) { s in
                HomeShelfView(shelf: s.shelf, items: s.items).padding(.top, 26)
            }
            if !radio.favorites.isEmpty { stations.padding(.top, 26) }
            if home.visibleQuick().isEmpty && home.visibleShelves().isEmpty {
                Text("Nothing in this mix matches “\(home.filter.title)” yet. Try another chip, or press Refresh mix.").font(Typo.callout).foregroundStyle(Brand.inkSecondary).padding(.top, 32)
            }
        } else {
            ProgressView().controlSize(.small).padding(.top, 40)
        }
    }

    private func header(_ mix: HomeMix) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(mix.greeting).font(Typo.title(44)).tracking(-0.5).lineLimit(1)
                HStack(spacing: 8) {
                    Circle().fill(Brand.accent).frame(width: 7, height: 7)
                    Text(mix.why).font(Typo.sans(14.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Button { withAnimation(Motion.glide) { home.refreshMix(m.library.store) } } label: { Label("Refresh mix", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(OutlinePillStyle())
                Button { home.showReasons.toggle() } label: { Text("Why these?") }
                    .buttonStyle(OutlinePillStyle())
                    .popover(isPresented: $home.showReasons, arrowEdge: .bottom) { reasons(mix) }
            }
        }
    }

    private func reasons(_ mix: HomeMix) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why these").font(Typo.serif(16, .medium))
            ForEach(mix.reasons, id: \.self) { r in
                HStack(alignment: .top, spacing: 8) { Circle().fill(Brand.accent).frame(width: 6, height: 6).padding(.top, 6); Text(r).font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            Text("Everything is worked out on this Mac from your own library and plays. Nothing is sent anywhere.").font(Typo.sans(12)).foregroundStyle(Brand.inkTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 320).background(Brand.canvas).foregroundStyle(Brand.ink)
    }

    private var stations: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Your stations").font(Typo.serif(22, .medium)); Spacer(); Button("Show all") { radio.section = .favorites; m.tab = .radio }.buttonStyle(.plain).foregroundStyle(Brand.inkSecondary).font(Typo.sans(13)) }
            ScrollView(.horizontal, showsIndicators: false) { HStack(alignment: .top, spacing: 16) { ForEach(radio.favorites) { StationCard(station: $0).frame(width: 140) } }.padding(.bottom, 4) }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Listen without compromise").font(Typo.title(44)).tracking(-0.5)
            Text("Bit-perfect playback from your own library or from radio stations around the world. Add a folder of music and Home fills with a mix for the time of day.").font(Typo.sans(15)).foregroundStyle(Brand.inkSecondary).frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: 8) {
                Button { chooseFolder() } label: { Label("Add folder", systemImage: "folder.badge.plus") }.buttonStyle(.solid).controlSize(.large)
                Button { m.tab = .radio } label: { Label("Browse radio", systemImage: "dot.radiowaves.left.and.right") }.buttonStyle(.rule).controlSize(.large)
            }
        }.padding(.top, 24)
    }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = "Choose the folder(s) that contain your music"
        DispatchQueue.main.async { if p.runModal() == .OK { p.urls.forEach { m.library.addFolder($0) } } }
    }
}

/// A pill with a hairline outline and no fill: the secondary actions beside a title.
struct OutlinePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }
    private struct Inner: View {
        let configuration: Configuration
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.font(Typo.sans(13, .medium)).labelStyle(.titleAndIcon)
                .foregroundStyle(Brand.ink.opacity(enabled ? 1 : 0.4))
                .padding(.horizontal, 16).frame(height: Metrics.pillHeight)
                .background(Capsule().fill(Brand.ink.opacity(configuration.isPressed ? 0.12 : (hover.v ? 0.07 : 0))))
                .overlay(Capsule().strokeBorder(Brand.ink.opacity(0.22), lineWidth: 1))
                .contentShape(Capsule())
                .animation(Motion.touch, value: hover.v)
                .onHover { hover.v = $0 }
        }
    }
}

/// A quick pick: a 56-point row on a raised plate, the cover at its left, the title beside it. A click opens the album; the play button appears under the pointer.
struct QuickTile: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    let album: ReleaseDTO
    @StateObject private var hover = Box(false)

    var body: some View {
        let info = art.info[album.id]
        HStack(spacing: 12) {
            CoverView(image: info?.image, palette: ArtPalette.fallback(seed: album.title), corner: 0, symbol: "music.note").frame(width: 56, height: 56)
            Text(album.title).font(Typo.sans(14.5)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if hover.v {
                Button { if let s = m.library.store { m.library.onReplace?(s.tracks(releaseID: album.id)) } } label: {
                    Image(systemName: "play.fill").font(Typo.sans(13)).foregroundStyle(Brand.onAccent).frame(width: 32, height: 32).background(Circle().fill(Brand.accent))
                }.buttonStyle(.plain).padding(.trailing, 10).transition(.opacity)
            }
        }
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(hover.v ? Brand.ink.opacity(0.12) : Brand.panel2))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { m.tab = .albums; m.library.selectedID = album.id }
        .onHover { h in withAnimation(Motion.touch) { hover.v = h } }
        .onAppear { art.load(album) }
        .accessibilityElement(children: .combine).accessibilityLabel(album.title).accessibilityAddTraits(.isButton)
    }
}

/// A shelf: a title with its explanation, "Show all", and one row of covers that fills the width.
struct HomeShelfView: View {
    @EnvironmentObject var m: PlayerModel
    let shelf: HomeShelf
    let items: [ReleaseDTO]
    @StateObject private var hover = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shelf.title).font(Typo.serif(22, .medium)).tracking(-0.2).lineLimit(1)
                    Text(shelf.sub).font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                }
                Spacer()
                Button("Show all") { m.tab = .albums }.buttonStyle(.plain).font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary)
            }
            ShelfRow(minCell: 150 * Look.current.density.cover + 20) {
                ForEach(items) { a in AlbumCard(album: a) { m.tab = .albums; m.library.selectedID = a.id } }
            }
            .clipped()
        }
    }
}

/// One row of equal cells that fills the width: as many as fit at `minCell`, the rest placed out of sight (and clipped).
struct ShelfRow: Layout {
    var minCell: CGFloat
    var gap: CGFloat = 16

    private func columns(_ width: CGFloat) -> Int {
        let w = width.isFinite ? width : 800                  // an unbounded proposal (measuring) gets a usual width
        return max(2, Int((w + gap) / (minCell + gap)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 800, n = columns(width), w = (width - gap * CGFloat(n - 1)) / CGFloat(n)
        let h = subviews.prefix(n).map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = columns(bounds.width), w = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        for (i, sv) in subviews.enumerated() {
            let x = i < n ? bounds.minX + CGFloat(i) * (w + gap) : bounds.maxX + 400
            sv.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: nil))
        }
    }
}

/// A door to another page, as a glass tile: the tint lives only in the symbol and a faint glow on hover.
struct PromoTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint: Color = Brand.accent
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radius(16), style: .continuous)
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(Typo.sans(21, .medium)).symbolRenderingMode(.monochrome).foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(tint.opacity(0.14)))
                    .overlay(Circle().strokeBorder(tint.opacity(0.32), lineWidth: 0.8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.serif(17, .regular)).tracking(-0.2)
                    Text(subtitle).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Typo.sans(12, .semibold)).foregroundStyle(Brand.inkTertiary).offset(x: hover.v ? 2 : 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity).frame(height: 96)
            .contentShape(shape)
            .glassSurface(shape, tint: hover.v ? tint.opacity(0.07) : nil)
            .scaleEffect(hover.v ? 1.01 : 1)
        }
        .buttonStyle(.plain).onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover.v = h } }
        .accessibilityLabel(title).accessibilityHint(subtitle)
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var query = Box("")

    /// Settings sections, then the pages the person hid that belong with sound and tools: they live here instead.
    private struct Entry: Hashable, Identifiable { var id: String; var title: String; var icon: String }
    private var entries: [Entry] {
        let all = SettingsSection.allCases.map { Entry(id: "s:" + $0.rawValue, title: $0.rawValue, icon: $0.icon) }
            + m.sidebar.hiddenTabs.filter { [.audio, .dsp, .deepDive, .rip, .convert, .cloud, .intelligence].contains($0) }.map { Entry(id: "p:" + $0.rawValue, title: $0.rawValue, icon: $0.icon) }
        let q = query.v.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
    private var currentID: String { m.settingsPage.map { "p:" + $0.rawValue } ?? "s:" + m.settingsSection.rawValue }
    private func choose(_ e: Entry) {
        if e.id.hasPrefix("p:") { m.settingsPage = Tab(rawValue: String(e.id.dropFirst(2))) }
        else { m.settingsPage = nil; m.settingsSection = SettingsSection(rawValue: String(e.id.dropFirst(2))) ?? .general }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            master.frame(width: 226)
            detail
        }
    }

    private var master: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary)
                TextField("Search settings", text: $query.v).textFieldStyle(.plain).font(Typo.sans(14))
            }
            .padding(.horizontal, 14).frame(height: 38).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.panel2)).padding(.bottom, 8)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entries) { e in
                        let on = e.id == currentID
                        Button { withAnimation(TabMotion.animation) { choose(e) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: e.icon).font(Typo.sans(14)).frame(width: 20)
                                Text(e.title).font(Typo.sans(14, on ? .medium : .regular))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).frame(height: 38)
                            .foregroundStyle(on ? Brand.ink : Brand.inkSecondary)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Brand.panel2 : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.top, 20).padding(.bottom, 16)
    }

    @ViewBuilder private var detail: some View {
        if let t = m.settingsPage, m.sidebar.isHidden(t) {
            PageScaffold(title: t.rawValue) {
                switch t {
                case .audio: AudioTab()
                case .dsp: DSPTab()
                case .deepDive: DeepDiveTab()
                case .intelligence: IntelligenceTab()
                default:
                    Card(title: t.rawValue, subtitle: "Hidden from the pages") { Button("Open \(t.rawValue)") { m.djMode = false; m.tab = t } }
                }
            }
        } else {
            PageScaffold(title: m.settingsSection.rawValue, trailing: { if m.settingsSection == .appearance, m.look != LookSettings.defaults { resetLook } }) {
                switch m.settingsSection {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .nowPlaying: NowPlayingSettings()
                case .miniPlayer: MiniPlayerSettings()
                case .sidebar: SidebarSettings()
                case .connect: ConnectTab()
                case .midi: MIDIPage()
                case .system: DiagnosticsTab()
                }
            }
            .id(m.settingsSection)
        }
    }

    private var resetLook: some View {
        HStack(spacing: 6) {
            Circle().fill(Brand.accent).frame(width: 6, height: 6)
            Text("Changed from default ·").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary)
            Button("Reset page") { withAnimation(Motion.glide) { m.look = LookSettings() } }.buttonStyle(.plain).font(Typo.sans(13, .medium)).foregroundStyle(Brand.accentText)
        }
    }
}

/// Appearance: a live preview of the look on top, then the themes and everything that changes how the interface looks. The preview and the changes
/// show at once; nothing here keeps running when the page is closed.
struct AppearanceSettings: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(spacing: 16) {
            preview
            Card(title: "Theme", subtitle: "Six dark themes and three soft light ones. The whole interface follows the one you pick") { ThemePicker() }
            if m.backdrop == .starlight { StarlightGroup() }
            if m.backdrop != .off {
                Card(title: "Backdrop strength", subtitle: "How far the cover's colours and the wash reach into the pages") {
                    LookSliderRow(title: "Strength", value: $m.look.backdrop, defaultValue: LookSettings.defaults.backdrop)
                }
            }
        }
    }

    /// The current look in one strip: what is playing (or a sample), its tags and the two buttons.
    private var preview: some View {
        let d = m.focusDisplay
        return HStack(spacing: 20) {
            CoverView(image: m.hero.image ?? m.focusItem?.thumb, palette: m.hero.palette, corner: 8).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(d?.title ?? "Harbour Lights").font(Typo.serif(17, .regular)).lineLimit(1)
                Text(d.map { $0.artist } ?? "Marlowe Quay").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
            }
            NowPlayingTags(place: .bar).frame(maxWidth: 260)
            Spacer(minLength: 8)
            Button { m.togglePlay() } label: { Text(m.isActive && m.status.state == .playing ? "Pause" : "Play") }.buttonStyle(.solid).disabled(m.items.isEmpty)
            Button { m.shuffle = m.shuffle == .off ? .normal : .off } label: { Text("Shuffle") }.buttonStyle(.rule)
            Text("Live preview").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 10).frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LinearGradient(colors: [m.hero.palette.accent.color.opacity(0.35), m.hero.palette.accent.color.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.panel2)))
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Layout", subtitle: "The same player, arranged for listening or for mixing") {
                SegmentedChoice(selection: $m.djMode, items: [false, true]) { $0 ? "DJ console" : "Normal" }.frame(maxWidth: 280)
                Note(text: "The DJ console has two decks, a mixer and a crossfader. You can switch at any time with the button in the top-right corner.")
            }
            Card(title: "Volume safety", subtitle: "A click on the volume line can raise the level only a little at a time, so a slip never makes it suddenly loud") {
                HStack {
                    Text("Never go above").frame(width: 110, alignment: .leading)
                    ValueSlider(value: Binding(get: { Double(m.volumeLimit) }, set: { m.volumeLimit = Float($0) }), in: 0.2...1, step: 0.05)
                    Text("\(Int(m.volumeLimit * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                Note(text: m.volumeLimit < 1 ? "Aureon's volume controls stop at \(Int(m.volumeLimit * 100))% of the device volume." : "No ceiling. Consider setting one if you use headphones.")
            }
            Card(title: "Artwork", subtitle: "Covers come from the file's own tags first (FLAC pictures, ID3, ALAC covr)") {
                Toggle("Look up missing covers and artist portraits online", isOn: $m.fetchMissingArt)
                Note(text: "Only the artist and album names are sent — to the iTunes Search API, MusicBrainz / Cover Art Archive, Deezer and Wikipedia. Results are cached on this Mac.")
            }
            Card(title: "Lyrics", subtitle: "Lyrics come from an .lrc file next to the song and from the file's own tags first") {
                LyricsSettingsToggle()
                Note(text: "Only the song's title, artist, album and length are sent, to LRCLIB (lrclib.net). Results are cached on this Mac. Writing lyrics by listening to a song is a separate, on-device feature in Intelligence, and only happens when you say yes for that song.")
            }
            Card(title: "About", subtitle: "") {
                HStack(spacing: 16) {
                    AppLogo(size: 56)
                    VStack(alignment: .leading, spacing: 2) { Text("Aureon").font(Typo.serif(17, .regular)); Text("An audiophile music player for the Mac").font(Typo.caption).foregroundStyle(Brand.inkSecondary) }
                }
            }
            Card(title: "Window", subtitle: "") {
                Button("Reset window size") { if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) { w.setContentSize(NSSize(width: 1080, height: 700)); w.center() } }
            }
        }
    }
}

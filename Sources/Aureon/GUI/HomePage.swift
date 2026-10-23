import SwiftUI

/// The landing page: what you were listening to, quick doors to Radio and Podcasts, and rails of albums.
struct HomePage: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    @EnvironmentObject var radio: RadioModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let l = m.library
        PageScaffold(title: "Home") {
            hero
            HStack(spacing: 16) {
                PromoTile(title: "Radio", subtitle: "Free stations from around the world, upscaled automatically", symbol: "dot.radiowaves.left.and.right", tint: Brand.accent) { m.tab = .radio }
                PromoTile(title: "Podcasts", subtitle: "Top shows, categories and every language", symbol: "mic.fill", tint: Brand.accent2) { m.tab = .podcasts }
            }
            if !l.recentAlbums.isEmpty { rail("Recently added", l.recentAlbums, more: .albums) }
            if !l.hiResAlbums.isEmpty { rail("Hi-Res albums", l.hiResAlbums, more: .albums) }
            if !radio.favorites.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Your stations").font(Typo.serif(19, .regular)); Spacer(); Button("See all") { radio.section = .favorites; m.tab = .radio }.buttonStyle(.plain).foregroundStyle(Brand.accent).font(Typo.sans(12.5, .medium)) }
                    ScrollView(.horizontal, showsIndicators: false) { HStack(alignment: .top, spacing: 16) { ForEach(radio.favorites) { StationCard(station: $0).frame(width: 140) } }.padding(.bottom, 4) }
                }
            }
            if l.stats.tracks == 0 { emptyLibrary }
        }
    }

    // MARK: hero

    /// The hero is a pane of glass over the album-colour backdrop: the cover's colours reach it from behind, nothing is painted on it.
    @ViewBuilder private var hero: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radius(20), style: .continuous)
        if let item = m.focusItem, let d = m.focusDisplay {
            HStack(spacing: 24) {
                CoverView(image: m.hero.image ?? item.thumb, palette: m.hero.palette, corner: 12, symbol: item.isStream ? "dot.radiowaves.left.and.right" : "music.note").frame(width: 172, height: 172)
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.isActive ? (item.isStream ? "ON AIR" : "NOW PLAYING") : "CONTINUE LISTENING").microLabel().foregroundStyle(Brand.accent)
                    Text(d.title).font(Typo.serif(28, .regular)).tracking(-0.5).lineLimit(2)
                    if !d.artist.isEmpty { Text(d.artist).font(Typo.sans(16, .medium)).foregroundStyle(Brand.inkSecondary).lineLimit(1) }
                    if !d.detail.isEmpty { Text(d.detail).font(Typo.sans(12.5)).foregroundStyle(Brand.inkTertiary).lineLimit(1) }
                    HStack(spacing: 8) {
                        RuleButton(title: m.isActive && m.status.state == .playing ? "Pause" : "Play", symbol: m.isActive && m.status.state == .playing ? "pause.fill" : "play.fill", filled: true) { m.togglePlay() }
                        RuleButton(title: "Now Playing", symbol: "waveform") { stage.open(m, reduceMotion: reduceMotion) }
                    }.padding(.top, 12)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 220)
            .glassSurface(shape, tint: m.hero.palette.accent.color.opacity(0.07))
        } else {
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AUREON").microLabel().foregroundStyle(Brand.accent)
                    Text("Listen without compromise.").font(Typo.serif(32, .regular)).tracking(-0.6)
                    Text("Bit-perfect playback, from your own library or from radio stations around the world.").font(Typo.sans(14)).foregroundStyle(Brand.inkSecondary)
                    HStack(spacing: 8) {
                        Button { chooseFolder() } label: { Label("Add Music Folder", systemImage: "folder.badge.plus").font(Typo.sans(12.5, .semibold)) }
                            .buttonStyle(.solid).tint(Brand.accent).controlSize(.large)
                        Button { m.tab = .radio } label: { Label("Browse Radio", systemImage: "dot.radiowaves.left.and.right").font(Typo.sans(12.5, .semibold)) }
                            .buttonStyle(.rule).controlSize(.large)
                    }.padding(.top, 8)
                }.padding(32)
            }
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 220).clipShape(shape)
            .glassSurface(shape)
        }
    }

    private var emptyLibrary: some View {
        Text("Your library is empty. Add a folder of music to see albums here.").font(Typo.callout).foregroundStyle(Brand.inkSecondary).padding(.top, 8)
    }

    private func rail(_ title: String, _ albums: [ReleaseDTO], more: Tab) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(Typo.serif(19, .regular))
                Spacer()
                Button("See all") { m.tab = more }.buttonStyle(.plain).foregroundStyle(Brand.accent).font(Typo.sans(12.5, .medium))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(albums) { a in AlbumCard(album: a) { m.tab = .albums; m.library.selectedID = a.id }.frame(width: 140) }
                }.padding(.bottom, 4)
            }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = "Choose the folder(s) that contain your music"
        DispatchQueue.main.async { if p.runModal() == .OK { p.urls.forEach { m.library.addFolder($0) } } }
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

    /// Settings sections, then the pages the person hid from the sidebar that belong with sound and tools: they live here instead.
    private struct Chip: Hashable, Identifiable { var id: String; var title: String; var icon: String }
    private var chips: [Chip] {
        SettingsSection.allCases.map { Chip(id: "s:" + $0.rawValue, title: $0.rawValue, icon: $0.icon) }
            + m.sidebar.hiddenTabs.filter { [.audio, .dsp, .deepDive, .rip, .convert, .cloud, .intelligence].contains($0) }.map { Chip(id: "p:" + $0.rawValue, title: $0.rawValue, icon: $0.icon) }
    }
    private var selection: Binding<Chip> {
        Binding(get: {
            let id = m.settingsPage.map { "p:" + $0.rawValue } ?? "s:" + m.settingsSection.rawValue
            return chips.first { $0.id == id } ?? chips[0]
        }, set: { c in
            if c.id.hasPrefix("p:") { m.settingsPage = Tab(rawValue: String(c.id.dropFirst(2))) }
            else { m.settingsPage = nil; m.settingsSection = SettingsSection(rawValue: String(c.id.dropFirst(2))) ?? .general }
        })
    }

    var body: some View {
        PageScaffold(title: "Settings") {
            SectionChips(items: chips, selection: selection, label: \.title, icon: \.icon)
            if let t = m.settingsPage, m.sidebar.isHidden(t) {
                switch t {
                case .audio: AudioTab()
                case .dsp: DSPTab()
                case .deepDive: DeepDiveTab()
                case .intelligence: IntelligenceTab()
                default:
                    Card(title: t.rawValue, subtitle: "Hidden from the sidebar") {
                        Button("Open \(t.rawValue)") { m.djMode = false; m.tab = t }
                    }
                }
            } else {
                switch m.settingsSection {
                case .general: GeneralSettings()
                case .sidebar: SidebarSettings()
                case .connect: ConnectTab()
                case .midi: MIDIPage()
                case .system: DiagnosticsTab()
                }
            }
        }
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Appearance", subtitle: "Colour themes: the whole interface follows the one you pick") {
                ThemePicker()
            }
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

import SwiftUI

/// The landing page: what you were listening to, quick doors to Radio and Podcasts, and rails of albums.
struct HomePage: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: AlbumArt
    @EnvironmentObject var radio: RadioModel

    var body: some View {
        let l = m.library
        PageScaffold(title: "Home") {
            hero
            HStack(spacing: 14) {
                PromoTile(title: "Radio", subtitle: "Free stations from around the world, upscaled automatically", symbol: "dot.radiowaves.left.and.right",
                          colors: [Color(red: 0.98, green: 0.30, blue: 0.40), Color(red: 1.0, green: 0.55, blue: 0.32)]) { m.tab = .radio }
                PromoTile(title: "Podcasts", subtitle: "Top shows, categories and every language", symbol: "mic.fill",
                          colors: [Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 0.95, green: 0.40, blue: 0.75)]) { m.tab = .podcasts }
            }
            if !l.recentAlbums.isEmpty { rail("Recently added", l.recentAlbums, more: .albums) }
            if !l.hiResAlbums.isEmpty { rail("Hi-Res albums", l.hiResAlbums, more: .albums) }
            if !radio.favorites.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Your stations").font(.system(size: 19, weight: .bold)); Spacer(); Button("See all") { radio.section = .favorites; m.tab = .radio }.buttonStyle(.plain).foregroundStyle(Brand.accent).font(.system(size: 12.5, weight: .medium)) }
                    ScrollView(.horizontal, showsIndicators: false) { HStack(alignment: .top, spacing: 16) { ForEach(radio.favorites) { StationCard(station: $0).frame(width: 140) } }.padding(.bottom, 4) }
                }
            }
            if l.stats.tracks == 0 { emptyLibrary }
        }
    }

    // MARK: hero

    @ViewBuilder private var hero: some View {
        if let item = m.focusItem, let d = m.focusDisplay {
            ZStack(alignment: .leading) {
                heroBackground
                HStack(spacing: 22) {
                    CoverView(image: m.hero.image ?? item.thumb, palette: m.hero.palette, corner: 12, symbol: item.isStream ? "dot.radiowaves.left.and.right" : "music.note").frame(width: 172, height: 172)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(m.isActive ? (item.isStream ? "ON AIR" : "NOW PLAYING") : "CONTINUE LISTENING").microLabel().foregroundStyle(.white.opacity(0.7))
                        Text(d.title).font(.system(size: 28, weight: .bold)).tracking(-0.5).foregroundStyle(.white).lineLimit(2)
                        if !d.artist.isEmpty { Text(d.artist).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1) }
                        if !d.detail.isEmpty { Text(d.detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1) }
                        HStack(spacing: 8) {
                            PillButton(title: m.isActive && m.status.state == .playing ? "Pause" : "Play", symbol: m.isActive && m.status.state == .playing ? "pause.fill" : "play.fill", filled: true) { m.togglePlay() }
                            PillButton(title: "Now Playing", symbol: "waveform") { m.tab = .player }
                        }.padding(.top, 10)
                    }
                    Spacer(minLength: 0)
                }.padding(24)
            }
            .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.8))
        } else {
            ZStack(alignment: .leading) {
                LinearGradient(colors: [Brand.accent, Brand.accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "waveform").font(.system(size: 220, weight: .ultraLight)).foregroundStyle(.white.opacity(0.12)).offset(x: 360, y: 10)
                VStack(alignment: .leading, spacing: 8) {
                    Text("AUREON").microLabel().foregroundStyle(.white.opacity(0.8))
                    Text("Listen without compromise.").font(.system(size: 32, weight: .bold)).tracking(-0.6).foregroundStyle(.white)
                    Text("Bit-perfect playback, from your own library or from radio stations around the world.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                    HStack(spacing: 8) {
                        Button { chooseFolder() } label: { Label("Add Music Folder", systemImage: "folder.badge.plus").font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(.white)).foregroundStyle(.black) }.buttonStyle(.plain)
                        Button { m.tab = .radio } label: { Label("Browse Radio", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(.black.opacity(0.25))).foregroundStyle(.white) }.buttonStyle(.plain)
                    }.padding(.top, 8)
                }.padding(28)
            }
            .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var heroBackground: some View {
        ZStack {
            LinearGradient(colors: [m.hero.palette.grid[0].color, m.hero.palette.grid[8].color], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let img = m.hero.image ?? m.focusItem?.thumb {
                GeometryReader { g in Image(nsImage: img).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped().blur(radius: 60).saturation(1.3).opacity(0.5) }
            }
            Color.black.opacity(0.25)
        }
    }

    private var emptyLibrary: some View {
        Text("Your library is empty. Add a folder of music to see albums here.").font(.callout).foregroundStyle(.secondary).padding(.top, 6)
    }

    private func rail(_ title: String, _ albums: [ReleaseDTO], more: Tab) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 19, weight: .bold))
                Spacer()
                Button("See all") { m.tab = more }.buttonStyle(.plain).foregroundStyle(Brand.accent).font(.system(size: 12.5, weight: .medium))
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
        if p.runModal() == .OK { p.urls.forEach { m.library.addFolder($0) } }
    }
}

struct PromoTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let colors: [Color]
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol).font(.system(size: 92, weight: .ultraLight)).foregroundStyle(.white.opacity(0.22)).offset(x: 150, y: -14).frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.3)
                    Text(subtitle).font(.system(size: 12)).opacity(0.9).lineLimit(2)
                }.foregroundStyle(.white).padding(16)
            }
            .frame(maxWidth: .infinity).frame(height: 112).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(hover.v ? 1.015 : 1)
        }
        .buttonStyle(.plain).onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover.v = h } }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        PageScaffold(title: "Settings") {
            SectionChips(items: SettingsSection.allCases, selection: $m.settingsSection, label: \.rawValue, icon: \.icon)
            switch m.settingsSection {
            case .general: GeneralSettings()
            case .connect: ConnectTab()
            case .system: DiagnosticsTab()
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
                Picker("", selection: $m.djMode) { Text("Normal").tag(false); Text("DJ console").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                Note(text: "The DJ console has two decks, a mixer and a crossfader. You can switch at any time with the button in the top-right corner.")
            }
            Card(title: "Volume safety", subtitle: "Volume controls move only when you grab the knob; a click elsewhere nudges by a few per cent") {
                HStack {
                    Text("Never go above").frame(width: 110, alignment: .leading)
                    Slider(value: Binding(get: { Double(m.volumeLimit) }, set: { m.volumeLimit = Float($0) }), in: 0.2...1, step: 0.05)
                    Text("\(Int(m.volumeLimit * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                Note(text: m.volumeLimit < 1 ? "Aureon's volume controls stop at \(Int(m.volumeLimit * 100))% of the device volume." : "No ceiling. Consider setting one if you use headphones.")
            }
            Card(title: "Artwork", subtitle: "Covers come from the file's own tags first (FLAC pictures, ID3, ALAC covr)") {
                Toggle("Look up missing covers and artist portraits online", isOn: $m.fetchMissingArt)
                Note(text: "Only the artist and album names are sent — to the iTunes Search API, MusicBrainz / Cover Art Archive, Deezer and Wikipedia. Results are cached on this Mac.")
            }
            Card(title: "Window", subtitle: "") {
                Button("Reset window size") { if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) { w.setContentSize(NSSize(width: 1080, height: 700)); w.center() } }
            }
        }
    }
}

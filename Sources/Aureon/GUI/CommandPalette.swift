import SwiftUI
import AppKit

// Quick find (⌘K): every page and the main actions, reachable by typing. The rail shows five destinations; this reaches all of the pages behind them,
// so no page of the old sidebar is out of reach.

enum PaletteAction: Hashable {
    case go(NavTarget)
    case togglePlay, next, previous, toggleQueue, showLyrics, addMusic
    case theme(String), appearance(AppearanceMode), backdrop(BackdropMode)
    case search(String)
    case sound(SoundSection), intensity(BackdropIntensity), glass(Bool), pureBlack(Bool), quickPanel, toggleAppearance, levelSpeakers
}

struct PaletteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let group: String
    let icon: String
    let action: PaletteAction
    /// Extra words that find it.
    var keywords = ""
}

enum PaletteCatalog {
    /// Every place the interface can go: each page, the DJ console and each section of the settings.
    static var destinations: [NavTarget] {
        Tab.allCases.map { NavTarget.tab($0) } + [.dj] + SettingsSection.allCases.map { NavTarget.settings($0) }
    }

    private static func name(_ t: NavTarget) -> String {
        switch t { case .tab(let tab): tab == .player ? "Now Playing" : tab.rawValue; case .dj: "DJ console"; case .settings(let s): "Settings · " + (s == .sidebar ? "Pages" : s == .system ? "System and diagnostics" : s.rawValue) }
    }

    private static func keywords(_ t: NavTarget) -> String {
        switch t {
        case .tab(let tab):
            switch tab {
            case .player: "now playing listen gallery cover lyrics"
            case .home: "home overview recently added"
            case .audio: "sound output pipeline dsd upsampling replaygain dither"
            case .dsp: "equaliser equalizer eq plug-ins audio unit"
            case .rooms: "output device speakers cast airplay zone remote chromecast sonos"
            case .rip: "cd ripping"
            case .convert: "transcode convert flac"
            case .cloud: "s3 b2 navidrome subsonic"
            case .intelligence: "ai models smart dj enhancer"
            case .abx: "blind test listening"
            case .folders: "files browse"
            case .deepDive: "credits biography discography"
            default: ""
            }
        case .dj: "mix decks crossfader turntable"
        case .settings(let s): s == .system ? "diagnostics system stethoscope quiet mode freeze recorder hardware path" : s == .cloud ? "s3 b2 navidrome subsonic storage" : s == .intelligence ? "models enhancer api keys" : ""
        }
    }

    /// The actions that are not places.
    static var actions: [PaletteItem] {
        var out: [PaletteItem] = [
            PaletteItem(id: "act:play", title: "Play or pause", group: "Playback", icon: "playpause", action: .togglePlay, keywords: "resume stop"),
            PaletteItem(id: "act:next", title: "Next song", group: "Playback", icon: "forward", action: .next, keywords: "skip"),
            PaletteItem(id: "act:previous", title: "Previous song", group: "Playback", icon: "backward", action: .previous, keywords: "back"),
            PaletteItem(id: "act:queue", title: "Show or hide the queue", group: "Playback", icon: "list.bullet", action: .toggleQueue, keywords: "up next"),
            PaletteItem(id: "act:lyrics", title: "Lyrics", group: "Playback", icon: "quote.bubble", action: .showLyrics),
            PaletteItem(id: "act:add", title: "Add a music folder", group: "Library", icon: "folder.badge.plus", action: .addMusic, keywords: "import scan"),
        ]
        out += Theme.families.map { PaletteItem(id: "theme:" + $0.id, title: "Colour · " + $0.name, group: "Appearance", icon: "paintpalette", action: .theme($0.id), keywords: "colour color theme family " + $0.blurb) }
        out += [PaletteItem(id: "black:on", title: "Pure black · On", group: "Appearance", icon: "circle.fill", action: .pureBlack(true), keywords: "amoled oled black dark"),
                PaletteItem(id: "black:off", title: "Pure black · Off", group: "Appearance", icon: "circle", action: .pureBlack(false), keywords: "amoled oled black dark")]
        out += AppearanceMode.pickerOrder.map { PaletteItem(id: "appearance:" + $0.rawValue, title: "Appearance · " + $0.title, group: "Appearance", icon: $0.icon, action: .appearance($0), keywords: "dark light day night") }
        out += BackdropMode.allCases.map { PaletteItem(id: "backdrop:" + $0.rawValue, title: "Backdrop · " + $0.title, group: "Appearance", icon: "circle.lefthalf.filled", action: .backdrop($0), keywords: "background gradient blur stars") }
        out += SoundSection.allCases.map { PaletteItem(id: "sound:" + $0.rawValue, title: "Sound · " + $0.title, group: "Atelier", icon: $0.icon, action: .sound($0), keywords: "sound audio settings " + $0.blurb) }
        out += BackdropIntensity.allCases.map { PaletteItem(id: "intensity:" + $0.rawValue, title: "Album backdrop · " + $0.title, group: "Appearance", icon: "circle.lefthalf.filled", action: .intensity($0), keywords: "intensity gradient blur colour") }
        out += [PaletteItem(id: "glass:on", title: "Glass accents · On", group: "Appearance", icon: "square.on.square", action: .glass(true), keywords: "liquid glass blur translucent"),
                PaletteItem(id: "glass:off", title: "Glass accents · Off", group: "Appearance", icon: "square", action: .glass(false), keywords: "liquid glass flat opaque")]
        out += [PaletteItem(id: "act:levelSpeakers", title: "Level speakers", group: "Rooms", icon: "slider.horizontal.3", action: .levelSpeakers, keywords: "balance calibrate multi output loudness volume match ambience stereo")]
        out += [PaletteItem(id: "act:quickpanel", title: "Quick controls: output device and sound", group: "Sound", icon: "hifispeaker", action: .quickPanel, keywords: "output device switch speakers headphones dac volume exclusive"),
                PaletteItem(id: "act:toggleAppearance", title: "Switch between light and dark", group: "Appearance", icon: "circle.lefthalf.filled", action: .toggleAppearance, keywords: "dark light day night mode theme")]
        return out
    }

    /// All items, places first.
    static var all: [PaletteItem] {
        destinations.map { t in PaletteItem(id: t.id, title: name(t), group: t.destination.rawValue, icon: t.icon, action: .go(t), keywords: keywords(t)) } + actions
    }

    /// The items that match `query`, best first; with text typed, a library search is offered last.
    static func matches(_ query: String) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        func score(_ i: PaletteItem) -> Int? {
            let t = i.title.lowercased()
            let hay = (i.title + " " + i.group + " " + i.keywords).lowercased()
            if t.hasPrefix(q) { return 0 }
            if t.contains(q) { return 1 }
            if q.split(separator: " ").allSatisfy({ hay.contains($0) }) { return 2 }
            return nil
        }
        let found = all.compactMap { i in score(i).map { (i, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        return found + [PaletteItem(id: "act:search", title: "Search the library for “\(query.trimmingCharacters(in: .whitespaces))”", group: "Library", icon: "magnifyingglass", action: .search(query.trimmingCharacters(in: .whitespaces)))]
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var query = Box("")
    @StateObject private var selected = Box(0)
    @FocusState private var focused: Bool

    private var items: [PaletteItem] { PaletteCatalog.matches(query.v) }

    var body: some View {
        let list = items
        ZStack(alignment: .top) {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Image(systemName: "magnifyingglass").font(Typo.sans(15, .light)).foregroundStyle(Brand.inkSecondary)
                    TextField("Find a page or an action", text: $query.v).textFieldStyle(.plain).font(Typo.serif(20, .regular)).focused($focused)
                        .onSubmit { run(list) }
                    Text("esc").font(Typo.mono(10, .regular)).foregroundStyle(Brand.inkTertiary)
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
                Rule()
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                                PaletteRow(item: item, selected: i == selected.v)
                                    .id(item.id)
                                    .onTapGesture { selected.v = i; run(list) }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selected.v) { _, i in if list.indices.contains(i) { proxy.scrollTo(list[i].id) } }
                }
            }
            .frame(width: 560)
            .glassAccent()
            .padding(.top, 96)
            .onKeyPress(.downArrow) { selected.v = min(max(0, list.count - 1), selected.v + 1); return .handled }
            .onKeyPress(.upArrow) { selected.v = max(0, selected.v - 1); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onChange(of: query.v) { _, _ in selected.v = 0 }
            .onAppear { focused = true }
        }
        .accessibilityAddTraits(.isModal)
    }

    private func close() { withAnimation(Motion.glide) { m.showPalette = false } }

    private func run(_ list: [PaletteItem]) {
        guard list.indices.contains(selected.v) else { return }
        let item = list[selected.v]
        close()
        PaletteRunner.run(item.action, m: m, stage: stage, reduceMotion: reduceMotion)
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: item.icon).font(Typo.sans(13, .light)).frame(width: 20).foregroundStyle(selected ? Brand.accentText : Brand.inkSecondary)
            Text(item.title).font(Typo.sans(14, selected ? .medium : .regular)).foregroundStyle(selected ? Brand.ink : Brand.inkSecondary).lineLimit(1)
            Spacer(minLength: 16)
            Text(item.group).font(Typo.sans(10, .regular)).tracking(Typo.microTracking).textCase(.uppercase).foregroundStyle(Brand.inkTertiary)
        }
        .padding(.horizontal, 24).padding(.vertical, 12).contentShape(Rectangle())
        .background(Rectangle().fill(Brand.ink.opacity(selected ? 0.06 : 0)))
        .overlay(alignment: .leading) { Rectangle().fill(Brand.gradientVertical).frame(width: 2).opacity(selected ? 1 : 0) }
    }
}

/// What each palette action does.
@MainActor
enum PaletteRunner {
    static func run(_ a: PaletteAction, m: PlayerModel, stage: StageModel, reduceMotion: Bool) {
        switch a {
        case .go(let t): withAnimation(Motion.page) { m.go(t) }
        case .togglePlay: m.togglePlay()
        case .next: m.player.send(.next)
        case .previous: m.player.send(.previous)
        case .toggleQueue: withAnimation(Motion.carpet) { m.showQueue.toggle() }
        case .showLyrics: stage.showLyrics(m, reduceMotion: reduceMotion)
        case .addMusic:
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
            p.message = "Choose the folder(s) that contain your music"
            // after the action has returned: a modal loop run inside a SwiftUI action can leave the window unresponsive
            DispatchQueue.main.async { if p.runModal() == .OK { p.urls.forEach { m.library.addFolder($0) } } }
        case .theme(let id): withAnimation(Motion.glide) { m.choose(family: id) }
        case .appearance(let mode): withAnimation(Motion.glide) { m.appearance = mode }
        case .backdrop(let mode): m.backdrop = mode
        case .sound(let section): withAnimation(Motion.page) { m.showSound(section) }
        case .intensity(let level): m.backdrop = .album; m.backdropIntensity = level
        case .glass(let on): m.glassAccents = on
        case .pureBlack(let on): m.look.pureBlack = on
        case .quickPanel: m.quickPanel = .rail
        case .levelSpeakers: m.showLevelSpeakers()
        case .toggleAppearance: m.toggleAppearance(from: nil)
        case .search(let q): m.searchText = q; withAnimation(Motion.page) { m.go(.tab(.search)) }
        }
    }
}

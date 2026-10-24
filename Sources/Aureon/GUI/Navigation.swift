import SwiftUI

// The shape of the interface: a top bar (Home, search, the output, Settings), a rail of five destinations on the left, and Now Playing as the
// whole window. Every page of the old sidebar belongs to one of them, and the command palette (⌘K) reaches all of them, so nothing is out of reach.
//
//   HOME         the day's mix: what to play now, from the time and your history
//   LIBRARY      everything in the collection: albums, artists, songs, the classical views, folders
//   PLAYLISTS    playlists and liked songs
//   RADIO        stations and podcasts
//   ROOMS        where the sound goes: output devices, speaker groups, cast, multi-room zones, remote control
//   SOUND        the workshop: sound, equaliser, DJ, ripping, converting, cloud sources, smart features, ABX, diagnostics
//   (gear)       settings
//   NOW PLAYING  the whole window: the song

enum RailDestination: String, CaseIterable, Identifiable {
    case listen = "Now Playing", home = "Home", library = "Library", playlists = "Playlists", radio = "Radio", rooms = "Rooms", sound = "Sound", settings = "Settings"
    var id: String { rawValue }

    /// The five on the rail, top to bottom. Home and Settings sit in the top bar.
    static let rail: [RailDestination] = [.library, .playlists, .radio, .rooms, .sound]

    /// The pages that belong to the destination.
    var tabs: [Tab] {
        switch self {
        case .listen: [.player]
        case .home: [.home, .search]
        case .library: [.albums, .artists, .songs, .composers, .works, .conductors, .ensembles, .folders, .deepDive]
        case .playlists: [.playlists, .liked]
        case .radio: [.radio, .podcasts]
        case .rooms: [.rooms]
        case .sound: [.audio, .dsp, .rip, .convert, .cloud, .intelligence, .abx]
        case .settings: [.settings]
        }
    }

    /// The destination a page belongs to.
    static func of(_ t: Tab) -> RailDestination { allCases.first { $0.tabs.contains(t) } ?? .library }

    /// The chips along the top of the destination's pages: every page of it, in one line (there is no overflow menu; if the window is too narrow the line scrolls).
    var subNav: [NavTarget] {
        switch self {
        case .library: [.tab(.albums), .tab(.artists), .tab(.songs), .tab(.composers), .tab(.works), .tab(.conductors), .tab(.ensembles), .tab(.folders), .tab(.deepDive)]
        case .playlists: [.tab(.playlists), .tab(.liked)]
        case .radio: [.tab(.radio), .tab(.podcasts)]
        case .sound: [.tab(.audio), .tab(.dsp), .dj, .tab(.rip), .tab(.convert), .tab(.cloud), .tab(.intelligence), .tab(.abx), .settings(.system)]
        default: []
        }
    }

    /// The symbol on the rail.
    var icon: String {
        switch self {
        case .listen: "play.circle"; case .home: "house"; case .library: "square.stack"; case .playlists: "music.note.list"
        case .radio: "dot.radiowaves.left.and.right"; case .rooms: "hifispeaker.2"; case .sound: "slider.vertical.3"; case .settings: "gearshape"
        }
    }

    /// Where choosing the destination goes: the page of it that was open last, else its first.
    var home: NavTarget { switch self { case .sound: .tab(.audio); case .library: .tab(.albums); default: .tab(tabs[0]) } }
}

/// Somewhere to go: a page, the DJ console, or a section of the settings.
enum NavTarget: Hashable, Identifiable {
    case tab(Tab), dj, settings(SettingsSection)

    var id: String {
        switch self { case .tab(let t): "tab:" + t.rawValue; case .dj: "dj"; case .settings(let s): "settings:" + s.rawValue }
    }

    /// The short, plain name used in the sub-header and the palette.
    var title: String {
        switch self {
        case .tab(let t):
            switch t {
            case .home: "Overview"; case .liked: "Liked"; case .audio: "Sound"; case .dsp: "Equaliser"; case .abx: "ABX Test"; case .rip: "Rip CD"; case .deepDive: "Deep Dive"
            case .player: "Now Playing"; default: t.rawValue
            }
        case .dj: "DJ"
        case .settings(let s): s == .system ? "Diagnostics" : s.rawValue
        }
    }

    var destination: RailDestination {
        switch self { case .tab(let t): RailDestination.of(t); case .dj: .sound; case .settings(let s): s == .system ? .sound : .settings }
    }

    var icon: String {
        switch self { case .tab(let t): t.icon; case .dj: "dial.medium"; case .settings(let s): s.icon }
    }
}

extension PlayerModel {
    /// Goes there. Leaves the DJ console unless that is where it is going.
    func go(_ target: NavTarget) {
        switch target {
        case .tab(let t): djMode = false; settingsPage = nil; tab = t
        case .dj: djMode = true
        case .settings(let s): djMode = false; settingsPage = nil; settingsSection = s; tab = .settings
        }
    }

    /// Whether the target is the one on screen.
    func isCurrent(_ target: NavTarget) -> Bool {
        switch target {
        case .tab(let t): return !djMode && tab == t
        case .dj: return djMode
        case .settings(let s): return !djMode && tab == .settings && settingsSection == s
        }
    }
}

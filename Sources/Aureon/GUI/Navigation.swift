import SwiftUI

// The shape of the interface: five destinations on a slim rail across the top. Every page of the old sidebar belongs to one of them, and the command
// palette (⌘K) reaches all of them, so nothing is out of reach.
//
//   NOW PLAYING  the Gallery: the song, the whole window
//   COLLECTION   the library and everything to play from it: albums, artists, songs, playlists, radio, podcasts, the classical views, folders
//   ROOMS        where the sound goes: output devices, speaker groups, cast, multi-room zones, remote control
//   ATELIER      the workshop: sound, equaliser, DJ, ripping, converting, cloud sources, intelligence, ABX, diagnostics
//   (gear)       settings

enum RailDestination: String, CaseIterable, Identifiable {
    case listen = "Now Playing", collection = "Collection", rooms = "Rooms", atelier = "Atelier", settings = "Settings"
    var id: String { rawValue }

    /// The pages that belong to the destination.
    var tabs: [Tab] {
        switch self {
        case .listen: [.player]
        case .collection: [.home, .albums, .artists, .songs, .playlists, .liked, .radio, .podcasts, .composers, .works, .conductors, .ensembles, .folders, .deepDive, .search]
        case .rooms: [.rooms]
        case .atelier: [.audio, .dsp, .rip, .convert, .cloud, .intelligence, .abx]
        case .settings: [.settings]
        }
    }

    /// The destination a page belongs to.
    static func of(_ t: Tab) -> RailDestination { allCases.first { $0.tabs.contains(t) } ?? .collection }

    /// The quiet sub-header of the destination: every page of it, in one line (there is no overflow menu; if the window is too narrow the line scrolls).
    var subNav: [NavTarget] {
        switch self {
        case .collection:
            [.tab(.albums), .tab(.artists), .tab(.songs), .tab(.playlists), .tab(.liked), .tab(.radio), .tab(.podcasts),
             .tab(.home), .tab(.composers), .tab(.works), .tab(.conductors), .tab(.ensembles), .tab(.folders), .tab(.deepDive), .tab(.search)]
        case .atelier:
            [.tab(.audio), .tab(.dsp), .dj, .tab(.rip), .tab(.convert), .tab(.cloud), .tab(.intelligence), .tab(.abx), .settings(.system)]
        default: []
        }
    }

    /// Where choosing the destination goes: the page of it that was open last, else its first.
    var home: NavTarget { switch self { case .collection: .tab(.albums); case .atelier: .tab(.audio); default: .tab(tabs[0]) } }
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
        switch self { case .tab(let t): RailDestination.of(t); case .dj: .atelier; case .settings(let s): s == .system ? .atelier : .settings }
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

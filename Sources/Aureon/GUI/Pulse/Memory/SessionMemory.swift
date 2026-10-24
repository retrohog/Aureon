import SwiftUI

// What Aureon remembers between launches: the song and where it was, the queue, the page and where it was scrolled, the window's size and place on each
// display, the output. Everything is plain values with the decisions in pure functions (what to restore, where a window goes), so they are testable; the
// model and the app delegate only carry them out. The volume is deliberately not remembered: it belongs to the device, and nothing in the app sets it
// except the listener's own hand.

/// What happens to playback when Aureon opens.
enum ResumeMode: String, CaseIterable, Identifiable, Codable {
    case paused, playing, ask, fresh
    var id: String { rawValue }
    var title: String { switch self { case .paused: "Paused"; case .playing: "Playing"; case .ask: "Ask me"; case .fresh: "Start fresh" } }
    var blurb: String {
        switch self {
        case .paused: "The last song is ready where you left it, and waits for Play."
        case .playing: "The last song carries on where you left it."
        case .ask: "A small card offers to continue, or to start fresh."
        case .fresh: "Nothing is queued; Home is the first thing you see."
        }
    }
}

struct MemorySettings: Codable, Equatable {
    var resume = ResumeMode.paused
    var rememberQueue = true
    var rememberPage = true
    var rememberWindow = true
    var rememberOutput = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = MemorySettings()
        resume = try c.decodeIfPresent(ResumeMode.self, forKey: .resume) ?? d.resume
        rememberQueue = try c.decodeIfPresent(Bool.self, forKey: .rememberQueue) ?? d.rememberQueue
        rememberPage = try c.decodeIfPresent(Bool.self, forKey: .rememberPage) ?? d.rememberPage
        rememberWindow = try c.decodeIfPresent(Bool.self, forKey: .rememberWindow) ?? d.rememberWindow
        rememberOutput = try c.decodeIfPresent(Bool.self, forKey: .rememberOutput) ?? d.rememberOutput
    }
    private enum Keys: String, CodingKey { case resume, rememberQueue, rememberPage, rememberWindow, rememberOutput }
}

/// The state written to disk (a few hundred bytes plus the queue's paths).
struct SessionRecord: Codable, Equatable {
    var queue: [String] = []
    /// The index in `queue` of the song that was playing or ready.
    var current: Int?
    var position = 0.0
    var duration = 0.0
    var tab = Tab.home.rawValue
    var settingsSection = SettingsSection.general.rawValue
    /// The album, artist or other item that was open on a Library page.
    var selectedID: String?
    var deviceUID: String?
    var savedAt = 0.0
    /// Where each page was scrolled to (see `ScrollMemory`).
    var scroll: [String: Double] = [:]

    static let storageKey = "aureon.session.v1"
    /// How many songs of the queue are written: the ones around the current song.
    static let queueLimit = 600

    static func load(_ d: UserDefaults = .standard) -> SessionRecord? { d.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) } }
    func save(_ d: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.storageKey) } }
    static func forget(_ d: UserDefaults = .standard) { d.removeObject(forKey: storageKey) }

    /// A record from the queue as it is now: only songs that can be started again (no radio), at most `queueLimit` of them around the current one.
    static func make(items: [(path: String, isStream: Bool)], currentID: Int?, position: Double, duration: Double, tab: Tab, section: SettingsSection, selectedID: String?, deviceUID: String?, scroll: [String: Double] = [:], now: Double) -> SessionRecord {
        var paths: [String] = [], cur: Int?
        for (i, it) in items.enumerated() where !it.isStream {
            if i == currentID { cur = paths.count }
            paths.append(it.path)
        }
        if paths.count > queueLimit {
            let centre = cur ?? 0
            let lo = max(0, min(centre - queueLimit / 4, paths.count - queueLimit))
            paths = Array(paths[lo..<(lo + queueLimit)]); cur = cur.map { $0 - lo }.flatMap { (0..<queueLimit).contains($0) ? $0 : nil }
        }
        return SessionRecord(queue: paths, current: cur, position: position.isFinite ? max(0, position) : 0, duration: duration.isFinite ? max(0, duration) : 0, tab: tab.rawValue,
                             settingsSection: section.rawValue, selectedID: selectedID, deviceUID: deviceUID, savedAt: now, scroll: scroll)
    }
}

/// What to do with a record at launch.
struct SessionRestore: Equatable {
    var paths: [String]
    var current: Int?
    var position: Double
    var duration: Double
    var autoplay: Bool
    var offer: Bool
    var tab: Tab?
    var section: SettingsSection
    var selectedID: String?
    var deviceUID: String?
    var scroll: [String: Double] = [:]
}

enum SessionPlan {
    /// The restore for `record` under `memory`. Songs whose files are gone are left out (and the current index follows); a position at or near the end
    /// starts the song again; with Start fresh nothing is queued. Pages are restored when asked, whatever the resume mode.
    static func restore(_ record: SessionRecord?, memory: MemorySettings, exists: (String) -> Bool) -> SessionRestore? {
        guard let r = record else { return nil }
        var paths: [String] = [], cur: Int?
        if memory.resume != .fresh, memory.rememberQueue {
            for (i, p) in r.queue.enumerated() where RemoteMedia.isRemote(p) || exists(p) {
                if i == r.current { cur = paths.count }
                paths.append(p)
            }
        }
        var position = cur == nil ? 0 : r.position
        if r.duration > 0, position >= r.duration - 1 { position = 0 }
        let tab = memory.rememberPage ? Tab(rawValue: r.tab) : nil
        let playable = !paths.isEmpty
        if playable && cur == nil { cur = 0; position = 0 }
        return SessionRestore(paths: paths, current: cur, position: position, duration: position == 0 ? 0 : r.duration,
                              autoplay: playable && memory.resume == .playing, offer: playable && memory.resume == .ask,
                              tab: tab, section: memory.rememberPage ? SettingsSection(rawValue: r.settingsSection) ?? .general : .general,
                              selectedID: memory.rememberPage ? r.selectedID : nil, deviceUID: memory.rememberOutput ? r.deviceUID : nil, scroll: memory.rememberPage ? r.scroll : [:])
    }
}

/// The place and size of the main window on each display.
struct WindowMemory: Codable, Equatable {
    /// display id → [x, y, width, height]
    var frames: [String: [Double]] = [:]
    /// The display the window was on last.
    var lastDisplay: String?

    static let storageKey = "aureon.windowFrames.v1"
    static func load(_ d: UserDefaults = .standard) -> WindowMemory { d.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(WindowMemory.self, from: $0) } ?? WindowMemory() }
    func save(_ d: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.storageKey) } }
    static func forget(_ d: UserDefaults = .standard) { d.removeObject(forKey: storageKey) }

    mutating func record(_ frame: CGRect, display: String) { frames[display] = [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]; lastDisplay = display }

    /// The frame to open with: the one remembered for the display the window will appear on (the last one used when that is not known), kept on a screen of
    /// `visible` (the visible frames of the displays that are connected, keyed by display id) and no smaller than `minimum`.
    func frame(display: String?, visible: [String: CGRect], minimum: CGSize) -> CGRect? {
        guard let key = [display, lastDisplay].compactMap({ $0 }).first(where: { frames[$0] != nil }), let a = frames[key], a.count == 4 else { return nil }
        var f = CGRect(x: a[0], y: a[1], width: max(minimum.width, a[2]), height: max(minimum.height, a[3]))
        let screens = Array(visible.values)
        guard !screens.isEmpty else { return f }
        // a window larger than its screen is brought down to it
        let home = visible[key] ?? screens.max { $0.width * $0.height < $1.width * $1.height }!
        f.size.width = min(f.width, home.width); f.size.height = min(f.height, home.height)
        if let o = MiniSettings.onScreen(origin: f.origin, size: f.size, screens: screens) { f.origin = o }
        return f
    }
}

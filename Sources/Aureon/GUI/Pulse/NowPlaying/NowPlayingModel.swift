import SwiftUI

// What Now Playing knows about the song beyond the queue: the layouts it can take, what the credits say, the steps of the signal path and what is next.
// All of it is plain values made by pure functions, so it can be tested; the views only place it.

/// The ways Now Playing can be laid out. Each one is a separate view; the choice is made in Settings → Now Playing and remembered.
enum NowPlayingLayout: String, CaseIterable, Identifiable {
    case stage, classic, fullBleed = "fullbleed", carousel, chillax, poster, turntable

    var id: String { rawValue }
    var title: String {
        switch self { case .stage: "Stage"; case .classic: "Classic"; case .fullBleed: "Full-bleed"; case .carousel: "Carousel"; case .chillax: "Chillax"; case .poster: "Poster"; case .turntable: "Turntable" }
    }
    var blurb: String {
        switch self {
        case .stage: "The words, large and centred; the song at the foot of the screen"
        case .classic: "A large cover on the left; the words, queue and signal path on the right"
        case .fullBleed: "The cover is the whole screen; the title is set very large"
        case .carousel: "The cover among its neighbours in the queue, the words beneath"
        case .chillax: "A big cover and a very large title, with the queue as a shelf along the bottom"
        case .poster: "A very large title on a strict grid, three lines of words, and the cover with its credits and the next song beside it"
        case .turntable: "A record that turns on a platter while the music plays, with a tonearm that follows the song; the words and the queue beside it"
        }
    }
    /// The layouts that have a row of tabs (Lyrics, Up next, Credits, Signal path) over the middle of the screen.
    var hasTabs: Bool { self == .stage || self == .classic }

    /// The default: Chillax.
    static let standard = NowPlayingLayout.chillax
    /// A saved id (also those of layouts that do not exist yet) read as a layout. Lumen was folded into Classic (its queue column is part of Classic now);
    /// Orbit is gone; anything else unknown is the default.
    static func resolve(_ raw: String?) -> NowPlayingLayout {
        if raw == "lumen" { return .classic }
        return raw.flatMap(NowPlayingLayout.init(rawValue:)) ?? .standard
    }
}

/// What the middle of Stage and Classic shows.
enum NowPlayingTab: String, CaseIterable, Identifiable {
    case lyrics, upNext, credits, signal
    var id: String { rawValue }
    var title: String { switch self { case .lyrics: "Lyrics"; case .upNext: "Up next"; case .credits: "Credits"; case .signal: "Signal path" } }
}

/// One line of the credits: "Written by" and who.
struct NPCredit: Equatable, Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

enum NPCredits {
    /// The credits of a song in reading order: writers, producers, engineers, the classical roles, then each instrument. Names are joined with commas and
    /// listed once; roles nobody has are left out.
    static func lines(_ credits: [CreditDTO]) -> [NPCredit] {
        func names(_ roles: [CreditRole]) -> [String] {
            let wanted = Set(roles.map(\.rawValue))
            var seen = Set<String>(), out: [String] = []
            for c in credits where wanted.contains(c.role) { if seen.insert(c.name).inserted { out.append(c.name) } }
            return out
        }
        var out: [NPCredit] = []
        func add(_ label: String, _ roles: [CreditRole]) { let n = names(roles); if !n.isEmpty { out.append(NPCredit(label: label, value: n.joined(separator: ", "))) } }
        add("Written by", [.composer, .lyricist])
        add("Produced by", [.producer])
        add("Engineered by", [.engineer])
        add("Arranged by", [.arranger])
        add("Conductor", [.conductor])
        add("Ensemble", [.ensemble])
        add("Remixed by", [.remixer])
        add("Featuring", [.featured])
        // soloists and performers with an instrument: one line per instrument
        var byInstrument: [(String, [String])] = []
        for c in credits where [CreditRole.soloist.rawValue, CreditRole.performer.rawValue].contains(c.role) {
            let key = (c.instrument?.isEmpty == false ? c.instrument! : (c.role == CreditRole.soloist.rawValue ? "Soloist" : "Performer"))
            let label = key.prefix(1).uppercased() + key.dropFirst()
            if let i = byInstrument.firstIndex(where: { $0.0 == label }) { if !byInstrument[i].1.contains(c.name) { byInstrument[i].1.append(c.name) } }
            else { byInstrument.append((label, [c.name])) }
        }
        for (label, who) in byInstrument { out.append(NPCredit(label: label, value: who.joined(separator: ", "))) }
        return out
    }

    /// "Written by A, B · Produced by C": the first few credits on one line.
    static func line(_ lines: [NPCredit], limit: Int = 3) -> String {
        lines.prefix(limit).map { "\($0.label) \($0.value)" }.joined(separator: " · ")
    }
}

/// One step of the signal path: what it is and what it does.
struct NPSignalStep: Equatable, Identifiable {
    var title: String
    var detail: String
    var id: String { title }
}

enum NPSignal {
    static func rate(_ hz: Double) -> String { hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000))" : String(format: "%.1f", hz / 1000) }

    /// Source, player and output as three steps (processing stages, when there are any, take the place of the player's line).
    static func steps(source: StreamInfo?, output: StreamInfo?, stages: [String], bitPerfect: Bool, exclusive: Bool, device: String) -> [NPSignalStep] {
        guard let source else { return [] }
        let bits = source.sourceBits == 1 ? "DSD" : "\(source.sourceBits)-bit"
        var out = [NPSignalStep(title: "Source", detail: "\(source.codec) · \(bits) / \(rate(source.sourceRate ?? source.sampleRate)) kHz")]
        out.append(NPSignalStep(title: "Player", detail: stages.isEmpty ? (bitPerfect ? "Bit-perfect, no resampling" : "Untouched") : stages.joined(separator: " · ")))
        var dest = (exclusive ? "Exclusive mode · " : "") + (device.isEmpty ? "Output" : device)
        if let o = output { dest += " · \(rate(o.sampleRate)) kHz" }
        out.append(NPSignalStep(title: "Output", detail: dest))
        return out
    }

    /// The same, as one line: "FLAC 24/96 → bit-perfect → exclusive mode → DAC-1 · 192 kHz".
    static func line(source: StreamInfo?, output: StreamInfo?, stages: [String], bitPerfect: Bool, exclusive: Bool, device: String) -> String {
        guard let source else { return "" }
        var parts = ["\(source.codec) \(source.sourceBits == 1 ? "DSD" : "\(source.sourceBits)")/\(rate(source.sourceRate ?? source.sampleRate))"]
        parts.append(stages.isEmpty ? (bitPerfect ? "bit-perfect" : "untouched") : stages.joined(separator: " + ").lowercased())
        if exclusive { parts.append("exclusive mode") }
        var dest = device.isEmpty ? "output" : device
        if let o = output { dest += " · \(rate(o.sampleRate)) kHz" }
        parts.append(dest)
        return parts.joined(separator: " → ")
    }
}

enum NPQueue {
    /// What comes after the song that is playing, in queue order (at most `limit`). When nothing is playing, the start of the queue.
    static func upNext<T: Identifiable>(_ items: [T], current: T.ID?, limit: Int) -> [T] where T.ID: Equatable {
        guard !items.isEmpty else { return [] }
        let start = current.flatMap { id in items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        return Array(items.dropFirst(start).prefix(limit))
    }
    /// The song before and the song after the current one (the covers beside the carousel's centre).
    static func neighbours<T: Identifiable>(_ items: [T], current: T.ID?) -> (previous: T?, next: T?) where T.ID: Equatable {
        guard let id = current, let i = items.firstIndex(where: { $0.id == id }) else { return (nil, items.first) }
        return (i > 0 ? items[i - 1] : nil, i + 1 < items.count ? items[i + 1] : nil)
    }
}

/// The song in focus as the library knows it (credits, album, year): read off the main thread when the song changes.
@MainActor
final class NPTrackInfo: ObservableObject {
    @Published private(set) var track: TrackDTO?
    @Published private(set) var credits: [NPCredit] = []
    private var path: String?
    private var task: Task<Void, Never>?

    func load(path: String?, store: LibraryStore?) {
        guard path != self.path else { return }
        self.path = path
        task?.cancel()
        guard let path, let store else { track = nil; credits = []; return }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let t = store.track(path: path)
            let lines = t.map { NPCredits.lines($0.credits) } ?? []
            await MainActor.run { guard let self, self.path == path else { return }; self.track = t; self.credits = lines }
        }
    }
}

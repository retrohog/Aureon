import Foundation
import Synchronization

// The single place that says whether a smart feature may run. Settings live in `IntelligenceSettings` (saved), the page that edits them is
// `IntelligenceTab`, and `IntelligenceCenter` applies them to the running app. Everything else, on any thread, asks `IntelligenceGate`.

/// Every feature in Aureon that runs a learned model.
enum IntelligenceFeature: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Picks a set of songs from a request in words (language model: on-device MLX helper or an API).
    case smartDJ
    /// Finds songs by meaning ("rainy sunday piano") with text embeddings (on-device or an API).
    case semanticSearch
    /// The real-time smart upscaler (engine in `Upscaler/`). Strictly on-device: never routed to an API.
    case audioEnhancer
    /// Smart Shuffle's transition network, which orders a queue so each song flows into the next.
    case smartShuffle
    /// The DJ console's Smart Remixer, which learns which moves you like.
    case remixer
    /// Builds a playlist from a request in plain words ("a 2-hour mix of late-night, low-energy acoustic tracks"): language model on this Mac or an API.
    case naturalPlaylists
    /// Writes time-synced lyrics for a song that has none, by listening to it with a small speech model (Whisper) on this Mac. Strictly on-device.
    case lyricsGeneration

    var id: String { rawValue }
    fileprivate var bit: UInt32 { switch self { case .smartDJ: 1 << 0; case .semanticSearch: 1 << 1; case .audioEnhancer: 1 << 2; case .smartShuffle: 1 << 3; case .remixer: 1 << 4; case .naturalPlaylists: 1 << 5; case .lyricsGeneration: 1 << 6 } }

    /// Features whose work is text and can be sent to a model behind an API. Audio never leaves this Mac.
    var allowsAPI: Bool { self == .smartDJ || self == .semanticSearch || self == .naturalPlaylists }

    var title: String {
        switch self {
        case .smartDJ: "Smart DJ"
        case .semanticSearch: "Semantic Search"
        case .audioEnhancer: "Real-Time Audio Enhancer"
        case .smartShuffle: "Smart Shuffle network"
        case .remixer: "Smart Remixer"
        case .naturalPlaylists: "Natural-Language Playlists"
        case .lyricsGeneration: "Lyrics Generation"
        }
    }

    var icon: String {
        switch self {
        case .smartDJ: "sparkles"
        case .semanticSearch: "text.magnifyingglass"
        case .audioEnhancer: "waveform.badge.plus"
        case .smartShuffle: "shuffle"
        case .remixer: "wand.and.stars"
        case .naturalPlaylists: "text.badge.plus"
        case .lyricsGeneration: "quote.bubble"
        }
    }

    var summary: String {
        switch self {
        case .smartDJ: "Builds a set from a request in your own words, in the DJ console."
        case .semanticSearch: "Adds “matches by meaning” to Search, so “rainy sunday piano” finds songs that fit even when no tag says so."
        case .audioEnhancer: "Neural upscaling of lossy streams and files (internet radio, podcasts, MP3, AAC), on this Mac only. Lossless files stay bit-perfect. Falls back to the classic sinc resampler the moment it cannot keep up."
        case .smartShuffle: "A small network orders a smart-shuffled queue by tempo, key and energy. Off: the shuffle uses plain rules."
        case .remixer: "Performs filters, effects and loops on the bar line in the DJ console and learns from your thumbs up and down."
        case .naturalPlaylists: "Describe a playlist in your own words (“a 2-hour mix of late-night, low-energy acoustic tracks with high dynamic range”) and Aureon builds it from your library, using the tempo, energy, loudness and dynamic range it has measured. Uses the same local model and API provider as Smart DJ."
        case .lyricsGeneration: "When a song has no lyrics in its folder, its tags or online, Aureon asks whether to write them by listening to the song with a small Whisper speech model, on this Mac only. You can save the result into the file."
        }
    }
}

/// Where a text feature's model runs.
enum IntelligenceEngine: String, Codable, CaseIterable, Sendable {
    case onDevice, api
    var title: String { self == .onDevice ? "On this Mac" : "API" }
}

extension Notification.Name {
    /// Posted on the main thread after the Intelligence settings changed.
    static let intelligenceSettingsChanged = Notification.Name("aureon.intelligenceSettingsChanged")
}

/// The thread-safe view of the Intelligence settings.
///
/// `isEnabled(_:)` is one atomic load (acquire ordering) of a 32-bit mask: no lock, no allocation, no Objective-C, so it may be called
/// from the render callback. The model locations are behind a lock and are for setup code only.
final class IntelligenceGate: Sendable {
    static let shared = IntelligenceGate(hardware: .current, settings: IntelligenceSettings.initial(hardware: .current))

    let hardware: HostHardware
    fileprivate static let masterBit: UInt32 = 1 << 31
    private let mask: Atomic<UInt32>
    private let changes = Atomic<UInt64>(0)
    private let models: Mutex<Models>

    private struct Models: Sendable { var language: URL?; var enhancer: URL? }

    init(hardware: HostHardware, settings: IntelligenceSettings) {
        self.hardware = hardware
        mask = Atomic(Self.mask(for: settings, hardware: hardware))
        models = Mutex(Models(language: settings.languageModel.map { URL(fileURLWithPath: $0.path) }, enhancer: settings.enhancerModel.map { URL(fileURLWithPath: $0.path) }))
    }

    /// True when the feature may run now: the master switch is on, an Intel Mac's owner accepted the warning, and the feature is switched on.
    /// Safe on any thread, including the audio render callback.
    @inline(__always) func isEnabled(_ feature: IntelligenceFeature) -> Bool {
        let m = mask.load(ordering: .acquiring)
        return m & Self.masterBit != 0 && m & feature.bit != 0
    }

    /// The master switch as it takes effect (on Intel it needs the warning accepted as well).
    var isMasterOn: Bool { mask.load(ordering: .acquiring) & Self.masterBit != 0 }

    /// Every switch as one published state, from a single atomic load. Use it when a decision needs more than one switch, so a
    /// change published in between cannot be seen half-applied. Safe on any thread, including the audio render callback.
    struct State: Sendable, Equatable {
        fileprivate let mask: UInt32
        @inline(__always) func isEnabled(_ feature: IntelligenceFeature) -> Bool { mask & IntelligenceGate.masterBit != 0 && mask & feature.bit != 0 }
        var isMasterOn: Bool { mask & IntelligenceGate.masterBit != 0 }
    }

    @inline(__always) var state: State { State(mask: mask.load(ordering: .acquiring)) }

    /// Increases on every published change, so a loop can notice one with a single atomic load.
    var generation: UInt64 { changes.load(ordering: .acquiring) }

    /// The local model the user chose for the audio enhancer (a .mlpackage or .mlmodelc already checked against `LocalModelCap`), if any.
    /// Not for the render thread.
    var enhancerModelURL: URL? { models.withLock { $0.enhancer } }

    /// The local language model folder chosen for Smart DJ, or nil for the built-in one. Not for the render thread.
    var languageModelURL: URL? { models.withLock { $0.language } }

    /// Makes `settings` the ones in force. Call on the main thread; observers are told through `.intelligenceSettingsChanged`.
    func publish(_ settings: IntelligenceSettings) {
        models.withLock { $0 = Models(language: settings.languageModel.map { URL(fileURLWithPath: $0.path) }, enhancer: settings.enhancerModel.map { URL(fileURLWithPath: $0.path) }) }
        mask.store(Self.mask(for: settings, hardware: hardware), ordering: .releasing)
        _ = changes.wrappingAdd(1, ordering: .releasing)
        if Thread.isMainThread { NotificationCenter.default.post(name: .intelligenceSettingsChanged, object: self) }
        else { DispatchQueue.main.async { NotificationCenter.default.post(name: .intelligenceSettingsChanged, object: self) } }
    }

    static func mask(for s: IntelligenceSettings, hardware: HostHardware) -> UInt32 {
        guard s.masterEnabled, hardware.isAppleSilicon || s.intelRiskAccepted else { return 0 }
        var m = masterBit
        for f in IntelligenceFeature.allCases where s.isSwitchedOn(f) && !(f == .audioEnhancer && hardware.audioEnhancerBlocker != nil) { m |= f.bit }
        return m
    }
}

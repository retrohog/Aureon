import Foundation
import SwiftUI

struct SmartDJSuggestion: Equatable, Identifiable {
    let id = UUID()
    var request: String
    var intent: DJIntent
    var tracks: [TrackDTO]
    var usedModel: Bool
    var modelPicked = 0               // how many tracks the model chose itself
    var rejected = 0                  // model picks dropped for not fitting the request
    var filled = 0                    // tracks added by the ranking
    var seconds = 0.0
    var note: String?
    var contextTracks = 0             // how many songs the model was shown
}

/// Smart DJ: the on-device language model that turns "ten upbeat electronic tracks for a workout" into a list of songs from your library.
///
/// The model is only in memory while Smart DJ is switched on: `enable()` starts it, `disable()` quits it and the memory goes back to the system.
/// Without the model (not installed, or it failed to start) the same requests are answered by the ranking alone, and the panel says so.
@MainActor
final class SmartDJService: ObservableObject {
    enum State: Equatable {
        case off
        case loading(Double, String)
        case ready
        case thinking
    }

    static let modelID = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    @Published private(set) var state = State.off
    @Published private(set) var suggestion: SmartDJSuggestion?
    @Published private(set) var history: [SmartDJSuggestion] = []
    /// Set when the language model is not being used, with the reason a person can read.
    @Published private(set) var modelProblem: String?
    @Published private(set) var modelActive = false

    /// Makes the model for this session. The Intelligence settings replace it (on-device helper, a loaded local model, or an API);
    /// a thrown error is shown as the reason the model is not used.
    var makeBackend: () throws -> SmartDJBackend? = { SmartDJHelperLocator.find().map { HelperProcessBackend(executable: $0) } }
    /// Whether the Intelligence settings allow Smart DJ (master switch, Intel acceptance and its own switch).
    var isAllowed: () -> Bool = { IntelligenceGate.shared.isEnabled(.smartDJ) }
    /// Where the model runs, for the panel ("on-device model", "OpenAI · gpt-4.1-mini").
    @Published var engineDescription = "on-device model"
    var library: () -> [SmartDJTrack] = { [] }
    var model = SmartDJService.modelID
    var candidateLimit = 60
    var maxTokens = 220
    /// Tests fix the randomness.
    var rng: (() -> UInt64)?

    private var backend: SmartDJBackend?
    private var chain: Task<Void, Never>?
    private var wanted = false
    private var epoch = 0

    var isEnabled: Bool { state != .off }

    // MARK: switching on and off

    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in await previous?.value; await op() }
    }

    func enable() {
        guard !wanted else { return }
        guard isAllowed() else { modelProblem = "Smart DJ is switched off on the Intelligence page."; return }
        wanted = true; epoch += 1
        let my = epoch
        state = .loading(0, "Starting"); modelProblem = nil; modelActive = false
        enqueue { [self] in
            guard wanted, epoch == my else { return }
            let made: SmartDJBackend?
            do { made = try makeBackend() } catch {
                modelProblem = error.localizedDescription + " Requests are answered by matching tempo, genre, year and artist."
                state = .ready; return
            }
            guard let b = made else {
                modelProblem = SmartDJError.helperMissing.localizedDescription + " Requests are answered by matching tempo, genre, year and artist."
                state = .ready; return
            }
            backend = b
            do {
                try await b.load(model: model) { [weak self] f, msg in Task { @MainActor in
                    guard let self, self.wanted, self.epoch == my else { return }
                    self.state = .loading(f, msg)
                } }
                guard wanted, epoch == my else { await b.unload(); if backend === b { backend = nil }; return }
                modelActive = true; state = .ready
            } catch {
                await b.unload()
                if backend === b { backend = nil }
                guard wanted, epoch == my else { return }
                modelProblem = "The language model could not start (\(error.localizedDescription)) Requests are answered by matching tempo, genre, year and artist."
                state = .ready
            }
        }
    }

    func disable() {
        guard wanted else { return }
        wanted = false; epoch += 1
        state = .off; modelActive = false
        let b = backend; backend = nil
        enqueue { await b?.unload() }
    }

    /// For tests and shutdown: returns once the model is really gone.
    func disableAndWait() async {
        disable()
        await chain?.value
    }

    // MARK: asking

    func suggest(_ request: String) async {
        guard case .ready = state else { return }
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state = .thinking
        let my = epoch, started = Date()
        let songs = library()
        var gen = SeededRNG(seed: rng?() ?? UInt64.random(in: 1...UInt64.max))
        var result = await Self.compose(request: text, songs: songs, backend: modelActive ? backend : nil, candidateLimit: candidateLimit, maxTokens: maxTokens, rng: &gen)
        result.seconds = Date().timeIntervalSince(started)
        guard wanted, epoch == my else { return }                     // switched off while thinking: drop the answer
        suggestion = result
        history.insert(result, at: 0); if history.count > 12 { history.removeLast() }
        state = .ready
    }

    /// The whole pipeline, free of any interface: read the request, narrow the library, ask the model, check the answer.
    nonisolated static func compose<R: RandomNumberGenerator>(request: String, songs: [SmartDJTrack], backend: SmartDJBackend?, candidateLimit: Int, maxTokens: Int, rng: inout R) async -> SmartDJSuggestion {
        let vocab = LibraryVocabulary(tracks: songs.map(\.track))
        var intent = IntentParser.parse(request, vocabulary: vocab)
        guard !songs.isEmpty else { return SmartDJSuggestion(request: request, intent: intent, tracks: [], usedModel: false, note: "Your library is empty: add some music first.") }
        intent.count = min(intent.count, songs.count)
        let candidates = ContextBuilder.candidates(from: songs, intent: intent, limit: candidateLimit, using: &rng)
        let minScore = SmartDJSelection.minScore(library: songs, intent: intent)
        var out = SmartDJSuggestion(request: request, intent: intent, tracks: [], usedModel: false, contextTracks: candidates.count)
        var modelIDs: [Int] = []
        var notes: [String] = []
        if let backend, backend.isLoaded {
            let p = ContextBuilder.prompt(request: request, intent: intent, candidates: candidates)
            do {
                let text = try await backend.generate(system: p.system, user: p.user, schema: p.schema, maxTokens: maxTokens)
                modelIDs = SmartDJSelection.parse(text, valid: Set(candidates.map(\.id)))
                out.usedModel = !modelIDs.isEmpty
                if modelIDs.isEmpty { notes.append("The language model's answer could not be used.") }
            } catch {
                notes.append("The language model failed (\(error.localizedDescription))")
            }
        }
        let o = SmartDJSelection.finalize(modelIDs: modelIDs, candidates: candidates, count: p_count(intent, candidates), minScore: minScore)
        out.tracks = o.picks.map { $0.song.track }
        out.modelPicked = o.fromModel; out.rejected = o.rejected; out.filled = o.filled
        if o.rejected > 0 { notes.append("\(o.rejected) pick\(o.rejected == 1 ? "" : "s") from the model did not fit the request and \(o.rejected == 1 ? "was" : "were") replaced.") }
        if intent.bpm != nil, songs.filter({ $0.bpm != nil }).count * 4 < songs.count {
            notes.append("Only \(songs.filter { $0.bpm != nil }.count) of \(songs.count) songs have a measured tempo: analyse the library in the DJ browser for better matches.")
        }
        if intent.hasConstraints, o.picks.count < intent.count { notes.append("Only \(o.picks.count) songs were found.") }
        out.note = notes.isEmpty ? nil : notes.joined(separator: " ")
        return out
    }

    nonisolated private static func p_count(_ i: DJIntent, _ c: [SmartDJCandidate]) -> Int { min(i.count, c.count) }

    // MARK: building the library view

    /// Library songs with whatever the DJ analysis knows about them.
    nonisolated static func tracks(from library: [TrackDTO], analysis: (String) -> DJTrackAnalysis?) -> [SmartDJTrack] {
        library.map { t in
            let a = analysis(t.path)
            return SmartDJTrack(track: t, bpm: a?.bpm, energy: a.map { $0.energy }, key: a?.key?.camelot)
        }
    }
}

/// SplitMix64: small, fast and reproducible.
struct SeededRNG: RandomNumberGenerator {
    private var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

import Foundation
import SwiftUI

/// Builds a playlist from a request in plain words (see `PlaylistEngine` for how).
///
/// Everything heavy runs off the main thread: reading the library, reading the analysis of every song, scoring, and the model. The model is
/// loaded when a request comes in and unloaded `idleUnload` seconds after the last one, so it holds no memory while you listen.
/// The Intelligence gate is asked before every request: with the master switch or this feature off, nothing runs and nothing is loaded.
@MainActor
final class NaturalPlaylistService: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case done
        case failed(String)
    }

    static let offMessage = "Natural-language playlists are switched off. Turn them on in Intelligence."

    @Published private(set) var state = State.idle
    @Published private(set) var plan: PlaylistPlan?
    @Published private(set) var history: [PlaylistPlan] = []
    /// The language model is in memory.
    @Published private(set) var modelLoaded = false
    /// Where the model runs, for the page ("on-device model", "OpenAI · gpt-4.1-mini").
    @Published private(set) var engineDescription = ""

    /// Whether the Intelligence settings allow this feature (master switch, Intel acceptance, its own switch).
    var isAllowed: () -> Bool = { IntelligenceGate.shared.isEnabled(.naturalPlaylists) }
    /// The model for the current settings: the helper process (or an API client), the model to load, and a label for the page.
    var makeBackend: () throws -> (backend: SmartDJBackend?, model: String, label: String) = {
        (SmartDJHelperLocator.find().map { HelperProcessBackend(executable: $0) }, SmartDJService.modelID, "on-device model")
    }
    /// Hands over a reader of the whole library; the reader runs on a background thread.
    var library: () -> (@Sendable () -> [TrackDTO]) = { { [] } }
    /// Changes whenever the library does, so the prepared songs can be reused.
    var libraryRevision: () -> Int64 = { 0 }
    /// What the DJ analysis knows about a file.
    var analysis: @Sendable (String) -> AnalysisSummary? = { AnalysisCache.shared.summary(path: $0) }
    /// How close each song is in meaning to the request, or nil when Semantic Search is off or still preparing its index.
    var similarities: (String) async -> [String: Float]? = { _ in nil }
    var idleUnload: TimeInterval = 120
    /// Tests fix the randomness.
    var rng: (() -> UInt64)?

    private var backend: SmartDJBackend?
    private var idleTask: Task<Void, Never>?
    private var epoch = 0
    private var cache: (revision: Int64, count: Int, at: Date, songs: [SmartDJTrack])?

    var isBusy: Bool { if case .working = state { return true }; return false }

    // MARK: asking

    /// Builds the playlist for `request`. The result is in `plan`; `state` says how it went.
    func build(_ request: String) async {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        guard isAllowed() else { state = .failed(Self.offMessage); return }
        epoch += 1
        let my = epoch
        let started = Date()
        state = .working("Reading your library")

        // 1. the songs, with what the analyses know about them
        let reader = library(), an = analysis, rev = libraryRevision()
        let songs: [SmartDJTrack]
        if let c = cache, c.revision == rev, Date().timeIntervalSince(c.at) < 300 { songs = c.songs }
        else {
            songs = await Task.detached(priority: .userInitiated) { Self.prepare(tracks: reader(), analysis: an) }.value
            guard epoch == my else { return }
            cache = (rev, songs.count, Date(), songs)
        }
        guard !songs.isEmpty else {
            plan = PlaylistPlan(request: text, brief: PlaylistBriefParser.parse(text, vocabulary: LibraryVocabulary()), tracks: [], seconds: 0, notes: ["Your library is empty: add some music first."])
            state = .done; return
        }

        // 2. the model, if it can run; otherwise the ranking answers alone
        var preface: [String] = []
        state = .working("Starting the language model")
        var model: SmartDJBackend?
        do { model = try await acquireBackend(epoch: my) }
        catch {
            guard epoch == my else { return }
            preface.append("The language model could not start (\(error.localizedDescription)) The playlist was built by ranking alone.")
        }
        guard epoch == my else { return }
        guard isAllowed() else { state = .failed(Self.offMessage); await releaseModel(); return }

        // 3. meaning (Semantic Search, when it is on and its index is ready)
        state = .working("Matching meaning")
        let meaning = await similarities(text)
        guard epoch == my else { return }
        if meaning == nil, IntelligenceGate.shared.isEnabled(.semanticSearch) { preface.append("Matching by meaning is still preparing its index; it will be used next time.") }

        // 4. choose
        state = .working(model == nil ? "Choosing songs" : "Asking the language model")
        let seed = rng?() ?? UInt64.random(in: 1...UInt64.max)
        let sem = meaning ?? [:]
        let backendForRun = model
        var result = await Task.detached(priority: .userInitiated) { () -> PlaylistPlan in
            var gen = SeededRNG(seed: seed)
            return await PlaylistEngine.compose(request: text, songs: songs, backend: backendForRun, semantic: sem, rng: &gen)
        }.value
        guard epoch == my else { return }
        result.notes = preface + result.notes
        result.elapsed = Date().timeIntervalSince(started)
        plan = result
        history.insert(result, at: 0); if history.count > 8 { history.removeLast() }
        state = .done
        if backend != nil { scheduleIdleUnload() }
    }

    /// Songs with the figures the ranking uses. Runs on a background thread.
    nonisolated static func prepare(tracks: [TrackDTO], analysis: (String) -> AnalysisSummary?) -> [SmartDJTrack] {
        tracks.map { t in
            let a = analysis(t.path)
            // without a DJ analysis the loudness analysis still says something about intensity: -24 LUFS is hushed, -10 is loud
            let proxy = t.lufs.map { min(1, max(0, ($0 + 24) / 14)) }
            return SmartDJTrack(track: t, bpm: a?.bpm, energy: a?.energy ?? proxy, key: a?.key)
        }
    }

    // MARK: the model

    private func acquireBackend(epoch my: Int) async throws -> SmartDJBackend? {
        idleTask?.cancel(); idleTask = nil
        if let b = backend, b.isLoaded { return b }
        let made = try makeBackend()
        guard let b = made.backend else { throw SmartDJError.helperMissing }
        backend = b
        do {
            try await b.load(model: made.model) { [weak self] f, msg in
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == my, case .working = self.state else { return }
                    self.state = .working(f < 1 ? "\(msg) \(Int(f * 100))%" : msg)
                }
            }
        } catch {
            await b.unload()
            if backend === b { backend = nil }
            throw error
        }
        guard epoch == my else { await b.unload(); if backend === b { backend = nil }; return nil }
        engineDescription = made.label
        modelLoaded = true
        return b
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let seconds = idleUnload
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.releaseModel()
        }
    }

    /// Unloads the model now (its memory goes back to the system). Safe when nothing is loaded.
    func releaseModel() async {
        idleTask?.cancel(); idleTask = nil
        let b = backend
        backend = nil; modelLoaded = false
        await b?.unload()
    }

    /// The feature or the master switch was turned off: stop what is running, forget the result and free the model.
    func shutDown() {
        epoch += 1
        cache = nil
        plan = nil
        if isBusy { state = .idle }
        Task { await releaseModel() }
    }

    /// For tests: returns once the model is really gone.
    func shutDownAndWait() async {
        epoch += 1
        cache = nil
        if isBusy { state = .idle }
        await releaseModel()
    }

    // MARK: using the result

    /// Saves the plan as a playlist and returns it.
    @discardableResult
    func save(_ plan: PlaylistPlan, as name: String, in collections: CollectionsModel) -> PlaylistDTO? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plan.tracks.isEmpty else { return nil }
        return collections.create(name: n.isEmpty ? plan.name : n, with: plan.tracks)
    }
}

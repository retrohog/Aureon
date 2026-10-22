import Foundation
import SwiftUI

/// Applies the Intelligence settings to the running app and is the model behind the Intelligence page.
///
/// Turning the master switch (or a feature) off takes effect at once: Smart DJ's model process is quit, the AI Remixer stops, the semantic
/// index is dropped from memory, Smart Shuffle falls back to plain rules, and the audio enhancer's gate closes (its engine reads the gate).
@MainActor
final class IntelligenceCenter: ObservableObject {
    static let shared = IntelligenceCenter()

    enum Check: Equatable { case idle, checking, ok(String), failed(String) }

    let gate: IntelligenceGate
    let keys: AIKeyStore
    let search: SemanticSearchService
    /// Builds playlists from a request in plain words. Uses the Smart DJ model setup and the semantic index, and obeys its own switch on the gate.
    let playlists: NaturalPlaylistService
    @Published private(set) var settings: IntelligenceSettings
    /// The Intel warning sheet is up.
    @Published var showIntelWarning = false
    @Published private(set) var connection = Check.idle
    /// Which providers have a key in the Keychain, read once per provider (Keychain reads do not belong in a view's body).
    @Published private var keyPresent: [AIProvider: Bool] = [:]

    private let defaults: UserDefaults
    private let persist: Bool
    private weak var dj: DJModel?
    /// The Smart DJ service wired through `configure(_:)` (the DJ console's, in the app); the switches reach it even without a console.
    private weak var smart: SmartDJService?
    var http: HTTPClient = URLSessionClient()

    init(gate: IntelligenceGate = .shared, keys: AIKeyStore = .shared, defaults: UserDefaults = .standard,
         persist: Bool = ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil, settings: IntelligenceSettings? = nil) {
        self.gate = gate; self.keys = keys; self.defaults = defaults; self.persist = persist
        let s = settings ?? (persist ? IntelligenceSettings.load(defaults, hardware: gate.hardware) : IntelligenceSettings.initial(hardware: gate.hardware))
        self.settings = s
        search = SemanticSearchService()
        playlists = NaturalPlaylistService()
        gate.publish(s)
        configureSearch()
        configurePlaylists()
    }

    var hardware: HostHardware { gate.hardware }
    /// The master switch as it takes effect.
    var isMasterOn: Bool { gate.isMasterOn }
    func isActive(_ f: IntelligenceFeature) -> Bool { gate.isEnabled(f) }
    func hasKey(_ p: AIProvider) -> Bool {
        if let k = keyPresent[p] { return k }
        let k = keys.hasKey(p)
        DispatchQueue.main.async { [weak self] in self?.keyPresent[p] = k }       // not during a view update
        return k
    }

    // MARK: switches

    /// The master switch. On an Intel Mac, switching it on first shows the warning; it only goes on once the warning is accepted.
    func setMaster(_ on: Bool) {
        if on, hardware.isIntel, !settings.intelRiskAccepted { showIntelWarning = true; return }
        update { $0.masterEnabled = on }
    }

    func acceptIntelWarning() {
        showIntelWarning = false
        update { $0.intelRiskAccepted = true; $0.masterEnabled = true }
    }

    func declineIntelWarning() { showIntelWarning = false }

    /// Withdraws the Intel acceptance: the master switch goes off and the warning comes back next time.
    func revokeIntelAcceptance() { update { $0.intelRiskAccepted = false; $0.masterEnabled = false } }

    func setFeature(_ f: IntelligenceFeature, _ on: Bool) { update { $0.set(f, on) } }

    func setEngine(_ f: IntelligenceFeature, _ e: IntelligenceEngine) {
        guard f.allowsAPI || e == .onDevice else { return }                 // audio never goes to an API
        update { s in
            switch f {
            case .smartDJ: s.smartDJEngine = e
            case .semanticSearch: s.searchEngine = e
            case .naturalPlaylists: s.playlistEngine = e
            default: break
            }
        }
    }

    func setWhisperModel(_ m: WhisperModelSize) { update { $0.whisperModel = m } }

    func setProvider(_ p: AIProvider) {
        guard p != settings.api.provider else { return }
        update { $0.api = APIConfig(provider: p) }
        connection = .idle
    }

    func setAPI(baseURL: String? = nil, model: String? = nil, embeddingModel: String? = nil) {
        update { s in
            if let baseURL { s.api.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let model { s.api.model = model.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let embeddingModel { s.api.embeddingModel = embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        connection = .idle
    }

    func saveKey(_ key: String, for p: AIProvider) {
        keys.setKey(key, for: p); keyPresent[p] = keys.hasKey(p); connection = .idle
        if settings.api.provider == p { restartAPIUsers() }
    }

    func removeKey(for p: AIProvider) {
        keys.setKey(nil, for: p); keyPresent[p] = false; connection = .idle
        if settings.api.provider == p { restartAPIUsers() }
    }

    /// Uses a checked model for a role, or goes back to the default (nil). Returns the reason when the model is refused.
    @discardableResult
    func useModel(_ info: LocalModelInfo?, for role: LocalModelRole) -> LocalModelVerdict {
        if let info {
            let v = LocalModelInspector.verdict(info, role: role, hardware: hardware)
            guard v.isAccepted else { return v }
        }
        update { s in
            switch role {
            case .languageModel: s.languageModel = info.map(LocalModelSelection.init)
            case .audioEnhancer: s.enhancerModel = info.map(LocalModelSelection.init)
            }
        }
        return .accepted
    }

    /// Tries the API settings and key without spending tokens.
    func testConnection() async {
        connection = .checking
        let cfg = settings.api
        do {
            let client = try OpenAICompatibleClient.make(cfg, keys: keys, http: http)
            let msg = try await client.verifyConnection()
            guard settings.api == cfg else { return }
            connection = .ok(msg)
        } catch {
            guard settings.api == cfg else { return }
            connection = .failed(error.localizedDescription)
        }
    }

    // MARK: wiring

    /// Connects the app's AI features. Called once by `PlayerModel`.
    func attach(_ player: PlayerModel) {
        attach(dj: player.dj)
        // the enhancer engine follows the gate itself; starting it now compiles and times the model before the first lossy track plays
        NeuralUpscaler.shared.observeSettings()
        let lib = player.library
        search.library = { [weak lib] in
            let store = lib?.store                                               // the store itself is safe to use from any thread
            return { store?.allTracks(offset: 0, limit: 500_000) ?? [] }
        }
        playlists.library = search.library
        playlists.libraryRevision = { [weak lib] in lib?.store?.revision ?? 0 }
    }

    func attach(dj: DJModel) {
        self.dj = dj
        configure(dj.smart)
        apply(old: nil, new: settings)
    }

    /// Smart DJ asks here for its model each time it is switched on, so it always uses the engine chosen now.
    func configure(_ smart: SmartDJService) {
        self.smart = smart
        smart.isAllowed = { [weak self] in self?.gate.isEnabled(.smartDJ) ?? false }
        smart.makeBackend = { [weak self, weak smart] in
            guard let self else { return nil }
            let (backend, model, label) = try self.smartDJBackend()
            smart?.model = model
            smart?.engineDescription = label
            return backend
        }
    }

    /// The backend for the current settings: the on-device MLX helper (built-in or a loaded model) or the API.
    func smartDJBackend() throws -> (SmartDJBackend?, String, String) { try languageBackend(engine: settings.smartDJEngine) }

    /// The same for natural-language playlists, which have their own engine choice but share the model and the provider.
    func playlistBackend() throws -> (SmartDJBackend?, String, String) { try languageBackend(engine: settings.playlistEngine) }

    private func languageBackend(engine: IntelligenceEngine) throws -> (SmartDJBackend?, String, String) {
        switch engine {
        case .api:
            let client = try OpenAICompatibleClient.make(settings.api, keys: keys, http: http)
            return (RemoteLLMBackend(client: client), settings.api.model, "\(settings.api.provider.shortTitle) · \(settings.api.model)")
        case .onDevice:
            guard hardware.canRunMLX else {
                throw SmartDJError.failed(hardware.isIntel ? "On-device language models need Apple Silicon. Choose API on the Intelligence page."
                                                           : "On-device language models cannot run under Rosetta. Open the native Apple Silicon build.")
            }
            let model = settings.languageModel?.path ?? SmartDJService.modelID
            let label = settings.languageModel.map { "on-device · \($0.name)" } ?? "on-device model"
            return (SmartDJHelperLocator.find().map { HelperProcessBackend(executable: $0) }, model, label)
        }
    }

    private func configureSearch() {
        search.isAllowed = { [weak self] in self?.gate.isEnabled(.semanticSearch) ?? false }
        search.makeEmbedder = { [weak self] in
            guard let self else { throw SemanticSearchError.modelUnavailable("Semantic Search is not available.") }
            if self.settings.searchEngine == .api {
                let c = try OpenAICompatibleClient.make(self.settings.api, keys: self.keys, http: self.http)
                guard !c.config.embeddingModel.isEmpty else {
                    throw SemanticSearchError.modelUnavailable("\(c.config.provider.title) has no embedding model set. Enter one, or run Semantic Search on this Mac.")
                }
                return APIEmbedder(client: c)
            }
            return OnDeviceEmbedder()
        }
    }

    private func configurePlaylists() {
        playlists.isAllowed = { [weak self] in self?.gate.isEnabled(.naturalPlaylists) ?? false }
        playlists.makeBackend = { [weak self] in
            guard let self else { throw SmartDJError.stopped }
            let (backend, model, label) = try self.playlistBackend()
            return (backend, model, label)
        }
        playlists.similarities = { [weak self] query in
            guard let self, self.gate.isEnabled(.semanticSearch) else { return nil }
            return await self.search.similaritiesIfReady(to: query)
        }
    }

    private func update(_ change: (inout IntelligenceSettings) -> Void) {
        let old = settings
        var s = settings
        change(&s)
        guard s != old else { return }
        settings = s
        if persist { s.save(defaults) }
        gate.publish(s)
        apply(old: old, new: s)
    }

    /// Brings every feature in line with the gate.
    private func apply(old: IntelligenceSettings?, new: IntelligenceSettings) {
        if let smart {
            if !gate.isEnabled(.smartDJ) {
                if smart.isEnabled { smart.disable() }
            } else if let old, smart.isEnabled,
                      old.smartDJEngine != new.smartDJEngine || old.languageModel != new.languageModel || (new.smartDJEngine == .api && old.api != new.api) {
                smart.disable(); smart.enable()                                     // pick up the new engine
            }
        }
        if !gate.isEnabled(.naturalPlaylists) { playlists.shutDown() }
        else if let old, old.playlistEngine != new.playlistEngine || old.languageModel != new.languageModel || (new.playlistEngine == .api && old.api != new.api) {
            Task { await playlists.releaseModel() }                                  // the next request starts the model now chosen
        }
        if let dj, !gate.isEnabled(.remixer), dj.remix.enabled { dj.remix.enabled = false }
        if !gate.isEnabled(.semanticSearch) { search.release() }
        else if let old, old.searchEngine != new.searchEngine || (new.searchEngine == .api && (old.api.baseURL != new.api.baseURL || old.api.embeddingModel != new.api.embeddingModel || old.api.provider != new.api.provider)) {
            search.release()
        }
    }

    private func restartAPIUsers() {
        if let smart, smart.isEnabled, settings.smartDJEngine == .api { smart.disable(); smart.enable() }
        if settings.searchEngine == .api { search.release() }
        if settings.playlistEngine == .api { Task { await playlists.releaseModel() } }
    }

    /// What the Intelligence page shows as memory in use by AI features right now.
    var memoryNote: String {
        var parts: [String] = []
        if let smart, smart.modelActive { parts.append("Smart DJ model running") }
        if playlists.modelLoaded { parts.append("playlist model running") }
        if LyricsService.shared.isGenerating { parts.append("lyrics model running") }
        if search.isLoaded { parts.append("search index " + formatBytes(search.indexBytes)) }
        return parts.isEmpty ? "No AI model or index is in memory." : parts.joined(separator: " · ")
    }
}

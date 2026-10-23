import Foundation

/// A local model the user loaded, as it was when it passed the size check.
struct LocalModelSelection: Codable, Equatable, Sendable {
    var path: String
    var name: String
    var format: LocalModelFormat
    var parameters: Int64
    /// True when the count comes from the file size (CoreML), not from the tensors themselves.
    var parametersEstimated: Bool
    var bytes: Int64

    init(_ info: LocalModelInfo) {
        path = info.url.path; name = info.name; format = info.format
        parameters = info.parameters; parametersEstimated = info.parametersEstimated; bytes = info.bytes
    }
}

/// The OpenAI-compatible endpoint the text features may use. The key is not here: it lives in the Keychain (`AIKeyStore`).
struct APIConfig: Codable, Equatable, Sendable {
    var provider = AIProvider.openAI
    var baseURL = AIProvider.openAI.defaultBaseURL
    var model = AIProvider.openAI.defaultModel
    var embeddingModel = AIProvider.openAI.defaultEmbeddingModel

    init() {}
    init(provider: AIProvider) {
        self.provider = provider
        baseURL = provider.defaultBaseURL; model = provider.defaultModel; embeddingModel = provider.defaultEmbeddingModel
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        provider = (try? c.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? .openAI
        baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? provider.defaultBaseURL
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? provider.defaultModel
        embeddingModel = (try? c.decodeIfPresent(String.self, forKey: .embeddingModel)) ?? provider.defaultEmbeddingModel
    }
}

/// Everything the Intelligence page controls. Saved as JSON; the master switch is also its own Bool (`masterKey`), so `@AppStorage` can read it.
struct IntelligenceSettings: Codable, Equatable, Sendable {
    /// "Enable Intelligence Features". Off: no model process runs, no index is held in memory, and every feature uses its classic path.
    var masterEnabled: Bool
    /// On an Intel Mac the master switch only takes effect once the owner has read and accepted the warning.
    var intelRiskAccepted = false

    var smartDJ = true
    var semanticSearch = true
    /// Off by default everywhere: it changes the samples, and Aureon is bit-perfect unless asked otherwise.
    var audioEnhancer = false
    var smartShuffle = true
    var remixer = true
    var naturalPlaylists = true
    var lyricsGeneration = true
    /// Which Whisper model writes the lyrics (all far below the 1B cap on local models).
    var whisperModel = WhisperModelSize.base

    var smartDJEngine = IntelligenceEngine.onDevice
    var searchEngine = IntelligenceEngine.onDevice
    var playlistEngine = IntelligenceEngine.onDevice

    /// The local language model for Smart DJ; nil means the built-in one (`SmartDJService.modelID`).
    var languageModel: LocalModelSelection?
    /// The local model for the audio enhancer (CoreML).
    var enhancerModel: LocalModelSelection?
    var api = APIConfig()

    /// First launch: on for Apple Silicon, off for Intel, where it must be switched on by hand (and the warning accepted).
    static func defaults(for hw: HostHardware) -> IntelligenceSettings {
        var s = IntelligenceSettings(masterEnabled: hw.isAppleSilicon)
        if hw.localLanguageModelBlocker != nil { s.smartDJEngine = .api; s.playlistEngine = .api }       // no on-device language model on Intel
        return s
    }

    init(masterEnabled: Bool) { self.masterEnabled = masterEnabled }

    func isSwitchedOn(_ f: IntelligenceFeature) -> Bool {
        switch f {
        case .smartDJ: smartDJ
        case .semanticSearch: semanticSearch
        case .audioEnhancer: audioEnhancer
        case .smartShuffle: smartShuffle
        case .remixer: remixer
        case .naturalPlaylists: naturalPlaylists
        case .lyricsGeneration: lyricsGeneration
        }
    }

    mutating func set(_ f: IntelligenceFeature, _ on: Bool) {
        switch f {
        case .smartDJ: smartDJ = on
        case .semanticSearch: semanticSearch = on
        case .audioEnhancer: audioEnhancer = on
        case .smartShuffle: smartShuffle = on
        case .remixer: remixer = on
        case .naturalPlaylists: naturalPlaylists = on
        case .lyricsGeneration: lyricsGeneration = on
        }
    }

    func engine(for f: IntelligenceFeature) -> IntelligenceEngine {
        switch f {
        case .smartDJ: smartDJEngine
        case .semanticSearch: searchEngine
        case .naturalPlaylists: playlistEngine
        default: .onDevice
        }
    }

    // Tolerant decoding: a field added later must not wipe someone's choices.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        masterEnabled = v(.masterEnabled, false)
        intelRiskAccepted = v(.intelRiskAccepted, false)
        smartDJ = v(.smartDJ, true); semanticSearch = v(.semanticSearch, true); audioEnhancer = v(.audioEnhancer, false)
        smartShuffle = v(.smartShuffle, true); remixer = v(.remixer, true); naturalPlaylists = v(.naturalPlaylists, true)
        lyricsGeneration = v(.lyricsGeneration, true); whisperModel = v(.whisperModel, .base)
        smartDJEngine = v(.smartDJEngine, .onDevice); searchEngine = v(.searchEngine, .onDevice); playlistEngine = v(.playlistEngine, .onDevice)
        languageModel = (try? c.decodeIfPresent(LocalModelSelection.self, forKey: .languageModel)) ?? nil
        enhancerModel = (try? c.decodeIfPresent(LocalModelSelection.self, forKey: .enhancerModel)) ?? nil
        api = v(.api, APIConfig())
    }

    // MARK: storage

    static let key = "aureon.intelligence"
    /// The master switch on its own, for `@AppStorage("aureon.intelligence.enabled")`.
    static let masterKey = "aureon.intelligence.enabled"

    static func load(_ d: UserDefaults = .standard, hardware: HostHardware) -> IntelligenceSettings {
        var s = d.data(forKey: key).flatMap { try? JSONDecoder().decode(IntelligenceSettings.self, from: $0) } ?? defaults(for: hardware)
        if d.object(forKey: masterKey) != nil { s.masterEnabled = d.bool(forKey: masterKey) }
        if hardware.localLanguageModelBlocker != nil { s.smartDJEngine = .api; s.playlistEngine = .api }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
        d.set(masterEnabled, forKey: Self.masterKey)
    }

    /// What the app starts with. Headless runs start with every feature allowed (callers can switch them off), and never read
    /// or writes the user's own choices.
    static func initial(hardware: HostHardware, environment: [String: String] = ProcessInfo.processInfo.environment) -> IntelligenceSettings {
        if environment["AUREON_TESTING"] != nil {
            var s = IntelligenceSettings(masterEnabled: true)
            s.intelRiskAccepted = true
            return s
        }
        return load(hardware: hardware)
    }
}

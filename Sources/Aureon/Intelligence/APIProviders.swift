import Foundation
import Synchronization

/// A service that speaks the OpenAI chat-completions API. Only text goes to it (Smart DJ requests and song descriptions); audio never does.
enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case openAI, deepSeek, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }
    var shortTitle: String { self == .custom ? "Custom" : title }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .custom: "http://localhost:1234/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4.1-mini"
        case .deepSeek: "deepseek-chat"
        case .custom: ""
        }
    }

    /// Empty when the service has no embeddings endpoint (DeepSeek); Semantic Search then stays on this Mac.
    var defaultEmbeddingModel: String {
        switch self {
        case .openAI: "text-embedding-3-small"
        case .deepSeek: ""
        case .custom: ""
        }
    }

    /// How a reply is constrained to JSON. OpenAI follows a JSON schema; DeepSeek offers plain JSON mode; a custom server is tried with a
    /// schema first and steps down if it refuses.
    var preferredFormat: OpenAICompatibleClient.ResponseFormat { self == .deepSeek ? .jsonObject : .jsonSchema }
}

/// API keys, one per provider, kept in the macOS Keychain and nowhere else (never in UserDefaults, never in logs).
final class AIKeyStore: Sendable {
    static let shared = AIKeyStore(store: KeychainSecretStore(service: "org.aureon.intelligence"))
    let store: SecretStore
    init(store: SecretStore) { self.store = store }

    static func account(_ p: AIProvider) -> String { "api-key.\(p.rawValue)" }
    func key(for p: AIProvider) -> String? { store.get(Self.account(p)).flatMap { $0.isEmpty ? nil : $0 } }
    func setKey(_ key: String?, for p: AIProvider) {
        let k = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        store.set(k?.isEmpty == false ? k : nil, for: Self.account(p))
    }
    func hasKey(_ p: AIProvider) -> Bool { store.has(Self.account(p)) }
}

enum AIAPIError: LocalizedError, Equatable {
    case notConfigured(String)
    case insecureURL(String)
    case refused(String)
    case status(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m), .refused(let m), .badResponse(let m): m
        case .insecureURL(let u): "“\(u)” is not a secure address. Use https:// (plain http:// is accepted only for a server on this Mac, such as localhost)."
        case .status(let c, let m): "The API answered \(c)" + (m.isEmpty ? "." : ": \(m)")
        }
    }
}

/// A minimal client for OpenAI-compatible endpoints: chat completions with JSON output, embeddings, and a connection check.
struct OpenAICompatibleClient: Sendable {
    enum ResponseFormat: Equatable, Sendable { case jsonSchema, jsonObject, none }

    var config: APIConfig
    var apiKey: String
    var http: HTTPClient = URLSessionClient()
    var timeout: TimeInterval = 60

    init(config: APIConfig, apiKey: String, http: HTTPClient = URLSessionClient(), timeout: TimeInterval = 60) {
        self.config = config; self.apiKey = apiKey; self.http = http; self.timeout = timeout
    }

    /// A client for the saved settings and key, or a reason a person can act on.
    static func make(_ config: APIConfig, keys: AIKeyStore = .shared, http: HTTPClient = URLSessionClient()) throws -> OpenAICompatibleClient {
        _ = try validatedBaseURL(config.baseURL)
        let key = keys.key(for: config.provider)
        if key == nil && !isLocalHost(config.baseURL) { throw AIAPIError.notConfigured("Add your \(config.provider.title) API key on the Intelligence page.") }
        if config.model.trimmingCharacters(in: .whitespaces).isEmpty { throw AIAPIError.notConfigured("Enter the name of the model to use on the Intelligence page.") }
        return OpenAICompatibleClient(config: config, apiKey: key ?? "", http: http)
    }

    /// The base address must be https, except for a server on this Mac.
    static func validatedBaseURL(_ s: String) throws -> URL {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), let host = u.host, !host.isEmpty else {
            throw AIAPIError.notConfigured("“\(t)” is not a valid API address.")
        }
        if scheme == "https" { return u }
        if scheme == "http" && isLocalHost(t) { return u }
        throw AIAPIError.insecureURL(t)
    }

    static func isLocalHost(_ s: String) -> Bool {
        guard let h = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]"
    }

    func endpoint(_ path: String) throws -> URL {
        var base = try Self.validatedBaseURL(config.baseURL).absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let u = URL(string: base + "/" + path) else { throw AIAPIError.notConfigured("“\(config.baseURL)” is not a valid API address.") }
        return u
    }

    private func request(_ path: String, body: [String: Any]?) throws -> URLRequest {
        var r = URLRequest(url: try endpoint(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = body == nil ? "GET" : "POST"
        if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// The service's own explanation from an error body (`{"error":{"message":…}}`), shortened.
    static func errorMessage(_ d: Data) -> String {
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        let m = ((o?["error"] as? [String: Any])?["message"] as? String) ?? (o?["error"] as? String) ?? (o?["message"] as? String) ?? ""
        return String(m.prefix(240))
    }

    private func check(_ status: Int, _ d: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let m = Self.errorMessage(d)
        switch status {
        case 401, 403: throw AIAPIError.refused("\(config.provider.title) refused the API key" + (m.isEmpty ? "." : ": \(m)"))
        case 429: throw AIAPIError.refused("\(config.provider.title) is rate-limiting requests or the account has no credit left" + (m.isEmpty ? "." : ": \(m)"))
        default: throw AIAPIError.status(status, m)
        }
    }

    /// Asks the model for JSON matching `schema`. Steps down from a JSON schema to JSON mode to a plain request when a server refuses the format.
    func chatJSON(system: String, user: String, schema: String, maxTokens: Int) async throws -> String {
        let schemaObj = (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) ?? [String: Any]()
        var formats: [ResponseFormat] = [config.provider.preferredFormat]
        if formats[0] == .jsonSchema { formats.append(.jsonObject) }
        formats.append(.none)
        var lastError: Error = AIAPIError.badResponse("No answer from the API.")
        for (i, f) in formats.enumerated() {
            var sys = system
            if f != .jsonSchema { sys += "\n\nAnswer with a single JSON object only, no prose, matching this JSON schema:\n" + schema }
            var body: [String: Any] = ["model": config.model, "messages": [["role": "system", "content": sys], ["role": "user", "content": user]],
                                       "max_tokens": maxTokens, "temperature": 0.2]
            switch f {
            case .jsonSchema: body["response_format"] = ["type": "json_schema", "json_schema": ["name": "aureon_answer", "schema": schemaObj, "strict": false]]
            case .jsonObject: body["response_format"] = ["type": "json_object"]
            case .none: break
            }
            let (d, status) = try await http.send(try request("chat/completions", body: body))
            // 400 / 422 with a response_format usually means "this server does not support that format": try the next one
            if (status == 400 || status == 422), i < formats.count - 1 { lastError = AIAPIError.status(status, Self.errorMessage(d)); continue }
            try check(status, d)
            return try Self.content(d)
        }
        throw lastError
    }

    /// The assistant's text from a chat-completions reply, with any ```json fence removed.
    static func content(_ d: Data) throws -> String {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let choices = o["choices"] as? [[String: Any]], let first = choices.first else {
            throw AIAPIError.badResponse("The API's answer could not be read.")
        }
        let msg = first["message"] as? [String: Any]
        var text = ((msg?["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw AIAPIError.badResponse((first["finish_reason"] as? String) == "length" ? "The model ran out of room before answering." : "The model gave an empty answer.")
        }
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let r = text.range(of: "```", options: .backwards) { text = String(text[..<r.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Embeddings for `texts`, in order, in batches of 96.
    func embeddings(_ texts: [String]) async throws -> [[Float]] {
        let model = config.embeddingModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw AIAPIError.notConfigured("\(config.provider.title) has no embedding model set, so Semantic Search runs on this Mac.") }
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        var i = 0
        while i < texts.count {
            let batch = Array(texts[i..<min(texts.count, i + 96)])
            var body: [String: Any] = ["model": model, "input": batch]
            if model.hasPrefix("text-embedding-3") { body["dimensions"] = 256 }      // smaller vectors, same quality ranking, a quarter of the memory
            let (d, status) = try await http.send(try request("embeddings", body: body))
            try check(status, d)
            guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let data = o["data"] as? [[String: Any]], data.count == batch.count else {
                throw AIAPIError.badResponse("The embeddings answer could not be read.")
            }
            let sorted = data.sorted { (($0["index"] as? Int) ?? 0) < (($1["index"] as? Int) ?? 0) }
            for e in sorted {
                guard let v = e["embedding"] as? [Any], !v.isEmpty else { throw AIAPIError.badResponse("The embeddings answer could not be read.") }
                out.append(v.compactMap { ($0 as? NSNumber)?.floatValue })
            }
            i += batch.count
        }
        return out
    }

    /// Checks the address and key without spending tokens: lists the models. A server that has no model list is accepted.
    func verifyConnection() async throws -> String {
        let (d, status) = try await http.send(try request("models", body: nil))
        if status == 404 || status == 405 { return "Connected to \(config.provider.shortTitle)." }
        try check(status, d)
        let ids = (((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        if ids.isEmpty { return "Connected to \(config.provider.shortTitle)." }
        if !config.model.isEmpty, !ids.contains(config.model) {
            return "Connected, but \(config.provider.shortTitle) does not list “\(config.model)” among its \(ids.count) models. Check the model name."
        }
        return "Connected to \(config.provider.shortTitle): “\(config.model)” is available."
    }
}

/// Smart DJ's language model behind an API: the same questions the on-device model answers, sent as chat completions.
final class RemoteLLMBackend: SmartDJBackend, Sendable {
    let client: OpenAICompatibleClient
    private let ready = Atomic<Bool>(false)

    init(client: OpenAICompatibleClient) { self.client = client }

    var isLoaded: Bool { ready.load(ordering: .acquiring) }

    func load(model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        progress(0.3, "Connecting to \(client.config.provider.shortTitle)")
        do { _ = try await client.verifyConnection() } catch { throw SmartDJError.failed(error.localizedDescription) }
        ready.store(true, ordering: .releasing)
        progress(1, "Connected")
    }

    func generate(system: String, user: String, schema: String, maxTokens: Int) async throws -> String {
        guard isLoaded else { throw SmartDJError.stopped }
        do { return try await client.chatJSON(system: system, user: user, schema: schema, maxTokens: maxTokens) }
        catch { throw SmartDJError.failed(error.localizedDescription) }
    }

    func unload() async { ready.store(false, ordering: .releasing) }
}

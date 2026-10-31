import Foundation

/// Minimal HTTP abstraction so every online service can be tested with canned responses.
protocol HTTPClient: Sendable {
    /// Returns the body and status code. Throws only on transport errors.
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionClient: HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (d, r) = try await URLSession.shared.data(for: request)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum NetworkError: LocalizedError {
    case status(Int, String)
    case badResponse(String)
    var errorDescription: String? {
        switch self { case .status(let c, let u): "HTTP \(c) from \(u)"; case .badResponse(let m): m }
    }
}

/// The identification sent with every request. MusicBrainz asks for a meaningful User-Agent with a contact.
struct ClientIdentity {
    var app = "Aureon", version = "0.1", contact = "https://github.com/aureon-player/aureon"
    var userAgent: String { "\(app)/\(version) ( \(contact) )" }
}

/// Serialises calls and spaces them out (MusicBrainz allows one request per second per client).
actor RateLimiter {
    private let interval: TimeInterval
    private var next = Date.distantPast
    init(interval: TimeInterval) { self.interval = interval }
    func wait() async {
        let now = Date(), slot = max(now, next)
        next = slot.addingTimeInterval(interval)
        if slot > now { try? await Task.sleep(nanoseconds: UInt64(slot.timeIntervalSince(now) * 1_000_000_000)) }
    }
}

/// JSON-on-disk cache with a time-to-live per read.
final class MetadataCache: @unchecked Sendable {
    let directory: URL
    init(directory: URL? = nil) {
        directory_ = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Metadata", isDirectory: true)
        self.directory = directory_
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    private let directory_: URL

    private func file(_ key: String, ext: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." ? Character($0) : "_" }
        return directory.appendingPathComponent(String(safe) + "." + ext)
    }

    private func fresh(_ url: URL, _ ttl: TimeInterval) -> Bool {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(m) < ttl
    }

    func get<T: Decodable>(_ key: String, ttl: TimeInterval, as: T.Type = T.self) -> T? {
        let f = file(key, ext: "json")
        guard fresh(f, ttl), let d = try? Data(contentsOf: f) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    func put<T: Encodable>(_ key: String, _ value: T) { if let d = try? JSONEncoder().encode(value) { try? d.write(to: file(key, ext: "json")) } }

    func data(_ key: String, ttl: TimeInterval) -> Data? { let f = file(key, ext: "bin"); return fresh(f, ttl) ? try? Data(contentsOf: f) : nil }
    func putData(_ key: String, _ d: Data) { try? d.write(to: file(key, ext: "bin")) }
}

/// JSON helpers: tolerant access to API responses whose optional fields come and go.
typealias JSONObject = [String: Any]
extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func obj(_ k: String) -> JSONObject? { self[k] as? JSONObject }
    func arr(_ k: String) -> [JSONObject] { (self[k] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
    func strs(_ k: String) -> [String] { (self[k] as? [Any])?.compactMap { $0 as? String } ?? [] }
    func num(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
}

func parseJSON(_ d: Data) throws -> JSONObject {
    guard let o = try JSONSerialization.jsonObject(with: d) as? JSONObject else { throw NetworkError.badResponse("unexpected JSON shape") }
    return o
}

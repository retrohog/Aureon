import Foundation

struct RadioStation: Codable, Identifiable, Hashable {
    var id: String                // radio-browser station uuid, or "user-…" for stations added by hand
    var name: String
    var url: String               // direct stream address
    var favicon: String?
    var country: String?
    var countryCode: String?
    var language: String?
    var tags: [String]
    var codec: String             // MP3, AAC, AAC+, FLAC …
    var bitrate: Int              // kbit/s as reported by the station (0 = unknown)
    var votes: Int
    var homepage: String?

    var isLossless: Bool { codec.uppercased() == "FLAC" }
    var subtitle: String { [country, bitrate > 0 ? "\(bitrate) kbps" : nil, codec].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
    var isUserAdded: Bool { id.hasPrefix("user-") }
}

struct RadioFacet: Codable, Identifiable, Hashable {
    var name: String
    var code: String?             // country code or language code, when the directory has one
    var count: Int
    var id: String { (code ?? name) + "|" + name }
}

/// Free station directory from radio-browser.info (community-maintained, no account or key). Only streams Aureon can decode are offered:
/// MP3, AAC and FLAC over plain HTTP(S) — not HLS playlists.
final class RadioDirectory: @unchecked Sendable {
    static let playableCodecs: Set<String> = ["MP3", "AAC", "AAC+", "FLAC"]

    private let http: HTTPClient
    private let cache: MetadataCache
    private let servers: [String]
    private let identity: ClientIdentity
    private let ttl: TimeInterval

    init(http: HTTPClient = NetHTTPClient(), cache: MetadataCache = MetadataCache(), servers: [String] = ["de1.api.radio-browser.info", "nl1.api.radio-browser.info", "at1.api.radio-browser.info"],
         identity: ClientIdentity = ClientIdentity(), ttl: TimeInterval = 3600) {
        self.http = http; self.cache = cache; self.servers = servers; self.identity = identity; self.ttl = ttl
    }

    // MARK: queries

    struct Query: Equatable {
        var name: String?
        var countryCode: String?
        var language: String?
        var tag: String?
        var minBitrate: Int?
        var lossless = false
        var limit = 60
        var order = "votes"
    }

    func search(_ q: Query) async throws -> [RadioStation] {
        var items: [URLQueryItem] = [.init(name: "hidebroken", value: "true"), .init(name: "order", value: q.order), .init(name: "reverse", value: "true"),
                                     .init(name: "limit", value: String(min(500, q.limit * 3)))]    // fetch extra: unplayable codecs are dropped afterwards
        if let n = q.name, !n.isEmpty { items.append(.init(name: "name", value: n)) }
        if let c = q.countryCode, !c.isEmpty { items.append(.init(name: "countrycode", value: c.uppercased())) }
        if let l = q.language, !l.isEmpty { items.append(.init(name: "language", value: l.lowercased())); items.append(.init(name: "languageExact", value: "true")) }
        if let t = q.tag, !t.isEmpty { items.append(.init(name: "tag", value: t.lowercased())); items.append(.init(name: "tagExact", value: "true")) }
        if let b = q.minBitrate { items.append(.init(name: "bitrateMin", value: String(b))) }
        if q.lossless { items.append(.init(name: "codec", value: "FLAC")) }
        let body = try await get("/json/stations/search", items)
        return Self.parseStations(body, limit: q.limit)
    }

    func facets(_ kind: String) async throws -> [RadioFacet] {      // "tags" | "countries" | "languages"
        let key = "radio-facets-" + kind
        if let c: [RadioFacet] = cache.get(key, ttl: 24 * 3600) { return c }
        let items: [URLQueryItem] = [.init(name: "hidebroken", value: "true"), .init(name: "order", value: "stationcount"), .init(name: "reverse", value: "true")]
        let body = try await get("/json/" + kind, items)
        let facets = Self.parseFacets(body, kind: kind)
        if !facets.isEmpty { cache.put(key, facets) }
        return facets
    }

    /// Courtesy ping the directory asks for when a station is played (it drives the popularity ranking).
    func registerClick(_ station: RadioStation) async {
        guard !station.isUserAdded else { return }
        _ = try? await get("/json/url/" + station.id, [])
    }

    // MARK: transport

    private func get(_ path: String, _ items: [URLQueryItem]) async throws -> Data {
        var lastError: Error = NetworkError.badResponse("no radio directory server answered")
        for host in servers {
            var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = path; c.queryItems = items.isEmpty ? nil : items
            guard let url = c.url else { continue }
            // cached by what was asked, not by which mirror answered
            let key = "radio-" + path + "?" + (c.query ?? "")
            if let d = cache.data(key, ttl: ttl) { return d }
            var r = URLRequest(url: url, timeoutInterval: 15)
            r.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (d, status) = try await http.send(r)
                if status == 200 { cache.putData(key, d); return d }
                lastError = NetworkError.status(status, host)
            } catch { lastError = error }
        }
        throw lastError
    }

    // MARK: parsing

    static func parseStations(_ data: Data, limit: Int = .max) -> [RadioStation] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [JSONObject] else { return [] }
        var seen = Set<String>(), out: [RadioStation] = []
        for o in arr {
            guard let id = o.str("stationuuid"), let name = o.str("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let url = (o.str("url_resolved")?.isEmpty == false ? o.str("url_resolved") : o.str("url")) ?? ""
            let codec = (o.str("codec") ?? "").uppercased()
            guard !url.isEmpty, (url.hasPrefix("http://") || url.hasPrefix("https://")), playableCodecs.contains(codec),
                  (o.num("hls") ?? 0) == 0, (o.num("lastcheckok") ?? 1) == 1 else { continue }
            // directories list the same station many times under slightly different names
            let dedupe = ArtworkMatch.normalize(name) + "|" + (o.str("countrycode") ?? "")
            guard seen.insert(dedupe).inserted else { continue }
            out.append(RadioStation(id: id, name: name, url: url, favicon: o.str("favicon").flatMap { $0.isEmpty ? nil : $0 }, country: o.str("country").flatMap { $0.isEmpty ? nil : $0 },
                                    countryCode: o.str("countrycode").flatMap { $0.isEmpty ? nil : $0 }, language: o.str("language").flatMap { $0.isEmpty ? nil : $0 },
                                    tags: (o.str("tags") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(4).map { $0 },
                                    codec: codec, bitrate: Int(o.num("bitrate") ?? 0), votes: Int(o.num("votes") ?? 0), homepage: o.str("homepage")))
            if out.count >= limit { break }
        }
        return out
    }

    static func parseFacets(_ data: Data, kind: String) -> [RadioFacet] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [JSONObject] else { return [] }
        return arr.compactMap { o in
            guard let name = o.str("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty, let n = o.num("stationcount"), n >= (kind == "tags" ? 30 : 1) else { return nil }
            let code = o.str("iso_3166_1") ?? o.str("iso_639")
            return RadioFacet(name: name.prefix(1).uppercased() + name.dropFirst(), code: code.flatMap { $0.isEmpty ? nil : $0 }, count: Int(n))
        }
    }
}

/// Stations the user added by hand and the ones they starred, kept in one small JSON file.
final class RadioLibrary: @unchecked Sendable {
    struct Stored: Codable { var favorites: [RadioStation] = []; var custom: [RadioStation] = [] }
    private let url: URL
    private let lock = NSLock()
    private var stored: Stored

    init(url: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("radio.json")
        stored = (try? Data(contentsOf: self.url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    var favorites: [RadioStation] { lock.lock(); defer { lock.unlock() }; return stored.favorites }
    var custom: [RadioStation] { lock.lock(); defer { lock.unlock() }; return stored.custom }
    func isFavorite(_ s: RadioStation) -> Bool { lock.lock(); defer { lock.unlock() }; return stored.favorites.contains { $0.id == s.id } }

    func toggleFavorite(_ s: RadioStation) {
        lock.lock()
        if let i = stored.favorites.firstIndex(where: { $0.id == s.id }) { stored.favorites.remove(at: i) } else { stored.favorites.insert(s, at: 0) }
        lock.unlock(); save()
    }

    /// Adds a station from an address typed by the user.
    @discardableResult func addCustom(name: String, address: String) -> RadioStation? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: a), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { return nil }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let st = RadioStation(id: "user-" + UUID().uuidString, name: n.isEmpty ? (u.host ?? "Radio") : n, url: a, favicon: nil, country: nil, countryCode: nil, language: nil, tags: [], codec: "?", bitrate: 0, votes: 0, homepage: nil)
        lock.lock(); stored.custom.insert(st, at: 0); lock.unlock(); save()
        return st
    }

    func removeCustom(_ s: RadioStation) { lock.lock(); stored.custom.removeAll { $0.id == s.id }; lock.unlock(); save() }

    private func save() {
        lock.lock(); let s = stored; lock.unlock()
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }
}

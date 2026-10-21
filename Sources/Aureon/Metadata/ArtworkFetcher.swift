import Foundation
import CryptoKit

/// Decides whether a search hit really is the album we are looking for.
enum ArtworkMatch {
    /// Lower-case, diacritics folded, "(Deluxe Edition)" / "[Remastered]" and punctuation removed.
    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
        return t.split(separator: " ").joined(separator: " ")
    }

    private static func tokens(_ s: String) -> Set<String> { Set(normalize(s).split(separator: " ").map(String.init)) }

    /// 0…1 similarity: 1 for equal names, 0.85 when one contains the other, otherwise the token overlap.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }
        if x.contains(y) || y.contains(x) { return 0.85 }
        let tx = tokens(a), ty = tokens(b)
        return Double(tx.intersection(ty).count) / Double(max(tx.union(ty).count, 1))
    }

    static func isVariousArtists(_ s: String?) -> Bool {
        guard let s else { return true }
        let n = normalize(s)
        return n.isEmpty || n == "various artists" || n == "various" || n == "va"
    }

    /// A match score, or nil when the hit should be rejected (wrong album, or wrong artist when we know the artist).
    static func score(wantAlbum: String, wantArtist: String?, gotAlbum: String, gotArtist: String?) -> Double? {
        let album = similarity(wantAlbum, gotAlbum)
        guard album >= 0.6 else { return nil }
        if isVariousArtists(wantArtist) || gotArtist == nil { return album }
        // several artists "A, B" or "A feat. B": the best-matching one counts
        let wanted = wantArtist!.components(separatedBy: CharacterSet(charactersIn: ",;&/")).map { $0.trimmingCharacters(in: .whitespaces) } + [wantArtist!]
        let artist = wanted.map { similarity($0, gotArtist!) }.max() ?? 0
        guard artist >= 0.5 else { return nil }
        return album * 0.6 + artist * 0.4
    }
}

/// Finds cover art for albums whose files carry none: the iTunes Search API first (large, fast), MusicBrainz + the Cover Art Archive second.
///
/// Only the artist and album *names* leave the machine. Results are cached on disk, including "nothing found" (for a week), so each
/// album is looked up at most once. A network failure is never cached.
actor ArtworkFetcher {
    enum Source: String { case itunes, coverArtArchive }

    private let http: HTTPClient
    let directory: URL
    private let identity: ClientIdentity
    private let limiter: RateLimiter
    private let negativeTTL: TimeInterval
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private(set) var lastSource: Source?

    init(http: HTTPClient = URLSessionClient(), directory: URL? = nil, identity: ClientIdentity = ClientIdentity(),
         musicBrainzInterval: TimeInterval = 1.1, negativeTTL: TimeInterval = 7 * 86_400) {
        self.http = http; self.identity = identity; self.negativeTTL = negativeTTL
        self.limiter = RateLimiter(interval: musicBrainzInterval)
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    nonisolated static func key(artist: String?, album: String) -> String {
        let s = (ArtworkMatch.isVariousArtists(artist) ? "" : ArtworkMatch.normalize(artist ?? "")) + "|" + ArtworkMatch.normalize(album)
        return SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ key: String, _ ext: String) -> URL { directory.appendingPathComponent(key + "." + ext) }

    /// The cached cover, if one was fetched before. Never touches the network.
    func cached(artist: String?, album: String) -> Data? { try? Data(contentsOf: file(Self.key(artist: artist, album: album), "img")) }

    /// Cover art for an album, from the cache or the network; nil when nothing trustworthy was found.
    func cover(artist: String?, album: String, size: Int = 1200) async -> Data? {
        let album = album.trimmingCharacters(in: .whitespaces)
        guard !album.isEmpty else { return nil }
        let key = Self.key(artist: artist, album: album)
        if let d = try? Data(contentsOf: file(key, "img")) { return d }
        if let m = (try? FileManager.default.attributesOfItem(atPath: file(key, "none").path))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < negativeTTL { return nil }
        if let t = inFlight[key] { return await t.value }          // two tracks of one album ask at once: one lookup
        let task = Task<Data?, Never> { await self.lookup(artist: artist, album: album, size: size, key: key) }
        inFlight[key] = task
        let r = await task.value
        inFlight[key] = nil
        return r
    }

    private func lookup(artist: String?, album: String, size: Int, key: String) async -> Data? {
        var transportFailed = false
        for source in [Source.itunes, .coverArtArchive] {
            do {
                let found = source == .itunes ? try await itunes(artist: artist, album: album, size: size) : try await coverArtArchive(artist: artist, album: album, size: size)
                if let d = found {
                    try? d.write(to: file(key, "img"))
                    lastSource = source
                    return d
                }
            } catch { transportFailed = true }
        }
        if !transportFailed { try? Data().write(to: file(key, "none")) }
        return nil
    }

    // MARK: iTunes

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    /// An image worth showing: decodes, and is at least 200 px on its short side.
    private func usable(_ d: Data) -> Bool { ImageTools.size(d).map { min($0.0, $0.1) >= 200 } ?? false }

    private func itunes(artist: String?, album: String, size: Int) async throws -> Data? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: [ArtworkMatch.isVariousArtists(artist) ? nil : artist, album].compactMap { $0 }.joined(separator: " ")),
                        .init(name: "media", value: "music"), .init(name: "entity", value: "album"), .init(name: "limit", value: "10")]
        let (body, status) = try await http.send(request(c.url!))
        guard status == 200 else { if status >= 500 || status == 429 { throw NetworkError.status(status, "itunes") }; return nil }
        let hits = try parseJSON(body).arr("results").compactMap { r -> (Double, String)? in
            guard let name = r.str("collectionName"), let art = r.str("artworkUrl100"),
                  let s = ArtworkMatch.score(wantAlbum: album, wantArtist: artist, gotAlbum: name, gotArtist: r.str("artistName")) else { return nil }
            return (s, art)
        }.sorted { $0.0 > $1.0 }
        for (_, art) in hits.prefix(3) {
            guard let url = URL(string: art.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb")) else { continue }
            let (img, st) = try await http.send(request(url))
            if st == 200, usable(img) { return img }
        }
        return nil
    }

    // MARK: MusicBrainz + Cover Art Archive

    private func coverArtArchive(artist: String?, album: String, size: Int) async throws -> Data? {
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var query = "release:" + quote(album)
        if !ArtworkMatch.isVariousArtists(artist), let artist { query += " AND artist:" + quote(artist) }
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        c.queryItems = [.init(name: "query", value: query), .init(name: "fmt", value: "json"), .init(name: "limit", value: "8")]
        await limiter.wait()
        let (body, status) = try await http.send(request(c.url!))
        guard status == 200 else { if status >= 500 || status == 503 { throw NetworkError.status(status, "musicbrainz") }; return nil }
        let releases = try parseJSON(body).arr("releases").compactMap { r -> (Double, String)? in
            guard let id = r.str("id"), let title = r.str("title") else { return nil }
            let credit = r.arr("artist-credit").compactMap { $0.str("name") ?? $0.obj("artist")?.str("name") }.first
            guard let s = ArtworkMatch.score(wantAlbum: album, wantArtist: artist, gotAlbum: title, gotArtist: credit) else { return nil }
            return (s + (r.num("score") ?? 0) / 1000, id)
        }.sorted { $0.0 > $1.0 }
        for (_, id) in releases.prefix(3) {
            for path in ["front-\(size >= 1000 ? 1200 : 500)", "front"] {
                guard let url = URL(string: "https://coverartarchive.org/release/\(id)/\(path)") else { continue }
                let (img, st) = try await http.send(request(url))
                if st == 200, usable(img) { return img }
                if st >= 500 { throw NetworkError.status(st, "coverartarchive") }
            }
        }
        return nil
    }
}

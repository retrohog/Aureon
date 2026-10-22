import Foundation

// LRCLIB (lrclib.net): a free, open database of time-synced lyrics. The only things sent are the song's title, artist, album and length. The
// results are kept on this Mac (LyricsStore), so a song is asked about once.

struct OnlineLyrics: Equatable, Sendable {
    var synced: String?
    var plain: String?
    var instrumental = false
    var title = "", artist = ""
}

struct LRCLIBClient: Sendable {
    var http: HTTPClient = URLSessionClient()
    var base = URL(string: "https://lrclib.net/api")!
    var identity = ClientIdentity()
    var timeout: TimeInterval = 12
    /// LRCLIB answers 502/503/504 now and then when it is busy; one more try a moment later usually gets through.
    var retryDelay: TimeInterval = 0.8

    /// Looks the song up: first by exact match (title, artist, album and length), then by search. Nil when the database has nothing for it.
    /// Throws on a network failure, which says nothing about whether the song is in the database.
    func lookup(_ r: LyricsRequest) async throws -> OnlineLyrics? {
        guard !r.title.isEmpty else { return nil }
        if r.duration > 0, !r.artist.isEmpty, !r.album.isEmpty {
            let (data, status) = try await get("get", [("track_name", r.title), ("artist_name", r.artist), ("album_name", r.album), ("duration", String(Int(r.duration.rounded())))])
            if status == 200, let o = Self.parseObject(data) { return o }
            if status != 404 && status != 400 { throw NetworkError.status(status, "lrclib.net") }
        }
        var query = [("track_name", r.title)]
        if !r.artist.isEmpty { query.append(("artist_name", r.artist)) }
        let (data, status) = try await get("search", query)
        guard status == 200 else { if status == 404 { return nil }; throw NetworkError.status(status, "lrclib.net") }
        return Self.best(in: Self.parseArray(data), for: r)
    }

    private func get(_ path: String, _ query: [(String, String)]) async throws -> (Data, Int) {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        // URLQueryItem leaves "+" alone and LRCLIB reads it as a space, so titles like "Florence + the Machine" never matched
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        c.percentEncodedQueryItems = query.map { URLQueryItem(name: $0.0, value: $0.1.addingPercentEncoding(withAllowedCharacters: safe)) }
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let first = try await http.send(req)
        guard [502, 503, 504].contains(first.1) else { return first }
        try await Task.sleep(nanoseconds: UInt64(max(0, retryDelay) * 1_000_000_000))
        return try await http.send(req)
    }

    // MARK: reading answers

    struct Candidate: Equatable, Sendable {
        var lyrics: OnlineLyrics
        var duration: Double
    }

    static func parseObject(_ data: Data) -> OnlineLyrics? { candidate(from: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?.lyrics }

    static func parseArray(_ data: Data) -> [Candidate] {
        guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return a.compactMap { candidate(from: $0) }
    }

    private static func candidate(from o: [String: Any]?) -> Candidate? {
        guard let o else { return nil }
        func text(_ k: String) -> String? { (o[k] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        var l = OnlineLyrics(synced: text("syncedLyrics"), plain: text("plainLyrics"), instrumental: (o["instrumental"] as? Bool) == true)
        l.title = (o["trackName"] as? String) ?? ""; l.artist = (o["artistName"] as? String) ?? ""
        guard l.synced != nil || l.plain != nil || l.instrumental else { return nil }
        return Candidate(lyrics: l, duration: (o["duration"] as? Double) ?? Double((o["duration"] as? Int) ?? 0))
    }

    /// The search result that is the song: same title and artist (ignoring case and punctuation), a length within a few seconds, and synced
    /// lyrics preferred over plain ones.
    static func best(in found: [Candidate], for r: LyricsRequest) -> OnlineLyrics? {
        func norm(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber } }
        let title = norm(r.title), artist = norm(r.artist)
        var best: (score: Double, lyrics: OnlineLyrics)?
        for c in found {
            let t = norm(c.lyrics.title), a = norm(c.lyrics.artist)
            var score = 0.0
            if t == title { score += 4 } else if !title.isEmpty, t.contains(title) || title.contains(t), min(t.count, title.count) >= 4 { score += 1.5 } else { continue }
            if !artist.isEmpty {
                if a == artist { score += 3 } else if a.contains(artist) || artist.contains(a), min(a.count, artist.count) >= 3 { score += 1.5 } else { continue }
            }
            if r.duration > 0, c.duration > 0 {
                let d = abs(c.duration - r.duration)
                if d > 8 { continue }
                score += d <= 2 ? 2 : (d <= 4 ? 1 : 0)
            }
            if c.lyrics.synced != nil { score += 4 } else if c.lyrics.plain != nil { score += 0.5 }
            if best == nil || score > best!.score { best = (score, c.lyrics) }
        }
        return best?.lyrics
    }
}

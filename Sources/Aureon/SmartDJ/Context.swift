import Foundation

// Smart DJ, part 2: the part of the library the model gets to see.

/// What the DJ knows about one song (library data plus, when the DJ console has analysed it, tempo, key and energy).
struct SmartDJTrack: Equatable {
    var track: TrackDTO
    var bpm: Double?
    var energy: Double?          // 0…1
    var key: String?             // Camelot code, e.g. "8A"

    var artist: String { track.primaryArtistLine }
    var genre: String? { track.genres.first }
    var year: Int? { track.year }
}

enum Relevance {
    /// How well a song fits the request. Higher is better; the numbers are only meaningful relative to each other.
    static func score(_ t: SmartDJTrack, _ i: DJIntent) -> Double {
        var s = 0.0
        let genres = t.track.genres.map { $0.lowercased().replacingOccurrences(of: "-", with: " ") }
        if !i.avoidGenres.isEmpty, genres.contains(where: { g in i.avoidGenres.contains { g.contains($0) } }) { s -= 8 }
        if !i.genres.isEmpty {
            let hit = genres.contains { g in i.genres.contains { want in g.contains(want.replacingOccurrences(of: "-", with: " ")) || want.replacingOccurrences(of: "-", with: " ").contains(g) } }
            s += hit ? 4 : -3
        }
        if !i.artists.isEmpty {
            let names = (t.track.names(.artist) + t.track.names(.albumArtist)).map { $0.lowercased() }
            s += names.contains { n in i.artists.contains { n.contains($0) || $0.contains(n) } } ? 5 : -2
        }
        if let r = i.bpm {
            if let b = t.bpm {
                // half- and double-time count: a 70 BPM ballad "feels" 140 to a workout list only if it is also energetic, so no folding here
                if r.contains(b) { s += 2 } else { s -= min(3, (b < r.lowerBound ? r.lowerBound - b : b - r.upperBound) / 20) }
            } else { s -= 0.5 }
        }
        if let e = i.energy, let v = t.energy {
            switch e {
            case .high: s += v >= 0.55 ? 1.5 : (v >= 0.4 ? 0 : -1.5)
            case .low: s += v <= 0.4 ? 1.5 : (v <= 0.55 ? 0 : -1.5)
            case .medium: s += abs(v - 0.5) < 0.2 ? 1 : -0.5
            }
        }
        if !i.decades.isEmpty || i.years != nil {
            if let y = t.year {
                let inDecade = i.decades.contains { y >= $0 && y < $0 + 10 }
                let inYears = i.years.map { $0.contains(y) } ?? false
                s += (inDecade || inYears) ? 2.5 : -2
            } else { s -= 0.5 }
        }
        if !i.keywords.isEmpty {
            let hay = (t.track.title + " " + (t.track.releaseTitle ?? "") + " " + t.artist).lowercased()
            s += min(3, Double(i.keywords.filter { hay.contains($0) }.count))
        }
        if i.onlyLiked { s += t.track.isLiked ? 3 : -6 } else if t.track.isLiked { s += 0.4 }
        s += min(0.4, Double(t.track.playCount ?? 0) * 0.04)
        return s
    }
}

struct SmartDJCandidate: Equatable {
    var id: Int                  // the short id the model sees
    var song: SmartDJTrack
    var score: Double
}

struct SmartDJPrompt {
    var system: String
    var user: String
    var schema: String                   // JSON schema text for the answer
    var candidates: [SmartDJCandidate]
    var count: Int                       // how many tracks the answer must contain
    var contextJSON: String
}

enum ContextBuilder {
    /// Picks the candidates: the best matches first, no artist taking over the list, a little randomness so the same request does not always give the same set.
    static func candidates<R: RandomNumberGenerator>(from library: [SmartDJTrack], intent: DJIntent, limit: Int = 60, using rng: inout R) -> [SmartDJCandidate] {
        guard !library.isEmpty else { return [] }
        var scored = library.map { (song: $0, score: Relevance.score($0, intent)) }
        // jitter: small enough never to reorder a clear difference, large enough to shuffle ties
        for i in scored.indices { scored[i].score += Double.random(in: 0..<0.9, using: &rng) }
        scored.sort { $0.score > $1.score }
        // no artist may fill the list, but when only a few artists fit the request each has to be allowed enough songs to reach `limit`
        let tier = scored.prefix(limit)
        let distinct = max(1, Set(tier.map { $0.song.artist.lowercased() }).count)
        let perArtist = intent.artists.isEmpty ? max(3, Int((Double(limit) / Double(distinct)).rounded(.up))) : max(10, Int((Double(limit) / Double(distinct)).rounded(.up)))
        var taken: [(song: SmartDJTrack, score: Double)] = [], perCount: [String: Int] = [:]
        for s in scored {
            let a = s.song.artist.lowercased()
            if perCount[a, default: 0] >= perArtist { continue }
            perCount[a, default: 0] += 1
            taken.append(s)
            if taken.count >= limit { break }
        }
        if taken.count < min(limit, library.count) {                       // artist cap left too few: relax it
            let have = Set(taken.map { $0.song.track.path })
            for s in scored where !have.contains(s.song.track.path) { taken.append(s); if taken.count >= limit { break } }
        }
        // the model leans toward the top of a list: present the candidates in a shuffled order so position carries no information
        var order = Array(taken.indices)
        order.shuffle(using: &rng)
        return order.enumerated().map { SmartDJCandidate(id: $0.offset + 1, song: taken[$0.element].song, score: taken[$0.element].score) }
    }

    static func tags(_ s: SmartDJTrack) -> [String] {
        var t: [String] = []
        if let b = s.bpm { t.append(b >= 125 ? "fast" : (b >= 100 ? "mid-tempo" : "slow")) }
        if let e = s.energy { t.append(e >= 0.6 ? "high-energy" : (e <= 0.35 ? "calm" : "balanced")) }
        if let y = s.year { t.append("\(y / 10 % 10)0s") }
        for g in s.track.genres.dropFirst().prefix(2) { t.append(g.lowercased()) }
        if s.track.isLiked { t.append("liked") }
        return t
    }

    private static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }

    /// One compact JSON array: [{"i":1,"a":"Artist","t":"Title","g":"Genre","b":123,"y":2001,"k":"8A","tags":["fast","2000s"]}, …]
    static func json(_ c: [SmartDJCandidate]) -> String {
        let rows: [[String: Any]] = c.map { x in
            var r: [String: Any] = ["i": x.id, "a": clip(x.song.artist, 28), "t": clip(x.song.track.title, 40)]
            if let g = x.song.genre { r["g"] = clip(g, 20) }
            if let b = x.song.bpm { r["b"] = Int(b.rounded()) }
            if let y = x.song.year { r["y"] = y }
            if let k = x.song.key { r["k"] = k }
            let t = tags(x.song); if !t.isEmpty { r["tags"] = t }
            return r
        }
        guard let d = try? JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes, .sortedKeys]) else { return "[]" }
        return String(decoding: d, as: UTF8.self)
    }

    static let systemPrompt = """
    You are the DJ of a music player. You get a list of tracks as JSON (i = id, a = artist, t = title, g = genre, b = tempo in BPM, y = year, k = key, tags = descriptive words) and a request from the listener. \
    Choose the tracks that best fit the request and put them in an order that flows well, with energy building or holding steady. \
    Use only ids from the list and never repeat an id. Answer with JSON only: {"ids":[...]}
    """

    static func schema(ids: [Int], count: Int) -> String {
        let list = ids.map(String.init).joined(separator: ",")
        return #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"integer","enum":[\#(list)]},"minItems":\#(count),"maxItems":\#(count)}},"required":["ids"],"additionalProperties":false}"#
    }

    static func prompt(request: String, intent: DJIntent, candidates: [SmartDJCandidate]) -> SmartDJPrompt {
        let n = min(intent.count, candidates.count)
        let ctx = json(candidates)
        let user = "Request: \(request.trimmingCharacters(in: .whitespacesAndNewlines))\nNumber of tracks to choose: \(n)\nTracks:\n\(ctx)"
        return SmartDJPrompt(system: systemPrompt, user: user, schema: schema(ids: candidates.map(\.id), count: n), candidates: candidates, count: n, contextJSON: ctx)
    }
}

/// Turns the model's answer into a playlist, and makes sure it is a good one whatever the model did.
enum SmartDJSelection {
    /// Ids in the order the model gave them. Tolerates code fences, prose around the JSON, a bare array and numbers written as strings.
    static func parse(_ text: String, valid: Set<Int>) -> [Int] {
        func ids(from v: Any) -> [Int]? {
            if let a = v as? [Any] { return a.compactMap { ($0 as? NSNumber)?.intValue ?? Int(($0 as? String) ?? "") } }
            if let o = v as? [String: Any] { for k in ["ids", "tracks", "playlist", "selection"] { if let x = o[k], let r = ids(from: x) { return r } } }
            return nil
        }
        var found: [Int] = []
        let bytes = Array(text.utf8)
        // try the whole text, then the first {...} or [...] block
        var spans: [Range<Int>] = [0..<bytes.count]
        for (open, close) in [(UInt8(ascii: "{"), UInt8(ascii: "}")), (UInt8(ascii: "["), UInt8(ascii: "]"))] {
            if let a = bytes.firstIndex(of: open), let b = bytes.lastIndex(of: close), a < b { spans.append(a..<(b + 1)) }
        }
        for s in spans {
            if let o = try? JSONSerialization.jsonObject(with: Data(bytes[s])), let r = ids(from: o) { found = r; break }
        }
        var seen = Set<Int>(), out: [Int] = []
        for i in found where valid.contains(i) && seen.insert(i).inserted { out.append(i) }
        return out
    }

    struct Outcome: Equatable {
        var picks: [SmartDJCandidate]
        var fromModel = 0                // how many of the picks are the model's own
        var rejected = 0                 // model picks dropped because they did not fit the request
        var filled = 0                   // picks added by the ranking to reach the count
    }

    /// Model picks first (checked against the request), then the best-scoring remaining candidates until there are `count`.
    static func finalize(modelIDs: [Int], candidates: [SmartDJCandidate], count: Int, minScore: Double) -> Outcome {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var out = Outcome(picks: [])
        var used = Set<Int>()
        for id in modelIDs {
            guard out.picks.count < count, let c = byID[id], used.insert(id).inserted else { continue }
            if c.score < minScore { out.rejected += 1; continue }
            out.picks.append(c); out.fromModel += 1
        }
        if out.picks.count < count {
            for c in candidates.sorted(by: { $0.score > $1.score }) where !used.contains(c.id) {
                out.picks.append(c); used.insert(c.id); out.filled += 1
                if out.picks.count >= count { break }
            }
        }
        return out
    }

    /// How low a score may be and still be an acceptable pick: 4.5 under what the N-th best song in the whole library scores, which tolerates a
    /// tempo or energy that is a little off but not a song of the wrong genre, artist or decade.
    static func minScore(library: [SmartDJTrack], intent: DJIntent) -> Double {
        guard intent.hasConstraints else { return -.infinity }
        let scores = library.map { Relevance.score($0, intent) }.sorted(by: >)
        guard !scores.isEmpty else { return -.infinity }
        return scores[min(intent.count, scores.count) - 1] - 4.5
    }
}

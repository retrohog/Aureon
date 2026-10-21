import Foundation

enum ShuffleMode: String, Codable, CaseIterable, Identifiable {
    case off, normal, smart
    var id: String { rawValue }
    var title: String { switch self { case .off: "Off"; case .normal: "Shuffle"; case .smart: "Smart Shuffle" } }
    var blurb: String {
        switch self {
        case .off: "Play in order"
        case .normal: "Random order"
        case .smart: "Mixes it up without back-to-back artists, favours liked songs and tracks that flow into each other"
        }
    }
    var icon: String { self == .smart ? "sparkles" : "shuffle" }
}

/// What the shuffler knows about a queued song.
struct ShuffleCandidate {
    var id: UUID
    var path: String
    var artist = ""
    var album = ""
    var genres: [String] = []
    var year: Int?
    var liked = false
    var playCount = 0
    var lastPlayedAt: Double?
    var analysis: DJTrackAnalysis?
}

/// Small deterministic generator so shuffles can be tested.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum Shuffler {
    /// A plain random order (Fisher–Yates).
    static func normal<R: RandomNumberGenerator>(_ ids: [UUID], using rng: inout R) -> [UUID] {
        var a = ids
        if a.count > 1 { for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, Int.random(in: 0...i, using: &rng)) } }
        return a
    }

    /// How good `next` would be right after `prev` (and `prev2` before it). Higher is better.
    static func affinity(prev: ShuffleCandidate?, prev2: ShuffleCandidate?, next c: ShuffleCandidate, now: Double, net: TransitionNet?) -> Double {
        var s = 0.0
        if let p = prev {
            let same = !c.artist.isEmpty && c.artist == p.artist
            if same { s -= 0.9 }
            if !c.album.isEmpty && c.album == p.album { s -= 0.5 }
            if let p2 = prev2, !c.artist.isEmpty, c.artist == p2.artist, !same { s -= 0.35 }
            if !Set(c.genres).isDisjoint(with: p.genres) { s += 0.25 }
            if let a = c.year, let b = p.year { s += 0.15 * (1 - min(Double(abs(a - b)), 25) / 25) }
            if let na = p.analysis, let nb = c.analysis, let f = TransitionFeatures(from: na, to: nb), let net { s += (Double(net.score(f)) - 0.5) * 0.9 }
        }
        if c.liked { s += 0.35 }
        s += 0.12 / Double(1 + c.playCount)                                  // a little love for the songs you have heard least
        if let last = c.lastPlayedAt, now - last < 3 * 86_400 { s -= 0.3 }   // not the song from this morning
        return s
    }

    /// An order that avoids repeating artists and albums, prefers songs that suit each other and favours liked ones, with enough randomness
    /// that it never plays the same set twice. `start` (the song that is playing) stays first when given.
    static func smart<R: RandomNumberGenerator>(_ items: [ShuffleCandidate], start: ShuffleCandidate? = nil, now: Double = Date().timeIntervalSince1970, net: TransitionNet? = nil, using rng: inout R) -> [UUID] {
        var pool = items.filter { $0.id != start?.id }
        var out: [ShuffleCandidate] = start.map { [$0] } ?? []
        out.reserveCapacity(items.count)
        while !pool.isEmpty {
            let prev = out.last, prev2 = out.count >= 2 ? out[out.count - 2] : nil
            // a big library is sampled instead of scored in full at every step
            let indices: [Int] = pool.count <= 120 ? Array(pool.indices) : (0..<120).map { _ in Int.random(in: 0..<pool.count, using: &rng) }
            var best = indices[0], bestScore = -Double.infinity
            for i in indices {
                let score = affinity(prev: prev, prev2: prev2, next: pool[i], now: now, net: net) + Double.random(in: 0...0.45, using: &rng)
                if score > bestScore { bestScore = score; best = i }
            }
            out.append(pool.remove(at: best))
        }
        return out.map(\.id)
    }

    /// The order that restores `original` for the songs still in the queue, with newcomers last.
    static func restore(current order: [UUID], original: [UUID]) -> [UUID] {
        let rank = Dictionary(original.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return order.enumerated().sorted { a, b in
            let ra = rank[a.element] ?? Int.max, rb = rank[b.element] ?? Int.max
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }
}

import Foundation

// How well one analysed track follows another, by ordinary DJ rules of thumb (plain arithmetic, no model). Balanced Shuffle uses it to order a queue.

/// What the network sees about a pair of tracks: A is playing, B is a candidate to follow it.
struct TransitionFeatures: Equatable, Codable {
    static let count = 9
    var v: [Float]

    init(_ v: [Float]) { self.v = v }

    init?(from a: DJTrackAnalysis, to b: DJTrackAnalysis) {
        guard let ba = a.bpm, let bb = b.bpm, ba > 0, bb > 0 else { return nil }
        let ratio = Self.bestTempoRatio(from: ba, to: bb)
        let tempo = Float(min(1, abs(ratio - 1) / 0.16))
        let key: Float = (a.key != nil && b.key != nil) ? Float(a.key!.distance(to: b.key!)) / 6 : 0.5
        let de = Float(b.energy - a.energy)
        let dl = Float(max(-1, min(1, (b.loudness - a.loudness) / 12)))
        v = [tempo, key, de, abs(de), abs(dl), Float(a.keyStrength * b.keyStrength), Float(a.confidence * b.confidence), Float(a.energy), Float(b.energy)]
    }

    /// The factor to play B at to match A, allowing half or double time.
    static func bestTempoRatio(from a: Double, to b: Double) -> Double {
        [a / b, a / (2 * b), 2 * a / b].min { abs($0 - 1) < abs($1 - 1) }!
    }
}

extension TransitionFeatures {
    /// How well B follows A by the usual DJ rules of thumb (match the tempo, keep the key compatible, avoid big jumps in energy and loudness). 0…1.
    static func ruleScore(_ f: [Float]) -> Float {
        let tempo = f[0], key = f[1], dE = f[2], aE = f[3], dL = f[4], keyConf = f[5], beatConf = f[6]
        var bad = 0.42 * tempo * (0.4 + 0.6 * beatConf)         // an unreliable tempo estimate is penalised less
        bad += 0.30 * (key > 0.2 ? min(1, key * 1.4) : 0) * (0.3 + 0.7 * min(1, keyConf * 4))
        bad += 0.12 * aE + 0.10 * dL + 0.06 * max(0, dE)       // big jumps, and a sudden step up, cost a little
        return max(0, min(1, 1 - bad))
    }
}

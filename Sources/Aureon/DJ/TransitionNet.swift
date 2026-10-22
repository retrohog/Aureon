import Foundation

// The transition network: a small feed-forward network (about 200 weights) that scores how well one analysed track follows another.
// It starts from a network trained, in a fraction of a second at first use, on examples generated from ordinary DJ rules of thumb
// (match the tempo, keep the key compatible, avoid big jumps in energy and loudness). Smart shuffle uses it to order a queue.
// Everything stays on this Mac.

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

/// A 9 → 12 → 6 → 1 network with tanh hidden units and a sigmoid output: the probability that a mix between two tracks is a good one.
final class TransitionNet {
    static let sizes = [TransitionFeatures.count, 12, 6, 1]
    private(set) var w: [[Float]]          // per layer: weights (out × in, row-major) followed by biases
    private(set) var feedbackCount = 0

    private struct Stored: Codable { var w: [[Float]]; var feedback: Int; var version: Int }
    static let version = 1

    init(weights: [[Float]]) { w = weights }

    /// Small deterministic generator, so a "fresh" network is the same on every launch and in tests.
    private struct LCG { var s: UInt64; mutating func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) } }

    static func fresh(seed: UInt64 = 7) -> TransitionNet {
        var g = LCG(s: seed)
        var layers: [[Float]] = []
        for l in 0..<(sizes.count - 1) {
            let i = sizes[l], o = sizes[l + 1], scale = (6 / Float(i + o)).squareRoot()
            layers.append((0..<(o * i)).map { _ in (g.next() * 2 - 1) * scale } + [Float](repeating: 0, count: o))
        }
        return TransitionNet(weights: layers)
    }

    /// The rule of thumb used to teach the network before it has heard any opinions. 0…1.
    static func ruleScore(_ f: [Float]) -> Float {
        let tempo = f[0], key = f[1], dE = f[2], aE = f[3], dL = f[4], keyConf = f[5], beatConf = f[6]
        var bad = 0.42 * tempo * (0.4 + 0.6 * beatConf)         // an unreliable tempo estimate is penalised less
        bad += 0.30 * (key > 0.2 ? min(1, key * 1.4) : 0) * (0.3 + 0.7 * min(1, keyConf * 4))
        bad += 0.12 * aE + 0.10 * dL + 0.06 * max(0, dE)       // big jumps, and a sudden step up, cost a little
        return max(0, min(1, 1 - bad))
    }

    func forward(_ x: [Float]) -> Float {
        var a = x
        for l in 0..<(Self.sizes.count - 1) {
            let i = Self.sizes[l], o = Self.sizes[l + 1]
            var out = [Float](repeating: 0, count: o)
            for r in 0..<o {
                var s = w[l][o * i + r]
                for c in 0..<i { s += w[l][r * i + c] * a[c] }
                out[r] = l == Self.sizes.count - 2 ? s : tanh(s)
            }
            a = out
        }
        return 1 / (1 + exp(-a[0]))
    }

    func score(_ f: TransitionFeatures) -> Float { forward(f.v) }

    /// One step of gradient descent on the squared error towards `target` (0…1).
    func train(_ x: [Float], target: Float, rate: Float) {
        let L = Self.sizes.count - 1
        var acts: [[Float]] = [x]
        for l in 0..<L {
            let i = Self.sizes[l], o = Self.sizes[l + 1]
            var out = [Float](repeating: 0, count: o)
            for r in 0..<o { var s = w[l][o * i + r]; for c in 0..<i { s += w[l][r * i + c] * acts[l][c] }; out[r] = l == L - 1 ? 1 / (1 + exp(-s)) : tanh(s) }
            acts.append(out)
        }
        var delta = [(acts[L][0] - target) * acts[L][0] * (1 - acts[L][0])]
        for l in stride(from: L - 1, through: 0, by: -1) {
            let i = Self.sizes[l], o = Self.sizes[l + 1]
            var prev = [Float](repeating: 0, count: i)
            for r in 0..<o {
                for c in 0..<i { prev[c] += delta[r] * w[l][r * i + c]; w[l][r * i + c] -= rate * delta[r] * acts[l][c] }
                w[l][o * i + r] -= rate * delta[r]
            }
            if l > 0 { delta = (0..<i).map { prev[$0] * (1 - acts[l][$0] * acts[l][$0]) } }
        }
    }

    /// Teaches the network the rules of thumb from generated examples.
    func pretrain(samples: Int = 6_000, epochs: Int = 4, seed: UInt64 = 11) {
        var g = LCG(s: seed)
        for e in 0..<epochs {
            let rate: Float = 0.25 / Float(e + 1)
            for _ in 0..<samples {
                let aE = g.next(), bE = g.next()
                let f: [Float] = [pow(g.next(), 1.6), g.next() < 0.3 ? 0 : g.next(), bE - aE, abs(bE - aE), pow(g.next(), 2), g.next(), g.next(), aE, bE]
                train(f, target: Self.ruleScore(f), rate: rate)
            }
        }
    }

    /// The listener's verdict on a transition that was played.
    func feedback(_ f: TransitionFeatures, liked: Bool, rate: Float = 0.12) {
        for _ in 0..<3 { train(f.v, target: liked ? 0.97 : 0.03, rate: rate) }
        feedbackCount += 1
    }

    func data() -> Data? { try? JSONEncoder().encode(Stored(w: w, feedback: feedbackCount, version: Self.version)) }

    static func load(_ d: Data) -> TransitionNet? {
        guard let s = try? JSONDecoder().decode(Stored.self, from: d), s.version == version, s.w.count == sizes.count - 1 else { return nil }
        for l in 0..<s.w.count where s.w[l].count != sizes[l + 1] * sizes[l] + sizes[l + 1] { return nil }
        let n = TransitionNet(weights: s.w); n.feedbackCount = s.feedback
        return n
    }

    static var storeURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/auto-dj.json") }

    /// The saved network, or a freshly pretrained one.
    static func loadOrCreate(at url: URL = storeURL) -> TransitionNet {
        if let d = try? Data(contentsOf: url), let n = load(d) { return n }
        let n = fresh(); n.pretrain(); return n
    }
    func save(to url: URL = TransitionNet.storeURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = data() { try? d.write(to: url, options: .atomic) }
    }
}

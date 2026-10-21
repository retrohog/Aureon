import Foundation

// Auto DJ: what to play next, and how to get there.
//
// There is no language model here. The "AI" is a small feed-forward network (about 200 weights) that scores how good a transition between two
// analysed tracks would sound. It starts from a network trained, in a fraction of a second at first use, on examples generated from ordinary
// DJ rules of thumb (match the tempo, keep the key compatible, avoid big jumps in energy and loudness), and it keeps learning from the
// thumbs-up / thumbs-down the listener gives mixes. Everything stays on this Mac. The mixing itself (when to start, how long to blend,
// the bass swap) is plain, deterministic code that can be tested without any audio.

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

enum AutoVibe: String, CaseIterable, Identifiable, Codable {
    case steady, build, wind
    var id: String { rawValue }
    var title: String { switch self { case .steady: "Steady"; case .build: "Build up"; case .wind: "Wind down" } }
    /// How much the next track's energy relative to the current one is wanted: positive = higher.
    var energyTrend: Float { switch self { case .steady: 0; case .build: 0.12; case .wind: -0.12 } }
}

struct AutoCandidate: Equatable {
    var track: DJTrack
    var analysis: DJTrackAnalysis
}

enum AutoPlanner {
    /// Ranks the candidates to follow `current`. Recently played tracks are skipped; `strictKey` rules out clashing keys altogether.
    static func rank(current: DJTrackAnalysis, candidates: [AutoCandidate], recent: [String], vibe: AutoVibe, strictKey: Bool, net: TransitionNet) -> [(candidate: AutoCandidate, score: Float)] {
        var out: [(AutoCandidate, Float)] = []
        for c in candidates where !recent.contains(c.track.path) {
            guard let f = TransitionFeatures(from: current, to: c.analysis) else { continue }
            if strictKey, let ka = current.key, let kb = c.analysis.key, !ka.compatible(with: kb) { continue }
            var s = net.score(f)
            // steer the energy curve: reward the wanted direction, mildly
            let de = Float(c.analysis.energy - current.energy)
            s += 0.12 * (1 - min(1, abs(de - vibe.energyTrend) / 0.5)) - 0.06
            out.append((c, s))
        }
        return out.sorted { $0.1 > $1.1 }.map { (candidate: $0.0, score: $0.1) }
    }
}

/// The timing of one transition, in seconds on each track's own clock.
struct MixPlan: Equatable {
    /// Position in track A at which B starts (and the blend begins).
    var aStart: Double
    /// Where B is started in its own timeline (a beat on its grid, usually the first beat after its intro silence).
    var bStart: Double
    var duration: Double
    /// Speed ratio B must be played at to match A's tempo (1 = unchanged).
    var bRatio: Double
    var beats: Int
}

enum AutoMixer {
    /// Plans a blend of `beats` beats (rounded to a phrase) that ends where A's outro ends.
    static func plan(a: DJTrackAnalysis, aRatio: Double, b: DJTrackAnalysis, beats requested: Int, maxPitch: Double = 0.16) -> MixPlan? {
        guard let bpmA = a.bpm, let bpmB = b.bpm, bpmA > 0, bpmB > 0 else { return nil }
        let tempoA = bpmA * aRatio
        let ratio = max(1 - maxPitch, min(1 + maxPitch, FeaturesTempo.ratio(tempoA, bpmB)))
        let beatSec = 60 / (bpmA * aRatio)                   // seconds of real time per beat while A plays
        let beats = max(4, min(requested, Int(a.duration * 0.5 / beatSec)))      // never more than half of a short track
        let duration = Double(beats) * beatSec
        // end the blend at A's outro end (its natural ending when the track has no marked outro), on a beat of A's grid
        let end = a.duration
        var start = end - duration
        if let o = a.outroStart { start = max(o - duration * 0.25, min(start, o + duration * 0.1)) }
        start = max(0, min(start, end - duration))
        if let near = a.nearestBeat(to: start) { start = near >= 0 && near + duration <= end + 1e-6 ? near : start }
        // B starts on a beat; if it has an intro, begin at its first beat, otherwise at the very start of its grid
        let bFirst = b.firstBeat ?? 0
        let bStart = bFirst
        return MixPlan(aStart: start, bStart: bStart, duration: duration, bRatio: ratio, beats: beats)
    }

    /// Everything that moves during a blend, for progress `p` in 0…1.
    struct Frame: Equatable {
        var gainA: Double, gainB: Double        // crossfader gains (equal power)
        var lowA: Double, lowB: Double          // low EQ in dB (bass swap)
        var filterA: Double                     // high-pass sweep on the outgoing deck, 0…1
    }

    static func frame(_ p: Double) -> Frame {
        let p = max(0, min(1, p.isFinite ? p : 0))
        let s = p * p * (3 - 2 * p)                                     // smoothstep
        let t = s * .pi / 2
        // the bass changes hands in one move in the middle, two decks' low end never play together
        let swap = max(0, min(1, (p - 0.45) / 0.1))
        let sw = swap * swap * (3 - 2 * swap)
        return Frame(gainA: cos(t), gainB: sin(t), lowA: DJMath.eqRange.lowerBound * sw, lowB: DJMath.eqRange.lowerBound * (1 - sw), filterA: max(0, (p - 0.5) * 1.2))
    }
}

enum FeaturesTempo {
    /// The speed factor that brings track B (bpm `b`) to tempo `a`, allowing half and double time.
    static func ratio(_ a: Double, _ b: Double) -> Double { TransitionFeatures.bestTempoRatio(from: a, to: b) }
}

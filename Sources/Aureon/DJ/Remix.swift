import Foundation

// AI Remixer: a live arrangement layer on top of a playing deck.
//
// It does not separate stems or generate new audio. What it does is what a DJ does with the controls in front of them: on bar boundaries it picks a
// move (filter sweep, echo-out, reverb wash, loop roll, bass drop, riser, stutter, flanger sweep) according to where the track is (intro, build,
// phrase end, outro) and what is about to happen to its energy, and performs it with the deck's own filter, effects, EQ and loops. "Which move now?"
// is answered by a small neural network (a few hundred weights) that starts from DJ rules of thumb and learns from thumbs-up / thumbs-down.
// The performance itself (`RemixAction.state`) is plain, deterministic code.

enum RemixAction: Int, CaseIterable, Identifiable, Codable {
    case none, filterSweep, echoOut, reverbWash, loopRoll, bassDrop, riser, stutter, flangerSweep
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: "Let it play"; case .filterSweep: "Filter sweep"; case .echoOut: "Echo out"; case .reverbWash: "Reverb wash"; case .loopRoll: "Loop roll"
        case .bassDrop: "Bass drop"; case .riser: "Riser"; case .stutter: "Stutter"; case .flangerSweep: "Flanger sweep"
        }
    }

    /// Length in beats.
    var beats: Double {
        switch self {
        case .none: 0; case .filterSweep: 8; case .echoOut: 8; case .reverbWash: 4; case .loopRoll: 4; case .bassDrop: 4; case .riser: 8; case .stutter: 4; case .flangerSweep: 8
        }
    }
}

/// What the deck should look like at one moment of a move. The controller applies it to the real deck.
struct RemixDeckState: Equatable {
    var filter = 0.0                     // -1…1
    var fx: DeckFXKind = .echo
    var fxOn = false
    var fxWet = 0.35
    var fxParam = 0.5
    var lowDB = 0.0                      // 0 = flat; DJMath.eqRange.lowerBound = kill
    var loopBeats: Double? = nil         // nil = no loop
    static let neutral = RemixDeckState()
}

extension RemixAction {
    /// The performance: the deck's state `beat` beats after the move began. Past the end it is neutral again.
    func state(atBeat b: Double) -> RemixDeckState {
        var s = RemixDeckState()
        guard b >= 0, b < beats else { return s }
        let p = b / beats
        func tri(_ x: Double) -> Double { x < 0.5 ? x * 2 : (1 - x) * 2 }                   // 0 → 1 → 0
        switch self {
        case .none: break
        case .filterSweep:                                                                  // close a low-pass and open it again
            s.filter = -0.7 * tri(p) * tri(p).squareRoot()
        case .echoOut:                                                                      // throw an echo, let the tail ring
            s.fx = .echo; s.fxOn = true; s.fxParam = 0.5; s.fxWet = p < 0.5 ? 0.4 : 0.4 * (1 - (p - 0.5) * 2)
        case .reverbWash:
            s.fx = .reverb; s.fxOn = true; s.fxParam = 0.8; s.fxWet = 0.4 * tri(p)
        case .loopRoll:                                                                     // 1 beat, then half, then quarter: the roll tightens
            s.loopBeats = b < 2 ? 1 : (b < 3 ? 0.5 : 0.25)
        case .bassDrop:                                                                     // the low end vanishes, then slams back
            s.lowDB = DJMath.eqRange.lowerBound
            if p > 0.97 { s.lowDB = 0 }
        case .riser:                                                                        // a high-pass climbing with a flanger
            s.filter = 0.6 * p; s.fx = .flanger; s.fxOn = true; s.fxParam = 0.3 + 0.4 * p; s.fxWet = 0.2 + 0.25 * p
        case .stutter:
            s.fx = .gate; s.fxOn = true; s.fxParam = p < 0.5 ? 0.5 : 0.8; s.fxWet = 0.7
        case .flangerSweep:
            s.fx = .flanger; s.fxOn = true; s.fxParam = 0.5; s.fxWet = 0.35 * tri(p)
        }
        return s
    }
}

/// Where a track is, as the policy sees it.
struct RemixContext: Equatable {
    static let count = 11 + RemixAction.allCases.count
    var energyNow = 0.5, energyNext = 0.5
    var upcomingBuild = 0.0              // how much louder the next 8 bars get than now
    var barInPhrase = 0                  // 0…7
    var inIntro = false, inOutro = false
    var intensity = 0.5                  // the user's setting, 0…1
    var barsSinceAction = 16
    var last: RemixAction = .none

    var vector: [Float] {
        let ph = Double(barInPhrase) / 8 * 2 * .pi
        var v: [Float] = [Float(energyNow), Float(energyNext), Float(max(-1, min(1, (energyNext - energyNow) * 2))), Float(min(1, upcomingBuild * 2)),
                          Float(sin(ph)), Float(cos(ph)), barInPhrase == 7 ? 1 : 0, inIntro ? 1 : 0, inOutro ? 1 : 0, Float(intensity), Float(min(1, Double(barsSinceAction) / 16))]
        for a in RemixAction.allCases { v.append(a == last ? 1 : 0) }
        return v
    }
}

/// How loud a track is over time, from its waveform overview.
struct EnergyContour {
    let values: [Float]
    let duration: Double
    init(analysis: DJTrackAnalysis) { values = analysis.peaks; duration = max(0.001, analysis.duration) }

    /// Mean level between two times (seconds), 0…1.
    func level(from a: Double, to b: Double) -> Double {
        guard !values.isEmpty else { return 0.5 }
        let n = values.count
        let i0 = max(0, min(n - 1, Int(a / duration * Double(n)))), i1 = max(i0 + 1, min(n, Int(b / duration * Double(n))))
        var s = 0.0; for i in i0..<i1 { s += Double(values[i]) }
        return min(1, s / Double(i1 - i0) * 1.4)
    }
}

enum RemixPlanner {
    /// The context at bar `bar` (counted from the first beat) of a track.
    static func context(analysis a: DJTrackAnalysis, contour: EnergyContour, bar: Int, intensity: Double, barsSinceAction: Int, last: RemixAction) -> RemixContext? {
        guard let bpm = a.bpm, bpm > 0, let fb = a.firstBeat else { return nil }
        let barLen = 4 * 60 / bpm, t = fb + Double(bar) * barLen
        guard t >= 0, t < a.duration else { return nil }
        let now = contour.level(from: t, to: t + barLen), next = contour.level(from: t + barLen, to: t + 2 * barLen)
        let ahead = contour.level(from: t + barLen, to: t + 9 * barLen)
        var c = RemixContext()
        c.energyNow = now; c.energyNext = next; c.upcomingBuild = max(0, ahead - now)
        c.barInPhrase = ((bar % 8) + 8) % 8
        c.inIntro = a.introEnd.map { t < $0 } ?? false
        c.inOutro = a.outroStart.map { t >= $0 } ?? false
        c.intensity = intensity; c.barsSinceAction = barsSinceAction; c.last = last
        return c
    }
}

/// The small network that chooses the next move: 20 → 16 → 9, tanh hidden units, sigmoid outputs (one score per move).
final class RemixPolicy {
    static let sizes = [RemixContext.count, 16, RemixAction.allCases.count]
    private(set) var w: [[Float]]
    private(set) var feedbackCount = 0
    private struct Stored: Codable { var w: [[Float]]; var feedback: Int; var version: Int }
    static let version = 1

    init(weights: [[Float]]) { w = weights }

    private struct LCG { var s: UInt64; mutating func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) } }

    static func fresh(seed: UInt64 = 21) -> RemixPolicy {
        var g = LCG(s: seed)
        var layers: [[Float]] = []
        for l in 0..<(sizes.count - 1) {
            let i = sizes[l], o = sizes[l + 1], scale = (6 / Float(i + o)).squareRoot()
            layers.append((0..<(o * i)).map { _ in (g.next() * 2 - 1) * scale } + [Float](repeating: 0, count: o))
        }
        return RemixPolicy(weights: layers)
    }

    /// DJ rules of thumb, as a target for every move in a context. The network is taught these before it hears any opinions.
    static func ruleScores(_ c: RemixContext) -> [Float] {
        var s = [Float](repeating: 0.05, count: RemixAction.allCases.count)
        let phraseEnd = c.barInPhrase == 7, early = c.barInPhrase < 2, build = c.upcomingBuild > 0.12
        let calm = 0.4 + 0.5 * (1 - c.intensity)
        func set(_ a: RemixAction, _ v: Double) { s[a.rawValue] = Float(max(0, min(1, v))) }
        set(.none, calm + (early ? 0.25 : 0) - (phraseEnd ? 0.2 : 0))
        set(.riser, build && c.barInPhrase >= 4 ? 0.55 + 0.4 * c.intensity : 0.06)
        set(.bassDrop, (phraseEnd && c.energyNow > 0.35 && (build || c.energyNext > c.energyNow)) ? 0.35 + 0.5 * c.intensity : 0.04)
        set(.echoOut, c.inOutro ? 0.8 : (phraseEnd && c.energyNow < 0.7 ? 0.5 + 0.3 * c.intensity : 0.08))
        set(.reverbWash, c.inOutro || c.inIntro ? 0.55 : (phraseEnd ? 0.3 : 0.05))
        set(.loopRoll, phraseEnd && c.energyNow > 0.45 ? 0.3 + 0.55 * c.intensity : 0.05)
        set(.stutter, phraseEnd && c.intensity > 0.5 && c.energyNow > 0.5 ? 0.2 + 0.6 * (c.intensity - 0.4) : 0.03)
        set(.filterSweep, (c.inIntro || (c.barInPhrase == 3 && c.energyNow > 0.3)) ? 0.45 + 0.2 * c.intensity : 0.1)
        set(.flangerSweep, (c.barInPhrase == 5 || c.barInPhrase == 2) ? 0.2 + 0.4 * c.intensity : 0.04)
        // never the same move twice in a row, and give each one room to breathe
        if c.last != .none { s[c.last.rawValue] *= 0.2 }
        if c.barsSinceAction < 2 { for i in 1..<s.count { s[i] *= 0.3 } }
        return s
    }

    private func layerOutputs(_ x: [Float]) -> [[Float]] {
        var acts: [[Float]] = [x]
        let L = Self.sizes.count - 1
        for l in 0..<L {
            let i = Self.sizes[l], o = Self.sizes[l + 1]
            var out = [Float](repeating: 0, count: o)
            for r in 0..<o {
                var s = w[l][o * i + r]
                for c in 0..<i { s += w[l][r * i + c] * acts[l][c] }
                out[r] = l == L - 1 ? 1 / (1 + exp(-s)) : tanh(s)
            }
            acts.append(out)
        }
        return acts
    }

    func scores(_ c: RemixContext) -> [Float] { layerOutputs(c.vector).last! }

    /// A gradient step towards `target` (per move) on the squared error.
    func train(_ x: [Float], target: [Float], rate: Float, mask: [Float]? = nil) {
        let acts = layerOutputs(x)
        let L = Self.sizes.count - 1
        var delta = [Float](repeating: 0, count: target.count)
        for k in 0..<target.count {
            let a = acts[L][k]
            let m: Float = mask?[k] ?? 1
            delta[k] = (a - target[k]) * a * (1 - a) * m
        }
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

    func pretrain(samples: Int = 5_000, epochs: Int = 5, seed: UInt64 = 5) {
        var g = LCG(s: seed)
        for e in 0..<epochs {
            let rate: Float = 0.3 / Float(e + 1)
            for _ in 0..<samples {
                var c = RemixContext()
                c.energyNow = Double(g.next()); c.energyNext = Double(g.next()); c.upcomingBuild = Double(max(0, g.next() - 0.55)) * 0.6
                c.barInPhrase = Int(g.next() * 8) % 8; c.inIntro = g.next() < 0.12; c.inOutro = g.next() < 0.12; c.intensity = Double(g.next())
                c.barsSinceAction = Int(g.next() * 20); c.last = RemixAction(rawValue: Int(g.next() * 9) % 9) ?? .none
                train(c.vector, target: Self.ruleScores(c), rate: rate)
            }
        }
    }

    /// Thumbs on a move that was played: push its score up or down in that context (the others are left alone).
    func feedback(_ c: RemixContext, action: RemixAction, liked: Bool, rate: Float = 0.15) {
        var target = scores(c); target[action.rawValue] = liked ? 0.97 : 0.02
        var mask = [Float](repeating: 0, count: target.count); mask[action.rawValue] = 1
        for _ in 0..<4 { train(c.vector, target: target, rate: rate, mask: mask) }
        feedbackCount += 1
    }

    /// Picks a move: a draw from the scores sharpened by `sharpness`, so strong candidates win most of the time and weaker ones sometimes do.
    func choose<R: RandomNumberGenerator>(_ c: RemixContext, using rng: inout R, sharpness: Float = 6, allowed: Set<RemixAction>? = nil) -> RemixAction {
        var s = scores(c)
        if let allowed { for a in RemixAction.allCases where !allowed.contains(a) && a != .none { s[a.rawValue] = 0 } }
        let weights = s.map { exp(sharpness * $0) }
        var r = Float.random(in: 0..<weights.reduce(0, +), using: &rng)
        for (i, wgt) in weights.enumerated() { r -= wgt; if r <= 0 { return RemixAction(rawValue: i) ?? .none } }
        return .none
    }

    func data() -> Data? { try? JSONEncoder().encode(Stored(w: w, feedback: feedbackCount, version: Self.version)) }
    static func load(_ d: Data) -> RemixPolicy? {
        guard let s = try? JSONDecoder().decode(Stored.self, from: d), s.version == version, s.w.count == sizes.count - 1 else { return nil }
        for l in 0..<s.w.count where s.w[l].count != sizes[l + 1] * sizes[l] + sizes[l + 1] { return nil }
        let n = RemixPolicy(weights: s.w); n.feedbackCount = s.feedback
        return n
    }
    static var storeURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/remix-policy.json") }
    static func loadOrCreate(at url: URL = storeURL) -> RemixPolicy {
        if let d = try? Data(contentsOf: url), let n = load(d) { return n }
        let n = fresh(); n.pretrain(); return n
    }
    func save(to url: URL = RemixPolicy.storeURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = data() { try? d.write(to: url, options: .atomic) }
    }
}

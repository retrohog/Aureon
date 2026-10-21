import Foundation
import Synchronization

/// A Float or Int that one thread writes and the audio thread reads, without locks.
final class ParamF: @unchecked Sendable {
    private let bits: Atomic<UInt32>
    init(_ v: Float = 0) { bits = Atomic(v.bitPattern) }
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.isFinite ? newValue.bitPattern : 0, ordering: .relaxed) }
    }
}

final class ParamI: @unchecked Sendable {
    private let v: Atomic<Int>
    init(_ x: Int = 0) { v = Atomic(x) }
    var value: Int { get { v.load(ordering: .relaxed) } set { v.store(newValue, ordering: .relaxed) } }
}

/// One biquad section for a stereo pair (transposed direct form II, Double state). Coefficients can be replaced between blocks.
struct StereoBiquad {
    var c = BiquadSection()
    private var z1l = 0.0, z2l = 0.0, z1r = 0.0, z2r = 0.0
    var bypass: Bool { c.b0 == 1 && c.b1 == 0 && c.b2 == 0 && c.a1 == 0 && c.a2 == 0 }

    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        if bypass { return }
        for i in 0..<frames {
            let xl = Double(l[i]), yl = c.b0 * xl + z1l
            z1l = c.b1 * xl - c.a1 * yl + z2l; z2l = c.b2 * xl - c.a2 * yl; l[i] = Float(yl)
            let xr = Double(r[i]), yr = c.b0 * xr + z1r
            z1r = c.b1 * xr - c.a1 * yr + z2r; z2r = c.b2 * xr - c.a2 * yr; r[i] = Float(yr)
        }
    }
}

enum DeckFXKind: Int, CaseIterable, Identifiable, Codable {
    case off, echo, reverb, flanger, gate
    var id: Int { rawValue }
    var title: String { switch self { case .off: "Off"; case .echo: "Echo"; case .reverb: "Reverb"; case .flanger: "Flanger"; case .gate: "Gate" } }
    var paramLabel: String { switch self { case .off: ""; case .echo: "BEATS"; case .reverb: "SIZE"; case .flanger: "RATE"; case .gate: "RATE" } }
}

/// Everything the interface can change on a deck's channel strip. Read by the audio thread each block.
final class DeckParams: @unchecked Sendable {
    let trim = ParamF(1)                 // linear
    let filter = ParamF(0)               // -1 low-pass … 0 off … +1 high-pass
    let low = ParamF(0), mid = ParamF(0), high = ParamF(0)       // dB; <= -60 is a full kill
    let fxKind = ParamI(0)
    let fxOn = ParamI(0)
    let fxWet = ParamF(0.35)             // 0…1
    let fxParam = ParamF(0.5)            // 0…1 (meaning depends on the effect)
    let bpm = ParamF(0)                  // the deck's current tempo, for beat-synced effects
}

// MARK: - Effects

/// A feedback delay with a slewed, fractional delay time (so changing it glides like a tape echo) and a darkening filter in the loop.
final class EchoFX {
    private let l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>
    private let size: Int
    private var w = 0
    private var time: Double            // current delay in frames
    private var dampL: Float = 0, dampR: Float = 0

    init(sampleRate: Double) {
        size = Int(sampleRate * 4) + 8
        l = .allocate(capacity: size); r = .allocate(capacity: size)
        l.initialize(repeating: 0, count: size); r.initialize(repeating: 0, count: size)
        time = sampleRate * 0.375
    }
    deinit { l.deallocate(); r.deallocate() }

    func reset() { l.update(repeating: 0, count: size); r.update(repeating: 0, count: size); dampL = 0; dampR = 0 }

    func process(_ xl: UnsafeMutablePointer<Float>, _ xr: UnsafeMutablePointer<Float>, frames: Int, targetFrames: Double, feedback: Float, wet: Float) {
        let target = max(32, min(Double(size - 4), targetFrames))
        let slew = 1.0 - exp(-1.0 / 4800)        // ~100 ms glide at 48 kHz
        for i in 0..<frames {
            time += (target - time) * slew
            var rp = Double(w) - time; if rp < 0 { rp += Double(size) }
            let i0 = Int(rp), f = Float(rp - Double(i0)), i1 = (i0 + 1) % size
            let dl = l[i0] * (1 - f) + l[i1] * f, dr = r[i0] * (1 - f) + r[i1] * f
            dampL += (dl - dampL) * 0.45; dampR += (dr - dampR) * 0.45          // one-pole low-pass: each repeat is darker
            l[w] = xl[i] + dampL * feedback; r[w] = xr[i] + dampR * feedback
            xl[i] += dl * wet; xr[i] += dr * wet
            w += 1; if w == size { w = 0 }
        }
    }
}

/// Freeverb: eight damped comb filters in parallel, four all-passes in series, per channel.
final class ReverbFX {
    private struct Comb { var buf: UnsafeMutablePointer<Float>; var n: Int; var i = 0; var store: Float = 0 }
    private struct AllPass { var buf: UnsafeMutablePointer<Float>; var n: Int; var i = 0 }
    private var combsL: [Comb] = [], combsR: [Comb] = []
    private var apL: [AllPass] = [], apR: [AllPass] = []

    init(sampleRate: Double) {
        let k = sampleRate / 44_100
        func buf(_ n: Int) -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p }
        for t in [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617] {
            let a = max(8, Int(Double(t) * k)), b = max(8, Int(Double(t + 23) * k))
            combsL.append(Comb(buf: buf(a), n: a)); combsR.append(Comb(buf: buf(b), n: b))
        }
        for t in [556, 441, 341, 225] {
            let a = max(8, Int(Double(t) * k)), b = max(8, Int(Double(t + 23) * k))
            apL.append(AllPass(buf: buf(a), n: a)); apR.append(AllPass(buf: buf(b), n: b))
        }
    }
    deinit { for c in combsL + combsR { c.buf.deallocate() }; for a in apL + apR { a.buf.deallocate() } }

    func reset() {
        for i in combsL.indices { combsL[i].buf.update(repeating: 0, count: combsL[i].n); combsL[i].store = 0; combsR[i].buf.update(repeating: 0, count: combsR[i].n); combsR[i].store = 0 }
        for i in apL.indices { apL[i].buf.update(repeating: 0, count: apL[i].n); apR[i].buf.update(repeating: 0, count: apR[i].n) }
    }

    /// `room` 0…1 sets the decay time, `wet` is the mix (0 = dry).
    func process(_ xl: UnsafeMutablePointer<Float>, _ xr: UnsafeMutablePointer<Float>, frames: Int, room: Float, wet: Float) {
        let feedback = 0.7 + 0.28 * max(0, min(1, room)), damp: Float = 0.25
        for i in 0..<frames {
            let input = (xl[i] + xr[i]) * 0.015
            var outL: Float = 0, outR: Float = 0
            for c in 0..<combsL.count {
                var a = combsL[c]
                let y = a.buf[a.i]; a.store = y * (1 - damp) + a.store * damp; a.buf[a.i] = input + a.store * feedback; a.i += 1; if a.i == a.n { a.i = 0 }
                combsL[c] = a; outL += y
                var b = combsR[c]
                let z = b.buf[b.i]; b.store = z * (1 - damp) + b.store * damp; b.buf[b.i] = input + b.store * feedback; b.i += 1; if b.i == b.n { b.i = 0 }
                combsR[c] = b; outR += z
            }
            for p in 0..<apL.count {
                var a = apL[p]; let bl = a.buf[a.i]; a.buf[a.i] = outL + bl * 0.5; outL = bl - outL; a.i += 1; if a.i == a.n { a.i = 0 }; apL[p] = a
                var b = apR[p]; let br = b.buf[b.i]; b.buf[b.i] = outR + br * 0.5; outR = br - outR; b.i += 1; if b.i == b.n { b.i = 0 }; apR[p] = b
            }
            xl[i] += outL * wet * 3; xr[i] += outR * wet * 3
        }
    }
}

/// A short modulated delay with feedback: the classic jet-plane sweep.
final class FlangerFX {
    private let l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>
    private let size: Int
    private var w = 0
    private var phase = 0.0
    private let sr: Double

    init(sampleRate: Double) {
        sr = sampleRate; size = Int(sampleRate * 0.02) + 8
        l = .allocate(capacity: size); r = .allocate(capacity: size)
        l.initialize(repeating: 0, count: size); r.initialize(repeating: 0, count: size)
    }
    deinit { l.deallocate(); r.deallocate() }
    func reset() { l.update(repeating: 0, count: size); r.update(repeating: 0, count: size) }

    /// `rate` 0…1 maps to 0.05…3 Hz; `wet` is the mix.
    func process(_ xl: UnsafeMutablePointer<Float>, _ xr: UnsafeMutablePointer<Float>, frames: Int, rate: Float, wet: Float) {
        let hz = 0.05 + 2.95 * Double(max(0, min(1, rate))) * Double(max(0, min(1, rate)))
        let inc = 2 * Double.pi * hz / sr
        for i in 0..<frames {
            let m = 0.5 + 0.5 * sin(phase); phase += inc; if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            let d = (0.0004 + 0.0036 * m) * sr
            var rp = Double(w) - d; if rp < 0 { rp += Double(size) }
            let i0 = Int(rp), f = Float(rp - Double(i0)), i1 = (i0 + 1) % size
            let dl = l[i0] * (1 - f) + l[i1] * f, dr = r[i0] * (1 - f) + r[i1] * f
            l[w] = xl[i] + dl * 0.55; r[w] = xr[i] + dr * 0.55
            xl[i] = xl[i] * (1 - wet * 0.5) + dl * wet * 0.7; xr[i] = xr[i] * (1 - wet * 0.5) + dr * wet * 0.7
            w += 1; if w == size { w = 0 }
        }
    }
}

/// A rhythmic gate ("trans"): chops the sound on and off in eighth notes at the deck's tempo.
final class GateFX {
    private var counter = 0.0
    private var smooth: Float = 1
    func process(_ xl: UnsafeMutablePointer<Float>, _ xr: UnsafeMutablePointer<Float>, frames: Int, bpm: Double, rate: Float, wet: Float, sampleRate: Double) {
        let division = rate < 0.34 ? 1.0 : (rate < 0.67 ? 2.0 : 4.0)           // quarter, eighth or sixteenth notes
        let period = max(64, sampleRate * 60 / max(40, bpm == 0 ? 120 : bpm) / division)
        for i in 0..<frames {
            counter += 1; if counter >= period { counter -= period }
            let open: Float = counter < period * 0.5 ? 1 : 0.04
            smooth += (open - smooth) * 0.02
            let g = 1 - wet + wet * smooth
            xl[i] *= g; xr[i] *= g
        }
    }
}

// MARK: - A deck's channel strip

/// Filter → 3-band EQ → effect, in Float, with every control read from atomics so the interface can move them at any time.
final class DeckProcessor {
    private let params: DeckParams
    private let sr: Double
    private var filter = StereoBiquad()
    private var low = StereoBiquad(), mid = StereoBiquad(), high = StereoBiquad()
    private var lastFilter: Float = .nan, lastLow: Float = .nan, lastMid: Float = .nan, lastHigh: Float = .nan
    private let echo: EchoFX, reverb: ReverbFX, flanger: FlangerFX, gate = GateFX()
    private var lastKind = 0

    init(params: DeckParams, sampleRate: Double) {
        self.params = params; sr = sampleRate
        echo = EchoFX(sampleRate: sampleRate); reverb = ReverbFX(sampleRate: sampleRate); flanger = FlangerFX(sampleRate: sampleRate)
    }

    /// The filter knob: left of centre sweeps a low-pass down, right of centre sweeps a high-pass up; a dead zone around the middle is off.
    static func filterSection(_ x: Double, sampleRate: Double) -> BiquadSection {
        if abs(x) < 0.03 { return BiquadSection() }
        if x < 0 {
            let fc = 18_000 * pow(100.0 / 18_000, min(1, -x))
            return BiquadSection.coefficients(EQFilter(kind: .lowPass, fc: min(fc, sampleRate * 0.45), q: 1.1), sampleRate: sampleRate) ?? BiquadSection()
        }
        let fc = 30 * pow(6_000.0 / 30, min(1, x))
        return BiquadSection.coefficients(EQFilter(kind: .highPass, fc: fc, q: 1.1), sampleRate: sampleRate) ?? BiquadSection()
    }

    private func refresh() {
        let f = params.filter.value
        if f != lastFilter { lastFilter = f; filter.c = Self.filterSection(Double(f), sampleRate: sr) }
        let lo = params.low.value, mi = params.mid.value, hi = params.high.value
        if lo != lastLow { lastLow = lo; low.c = abs(lo) < 0.05 ? BiquadSection() : (BiquadSection.coefficients(EQFilter(kind: .lowShelf, fc: 120, gainDB: Double(lo), q: 0.707), sampleRate: sr) ?? BiquadSection()) }
        if mi != lastMid { lastMid = mi; mid.c = abs(mi) < 0.05 ? BiquadSection() : (BiquadSection.coefficients(EQFilter(kind: .peak, fc: 1_000, gainDB: Double(mi), q: 0.6), sampleRate: sr) ?? BiquadSection()) }
        if hi != lastHigh { lastHigh = hi; high.c = abs(hi) < 0.05 ? BiquadSection() : (BiquadSection.coefficients(EQFilter(kind: .highShelf, fc: 6_000, gainDB: Double(hi), q: 0.707), sampleRate: sr) ?? BiquadSection()) }
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        refresh()
        let trim = params.trim.value
        if trim != 1 { for i in 0..<frames { l[i] *= trim; r[i] *= trim } }
        filter.process(l, r, frames: frames)
        low.process(l, r, frames: frames); mid.process(l, r, frames: frames); high.process(l, r, frames: frames)
        let kind = params.fxOn.value != 0 ? params.fxKind.value : 0
        if kind != lastKind { lastKind = kind; echo.reset(); reverb.reset(); flanger.reset() }
        let wet = params.fxWet.value, p = params.fxParam.value
        switch DeckFXKind(rawValue: kind) ?? .off {
        case .off: break
        case .echo:
            let bpm = max(40, Double(params.bpm.value == 0 ? 120 : params.bpm.value)), beats = p < 0.25 ? 0.25 : (p < 0.5 ? 0.5 : (p < 0.75 ? 0.75 : 1.0))
            echo.process(l, r, frames: frames, targetFrames: sr * 60 / bpm * beats, feedback: 0.45, wet: wet)
        case .reverb: reverb.process(l, r, frames: frames, room: p, wet: wet)
        case .flanger: flanger.process(l, r, frames: frames, rate: p, wet: wet)
        case .gate: gate.process(l, r, frames: frames, bpm: Double(params.bpm.value), rate: p, wet: wet, sampleRate: sr)
        }
    }
}

// MARK: - Master limiter

/// A peak limiter on the master bus: the signal can never leave it above the ceiling, however hot the two decks are summed.
struct MasterLimiter {
    var ceiling: Float = 0.966           // -0.3 dBFS
    private var gain: Float = 1
    private(set) var reduction: Float = 0   // dB of gain reduction right now (for the meter)

    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int, release: Float = 0.0004) {
        var minGain: Float = 1
        for i in 0..<frames {
            let p = max(abs(l[i]), abs(r[i]))
            let need: Float = p > ceiling ? ceiling / p : 1
            if need < gain { gain = need } else { gain += (1 - gain) * release }
            l[i] *= gain; r[i] *= gain
            minGain = min(minGain, gain)
        }
        reduction = minGain < 1 ? -20 * log10(max(minGain, 1e-4)) : 0
    }
}

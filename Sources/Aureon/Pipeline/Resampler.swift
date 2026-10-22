import Foundation
import Accelerate

// Native polyphase windowed-sinc sample-rate converter.
//
//   • any rational ratio L/M (44.1 → 176.4 kHz is 4/1, 44.1 → 192 kHz is 640/147, 192 → 44.1 kHz is 147/640)
//   • Kaiser-windowed sinc prototype, selectable stop-band attenuation and pass-band width
//   • linear-phase (symmetric, pre/post ringing, constant delay — delay is compensated, output is time-aligned)
//     or minimum-phase (no pre-ringing, frequency-dependent delay) via the homomorphic / cepstral method
//   • four named filters (`OversamplingFilter`): linear phase, minimum phase, apodizing and brickwall
//   • the filter of a running source can be changed (`FilterSwitch`): the new design is built on a background queue, then swapped in
//     between two reads, with a short crossfade, so changing it never stalls the producer or touches the audio thread
//   • double-precision filtering; vDSP dot products do the heavy lifting
//
// The filter is applied on the producer thread, never in the real-time callback.

struct ResamplerConfig: Equatable, Codable, Hashable {
    enum Phase: String, Codable, CaseIterable, Identifiable {
        case linear, minimum
        var id: String { rawValue }
        var title: String { self == .linear ? "Linear phase" : "Minimum phase" }
    }
    /// How the transition band is drawn. `plain` follows `passband` and `stopbandDB`; the other two are fixed designs that ignore them.
    enum Shape: String, Codable, CaseIterable {
        case plain
        /// Closes at the source's Nyquist frequency and starts to roll off well below it, so the energy the original recording's own
        /// anti-alias filter left near Nyquist (and the ringing that goes with it) is not carried into the upsampled signal.
        case apodizing
        /// As steep as is practical: flat to 99% of Nyquist and 144 dB down beyond it. Needs many more taps than the others.
        case brickwall
    }
    var phase: Phase = .linear
    /// Fraction of the lower Nyquist frequency kept flat (0.90 … 0.995). Higher = steeper filter = more taps.
    var passband: Double = 0.95
    /// Stop-band attenuation in dB.
    var stopbandDB: Double = 120
    var shape: Shape = .plain

    static let standard = ResamplerConfig()

    /// Pass-band edge (fraction of the lower Nyquist frequency) and stop-band attenuation the design actually uses.
    var effectivePassband: Double {
        switch shape { case .plain: passband; case .apodizing: 0.86; case .brickwall: 0.99 }
    }
    var effectiveStopbandDB: Double {
        switch shape { case .plain: stopbandDB; case .apodizing: 130; case .brickwall: 144 }
    }

    /// Approximate filter length per polyphase branch (it does not depend on the conversion ratio), and its cost relative to `standard`.
    var tapsPerPhase: Int {
        let delta = (1 - effectivePassband) * 0.5
        let n0 = (effectiveStopbandDB - 7.95) / (2.285 * 2 * Double.pi * delta)           // length in units of the L-times-oversampled rate / L
        return Int(n0.rounded(.up)) + 1
    }
    var costFactor: Double { Double(tapsPerPhase) / Double(ResamplerConfig.standard.tapsPerPhase) }
}

extension ResamplerConfig {
    /// Tolerant decoding: settings saved before `shape` existed still load.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .linear
        passband = try c.decodeIfPresent(Double.self, forKey: .passband) ?? 0.95
        stopbandDB = try c.decodeIfPresent(Double.self, forKey: .stopbandDB) ?? 120
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? .plain
    }
}

/// The four oversampling filters offered in the settings. Each is a `ResamplerConfig`; linear and minimum phase keep the pass-band and
/// stop-band the person has chosen, apodizing and brickwall are fixed designs.
enum OversamplingFilter: String, CaseIterable, Identifiable {
    case linearPhase, minimumPhase, apodizing, brickwall
    var id: String { rawValue }
    var title: String {
        switch self { case .linearPhase: "Linear phase"; case .minimumPhase: "Minimum phase"; case .apodizing: "Apodizing"; case .brickwall: "Brickwall" }
    }
    var summary: String {
        switch self {
        case .linearPhase: "Constant delay at every frequency: ringing is symmetric, before and after a transient. The neutral choice."
        case .minimumPhase: "No ringing before a transient, a little after it; the delay varies slightly with frequency."
        case .apodizing: "Rolls off from about 19 kHz and is closed at the source's Nyquist frequency, so the recording's own filter ringing is not passed on."
        case .brickwall: "Flat to 99% of Nyquist and 144 dB down beyond it. The most exact, and about six times the processing of the standard filter."
        }
    }
    /// Whether the pass-band and stop-band sliders apply.
    var adjustable: Bool { self == .linearPhase || self == .minimumPhase }

    init(_ c: ResamplerConfig) {
        switch c.shape {
        case .apodizing: self = .apodizing
        case .brickwall: self = .brickwall
        case .plain: self = c.phase == .minimum ? .minimumPhase : .linearPhase
        }
    }

    /// `base` with this filter's shape applied (its sliders are kept).
    func applied(to base: ResamplerConfig) -> ResamplerConfig {
        var c = base
        switch self {
        case .linearPhase: c.phase = .linear; c.shape = .plain
        case .minimumPhase: c.phase = .minimum; c.shape = .plain
        case .apodizing: c.phase = .linear; c.shape = .apodizing
        case .brickwall: c.phase = .linear; c.shape = .brickwall
        }
        return c
    }
}

enum DSPMath {
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0, k = 1.0
        let q = x * x / 4
        while term > 1e-17 * sum { term *= q / (k * k); sum += term; k += 1 }
        return sum
    }

    static func kaiserBeta(attenuation a: Double) -> Double {
        if a > 50 { return 0.1102 * (a - 8.7) }
        if a >= 21 { return 0.5842 * pow(a - 21, 0.4) + 0.07886 * (a - 21) }
        return 0
    }

    /// Odd-length Kaiser-windowed-sinc low-pass with cutoff `fc` (cycles per sample, 0…0.5), DC gain = `gain`.
    static func lowpass(taps n: Int, cutoff fc: Double, beta: Double, gain: Double) -> [Double] {
        let c = Double(n - 1) / 2, i0b = besselI0(beta)
        var h = [Double](repeating: 0, count: n)
        var sum = 0.0
        for j in 0..<n {
            let t = Double(j) - c
            let s = t == 0 ? 2 * fc : sin(2 * Double.pi * fc * t) / (Double.pi * t)
            let r = c == 0 ? 0 : t / c
            let w = besselI0(beta * (1 - r * r).squareRoot()) / i0b
            h[j] = s * w; sum += h[j]
        }
        let g = gain / sum
        for j in 0..<n { h[j] *= g }
        return h
    }

    /// In-place complex FFT (power-of-two length). The inverse is scaled by 1/n.
    static func fft(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        let n = re.count
        let log2n = vDSP_Length(Int(log2(Double(n)).rounded()))
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(setup, &sc, 1, log2n, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
        vDSP_destroy_fftsetupD(setup)
        if inverse { var s = 1.0 / Double(n); vDSP_vsmulD(re, 1, &s, &re, 1, vDSP_Length(n)); vDSP_vsmulD(im, 1, &s, &im, 1, vDSP_Length(n)) }
    }

    /// Minimum-phase filter with the same magnitude response as the linear-phase `h` (homomorphic method).
    static func minimumPhase(from h: [Double], dcGain: Double) -> [Double] {
        let n = h.count
        var size = 1; while size < n * 8 { size <<= 1 }
        var re = [Double](repeating: 0, count: size), im = [Double](repeating: 0, count: size)
        for j in 0..<n { re[j] = h[j] }
        fft(&re, &im, inverse: false)
        // log-magnitude (clamped at -200 dB), zero imaginary part
        var logmag = [Double](repeating: 0, count: size), zero = [Double](repeating: 0, count: size)
        for k in 0..<size { logmag[k] = log(max((re[k] * re[k] + im[k] * im[k]).squareRoot(), 1e-10)) }
        fft(&logmag, &zero, inverse: true)                 // real cepstrum
        // fold to a causal cepstrum
        var cr = [Double](repeating: 0, count: size), ci = [Double](repeating: 0, count: size)
        cr[0] = logmag[0]
        for k in 1..<(size / 2) { cr[k] = 2 * logmag[k] }
        cr[size / 2] = logmag[size / 2]
        fft(&cr, &ci, inverse: false)
        // exp of a complex spectrum
        for k in 0..<size { let m = exp(cr[k]); let p = ci[k]; cr[k] = m * cos(p); ci[k] = m * sin(p) }
        fft(&cr, &ci, inverse: true)
        var out = Array(cr[0..<n])
        let sum = out.reduce(0, +)
        let g = dcGain / sum
        for j in 0..<n { out[j] *= g }
        return out
    }
}

/// Polyphase filter bank for one (L, M, config) triple. Immutable after creation, shared between sources.
final class PolyphaseDesign: @unchecked Sendable {
    let L: Int, M: Int, taps: Int      // taps = filter length per phase (P)
    let lead: Int                      // future input samples a linear-phase window needs (K); 0 for minimum phase
    let coefficients: [Double]         // phase-major: coefficients[r * taps + i], applied to x[window start + i]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: PolyphaseDesign] = [:]

    static func shared(inRate: Double, outRate: Double, config: ResamplerConfig) -> PolyphaseDesign? {
        guard let (l, m) = ratio(inRate, outRate) else { return nil }
        let key = "\(l)/\(m)/\(config.phase.rawValue)/\(config.effectivePassband)/\(config.effectiveStopbandDB)"
        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit { return hit }
        // built outside the lock: a design can take a while, and another thread opening a track must not wait for it
        let d = PolyphaseDesign(L: l, M: m, config: config)
        lock.lock(); defer { lock.unlock() }
        if let raced = cache[key] { return raced }
        if cache.count > 8 { cache.removeAll() }
        cache[key] = d
        return d
    }

    /// True when the design for this conversion is already built.
    static func isCached(inRate: Double, outRate: Double, config: ResamplerConfig) -> Bool {
        guard let (l, m) = ratio(inRate, outRate) else { return false }
        let key = "\(l)/\(m)/\(config.phase.rawValue)/\(config.effectivePassband)/\(config.effectiveStopbandDB)"
        lock.lock(); defer { lock.unlock() }
        return cache[key] != nil
    }

    /// Reduced integer ratio out/in = L/M for rates that are whole numbers of Hz.
    static func ratio(_ inRate: Double, _ outRate: Double) -> (Int, Int)? {
        let a = Int(inRate.rounded()), b = Int(outRate.rounded())
        guard a > 0, b > 0, abs(Double(a) - inRate) < 1e-6, abs(Double(b) - outRate) < 1e-6 else { return nil }
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return (b / x, a / x)
    }

    init(L: Int, M: Int, config: ResamplerConfig) {
        self.L = L; self.M = M
        let hi = Double(max(L, M))
        let stopEdge = 0.5 / hi                               // lower of the two Nyquist frequencies, at the L-times-oversampled rate
        let passEdge = config.effectivePassband * stopEdge
        let delta = stopEdge - passEdge
        let n0 = Int(((config.effectiveStopbandDB - 7.95) / (2.285 * 2 * Double.pi * delta)).rounded(.up))
        let k = max(1, Int((Double(n0 - 1) / Double(2 * L)).rounded(.up)))
        let n = 2 * k * L + 1                                  // odd; centre = k·L, i.e. a whole number of input samples
        let beta = DSPMath.kaiserBeta(attenuation: config.effectiveStopbandDB)
        var h = DSPMath.lowpass(taps: n, cutoff: (stopEdge + passEdge) / 2, beta: beta, gain: Double(L))
        if config.phase == .minimum { h = DSPMath.minimumPhase(from: h, dcGain: Double(L)); lead = 0 } else { lead = k }
        let p = 2 * k + 1
        taps = p
        // Phase r uses h[r + j·L]; store reversed so the window can be read forwards in time.
        var c = [Double](repeating: 0, count: L * p)
        for r in 0..<L { for i in 0..<p {
            let idx = r + (p - 1 - i) * L
            if idx < n { c[r * p + i] = h[idx] }
        } }
        coefficients = c
    }
}

/// The filter wanted by the resamplers built with it. Changing it is a request: each running `ResamplingSource` builds the new design on a
/// background queue and swaps it in between two reads (crossfading over about 20 ms), or at once when it is repositioned. Nothing is built,
/// locked or allocated on the audio thread, and the producer never waits for a design.
final class FilterSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var wanted: ResamplerConfig
    private var generation = 0
    private var ready = 0
    private var refusal: String?

    init(_ config: ResamplerConfig) { wanted = config }

    /// The filter now wanted, and which request it is.
    func current() -> (config: ResamplerConfig, generation: Int) { lock.lock(); defer { lock.unlock() }; return (wanted, generation) }
    var config: ResamplerConfig { current().config }

    /// Asks for `config`. Returns false when it is already the one wanted.
    @discardableResult
    func request(_ config: ResamplerConfig) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard config != wanted else { return false }
        wanted = config; generation += 1; refusal = nil
        return true
    }

    /// True once a resampler has the latest request built and waiting to be swapped in.
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready == generation }
    fileprivate func markReady(_ gen: Int) { lock.lock(); ready = max(ready, gen); lock.unlock() }

    /// A reason a resampler declined the request (the new filter needs more than this Mac can spare), once.
    fileprivate func refuse(_ message: String) { lock.lock(); refusal = message; lock.unlock() }
    func takeRefusal() -> String? { lock.lock(); defer { lock.unlock() }; let r = refusal; refusal = nil; return r }
}

/// Converts the stream of `upstream` to `outRate`.
final class ResamplingSource: FrameSource {
    private let upstream: FrameSource
    private var design: PolyphaseDesign
    private let ch: Int
    let info: StreamInfo
    private let outTotal: Int64
    private let inRate: Double

    // Per-channel input window in absolute input-sample coordinates: buf[c][0..<have] holds samples base ..< base+have.
    private var buf: [UnsafeMutablePointer<Double>] = []
    private var capacity: Int
    private var base = 0, have = 0
    private var m = 0                       // next output frame
    private var eof = false
    private let pull: UnsafeMutablePointer<Int32>
    private let pullFrames = 4096

    // Changing the filter while playing
    private let control: FilterSwitch?
    private var seenGeneration = 0, buildingGeneration = 0
    private let swapLock = NSLock()
    private var built: (generation: Int, design: PolyphaseDesign)?
    private var fadeFrom: PolyphaseDesign?
    private var fadeTotal = 1, fadeLeft = 0

    /// `control`, when given, supplies the filter (now and whenever it is changed) in place of `config`.
    init?(_ upstream: FrameSource, outRate: Double, config: ResamplerConfig, control: FilterSwitch? = nil) {
        let start = control?.current()
        guard let d = PolyphaseDesign.shared(inRate: upstream.info.sampleRate, outRate: outRate, config: start?.config ?? config) else { return nil }
        self.upstream = upstream; design = d; ch = upstream.info.channels; inRate = upstream.info.sampleRate
        self.control = control; seenGeneration = start?.generation ?? 0; buildingGeneration = seenGeneration
        capacity = d.taps + pullFrames + 8
        for _ in 0..<ch { buf.append(.allocate(capacity: capacity)) }
        pull = .allocate(capacity: pullFrames * ch)
        let nin = upstream.info.totalFrames
        outTotal = (nin * Int64(d.L) + Int64(d.M) - 1) / Int64(d.M)
        var i = upstream.info
        i.sampleRate = outRate; i.totalFrames = outTotal; i.sourceRate = upstream.info.sampleRate; i.transparent = false
        info = i
        reset(to: 0)
    }

    deinit { buf.forEach { $0.deallocate() }; pull.deallocate() }

    private func windowStart(_ out: Int) -> Int { (out * design.M) / design.L + design.lead - (design.taps - 1) }

    private func reset(to frame: Int) {
        m = frame; eof = false
        let ws = windowStart(frame)
        if ws < 0 {
            base = ws; have = -ws
            for c in 0..<ch { buf[c].update(repeating: 0, count: have) }
            upstream.seek(to: 0)
        } else {
            base = ws; have = 0
            upstream.seek(to: Int64(ws))
        }
    }

    func seek(to frame: Int64) {
        pollSwitch(immediate: true)
        fadeFrom = nil; fadeLeft = 0
        reset(to: max(0, min(Int(frame), Int(outTotal))))
    }

    // MARK: changing the filter

    /// Makes room for a window of `taps` input samples plus a pull.
    private func reserve(_ taps: Int) {
        let need = taps + pullFrames + 8
        guard need > capacity else { return }
        for c in 0..<ch {
            let nb = UnsafeMutablePointer<Double>.allocate(capacity: need)
            nb.update(from: buf[c], count: have)
            buf[c].deallocate(); buf[c] = nb
        }
        capacity = need
    }

    /// Notices a new request, starts building its design, and swaps a finished one in. Runs on the producer thread.
    private func pollSwitch(immediate: Bool) {
        guard let control else { return }
        let (cfg, gen) = control.current()
        guard gen != seenGeneration else { return }
        swapLock.lock()
        if let b = built, b.generation == gen {
            built = nil; swapLock.unlock()
            reserve(design.taps + b.design.taps)
            // a design that reaches further back than the history held cannot be faded in: reposition (seek and refill) instead
            let needsHistory = (b.design.taps - b.design.lead) > (design.taps - design.lead)
            if immediate || have == 0 || needsHistory { fadeFrom = nil; fadeLeft = 0 }
            else { fadeFrom = design; fadeTotal = max(256, Int(info.sampleRate * 0.02)); fadeLeft = fadeTotal }
            design = b.design; seenGeneration = gen
            if needsHistory && !immediate { reset(to: m) }
            return
        }
        let start = buildingGeneration != gen
        if start { buildingGeneration = gen }
        swapLock.unlock()
        guard start else { return }
        // a filter that costs more than this Mac can spare at this rate is not switched to
        if cfg.costFactor > 1, !PerformanceProfile.ready.canResample(to: info.sampleRate, channels: ch, cost: cfg.costFactor) {
            seenGeneration = gen
            control.refuse("The \(OversamplingFilter(cfg).title.lowercased()) filter needs more processing than this Mac can spare at \(formatRate(info.sampleRate)): keeping the filter that is playing")
            return
        }
        let (i, o) = (inRate, info.sampleRate)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let d = PolyphaseDesign.shared(inRate: i, outRate: o, config: cfg), let self else { return }
            self.swapLock.lock(); self.built = (gen, d); self.swapLock.unlock()
            control.markReady(gen)
        }
    }

    /// Makes sure the absolute input index `last` is in the window, discarding samples before `start`.
    private func ensure(start: Int, last: Int) {
        guard base + have <= last else { return }
        // Only compact when more input is needed; the window start never exceeds what we hold because a
        // window (one filter length) is always wider than the per-output input step.
        let drop = min(max(0, start - base), have)
        if drop > 0 {
            for c in 0..<ch { buf[c].update(from: buf[c] + drop, count: have - drop) }
            base += drop; have -= drop
        }
        while base + have <= last {
            var got = 0
            if !eof {
                got = upstream.read(into: pull, frames: pullFrames)
                if got == 0 { eof = true }
            }
            if got > 0 {
                for f in 0..<got { for c in 0..<ch { buf[c][have + f] = Double(pull[f * ch + c]) / 2_147_483_648.0 } }
            } else {                       // past the end of the stream: zeros
                got = pullFrames
                for c in 0..<ch { buf[c].advanced(by: have).update(repeating: 0, count: got) }
            }
            have += got
        }
    }

    @inline(__always) private static func int32(_ v: Double) -> Int32 {
        let r = (v * 2_147_483_648.0).rounded()
        return r >= 2_147_483_647 ? .max : (r <= -2_147_483_648 ? .min : Int32(r))
    }

    func read(into out: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        pollSwitch(immediate: false)
        let d = design, o = fadeFrom
        let L = d.L, M = d.M, P = d.taps
        var produced = 0
        d.coefficients.withUnsafeBufferPointer { coef in
            (o ?? d).coefficients.withUnsafeBufferPointer { oldCoef in
                while produced < frames && Int64(m) < outTotal {
                    let q = (m * M) / L, r = (m * M) % L
                    let ws = q + d.lead - (P - 1)
                    let fading = fadeLeft > 0, po = o ?? d
                    let wo = q + po.lead - (po.taps - 1)
                    ensure(start: fading ? min(ws, wo) : ws, last: fading ? max(q + d.lead, q + po.lead) : ws + P - 1)
                    let k = ws - base
                    let cp = coef.baseAddress! + r * P
                    if fading {
                        let t = Double(fadeTotal - fadeLeft) / Double(fadeTotal)
                        let ko = wo - base, cpo = oldCoef.baseAddress! + r * po.taps
                        for c in 0..<ch {
                            var a = 0.0, b = 0.0
                            vDSP_dotprD(buf[c] + k, 1, cp, 1, &a, vDSP_Length(P))
                            vDSP_dotprD(buf[c] + ko, 1, cpo, 1, &b, vDSP_Length(po.taps))
                            out[produced * ch + c] = Self.int32(b + (a - b) * t)
                        }
                        fadeLeft -= 1
                        if fadeLeft == 0 { fadeFrom = nil }
                    } else {
                        for c in 0..<ch {
                            var acc = 0.0
                            vDSP_dotprD(buf[c] + k, 1, cp, 1, &acc, vDSP_Length(P))
                            out[produced * ch + c] = Self.int32(acc)
                        }
                    }
                    produced += 1; m += 1
                }
            }
        }
        return produced
    }
}

// MARK: - Choosing a target rate

enum UpsamplingMode: String, Codable, CaseIterable, Identifiable {
    case off, double, powerOfTwo, deviceMax
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off (native rate)"
        case .double: "2× the source rate"
        case .powerOfTwo: "Highest power-of-two multiple"
        case .deviceMax: "Device maximum rate"
        }
    }
}

struct UpsamplingSettings: Equatable, Codable {
    var mode: UpsamplingMode = .off
    var filter = ResamplerConfig.standard
    /// Never go above this rate (limits CPU use). 0 = no limit.
    var maxRate: Double = 0
    /// Also resample material that is *above* the target (e.g. 352.8 kHz to a 192 kHz DAC). Off = leave as is.
    var downsampleToFit = true

    /// The named filter the configuration amounts to.
    var chosenFilter: OversamplingFilter {
        get { OversamplingFilter(filter) }
        set { filter = newValue.applied(to: filter) }
    }
}

/// Picks the output rate for a PCM stream, or nil to keep the source rate. `deviceRates` are the rates the DAC supports.
func upsamplingTarget(source: Double, mode: UpsamplingMode, deviceRates: [Double], maxRate: Double) -> Double? {
    let cap = maxRate > 0 ? maxRate : .infinity
    let rates = deviceRates.filter { $0 <= cap + 0.5 && $0 > source + 0.5 }.sorted()
    func isMultiple(_ r: Double) -> Bool { let k = r / source; return abs(k - k.rounded()) < 1e-9 }
    switch mode {
    case .off: return nil
    case .double: return rates.first { abs($0 - source * 2) < 0.5 }
    case .powerOfTwo:
        var best: Double?
        var r = source * 2
        let top = min(cap, deviceRates.max() ?? 0)
        while r <= top + 0.5 { if rates.contains(where: { abs($0 - r) < 0.5 }) { best = r }; r *= 2 }
        return best
    case .deviceMax:
        return rates.last(where: isMultiple) ?? rates.last
    }
}

/// The highest rate the device supports that does not exceed `source`, used when material must be brought down to fit.
func fitRate(source: Double, deviceRates: [Double]) -> Double? {
    if deviceRates.contains(where: { abs($0 - source) < 0.5 }) { return nil }
    let family441 = source.truncatingRemainder(dividingBy: 44_100) == 0
    let same = deviceRates.filter { r in (r.truncatingRemainder(dividingBy: 44_100) == 0) == family441 && r < source }
    return (same.max() ?? deviceRates.filter { $0 < source }.max())
}

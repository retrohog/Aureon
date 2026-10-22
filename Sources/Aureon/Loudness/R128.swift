import Foundation
import Accelerate

// EBU R128 / ITU-R BS.1770-4 loudness, EBU Tech 3342 loudness range, BS.1770 true peak and the TT "DR" dynamic-range score,
// computed in one pass over a file with vDSP.
//
//   interleaved Int32/Float ─► per channel Double ─► K-weighting (2 × vDSP_deq22D) ─► 100 ms mean-square sub-blocks
//                                                    └► 400 ms (momentary) / 3 s (short-term) / gated integral / LRA percentiles
//                           ─► per channel Float ─► polyphase FIR oversampler (vDSP_conv) ─► true peak
//                           ─► 3 s blocks of raw samples ─► RMS and peak per block ─► DR

struct R128Result: Codable, Equatable {
    var integratedLUFS: Double?          // nil when the file is silent (or shorter than 400 ms)
    var loudnessRange: Double            // LU, EBU Tech 3342
    var truePeakDB: Double               // dBTP (oversampled)
    var samplePeakDB: Double             // dBFS
    var momentaryMaxLUFS: Double?
    var shortTermMaxLUFS: Double?
    var dynamicRange: Double             // DR score, integer valued (the "DR14" figure)
    var duration: Double
    var sampleRate: Double
    var channels: Int
    var version = R128Result.currentVersion

    static let currentVersion = 2
    /// Linear true peak.
    var truePeakLinear: Double { pow(10, truePeakDB / 20) }
}

/// Channel weights of BS.1770 for the usual layouts (FLAC channel order): the LFE is left out, surrounds count +1.5 dB.
enum R128Weights {
    static func forChannels(_ n: Int) -> [Double] {
        switch n {
        case 6: return [1, 1, 1, 0, 1.41, 1.41]                       // L R C LFE Ls Rs
        case 8: return [1, 1, 1, 0, 1.41, 1.41, 1.41, 1.41]           // L R C LFE Lb Rb Ls Rs
        case 4: return [1, 1, 1.41, 1.41]                             // quad: L R Ls Rs
        case 5: return [1, 1, 1, 1.41, 1.41]                          // L R C Ls Rs
        default: return [Double](repeating: 1, count: max(1, n))
        }
    }
}

/// A double-precision biquad run through vDSP_deq22D, with state carried between blocks.
final class DeqBiquad {
    private let coef: [Double]                  // b0 b1 b2 a1 a2
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    private var inBuf: [Double], outBuf: [Double]

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double, capacity: Int) {
        coef = [b0, b1, b2, a1, a2]
        inBuf = [Double](repeating: 0, count: capacity + 2); outBuf = inBuf
    }

    /// Filters `n` samples from `x` into `y` (they may be the same buffer).
    func run(_ x: UnsafePointer<Double>, _ y: UnsafeMutablePointer<Double>, _ n: Int) {
        guard n > 0 else { return }
        if inBuf.count < n + 2 { inBuf = [Double](repeating: 0, count: n + 2); outBuf = inBuf }
        inBuf.withUnsafeMutableBufferPointer { ib in outBuf.withUnsafeMutableBufferPointer { ob in
            ib[0] = x2; ib[1] = x1
            memcpy(ib.baseAddress! + 2, x, n * 8)
            ob[0] = y2; ob[1] = y1
            vDSP_deq22D(ib.baseAddress!, 1, coef, ob.baseAddress!, 1, vDSP_Length(n))
            memcpy(y, ob.baseAddress! + 2, n * 8)
            x1 = ib[n + 1]; x2 = ib[n]; y1 = ob[n + 1]; y2 = ob[n]
        } }
    }
}

/// Polyphase FIR oversampler for true-peak detection (BS.1770-4 Annex 2): 4× below 96 kHz, 2× below 192 kHz, none above.
final class TruePeakDetector {
    let factor: Int
    private let taps = 32
    private var phases: [[Float]] = []
    private var history: [Float]
    private var work: [Float] = []
    private(set) var peak: Float = 0

    static func oversampling(for fs: Double) -> Int { fs < 96_000 ? 4 : (fs < 192_000 ? 2 : 1) }

    init(sampleRate: Double) {
        factor = Self.oversampling(for: sampleRate)
        history = [Float](repeating: 0, count: taps - 1)
        guard factor > 1 else { return }
        // windowed-sinc low-pass at the original Nyquist, designed at the oversampled rate (Kaiser window, beta 8)
        let n = taps * factor, c = Double(n - 1) / 2
        func i0(_ x: Double) -> Double { var s = 1.0, t = 1.0; for k in 1..<40 { t *= (x / (2 * Double(k))) * (x / (2 * Double(k))); s += t }; return s }
        let beta = 8.0
        var h = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let t = Double(k) - c, arg = Double.pi * t / Double(factor)
            let sinc = t == 0 ? 1.0 : sin(arg) / arg
            let r = 2 * Double(k) / Double(n - 1) - 1
            h[k] = sinc * i0(beta * (1 - r * r).squareRoot()) / i0(beta)
        }
        phases = (0..<factor).map { p in (0..<taps).map { Float(h[$0 * factor + p]) } }
        // each phase should have unity DC gain after the interpolation
        phases = phases.map { ph in let s = ph.reduce(0, +); return ph.map { $0 / s } }
    }

    func process(_ x: UnsafePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        var m: Float = 0
        vDSP_maxmgv(x, 1, &m, vDSP_Length(n)); peak = max(peak, m)
        guard factor > 1 else { return }
        if work.count < n + taps - 1 { work = [Float](repeating: 0, count: n + taps - 1) }
        var out = [Float](repeating: 0, count: n)
        work.withUnsafeMutableBufferPointer { w in
            history.withUnsafeBufferPointer { h in memcpy(w.baseAddress!, h.baseAddress!, (taps - 1) * 4) }
            memcpy(w.baseAddress! + taps - 1, x, n * 4)
            for p in 0..<factor {
                phases[p].withUnsafeBufferPointer { f in
                    out.withUnsafeMutableBufferPointer { o in
                        vDSP_conv(w.baseAddress!, 1, f.baseAddress! + (taps - 1), -1, o.baseAddress!, 1, vDSP_Length(n), vDSP_Length(taps))
                        var q: Float = 0
                        vDSP_maxmgv(o.baseAddress!, 1, &q, vDSP_Length(n)); peak = max(peak, q)
                    }
                }
            }
            for i in 0..<(taps - 1) { history[i] = w[n + i] }
        }
    }
}

final class R128Meter {
    let sampleRate: Double
    let channels: Int
    private let weights: [Double]
    private let sub: Int                                   // frames per 100 ms
    private var shelf: [DeqBiquad], rlb: [DeqBiquad]
    private var subFill = 0
    private var subSums: [Double]
    private(set) var subBlocks: [Double] = []              // channel-weighted mean square per 100 ms
    private var tp: [TruePeakDetector]
    private var samplePeak: Float = 0
    // dynamic range: 3 s blocks of unweighted samples
    private let drLen: Int
    private var drFill = 0
    private var drSum: [Double], drPeak: [Float]
    private var drRMS: [[Double]], drPeaks: [[Double]]
    private var frames = 0
    private var dbuf: [Double], fbuf: [Float]

    init(sampleRate: Double, channels: Int, chunk: Int = 16_384) {
        self.sampleRate = sampleRate; self.channels = channels
        weights = R128Weights.forChannels(channels)
        sub = max(1, Int((sampleRate / 10).rounded()))
        let k = Loudness.kWeighting(sampleRate: sampleRate)
        shelf = (0..<channels).map { _ in DeqBiquad(b0: k.0.b0, b1: k.0.b1, b2: k.0.b2, a1: k.0.a1, a2: k.0.a2, capacity: chunk) }
        rlb = (0..<channels).map { _ in DeqBiquad(b0: k.1.b0, b1: k.1.b1, b2: k.1.b2, a1: k.1.a1, a2: k.1.a2, capacity: chunk) }
        subSums = [Double](repeating: 0, count: channels)
        tp = (0..<channels).map { _ in TruePeakDetector(sampleRate: sampleRate) }
        drLen = Int(sampleRate * 3)
        drSum = [Double](repeating: 0, count: channels); drPeak = [Float](repeating: 0, count: channels)
        drRMS = Array(repeating: [], count: channels); drPeaks = Array(repeating: [], count: channels)
        dbuf = [Double](repeating: 0, count: chunk); fbuf = [Float](repeating: 0, count: chunk)
    }

    /// Adds interleaved samples in -1…1.
    func feed(_ x: UnsafePointer<Float>, frames n: Int) {
        guard n > 0 else { return }
        if fbuf.count < n { fbuf = [Float](repeating: 0, count: n); dbuf = [Double](repeating: 0, count: n) }
        for c in 0..<channels {
            fbuf.withUnsafeMutableBufferPointer { f in cblas_scopy(Int32(n), x + c, Int32(channels), f.baseAddress!, 1) }       // deinterleave channel c
            fbuf.withUnsafeBufferPointer { f in
                var m: Float = 0
                vDSP_maxmgv(f.baseAddress!, 1, &m, vDSP_Length(n)); samplePeak = max(samplePeak, m)
                tp[c].process(f.baseAddress!, n)
            }
            dbuf.withUnsafeMutableBufferPointer { d in
                fbuf.withUnsafeBufferPointer { f in vDSP_vspdp(f.baseAddress!, 1, d.baseAddress!, 1, vDSP_Length(n)) }
                // dynamic range blocks use the raw samples; do their bookkeeping before the weighting filters change the buffer
                accumulateDR(channel: c, d.baseAddress!, n)
                shelf[c].run(d.baseAddress!, d.baseAddress!, n)
                rlb[c].run(d.baseAddress!, d.baseAddress!, n)
                accumulateEnergy(channel: c, d.baseAddress!, n)
            }
        }
        frames += n
    }

    /// Per-channel 100 ms mean squares are completed when every channel has reached the end of the sub-block; the channels advance in lock step per call.
    private var subPos: [Int] = []
    private var subChannelSums: [[Double]] = []

    private func accumulateEnergy(channel c: Int, _ d: UnsafePointer<Double>, _ n: Int) {
        if subPos.isEmpty { subPos = [Int](repeating: 0, count: channels); subChannelSums = Array(repeating: [], count: channels) }
        var offset = 0
        var pos = subPos[c]
        var cur = subSums[c]
        while offset < n {
            let take = min(sub - pos, n - offset)
            var s = 0.0
            vDSP_svesqD(d + offset, 1, &s, vDSP_Length(take))
            cur += s; pos += take; offset += take
            if pos == sub { subChannelSums[c].append(cur / Double(sub)); cur = 0; pos = 0 }
        }
        subPos[c] = pos; subSums[c] = cur
        // when every channel has produced the same number of complete sub-blocks, fold them in
        if c == channels - 1 {
            let k = subChannelSums.map(\.count).min() ?? 0
            if k > 0 {
                for i in 0..<k { var e = 0.0; for ch in 0..<channels { e += weights[ch] * subChannelSums[ch][i] }; subBlocks.append(e) }
                for ch in 0..<channels { subChannelSums[ch].removeFirst(k) }
            }
        }
    }

    private var drPos: [Int] = []
    private func accumulateDR(channel c: Int, _ d: UnsafePointer<Double>, _ n: Int) {
        if drPos.isEmpty { drPos = [Int](repeating: 0, count: channels) }
        var offset = 0
        var pos = drPos[c]
        while offset < n {
            let take = min(drLen - pos, n - offset)
            var s = 0.0, m = 0.0
            vDSP_svesqD(d + offset, 1, &s, vDSP_Length(take))
            vDSP_maxmgvD(d + offset, 1, &m, vDSP_Length(take))
            drSum[c] += s; drPeak[c] = max(drPeak[c], Float(m))
            pos += take; offset += take
            if pos == drLen {
                drRMS[c].append((2 * drSum[c] / Double(drLen)).squareRoot()); drPeaks[c].append(Double(drPeak[c]))
                drSum[c] = 0; drPeak[c] = 0; pos = 0
            }
        }
        drPos[c] = pos
    }

    // MARK: results

    private static func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }

    /// Mean of `window` consecutive sub-blocks, for every position (hop = one sub-block).
    private func sliding(_ window: Int) -> [Double] {
        guard subBlocks.count >= window else { return [] }
        var out = [Double](repeating: 0, count: subBlocks.count - window + 1)
        var run = subBlocks[0..<window].reduce(0, +)
        out[0] = run / Double(window)
        if out.count > 1 { for i in 1..<out.count { run += subBlocks[i + window - 1] - subBlocks[i - 1]; out[i] = run / Double(window) } }
        return out
    }

    func integrated() -> Double? {
        let blocks = sliding(4)
        let absGated = blocks.filter { $0 > 0 && Self.lufs($0) > -70 }
        guard !absGated.isEmpty else { return nil }
        let rel = Self.lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { Self.lufs($0) > rel }
        guard !gated.isEmpty else { return nil }
        return Self.lufs(gated.reduce(0, +) / Double(gated.count))
    }

    func loudnessRange() -> Double {
        let st = sliding(30).filter { $0 > 0 && Self.lufs($0) > -70 }
        guard st.count >= 2 else { return 0 }
        let rel = Self.lufs(st.reduce(0, +) / Double(st.count)) - 20
        let l = st.map(Self.lufs).filter { $0 > rel }.sorted()
        guard l.count >= 2 else { return 0 }
        func pct(_ p: Double) -> Double { let x = p * Double(l.count - 1), i = Int(x), f = x - Double(i); return i + 1 < l.count ? l[i] * (1 - f) + l[i + 1] * f : l[i] }
        return max(0, pct(0.95) - pct(0.10))
    }

    func dynamicRange() -> Double {
        var perChannel: [Double] = []
        for c in 0..<channels {
            var rms = drRMS[c], peaks = drPeaks[c]
            if rms.count < 2 {                                    // shorter than two blocks: use the whole signal as one
                let r = (2 * (drSum[c] + rms.map { $0 * $0 / 2 * Double(drLen) }.reduce(0, +)) / Double(max(1, frames))).squareRoot()
                rms = [r]; peaks = [Double(max(drPeak[c], Float(peaks.max() ?? 0)))]
            }
            let top = rms.sorted(by: >).prefix(max(1, Int((Double(rms.count) * 0.2).rounded(.up))))
            let rms20 = (top.map { $0 * $0 }.reduce(0, +) / Double(top.count)).squareRoot()
            let sortedPeaks = peaks.sorted(by: >)
            let ref = sortedPeaks.count > 1 ? sortedPeaks[1] : sortedPeaks[0]
            guard rms20 > 0, ref > 0 else { continue }
            perChannel.append(20 * log10(ref / rms20))
        }
        guard !perChannel.isEmpty else { return 0 }
        return max(0, (perChannel.reduce(0, +) / Double(perChannel.count)).rounded())
    }

    func finish(duration: Double? = nil) -> R128Result {
        let mom = sliding(4).max().flatMap { $0 > 0 ? Self.lufs($0) : nil }
        let st = sliding(30).max().flatMap { $0 > 0 ? Self.lufs($0) : nil }
        let tpLin = tp.map { Double($0.peak) }.max() ?? 0
        func db(_ v: Double) -> Double { v > 0 ? 20 * log10(v) : -200 }
        return R128Result(integratedLUFS: integrated(), loudnessRange: loudnessRange(), truePeakDB: db(max(tpLin, Double(samplePeak))), samplePeakDB: db(Double(samplePeak)),
                          momentaryMaxLUFS: mom, shortTermMaxLUFS: st, dynamicRange: dynamicRange(), duration: duration ?? Double(frames) / sampleRate,
                          sampleRate: sampleRate, channels: channels)
    }
}

enum R128 {
    /// Analyses a whole file. Runs off the main thread; `cancelled` is polled between chunks.
    static func analyze(path: String, cancelled: () -> Bool = { false }) -> R128Result? {
        guard let f = try? openLossless(path: path), f.info.totalFrames > 0, f.info.sourceBits != 1 else { return nil }
        let ch = f.info.channels, chunk = 16_384
        let meter = R128Meter(sampleRate: f.info.sampleRate, channels: ch, chunk: chunk)
        let ints = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * ch), floats = UnsafeMutablePointer<Float>.allocate(capacity: chunk * ch)
        defer { ints.deallocate(); floats.deallocate() }
        while true {
            if cancelled() { return nil }
            let n = f.read(into: ints, frames: chunk)
            if n == 0 { break }
            vDSP_vflt32(ints, 1, floats, 1, vDSP_Length(n * ch))
            var scale: Float = 1 / 2_147_483_648
            vDSP_vsmul(floats, 1, &scale, floats, 1, vDSP_Length(n * ch))
            meter.feed(floats, frames: n)
        }
        return meter.finish(duration: f.info.duration)
    }

    /// Analyses interleaved Float samples already in memory (tests, the transcoder).
    static func analyze(samples: [Float], sampleRate: Double, channels: Int) -> R128Result {
        let meter = R128Meter(sampleRate: sampleRate, channels: channels)
        samples.withUnsafeBufferPointer { p in
            var i = 0
            let total = samples.count / channels
            while i < total { let n = min(16_384, total - i); meter.feed(p.baseAddress! + i * channels, frames: n); i += n }
        }
        return meter.finish()
    }
}

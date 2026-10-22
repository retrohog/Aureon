import Foundation
import Accelerate

// PCM → DSD, for a DAC that takes DSD over PCM (DoP).
//
//   PCM ──(polyphase resampler, the chosen oversampling filter)──▶ 16 × the base rate (32 × for DSD512)
//       ──(half-band interpolators, ×2 each)──▶ the DSD rate
//       ──(5th or 7th-order one-bit noise-shaping modulator)──▶ DSD bits ──▶ 16 per channel into each 24-bit DoP sample
//
// Everything here runs on the producer thread, in double precision. The audio thread only ever sees finished DoP words in the ring, like any
// other stream. The modulator is an error-feedback loop whose noise-transfer function is tabulated in `ModulatorTables` (designed and
// simulated by Tools/modulator/design_ntf.py): zeros spread over the audio band, a flat out-of-band gain of 1.35–1.4 so a one-bit loop of that
// order stays stable. The input is scaled so full scale sits at half the one-bit range, the level DSD itself uses for 0 dB, and a loop that
// does overload is reset rather than allowed to run away.

enum DSDOutputRate: Int, Codable, CaseIterable, Identifiable {
    case dsd64 = 64, dsd128 = 128, dsd256 = 256, dsd512 = 512
    var id: Int { rawValue }
    var name: String { "DSD\(rawValue)" }
    /// Bit rate for the 44.1 kHz family (`base` 44 100) or the 48 kHz family (`base` 48 000).
    func hz(base: Double) -> Double { base * Double(rawValue) }
}

enum DSDModulatorOrder: Int, Codable, CaseIterable, Identifiable {
    case fifth = 5, seventh = 7
    var id: Int { rawValue }
    var title: String { self == .fifth ? "5th order" : "7th order" }
    var summary: String {
        self == .fifth ? "Stable with a wide margin and lighter on the processor. About 110 dB of in-band signal-to-noise at DSD64, more at the higher rates."
                       : "Pushes the noise further from the audio band: about 120 dB at DSD64 and as clean as the maths allows from DSD128 up."
    }
}

struct DSDOutputSettings: Equatable, Codable {
    /// Convert PCM music to DSD for the DAC (needs "DoP" enabled for DSD).
    var enabled = false
    /// The highest DSD rate to use. The DAC must accept the matching DoP rate and the Mac must keep up, or a lower one is used.
    var maxRate: DSDOutputRate = .dsd512
    var modulator: DSDModulatorOrder = .seventh
}

extension DSDOutputSettings {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        maxRate = try c.decodeIfPresent(DSDOutputRate.self, forKey: .maxRate) ?? .dsd512
        modulator = try c.decodeIfPresent(DSDModulatorOrder.self, forKey: .modulator) ?? .seventh
    }
}

// MARK: - The modulator

/// A one-bit sigma-delta modulator of 5th or 7th order. Transposed direct form II of the error-feedback structure
///     v = x + s;  y = sign(v);  e = y − v;  u = y − x;  state update from e and u,
/// which realises NTF(z) = b(z)/a(z) exactly, with a signal transfer function of 1.
final class SigmaDeltaModulator {
    /// Inputs beyond this are limited: a one-bit loop of this order is stable up to about 0.65 of its range.
    static let inputLimit = 0.62
    /// A loop whose quantiser input grows past this has gone unstable (in normal use it stays below about 1.4).
    static let overloadThreshold = 8.0

    let order: Int, osr: Int
    /// How many times the loop was reset because it overloaded.
    private(set) var overloads = 0
    private var w = [Double](repeating: 0, count: 7)
    private let b: [Double], a: [Double]

    init?(order: DSDModulatorOrder, osr: Int) {
        guard let e = ModulatorTables.entries.first(where: { $0.order == order.rawValue && $0.osr == osr }), e.b.count == order.rawValue, e.a.count == order.rawValue else { return nil }
        self.order = order.rawValue; self.osr = osr
        b = e.b + [Double](repeating: 0, count: 7 - e.b.count)
        a = e.a + [Double](repeating: 0, count: 7 - e.a.count)
    }

    func reset() { w = [Double](repeating: 0, count: 7) }

    /// Modulates `count` samples (a multiple of 8) into `count / 8` bytes, oldest bit in bit 7, a one bit meaning positive.
    func process(_ x: UnsafePointer<Double>, count: Int, into out: UnsafeMutablePointer<UInt8>) {
        precondition(count % 8 == 0)
        let b0 = b[0], b1 = b[1], b2 = b[2], b3 = b[3], b4 = b[4], b5 = b[5], b6 = b[6]
        let a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3], a4 = a[4], a5 = a[5], a6 = a[6]
        var w0 = w[0], w1 = w[1], w2 = w[2], w3 = w[3], w4 = w[4], w5 = w[5], w6 = w[6]
        let lim = Self.inputLimit, over = Self.overloadThreshold
        var resets = 0
        var p = 0
        if order == 7 {
            for j in 0..<(count / 8) {
                var byte: UInt8 = 0
                for _ in 0..<8 {
                    let xi = min(max(x[p], -lim), lim); p += 1
                    let v = xi + w0
                    let y: Double = v >= 0 ? 1 : -1
                    let e = y - v, u = y - xi
                    w0 = w1 + b0 * e - a0 * u
                    w1 = w2 + b1 * e - a1 * u
                    w2 = w3 + b2 * e - a2 * u
                    w3 = w4 + b3 * e - a3 * u
                    w4 = w5 + b4 * e - a4 * u
                    w5 = w6 + b5 * e - a5 * u
                    w6 = b6 * e - a6 * u
                    byte = (byte << 1) | (y > 0 ? 1 : 0)
                    if v > over || v < -over { w0 = 0; w1 = 0; w2 = 0; w3 = 0; w4 = 0; w5 = 0; w6 = 0; resets += 1 }
                }
                out[j] = byte
            }
        } else {
            for j in 0..<(count / 8) {
                var byte: UInt8 = 0
                for _ in 0..<8 {
                    let xi = min(max(x[p], -lim), lim); p += 1
                    let v = xi + w0
                    let y: Double = v >= 0 ? 1 : -1
                    let e = y - v, u = y - xi
                    w0 = w1 + b0 * e - a0 * u
                    w1 = w2 + b1 * e - a1 * u
                    w2 = w3 + b2 * e - a2 * u
                    w3 = w4 + b3 * e - a3 * u
                    w4 = b4 * e - a4 * u
                    byte = (byte << 1) | (y > 0 ? 1 : 0)
                    if v > over || v < -over { w0 = 0; w1 = 0; w2 = 0; w3 = 0; w4 = 0; resets += 1 }
                }
                out[j] = byte
            }
        }
        w[0] = w0; w[1] = w1; w[2] = w2; w[3] = w3; w[4] = w4; w[5] = w5; w[6] = w6
        overloads += resets
    }
}

// MARK: - Interpolation to the DSD rate

/// Doubles the sample rate of a signal that occupies only the lower part of the spectrum, with a Kaiser-windowed half-band filter: the even
/// output samples are the input samples themselves and each odd one is a symmetric sum over the neighbours, so the cost is half the taps.
/// The output lags the input by `pairs` input samples (a few microseconds at the rates used here).
final class HalfbandInterpolator {
    /// Coefficient pairs: the filter has 4·pairs − 1 taps, `pairs` of them to each side of the centre on odd offsets.
    let pairs: Int
    private let hist: Int
    private let g: UnsafeMutablePointer<Double>          // 2·pairs taps, symmetric
    private let buf: UnsafeMutablePointer<Double>
    private let odd: UnsafeMutablePointer<Double>
    private let maxBlock: Int

    /// Pairs needed to keep everything above `inputRate − bandEdge` (the image of the band edge) `attenuationDB` down.
    static func pairs(inputRate: Double, bandEdge: Double, attenuationDB: Double) -> Int {
        let width = max(0.05, (inputRate - 2 * bandEdge) / (2 * inputRate))
        let n = Int(((attenuationDB - 7.95) / (2.285 * 2 * Double.pi * width)).rounded(.up)) + 1
        return max(2, (n + 4) / 4)
    }

    init(inputRate: Double, bandEdge: Double, attenuationDB: Double = 130, maxBlock: Int) {
        let h = Self.pairs(inputRate: inputRate, bandEdge: bandEdge, attenuationDB: attenuationDB)
        pairs = h
        hist = 2 * h
        self.maxBlock = maxBlock
        let n = 4 * h - 1, c = Double(n - 1) / 2
        let beta = DSPMath.kaiserBeta(attenuation: attenuationDB), i0 = DSPMath.besselI0(beta)
        g = .allocate(capacity: 2 * h); buf = .allocate(capacity: 2 * h + maxBlock); odd = .allocate(capacity: maxBlock)
        // c_k = h[2k+1]; g is c reversed then c
        for k in 0..<h {
            let j = Double(2 * k + 1)
            let t = j / 2
            let r = j / c
            let ck = sin(Double.pi * t) / (Double.pi * t) * DSPMath.besselI0(beta * (1 - r * r).squareRoot()) / i0
            g[h - 1 - k] = ck; g[h + k] = ck
        }
        buf.initialize(repeating: 0, count: 2 * h + maxBlock)
    }

    deinit { g.deallocate(); buf.deallocate(); odd.deallocate() }

    func reset() { buf.update(repeating: 0, count: hist) }

    /// Reads `n` samples (at most `maxBlock`) and writes `2n`.
    func process(_ x: UnsafePointer<Double>, count n: Int, into out: UnsafeMutablePointer<Double>) {
        precondition(n <= maxBlock)
        (buf + hist).update(from: x, count: n)
        vDSP_convD(buf + (hist - 2 * pairs + 1), 1, g, 1, odd, 1, vDSP_Length(n), vDSP_Length(2 * pairs))
        let even = buf + (hist - pairs)
        for t in 0..<n { out[2 * t] = even[t]; out[2 * t + 1] = odd[t] }
        buf.update(from: buf + n, count: hist)
    }
}

/// One channel's path from the intermediate rate to DSD bits: `log2(factor)` half-band stages, then the modulator.
final class DSDLane {
    private let stages: [HalfbandInterpolator]
    private let modulator: SigmaDeltaModulator
    private let x: UnsafeMutablePointer<Double>
    private let a: UnsafeMutablePointer<Double>
    private let b: UnsafeMutablePointer<Double>
    private let d: UnsafeMutablePointer<Double>
    let bytes: UnsafeMutablePointer<UInt8>
    let chunkIn: Int, factor: Int

    init?(order: DSDModulatorOrder, rate: DSDOutputRate, intermediateRate: Double, factor: Int, bandEdge: Double, chunkIn: Int) {
        guard factor >= 1, factor & (factor - 1) == 0, let m = SigmaDeltaModulator(order: order, osr: rate.rawValue) else { return nil }
        var s: [HalfbandInterpolator] = [], r = intermediateRate, n = chunkIn, f = factor
        while f > 1 { s.append(HalfbandInterpolator(inputRate: r, bandEdge: bandEdge, maxBlock: n)); r *= 2; n *= 2; f /= 2 }
        guard f == 1 else { return nil }
        stages = s; modulator = m; self.chunkIn = chunkIn; self.factor = factor
        let total = chunkIn * factor
        x = .allocate(capacity: chunkIn); a = .allocate(capacity: total); b = .allocate(capacity: total); d = .allocate(capacity: total)
        bytes = .allocate(capacity: total / 8)
    }

    deinit { x.deallocate(); a.deallocate(); b.deallocate(); d.deallocate(); bytes.deallocate() }

    var overloads: Int { modulator.overloads }

    func reset() { stages.forEach { $0.reset() }; modulator.reset() }

    /// Takes `chunkIn` interleaved Int32 frames (channel `c` of `channels`), leaves `chunkIn · factor / 8` bytes in `bytes`.
    func run(_ pcm: UnsafePointer<Int32>, channels: Int, channel c: Int) {
        let scale = 0.5 / 2_147_483_648.0, lim = 0.6
        for i in 0..<chunkIn { x[i] = min(max(Double(pcm[i * channels + c]) * scale, -lim), lim) }
        var src: UnsafePointer<Double> = UnsafePointer(x), n = chunkIn
        for (k, st) in stages.enumerated() {
            let dst = k == stages.count - 1 ? d : (k % 2 == 0 ? a : b)
            st.process(src, count: n, into: dst)
            src = UnsafePointer(dst); n *= 2
        }
        modulator.process(src, count: n, into: bytes)
    }
}

// MARK: - The source

/// PCM at the intermediate rate in, DoP words out (marker byte still zero: `DoPStampSource` adds it, so the markers stay continuous
/// across gapless track changes).
final class PCMToDSDSource: FrameSource {
    static let chunkIn = 1024
    private let upstream: FrameSource
    private let lanes: [DSDLane]
    private let ch: Int
    private let factor: Int
    let info: StreamInfo
    private let total: Int64
    private let chunkFrames: Int                        // DoP frames made from one chunk
    private let pcm: UnsafeMutablePointer<Int32>
    private let packed: UnsafeMutablePointer<Int32>
    private var avail = 0, offset = 0
    private var pos: Int64 = 0                          // DoP frames handed out
    private var upstreamDone = false

    /// `upstream` must run at `plan.intermediateRate`, in stereo.
    init?(_ upstream: FrameSource, plan: DSDOutputPlan) {
        let u = upstream.info
        guard (1...2).contains(u.channels), abs(u.sampleRate - plan.intermediateRate) < 0.5, plan.interpolation >= 2,
              Self.chunkIn * plan.interpolation % 16 == 0 else { return nil }
        ch = u.channels; factor = plan.interpolation
        let edge = max(24_000, min((u.sourceRate ?? u.sampleRate) / 2, 0.3 * u.sampleRate))
        var made: [DSDLane] = []
        for _ in 0..<ch {
            guard let l = DSDLane(order: plan.order, rate: plan.rate, intermediateRate: u.sampleRate, factor: plan.interpolation, bandEdge: edge, chunkIn: Self.chunkIn) else { return nil }
            made.append(l)
        }
        lanes = made
        self.upstream = upstream
        chunkFrames = Self.chunkIn * plan.interpolation / 16
        // two frames of tail so the last samples leave the interpolators
        total = (u.totalFrames * Int64(plan.interpolation) + 15) / 16 + 2
        pcm = .allocate(capacity: Self.chunkIn * ch); packed = .allocate(capacity: chunkFrames * ch)
        info = StreamInfo(sampleRate: plan.carrier, channels: ch, sourceBits: u.sourceBits, totalFrames: total, codec: u.codec, isDoP: true,
                          sourceRate: u.sourceRate ?? u.sampleRate, transparent: false)
    }

    deinit { pcm.deallocate(); packed.deallocate() }

    /// Times of loop resets since the stream was opened (zero in normal use).
    var overloads: Int { lanes.reduce(0) { $0 + $1.overloads } }

    private func refill() {
        var got = 0
        if !upstreamDone {
            while got < Self.chunkIn {
                let n = upstream.read(into: pcm + got * ch, frames: Self.chunkIn - got)
                if n == 0 { upstreamDone = true; break }
                got += n
            }
        }
        if got < Self.chunkIn { (pcm + got * ch).update(repeating: 0, count: (Self.chunkIn - got) * ch) }
        let c = ch, p = UnsafePointer(pcm)
        if c == 1 { lanes[0].run(p, channels: 1, channel: 0) }
        else { DispatchQueue.concurrentPerform(iterations: c) { lanes[$0].run(p, channels: c, channel: $0) } }
        for k in 0..<c {
            let bytes = lanes[k].bytes
            for f in 0..<chunkFrames { packed[f * c + k] = (Int32(bytes[2 * f]) << 16) | (Int32(bytes[2 * f + 1]) << 8) }
        }
        avail = chunkFrames; offset = 0
    }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var done = 0
        while done < frames && pos < total {
            if avail == 0 { refill() }
            let n = min(frames - done, avail, Int(total - pos))
            (buf + done * ch).update(from: packed + offset * ch, count: n * ch)
            done += n; offset += n; avail -= n; pos += Int64(n)
        }
        return done
    }

    func seek(to frame: Int64) {
        let f = max(0, min(frame, total))
        pos = f; avail = 0; offset = 0; upstreamDone = false
        lanes.forEach { $0.reset() }
        upstream.seek(to: min(upstream.info.totalFrames, f * 16 / Int64(factor)))
    }

    // MARK: speed

    /// DSD bits per second (all channels) this machine makes from PCM: both channels of DSD256, 0.1 s, after a warm-up chunk.
    static func benchmarkBitsPerSecond() -> Double? {
        let plan = DSDOutputPlan(rate: .dsd256, base: 44_100, order: .seventh)
        let rate = plan.intermediateRate, frames = Int(rate / 10)
        let tone = ToneFrames(rate: rate, frames: frames + chunkIn * 2)
        guard let s = PCMToDSDSource(tone, plan: plan) else { return nil }
        let out = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * 2); defer { out.deallocate() }
        _ = s.read(into: out, frames: 256)
        let want = frames * plan.interpolation / 16
        var made = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        while made < want { let n = s.read(into: out, frames: 4096); if n == 0 { break }; made += n }
        let took = CFAbsoluteTimeGetCurrent() - t0
        return took > 0 ? Double(made * 16 * 2) / took : nil
    }
}

/// A stereo sine at the intermediate rate, for the speed measurement.
private final class ToneFrames: FrameSource {
    let info: StreamInfo
    private var pos = 0
    init(rate: Double, frames: Int) { info = StreamInfo(sampleRate: rate, channels: 2, sourceBits: 24, totalFrames: Int64(frames), codec: "benchmark") }
    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let n = max(0, min(frames, Int(info.totalFrames) - pos))
        for f in 0..<n {
            let v = Int32(0.4 * 2_147_483_647 * sin(2 * Double.pi * 997 * Double(pos + f) / info.sampleRate))
            buf[f * 2] = v; buf[f * 2 + 1] = v
        }
        pos += n; return n
    }
    func seek(to frame: Int64) { pos = Int(frame) }
}

// MARK: - Choosing a rate

/// What the converter will do for one stream: the DSD rate, the family it belongs to, and the rate the resampler brings the music to first.
struct DSDOutputPlan: Equatable {
    var rate: DSDOutputRate
    /// 44 100 or 48 000.
    var base: Double
    var order: DSDModulatorOrder

    var dsdRate: Double { rate.hz(base: base) }
    /// The PCM rate of the DoP stream the DAC receives.
    var carrier: Double { dsdRate / 16 }
    /// The half-band stages double the rate up to the DSD rate: 4× for DSD64, 8× for DSD128, 16× for DSD256 and DSD512.
    var interpolation: Int { min(16, rate.rawValue / 16) }
    /// The resampler (with the chosen oversampling filter) brings the music to this rate: 16 × the base, 32 × for DSD512.
    var intermediateRate: Double { dsdRate / Double(interpolation) }
}

enum DSDOutputPlanner {
    /// The highest DSD rate up to `settings.maxRate` that the device takes (as DoP) and this Mac sustains, or nil with the reason.
    /// `filterCost` is `ResamplerConfig.costFactor` of the oversampling filter.
    static func plan(settings: DSDOutputSettings, sourceRate: Double, channels: Int, deviceRates: [Double], profile: PerformanceProfile,
                     filterCost: Double) -> (plan: DSDOutputPlan?, note: String?) {
        guard channels == 2 else { return (nil, "Conversion to DSD needs a stereo stream: this one has \(channels) channel\(channels == 1 ? "" : "s"), so it is sent as PCM") }
        let is48 = Int(sourceRate.rounded()) % 48_000 == 0
        let bases: [Double] = is48 ? [48_000, 44_100] : [44_100, 48_000]
        func offered(_ r: Double) -> Bool { deviceRates.contains { abs($0 - r) < 0.5 } }
        var tooHeavy: DSDOutputRate?, notOffered = true
        for rate in DSDOutputRate.allCases.reversed() where rate.rawValue <= settings.maxRate.rawValue {
            for base in bases {
                let plan = DSDOutputPlan(rate: rate, base: base, order: settings.modulator)
                // an unknown device (no list of rates) is only trusted with DSD64
                let usable = deviceRates.isEmpty ? rate == .dsd64 : offered(plan.carrier)
                if !usable { continue }
                notOffered = false
                let resample = abs(sourceRate - plan.intermediateRate) < 0.5 ? Double.infinity : profile.resampleFactor(rate: plan.intermediateRate, channels: channels, cost: filterCost)
                let modulate = profile.modulatorFactor(dsdRate: plan.dsdRate, channels: channels)
                // both run on the producer thread, one after the other
                let combined = 1 / (1 / resample + 1 / modulate)
                if combined >= PerformanceProfile.safetyFactor { return (plan, tooHeavy.map { "\($0.name) is too heavy for this Mac in real time: using \(rate.name)" }) }
                tooHeavy = tooHeavy ?? rate
            }
        }
        if notOffered { return (nil, "The device accepts no DSD rate up to \(settings.maxRate.name): music is sent as PCM") }
        return (nil, "This Mac cannot make DSD in real time at the rates the device takes: music is sent as PCM")
    }
}

import Foundation
import Accelerate

// Room correction by convolution with an impulse response (for example a Room EQ Wizard export).
//
// Uniform-partitioned overlap-save convolution (UPOLS) on Accelerate:
//   • the IR is cut into blocks of B samples; each block is transformed once, off the audio thread
//   • on the audio thread, every B input samples cost one forward FFT, P complex multiply-accumulates over a frequency-domain
//     delay line, and one inverse FFT per channel
//   • everything is preallocated and uses the temp-buffer `vDSP_fft_zript` variant, so nothing allocates in the callback
// Latency is one block (B frames). Different IRs per channel (stereo IR) or one IR shared by all channels (mono IR).

struct ConvolutionSettings: Codable, Equatable {
    var enabled = false
    var irPath: String? = nil
    var gainDB = 0.0
    /// Scale the IR down if its frequency response boosts anywhere above 0 dB, so the correction cannot clip.
    var normalize = true
}

struct ImpulseResponse {
    var channels: [[Float]]          // 1 or 2 (more are ignored)
    var sampleRate: Double
    var length: Int { channels.first?.count ?? 0 }
}

enum IRLoader {
    /// Reads RIFF/WAVE with PCM 8–32 bit, IEEE float 32/64 bit and WAVE_FORMAT_EXTENSIBLE. Float data keeps values above 1.0.
    static func readWAV(path: String) throws -> ImpulseResponse {
        let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        guard d.count > 44, d[0..<4] == Data("RIFF".utf8), d[8..<12] == Data("WAVE".utf8) else { throw AureonError.message("not a WAV file") }
        var pos = 12, fmtTag = 0, ch = 0, rate = 0, bits = 0, dataStart = 0, dataLen = 0
        while pos + 8 <= d.count {
            let id = String(decoding: d[pos..<(pos + 4)], as: UTF8.self), len = u32(pos + 4)
            if id == "fmt " {
                fmtTag = u16(pos + 8); ch = u16(pos + 10); rate = u32(pos + 12); bits = u16(pos + 22)
                if fmtTag == 0xFFFE, len >= 26 { fmtTag = u16(pos + 32) }       // sub-format GUID starts with the real tag
            } else if id == "data" { dataStart = pos + 8; dataLen = min(len, d.count - dataStart); break }
            pos += 8 + len + (len & 1)
        }
        guard ch > 0, rate > 0, dataStart > 0 else { throw AureonError.message("incomplete WAV header") }
        let bytes = bits / 8, frames = dataLen / (bytes * ch)
        guard frames > 0 else { throw AureonError.message("the impulse response is empty") }
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: min(ch, 2))
        for f in 0..<frames {
            for c in 0..<min(ch, 2) {
                let o = dataStart + (f * ch + c) * bytes
                var v: Float
                switch (fmtTag, bits) {
                case (3, 32): v = Float(bitPattern: UInt32(truncatingIfNeeded: u32(o)))
                case (3, 64): var x: UInt64 = 0; for k in 0..<8 { x |= UInt64(d[o + k]) << (8 * UInt64(k)) }; v = Float(Double(bitPattern: x))
                case (1, 8): v = (Float(d[o]) - 128) / 128
                case (1, 16): v = Float(Int16(truncatingIfNeeded: u16(o))) / 32_768
                case (1, 24): var x = Int32(d[o]) | Int32(d[o + 1]) << 8 | Int32(d[o + 2]) << 16; if x & 0x800000 != 0 { x |= ~0xFFFFFF }; v = Float(x) / 8_388_608
                case (1, 32): v = Float(Int32(truncatingIfNeeded: u32(o))) / 2_147_483_648
                default: throw AureonError.message("unsupported WAV format (tag \(fmtTag), \(bits)-bit)")
                }
                out[c][f] = v.isFinite ? v : 0
            }
        }
        return ImpulseResponse(channels: out, sampleRate: Double(rate))
    }

    /// Removes the noise-floor tail (below −100 dB of the peak) and caps the length.
    static func trimmed(_ ir: ImpulseResponse, maxSeconds: Double = 12) -> ImpulseResponse {
        let peak = ir.channels.flatMap { $0 }.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return ir }
        let floor = peak * 1e-5
        var last = 0
        for ch in ir.channels { if let i = ch.lastIndex(where: { abs($0) > floor }) { last = max(last, i) } }
        let n = min(last + 1, Int(maxSeconds * ir.sampleRate))
        return ImpulseResponse(channels: ir.channels.map { Array($0.prefix(n)) }, sampleRate: ir.sampleRate)
    }

    private final class FloatSource: FrameSource {
        let samples: [[Float]], scale: Float
        var info: StreamInfo
        var pos = 0
        init(_ s: [[Float]], rate: Double, peak: Float) {
            samples = s; scale = 1 / peak
            info = StreamInfo(sampleRate: rate, channels: s.count, sourceBits: 32, totalFrames: Int64(s[0].count), codec: "IR")
        }
        func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
            let n = min(frames, samples[0].count - pos)
            for f in 0..<max(0, n) { for c in 0..<samples.count { buf[f * samples.count + c] = Int32(max(-1.0, min(0.99999999, Double(samples[c][pos + f] * scale))) * 2_147_483_647) } }
            pos += max(0, n); return max(0, n)
        }
        func seek(to frame: Int64) { pos = Int(frame) }
    }

    /// Converts an IR to another sample rate with the native resampler (linear phase, so the response keeps its timing).
    static func resampled(_ ir: ImpulseResponse, to rate: Double) -> ImpulseResponse? {
        if abs(ir.sampleRate - rate) < 0.5 { return ir }
        let peak = ir.channels.flatMap { $0 }.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0, let r = ResamplingSource(FloatSource(ir.channels, rate: ir.sampleRate, peak: peak), outRate: rate, config: .standard) else { return nil }
        let ch = ir.channels.count
        let raw = readAll(r)
        // A value-preserving converter keeps sample *levels*, but an impulse response is a filter: its gain is the sum of its taps,
        // which scales with the sample rate. Multiply by fs_old / fs_new so the frequency response is unchanged.
        let k = Float(ir.sampleRate / rate) * peak / 2_147_483_648
        var out = [[Float]](repeating: [], count: ch)
        for f in 0..<(raw.count / ch) { for c in 0..<ch { out[c].append(Float(raw[f * ch + c]) * k) } }
        return ImpulseResponse(channels: out, sampleRate: rate)
    }

    /// Reads a file's audio into Int32 frames (shared with the tests).
    private static func readAll(_ s: FrameSource) -> [Int32] {
        var out: [Int32] = []
        let ch = s.info.channels
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * ch); defer { buf.deallocate() }
        while true { let n = s.read(into: buf, frames: 4096); if n == 0 { break }; out.append(contentsOf: UnsafeBufferPointer(start: buf, count: n * ch)) }
        return out
    }
}

/// The IR transformed into frequency-domain partitions. Immutable and shareable.
final class PreparedIR: @unchecked Sendable {
    let block: Int, fftSize: Int, partitions: Int, channels: Int, rate: Double, lengthFrames: Int
    let appliedGainDB: Double
    fileprivate let real: [UnsafeMutablePointer<Float>], imag: [UnsafeMutablePointer<Float>]

    init(_ ir: ImpulseResponse, block B: Int = 512, gainDB: Double, normalize: Bool) {
        block = B; fftSize = 2 * B; rate = ir.sampleRate; channels = ir.channels.count; lengthFrames = ir.length
        let N = 2 * B, half = N / 2
        partitions = max(1, (ir.length + B - 1) / B)
        let P = partitions

        // peak of the frequency response (to keep boosts from clipping)
        var g = pow(10, gainDB / 20)
        if normalize {
            var size = 1; while size < ir.length * 2 { size <<= 1 }
            var peak = 0.0
            for ch in ir.channels {
                var re = [Double](repeating: 0, count: size), im = [Double](repeating: 0, count: size)
                for i in 0..<ch.count { re[i] = Double(ch[i]) }
                DSPMath.fft(&re, &im, inverse: false)
                for k in 0..<(size / 2) { peak = max(peak, (re[k] * re[k] + im[k] * im[k]).squareRoot()) }
            }
            if peak * g > 1 { g = 1 / peak }
        }
        appliedGainDB = 20 * log10(g)

        let log2n = vDSP_Length(log2(Double(N)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        let scale = Float(g) / Float(4 * N)          // forward zrip scales by 2 per transform (×4 for X·H) and the inverse by 2N
        var rs: [UnsafeMutablePointer<Float>] = [], isp: [UnsafeMutablePointer<Float>] = []
        for ch in ir.channels {
            let r = UnsafeMutablePointer<Float>.allocate(capacity: P * half), i = UnsafeMutablePointer<Float>.allocate(capacity: P * half)
            r.initialize(repeating: 0, count: P * half); i.initialize(repeating: 0, count: P * half)
            for p in 0..<P {
                var split = DSPSplitComplex(realp: r + p * half, imagp: i + p * half)
                for k in 0..<half {
                    let i0 = p * B + 2 * k, i1 = p * B + 2 * k + 1
                    // only the first B samples of each 2B-point block carry IR data (the rest is the overlap-save zero pad)
                    (r + p * half)[k] = (2 * k < B && i0 < ch.count) ? ch[i0] * scale : 0
                    (i + p * half)[k] = (2 * k + 1 < B && i1 < ch.count) ? ch[i1] * scale : 0
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
            rs.append(r); isp.append(i)
        }
        real = rs; imag = isp
    }
    deinit { real.forEach { $0.deallocate() }; imag.forEach { $0.deallocate() } }
}

final class ConvolutionProcessor: RTProcessor {
    let name: String
    let latencyFrames: Int
    private let ir: PreparedIR
    private let ch: Int
    private let B: Int, N: Int, half: Int, P: Int
    private let setup: FFTSetup
    private let log2n: vDSP_Length
    // per channel state
    private let fdlR: [UnsafeMutablePointer<Float>], fdlI: [UnsafeMutablePointer<Float>]
    private let prev: [UnsafeMutablePointer<Float>], cur: [UnsafeMutablePointer<Float>], out: [UnsafeMutablePointer<Float>]
    private let accR: UnsafeMutablePointer<Float>, accI: UnsafeMutablePointer<Float>
    private let tmpR: UnsafeMutablePointer<Float>, tmpI: UnsafeMutablePointer<Float>
    private var fill = 0, slot = 0

    init(ir: PreparedIR, channels: Int) {
        self.ir = ir; ch = channels; B = ir.block; N = ir.fftSize; half = ir.fftSize / 2; P = ir.partitions
        latencyFrames = ir.block
        log2n = vDSP_Length(log2(Double(ir.fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p }
        fdlR = (0..<channels).map { _ in alloc(ir.partitions * (ir.fftSize / 2)) }; fdlI = (0..<channels).map { _ in alloc(ir.partitions * (ir.fftSize / 2)) }
        prev = (0..<channels).map { _ in alloc(ir.block) }; cur = (0..<channels).map { _ in alloc(ir.block) }; out = (0..<channels).map { _ in alloc(ir.block) }
        accR = alloc(ir.fftSize / 2); accI = alloc(ir.fftSize / 2); tmpR = alloc(ir.fftSize / 2); tmpI = alloc(ir.fftSize / 2)
        name = String(format: "Room correction: convolution, %.2f s IR, %.0f ms latency, %+.1f dB", Double(ir.lengthFrames) / ir.rate, 1000 * Double(ir.block) / ir.rate, ir.appliedGainDB)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for a in [fdlR, fdlI, prev, cur, out] { a.forEach { $0.deallocate() } }
        accR.deallocate(); accI.deallocate(); tmpR.deallocate(); tmpI.deallocate()
    }

    func process(_ x: UnsafeMutablePointer<Float>, frames: Int) {
        for f in 0..<frames {
            for c in 0..<ch {
                cur[c][fill] = x[f * ch + c]
                x[f * ch + c] = out[c][fill]
            }
            fill += 1
            if fill == B { for c in 0..<ch { runBlock(c) }; slot = (slot + 1) % P; fill = 0 }
        }
    }

    private func runBlock(_ c: Int) {
        let hp = min(c, ir.channels - 1)
        let sR = fdlR[c] + slot * half, sI = fdlI[c] + slot * half
        // [previous block | current block] packed as even/odd samples
        for k in 0..<half {
            let i0 = 2 * k, i1 = 2 * k + 1
            sR[k] = i0 < B ? prev[c][i0] : cur[c][i0 - B]
            sI[k] = i1 < B ? prev[c][i1] : cur[c][i1 - B]
        }
        prev[c].update(from: cur[c], count: B)
        var xs = DSPSplitComplex(realp: sR, imagp: sI), tmp = DSPSplitComplex(realp: tmpR, imagp: tmpI)
        vDSP_fft_zript(setup, &xs, 1, &tmp, log2n, FFTDirection(kFFTDirection_Forward))

        accR.update(repeating: 0, count: half); accI.update(repeating: 0, count: half)
        let hR = ir.real[hp], hI = ir.imag[hp]
        for p in 0..<P {
            let s = (slot - p + P) % P
            let xr = fdlR[c] + s * half, xi = fdlI[c] + s * half, yr = hR + p * half, yi = hI + p * half
            accR[0] += xr[0] * yr[0]; accI[0] += xi[0] * yi[0]          // DC and Nyquist are packed into bin 0 as two real values
            var X = DSPSplitComplex(realp: xr + 1, imagp: xi + 1), H = DSPSplitComplex(realp: yr + 1, imagp: yi + 1)
            var A = DSPSplitComplex(realp: accR + 1, imagp: accI + 1)
            vDSP_zvma(&X, 1, &H, 1, &A, 1, &A, 1, vDSP_Length(half - 1))
        }
        var acc = DSPSplitComplex(realp: accR, imagp: accI)
        vDSP_fft_zript(setup, &acc, 1, &tmp, log2n, FFTDirection(kFFTDirection_Inverse))
        for j in 0..<B { let idx = B + j; out[c][j] = idx & 1 == 0 ? accR[idx / 2] : accI[idx / 2] }   // overlap-save: keep the last B samples
    }
}

import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

// ABX blind testing and A/B mastering comparison.
//
//   file A ─► decode ─► (resample) ─► stereo ─┐
//                                             ├─► producer thread "aureon.abx" ─► RingBuffer (4 ch: A L/R, B L/R) ─► ABXCore.process ─► IOProc
//   file B ─► decode ─► (resample) ─► stereo ─┘        (B shifted by the alignment offset,                        (gains, 10 ms crossfade,
//                                                       loop region with short fades)                              start/stop ramp)
//
// Both files travel through one ring, frame by frame, so they can never drift apart: switching only changes which half of each frame
// is heard. Everything the interface changes reaches the audio thread through atomics; `process` allocates nothing, takes no locks and
// sends no messages.

enum ABXSlot: Int, Sendable, CaseIterable { case a = 0, b = 1
    var label: String { self == .a ? "A" : "B" }
    var other: ABXSlot { self == .a ? .b : .a }
}

// MARK: - Decoded stereo stream

/// A file decoded to interleaved stereo Int32 at a fixed rate: mono is doubled, multichannel keeps its front left and right.
/// Producer and analysis threads only.
final class ABXStream {
    let path: String
    /// The file as it is stored.
    let source: StreamInfo
    let rate: Double
    /// Length at `rate`.
    let frames: Int64
    private let upstream: FrameSource
    private let ch: Int
    private let pull: UnsafeMutablePointer<Int32>
    private let pullFrames = 4096

    init(path: String, rate: Double) throws {
        let file = try openLossless(path: path)
        guard file.info.sourceBits != 1, !file.info.isDoP else { throw AureonError.message("DSD files cannot be compared yet; convert them to PCM first.") }
        guard file.info.totalFrames > 0 else { throw AureonError.message("\((path as NSString).lastPathComponent) has no audio.") }
        self.path = path
        source = file.info
        self.rate = rate
        if abs(file.info.sampleRate - rate) < 0.5 {
            upstream = file
        } else {
            guard let r = ResamplingSource(file, outRate: rate, config: .standard) else { throw AureonError.message("Cannot convert \(Int(file.info.sampleRate)) Hz to \(Int(rate)) Hz.") }
            upstream = r
        }
        frames = upstream.info.totalFrames
        ch = max(1, upstream.info.channels)
        pull = .allocate(capacity: pullFrames * ch)
    }

    deinit { pull.deallocate() }

    func seek(to frame: Int64) { upstream.seek(to: max(0, min(frame, frames))) }

    /// Reads up to `frames` stereo frames (L, R interleaved). Returns 0 at the end.
    func read(into dst: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var done = 0
        while done < frames {
            let n = upstream.read(into: pull, frames: min(pullFrames, frames - done))
            if n == 0 { break }
            let o = dst + done * 2
            if ch == 1 {
                for i in 0..<n { o[i * 2] = pull[i]; o[i * 2 + 1] = pull[i] }
            } else {
                for i in 0..<n { o[i * 2] = pull[i * ch]; o[i * 2 + 1] = pull[i * ch + 1] }
            }
            done += n
        }
        return done
    }

    /// A short description of what happens to the file on its way to the comparison.
    var conversion: String? {
        var parts: [String] = []
        if abs(source.sampleRate - rate) >= 0.5 { parts.append("resampled \(formatRate(source.sampleRate)) → \(formatRate(rate))") }
        if source.channels == 1 { parts.append("mono on both channels") } else if source.channels > 2 { parts.append("front left/right of \(source.channels) channels") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Loudness matching

enum ABXLoudness {
    /// Integrated loudness of exactly what the comparison plays (stereo, at the comparison rate), EBU R128 (vDSP K-weighting).
    static func measure(_ s: ABXStream, cancelled: () -> Bool = { false }) -> R128Result? {
        let chunk = 16_384
        let meter = R128Meter(sampleRate: s.rate, channels: 2, chunk: chunk)
        let ints = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * 2), floats = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer { ints.deallocate(); floats.deallocate() }
        s.seek(to: 0)
        while true {
            if cancelled() { return nil }
            let n = s.read(into: ints, frames: chunk)
            if n == 0 { break }
            vDSP_vflt32(ints, 1, floats, 1, vDSP_Length(n * 2))
            var scale: Float = 1 / 2_147_483_648
            vDSP_vsmul(floats, 1, &scale, floats, 1, vDSP_Length(n * 2))
            meter.feed(floats, frames: n)
        }
        s.seek(to: 0)
        return meter.finish(duration: Double(s.frames) / s.rate)
    }

    /// Linear gains that bring both to the loudness of the quieter one: only the louder file is turned down, so nothing can clip.
    /// R128 integrated loudness moves exactly with gain, so the match is exact to the precision of the measurement.
    static func gains(lufsA: Double?, lufsB: Double?) -> (a: Double, b: Double) {
        guard let la = lufsA, let lb = lufsB, la.isFinite, lb.isFinite else { return (1, 1) }
        let quiet = min(la, lb)
        return (pow(10, -(la - quiet) / 20), pow(10, -(lb - quiet) / 20))
    }
}

// MARK: - Alignment

/// Finds how far B is shifted against A, so that both play the same moment: B[t + offset] ≈ A[t].
enum ABXAlign {
    struct Result: Equatable, Sendable {
        /// Frames at the comparison rate. Positive: B starts later than A.
        var offset: Int
        /// Normalised correlation at that offset, 0…1. Below `minimumConfidence` the offset is not trusted.
        var confidence: Double
    }
    static let minimumConfidence = 0.5

    /// Decodes the first `seconds` of each (mono sum) and correlates them.
    static func measure(_ a: ABXStream, _ b: ABXStream, seconds: Double = 24, maxLagSeconds: Double = 4) -> Result {
        let n = Int(a.rate * seconds)
        let xa = mono(a, frames: n), xb = mono(b, frames: n + Int(a.rate * maxLagSeconds))
        return offset(a: xa, b: xb, maxLag: Int(a.rate * maxLagSeconds))
    }

    private static func mono(_ s: ABXStream, frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        let chunk = 8192
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * 2)
        defer { buf.deallocate() }
        s.seek(to: 0)
        var at = 0
        while at < frames {
            let got = s.read(into: buf, frames: min(chunk, frames - at))
            if got == 0 { break }
            for i in 0..<got { out[at + i] = (Float(buf[i * 2]) + Float(buf[i * 2 + 1])) * (0.5 / 2_147_483_648) }
            at += got
        }
        s.seek(to: 0)
        return Array(out.prefix(at))
    }

    /// Coarse search on a 4× decimated copy by FFT cross-correlation, then the exact sample by direct correlation around it.
    static func offset(a: [Float], b: [Float], maxLag: Int) -> Result {
        guard a.count >= 1024, b.count >= 1024 else { return Result(offset: 0, confidence: 0) }
        let d = 4
        let da = decimate(a, by: d), db = decimate(b, by: d)
        let coarseLag = maxLag / d
        let r = xcorr(db, da)                    // r[k] = Σ db[t + k] · da[t]
        var best = 0, bestValue = -Float.infinity
        for k in -coarseLag...coarseLag {
            let idx = k >= 0 ? k : r.count + k
            guard idx >= 0, idx < r.count else { continue }
            if r[idx] > bestValue { bestValue = r[idx]; best = k }
        }
        var bestLag = best * d, bestCorr = -2.0
        for lag in (best * d - 2 * d)...(best * d + 2 * d) {
            let c = normalizedCorrelation(a, b, lag: lag)
            if c > bestCorr { bestCorr = c; bestLag = lag }
        }
        return Result(offset: bestLag, confidence: max(0, bestCorr))
    }

    private static func decimate(_ x: [Float], by d: Int) -> [Float] {
        let n = x.count / d
        var out = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            for i in 0..<n { var s: Float = 0; for k in 0..<d { s += p[i * d + k] }; out[i] = s / Float(d) }
        }
        return out
    }

    /// Cross-correlation by FFT (vDSP), zero-padded so that it is linear: r[k] = Σ x[t + k] · y[t], negative k at the end.
    static func xcorr(_ x: [Float], _ y: [Float]) -> [Float] {
        let need = x.count + y.count
        var log2n = 0
        while (1 << log2n) < need { log2n += 1 }
        let n = 1 << log2n, half = n / 2
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var xr = [Float](repeating: 0, count: half), xi = [Float](repeating: 0, count: half)
        var yr = [Float](repeating: 0, count: half), yi = [Float](repeating: 0, count: half)
        var padded = [Float](repeating: 0, count: n)
        func forward(_ v: [Float], _ re: inout [Float], _ im: inout [Float]) {
            for i in 0..<n { padded[i] = i < v.count ? v[i] : 0 }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { pp in
                        pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                }
            }
        }
        forward(x, &xr, &xi)
        forward(y, &yr, &yi)
        // X · conj(Y). Element 0 packs DC (real) and Nyquist (imaginary), both real numbers.
        var pr = [Float](repeating: 0, count: half), pi = [Float](repeating: 0, count: half)
        pr[0] = xr[0] * yr[0]; pi[0] = xi[0] * yi[0]
        for i in 1..<half {
            pr[i] = xr[i] * yr[i] + xi[i] * yi[i]
            pi[i] = xi[i] * yr[i] - xr[i] * yi[i]
        }
        var out = [Float](repeating: 0, count: n)
        pr.withUnsafeMutableBufferPointer { rp in
            pi.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ztoc(&sc, 1, $0, 2, vDSP_Length(half)) }
                }
            }
        }
        return out
    }

    /// Σ a[t] · b[t + lag] over the overlap, divided by both energies there.
    static func normalizedCorrelation(_ a: [Float], _ b: [Float], lag: Int) -> Double {
        let start = max(0, -lag), end = min(a.count, b.count - lag)
        guard end - start > 256 else { return 0 }
        let len = vDSP_Length(end - start)
        var dot: Float = 0, ea: Float = 0, eb: Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                let pa = ap.baseAddress! + start, pb = bp.baseAddress! + start + lag
                vDSP_dotpr(pa, 1, pb, 1, &dot, len)
                vDSP_svesq(pa, 1, &ea, len)
                vDSP_svesq(pb, 1, &eb, len)
            }
        }
        guard ea > 0, eb > 0 else { return 0 }
        return Double(dot) / (Double(ea).squareRoot() * Double(eb).squareRoot())
    }
}

// MARK: - Real-time core

/// Plays the 4-channel ring as stereo: A or B (or a 10 ms crossfade between them), each at its matched gain, with a short ramp on
/// start, stop and seek. Allocation-free, lock-free and message-free: safe inside a Core Audio IOProc.
final class ABXCore: @unchecked Sendable {
    static let maxFrames = 16_384
    static let crossfadeSeconds = 0.010
    static let rampSeconds = 0.005

    let sampleRate: Double
    let ring: RingBuffer
    let fadeFrames: Int

    // Interface → audio thread
    private let gainA = Atomic<UInt32>(Float(1).bitPattern)
    private let gainB = Atomic<UInt32>(Float(1).bitPattern)
    private let target = Atomic<Int>(ABXSlot.a.rawValue)
    /// Wanted by the interface (play / pause).
    let playing = Atomic<Bool>(false)
    /// Wanted by the producer while it repositions (seek, alignment change).
    let ducked = Atomic<Bool>(false)

    // Audio thread → interface
    /// True once the output ramp reached silence (the producer may then flush without a click).
    let silent = Atomic<Bool>(true)
    let underruns = Atomic<Int>(0)

    // Audio thread only, all allocated here
    private let table: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Int32>
    private var pos = 0
    private var level: Float = 0
    private let rampStep: Float

    init(sampleRate: Double, ringSeconds: Double = 1.5) {
        self.sampleRate = sampleRate
        ring = RingBuffer(frames: max(8192, Int(sampleRate * ringSeconds)), channels: 4)
        fadeFrames = max(1, Int((sampleRate * Self.crossfadeSeconds).rounded()))
        table = .allocate(capacity: fadeFrames + 1)
        // raised cosine: weight of B; A gets 1 − w, so the sum is constant (the two are the same music, highly correlated)
        for i in 0...fadeFrames { table[i] = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeFrames))) }
        scratch = .allocate(capacity: Self.maxFrames * 4)
        scratch.initialize(repeating: 0, count: Self.maxFrames * 4)
        rampStep = Float(1 / max(1, sampleRate * Self.rampSeconds))
    }

    deinit { table.deallocate(); scratch.deallocate() }

    func setGains(a: Double, b: Double) {
        gainA.store(Float(a).bitPattern, ordering: .releasing)
        gainB.store(Float(b).bitPattern, ordering: .releasing)
    }

    var gains: (a: Double, b: Double) {
        (Double(Float(bitPattern: gainA.load(ordering: .acquiring))), Double(Float(bitPattern: gainB.load(ordering: .acquiring))))
    }

    func select(_ s: ABXSlot) { target.store(s.rawValue, ordering: .releasing) }
    var selected: ABXSlot { ABXSlot(rawValue: target.load(ordering: .acquiring)) ?? .a }

    /// Renders `frames` interleaved stereo Float frames.
    func process(_ out: UnsafeMutablePointer<Float>, frames requested: Int) {
        let frames = min(requested, Self.maxFrames)
        let on = playing.load(ordering: .relaxed) && !ducked.load(ordering: .relaxed)
        if !on && level <= 0 {
            _ = ring.read(into: scratch, frames: 0)                 // still answers flush requests
            for i in 0..<(frames * 2) { out[i] = 0 }
            silent.store(true, ordering: .releasing)
            return
        }
        silent.store(false, ordering: .releasing)
        let got = ring.read(into: scratch, frames: frames)
        if got < frames {
            if !ring.intentionallySilent && on { _ = underruns.add(1, ordering: .relaxed) }
            for i in (got * 4)..<(frames * 4) { scratch[i] = 0 }
        }
        let ga = Float(bitPattern: gainA.load(ordering: .relaxed)) / 2_147_483_648
        let gb = Float(bitPattern: gainB.load(ordering: .relaxed)) / 2_147_483_648
        let toB = target.load(ordering: .relaxed) == ABXSlot.b.rawValue
        let n = fadeFrames, step = rampStep
        var p = pos, lv = level
        for i in 0..<frames {
            if toB { if p < n { p += 1 } } else if p > 0 { p -= 1 }
            if on { if lv < 1 { lv = min(1, lv + step) } } else if lv > 0 { lv = max(0, lv - step) }
            let w = table[p]
            let wa = (1 - w) * ga * lv, wb = w * gb * lv
            let s = i * 4
            out[i * 2] = Float(scratch[s]) * wa + Float(scratch[s + 2]) * wb
            out[i * 2 + 1] = Float(scratch[s + 1]) * wa + Float(scratch[s + 3]) * wb
        }
        pos = p; level = lv
        if lv <= 0 && !on { silent.store(true, ordering: .releasing) }
    }
}

// MARK: - Engine (producer + output)

/// Owns the producer thread and the device output of one comparison.
final class ABXEngine: @unchecked Sendable {
    let pathA: String, pathB: String
    let rate: Double
    let core: ABXCore
    /// Length of A at `rate` (B is padded or cut to it).
    let frames: Int64
    let streamA: ABXStream, streamB: ABXStream

    private let offset = Atomic<Int>(0)
    private let loopStart = Atomic<Int>(-1), loopEnd = Atomic<Int>(-1)
    private let seekRequest = Atomic<Int>(-1)
    private let repositionRequest = Atomic<Bool>(false)
    private let stopFlag = Atomic<Bool>(false)
    private var thread: Thread?
    private let exited = DispatchSemaphore(value: 0)
    private var device: OutputDevice?
    private var proc: AudioDeviceIOProcID?
    private var outBuffer: UnsafeMutablePointer<Float>?

    // Ring position → stream position, for the playhead. Producer writes, interface reads; never the audio thread.
    private let segLock = NSLock()
    private var segments: [(written: Int, frame: Int)] = []

    /// Opens both files at `rate` (decode threads only: `ABXModel` creates engines in the background).
    init(pathA: String, pathB: String, rate: Double) throws {
        self.pathA = pathA; self.pathB = pathB; self.rate = rate
        streamA = try ABXStream(path: pathA, rate: rate)
        streamB = try ABXStream(path: pathB, rate: rate)
        frames = streamA.frames
        core = ABXCore(sampleRate: rate)
    }

    deinit { stop() }

    /// The rate both files are played at: their common rate when they share one, else the higher one when the device runs it, else
    /// the device's current rate.
    static func rate(for a: StreamInfo, _ b: StreamInfo, device: OutputDevice?) -> Double {
        let high = max(a.sampleRate, b.sampleRate)
        guard let device else { return high }
        if device.canRun(at: high) { return high }
        return device.currentRate > 0 ? device.currentRate : high
    }

    var offsetFrames: Int { offset.load(ordering: .acquiring) }
    func setOffset(_ frames: Int) {
        offset.store(frames, ordering: .releasing)
        repositionRequest.store(true, ordering: .releasing)
    }

    /// Loop region in frames, nil for the whole track.
    func setLoop(_ r: Range<Int>?) {
        if let r, r.count > Int(rate * 0.5) {
            loopStart.store(max(0, r.lowerBound), ordering: .releasing); loopEnd.store(min(Int(frames), r.upperBound), ordering: .releasing)
        } else {
            loopStart.store(-1, ordering: .releasing); loopEnd.store(-1, ordering: .releasing)
        }
    }

    var loop: Range<Int>? {
        let s = loopStart.load(ordering: .acquiring), e = loopEnd.load(ordering: .acquiring)
        return s >= 0 && e > s ? s..<e : nil
    }

    func seek(toFrame f: Int) { seekRequest.store(max(0, min(f, Int(frames) - 1)), ordering: .releasing) }

    /// The stream frame being heard.
    var playhead: Int {
        let consumed = core.ring.totalConsumed
        segLock.lock(); defer { segLock.unlock() }
        guard let seg = segments.last(where: { $0.written <= consumed }) ?? segments.first else { return 0 }
        return max(0, min(Int(frames), seg.frame + (consumed - seg.written)))
    }

    // MARK: Producer

    func startProducer() {
        stopFlag.store(false, ordering: .releasing)
        let t = Thread { [self] in produce(); exited.signal() }
        t.name = "aureon.abx"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func produce() {
        let chunk = 2048
        let fade = max(1, Int(rate * 0.005))                  // 5 ms fades where the loop wraps
        let a = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * 2), b = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * 2)
        let quad = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * 4)
        defer { a.deallocate(); b.deallocate(); quad.deallocate() }
        var frame = 0
        var fadeIn = 0                                        // frames of fade-in still to apply after a wrap

        func position(at f: Int) {
            frame = f
            streamA.seek(to: Int64(f))
            let off = offset.load(ordering: .acquiring)
            streamB.seek(to: Int64(max(0, f + off)))
            segLock.lock()
            segments.append((core.ring.totalWritten, f))
            if segments.count > 16 { segments.removeFirst(segments.count - 16) }
            segLock.unlock()
        }

        /// Fades out, drops what is buffered and continues at `f`.
        func jump(to f: Int) {
            core.ducked.store(true, ordering: .releasing)
            var waited = 0
            while !core.silent.load(ordering: .acquiring) && waited < 100 { usleep(500); waited += 1 }
            core.ring.flush()
            segLock.lock(); segments.removeAll(); segLock.unlock()
            position(at: f)
            fadeIn = 0
            core.ducked.store(false, ordering: .releasing)
        }

        position(at: 0)

        while !stopFlag.load(ordering: .acquiring) {
            let sk = seekRequest.exchange(-1, ordering: .acquiringAndReleasing)
            if sk >= 0 { jump(to: sk); continue }
            if repositionRequest.exchange(false, ordering: .acquiringAndReleasing) { jump(to: playhead); continue }

            if core.ring.availableToWrite < chunk { usleep(4000); continue }

            let ls = loopStart.load(ordering: .acquiring), le = loopEnd.load(ordering: .acquiring)
            let looping = ls >= 0 && le > ls
            let end = looping ? le : Int(frames)
            if looping && (frame < ls || frame >= le) { jump(to: ls); continue }
            if frame >= end { position(at: looping ? ls : 0); fadeIn = fade; continue }
            let n = min(chunk, end - frame)

            let gotA = streamA.read(into: a, frames: n)
            if gotA < n { for i in (gotA * 2)..<(n * 2) { a[i] = 0 } }
            // B: silence while it has not started yet (offset beyond this frame), then its own audio
            let off = offset.load(ordering: .acquiring)
            let lead = max(0, min(n, -(frame + off)))
            for i in 0..<(lead * 2) { b[i] = 0 }
            let gotB = lead < n ? streamB.read(into: b + lead * 2, frames: n - lead) : 0
            if lead + gotB < n { for i in ((lead + gotB) * 2)..<(n * 2) { b[i] = 0 } }

            for i in 0..<n {
                var g: Double = 1
                if fadeIn > 0 { g = Double(fade - fadeIn) / Double(fade); fadeIn -= 1 }
                let toEnd = end - (frame + i)
                if toEnd <= fade { g = min(g, Double(toEnd - 1) / Double(fade)) }
                let q = i * 4
                if g >= 1 {
                    quad[q] = a[i * 2]; quad[q + 1] = a[i * 2 + 1]; quad[q + 2] = b[i * 2]; quad[q + 3] = b[i * 2 + 1]
                } else {
                    let s = max(0, g)
                    quad[q] = Int32(Double(a[i * 2]) * s); quad[q + 1] = Int32(Double(a[i * 2 + 1]) * s)
                    quad[q + 2] = Int32(Double(b[i * 2]) * s); quad[q + 3] = Int32(Double(b[i * 2 + 1]) * s)
                }
            }
            var written = 0
            while written < n && !stopFlag.load(ordering: .acquiring) {
                if seekRequest.load(ordering: .acquiring) >= 0 || repositionRequest.load(ordering: .acquiring) { break }
                let w = core.ring.write(quad + written * 4, frames: n - written)
                written += w
                if w == 0 { usleep(2000) }
            }
            frame += n
        }
    }

    // MARK: Output

    /// Plays through `deviceID` (nil = the system output) and starts the producer. A seek requested before this is where playback begins.
    func start(deviceID: AudioDeviceID?) throws {
        guard let d = OutputDevice(id: deviceID) else { throw AureonError.message("No output device.") }
        if abs(d.currentRate - rate) >= 0.5, d.canRun(at: rate) { _ = d.setRate(rate) }
        guard abs(d.currentRate - rate) < 0.5 else {
            throw AureonError.message("\(d.name) does not run at \(formatRate(rate)).")
        }
        device = d
        let isFloat = (d.virtualFormat()?.mFormatFlags ?? kAudioFormatFlagIsFloat) & kAudioFormatFlagIsFloat != 0
        let maxFrames = ABXCore.maxFrames
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
        buf.initialize(repeating: 0, count: maxFrames * 2)
        outBuffer = buf
        let core = self.core
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, d.id, nil) { _, _, _, outData, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outData)
            guard let first = abl.first, let out = first.mData else { return }
            let devCh = max(Int(first.mNumberChannels), 1)
            let frames = min(Int(first.mDataByteSize) / (devCh * 4), maxFrames)
            core.process(buf, frames: frames)
            if isFloat {
                let o = out.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { for ch in 0..<devCh { o[i * devCh + ch] = ch < 2 ? buf[i * 2 + ch] : 0 } }
            } else {
                let o = out.assumingMemoryBound(to: Int32.self)
                for i in 0..<frames { for ch in 0..<devCh { o[i * devCh + ch] = ch < 2 ? Int32(clamping: Int64((max(-1, min(1, buf[i * 2 + ch])) * 2_147_483_647).rounded())) : 0 } }
            }
        }
        guard status == noErr, let procID else { stop(); throw AureonError.message("Could not open \(d.name) (OSStatus \(status)).") }
        proc = procID
        let started = AudioDeviceStart(d.id, procID)
        guard started == noErr else { stop(); throw AureonError.message("Could not start \(d.name) (OSStatus \(started)).") }
        // the consumer runs first, so the producer's opening flush (a pending seek) is answered at once
        startProducer()
    }

    private func stopProducer() {
        stopFlag.store(true, ordering: .releasing)
        if thread != nil { exited.wait(); thread = nil }
    }

    func stop() {
        if let d = device, let p = proc {
            // let the ramp reach silence before the device stops, so stopping never clicks
            core.playing.store(false, ordering: .releasing)
            var waited = 0
            while !core.silent.load(ordering: .acquiring) && waited < 60 { usleep(500); waited += 1 }
            AudioDeviceStop(d.id, p); AudioDeviceDestroyIOProcID(d.id, p)
        }
        proc = nil
        stopProducer()
        outBuffer?.deallocate(); outBuffer = nil
        device?.restore(); device = nil
    }
}

// MARK: - Trials and statistics

/// One blind trial: X is A or B, hidden until the session ends.
struct ABXTrial: Equatable, Sendable {
    let x: ABXSlot
    var answer: ABXSlot?
    /// How often the listener switched between A, B and X before answering.
    var switches = 0
    var seconds: Double = 0
    var correct: Bool? { answer.map { $0 == x } }
}

enum ABXStats {
    /// One-sided p-value: the chance of at least `correct` right answers out of `trials` by guessing (binomial, p = ½).
    static func pValue(correct: Int, trials: Int) -> Double {
        guard trials > 0 else { return 1 }
        let k0 = max(0, min(correct, trials))
        // Σ_{k ≥ k0} C(n, k) / 2^n, in logs so that it stays exact enough for any n
        var total = 0.0
        for k in k0...trials { total += exp(logChoose(trials, k) - Double(trials) * log(2)) }
        return min(1, total)
    }

    static func logChoose(_ n: Int, _ k: Int) -> Double { lgamma(Double(n) + 1) - lgamma(Double(k) + 1) - lgamma(Double(n - k) + 1) }

    /// Wilson score interval for the proportion of correct answers (95 % by default).
    static func wilson(correct: Int, trials: Int, z: Double = 1.959963984540054) -> (low: Double, high: Double) {
        guard trials > 0 else { return (0, 1) }
        let n = Double(trials), p = Double(correct) / n, z2 = z * z
        let centre = (p + z2 / (2 * n)) / (1 + z2 / n)
        let half = z * ((p * (1 - p) / n + z2 / (4 * n * n)).squareRoot()) / (1 + z2 / n)
        return (max(0, centre - half), min(1, centre + half))
    }

    /// The fewest correct answers out of `trials` that reach p < `alpha`.
    static func needed(trials: Int, alpha: Double = 0.05) -> Int {
        for c in 0...max(0, trials) where pValue(correct: c, trials: trials) < alpha { return c }
        return trials + 1
    }
}

/// A run of ABX trials. X for every trial is drawn up front from `rng` (the system generator in use, a seeded one in tests) and stays
/// hidden: nothing the listener sees depends on it until the session is finished.
struct ABXSession: Sendable {
    static let trialRange = 10...20
    private(set) var trials: [ABXTrial]
    private(set) var index = 0
    let startedAt: Date

    init<R: RandomNumberGenerator>(count: Int, rng: inout R) {
        let n = min(max(count, Self.trialRange.lowerBound), Self.trialRange.upperBound)
        trials = (0..<n).map { _ in ABXTrial(x: Bool.random(using: &rng) ? .a : .b) }
        startedAt = Date()
    }

    init(count: Int) { var g = SystemRandomNumberGenerator(); self.init(count: count, rng: &g) }

    var finished: Bool { index >= trials.count }
    var total: Int { trials.count }
    /// The hidden X of the trial being listened to (for the engine only, never shown).
    var currentX: ABXSlot? { finished ? nil : trials[index].x }
    var answered: Int { trials.filter { $0.answer != nil }.count }
    var correct: Int { trials.filter { $0.correct == true }.count }
    var pValue: Double { ABXStats.pValue(correct: correct, trials: answered) }
    var interval: (low: Double, high: Double) { ABXStats.wilson(correct: correct, trials: answered) }

    mutating func noteSwitch() { if !finished { trials[index].switches += 1 } }

    /// Records "X is `s`" for the current trial and moves on.
    @discardableResult
    mutating func answer(_ s: ABXSlot, seconds: Double) -> Bool {
        guard !finished else { return false }
        trials[index].answer = s
        trials[index].seconds = seconds
        index += 1
        return trials[index - 1].correct == true
    }

    /// Plain-language verdict once finished.
    var verdict: String {
        let p = pValue
        if p < 0.01 { return "You heard a difference: this score is very unlikely by guessing (p = \(ABXSession.format(p)))." }
        if p < 0.05 { return "You probably heard a difference (p = \(ABXSession.format(p)), below the usual 0.05)." }
        return "No proof of an audible difference: guessing would score this well \(Int((p * 100).rounded())) % of the time."
    }

    static func format(_ p: Double) -> String { p < 0.001 ? "< 0.001" : String(format: "%.3f", p) }
}

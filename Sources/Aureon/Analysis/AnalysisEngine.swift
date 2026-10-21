import Foundation
import Accelerate
import Synchronization

struct MeterSnapshot: Equatable {
    var vuL: Float = -30, vuR: Float = -30          // dB relative to 0 VU
    var rmsL: Float = -120, rmsR: Float = -120      // dBFS
    var peakL: Float = -120, peakR: Float = -120    // dBFS, with hold
    var clipped = false                             // a sample reached full scale recently
}

/// Spectrum analyser, spectrogram and meters. Runs at ~60 Hz on its own thread and reads from the `AnalysisTap`.
final class AnalysisEngine: @unchecked Sendable {
    static let fftSize = 4096
    static let bands = 192
    static let columns = 640
    static let minFreq: Float = 20

    let tap: AnalysisTap
    /// dBFS of an RMS-level sine that reads 0 VU. −18 is the EBU convention, −20 the SMPTE one.
    var vuReferenceDBFS: Float = -18
    var floorDB: Float = -100

    private let lock = NSLock()
    private var bars = [Float](repeating: -120, count: AnalysisEngine.bands)
    private var meters = MeterSnapshot()
    private var pixels = [UInt8](repeating: 0, count: AnalysisEngine.columns * AnalysisEngine.bands)   // column-major ring
    private var head = 0
    private var filled = 0

    // working state (analysis thread only)
    private let N = AnalysisEngine.fftSize
    private var history: [Float]
    private var window: [Float]
    private var real: [Float], imag: [Float], mags: [Float], windowed: [Float]
    private let setup: FFTSetup
    private let log2n: vDSP_Length
    private var chunk = [Float](repeating: 0, count: 32_768 * 2)
    private var bandBins: [(lo: Int, hi: Int, center: Float)] = []
    private var bandRate = 0
    private var vuLin: (Float, Float) = (0, 0)
    private var peakHold: (Float, Float) = (0, 0), holdLeft: (Float, Float) = (0, 0)
    private var clipLeft: Float = 0
    private var lastTick = Date()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "aureon.analysis", qos: .userInitiated)

    init(tap: AnalysisTap) {
        self.tap = tap
        log2n = vDSP_Length(log2(Double(AnalysisEngine.fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        history = [Float](repeating: 0, count: AnalysisEngine.fftSize)
        window = [Float](repeating: 0, count: AnalysisEngine.fftSize)
        vDSP_hann_window(&window, vDSP_Length(AnalysisEngine.fftSize), Int32(vDSP_HANN_DENORM))
        real = [Float](repeating: 0, count: AnalysisEngine.fftSize / 2)
        imag = real; mags = real
        windowed = [Float](repeating: 0, count: AnalysisEngine.fftSize)
    }
    deinit { stop(); vDSP_destroy_fftsetup(setup) }

    // MARK: lifecycle

    /// Starts/stops the 60 Hz timer and tells the audio thread whether to copy samples at all.
    func setActive(_ on: Bool) {
        if on {
            guard timer == nil else { return }
            tap.discard(); tap.enabled.store(true, ordering: .relaxed)
            lastTick = Date()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); timer = t
        } else {
            tap.enabled.store(false, ordering: .relaxed)
            timer?.cancel(); timer = nil
        }
    }
    func stop() { setActive(false) }

    // MARK: results

    func snapshot() -> (bars: [Float], meters: MeterSnapshot) { lock.lock(); defer { lock.unlock() }; return (bars, meters) }

    /// Spectrogram as row-major bytes (0…255 = floorDB…0 dB): oldest column on the left, high frequencies on top.
    func spectrogram() -> (pixels: [UInt8], width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        let W = Self.columns, H = Self.bands
        var out = [UInt8](repeating: 0, count: W * H)
        for x in 0..<W {
            let src = (head + x) % W                       // oldest column first
            for y in 0..<H { out[(H - 1 - y) * W + x] = pixels[src * H + y] }
        }
        return (out, W, H)
    }

    // MARK: processing

    private func rebuildBands(rate: Int) {
        bandRate = rate
        let nyq = Float(rate) / 2, fmax = min(20_000, nyq * 0.98), B = Self.bands
        var out: [(Int, Int, Float)] = []
        let binHz = Float(rate) / Float(N)
        for i in 0..<B {
            let c = Self.minFreq * pow(fmax / Self.minFreq, Float(i) / Float(B - 1))
            let lo = Self.minFreq * pow(fmax / Self.minFreq, (Float(i) - 0.5) / Float(B - 1))
            let hi = Self.minFreq * pow(fmax / Self.minFreq, (Float(i) + 0.5) / Float(B - 1))
            out.append((max(1, Int((lo / binHz).rounded(.up))), min(N / 2 - 1, Int((hi / binHz).rounded(.down))), c))
        }
        bandBins = out
    }

    /// One analysis step. Called by the timer; tests call it directly.
    func tick(now: Date = Date()) {
        let dt = Float(min(0.1, max(0.001, now.timeIntervalSince(lastTick)))); lastTick = now
        let rate = max(8_000, tap.sampleRate.load(ordering: .relaxed))
        if rate != bandRate { rebuildBands(rate: rate) }

        let got = chunk.withUnsafeMutableBufferPointer { tap.read(into: $0.baseAddress!, maxFrames: 32_768) }

        // meters ---------------------------------------------------------------------------------------------
        var sumL: Float = 0, sumR: Float = 0, pkL: Float = 0, pkR: Float = 0
        if got > 0 {
            for i in 0..<got {
                let l = chunk[i * 2], r = chunk[i * 2 + 1]
                sumL += l * l; sumR += r * r; pkL = max(pkL, abs(l)); pkR = max(pkR, abs(r))
            }
        }
        let rmsL = got > 0 ? (sumL / Float(got)).squareRoot() : 0, rmsR = got > 0 ? (sumR / Float(got)).squareRoot() : 0
        let a = 1 - exp(-dt / 0.065)                                   // 1-pole: 99 % of a step in 300 ms
        vuLin.0 += (rmsL - vuLin.0) * a; vuLin.1 += (rmsR - vuLin.1) * a
        func hold(_ pk: Float, _ cur: inout Float, _ left: inout Float) {
            if pk >= cur { cur = pk; left = 1.5 }
            else if left > 0 { left -= dt }
            else { cur *= pow(10, -20 * dt / 20) }                      // fall 20 dB/s after the hold time
        }
        hold(pkL, &peakHold.0, &holdLeft.0); hold(pkR, &peakHold.1, &holdLeft.1)
        if max(pkL, pkR) >= 0.99999 { clipLeft = 2 } else if clipLeft > 0 { clipLeft -= dt }
        func db(_ x: Float) -> Float { 20 * log10(max(x, 1e-6)) }
        let ref = vuReferenceDBFS

        // spectrum ---------------------------------------------------------------------------------------------
        if got > 0 {
            let keep = N - min(got, N)
            if keep > 0 { for i in 0..<keep { history[i] = history[i + N - keep] } }
            for i in 0..<min(got, N) {
                let k = got - min(got, N) + i
                history[keep + i] = (chunk[k * 2] + chunk[k * 2 + 1]) * 0.5
            }
        }
        var newBars = [Float](repeating: 0, count: Self.bands)
        let dbNorm = 20 * log10(Float(N) / 2)
        vDSP_vmul(history, 1, window, 1, &windowed, 1, vDSP_Length(N))
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N / 2) { cp in
                var split = DSPSplitComplex(realp: &real, imagp: &imag)
                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(N / 2))
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(N / 2))
            }
        }
        mags[0] = 0
        let binHz = Float(rate) / Float(N)
        func binDB(_ k: Int) -> Float { 10 * log10(max(mags[min(max(k, 0), N / 2 - 1)], 1e-20)) - dbNorm }
        for (i, b) in bandBins.enumerated() {
            if b.hi >= b.lo { var m: Float = -200; for k in b.lo...b.hi { m = max(m, binDB(k)) }; newBars[i] = m }
            else { let pos = b.center / binHz, k = Int(pos), f = pos - Float(k); newBars[i] = binDB(k) * (1 - f) + binDB(k + 1) * f }
        }

        lock.lock()
        for i in 0..<Self.bands { bars[i] = newBars[i] >= bars[i] ? newBars[i] : max(newBars[i], bars[i] - 30 * dt) }   // instant attack, 30 dB/s release
        meters = MeterSnapshot(vuL: db(vuLin.0) - ref, vuR: db(vuLin.1) - ref, rmsL: db(rmsL), rmsR: db(rmsR),
                               peakL: db(peakHold.0), peakR: db(peakHold.1), clipped: clipLeft > 0)
        let H = Self.bands
        for y in 0..<H { pixels[head * H + y] = UInt8(max(0, min(255, (newBars[y] - floorDB) / -floorDB * 255))) }
        head = (head + 1) % Self.columns; filled = min(filled + 1, Self.columns)
        lock.unlock()
    }
}

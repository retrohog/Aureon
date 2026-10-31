import Foundation
import AureonNeuralCore

// Tests for the neural upscaler: the C++ overlap-add and breaker, the pipeline stage, and the player end to end.
// No CoreML model is needed: the inference side is replaced by small functions with known output (the CoreML backend itself is
// exercised by `upscaler.coreml` when AUREON_TEST_ENHANCER_MODEL names a converted model).

func upscalerTests() -> [(String, TestFn)] {
    let u = UpscalerTests()
    return [("upscaler.olaBypassExact", u.olaWithoutNeuralBlocksIsBitExact), ("upscaler.olaIdentity", u.olaIdentityModelReconstructsAnyOverlap),
            ("upscaler.olaNoHopRipple", u.olaGainModelHasNoHopRateRipple), ("upscaler.olaCrossfade", u.olaMixedDecisionsCrossfadeWithoutSteps),
            ("upscaler.olaLate", u.olaLateBlocksFallBackWithoutWaiting), ("upscaler.olaSlots", u.olaRunningOutOfSlotsIsHarmless),
            ("upscaler.olaNonFinite", u.olaNonFiniteOutputIsRejected), ("upscaler.olaReset", u.olaResetForgetsEverything),
            ("upscaler.olaThreads", u.olaConcurrentWorkerKeepsOrderAndExactness), ("upscaler.guard", u.guardTripsBacksOffAndRecovers),
            ("upscaler.nodeOff", u.nodeSwitchedOffIsBitExact), ("upscaler.nodeIdentity", u.nodeRunsTheModelOnEveryBlock),
            ("upscaler.nodeWaits", u.nodeWaitsForAModelThatKeepsUp), ("upscaler.nodeFallback", u.nodeFallsBackAtOnceWhenTheDeviceIsShort),
            ("upscaler.service", u.serviceFollowsTheSwitch), ("upscaler.player", u.playerEnhancesALossyStreamAndRebuildsOnSwitch),
            ("upscaler.coreml", u.coreMLModelLoadsAndRuns)]
}

/// A model stand-in: applies `fn` to every sample, optionally taking `delay` seconds per block.
final class FunctionUpscaleBackend: UpscaleBackend {
    let info: UpscaleModelInfo
    let delay: TimeInterval
    let fn: @Sendable (Float) -> Float
    private final class B { let i: UnsafeMutablePointer<Float>; let o: UnsafeMutablePointer<Float>; let n: Int
        init(_ i: UnsafeMutablePointer<Float>, _ o: UnsafeMutablePointer<Float>, _ n: Int) { self.i = i; self.o = o; self.n = n } }

    init(rate: Double = 48_000, window: Int = 2048, hop: Int = 1024, delay: TimeInterval = 0, fn: @escaping @Sendable (Float) -> Float) {
        info = UpscaleModelInfo(name: "test model", sampleRate: rate, window: window, hop: hop); self.delay = delay; self.fn = fn
    }
    func bind(input: UnsafeMutablePointer<Float>, output: UnsafeMutablePointer<Float>, channels: Int) throws -> AnyObject { B(input, output, channels * info.window) }
    func run(_ binding: AnyObject) throws {
        let b = binding as! B
        if delay > 0 { usleep(useconds_t(delay * 1e6)) }
        for k in 0..<b.n { b.o[k] = fn(b.i[k]) }
    }
}

/// Plays back a fixed array of interleaved frames.
private final class ArrayFrameSource: FrameSource {
    let info: StreamInfo
    let data: [Int32]
    private var pos = 0
    init(_ data: [Int32], rate: Double, channels: Int, transparent: Bool = false) {
        self.data = data
        info = StreamInfo(sampleRate: rate, channels: channels, sourceBits: 16, totalFrames: Int64(data.count / channels), codec: "test", transparent: transparent)
    }
    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let ch = info.channels, n = max(0, min(frames, data.count / ch - pos))
        if n > 0 { data.withUnsafeBufferPointer { buf.update(from: $0.baseAddress! + pos * ch, count: n * ch) } }
        pos += n
        return n
    }
    func seek(to frame: Int64) { pos = max(0, min(Int(frame), data.count / info.channels)) }
}

struct UpscalerTests {
    static let fs = 2_147_483_648.0

    func makeOLA(channels: Int, window: Int, hop: Int, slots: Int = 6, lookahead: Int = 4) -> OpaquePointer {
        var c = AUOlaConfig(channels: Int32(channels), window: Int32(window), hop: Int32(hop), slots: Int32(slots), lookahead: Int32(lookahead))
        return au_ola_create(&c)!
    }

    /// Drives an AUOla single-threaded: push in varying chunks, run the "worker" inline with `model` (nil = never), commit each
    /// window with `accept(k)`, pull everything. Returns the output and the counters.
    func drive(_ input: [Int32], channels: Int, window: Int, hop: Int, slots: Int = 6, lookahead: Int = 4, submit: Bool = true,
               model: ((UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Bool)?, accept: (Int) -> Bool = { _ in true }) -> ([Int32], AUOlaStats) {
        let o = makeOLA(channels: channels, window: window, hop: hop, slots: slots, lookahead: lookahead)
        defer { au_ola_destroy(o) }
        var out = [Int32](repeating: 0, count: input.count)
        var inPos = 0, outPos = 0, k = 0, step = 0
        let frames = input.count / channels
        let sizes = [1, 7, 333, 1024, 4096, 64, 2049, 5]
        while outPos < frames {
            let space = Int(au_ola_input_space(o))
            if space > 0 && inPos < frames {
                let n = min(space, sizes[step % sizes.count], frames - inPos); step += 1
                var created: Int32 = 0
                let took = input.withUnsafeBufferPointer { Int(au_ola_push(o, $0.baseAddress! + inPos * channels, Int32(n), submit ? 1 : 0, &created)) }
                inPos += took
            }
            if let model {
                while true {
                    let s = au_ola_worker_take(o); if s < 0 { break }
                    let ok = model(au_ola_slot_input(o, s)!, au_ola_slot_output(o, s)!, channels * window)
                    au_ola_worker_finish(o, s, ok ? 1 : 0, 0.001)
                }
            }
            while au_ola_poll(o) != Int32(AU_WINDOW_NONE) { _ = au_ola_commit(o, accept(k) ? 1 : 0); k += 1 }
            if inPos == frames && au_ola_poll(o) == Int32(AU_WINDOW_NONE) { au_ola_finish(o) }   // all input is in: end of stream
            let got = out.withUnsafeMutableBufferPointer { Int(au_ola_pull(o, $0.baseAddress! + outPos * channels, Int32(frames - outPos))) }
            outPos += got
        }
        var st = AUOlaStats(); au_ola_stats(o, &st)
        return (out, st)
    }

    func randomInput(frames: Int, channels: Int, seed: UInt64 = 1) -> [Int32] {
        var x = seed &* 0x9E37_79B9_7F4A_7C15
        return (0..<(frames * channels)).map { _ in x ^= x << 13; x ^= x >> 7; x ^= x << 17; return Int32(truncatingIfNeeded: x) }
    }

    func sine(frames: Int, channels: Int, freq: Double, rate: Double, amp: Double) -> [Int32] {
        (0..<(frames * channels)).map { i in Int32((amp * (Self.fs - 1) * sin(2 * .pi * freq * Double(i / channels) / rate + Double(i % channels))).rounded()) }
    }

    /// Largest |a − scale·b| in full-scale units over frames `from ..< to` (to: from the end when negative).
    func maxError(_ a: [Int32], _ b: [Int32], from: Int = 0, to: Int = 0, channels: Int, scale: Double = 1) -> Double {
        var m = 0.0
        let n = min(a.count, b.count) / channels
        let end = to > 0 ? min(to, n) : n + to
        guard end > from else { return .infinity }
        for i in (from * channels)..<(end * channels) { m = max(m, abs(Double(a[i]) - Double(b[i]) * scale) / Self.fs) }
        return m
    }

    // MARK: overlap-add

    func olaWithoutNeuralBlocksIsBitExact() {
        let x = randomInput(frames: 50_017, channels: 2)
        let (y, st) = drive(x, channels: 2, window: 1024, hop: 512, submit: false, model: nil)
        expect(y == x, "no neural block: the output is the input, bit for bit")
        expect(st.windowsNeural == 0 && st.windowsFallback == st.windowsFormed && st.windowsFormed > 90, "\(st)")
        let (y2, st2) = drive(x, channels: 2, window: 1024, hop: 512, model: { i, o, n in o.update(from: i, count: n); return true }, accept: { _ in false })
        expect(y2 == x && st2.windowsNeural == 0, "blocks refused at commit: still bit-exact")
    }

    func olaIdentityModelReconstructsAnyOverlap() {
        let x = sine(frames: 40_000, channels: 2, freq: 997, rate: 48_000, amp: 0.9)
        for (w, h) in [(1024, 512), (1024, 256), (2048, 256), (960, 480)] {
            let (y, st) = drive(x, channels: 2, window: w, hop: h, model: { i, o, n in o.update(from: i, count: n); return true })
            let e = maxError(y, x, channels: 2)
            expect(e < 1e-6, "identity model, W \(w) H \(h): windows add up to one (error \(db(e)) dB)")
            expect(st.windowsNeural == st.windowsFormed, "\(st)")
        }
    }

    func olaGainModelHasNoHopRateRipple() {
        let rate = 48_000.0, w = 2048, h = 1024
        let x = sine(frames: 96_000, channels: 1, freq: 1000, rate: rate, amp: 0.5)
        let (y, _) = drive(x, channels: 1, window: w, hop: h, model: { i, o, n in for k in 0..<n { o[k] = 0.5 * i[k] }; return true })
        // (the first and last window lengths are where the stream starts and ends: there the model fades in and out by design)
        let e = maxError(y, x, from: w, to: -w, channels: 1, scale: 0.5)
        expect(e < 1e-6, "a −6 dB model gives exactly −6 dB everywhere, block edges included (error \(db(e)) dB)")
        let side = amplitude(y, channels: 1, rate: rate, freq: 1000 + rate / Double(h), skip: w, count: 65_536)
        expect(db(side) < -110, "no sideband at the hop rate: \(db(side)) dB")
    }

    func olaMixedDecisionsCrossfadeWithoutSteps() {
        let w = 1024, h = 512
        let x = [Int32](repeating: Int32(0.5 * Self.fs), count: 30_000)
        let pattern = [true, true, false, false, true, false, true, true, true, false]
        let (y, st) = drive(x, channels: 1, window: w, hop: h, model: { _, o, n in o.update(repeating: 0, count: n); return true },
                            accept: { pattern[$0 % pattern.count] })
        var maxStep = 0.0, lo = 1.0, hi = 0.0
        for i in 1..<y.count {
            maxStep = max(maxStep, abs(Double(y[i]) - Double(y[i - 1])) / Self.fs)
            lo = min(lo, Double(y[i]) / Self.fs); hi = max(hi, Double(y[i]) / Self.fs)
        }
        expect(st.windowsNeural > 0 && st.windowsFallback > 0, "\(st)")
        expect(maxStep <= 0.5 * Double.pi / Double(w) * 1.02, "switching between model and fallback is a Hann crossfade: largest step \(maxStep)")
        expect(lo > -1e-6 && hi < 0.5 + 1e-6 && lo < 0.01, "the output stays between the two signals and reaches the model's: \(lo)…\(hi)")
    }

    func olaLateBlocksFallBackWithoutWaiting() {
        let x = randomInput(frames: 20_000, channels: 2, seed: 7)
        let t0 = Date()
        let (y, st) = drive(x, channels: 2, window: 1024, hop: 512, model: nil)
        expect(y == x, "every block late: the input plays, bit-exact")
        expect(st.jobsLate == st.jobsSubmitted && st.jobsSubmitted > 30 && st.slotsExhausted == 0, "late jobs are cancelled and their slots reused: \(st)")
        expect(Date().timeIntervalSince(t0) < 2, "nothing waited for the missing worker")

        // a block the worker is running when the producer gives up: abandoned, then freed when the worker hands it back
        let o = makeOLA(channels: 1, window: 256, hop: 128, slots: 1, lookahead: 2)
        defer { au_ola_destroy(o) }
        let z = [Int32](repeating: 1000, count: 4096)
        var created: Int32 = 0
        _ = z.withUnsafeBufferPointer { au_ola_push(o, $0.baseAddress!, 256, 1, &created) }
        expect(created == 1 && au_ola_poll(o) == Int32(AU_SLOT_PENDING))
        let s = au_ola_worker_take(o)
        expect(s == 0 && au_ola_poll(o) == Int32(AU_SLOT_RUNNING))
        expect(au_ola_commit(o, 1) == 0, "running block committed as fallback")
        _ = z.withUnsafeBufferPointer { au_ola_push(o, $0.baseAddress! + 256, 128, 1, &created) }
        expect(created == 0 && au_ola_poll(o) == Int32(AU_WINDOW_UNSUBMITTED), "the only slot is still with the worker: the next block goes without")
        au_ola_worker_finish(o, s, 1, 0.01)
        _ = au_ola_commit(o, 1)
        _ = z.withUnsafeBufferPointer { au_ola_push(o, $0.baseAddress! + 384, 128, 1, &created) }
        expect(created == 1, "the abandoned slot came back")
    }

    func olaRunningOutOfSlotsIsHarmless() {
        let x = randomInput(frames: 30_000, channels: 1, seed: 3)
        let (y, st) = drive(x, channels: 1, window: 512, hop: 256, slots: 2, lookahead: 8, model: nil)
        expect(y == x && st.slotsExhausted > 0, "more blocks in flight than slots: the extra ones play the input: \(st)")
    }

    func olaNonFiniteOutputIsRejected() {
        let x = randomInput(frames: 10_000, channels: 2, seed: 11)
        let (y, st) = drive(x, channels: 2, window: 1024, hop: 512, model: { _, o, n in o.update(repeating: .nan, count: n); return true })
        expect(y == x && st.jobsNonFinite == st.windowsFormed && st.windowsNeural == 0, "NaN from the model never reaches the output: \(st)")
        let (y2, st2) = drive(x, channels: 2, window: 1024, hop: 512, model: { _, _, _ in false })
        expect(y2 == x && st2.jobsFailed == st2.jobsSubmitted, "a failed inference plays the input: \(st2)")
    }

    func olaResetForgetsEverything() {
        let o = makeOLA(channels: 1, window: 256, hop: 128)
        defer { au_ola_destroy(o) }
        let a = [Int32](repeating: Int32(0.25 * Self.fs), count: 2000)
        var created: Int32 = 0
        _ = a.withUnsafeBufferPointer { au_ola_push(o, $0.baseAddress!, 700, 1, &created) }
        while true { let s = au_ola_worker_take(o); if s < 0 { break }; au_ola_slot_output(o, s)!.update(repeating: 0.9, count: 256); au_ola_worker_finish(o, s, 1, 0) }
        _ = au_ola_commit(o, 1); _ = au_ola_commit(o, 1)
        au_ola_reset(o)
        expect(au_ola_ready_frames(o) == 0 && au_ola_poll(o) == Int32(AU_WINDOW_NONE))
        let b = randomInput(frames: 1000, channels: 1, seed: 5)
        var out = [Int32](repeating: 0, count: 1000)
        var pushed = 0, pulled = 0
        while pulled < 1000 {
            if pushed < 1000 { pushed += b.withUnsafeBufferPointer { Int(au_ola_push(o, $0.baseAddress! + pushed, Int32(1000 - pushed), 0, &created)) } }
            while au_ola_poll(o) != Int32(AU_WINDOW_NONE) { _ = au_ola_commit(o, 1) }
            if pushed == 1000 { au_ola_finish(o) }
            pulled += out.withUnsafeMutableBufferPointer { Int(au_ola_pull(o, $0.baseAddress! + pulled, Int32(1000 - pulled))) }
        }
        expect(out == b, "after a reset nothing of the old stream leaks into the new one")
    }

    func olaConcurrentWorkerKeepsOrderAndExactness() {
        // a real second thread runs the model while the producer commits with deadlines: every block is either the model's or the input
        let o = makeOLA(channels: 2, window: 1024, hop: 512)
        defer { au_ola_destroy(o) }
        let stop = Counter()
        let worker = Thread {
            while stop.n.load(ordering: .relaxed) == 0 {
                let s = au_ola_worker_take(o)
                if s < 0 { usleep(50); continue }
                let i = au_ola_slot_input(o, s)!, out = au_ola_slot_output(o, s)!
                for k in 0..<2048 { out[k] = 0.5 * i[k] }
                if Int(s) % 3 == 0 { usleep(300) }
                au_ola_worker_finish(o, s, 1, 0.0003)
            }
            stop.n.store(2, ordering: .relaxed)
        }
        worker.start()
        let x = sine(frames: 200_000, channels: 2, freq: 440, rate: 48_000, amp: 0.8)
        var y = [Int32](repeating: 0, count: x.count)
        var inPos = 0, outPos = 0, neural = 0, total = 0
        let frames = x.count / 2
        while outPos < frames {
            let space = Int(au_ola_input_space(o))
            if space > 0 && inPos < frames {
                var c: Int32 = 0
                inPos += x.withUnsafeBufferPointer { Int(au_ola_push(o, $0.baseAddress! + inPos * 2, Int32(min(space, 777, frames - inPos)), 1, &c)) }
            }
            if au_ola_poll(o) != Int32(AU_WINDOW_NONE) {
                let deadline = Date().addingTimeInterval(0.0002)
                while au_ola_poll(o) == Int32(AU_SLOT_PENDING) || au_ola_poll(o) == Int32(AU_SLOT_RUNNING) { if Date() > deadline { break } }
                neural += Int(au_ola_commit(o, 1)); total += 1
            }
            if inPos == frames && au_ola_poll(o) == Int32(AU_WINDOW_NONE) { au_ola_finish(o) }
            outPos += y.withUnsafeMutableBufferPointer { Int(au_ola_pull(o, $0.baseAddress! + outPos * 2, Int32(frames - outPos))) }
        }
        stop.n.store(1, ordering: .relaxed)
        while stop.n.load(ordering: .relaxed) != 2 { usleep(100) }
        // each sample lies between the input and half of it, and is never anything else
        var bad = 0
        for i in 0..<y.count {
            let v = Double(y[i]), a = Double(x[i]), b = 0.5 * Double(x[i])
            if v < min(a, b) - 512 || v > max(a, b) + 512 { bad += 1 }
        }
        expect(bad == 0, "\(bad) samples outside the model/fallback envelope")
        expect(neural > 0 && neural < total, "some blocks made it, some did not: \(neural) of \(total)")
    }

    // MARK: breaker

    func guardTripsBacksOffAndRecovers() {
        var c = AUGuardConfig(hopSeconds: 0.1, tripRTF: 0.8, missSpan: 16, missLimit: 3, warmupWindows: 2, probeWindows: 5, cooldownSeconds: 1, maxCooldownSeconds: 4)
        let g = au_guard_create(&c)!
        defer { au_guard_destroy(g) }
        for _ in 0..<20 { _ = au_guard_on_window(g, 1, 1, 0.05) }
        expect(au_guard_state(g) == Int32(AU_GUARD_ACTIVE) && abs(au_guard_rtf(g) - 0.5) < 1e-9)
        for _ in 0..<2 { _ = au_guard_on_window(g, 1, 0, 0.05) }
        expect(au_guard_state(g) == Int32(AU_GUARD_ACTIVE), "two misses in 16 are tolerated")
        _ = au_guard_on_window(g, 1, 0, 0.05)
        expect(au_guard_state(g) == Int32(AU_GUARD_BYPASSED) && au_guard_should_submit(g) == 0 && au_guard_trips(g) == 1, "the third miss trips it")
        for _ in 0..<9 { _ = au_guard_on_window(g, 0, 0, 0.05) }
        expect(au_guard_state(g) == Int32(AU_GUARD_BYPASSED), "cooldown is 1 s of audio")
        _ = au_guard_on_window(g, 0, 0, 0.05)
        expect(au_guard_state(g) == Int32(AU_GUARD_PROBING) && au_guard_should_submit(g) == 1, "then it probes")
        for _ in 0..<5 { _ = au_guard_on_window(g, 1, 1, 0.05) }
        expect(au_guard_state(g) == Int32(AU_GUARD_ACTIVE), "a clean probe recovers")
        // too slow: trips after the warm-up, and the cooldown doubles for each trip in a row
        // feeds slow windows until it trips (the warm-up applies after each probe starts), then counts the bypass in windows
        func tripBySlowness() -> Int { var n = 0; while au_guard_state(g) != Int32(AU_GUARD_BYPASSED) && n < 100 { _ = au_guard_on_window(g, 1, 1, 0.09); n += 1 }; return n }
        func windowsUntilProbe() -> Int { var n = 0; while au_guard_state(g) == Int32(AU_GUARD_BYPASSED) && n < 1000 { _ = au_guard_on_window(g, 0, 0, 0.09); n += 1 }; return n }
        expect(tripBySlowness() == 1 && au_guard_trips(g) == 2, "0.9× real time trips it at once once warmed up")
        expect(windowsUntilProbe() == 10, "first cooldown after a recovery: 1 s")
        expect(tripBySlowness() == 3, "a probe gets its warm-up (2 windows) before the speed rule applies")
        expect(windowsUntilProbe() == 20, "second trip in a row: 2 s")
        _ = tripBySlowness()
        expect(windowsUntilProbe() == 40, "third: 4 s")
        _ = tripBySlowness()
        expect(windowsUntilProbe() == 40, "capped at 4 s")
        au_guard_trip(g)
        expect(au_guard_state(g) == Int32(AU_GUARD_BYPASSED), "forced trip")
    }

    // MARK: pipeline stage

    func gate(enabled: Bool) -> EnhancerGate {
        var s = EnhancerSettings()
        s.enabled = enabled
        return EnhancerGate(hardware: .current, settings: s)
    }

    func service(gate: EnhancerGate, backend: UpscaleBackend) -> NeuralUpscaler {
        let svc = NeuralUpscaler(gate: gate, status: NeuralUpscaleStatus(), loader: { _, _ in backend })
        svc.reconcile(wait: true)
        return svc
    }

    func nodeSwitchedOffIsBitExact() {
        let g = gate(enabled: true)
        let svc = service(gate: g, backend: FunctionUpscaleBackend { $0 * 0.5 })
        expect(svc.isReady && svc.status.state == .ready, "\(svc.status.state)")
        let x = randomInput(frames: 60_000, channels: 2, seed: 9)
        let raw = StreamInfo(sampleRate: 48_000, channels: 2, sourceBits: 16, totalFrames: 60_000, codec: "MP3", transparent: false)
        guard let n = svc.makeNode(upstream: ArrayFrameSource(x, rate: 48_000, channels: 2), raw: raw, deckRate: nil, gauge: nil) else { expect(false, "no node"); return }
        g.publish(EnhancerSettings())                           // switched off after the stage was built
        expect(svc.makeNode(upstream: ArrayFrameSource(x, rate: 48_000, channels: 2), raw: raw, deckRate: nil, gauge: nil) == nil, "off: no new stage is built")
        expect(readAll(n.source) == x, "switched off mid-stream: bit-exact pass-through")
        expect(svc.status.windowsNeural == 0 && svc.status.state == .off, "\(svc.status.state)")
        // and a lossless (bit-transparent) source never gets the stage
        g.publish({ var s = EnhancerSettings(); s.enabled = true; return s }())
        expect(svc.makeNode(upstream: ArrayFrameSource(x, rate: 48_000, channels: 2, transparent: true), raw: StreamInfo(sampleRate: 48_000, channels: 2, sourceBits: 16, totalFrames: 30_000, codec: "FLAC"), deckRate: nil, gauge: nil) == nil,
               "bit-perfect sources are never enhanced")
        expect(svc.makeNode(upstream: ArrayFrameSource(x, rate: 48_000, channels: 2), raw: StreamInfo(sampleRate: 48_000, channels: 2, sourceBits: 16, totalFrames: 30_000, codec: "MP3", transparent: false), deckRate: 48_000, gauge: nil) == nil,
               "DJ decks are never enhanced")
    }

    func nodeRunsTheModelOnEveryBlock() {
        let svc = service(gate: gate(enabled: true), backend: FunctionUpscaleBackend { $0 * 0.5 })
        let x = sine(frames: 96_000, channels: 2, freq: 1000, rate: 48_000, amp: 0.8)
        let raw = StreamInfo(sampleRate: 48_000, channels: 2, sourceBits: 16, totalFrames: 48_000, codec: "AAC", transparent: false)
        guard let n = svc.makeNode(upstream: ArrayFrameSource(x, rate: 48_000, channels: 2), raw: raw, deckRate: nil, gauge: nil) else { expect(false, "no node"); return }
        let y = readAll(n.source)
        expect(y.count == x.count, "every frame comes out: \(y.count) of \(x.count)")
        let e = maxError(y, x, from: 2048, to: -2048, channels: 2, scale: 0.5)
        expect(e < 1e-6, "the model's output plays (error \(db(e)) dB)")
        expect(svc.status.windowsNeural > 80 && svc.status.windowsFallback <= 1, "neural \(svc.status.windowsNeural), fallback \(svc.status.windowsFallback)")
        expect(!n.source.info.transparent && n.stages.contains { $0.hasPrefix("Smart enhancer") }, "\(n.stages)")
        // a source at another rate is resampled to the model's first
        guard let n2 = svc.makeNode(upstream: ArrayFrameSource(Array(x.prefix(44_100 * 2)), rate: 44_100, channels: 2), raw: raw, deckRate: nil, gauge: nil) else { expect(false); return }
        expect(n2.source.info.sampleRate == 48_000 && n2.stages.first?.contains("44100 → 48000") == true, "\(n2.stages)")
    }

    func nodeWaitsForAModelThatKeepsUp() {
        // 21 ms hops, 10 ms of "inference" per block: half real time. With time to spare the decode thread waits, so every block is neural.
        let svc = service(gate: gate(enabled: true), backend: FunctionUpscaleBackend(window: 2048, hop: 1024, delay: 0.010) { $0 * 0.5 })
        let x = sine(frames: 48_000 * 2, channels: 2, freq: 440, rate: 48_000, amp: 0.5)
        let raw = StreamInfo(sampleRate: 48_000, channels: 2, sourceBits: 16, totalFrames: 96_000, codec: "AAC", transparent: false)
        guard let n = svc.makeNode(upstream: ArrayFrameSource(x, rate: 48_000, channels: 2), raw: raw, deckRate: nil, gauge: nil) else { expect(false); return }
        let y = readAll(n.source)
        expect(y.count == x.count)
        expect(svc.status.windowsFallback <= 1 && svc.status.windowsNeural > 90, "neural \(svc.status.windowsNeural), fallback \(svc.status.windowsFallback)")
        expect(svc.status.realTimeFactor > 0.3 && svc.status.realTimeFactor < 0.8, "measured \(svc.status.realTimeFactor)× real time")
    }

    func nodeFallsBackAtOnceWhenTheDeviceIsShort() {
        // 3× slower than real time, and the device has only 0.3 s queued: no block is waited for, the breaker trips, the input plays.
        let slowModel = FunctionUpscaleBackend(window: 2048, hop: 1024, delay: 0.020) { $0 * 0.5 }
        let svc = NeuralUpscaler(gate: gate(enabled: true), status: NeuralUpscaleStatus(), loader: { _, _ in slowModel })
        svc.admissionRTF = 10       // let the slow model in, to exercise the run-time fallback
        svc.reconcile(wait: true)
        expect(svc.isReady)
        let ring = RingBuffer(frames: 48_000, channels: 2)
        let fill = [Int32](repeating: 0, count: 14_400 * 2)
        _ = fill.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 14_400) }
        let gauge = PlayoutGauge(); gauge.attach(ring, rate: 48_000)
        let x = sine(frames: 48_000 * 4, channels: 2, freq: 440, rate: 48_000, amp: 0.5)
        let raw = StreamInfo(sampleRate: 48_000, channels: 2, sourceBits: 16, totalFrames: 192_000, codec: "AAC", transparent: false)
        guard let n = svc.makeNode(upstream: ArrayFrameSource(x, rate: 48_000, channels: 2), raw: raw, deckRate: nil, gauge: gauge) else { expect(false); return }
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 8192 * 2); defer { buf.deallocate() }
        var y: [Int32] = [], longest = 0.0
        let t0 = Date()
        while true {
            let t = Date()
            let got = n.source.read(into: buf, frames: 8192)
            longest = max(longest, Date().timeIntervalSince(t))
            if got == 0 { break }
            y.append(contentsOf: UnsafeBufferPointer(start: buf, count: got * 2))
        }
        let total = Date().timeIntervalSince(t0)
        expect(y.count == x.count, "nothing is lost")
        expect(longest < 0.05 && total < 1.5, "the decode thread never waited for the slow model: longest read \(longest) s, total \(total) s for 4 s of audio")
        if case .bypassed = svc.status.state {} else { expect(false, "the breaker bypassed the model: \(svc.status.state)") }
        expect(Array(y.suffix(48_000 * 2)) == Array(x.suffix(48_000 * 2)), "while bypassed the input plays bit-exact")
    }

    func serviceFollowsTheSwitch() {
        let g = gate(enabled: false)
        let svc = service(gate: g, backend: FunctionUpscaleBackend { $0 })
        let raw = StreamInfo(sampleRate: 48_000, channels: 2, sourceBits: 16, totalFrames: 0, codec: "AAC", transparent: false, isLive: true)
        let g0 = svc.generation
        expect(!svc.isReady && svc.status.state == .off && !svc.wouldInsert(for: raw, deckRate: nil), "off: nothing loaded")
        var on = EnhancerSettings(); on.enabled = true
        g.publish(on); svc.reconcile(wait: true)
        expect(svc.isReady && svc.wouldInsert(for: raw, deckRate: nil) && svc.generation > g0, "on: loaded, and the player is told")
        let g1 = svc.generation
        g.publish(on); svc.reconcile(wait: true)
        expect(svc.generation == g1, "publishing the same settings does not reload the model")
        var off = on; off.enabled = false; g.publish(off); svc.reconcile(wait: true)
        expect(!svc.isReady && svc.status.state == .off && svc.generation > g1, "switching it off unloads it")
        // a model that fails to load, or is too slow when timed, is refused with a reason
        let bad = NeuralUpscaler(gate: g, status: NeuralUpscaleStatus(), loader: { _, _ in throw UpscalerError.noModelSelected })
        g.publish(on); bad.reconcile(wait: true)
        if case .bypassed(let why) = bad.status.state { expect(why.contains("No enhancer model")) } else { expect(false, "\(bad.status.state)") }
        let slow = NeuralUpscaler(gate: g, status: NeuralUpscaleStatus(), loader: { _, _ in FunctionUpscaleBackend(window: 1024, hop: 512, delay: 0.02) { $0 } })
        slow.reconcile(wait: true)
        expect(!slow.isReady && slow.status.lastError?.contains("Too slow") == true, "\(String(describing: slow.status.lastError))")
    }

    func playerEnhancesALossyStreamAndRebuildsOnSwitch() {
        guard let aac = RadioTests().aacData(seconds: 6) else { return }
        let srv = try! FakeRadio(audio: aac, mode: .icy(metaint: 8192)); defer { srv.stop() }
        // the "model" adds a known non-linearity: x + x³ turns the 440 Hz tone into one with a 1320 Hz harmonic at A³/4
        let g = gate(enabled: false)
        let svc = service(gate: g, backend: FunctionUpscaleBackend(window: 4096, hop: 2048) { $0 + $0 * $0 * $0 })
        let sink = RecordingSink(rates: [48_000], speed: 1)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let p = Player(); p.upscaler = svc
        p.setQueue([srv.url.absoluteString]); p.start(options: o)
        var end = Date().addingTimeInterval(15)
        while sink.frameCount < 48_000 && Date() < end { usleep(20_000) }
        expect(!p.status.pipeline.contains { $0.hasPrefix("Smart enhancer") }, "off: no enhancer stage \(p.status.pipeline)")
        let before = sink.samples
        let h0 = amplitude(before, channels: 2, rate: 48_000, freq: 1320, skip: 12_000, count: 24_000)
        expect(db(h0) < -70, "off: no harmonic \(db(h0)) dB")

        var on = EnhancerSettings(); on.enabled = true
        g.publish(on); svc.reconcile(wait: true)
        end = Date().addingTimeInterval(15)
        while !p.status.pipeline.contains(where: { $0.hasPrefix("Smart enhancer") }) && Date() < end { usleep(20_000) }
        expect(p.status.pipeline.contains { $0.hasPrefix("Smart enhancer") }, "switching it on rebuilt the stream with the enhancer: \(p.status.pipeline)")
        let mark = sink.frameCount
        end = Date().addingTimeInterval(15)
        while sink.frameCount < mark + 96_000 && Date() < end { usleep(20_000) }
        let after = Array(sink.samples.suffix(48_000 * 2))
        let fund = amplitude(after, channels: 2, rate: 48_000, freq: 440, skip: 4_000, count: 40_000)
        let h3 = amplitude(after, channels: 2, rate: 48_000, freq: 1320, skip: 4_000, count: 40_000)
        // the measured fundamental already contains the cubic's own share (¾A³): solve fund = A + ¾A³ for the input amplitude A
        var a = fund
        for _ in 0..<20 { a -= (a + 0.75 * a * a * a - fund) / (1 + 2.25 * a * a) }
        let expected = 0.25 * pow(a, 3)
        expect(abs(db(h3) - db(expected)) < 1.5, "the model's output reaches the device: harmonic \(db(h3)) dB, expected \(db(expected)) dB")
        expect(svc.status.windowsNeural > 20 && svc.status.state == .active, "\(svc.status.state), neural \(svc.status.windowsNeural)")
        expect(p.status.underruns == 0, "no underruns: \(p.status.underruns)")
        expect(!p.status.bitPerfect, "never reported as bit-perfect")

        // switched off mid-stream: no rebuild, the stage crossfades back to its input. What is already in the ring (up to the buffer
        // length) still plays first.
        var off = on; off.enabled = false; g.publish(off)
        let mark2 = sink.frameCount
        end = Date().addingTimeInterval(25)
        while sink.frameCount < mark2 + 10 * 48_000 && Date() < end { usleep(20_000) }
        let late = Array(sink.samples.suffix(24_000 * 2))
        let h3off = amplitude(late, channels: 2, rate: 48_000, freq: 1320, skip: 0, count: 24_000)
        expect(db(h3off) < -60, "off again: the harmonic is gone without a rebuild: \(db(h3off)) dB")
        p.send(.stop); _ = p.waitUntilFinished(timeout: 8)
    }

    func coreMLModelLoadsAndRuns() {
        // Missing or foreign models are refused cleanly.
        let dir = tempDir("upscaler")
        let junk = dir.appendingPathComponent("junk.mlpackage", isDirectory: true)
        try? FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        expect((try? CoreMLUpscaleBackend(url: junk, computeUnits: .cpuOnly)) == nil, "a folder that is not a model is refused")
        expect((try? CoreMLUpscaleBackend.load(url: nil, hardware: .current)) == nil, "no model selected")
        expect(CoreMLUpscaleBackend.computeUnits(for: .current) == (HostHardware.current.isAppleSilicon && !HostHardware.current.isTranslated ? .cpuAndNeuralEngine : .cpuOnly))
        // A converted model, when one is provided: it loads, keeps time alignment and runs faster than real time.
        guard let path = ProcessInfo.processInfo.environment["AUREON_TEST_ENHANCER_MODEL"] else { return }
        do {
            let b = try CoreMLUpscaleBackend(url: URL(fileURLWithPath: path), computeUnits: CoreMLUpscaleBackend.computeUnits(for: .current))
            let rtf = try NeuralUpscaler.measure(b)
            expect(rtf < 1, "\(b.info.name): \(rtf)× real time")
            let w = b.info.window
            let i = UnsafeMutablePointer<Float>.allocate(capacity: w), o = UnsafeMutablePointer<Float>.allocate(capacity: w)
            defer { i.deallocate(); o.deallocate() }
            for k in 0..<w { i[k] = Float(0.5 * sin(2 * Double.pi * 1000 * Double(k) / b.info.sampleRate)) }
            try b.run(try b.bind(input: i, output: o, channels: 1))
            var dot = 0.0, ii = 0.0, oo = 0.0
            for k in (w / 4)..<(3 * w / 4) { dot += Double(i[k]) * Double(o[k]); ii += Double(i[k] * i[k]); oo += Double(o[k] * o[k]) }
            expect(dot / (ii * oo).squareRoot() > 0.9, "a 1 kHz tone (inside the band the model keeps) comes out in phase: correlation \(dot / (ii * oo).squareRoot())")
        } catch { expect(false, "\(path): \(error.localizedDescription)") }
    }
}

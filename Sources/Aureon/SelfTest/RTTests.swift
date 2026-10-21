import Foundation
import Synchronization

struct RCUTests {
    final class Payload {
        static let live = Counter()
        let value: Int
        let check: Int
        init(_ v: Int) { value = v; check = ~v; _ = Payload.live.n.add(1, ordering: .relaxed) }
        deinit { _ = Payload.live.n.subtract(1, ordering: .relaxed) }
    }

    func basics() {
        let box = RCUBox<Payload>()
        expect(box.isEmpty && box.read { $0.value } == nil)
        box.publish(Payload(7))
        expect(box.read { $0.value } == 7)
        box.publish(Payload(8))
        expect(box.read { $0.value } == 8)
        box.publish(nil)
        expect(box.isEmpty)
        expect(Payload.live.n.load(ordering: .relaxed) == 0, "published objects must be released")
    }

    /// A "real-time" reader hammers the box while a writer swaps and frees objects. A use-after-free would crash or
    /// read a torn (value, check) pair.
    func readerNeverSeesFreedObjects() {
        let box = RCUBox<Payload>(Payload(0))
        let stop = Atomic<Bool>(false), bad = Counter(), reads = Counter()
        let done = DispatchSemaphore(value: 0)
        Thread {
            while !stop.load(ordering: .relaxed) {
                _ = box.read { p in if p.check != ~p.value { _ = bad.n.add(1, ordering: .relaxed) } }
                _ = reads.n.add(1, ordering: .relaxed)
            }
            done.signal()
        }.start()
        for i in 1...20_000 { box.publish(Payload(i)) }
        stop.store(true, ordering: .relaxed)
        expect(done.wait(timeout: .now() + 10) == .success)
        expect(bad.n.load(ordering: .relaxed) == 0, "torn or freed object observed")
        expect(reads.n.load(ordering: .relaxed) > 1_000, "reader barely ran")
        expect(box.leaked == 0, "\(box.leaked) objects leaked by wait timeouts")
        box.publish(nil)
        expect(Payload.live.n.load(ordering: .relaxed) == 0, "every swapped-out object must be released, \(Payload.live.n.load(ordering: .relaxed)) alive")
    }
}

struct AnalysisTests {
    func feed(_ tap: AnalysisTap, _ engine: AnalysisEngine, rate: Int, seconds: Double, step: Int = 735,
              left: @escaping (Int) -> Double, right: ((Int) -> Double)? = nil, clock: inout Date) {
        let n = Int(Double(rate) * seconds)
        var buf = [Int32](repeating: 0, count: step * 2)
        var i = 0
        while i < n {
            let m = min(step, n - i)
            for k in 0..<m {
                buf[k * 2] = Int32(max(-1, min(0.9999999, left(i + k))) * 2_147_483_647)
                buf[k * 2 + 1] = Int32(max(-1, min(0.9999999, (right ?? left)(i + k))) * 2_147_483_647)
            }
            tap.write(buf, frames: m, channels: 2)
            clock = clock.addingTimeInterval(Double(m) / Double(rate))
            engine.tick(now: clock)
            i += m
        }
    }

    func make(rate: Int = 44_100) -> (AnalysisTap, AnalysisEngine) {
        let tap = AnalysisTap(); tap.sampleRate.store(rate, ordering: .relaxed); tap.enabled.store(true, ordering: .relaxed)
        return (tap, AnalysisEngine(tap: tap))
    }

    func bandFrequency(_ i: Int, rate: Int) -> Double {
        let fmax = min(20_000.0, Double(rate) / 2 * 0.98)
        return 20 * pow(fmax / 20, Double(i) / Double(AnalysisEngine.bands - 1))
    }

    func spectrumLevelAndFrequency() {
        for (freq, amp) in [(1000.0, 0.5), (440.0, 0.25), (8000.0, 0.8)] {
            let (tap, eng) = make(); var clock = Date()
            feed(tap, eng, rate: 44_100, seconds: 0.6, left: { amp * sin(2 * .pi * freq * Double($0) / 44_100) }, clock: &clock)
            let bars = eng.snapshot().bars
            let top = bars.enumerated().max { $0.element < $1.element }!
            let f = bandFrequency(top.offset, rate: 44_100)
            expect(abs(f / freq - 1) < 0.04, "peak at \(Int(f)) Hz, expected \(Int(freq))")
            expect(abs(Double(top.element) - 20 * log10(amp)) < 0.7, "\(Int(freq)) Hz read \(top.element) dB, expected \(20 * log10(amp))")
            let far = bars[(top.offset + 60) % bars.count]
            expect(far < top.element - 60, "spectrum floor only \(top.element - far) dB below the tone")
        }
    }

    func twoTonesAreSeparated() {
        let (tap, eng) = make(rate: 48_000); var clock = Date()
        feed(tap, eng, rate: 48_000, seconds: 0.6, left: { 0.3 * sin(2 * .pi * 440 * Double($0) / 48_000) + 0.3 * sin(2 * .pi * 5000 * Double($0) / 48_000) }, clock: &clock)
        let bars = eng.snapshot().bars
        let peaks = (1..<bars.count - 1).filter { bars[$0] > bars[$0 - 1] && bars[$0] >= bars[$0 + 1] && bars[$0] > -30 }.map { bandFrequency($0, rate: 48_000) }
        expect(peaks.count == 2 && abs(peaks[0] / 440 - 1) < 0.05 && abs(peaks[1] / 5000 - 1) < 0.05, "peaks at \(peaks)")
    }

    func spectrogramShowsTheToneInTheRightRow() {
        let (tap, eng) = make(); var clock = Date()
        feed(tap, eng, rate: 44_100, seconds: 0.4, left: { 0.5 * sin(2 * .pi * 2000 * Double($0) / 44_100) }, clock: &clock)
        let sg = eng.spectrogram()
        expect(sg.width == AnalysisEngine.columns && sg.height == AnalysisEngine.bands)
        let x = sg.width - 1                                   // newest column
        var best = 0, bestV: UInt8 = 0
        for y in 0..<sg.height { let v = sg.pixels[y * sg.width + x]; if v > bestV { bestV = v; best = y } }
        let band = sg.height - 1 - best                         // row 0 is the highest frequency
        expect(abs(bandFrequency(band, rate: 44_100) / 2000 - 1) < 0.04, "brightest row is \(Int(bandFrequency(band, rate: 44_100))) Hz")
        expect(bestV > 200, "tone should be bright, got \(bestV)")
        expect(sg.pixels[0 * sg.width + 0] == 0, "oldest columns are still empty")
    }

    func vuCalibrationAndBallistics() {
        for (rmsDB, want) in [(-18.0, 0.0), (-12.0, 6.0), (-24.0, -6.0)] {
            let (tap, eng) = make(); var clock = Date()
            let peak = pow(10, (rmsDB + 3.0103) / 20)
            feed(tap, eng, rate: 44_100, seconds: 1.5, left: { peak * sin(2 * .pi * 1000 * Double($0) / 44_100) }, clock: &clock)
            let m = eng.snapshot().meters
            expect(abs(Double(m.vuL) - want) < 0.25, "RMS \(rmsDB) dBFS reads \(m.vuL) VU, expected \(want)")
            expect(abs(Double(m.rmsL) - rmsDB) < 0.3)
        }
        // step response: 99 % of final deflection after 300 ms (and clearly less after 150 ms)
        func vuAfter(_ seconds: Double) -> Float {
            let (tap, eng) = make(); var clock = Date()
            let peak = pow(10, (-18 + 3.0103) / 20)
            feed(tap, eng, rate: 44_100, seconds: seconds, step: 705, left: { peak * sin(2 * .pi * 1000 * Double($0) / 44_100) }, clock: &clock)
            return eng.snapshot().meters.vuL
        }
        let at150 = vuAfter(0.15), at300 = vuAfter(0.30)
        expect(at300 > -0.2 && at300 < 0.1, "300 ms: \(at300) VU (99% ≈ −0.09 dB)")
        expect(at150 < -0.5 && at150 > -3.5, "150 ms: \(at150) VU should still be rising")
    }

    func peakHoldAndClip() {
        let (tap, eng) = make(); var clock = Date()
        feed(tap, eng, rate: 44_100, seconds: 0.1, left: { $0 == 100 ? 0.5 : 0 }, clock: &clock)
        expect(abs(Double(eng.snapshot().meters.peakL) - -6.02) < 0.1, "peak \(eng.snapshot().meters.peakL)")
        feed(tap, eng, rate: 44_100, seconds: 1.0, left: { _ in 0 }, clock: &clock)
        expect(abs(Double(eng.snapshot().meters.peakL) - -6.02) < 0.1, "peak must hold 1.5 s")
        feed(tap, eng, rate: 44_100, seconds: 2.5, left: { _ in 0 }, clock: &clock)
        expect(eng.snapshot().meters.peakL < -30, "peak must fall after the hold: \(eng.snapshot().meters.peakL)")
        expect(!eng.snapshot().meters.clipped)
        feed(tap, eng, rate: 44_100, seconds: 0.05, left: { $0 == 5 ? 1.0 : 0 }, clock: &clock)
        expect(eng.snapshot().meters.clipped, "full-scale sample must raise the clip flag")
        feed(tap, eng, rate: 44_100, seconds: 3, left: { _ in 0 }, clock: &clock)
        expect(!eng.snapshot().meters.clipped, "clip flag clears")
    }

    func metersFallWhenAudioStops() {
        let (tap, eng) = make(); var clock = Date()
        feed(tap, eng, rate: 44_100, seconds: 1.0, left: { 0.5 * sin(2 * .pi * 1000 * Double($0) / 44_100) }, clock: &clock)
        let hot = eng.snapshot().meters.vuL
        for _ in 0..<40 { clock = clock.addingTimeInterval(0.016); eng.tick(now: clock) }     // paused: no frames arrive
        expect(eng.snapshot().meters.vuL < hot - 20, "VU needle must fall when audio stops (\(hot) → \(eng.snapshot().meters.vuL))")
    }

    func tapNeverBlocksAndIsFreeWhenDisabled() {
        let tap = AnalysisTap()
        var buf = [Int32](repeating: 1 << 20, count: 4096 * 2)
        tap.write(buf, frames: 4096, channels: 2)
        expect(tap.available == 0, "a disabled tap must not copy anything")
        tap.enabled.store(true, ordering: .relaxed)
        let t0 = Date()
        for _ in 0..<100 { tap.write(buf, frames: 4096, channels: 2) }          // 400k frames into a 131k ring, nobody reading
        expect(Date().timeIntervalSince(t0) < 0.5, "writes must never wait for the analysis side")
        expect(tap.available == tap.capacity && tap.dropped.n.load(ordering: .relaxed) > 0, "overflow drops frames instead of blocking")
        var out = [Float](repeating: 0, count: 2048)
        expect(tap.read(into: &out, maxFrames: 1024) == 1024 && out[0] > 0)
        buf[0] = 0
    }

    func monoStreamsAreMirrored() {
        let tap = AnalysisTap(); tap.enabled.store(true, ordering: .relaxed)
        let buf: [Int32] = [1 << 30, -(1 << 30), 1 << 29]
        tap.write(buf, frames: 3, channels: 1)
        var out = [Float](repeating: 0, count: 6)
        expect(tap.read(into: &out, maxFrames: 3) == 3)
        expect(out[0] == out[1] && out[2] == out[3] && abs(out[0] - 0.5) < 1e-6 && abs(out[2] + 0.5) < 1e-6)
    }

    /// The real thing: a Player delivering audio through the Renderer, with the analyser running on its own timer.
    func livePlayerFeedsTheAnalyser() {
        let dir = tempDir("an")
        let t = sineWAV(dir.appendingPathComponent("a.wav"), rate: 44_100, freq: 1000, amp: 0.5, seconds: 2.0)
        let sink = RecordingSink(speed: 1)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let p = Player()
        p.analysis.setActive(true)
        p.setQueue([t.path]); p.start(options: o)
        usleep(1_000_000)
        let snap = p.analysis.snapshot()
        let top = snap.bars.enumerated().max { $0.element < $1.element }!
        expect(abs(bandFrequency(top.offset, rate: 44_100) / 1000 - 1) < 0.04, "live peak at \(Int(bandFrequency(top.offset, rate: 44_100))) Hz")
        expect(abs(Double(top.element) - -6.02) < 0.8, "live level \(top.element) dB")
        expect(snap.meters.vuL > -6, "VU should be moving: \(snap.meters.vuL)")
        _ = p.waitUntilFinished(timeout: 10)
        p.analysis.setActive(false)
        expect(!p.analysisTap.enabled.load(ordering: .relaxed))
    }
}

import Foundation

struct DJMixerTests {
    let dir = tempDir("djmix")

    private func tone(_ name: String, freq: Double, seconds: Double = 6, amp: Double = 0.4) -> URL {
        sineWAV(dir.appendingPathComponent(name), rate: 48_000, bits: 24, freq: freq, amp: amp, seconds: seconds)
    }

    private func ints(_ f: [Float]) -> [Int32] { f.map { Int32(clamping: Int64(max(-1, min(1, $0)) * 2_147_483_647)) } }

    /// A deck player that feeds a mixer deck.
    private func feed(_ deck: DJMixerCore.Deck, _ file: URL) -> Player {
        var o = PlayerOptions(); o.sinkFactory = { _ in DeckSink(deck: deck, rate: 48_000) }; o.bufferSeconds = 0.4; o.rateSwitch = false
        let p = Player(); var s = PlaybackSettings(); s.deckRate = 48_000; p.settings = s
        p.setQueue([file.path]); p.start(options: o)
        return p
    }

    private func waitBuffered(_ p: Player) { let end = Date().addingTimeInterval(5); while p.status.bufferedSeconds < 0.2 && Date() < end { usleep(5_000) } }

    private func run(_ core: DJMixerCore, seconds: Double, cue: Bool = false) -> PullOutput {
        let out = PullOutput(core: core, speed: 8, keepCue: cue)
        try! out.start()
        let end = Date().addingTimeInterval(20)
        while out.frames < Int(seconds * core.sampleRate) && Date() < end { usleep(5_000) }
        out.stop()
        return out
    }

    func crossfaderGainsSelectTheDecks() {
        let core = DJMixerCore(sampleRate: 48_000)
        let pa = feed(core.a, tone("a.wav", freq: 400)), pb = feed(core.b, tone("b.wav", freq: 1500))
        waitBuffered(pa); waitBuffered(pb)
        core.a.gain.value = 1; core.b.gain.value = 0
        let out = run(core, seconds: 1.5)
        let m = ints(out.master)
        let a = amplitude(m, channels: 2, rate: 48_000, freq: 400, skip: 24_000, count: 40_000), b = amplitude(m, channels: 2, rate: 48_000, freq: 1500, skip: 24_000, count: 40_000)
        expect(abs(a - 0.4) < 0.02 && b < 0.002, "only deck A is audible with the crossfader on A: \(a), \(b)")
        core.a.gain.value = 0.5; core.b.gain.value = 0.5
        let out2 = run(core, seconds: 1.5)
        let m2 = ints(out2.master)
        let a2 = amplitude(m2, channels: 2, rate: 48_000, freq: 400, skip: 24_000, count: 40_000), b2 = amplitude(m2, channels: 2, rate: 48_000, freq: 1500, skip: 24_000, count: 40_000)
        expect(abs(a2 - 0.2) < 0.02 && abs(b2 - 0.2) < 0.02, "half and half: \(a2), \(b2)")
        pa.send(.stop); pb.send(.stop); _ = pa.waitUntilFinished(timeout: 8); _ = pb.waitUntilFinished(timeout: 8)
    }

    func masterEqAndTrim() {
        let core = DJMixerCore(sampleRate: 48_000)
        let p = feed(core.a, tone("m.wav", freq: 60, seconds: 8, amp: 0.2))
        waitBuffered(p); core.a.gain.value = 1
        let flat = ints(run(core, seconds: 1.2).master)
        let ref = amplitude(flat, channels: 2, rate: 48_000, freq: 60, skip: 24_000, count: 30_000)
        core.masterLow.value = -12
        let cut = ints(run(core, seconds: 1.2).master)
        let c = amplitude(cut, channels: 2, rate: 48_000, freq: 60, skip: 24_000, count: 30_000)
        expect(db(c / ref) < -9 && db(c / ref) > -14, "master low shelf −12 dB cuts a 60 Hz tone: \(db(c / ref)) dB")
        core.masterLow.value = 0; core.trim.value = 0.5
        let half = ints(run(core, seconds: 1.2).master)
        let h = amplitude(half, channels: 2, rate: 48_000, freq: 60, skip: 24_000, count: 30_000)
        expect(abs(h / ref - 0.5) < 0.03, "trim halves the level: \(h / ref)")
        p.send(.stop); _ = p.waitUntilFinished(timeout: 8)
    }

    func limiterHoldsTheCeiling() {
        let core = DJMixerCore(sampleRate: 48_000)
        let pa = feed(core.a, tone("la.wav", freq: 300, seconds: 8, amp: 0.9)), pb = feed(core.b, tone("lb.wav", freq: 450, seconds: 8, amp: 0.9))
        waitBuffered(pa); waitBuffered(pb)
        core.a.gain.value = 1; core.b.gain.value = 1
        let hot = run(core, seconds: 1.5).master
        let peak = hot.dropFirst(2000).map { abs($0) }.max() ?? 0
        expect(peak <= 0.9661, "two hot decks never pass −0.3 dBFS: peak \(peak)")
        expect(core.limiterReduction.value > 3, "and the meter shows the reduction: \(core.limiterReduction.value) dB")
        core.limiterOn.value = 0
        let raw = run(core, seconds: 1.0).master
        expect((raw.dropFirst(2000).map { abs($0) }.max() ?? 0) > 1.0, "with the limiter off the sum is not touched")
        pa.send(.stop); pb.send(.stop); _ = pa.waitUntilFinished(timeout: 8); _ = pb.waitUntilFinished(timeout: 8)
    }

    func cueBusCarriesOnlyTheCuedDeck() {
        let core = DJMixerCore(sampleRate: 48_000)
        let pa = feed(core.a, tone("ca.wav", freq: 400)), pb = feed(core.b, tone("cb.wav", freq: 1500))
        waitBuffered(pa); waitBuffered(pb)
        core.a.gain.value = 1; core.b.gain.value = 0          // B is silent on the master…
        core.b.cue.value = 1; core.cueMix.value = 0           // …but cued
        let out = run(core, seconds: 1.5, cue: true)
        let cue = ints(out.cue), master = ints(out.master)
        let cb = amplitude(cue, channels: 2, rate: 48_000, freq: 1500, skip: 24_000, count: 40_000), ca = amplitude(cue, channels: 2, rate: 48_000, freq: 400, skip: 24_000, count: 40_000)
        let mb = amplitude(master, channels: 2, rate: 48_000, freq: 1500, skip: 24_000, count: 40_000)
        expect(cb > 0.35 && ca < 0.002 && mb < 0.002, "headphones hear deck B before the fader; the room does not: cue B \(cb), cue A \(ca), master B \(mb)")
        core.cueMix.value = 1
        let mixed = ints(run(core, seconds: 1.5, cue: true).cue)
        let ma = amplitude(mixed, channels: 2, rate: 48_000, freq: 400, skip: 24_000, count: 40_000)
        expect(ma > 0.35, "cue/master mix at 100 % is the master: \(ma)")
        pa.send(.stop); pb.send(.stop); _ = pa.waitUntilFinished(timeout: 8); _ = pb.waitUntilFinished(timeout: 8)
    }

    func cueResamplerFollowsAnotherClock() {
        // The producer runs at 48 000 Hz, the consumer's clock is 0.1 % fast and 44 100 Hz: the buffer must neither run dry nor grow.
        let ring = FloatRing(frames: 1 << 16)
        let rs = CueResampler(ring: ring, srcRate: 48_000, dstRate: 44_100 * 1.001, targetFill: 2_880)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 1024 * 2); defer { out.deallocate() }
        let src = UnsafeMutablePointer<Float>.allocate(capacity: 1024 * 2); defer { src.deallocate() }
        var phase = 0.0, produced = 0.0, consumed = 0.0
        var seen: [Float] = []
        for _ in 0..<600 {
            // 512 output frames take 512 / (44100 · 1.001) s; the producer delivers that much time at 48 kHz
            let secs = 512 / (44_100 * 1.001)
            produced += secs * 48_000
            let n = Int(produced); produced -= Double(n)
            var left = n
            while left > 0 { let k = min(left, 1024); for i in 0..<k { let v = Float(0.5 * sin(phase)); phase += 2 * .pi * 440 / 48_000; src[i * 2] = v; src[i * 2 + 1] = v }; ring.write(src, frames: k); left -= k }
            rs.render(into: out, frames: 512); consumed += 512
            seen.append(Float(ring.available))
        }
        expect(rs.underruns == 0, "no underruns over 6 s of drift: \(rs.underruns)")
        expect((seen.last ?? 0) < 8_000 && (seen.last ?? 0) > 500, "fill stays near its target: \(seen.last ?? 0)")
        expect(abs(rs.ratio - 48_000 / (44_100 * 1.001)) < 0.01, "ratio tracks the clock ratio: \(rs.ratio)")
        var peak: Float = 0; for i in 0..<1024 { peak = max(peak, abs(out[i])) }
        expect(peak > 0.3 && peak < 0.55, "and the tone comes through at the right level: \(peak)")
    }

    func recorderWritesAReadableWav() {
        let core = DJMixerCore(sampleRate: 48_000)
        let p = feed(core.a, tone("r.wav", freq: 800, seconds: 6, amp: 0.3))
        waitBuffered(p); core.a.gain.value = 1
        let url = dir.appendingPathComponent("rec.wav")
        let tap = RecorderTap(url: url, sampleRate: 48_000)!
        tap.start(); core.recorder.publish(tap)
        let out = run(core, seconds: 1.5)
        core.recorder.publish(nil)
        tap.stop()
        let f = try? LosslessFile(path: url.path)
        expect(f != nil, "the recording opens as an audio file")
        let frames = f.map { Int($0.info.duration * 48_000 + 0.5) } ?? 0
        expect(abs(frames - out.frames) < 1_100, "length matches what was mixed: \(frames) vs \(out.frames)")
        if let f {
            let got = readAll(f)
            let a = amplitude(got, channels: 2, rate: 48_000, freq: 800, skip: 24_000, count: 30_000)
            expect(abs(a - 0.3) < 0.02, "and holds the mix: \(a)")
        }
        expect(tap.dropped == 0, "nothing dropped: \(tap.dropped)")
        p.send(.stop); _ = p.waitUntilFinished(timeout: 8)
    }
}

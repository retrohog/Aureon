import Foundation

struct DJTests {
    let dir = tempDir("dj")

    private func tone(_ name: String, rate: Int = 44_100, freq: Double = 1000, seconds: Double = 3, amp: Double = 0.5) -> URL {
        sineWAV(dir.appendingPathComponent(name), rate: rate, bits: 24, freq: freq, amp: amp, seconds: seconds)
    }

    private func readAllFrames(_ s: FrameSource, limit: Int = .max) -> [Int32] {
        let ch = s.info.channels, buf = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * ch); defer { buf.deallocate() }
        var out: [Int32] = []
        while out.count / ch < limit {
            let n = s.read(into: buf, frames: 4096)
            if n == 0 { break }
            out.append(contentsOf: UnsafeBufferPointer(start: buf, count: n * ch))
        }
        return out
    }

    // MARK: varispeed

    func varispeedAtOneIsTransparent() {
        let f = tone("v1.wav", freq: 440, seconds: 2)
        let plain = readAll(try! LosslessFile(path: f.path))
        let v = VarispeedSource(try! LosslessFile(path: f.path), control: VarispeedControl())
        let got = readAllFrames(v)
        expect(got == plain, "ratio 1.0 must hand the samples through unchanged (\(got.count) vs \(plain.count))")
    }

    func varispeedChangesPitchAndLength() {
        let f = tone("v2.wav", freq: 1000, seconds: 3)
        for ratio in [1.05, 0.9, 1.16] {
            let c = VarispeedControl(); c.ratio = ratio
            let v = VarispeedSource(try! LosslessFile(path: f.path), control: c)
            let out = readAllFrames(v)
            let frames = out.count / 2
            expect(abs(Double(frames) - 3 * 44_100 / ratio) < 8, "length scales by 1/ratio: \(frames) frames at \(ratio)")
            let on = amplitude(out, channels: 2, rate: 44_100, freq: 1000 * ratio, skip: 4000, count: 40_000)
            let off = amplitude(out, channels: 2, rate: 44_100, freq: 1000, skip: 4000, count: 40_000)
            expect(on > 0.45 && on > 8 * off, "the tone moves to \(1000 * ratio) Hz: \(on) vs \(off) at 1 kHz")
            expect(abs(c.sourceFrame - Double(3 * 44_100)) < 4, "source position reaches the end: \(c.sourceFrame)")
        }
    }

    func varispeedLoopsAndBends() {
        let f = tone("lp.wav", freq: 441, seconds: 4)   // exactly 100 frames per period, so an 8 000-frame loop splices in phase
        let c = VarispeedControl()
        let v = VarispeedSource(try! LosslessFile(path: f.path), control: c)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 2 * 1000); defer { buf.deallocate() }
        for _ in 0..<10 { _ = v.read(into: buf, frames: 1000) }
        c.setLoop(from: 12_000, to: 20_000, on: true)
        for _ in 0..<30 { _ = v.read(into: buf, frames: 1000) }
        expect(c.loopOn && c.sourceFrame >= 12_000 && c.sourceFrame < 20_000, "30 000 frames later the position is still inside the loop: \(c.sourceFrame)")
        expect(c.wraps >= 3, "and it has wrapped several times: \(c.wraps)")
                var worst = 0.0, prev = Double(buf[0])
        for _ in 0..<20 { let n = v.read(into: buf, frames: 1000); for i in 0..<n { worst = max(worst, abs(Double(buf[i * 2]) - prev) / 2_147_483_648); prev = Double(buf[i * 2]) } }
        expect(worst < 0.06, "the splice is as smooth as the tone itself: \(worst)")
        c.clearLoop()
        for _ in 0..<10 { _ = v.read(into: buf, frames: 1000) }
        expect(c.sourceFrame > 20_000, "leaving the loop carries on past it: \(c.sourceFrame)")
        v.seek(to: 0); c.bend = 0.1
        for _ in 0..<10 { _ = v.read(into: buf, frames: 1000) }
        expect(abs(c.sourceFrame - 11_000) < 1e-6, "a +10 % bend consumes 10 % more source: \(c.sourceFrame)")
        c.bend = 9; expect(c.bend == 0.5, "bend is limited")
    }

    func varispeedLiveChangeAndSeek() {
        let f = tone("v3.wav", freq: 500, seconds: 4)
        let c = VarispeedControl()
        let v = VarispeedSource(try! LosslessFile(path: f.path), control: c)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 2 * 1000); defer { buf.deallocate() }
        for _ in 0..<10 { _ = v.read(into: buf, frames: 1000) }
        expect(abs(c.sourceFrame - 10_000) < 1e-6, "ratio 1: 10 000 frames read, 10 000 consumed")
        c.ratio = 1.5
        for _ in 0..<10 { _ = v.read(into: buf, frames: 1000) }
        expect(abs(c.sourceFrame - 25_000) < 1e-6, "ratio 1.5 takes effect immediately: \(c.sourceFrame)")
        v.seek(to: 100_000)
        expect(c.sourceFrame == 100_000, "seek addresses the source timeline")
        c.ratio = 1
        let n = v.read(into: buf, frames: 1000)
        let plain = readAll(try! LosslessFile(path: f.path))
        expect(n == 1000 && Array(UnsafeBufferPointer(start: buf, count: 2000)) == Array(plain[200_000..<202_000]), "after the seek the samples are the file's own")
        c.ratio = 9; expect(c.ratio == 2); c.ratio = -1; expect(c.ratio == 0.5); c.ratio = .nan; expect(c.ratio == 1)
        // reading past the end terminates
        v.seek(to: Int64(4 * 44_100 - 10))
        var total = 0
        for _ in 0..<5 { total += v.read(into: buf, frames: 1000) }
        expect(total <= 12, "the end of the source ends the stream (\(total) frames)")
    }

    // MARK: through the Player

    private func deckPlayer(_ file: URL, rate: Double = 48_000, paused: Bool = false, gain: DeckGain? = nil, control: VarispeedControl? = nil, rt: RTSettings = RTSettings(), speed: Double = 0) -> (Player, RecordingSink) {
        let sink = RecordingSink(speed: speed)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.startPaused = paused; o.bufferSeconds = 0.4; o.rateSwitch = false
        let p = Player(); p.deckGain = gain; p.varispeed = control
        var s = PlaybackSettings(); s.deckRate = rate; s.rt = rt; p.settings = s
        p.setQueue([file.path]); p.start(options: o)
        return (p, sink)
    }

    func decksResampleToTheSharedRate() {
        let f = tone("d1.wav", rate: 44_100, freq: 1000, seconds: 2)
        let (p, sink) = deckPlayer(f, rate: 48_000)
        expect(p.waitUntilFinished(timeout: 20))
        expect(sink.configured.first?.sampleRate == 48_000, "every deck stream is delivered at the shared rate: \(String(describing: sink.configured.first?.sampleRate))")
        let a = amplitude(sink.samples, channels: 2, rate: 48_000, freq: 1000, skip: 6000, count: 40_000)
        expect(abs(a - 0.5) < 0.02, "and the tone survives the conversion: \(a)")
        expect(abs(Double(sink.frameCount) - 2 * 48_000) < 400, "duration is preserved: \(sink.frameCount)")
        // a file already at the shared rate is not resampled
        let g = tone("d2.wav", rate: 48_000, freq: 1000, seconds: 1)
        let (q, s2) = deckPlayer(g, rate: 48_000)
        expect(q.waitUntilFinished(timeout: 20) && !q.status.pipeline.contains { $0.hasPrefix("Resample") }, "\(q.status.pipeline)")
        expect(readAll(try! LosslessFile(path: g.path)) == s2.samples, "…and passes through bit-identically")
    }

    func startingPausedPlaysNothingUntilToldTo() {
        let f = tone("p1.wav", rate: 48_000, freq: 600, seconds: 3)
        let (p, sink) = deckPlayer(f, paused: true, speed: 1)
        let end = Date().addingTimeInterval(5)
        while p.status.state == .idle && Date() < end { usleep(10_000) }
        usleep(400_000)
        expect(p.status.state == .paused && sink.frameCount == 0, "prepared and silent: state \(p.status.state), \(sink.frameCount) frames")
        p.send(.setPaused(false))
        let end2 = Date().addingTimeInterval(5)
        while sink.frameCount < 24_000 && Date() < end2 { usleep(10_000) }
        expect(p.status.state == .playing && sink.frameCount >= 24_000, "plays once released")
        p.send(.stop); _ = p.waitUntilFinished(timeout: 8)
    }

    func deckGainScalesSmoothly() {
        let f = tone("g1.wav", rate: 48_000, freq: 300, seconds: 6, amp: 0.5)
        let gain = DeckGain()
        let (p, sink) = deckPlayer(f, gain: gain, speed: 1)
        let wait = { (n: Int) in let end = Date().addingTimeInterval(10); while sink.frameCount < n && Date() < end { usleep(5_000) } }
        wait(48_000)
        let at = sink.frameCount
        gain.value = 0.25
        wait(at + 60_000)
        gain.value = 0
        wait(at + 120_000)
        p.send(.stop); _ = p.waitUntilFinished(timeout: 8)
        let s = sink.samples
        let full = amplitude(s, channels: 2, rate: 48_000, freq: 300, skip: 10_000, count: 30_000)
        let quarter = amplitude(s, channels: 2, rate: 48_000, freq: 300, skip: at + 12_000, count: 30_000)
        let silent = amplitude(s, channels: 2, rate: 48_000, freq: 300, skip: at + 90_000, count: 20_000)
        expect(abs(full - 0.5) < 0.02 && abs(quarter - 0.125) < 0.01 && silent < 0.002, "levels \(full) → \(quarter) → \(silent)")
        // no click: the largest step between neighbouring samples never exceeds what the tone itself can do
        let ch = 2, maxStep = 2 * Double.pi * 300 / 48_000 * 0.5 * 2_147_483_648 * 1.3
        var worst = 0.0
        for i in stride(from: ch, to: min(s.count, (at + 130_000) * ch), by: ch) { worst = max(worst, abs(Double(s[i]) - Double(s[i - ch]))) }
        expect(worst < maxStep, "gain changes are ramped, not stepped: worst step \(worst / 2_147_483_648) vs \(maxStep / 2_147_483_648)")
    }

    func pitchControlThroughThePlayer() {
        let f = tone("pc.wav", rate: 48_000, freq: 1000, seconds: 3)
        let c = VarispeedControl(); c.ratio = 1.08
        let (p, sink) = deckPlayer(f, control: c)
        expect(p.waitUntilFinished(timeout: 20))
        expect(abs(Double(sink.frameCount) - 3 * 48_000 / 1.08) < 600, "plays 8 % faster: \(sink.frameCount) frames")
        let on = amplitude(sink.samples, channels: 2, rate: 48_000, freq: 1080, skip: 8000, count: 40_000)
        expect(on > 0.45, "and 8 % higher: \(on)")
        expect(p.status.pipeline.contains("Pitch control"))
    }

    func deckEqCutsAndBoostsBands() {
        // low band killed: a 60 Hz tone disappears, a 5 kHz tone is untouched
        let low = tone("e1.wav", rate: 48_000, freq: 60, seconds: 3), high = tone("e2.wav", rate: 48_000, freq: 5000, seconds: 3)
        var rt = RTSettings(); let prof = DJMath.eqProfile(low: DJMath.eqRange.lowerBound, mid: 0, high: 0)!
        rt.headphoneEQ = HeadphoneEQSettings(enabled: true, profile: prof)
        let (p1, s1) = deckPlayer(low, rt: rt); expect(p1.waitUntilFinished(timeout: 20))
        let (p2, s2) = deckPlayer(high, rt: rt); expect(p2.waitUntilFinished(timeout: 20))
        let cut = amplitude(s1.samples, channels: 2, rate: 48_000, freq: 60, skip: 60_000, count: 48_000)
        let kept = amplitude(s2.samples, channels: 2, rate: 48_000, freq: 5000, skip: 60_000, count: 48_000)
        expect(db(cut / 0.5) < -20, "the low kill removes 60 Hz: \(db(cut / 0.5)) dB")
        expect(abs(db(kept / 0.5)) < 1.0, "…and leaves 5 kHz alone: \(db(kept / 0.5)) dB")
    }

    func twoDecksPlayAtTheSameTime() {
        let a = tone("t1.wav", rate: 48_000, freq: 400, seconds: 3, amp: 0.3), b = tone("t2.wav", rate: 48_000, freq: 900, seconds: 3, amp: 0.3)
        let (pa, sa) = deckPlayer(a, speed: 1), (pb, sb) = deckPlayer(b, speed: 1)
        let end = Date().addingTimeInterval(10)
        while (sa.frameCount < 72_000 || sb.frameCount < 72_000) && Date() < end { usleep(10_000) }
        expect(pa.status.state == .playing && pb.status.state == .playing, "both decks run independently")
        let x = amplitude(sa.samples, channels: 2, rate: 48_000, freq: 400, skip: 12_000, count: 40_000), y = amplitude(sb.samples, channels: 2, rate: 48_000, freq: 900, skip: 12_000, count: 40_000)
        expect(abs(x - 0.3) < 0.02 && abs(y - 0.3) < 0.02, "each deck delivers only its own track: \(x), \(y)")
        pa.send(.stop); pb.send(.stop); _ = pa.waitUntilFinished(timeout: 8); _ = pb.waitUntilFinished(timeout: 8)
    }

    // MARK: mixing maths

    func crossfaderCurves() {
        let s = CrossfaderCurve.smooth, l = CrossfaderCurve.linear, c = CrossfaderCurve.sharp
        for curve in CrossfaderCurve.allCases {
            let left = curve.gains(-1), right = curve.gains(1)
            expect(abs(left.a - 1) < 1e-9 && abs(left.b) < 1e-9 && abs(right.a) < 1e-9 && abs(right.b - 1) < 1e-9, "\(curve): the ends are one deck")
            var prevA = 2.0, prevB = -1.0
            for i in 0...100 { let g = curve.gains(-1 + 0.02 * Double(i)); expect(g.a <= prevA + 1e-12 && g.b >= prevB - 1e-12, "\(curve): monotonic"); prevA = g.a; prevB = g.b }
            expect(curve.gains(5).b == 1 && curve.gains(-5).a == 1 && curve.gains(.nan).a >= 0, "out-of-range positions are clamped")
        }
        for i in 0...50 { let g = s.gains(-1 + 0.04 * Double(i)); expect(abs(g.a * g.a + g.b * g.b - 1) < 1e-9, "smooth is equal power") }
        expect(abs(l.gains(0).a - 1) < 1e-9 && abs(l.gains(0).b - 1) < 1e-9 && abs(l.gains(0.5).a - 0.5) < 1e-9, "blend keeps both decks full in the middle")
        expect(c.gains(0.5).a == 1 && c.gains(0.5).b == 1 && abs(c.gains(0.95).a - 0.5) < 1e-9 && c.gains(1).a == 0, "cut stays open almost to the end")
        expect(DJMath.channelGain(1) == 1 && DJMath.channelGain(0) == 0 && abs(DJMath.channelGain(0.5) - 0.25) < 1e-12 && DJMath.channelGain(2) == 1)
    }

    func eqProfileAndSync() {
        expect(DJMath.eqProfile(low: 0, mid: 0, high: 0) == nil, "flat EQ needs no processor")
        let p = DJMath.eqProfile(low: -26, mid: 3, high: 6)!
        expect(p.filters.map(\.kind) == [.lowShelf, .peak, .highShelf] && p.filters[0].gainDB == DJMath.killDB && p.filters[1].gainDB == 3 && p.filters[2].gainDB == 6)
        expect(p.responseDB(atHz: 40, sampleRate: 48_000, includePreamp: false) < -25, "the low kill is deep: \(p.responseDB(atHz: 40, sampleRate: 48_000, includePreamp: false)) dB at 40 Hz")
        expect(abs(p.responseDB(atHz: 12_000, sampleRate: 48_000, includePreamp: false) - 6) < 1, "the high shelf boosts the top")
        expect(DJMath.eqGainDB(-25.6) == DJMath.killDB && DJMath.eqGainDB(-10) == -10 && DJMath.eqGainDB(99) == 6)
        expect(abs(DJMath.syncPitch(bpm: 120, target: 126)! - 0.05) < 1e-9)
        expect(abs(DJMath.syncPitch(bpm: 128, target: 64)!) < 1e-9, "half time is the same tempo")
        expect(abs(DJMath.syncPitch(bpm: 70, target: 140)!) < 1e-9, "double time too")
        expect(DJMath.syncPitch(bpm: 100, target: 140) == nil && DJMath.syncPitch(bpm: 0, target: 120) == nil, "out of range: refuse")
        expect(abs(DJMath.effectiveBPM(125, pitch: 0.04)! - 130) < 1e-9 && DJMath.effectiveBPM(nil, pitch: 0.1) == nil)
    }

    // MARK: analysis

    /// A four-on-the-floor pattern: a decaying 55 Hz kick on every beat and a short noise hat on the off-beats.
    private func beatWAV(_ name: String, bpm: Double, seconds: Double, rate: Int = 44_100) -> URL {
        let frames = Int(Double(rate) * seconds), beat = 60 / bpm * Double(rate)
        var rng = SystemRandomNumberGenerator()
        let full = Double((1 << 23) - 1)
        return writeWAV(dir.appendingPathComponent(name), rate: rate, bits: 24, frames: frames) { f, _ in
            let k = Double(f).truncatingRemainder(dividingBy: beat), h = (Double(f) + beat / 2).truncatingRemainder(dividingBy: beat)
            var v = 0.0
            if k < 0.12 * Double(rate) { v += 0.8 * exp(-k / (0.04 * Double(rate))) * sin(2 * .pi * 55 * k / Double(rate)) }
            if h < 0.01 * Double(rate) { v += 0.25 * Double.random(in: -1...1, using: &rng) * (1 - h / (0.01 * Double(rate))) }
            return Int(v * full)
        }
    }

    func tempoDetection() {
        for bpm in [90.0, 124, 128, 140] {
            let f = beatWAV("beat\(Int(bpm)).wav", bpm: bpm, seconds: 24)
            guard let a = DJAnalysis.analyze(path: f.path) else { expect(false, "analysis failed at \(bpm)"); continue }
            expect(a.bpm != nil && abs(a.bpm! - bpm) < 1.0, "\(bpm) BPM detected as \(String(describing: a.bpm))")
            expect(a.confidence > 0.15, "\(bpm): a clear beat is confident: \(a.confidence)")
        }
        // noise has no tempo to speak of
        var rng = SystemRandomNumberGenerator()
        let noise = writeWAV(dir.appendingPathComponent("noise.wav"), rate: 44_100, bits: 16, frames: 44_100 * 20) { _, _ in Int.random(in: -8000...8000, using: &rng) }
        let n = DJAnalysis.analyze(path: noise.path)
        expect(n == nil || n!.bpm == nil || n!.confidence < 0.35, "noise is not a clear tempo: \(String(describing: n?.confidence))")
        // too short to judge
        let short = beatWAV("short.wav", bpm: 120, seconds: 3)
        expect(DJAnalysis.analyze(path: short.path)?.bpm == nil, "three seconds is not enough for a tempo")
        expect(DJAnalysis.analyze(path: "/nonexistent.flac") == nil)
    }

    func waveformOverview() {
        let rate = 44_100, full = Double((1 << 15) - 1)
        let f = writeWAV(dir.appendingPathComponent("wave.wav"), rate: rate, bits: 16, frames: rate * 10) { fr, c in
            let t = Double(fr) / Double(rate)
            return Int((t < 5 ? 0.1 : 0.8) * full * sin(2 * .pi * 200 * t))
        }
        let a = DJAnalysis.analyze(path: f.path, buckets: 100)!
        expect(a.peaks.count == 100 && abs(a.duration - 10) < 0.01)
        expect(a.peaks[10] > 0.08 && a.peaks[10] < 0.12 && a.peaks[90] > 0.75 && a.peaks[90] <= 1, "quiet half then loud half: \(a.peaks[10]) \(a.peaks[90])")
        expect(a.peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
        var cancelled = 0
        expect(DJAnalysis.analyze(path: f.path, cancelled: { cancelled += 1; return cancelled > 2 }) == nil, "analysis can be cancelled")
    }

    // MARK: the deck, end to end

    func deckLifecycle() {
        MainActor.assumeIsolated {
            let deck = DJDeck("T")
            let sink = RecordingSink(speed: 1)
            var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.4
            deck.options = o; deck.deckRate = 48_000
            let f = beatWAV("deck.wav", bpm: 120, seconds: 20, rate: 48_000)
            deck.load(DJTrack(path: f.path, title: "Test", artist: "Me"))
            expect(deck.isLoaded && abs(deck.duration - 20) < 0.01 && !deck.playing, "loaded, stopped, duration known")
            wait { deck.player.status.state == .paused }
            expect(deck.player.status.state == .paused && sink.frameCount == 0, "prepared silently")
            wait(timeout: 20) { deck.analysis != nil }
            expect(deck.analysis?.bpm != nil && abs(deck.bpm! - 120) < 1.0 && !deck.analyzing, "tempo found: \(String(describing: deck.bpm))")

            deck.play()
            wait { deck.refresh(); return deck.playing && deck.position > 1.0 }
            expect(deck.playing && deck.position > 1.0 && deck.position < 4, "playing: position \(deck.position)")
            // pitch: the position moves faster than the clock
            deck.pitch = 0.08
            wait(timeout: 1.5) { deck.refresh(); return false }          // let the new ratio reach the audio
            let p0 = deck.position, n0 = sink.frameCount
            wait(timeout: 5) { deck.refresh(); return false }
            deck.refresh()
            let played = Double(sink.frameCount - n0) / 48_000            // seconds of output the "speakers" consumed
            let rate = (deck.position - p0) / max(played, 0.001)
            expect(played > 3.5 && rate > 1.03 && rate < 1.13, "at +8 % each second of output advances the track by about 1.08 s: \(rate) over \(played) s")
            // and the displayed position never steps backwards while playing
            var last = deck.position, back = 0
            let t1 = Date()
            while Date().timeIntervalSince(t1) < 1.5 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)); deck.refresh(); if deck.position < last - 0.001 { back += 1 }; last = deck.position }
            expect(back == 0, "the position moves smoothly forward (\(back) backward steps)")
            expect(abs((deck.effectiveBPM ?? 0) - 120 * 1.08) < 1.2, "effective BPM follows the pitch: \(String(describing: deck.effectiveBPM))")
            deck.pitch = 0

            // seek and cue
            deck.quantize = false
            deck.seek(to: 12)
            wait(timeout: 6) { deck.refresh(); return abs(deck.position - 12.4) < 0.9 && deck.position >= 12 }
            expect(deck.position >= 11.9 && deck.position < 13.5, "seek lands near 12 s: \(deck.position)")
            deck.pause()
            wait { deck.refresh(); return !deck.playing }
            let held = deck.position
            deck.cuePressed()                       // stopped: sets the cue here
            expect(abs(deck.cue - held) < 1e-9)
            deck.play(); wait { deck.refresh(); return deck.playing && deck.position > held + 0.5 }
            deck.cuePressed()                       // playing: back to the cue and wait
            wait(timeout: 6) { deck.refresh(); return !deck.playing && abs(deck.position - held) < 0.8 }
            expect(!deck.playing && abs(deck.position - held) < 0.9, "cue returns and stops: \(deck.position) vs \(held)")

            // errors and unloading
            deck.load(DJTrack(path: "/nonexistent.flac", title: "x", artist: ""))
            expect(!deck.isLoaded && deck.error != nil, "a missing file is reported")
            deck.load(DJTrack(path: f.path, title: "Test", artist: ""))
            deck.unload()
            expect(!deck.isLoaded && !deck.playing && deck.position == 0)
            deck.shutdown()
        }
    }

    func djModelMixing() {
        MainActor.assumeIsolated {
            let m = DJModel()
            m.a.channel = 1; m.b.channel = 1
            m.crossfader = -1; m.curve = .smooth
            expect(abs(Double(m.a.mix.gain.value) - 1) < 1e-6 && m.b.mix.gain.value < 1e-6, "crossfader hard left: only deck A is audible")
            m.crossfader = 1
            expect(m.a.mix.gain.value < 1e-6 && abs(Double(m.b.mix.gain.value) - 1) < 1e-6)
            m.crossfader = 0
            expect(abs(Double(m.a.mix.gain.value) - 0.7071) < 0.001 && abs(Double(m.b.mix.gain.value) - 0.7071) < 0.001, "equal power in the middle")
            m.a.channel = 0.5
            expect(abs(Double(m.a.mix.gain.value) - 0.25 * 0.7071) < 0.001, "the channel fader multiplies in")
            m.curve = .sharp; expect(abs(Double(m.a.mix.gain.value) - 0.25) < 1e-6 && abs(Double(m.b.mix.gain.value) - 1) < 1e-6)
            // sync
            m.a.testSetAnalysis(DJTrackAnalysis(peaks: [], bpm: 120, confidence: 1, duration: 10))
            m.b.testSetAnalysis(DJTrackAnalysis(peaks: [], bpm: 126, confidence: 1, duration: 10))
            m.sync(m.a)
            expect(abs(m.a.pitch - 0.05) < 1e-9 && abs((m.a.effectiveBPM ?? 0) - 126) < 1e-9, "sync matches the other deck: \(m.a.pitch)")
            m.b.pitch = 0.08; m.sync(m.a)
            expect(abs((m.a.effectiveBPM ?? 0) - 126 * 1.08) < 1e-9 && m.a.pitchRange == 0.16, "a larger offset widens the pitch range: \(String(describing: m.a.effectiveBPM))")
            m.b.testSetAnalysis(DJTrackAnalysis(peaks: [], bpm: 200, confidence: 1, duration: 10)); m.b.pitch = 0
            let before = m.a.pitch; m.sync(m.a)
            expect(m.a.pitch == before, "an impossible sync changes nothing")
            expect(m.freeDeck() === m.a, "with nothing loaded the first deck is free")
        }
    }

    private func wait(timeout: TimeInterval = 10, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
}

extension DJDeck {
    /// Test seam: pretend this deck has analysed a track.
    func testSetAnalysis(_ a: DJTrackAnalysis) { setAnalysisForTests(a) }
}

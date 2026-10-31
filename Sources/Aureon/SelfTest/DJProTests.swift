import Foundation

/// The Pro console: the engine behind its modes (key lock, key shift, reverse, scratch), the mixer's extra channels, the sampler and booth, and the
/// numbers that keep its layout from moving.
struct DJProTests {
    let dir = tempDir("djpro")

    private func tone(_ name: String, rate: Int = 48_000, freq: Double = 440, seconds: Double = 3, amp: Double = 0.5) -> URL {
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

    // MARK: time stretch and key

    func stretcherKeepsThePitch() {
        let rate = 48_000.0, freq = 440.0
        let n = Int(rate * 4)
        let input: [Float] = (0..<n).flatMap { i -> [Float] in let v = Float(0.5 * sin(2 * Double.pi * freq * Double(i) / rate)); return [v, v] }
        for s in [1.25, 0.8] {
            let st = TimeStretcher(channels: 2)
            var pos = 0
            var out = [Float](repeating: 0, count: Int(Double(n) / s) * 2 + 8192)
            let produced = out.withUnsafeMutableBufferPointer { o in
                st.render(into: o.baseAddress!, frames: o.count / 2, stretch: s) { dst, want in
                    let k = min(want, n - pos)
                    for i in 0..<(k * 2) { dst[i] = input[pos * 2 + i] }
                    pos += k
                    return k
                }
            }
            expect(abs(Double(produced) - Double(n) / s) < Double(n) * 0.03, "the length follows the stretch: \(produced) frames for \(Double(n) / s) at \(s)")
            let asInts: [Int32] = out[0..<(produced * 2)].map { Int32(max(-1, min(1, $0)) * 2_147_483_000) }
            let on = amplitude(asInts, channels: 2, rate: rate, freq: freq, skip: 12_000, count: 60_000)
            let moved = amplitude(asInts, channels: 2, rate: rate, freq: freq * s, skip: 12_000, count: 60_000)
            expect(on > 0.4 && on > 6 * moved, "the tone stays at \(freq) Hz at stretch \(s): \(on) vs \(moved)")
        }
    }

    func keyLockAndKeyShiftInTheSource() {
        let f = tone("kl.wav", freq: 440, seconds: 4)
        func render(_ setup: (VarispeedControl) -> Void) -> (out: [Int32], control: VarispeedControl) {
            let c = VarispeedControl(); setup(c)
            return (readAllFrames(VarispeedSource(try! LosslessFile(path: f.path), control: c)), c)
        }
        // faster, key locked: shorter, same pitch
        let locked = render { $0.ratio = 1.1; $0.keyLock = true }
        let frames = locked.out.count / 2
        expect(abs(Double(frames) - 4 * 48_000 / 1.1) < 4 * 48_000 * 0.04, "the track is shorter at +10 %: \(frames)")
        let same = amplitude(locked.out, channels: 2, rate: 48_000, freq: 440, skip: 12_000, count: 60_000)
        let moved = amplitude(locked.out, channels: 2, rate: 48_000, freq: 484, skip: 12_000, count: 60_000)
        expect(same > 0.4 && same > 6 * moved, "key lock keeps 440 Hz: \(same) vs \(moved) at 484 Hz")
        // key lock off: the pitch follows, as on a turntable
        let free = render { $0.ratio = 1.1 }
        let follows = amplitude(free.out, channels: 2, rate: 48_000, freq: 484, skip: 12_000, count: 60_000)
        expect(follows > 0.45, "without key lock the tone moves with the speed: \(follows)")
        // an octave up, same speed
        let up = render { $0.keyShift = 12; $0.keyLock = true }
        let upFrames = up.out.count / 2
        let octave = amplitude(up.out, channels: 2, rate: 48_000, freq: 880, skip: 12_000, count: 60_000)
        let base = amplitude(up.out, channels: 2, rate: 48_000, freq: 440, skip: 12_000, count: 60_000)
        expect(abs(Double(upFrames) - 4 * 48_000) < 4 * 48_000 * 0.04 && octave > 0.4 && octave > 6 * base, "twelve semitones up doubles the pitch and keeps the length: \(octave) vs \(base), \(upFrames) frames")
        // key shift without lock at the original speed behaves the same
        let upFree = render { $0.keyShift = 12 }
        expect(amplitude(upFree.out, channels: 2, rate: 48_000, freq: 880, skip: 12_000, count: 60_000) > 0.4, "the shift works without key lock too")
        // nothing set: exact pass-through
        let plain = render { _ in }
        expect(plain.out == readAll(try! LosslessFile(path: f.path)), "with no key work the samples pass through unchanged")
    }

    // MARK: reverse and scratch

    private func rampFile(_ name: String, frames: Int) -> URL {
        writeWAV(dir.appendingPathComponent(name), rate: 48_000, bits: 24, frames: frames) { f, _ in f * 40 - 3_000_000 }
    }

    func reverseAndScratchMoveTheTrack() {
        let f = rampFile("ramp.wav", frames: 200_000)
        let c = VarispeedControl()
        let v = VarispeedSource(try! LosslessFile(path: f.path), control: c)
        v.seek(to: 100_000)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 2 * 6000); defer { buf.deallocate() }
        c.reverse = true
        var n = v.read(into: buf, frames: 6000)
        expect(n == 6000, "reverse delivers audio")
        var falling = 0
        for i in 1..<n where buf[i * 2] < buf[(i - 1) * 2] { falling += 1 }
        expect(falling > n - 5, "a rising ramp played backwards falls: \(falling) of \(n)")
        expect(abs(c.sourceFrame - (100_000 - 6000)) < 3, "the position moves back: \(c.sourceFrame)")
        // keep going back across the chunk boundaries, then forwards again without a jump
        for _ in 0..<5 { n = v.read(into: buf, frames: 6000) }
        let atTurn = c.sourceFrame
        c.reverse = false
        n = v.read(into: buf, frames: 6000)
        var rising = 0
        for i in 1..<n where buf[i * 2] > buf[(i - 1) * 2] { rising += 1 }
        expect(rising > n - 5 && abs(c.sourceFrame - (atTurn + 6000)) < 3, "and forwards again from where it turned: \(c.sourceFrame) after \(atTurn)")
        // the start of the track ends the read
        v.seek(to: 3000)
        c.reverse = true
        var total = 0
        while true { let k = v.read(into: buf, frames: 2048); total += k; if k == 0 { break } }
        expect(total >= 2990 && total <= 3010, "reverse stops at the start: \(total) frames")
        // a loop that runs backwards stays inside the loop
        c.reverse = true
        v.seek(to: 50_000)
        c.setLoop(from: 40_000, to: 48_000, on: true)
        for _ in 0..<12 { _ = v.read(into: buf, frames: 2000) }
        expect(c.sourceFrame >= 39_990 && c.sourceFrame < 48_000 && c.wraps >= 1, "a loop wraps backwards too: \(c.sourceFrame), \(c.wraps) wraps")
        c.clearLoop()

        // scratch: held still is silent and does not move; a negative speed goes back
        c.reverse = false
        v.seek(to: 80_000)
        c.scratchOn = true; c.scratchSpeed = 0
        n = v.read(into: buf, frames: 2000)
        var silent = true; for i in 0..<(n * 2) where buf[i] != 0 { silent = false }
        expect(silent && abs(c.sourceFrame - 80_000) < 1, "a held disc is silent and still: \(c.sourceFrame)")
        c.scratchSpeed = -1.5
        _ = v.read(into: buf, frames: 2000)
        expect(abs(c.sourceFrame - (80_000 - 3000)) < 3, "a backwards flick moves the track back: \(c.sourceFrame)")
        c.scratchSpeed = 2
        _ = v.read(into: buf, frames: 1000)
        expect(abs(c.sourceFrame - (80_000 - 3000 + 2000)) < 3, "and forwards at twice the speed: \(c.sourceFrame)")
        expect(abs(c.effectiveSpeed - 2) < 1e-9, "the control reports the hand's speed")
        c.scratchOn = false
        expect(abs(c.effectiveSpeed - 1) < 1e-9, "and the fader's again once the hand lifts")
        c.reverse = true
        expect(c.effectiveSpeed < 0, "reverse reports a negative speed")
    }

    // MARK: sampler, live channels, booth

    private func core() -> DJMixerCore { DJMixerCore(sampleRate: 48_000) }

    func samplerPlaysAndRestarts() {
        let c = core()
        let s = SampleData(left: [Float](repeating: 0.5, count: 300), right: [Float](repeating: -0.25, count: 300))
        c.sampler.level.value = 1
        c.sampler.load(s, slot: 3)
        expect(c.sampler.hasSample(3) && !c.sampler.hasSample(2) && c.sampler.length(3) == 300)
        let m = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 512); defer { m.deallocate() }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 512); defer { out.deallocate() }
        c.limiterOn.value = 0
        c.process(master: out, cue: nil, frames: 128)
        expect((0..<256).allSatisfy { out[$0] == 0 }, "a sampler at rest adds nothing")
        c.sampler.trigger(3)
        c.process(master: out, cue: nil, frames: 128)
        expect(abs(out[0] - 0.5) < 1e-4 && abs(out[1] + 0.25) < 1e-4 && abs(out[254] - 0.5) < 1e-4, "triggering plays the sample: \(out[0]), \(out[1])")
        expect(c.sampler.sounding[3].value == 1, "and the slot reports that it is sounding")
        c.process(master: out, cue: nil, frames: 128)
        c.process(master: out, cue: nil, frames: 128)
        expect(abs(out[2 * 43 - 2] - 0.5) < 1e-4 && out[2 * 44] == 0, "it ends where the sample ends: \(out[2 * 44])")
        expect(c.sampler.sounding[3].value == 0, "and the slot goes quiet")
        c.sampler.trigger(3); c.process(master: out, cue: nil, frames: 100)
        c.sampler.trigger(3); c.process(master: out, cue: nil, frames: 100)
        expect(abs(out[0] - 0.5) < 1e-4 && abs(out[198] - 0.5) < 1e-4, "triggering again restarts it")
        c.sampler.stopAll(); c.process(master: out, cue: nil, frames: 64)
        expect((0..<128).allSatisfy { out[$0] == 0 } && c.sampler.sounding[3].value == 0, "stop silences every slot")
        c.sampler.load(nil, slot: 3)
        expect(!c.sampler.hasSample(3))
        _ = m
    }

    func liveChannelsReachTheMaster() {
        let c = core()
        c.limiterOn.value = 0
        let ring = FloatRing(frames: 48_000)
        let sine: [Float] = (0..<9600).flatMap { i -> [Float] in let v = Float(0.4 * sin(2 * Double.pi * 1000 * Double(i) / 48_000)); return [v, v] }
        sine.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, frames: 9600) }
        c.mic.feed.publish(LineFeed(ring: ring, srcRate: 48_000, dstRate: 48_000))
        c.mic.gain.value = 1
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 4096); defer { out.deallocate() }
        c.process(master: out, cue: nil, frames: 4096)       // lets the resampler settle
        c.process(master: out, cue: nil, frames: 4096)
        var peak: Float = 0; for i in 0..<8192 { peak = max(peak, abs(out[i])) }
        expect(peak > 0.3 && peak < 0.5, "the microphone is in the mix at its fader level: \(peak)")
        expect(c.mic.peakL.value > 0.3, "and its meter moves: \(c.mic.peakL.value)")
        c.mic.gain.value = 0
        c.process(master: out, cue: nil, frames: 2048)
        c.process(master: out, cue: nil, frames: 2048)
        var quiet: Float = 0; for i in 0..<4096 { quiet = max(quiet, abs(out[i])) }
        expect(quiet < 1e-3, "with its fader down it adds nothing: \(quiet)")
        // an empty input falls silent instead of holding a value
        let dry = FloatRing(frames: 4800)
        c.aux.feed.publish(LineFeed(ring: dry, srcRate: 48_000, dstRate: 48_000))
        c.aux.gain.value = 1
        c.process(master: out, cue: nil, frames: 2048)
        var dc: Float = 0; for i in 0..<4096 { dc = max(dc, abs(out[i])) }
        expect(dc < 1e-4, "an input that has nothing to say stays silent: \(dc)")
        // a different input rate is brought to the mixer's rate
        let slow = FloatRing(frames: 48_000)
        let tone: [Float] = (0..<32_000).flatMap { i -> [Float] in let v = Float(0.4 * sin(2 * Double.pi * 1000 * Double(i) / 32_000)); return [v, v] }
        tone.withUnsafeBufferPointer { _ = slow.write($0.baseAddress!, frames: 32_000) }
        c.mic.feed.publish(LineFeed(ring: slow, srcRate: 32_000, dstRate: 48_000))
        c.mic.gain.value = 1; c.aux.gain.value = 0
        var collected = [Int32]()
        for _ in 0..<8 { c.process(master: out, cue: nil, frames: 4096); collected += (0..<4096).map { Int32(max(-1, min(1, out[$0 * 2])) * 2_000_000_000) } }
        let stereo = collected.flatMap { [$0, $0] }
        // the input's clock is followed by a small ratio correction, so look a few hertz either side
        let freqOK = stride(from: 990.0, through: 1020, by: 2).map { amplitude(stereo, channels: 2, rate: 48_000, freq: $0, skip: 8192, count: 16_384) }.max() ?? 0
        var crossings = 0
        for i in 9000..<(collected.count - 1) where (collected[i] < 0) != (collected[i + 1] < 0) { crossings += 1 }
        let hz = Double(crossings) / 2 / (Double(collected.count - 1 - 9000) / 48_000)
        expect(freqOK > 0.3, "a 32 kHz input still plays a 1 kHz tone at 1 kHz: \(freqOK), \(hz) Hz by zero crossings, peak \(collected.max() ?? 0)")
    }

    func boothCarriesTheMasterAtItsOwnLevel() {
        let c = core()
        c.limiterOn.value = 0
        let s = SampleData(left: [Float](repeating: 0.5, count: 2000), right: [Float](repeating: 0.5, count: 2000))
        c.sampler.level.value = 1; c.sampler.load(s, slot: 0); c.sampler.trigger(0)
        let ring = FloatRing(frames: 8192)
        c.booth.publish(ring); c.boothLevel.value = 0.5
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 1024); defer { out.deallocate() }
        c.process(master: out, cue: nil, frames: 1024)
        expect(ring.available == 1024, "the booth ring receives every frame: \(ring.available)")
        let got = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 1024); defer { got.deallocate() }
        _ = ring.read(into: got, frames: 1024)
        expect(abs(got[100] - out[100] * 0.5) < 1e-5 && abs(got[100] - 0.25) < 1e-3, "at half the master's level: \(got[100]) vs \(out[100])")
        c.booth.publish(nil)
        c.process(master: out, cue: nil, frames: 512)
        expect(ring.available == 0, "and nothing once the booth is off")
    }

    // MARK: the model

    func detailWaveformShowsBassAndTreble() {
        let bass = DJWaveDetail.build(path: tone("bass.wav", freq: 80, seconds: 2, amp: 0.8).path)
        let treble = DJWaveDetail.build(path: tone("treb.wav", freq: 6000, seconds: 2, amp: 0.8).path)
        expect(bass != nil && treble != nil)
        guard let bass, let treble else { return }
        expect(abs(bass.count - 200) <= 2, "100 bins a second: \(bass.count)")
        let b = bass.peaks(from: 50, to: 150), t = treble.peaks(from: 50, to: 150)
        expect(b.low > 0.5 && b.low > 4 * b.high, "a bass tone is low: \(b)")
        expect(t.high > 0.5 && t.high > 4 * t.low, "a high tone is high: \(t)")
        expect(bass.peaks(from: 500, to: 600) == (0, 0) && bass.peaks(from: -20, to: 5).low >= 0, "reading past the ends is safe")
    }

    func gridAndSlipAndModes() {
        MainActor.assumeIsolated {
            let ud = UserDefaults(suiteName: "aureon.djpro.\(UUID().uuidString.prefix(6))")!
            GridStore.overrideDefaults = ud
            defer { GridStore.overrideDefaults = nil }
            let d = DJDeck("T")
            d.setAnalysisForTests(DJTrackAnalysis(peaks: [], bpm: 120, confidence: 1, duration: 60, firstBeat: 0.5))
            expect(d.firstBeat == 0.5 && d.gridOffset == 0, "the grid starts where the analysis put it")
            // no track is loaded, so nudging is refused
            d.nudgeGrid(by: 0.01)
            expect(d.gridOffset == 0, "nothing to move without a track")
            expect(GridStore.load(path: "/x") == 0)
            GridStore.save(path: "/x", offset: 0.02)
            expect(GridStore.load(path: "/x") == 0.02, "grid offsets are remembered per track")
            GridStore.save(path: "/x", offset: 0)
            expect(GridStore.load(path: "/x") == 0, "and forgotten when back at zero")
            d.padMode = .loop; d.padBank = 1
            d.padMode = .slicer
            expect(d.padBank == 0, "changing the pad mode returns to the first bank")
            expect(PadMode.slicer.banks == 4 && PadMode.cues.banks == 1)
            d.reverse = true; expect(d.control.reverse)
            d.reverse = false; expect(!d.control.reverse)
            d.keyLock = true; d.keyShift = -3
            expect(d.control.keyLock && d.control.keyShift == -3, "key lock and shift reach the engine")
            d.slip = true
            d.slipBegin()
            expect(!d.slipping, "slip needs the deck to be playing")
            d.scratchBegin()
            expect(!d.scratching, "and a track to scratch")
        }
    }

    func effectUnitsFollowTheirSettings() {
        MainActor.assumeIsolated {
            let m = DJModel()
            m.a.fxUnit = 2
            m.fxUnits[1].kind = .flanger; m.fxUnits[1].wet = 0.6; m.fxUnits[1].param = 0.8; m.fxUnits[1].on = true
            expect(m.a.fxOn && m.a.fxKind == .flanger && abs(m.a.fxWet - 0.6) < 1e-9 && abs(m.a.fxParam - 0.8) < 1e-9, "a deck takes on its unit's settings")
            expect(m.a.mix.params.fxOn.value == 1 && m.a.mix.params.fxKind.value == DeckFXKind.flanger.rawValue, "and so does the mixer channel")
            m.fxUnits[1].on = false
            expect(!m.a.fxOn, "switching the unit off switches the deck's effect off")
            m.b.fxUnit = 0
            m.fxUnits[0].on = true
            expect(!m.b.fxOn, "a channel with no unit is untouched")
            m.mic.fxUnit = 1
            expect(m.mic.mix.params.fxOn.value == 1, "the microphone can use a unit too")
            m.mic.toggleKill("low"); expect(m.mic.isKilled("low") && m.mic.mix.params.low.value <= -59)
            m.mic.toggleKill("low"); expect(!m.mic.isKilled("low"))
            m.mic.channel = 0.5
            expect(abs(Double(m.mic.mix.gain.value) - DJMath.channelGain(0.5)) < 1e-6, "the microphone fader sets its gain")
        }
    }

    func masterAndSync() {
        MainActor.assumeIsolated {
            let m = DJModel()
            expect(m.masterDeck == nil)
            m.setMaster(m.b)
            expect(m.masterDeck === m.b && m.b.isMaster && !m.a.isMaster)
            expect(m.syncSource(for: m.a) === m.b && m.syncSource(for: m.b) === m.a, "a deck follows the master; the master follows the other")
            m.setMaster(m.b)
            expect(m.masterDeck == nil && !m.b.isMaster, "pressing master again clears it")
            m.setMaster(m.a)
            m.setMaster(m.b)
            expect(m.masterDeck === m.b && !m.a.isMaster, "choosing the other deck moves it")
            // followers match the master's tempo
            m.a.setAnalysisForTests(DJTrackAnalysis(peaks: [], bpm: 124, confidence: 1, duration: 60, firstBeat: 0))
            m.b.setAnalysisForTests(DJTrackAnalysis(peaks: [], bpm: 128, confidence: 1, duration: 60, firstBeat: 0))
            m.a.syncOn = true
            m.followMaster()
            // nothing is loaded, so followers wait for a track
            expect(m.a.pitch == 0, "without a loaded track nothing moves")
            expect(m.masterTempo == 128 || m.masterTempo == nil)
        }
    }

    func presetsAndWindowRules() {
        expect(DJLayoutPreset.pro.minimumWindow == CGSize(width: 1180, height: 760), "Pro cannot be dragged below 1180 × 760")
        expect(DJLayoutPreset.compact.minimumWindow.width < 1300 && DJLayoutPreset.allCases.count == 2)
        let d = UserDefaults(suiteName: "aureon.djpreset.\(UUID().uuidString.prefix(6))")!
        expect(DJLayoutPreset.load(d) == .pro, "Pro is the default")
        DJLayoutPreset.compact.save(d)
        expect(DJLayoutPreset.load(d) == .compact, "the choice is remembered")
        // the customisation of the compact layout still works next to it
        var l = DJLayout(); l.setShown(.deck, "fx", false)
        expect(!l.visible(.deck).contains("fx"))
    }

    /// The Pro console never scrolls: no scroll container in its root view, and at every window size the scaled console, the toolbar and the margin fit the window.
    func consoleFitsTheWindowWithoutScrolling() {
        let m = DJProMetrics.self
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("GUI/DJProRoot.swift")
        if let text = try? String(contentsOf: root, encoding: .utf8) {
            let view = text[text.range(of: "struct DJProView")!.lowerBound..<text.range(of: "// MARK: - Toolbar")!.lowerBound]
            expect(!view.contains("ScrollView") && !view.contains("scrollPosition"), "the Pro console root has no scroll container")
        }
        for body in [m.bodyHeightEstimate - 60, m.bodyHeightEstimate, m.bodyHeightEstimate + 60] {
            var lastScale: CGFloat = 0
            for h in stride(from: m.minimumWindow.height, through: 2200, by: 20) {
                for w in [m.minimumWindow.width, 1440, 1920, 3840] {
                    let f = m.fit(window: CGSize(width: w, height: h), bodyHeight: body)
                    let used = m.toolbarHeight + m.gap + f.consoleHeight * f.scale + m.outer + (f.libraryInline ? m.gap + m.libraryMin : 0)
                    expect(f.scale <= 1 && f.scale >= 0.5, "never scaled up, never below half: \(f.scale) at \(w)×\(h)")
                    expect(used <= h + 0.5 || f.scale == 0.5, "everything fits \(w)×\(h) (body \(body)): \(used)")
                    expect(f.stageHeight >= m.stageMin && f.stageHeight <= m.stageMax, "the stage stays in its range at \(w)×\(h): \(f.stageHeight)")
                }
                let f = m.fit(window: CGSize(width: 1180, height: h), bodyHeight: body)
                expect(f.scale >= lastScale - 0.001, "a taller window never shrinks the console (\(h))")
                lastScale = f.scale
            }
        }
        let atMin = m.fit(window: m.minimumWindow, bodyHeight: m.bodyHeightEstimate)
        expect(!atMin.libraryInline && atMin.scale >= 0.7, "at 1180×760 the console is scaled \(atMin.scale) and the library is a drawer")
        expect(m.fit(window: CGSize(width: 1440, height: 1500), bodyHeight: m.bodyHeightEstimate).libraryInline, "a tall window shows the library under the console")
        expect(m.fit(window: CGSize(width: 1920, height: 1080), bodyHeight: m.bodyHeightEstimate).scale == 1, "a full-screen display shows the console at full size")
    }

    func layoutNeverOverlapsAtAnyWidth() {
        let m = DJProMetrics.self
        let needDeck = 2 * m.deckPad + m.modesColumn + m.tempoBlock + m.pitchBlock + m.jogMin + 3 * 10
        var w: CGFloat = 1180
        var lastMixer: CGFloat = 0, lastDeck: CGFloat = 0
        while w <= 3840 {
            let c = m.columns(window: w)
            expect(c.deck >= needDeck, "a deck always has room for its controls at \(w): \(c.deck) < \(needDeck)")
            expect(c.mixer >= m.mixerMin && c.mixer <= m.mixerMax, "the mixer stays within its range at \(w): \(c.mixer)")
            expect(2 * c.deck + c.mixer + 2 * m.gap + 2 * m.outer <= w + 0.5, "the columns fit the window at \(w)")
            let j = m.jog(deckWidth: c.deck)
            expect(j >= m.jogMin && j <= m.jogMax, "the disc stays within its range at \(w): \(j)")
            expect(c.mixer >= lastMixer - 0.5 && c.deck >= lastDeck - 0.5, "columns only grow as the window grows (\(w))")
            lastMixer = c.mixer; lastDeck = c.deck
            w += 17
        }
        // smaller than the minimum is treated as the minimum
        expect(m.columns(window: 800).deck == m.columns(window: 1180).deck)
        // the strips fit their column
        let c = m.columns(window: 1180)
        expect((c.mixer - 2 * m.deckPad) / 4 >= m.stripMin - 6, "four strips fit the mixer at the minimum width: \((c.mixer - 2 * m.deckPad) / 4)")
    }

    func discAndScratchMaths() {
        expect(abs(DJProMath.discAngle(position: 0.9) - 180) < 1e-9, "half a turn after 0.9 s")
        expect(abs(DJProMath.discAngle(position: 1.8)) < 1e-9 || abs(DJProMath.discAngle(position: 1.8) - 360) < 1e-9)
        expect(abs(DJProMath.angle(x: 0, y: -1)) < 1e-9 && abs(DJProMath.angle(x: 1, y: 0) - 90) < 1e-9 && abs(DJProMath.angle(x: 0, y: 1) - 180) < 1e-9 && abs(DJProMath.angle(x: -1, y: 0) - 270) < 1e-9, "angles run clockwise from the top")
        expect(DJProMath.turn(from: 350, to: 10) == 20 && DJProMath.turn(from: 10, to: 350) == -20, "turning through the top is short")
        expect(abs(DJProMath.scratchSpeed(degrees: 360, seconds: 1.8) - 1) < 1e-9, "one turn in 1.8 s is normal speed")
        expect(DJProMath.scratchSpeed(degrees: -180, seconds: 0.9) < 0 && DJProMath.scratchSpeed(degrees: 10, seconds: 0) == 0)
        expect(DJProMath.scratchSpeed(degrees: 36_000, seconds: 0.01) == 8, "and is limited")
        let b = DJProMath.beats(from: 0, to: 4, bpm: 120, firstBeat: 0.25)
        expect(b.count == 8 && abs(b[0].time - 0.25) < 1e-9 && b[0].index == 0 && abs(b[7].time - 3.75) < 1e-9, "beats of a 120 bpm grid: \(b.map(\.time))")
        let early = DJProMath.beats(from: 0, to: 1, bpm: 120, firstBeat: 0.75)
        expect(early.first.map { abs($0.time - 0.25) < 1e-9 && $0.index == -1 } ?? false, "the grid reaches back before its first beat")
        expect(DJProMath.beats(from: 5, to: 5, bpm: 120, firstBeat: 0).isEmpty && DJProMath.beats(from: 0, to: 5, bpm: 0, firstBeat: 0).isEmpty)
        let bb = DJProMath.barBeat(at: 5.1, bpm: 120, firstBeat: 0.1)
        expect(bb.bar == 3 && bb.beat == 3, "bar and beat: \(bb)")
        expect(DJProMath.clock(125.4) == "02:05" && DJProMath.clock(-3) == "00:00")
        let k = MusicalKey(pitchClass: 9, minor: true)
        expect(DJProMath.shifted(k, semitones: 2)?.pitchClass == 11 && DJProMath.shifted(k, semitones: -10)?.pitchClass == 11 && DJProMath.shifted(nil, semitones: 3) == nil)
        expect(DJPadSets.label(beats: 0.125) == "1/8" && DJPadSets.label(beats: 8) == "8" && DJPadSets.label(beats: 1.5) == "1.5")
        expect(DJPadSets.fx.count == 16 && DJPadSets.loopBeats.count == 16 && DJPadSets.rollBeats.count == 16)
    }
}

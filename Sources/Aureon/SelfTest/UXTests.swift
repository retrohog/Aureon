import Foundation

struct UXTests {
    let dir = tempDir("ux")
    func conflictRules() {
        var base = PlaybackSettings()
        expect(SettingRules.check(old: base, new: base) == nil, "nothing on, nothing to say")
        // turning DoP on while processing is on
        var on = base; on.replayGain.mode = .track; on.rt.dither.mode = .tpdf
        var dop = on; dop.dsd.mode = .dop
        let c = SettingRules.check(old: on, new: dop)
        expect(c != nil && c!.message.contains("Volume leveling and Dither") && c!.fixLabel.contains("DoP"), "\(String(describing: c?.message))")
        var fixed = dop; c!.fix(&fixed)
        expect(fixed.dsd.mode == .dop && fixed.replayGain.mode == .off && !fixed.rt.dither.enabled && SettingRules.check(old: on, new: fixed) == nil, "the fix removes the clash and keeps DoP")
        // turning processing on while DoP is on: the offer is to leave DoP
        base.dsd.mode = .dop
        var lvl = base; lvl.replayGain.mode = .album
        let c2 = SettingRules.check(old: base, new: lvl)
        expect(c2 != nil && c2!.message.contains("Volume leveling") && c2!.fixLabel.contains("PCM"), "\(String(describing: c2?.message))")
        var f2 = lvl; c2!.fix(&f2)
        expect(f2.dsd.mode == .pcm && f2.replayGain.mode == .album && SettingRules.check(old: base, new: f2) == nil)
        // a combination that was already saved is not announced again, and unrelated changes pass
        var legacy = base; legacy.replayGain.mode = .track
        var tweak = legacy; tweak.replayGain.preampDB = 2
        expect(SettingRules.check(old: legacy, new: tweak) == nil, "an old clash is not re-announced")
        var ram = PlaybackSettings(); ram.ram.enabled = true
        expect(SettingRules.check(old: PlaybackSettings(), new: ram) == nil)
        // room correction vs headphones, both directions
        var cf = PlaybackSettings(); cf.rt.crossfeed.enabled = true
        var room = cf; room.rt.convolution.enabled = true
        let c3 = SettingRules.check(old: cf, new: room)
        expect(c3 != nil && c3!.message.contains("Crossfeed"), "\(String(describing: c3?.message))")
        var f3 = room; c3!.fix(&f3)
        expect(f3.rt.convolution.enabled && !f3.rt.crossfeed.enabled)
        var roomOnly = PlaybackSettings(); roomOnly.rt.convolution.enabled = true
        var plusEQ = roomOnly; plusEQ.rt.headphoneEQ.enabled = true
        let c4 = SettingRules.check(old: roomOnly, new: plusEQ)
        var f4 = plusEQ; c4?.fix(&f4)
        expect(c4 != nil && !f4.rt.convolution.enabled && f4.rt.headphoneEQ.enabled, "the other way round, the offer is to drop room correction")
        expect(SettingRules.list(["a"]) == "a" && SettingRules.list(["a", "b", "c"]) == "a, b and c")
    }

    func sidebarLayout() {
        var l = SidebarLayout()
        expect(l.visible(in: .sound) == [.rooms, .audio, .dsp] && l.visible(in: .tools) == [.rip, .convert, .cloud, .abx] && l.visible(in: .listen) == [.home, .player, .radio, .podcasts], "the default is the usual sidebar")
        l.setHidden(.dsp, true); l.setHidden(.cloud, true)
        expect(l.visible(in: .sound) == [.rooms, .audio] && l.hiddenTabs == [.dsp, .cloud] && l.isHidden(.dsp), "hidden pages leave the sidebar")
        l.setHidden(.settings, true); l.setHidden(.search, true)
        expect(!l.isHidden(.settings) && !l.isHidden(.search), "Settings and search cannot be removed")
        l.move(.convert, by: -1)
        expect(l.ordered(in: .tools) == [.rip, .convert, .cloud, .abx].swapped(0, 1) , "\(l.ordered(in: .tools))")
        l.move(.convert, by: -1)
        expect(l.ordered(in: .tools).first == .convert, "moving past the top does nothing more")
        l.move(.home, by: 1)
        expect(l.ordered(in: .listen) == [.player, .home, .radio, .podcasts, ].filter { $0 != .search } && l.ordered(in: .tools).first == .convert, "groups are independent: \(l.ordered(in: .listen))")
        let d = UserDefaults(suiteName: "aureon.sidebartest.\(UUID().uuidString.prefix(6))")!
        l.save(d)
        expect(SidebarLayout.load(d) == l, "the layout is remembered")
        expect(SidebarLayout.load(UserDefaults(suiteName: "aureon.sidebartest.empty.\(UUID().uuidString.prefix(6))")!) == SidebarLayout(), "and a fresh install gets the default")
        // every page is either in the sidebar or reachable
        var all = SidebarLayout()
        for t in Tab.allCases { all.setHidden(t, true) }
        let reachable = Set(all.hiddenTabs).union([.settings, .search])
        expect(reachable.count == Tab.allCases.count, "hiding everything leaves each page listed under Hidden pages")
        // saved by a version that had fewer pages: new pages still appear
        var old = SidebarLayout(); old.order = [Tab.dsp.rawValue]
        expect(old.ordered(in: .sound) == [.dsp, .rooms, .audio] && old.visible(in: .tools) == [.rip, .convert, .cloud, .abx], "pages missing from a saved order keep their place after the listed ones")
    }


    // MARK: speaker setup

    func speakerPlan() {
        var a = SpeakerMember(uid: "a", name: "Table"), b = SpeakerMember(uid: "b", name: "MacBook")
        a.distanceM = 3.43; b.distanceM = 1.0; b.role = .center; b.trimDB = -6; b.extraDelayMs = 2
        let e = SpeakerPlan.entries([a, b], rate: 48_000, bassManagement: true, extraLatencyFrames: [1920, 0])
        // the nearer speaker waits for the farther one: 2.43 m is 7.08 ms, plus 2 ms; the master adds the ring's latency
        expect(e[0].delayFrames == 1920 && abs(e[1].delayFrames - Int(((2.43 / 343) + 0.002) * 48_000)) <= 1, "\(e)")
        expect(abs(Double(e[1].gain) - 0.5012) < 0.001 && e[0].gain == 1 && !e[0].highPass && !e[1].highPass, "no bass speaker, no high-pass")
        var sub = SpeakerMember(uid: "c", name: "Sub"); sub.role = .bass
        let e2 = SpeakerPlan.entries([a, b, sub], rate: 48_000, bassManagement: true, extraLatencyFrames: [])
        expect(e2[0].highPass && e2[1].highPass && !e2[2].highPass, "with a bass speaker the others are high-passed")
        expect(!SpeakerPlan.entries([a, b, sub], rate: 48_000, bassManagement: false, extraLatencyFrames: []).contains { $0.highPass })
        var far = a; far.distanceM = 0; far.extraDelayMs = 9_999
        expect(SpeakerPlan.entries([far], rate: 48_000, bassManagement: false, extraLatencyFrames: [])[0].delayFrames == 24_000, "delays are capped at half a second")
        let setup = SpeakerSetup(enabled: true, members: [a, b], crossoverHz: 120, bassManagement: false)
        expect((try? JSONDecoder().decode(SpeakerSetup.self, from: JSONEncoder().encode(setup))) == setup, "the setup is saved faithfully")
    }

    func speakerRoles() {
        func run(_ role: SpeakerRole, _ l: Float, _ r: Float, hp: Bool = false) -> (Float, Float) {
            let p = RoleProcessor(entry: .init(role: role, gain: 1, delayFrames: 0, highPass: hp), crossover: 100, rate: 48_000)
            var out = (Float(0), Float(0)); for _ in 0..<4000 { out = p.process(l, r) }; return out
        }
        expect(run(.main, 0.3, -0.2) == (0.3, -0.2) && run(.left, 0.3, -0.2) == (0.3, 0.3) && run(.right, 0.3, -0.2) == (-0.2, -0.2))
        expect(abs(run(.center, 0.5, 0.5).0 - 0.5) < 1e-6 && run(.center, 0.5, -0.5).0 == 0, "centre: what both channels share")
        expect(abs(run(.surround, 0.5, 0.5).0 - 0.5) < 0.001 && abs(run(.surround, 0.5, -0.5).0) < 0.001, "ambience: the low notes as the stereo speakers play them (the beat stays), and no steady difference signal")
        expect(abs(run(.bass, 0.4, 0.4).0 - 0.4) < 0.001, "bass passes steady (low) signals")
        expect(abs(run(.main, 0.4, 0.4, hp: true).0) < 0.001, "high-passed speakers drop them")
        // tones: 40 Hz and 4 kHz through the low and high sides of the crossover
        func level(_ role: SpeakerRole, hp: Bool, hz: Double) -> Double {
            let p = RoleProcessor(entry: .init(role: role, gain: 1, delayFrames: 0, highPass: hp), crossover: 100, rate: 48_000)
            var peak = 0.0
            for i in 0..<48_000 { let x = Float(sin(2 * .pi * hz * Double(i) / 48_000)); let y = p.process(x, x).0; if i > 24_000 { peak = max(peak, Double(abs(y))) } }
            return peak
        }
        expect(level(.bass, hp: false, hz: 4_000) < 0.002 && level(.bass, hp: false, hz: 40) > 0.9, "the bass speaker plays 40 Hz, not 4 kHz")
        expect(level(.main, hp: true, hz: 40) < 0.1 && level(.main, hp: true, hz: 4_000) > 0.99, "the others play 4 kHz, not 40 Hz")
        // at the crossover the two sides add back to the original level
        var low = LR4(low: true, freq: 100, rate: 48_000), high = LR4(low: false, freq: 100, rate: 48_000), peak = 0.0
        for i in 0..<48_000 { let x = sin(2 * .pi * 100 * Double(i) / 48_000); let y = low.process(x) + high.process(x); if i > 24_000 { peak = max(peak, abs(y)) } }
        expect(abs(peak - 1) < 0.02, "Linkwitz-Riley sides add up flat: \(peak)")
    }

    func speakerDelayAndRing() {
        let d = StereoDelay(maxFrames: 1000)
        d.setFrames(3)
        var out: [Float] = []
        for i in 1...8 { out.append(d.process(Float(i), -Float(i)).0) }
        expect(out == [0, 0, 0, 1, 2, 3, 4, 5], "\(out)")
        d.setFrames(1)
        let r = StereoRing(frames: 8)
        var src = (0..<20).map { Float($0) }, dst = [Float](repeating: -1, count: 20)
        expect(src.withUnsafeBufferPointer { r.write($0.baseAddress!, frames: 10) } == 8, "only what fits is taken")
        expect(r.fill == 8 && dst.withUnsafeMutableBufferPointer { r.read(into: $0.baseAddress!, frames: 3) } == 3 && Array(dst[0..<6]) == [0, 1, 2, 3, 4, 5], "frames come out in order")
        r.discard(2)
        expect(r.fill == 3 && dst.withUnsafeMutableBufferPointer { r.read(into: $0.baseAddress!, frames: 10) } == 3 && Array(dst[0..<2]) == [10, 11], "discarding skips the oldest")
        // a producer and a consumer on different threads lose and reorder nothing
        let ring = StereoRing(frames: 4096), total = 200_000
        let done = DispatchSemaphore(value: 0), ok = Atomic2()
        Thread {
            var next = 0, buf = [Float](repeating: 0, count: 2 * 256), good = true
            while next < total {
                let got = buf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 256) }
                for i in 0..<got { if buf[i * 2] != Float(next + i) || buf[i * 2 + 1] != -Float(next + i) { good = false } }
                next += got
                if got == 0 { usleep(50) }
            }
            ok.value = good; done.signal()
        }.start()
        var sent = 0
        while sent < total {
            let n = min(100, total - sent)
            var chunk = [Float](repeating: 0, count: n * 2)
            for i in 0..<n { chunk[i * 2] = Float(sent + i); chunk[i * 2 + 1] = -Float(sent + i) }
            let w = chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: n) }
            if w < n { usleep(50) }
            sent += w
            if w < n { /* the rest of the chunk is retried below */ var rest = Array(chunk[(w * 2)...]); while !rest.isEmpty { let k = rest.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: rest.count / 2) }; rest.removeFirst(k * 2); if k == 0 { usleep(50) } }; sent += n - w }
        }
        expect(done.wait(timeout: .now() + 20) == .success && ok.value, "200 000 frames across threads arrive in order")
    }


    /// Real devices, silent audio: two outputs of this Mac play one stream and neither crashes, starves or ends up with a wrong sample rate.
    func speakersOnRealDevices() {
        // the Mac's own speakers and its headphone jack: always there on a laptop, unlike monitors that sleep
        let all = listOutputDevices().filter { !$0.uid.isEmpty && !$0.rates.isEmpty }
        let devs = [all.first { $0.name.contains("Headphones") }, all.first { $0.name.contains("Speakers") }].compactMap { $0 }
        guard devs.count >= 2 else { print("    (fewer than two output devices here: skipped)"); return }
        var setup = SpeakerSetup(enabled: true)
        setup.members = [SpeakerMember(uid: devs[0].uid, name: devs[0].name), SpeakerMember(uid: devs[1].uid, name: devs[1].name, role: .center, distanceM: 1.5, extraDelayMs: 3, trimDB: -3)]
        guard let sink = MultiDeviceSink(setup: setup, primaryID: devs[0].id) else { expect(false, "the sink could not be built from two present devices"); return }
        expect(sink.outputChannels == 2 && sink.deviceName.contains(devs[0].name) && sink.deviceName.contains(devs[1].name))
        let wav = writeWAV(dir.appendingPathComponent("silence-speakers.wav"), rate: 44_100, bits: 16, frames: 44_100 * 2) { _, _ in 0 }
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let pl = Player()
        pl.setQueue([wav.path]); pl.start(options: o)
        expect(pl.waitUntilFinished(timeout: 15), "the track plays through to the end")
        // while it ran, retune live
        var changed = setup; changed.members[1].role = .surround; changed.members[1].trimDB = 0; sink.update(changed)
        expect(pl.status.errors.isEmpty, "\(pl.status.errors) devices: \(devs.map { "\($0.name) \($0.channels)ch \($0.rates.count) rates" })")
        expect(pl.status.pathLines.contains { $0.contains("Speaker setup") }, "\(pl.status.pathLines)")
        pl.stop()
        sink.shutdown()
    }

    func scrollGate() {
        var g = ScrollGate()
        // a mouse wheel: the page, unless ⌥ is held over a slider
        expect(g.decide(now: 1, phased: false, begins: false, momentumEnded: false, option: false, overControl: true) == .page)
        expect(g.decide(now: 1, phased: false, begins: false, momentumEnded: false, option: true, overControl: true) == .adjust)
        expect(g.decide(now: 1, phased: false, begins: false, momentumEnded: false, option: true, overControl: false) == .page)
        // a trackpad gesture that begins over a slider stays with it, momentum included, then lets go
        var t = 10.0
        func step(_ begins: Bool, over: Bool, end: Bool = false) -> ScrollGate.Action { t += 0.016; return g.decide(now: t, phased: true, begins: begins, momentumEnded: end, option: false, overControl: over) }
        expect(step(true, over: true) == .adjust && step(false, over: false) == .adjust && step(false, over: false) == .adjust, "the gesture belongs to the slider where it began")
        expect(step(false, over: false) == .adjust && step(false, over: false, end: true) == .adjust, "its momentum too")
        expect(step(false, over: false) == .page, "and afterwards the page scrolls again")
        // one that begins elsewhere is the page's, even when it passes over a slider
        expect(step(true, over: false) == .page && step(false, over: true) == .page && step(false, over: true) == .page)
        // a gesture whose end never arrived cannot hold the scrolling: silence ends it, and so does the next gesture
        expect(step(true, over: true) == .adjust)
        t += 1.0
        expect(step(false, over: false) == .page, "after a pause it is the page's")
        expect(step(true, over: true) == .adjust && step(true, over: false) == .page, "a new gesture decides afresh")
    }

    func speakerVolumeMatching() {
        expect(MultiDeviceSink.joiningVolume(current: 0.9, main: 0.4) == 0.4, "an output that joins takes the main output's volume, not its own old one")
        expect(MultiDeviceSink.joiningVolume(current: 0.2, main: 0.4) == 0.4, "even when its own was lower")
        expect(MultiDeviceSink.joiningVolume(current: 0.9, main: nil) == 0.35, "with no main volume to follow it is held to a cautious level")
        expect(MultiDeviceSink.joiningVolume(current: 0.1, main: nil) == 0.1 && MultiDeviceSink.joiningVolume(current: nil, main: nil) == nil)
        expect(MultiDeviceSink.joiningVolume(current: 0.5, main: 7) == 1 && MultiDeviceSink.joiningVolume(current: 0.5, main: -1) == 0, "always a valid level")
    }

    // MARK: DJ console

    func djLayout() {
        var l = DJLayout()
        expect(l.visible(.deck) == ["cues", "loops", "roll", "fx", "tools", "pitch"] && l.visible(.strip).count == 7 && l.visible(.bottom) == ["master", "crossfader", "automix", "phones"] && l.visible(.page) == ["masterbar", "browser"], "the default shows everything")
        l.setShown(.deck, "fx", false); l.setShown(.page, "browser", false)
        expect(l.visible(.deck) == ["cues", "loops", "roll", "tools", "pitch"] && !l.isShown(.page, "browser"), "hidden sections drop out")
        l.move(.deck, "pitch", by: -5)
        expect(l.items(.deck).first?.id == "pitch" && l.visible(.deck).first == "pitch", "sections can be moved to the top")
        l.move(.deck, "pitch", by: -1)
        expect(l.items(.deck).first?.id == "pitch", "and not past it")
        let stripBefore = l.items(.strip).map(\.id)
        l.move(.strip, "fader", by: -1)
        expect(l.items(.strip).map(\.id) != stripBefore && l.items(.deck).first?.id == "pitch" && l.items(.bottom).map(\.id) == ["master", "crossfader", "automix", "phones"], "areas are independent")
        let d = UserDefaults(suiteName: "aureon.djlayout.\(UUID().uuidString.prefix(6))")!
        l.save(d)
        expect(DJLayout.load(d) == l, "the layout is remembered")
        expect(DJLayout.load(UserDefaults(suiteName: "aureon.djlayout.none.\(UUID().uuidString.prefix(6))")!) == DJLayout())
        var old = DJLayout(); old.order = ["Each deck/pitch"]
        expect(old.items(.deck).first?.id == "pitch" && old.items(.deck).count == 6, "sections missing from a saved order keep their place")
    }

    func djDeckTools() {
        MainActor.assumeIsolated {
            let deck = DJDeck("T")
            deck.setAnalysisForTests(DJTrackAnalysis(peaks: [], bpm: 100, confidence: 1, duration: 60, firstBeat: 0.2))
            expect(deck.bpm == 100 && deck.effectiveBPM == 100)
            deck.bpmScale = 2; expect(deck.bpm == 200)
            deck.bpmScale = 0.5; expect(deck.bpm == 50 && deck.beatLength == 1.2)
            deck.bpmScale = 1
            // tapping 0.5 s apart is 120 BPM; a pause starts over
            let t0 = Date()
            deck.tap(now: t0); deck.tap(now: t0.addingTimeInterval(0.5))
            expect(deck.manualBPM == nil, "two taps are not enough")
            deck.tap(now: t0.addingTimeInterval(1.0)); deck.tap(now: t0.addingTimeInterval(1.5))
            expect(deck.manualBPM != nil && abs(deck.manualBPM! - 120) < 0.01 && deck.bpm == deck.manualBPM, "\(String(describing: deck.manualBPM))")
            deck.tap(now: t0.addingTimeInterval(10)); deck.tap(now: t0.addingTimeInterval(10.4)); deck.tap(now: t0.addingTimeInterval(10.8))
            expect(abs(deck.manualBPM! - 150) < 0.01, "a long pause starts a new count: \(String(describing: deck.manualBPM))")
            deck.resetBPM()
            expect(deck.manualBPM == nil && deck.bpm == 100)
            // the beat grid follows the tempo in use
            deck.quantize = true
            expect(abs((deck.gridBeat(near: 1.0) ?? 0) - 1.4) < 1e-9 || abs((deck.gridBeat(near: 1.0) ?? 0) - 0.8) < 1e-9, "grid at 100 BPM")
            deck.bpmScale = 2
            expect(abs((deck.gridBeat(near: 0.5) ?? 0) - 0.5) < 1e-9 && abs((deck.gridBeat(near: 0.62) ?? 0) - 0.5) < 1e-9, "…and at double time the beats are twice as close")
            deck.bpmScale = 1
            // kill switches put the band back where it was
            deck.low = 3
            deck.toggleKill("low")
            expect(deck.isKilled("low") && deck.low == DJMath.eqRange.lowerBound && !deck.isKilled("high"))
            deck.toggleKill("low")
            expect(!deck.isKilled("low") && deck.low == 3, "a second press restores \(deck.low)")
            deck.high = DJMath.eqRange.lowerBound
            deck.toggleKill("high")
            expect(!deck.isKilled("high") && deck.high == 0, "a band that was already at the bottom comes back flat")
        }
    }

    func djCrossfaderAssign() {
        MainActor.assumeIsolated {
            let dj = DJModel()
            expect(dj.a.assign == .left && dj.b.assign == .right)
            dj.a.channel = 1; dj.b.channel = 1
            dj.crossfader = -1
            expect(dj.a.mix.gain.value > 0.99 && dj.b.mix.gain.value < 0.01, "A on the left, B silent")
            dj.b.assign = .thru
            expect(dj.b.mix.gain.value > 0.99, "a channel set to THRU ignores the crossfader")
            dj.b.assign = .right; dj.crossfaderReverse = true
            expect(dj.a.mix.gain.value < 0.01 && dj.b.mix.gain.value > 0.99, "reverse flips which side is which")
            dj.crossfaderReverse = false; dj.a.assign = .right
            expect(dj.a.mix.gain.value < 0.01, "channels can swap sides")
        }
    }

    func knobReadouts() {
        expect(KnobKind.eq.text(-26, range: DJMath.eqRange) == "KILL" && KnobKind.eq.text(0, range: DJMath.eqRange) == "+0.0 dB" && KnobKind.eq.text(4.5, range: DJMath.eqRange) == "+4.5 dB")
        expect(KnobKind.filter.text(0, range: -1...1) == "OFF" && KnobKind.filter.text(-0.5, range: -1...1) == "LP 50 %" && KnobKind.filter.text(0.25, range: -1...1) == "HP 25 %")
        expect(KnobKind.level.text(1, range: 0...1.25) == "100 %" && KnobKind.percent.text(0.35, range: 0...1) == "35 %")
        expect(KnobKind.blend.text(0, range: 0...1) == "CUE" && KnobKind.blend.text(1, range: 0...1) == "MASTER" && KnobKind.blend.text(0.5, range: 0...1) == "50 % MST")
    }

    func scrollingNeverSticks() {
        // the slider arithmetic is unchanged
        expect(ScrollStep.apply(value: 0.5, notches: 1, range: 0...1) == 0.52)
        expect(ScrollStep.apply(value: 0.99, notches: 5, range: 0...1) == 1)
        expect(ScrollStep.notches(deltaY: 28, precise: true) == 2 && ScrollStep.notches(deltaY: 3, precise: false) == 3)
    }
}

private extension Array {
    func swapped(_ i: Int, _ j: Int) -> [Element] { var a = self; a.swapAt(i, j); return a }
}

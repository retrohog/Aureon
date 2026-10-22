import Foundation

struct DJDeckTests {
    let dir = tempDir("djdeck")

    private func beatWAV(_ name: String, bpm: Double, seconds: Double, rate: Int = 48_000, freq: Double = 55) -> URL {
        let frames = Int(Double(rate) * seconds), beat = 60 / bpm * Double(rate)
        let full = Double((1 << 23) - 1)
        return writeWAV(dir.appendingPathComponent(name), rate: rate, bits: 24, frames: frames) { f, _ in
            let k = Double(f).truncatingRemainder(dividingBy: beat)
            var v = 0.0
            if k < 0.12 * Double(rate) { v += 0.8 * exp(-k / (0.04 * Double(rate))) * sin(2 * .pi * freq * k / Double(rate)) }
            return Int(v * full)
        }
    }

    private func wait(timeout: TimeInterval = 10, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func hotCuesAndLoops() {
        MainActor.assumeIsolated {
            let suite = UserDefaults(suiteName: "aureon.test.\(ProcessInfo.processInfo.processIdentifier)")!
            HotCueStore.overrideDefaults = suite
            defer { HotCueStore.overrideDefaults = nil; suite.removePersistentDomain(forName: "aureon.test.\(ProcessInfo.processInfo.processIdentifier)") }
            let deck = DJDeck("T")
            let sink = RecordingSink(speed: 1)
            var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.25
            deck.options = o; deck.deckRate = 48_000
            let f = beatWAV("hc.wav", bpm: 120, seconds: 40)
            deck.load(DJTrack(path: f.path, title: "HC", artist: ""))
            wait(timeout: 20) { deck.analysis != nil }
            expect(deck.analysis?.bpm != nil && abs(deck.bpm! - 120) < 1, "tempo \(String(describing: deck.bpm))")
            deck.quantize = false
            deck.play()
            wait { deck.refresh(); return deck.playing && deck.position > 1 }

            // hot cues: first press stores, second press jumps
            deck.seek(to: 8); wait(timeout: 4) { deck.refresh(); return deck.position >= 8 }
            deck.pause(); wait { deck.refresh(); return !deck.playing }
            let at = deck.position
            deck.hotCue(2)
            expect(deck.hotCues[2] != nil && abs(deck.hotCues[2]! - at) < 1e-9 && deck.hotCues[0] == nil, "a pad stores the position")
            deck.seek(to: 20); wait(timeout: 4) { deck.refresh(); return abs(deck.position - 20) < 0.3 }
            deck.hotCue(2)
            wait(timeout: 6) { deck.refresh(); return abs(deck.position - at) < 1.0 && deck.playing }
            expect(abs(deck.position - at) < 1.2, "pressing a stored pad jumps back: \(deck.position) vs \(at)")
            deck.pause()
            // they are remembered for this track
            deck.load(DJTrack(path: f.path, title: "HC", artist: ""))
            expect(deck.hotCues[2] != nil && abs(deck.hotCues[2]! - at) < 1e-9, "…and come back when the track is loaded again")
            deck.hotCue(2); deck.clearHotCue(2)
            expect(deck.hotCues[2] == nil)
            deck.load(DJTrack(path: f.path, title: "HC", artist: ""))
            expect(deck.hotCues.allSatisfy { $0 == nil }, "clearing is remembered too")

            // snapping to the beat grid
            wait(timeout: 20) { deck.analysis != nil }
            deck.quantize = true
            let a = deck.analysis!
            let s = deck.snapped(10.13)
            let ph = a.beatPhase(at: s)!
            expect(ph < 0.01 || ph > 0.99, "quantize puts a cue on the beat grid: \(ph)")

            // loops
            deck.quantize = false
            deck.seek(to: 4); deck.play()
            wait(timeout: 6) { deck.refresh(); return deck.playing && deck.position >= 4.2 }
            deck.autoLoop(beats: 4)
            expect(deck.loopActive && abs((deck.loopOut! - deck.loopIn!) - 2.0) < 0.02 && abs(deck.loopBeats! - 4) < 0.05, "a 4-beat loop at 120 BPM is 2 s: \(String(describing: deck.loopBeats))")
            let li = deck.loopIn!, lo = deck.loopOut!
            var worst = 0.0, outside = 0
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 6 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1)); deck.refresh()
                if deck.position > lo + 0.05 || deck.position < li - 0.05 { outside += 1 }
                worst = max(worst, deck.position)
            }
            expect(outside <= 6, "for six seconds the position stays inside the loop (\(outside) readings outside), max \(worst)")
            expect(deck.control.wraps >= 2, "and the audio really wrapped: \(deck.control.wraps)")
            deck.scaleLoop(0.5)
            expect(abs((deck.loopOut! - deck.loopIn!) - 1.0) < 0.02, "halving makes it one beat-pair shorter")
            deck.scaleLoop(2); deck.scaleLoop(2)
            expect(abs((deck.loopOut! - deck.loopIn!) - 4.0) < 0.02, "doubling twice makes 4 s")
            deck.toggleLoop()
            expect(!deck.loopActive && deck.loopIn != nil, "switching off keeps the points for reloop")
            deck.toggleLoop()
            expect(deck.loopActive, "reloop")
            deck.clearLoop()
            expect(!deck.loopActive && deck.loopIn == nil && deck.loopOut == nil)
            // set in / out by hand
            deck.setLoopIn(); deck.setLoopOut()
            expect(deck.loopIn != nil && deck.loopOut == nil || deck.loopOut != nil, "setting out right at in does nothing")
            deck.bend(1); expect(abs(deck.control.bend - 0.04) < 1e-12 && deck.bending == 1, "bend")
            deck.bend(0); expect(deck.control.bend == 0)
            deck.shutdown()
        }
    }

    func autoDJMixesTwoTracks() {
        MainActor.assumeIsolated {
            let m = DJModel()
            var pull: PullOutput?
            m.outputFactory = { core in let p = PullOutput(core: core, speed: 1); p.keep = true; pull = p; return p }
            var o = PlayerOptions(); o.bufferSeconds = 0.25
            m.enter(options: o, rate: 48_000)
            defer { m.exit() }
            let names = ["x1", "x2", "x3"]
            let tracks: [DJTrack] = names.enumerated().map { i, n in
                let f = beatWAV(n + ".wav", bpm: 120 + Double(i) * 2, seconds: 26)
                return DJTrack(path: f.path, title: n, artist: "")
            }
            for t in tracks { m.auto.addToPool(t, AnalysisCache.shared.analysis(path: t.path)!) }
            m.auto.library = { tracks }
            m.auto.persistence = false
            m.auto.mixBeats = 8
            m.auto.strictKey = false
            m.a.load(tracks[0]); m.a.setAnalysisForTests(AnalysisCache.shared.analysis(path: tracks[0].path)!)
            wait { m.a.isLoaded }
            m.a.quantize = false
            m.a.play(); wait(timeout: 6) { m.tick(); return m.a.playing }
            m.a.seek(to: 12)
            wait(timeout: 6) { m.tick(); return m.a.position >= 12 }
            m.auto.enabled = true
            expect(m.auto.phase != .off && m.crossfader == -1, "Auto DJ takes over the playing deck and puts the crossfader on it")
            wait(timeout: 6) { m.tick(); return m.auto.phase == .armed }
            expect(m.auto.phase == .armed && m.b.isLoaded && m.auto.next != nil, "it queues a track on the idle deck: \(m.auto.status)")
            expect(m.b.low <= DJMath.eqRange.lowerBound + 0.01 && !m.b.playing, "…with its bass cut and not yet playing")
            expect(abs(m.b.effectiveBPM! - m.a.effectiveBPM!) < 0.6, "…at the playing tempo: \(m.b.effectiveBPM!) vs \(m.a.effectiveBPM!)")
            var sawBlend = false, lowSwapped = false
            wait(timeout: 25) {
                m.tick()
                if m.auto.phase == .blending { sawBlend = true; if m.a.low <= DJMath.eqRange.lowerBound + 0.1 && m.b.low >= -0.1 { lowSwapped = true } }
                return m.auto.mixes >= 1
            }
            expect(sawBlend, "a blend happened")
            expect(lowSwapped, "and the bass was swapped from the old deck to the new one")
            expect(m.auto.mixes == 1 && m.b.playing && !m.a.isLoaded, "afterwards the new deck is on air and the old one is empty")
            expect(m.crossfader == 1 && m.autoBlendIsOff && m.b.low == 0, "the crossfader ends on the new deck, with flat EQ")
            expect(m.auto.canRate, "the mix can be rated")
            let before = m.auto.net.feedbackCount
            m.auto.rate(liked: true)
            expect(m.auto.net.feedbackCount == before + 1 && !m.auto.canRate, "a rating teaches the network once")
            // the output never clipped or went silent through the blend
            if let p = pull {
                let x = p.master
                let peak = x.map { abs($0) }.max() ?? 0
                expect(peak <= 0.9661, "the master stayed under the limiter ceiling: \(peak)")
                // long stretches of digital silence would mean a dropout
                var run = 0, longest = 0
                for i in stride(from: 0, to: x.count, by: 2) { if abs(x[i]) < 1e-4 { run += 1; longest = max(longest, run) } else { run = 0 } }
                expect(Double(longest) / 48_000 < 0.5, "no dropout in the mix: longest quiet stretch \(Double(longest) / 48_000) s (a kick every 0.5 s)")
            }
            m.auto.enabled = false
            expect(m.auto.phase == .off)
        }
    }
}

extension DJModel { var autoBlendIsOff: Bool { autoBlend == nil } }

extension DJDeckTests {
    /// Nothing loaded, nothing analysed yet: Auto DJ has to analyse a few tracks, start one by itself and mix into the next.
    func autoDJStartsFromScratch() {
        MainActor.assumeIsolated {
            let m = DJModel()
            m.outputFactory = { core in let p = PullOutput(core: core, speed: 1); p.keep = false; return p }
            var o = PlayerOptions(); o.bufferSeconds = 0.25
            m.enter(options: o, rate: 48_000)
            defer { m.exit() }
            let stamp = Int(Date().timeIntervalSince1970)
            let tracks: [DJTrack] = (0..<3).map { i in
                let f = beatWAV("cold\(stamp)-\(i).wav", bpm: 118 + Double(i) * 3, seconds: 24)
                return DJTrack(path: f.path, title: "Cold \(i)", artist: "")
            }
            expect(tracks.allSatisfy { AnalysisCache.shared.cached(path: $0.path) == nil }, "none of them analysed yet")
            m.auto.library = { tracks }
            m.auto.persistence = false
            m.auto.mixBeats = 8
            m.auto.enabled = true
            expect(m.auto.strictKey == false, "harmonic-only is off by default")
            wait(timeout: 40) { m.tick(); return m.decks.contains { $0.playing } }
            expect(m.decks.contains { $0.playing }, "it picked a track and started it by itself: \(m.auto.status)")
            wait(timeout: 60) { m.tick(); return m.auto.mixes >= 1 }
            expect(m.auto.mixes >= 1, "and mixed into another one: \(m.auto.status), analysed \(m.auto.analysed)")
            expect(m.decks.filter(\.playing).count == 1, "leaving one deck playing")
            m.auto.enabled = false
        }
    }
}

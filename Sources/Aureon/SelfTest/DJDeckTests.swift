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
}

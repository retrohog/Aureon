import Foundation

struct RemixTests {
    private func analysis(duration: Double = 200, bpm: Double = 120, energy: (Double) -> Double = { _ in 0.6 }) -> DJTrackAnalysis {
        let n = 1200
        let peaks = (0..<n).map { Float(energy(Double($0) / Double(n) * duration)) }
        var a = DJTrackAnalysis(peaks: peaks, bpm: bpm, confidence: 0.8, duration: duration)
        a.firstBeat = 0.25; a.introEnd = 16; a.outroStart = duration - 24
        return a
    }

    func performancesAreWellFormed() {
        for a in RemixAction.allCases where a != .none {
            let before = a.state(atBeat: -1), after = a.state(atBeat: a.beats + 0.01)
            expect(before == .neutral && after == .neutral, "\(a.title): neutral before and after")
            var touched = false
            var b = 0.0
            while b < a.beats { let s = a.state(atBeat: b); if s != .neutral { touched = true }; expect(s.filter >= -1 && s.filter <= 1 && s.fxWet >= 0 && s.fxWet <= 1 && s.fxParam >= 0 && s.fxParam <= 1, "\(a.title) stays in range at \(b)"); b += 0.125 }
            expect(touched, "\(a.title) actually does something")
        }
        expect(RemixAction.filterSweep.state(atBeat: 4).filter < -0.6 && RemixAction.filterSweep.state(atBeat: 0.5).filter > -0.3, "the sweep closes in the middle and opens again")
        expect(RemixAction.riser.state(atBeat: 7.5).filter > 0.5 && RemixAction.riser.state(atBeat: 1).filter < 0.2, "the riser climbs")
        expect(RemixAction.bassDrop.state(atBeat: 2).lowDB == DJMath.eqRange.lowerBound && RemixAction.bassDrop.state(atBeat: 3.99).lowDB == 0, "the bass is cut, then slams back on the beat")
        expect(RemixAction.loopRoll.state(atBeat: 0.5).loopBeats == 1 && RemixAction.loopRoll.state(atBeat: 2.5).loopBeats == 0.5 && RemixAction.loopRoll.state(atBeat: 3.5).loopBeats == 0.25, "the roll tightens")
        expect(RemixAction.echoOut.state(atBeat: 7.9).fxWet < 0.05, "the echo's feed fades out so the tail rings out")
    }

    func contextComesFromTheTrack() {
        // quiet intro, a build, then a loud section
        let a = analysis { t in t < 30 ? 0.2 : (t < 60 ? 0.2 + (t - 30) / 30 * 0.5 : 0.8) }
        let c = EnergyContour(analysis: a)
        expect(c.level(from: 0, to: 10) < 0.35 && c.level(from: 100, to: 110) > 0.9, "levels follow the waveform: \(c.level(from: 0, to: 10)), \(c.level(from: 100, to: 110))")
        let build = RemixPlanner.context(analysis: a, contour: c, bar: 12, intensity: 0.7, barsSinceAction: 5, last: .none)!      // 0.25 + 12 bars × 2 s = 24 s
        expect(build.upcomingBuild > 0.1 && !build.inOutro && build.barInPhrase == 4, "ahead of a build: \(build)")
        let late = RemixPlanner.context(analysis: a, contour: c, bar: 90, intensity: 0.5, barsSinceAction: 20, last: .echoOut)!
        expect(!late.inIntro && late.upcomingBuild < 0.05 && late.last == .echoOut, "\(late)")
        let outro = RemixPlanner.context(analysis: a, contour: c, bar: 90, intensity: 0.5, barsSinceAction: 3, last: .none)!
        expect(outro.inOutro == (0.25 + 90 * 2 >= 200 - 24), "outro detection")
        expect(RemixPlanner.context(analysis: a, contour: c, bar: 500, intensity: 0.5, barsSinceAction: 0, last: .none) == nil, "past the end there is nothing")
        var none = a; none.bpm = nil
        expect(RemixPlanner.context(analysis: none, contour: c, bar: 3, intensity: 0.5, barsSinceAction: 0, last: .none) == nil, "no tempo, no bars")
        expect(build.vector.count == RemixContext.count)
    }

    func policyKnowsTheRules() {
        let net = RemixPolicy.fresh(); net.pretrain()
        func best(_ c: RemixContext) -> RemixAction { RemixAction(rawValue: net.scores(c).enumerated().max { $0.element < $1.element }!.offset)! }
        var build = RemixContext(); build.energyNow = 0.45; build.energyNext = 0.6; build.upcomingBuild = 0.3; build.barInPhrase = 6; build.intensity = 0.8
        expect([.riser, .none].contains(best(build)) && net.scores(build)[RemixAction.riser.rawValue] > 0.5, "a build wants a riser: \(best(build)) \(net.scores(build))")
        var outro = RemixContext(); outro.inOutro = true; outro.energyNow = 0.4; outro.barInPhrase = 7; outro.intensity = 0.6
        expect(net.scores(outro)[RemixAction.echoOut.rawValue] > net.scores(outro)[RemixAction.stutter.rawValue] + 0.3, "an outro wants an echo, not a stutter")
        var mid = RemixContext(); mid.energyNow = 0.7; mid.barInPhrase = 1; mid.intensity = 0.3; mid.barsSinceAction = 8
        expect(best(mid) == .none, "in the middle of a phrase with a low setting: leave it alone, \(best(mid))")
        var end = RemixContext(); end.energyNow = 0.8; end.energyNext = 0.8; end.barInPhrase = 7; end.intensity = 0.9
        let wild = net.scores(end)
        expect(wild[RemixAction.loopRoll.rawValue] > 0.5 && wild[RemixAction.stutter.rawValue] > 0.2, "a phrase end at a high setting invites a loop roll or stutter: \(wild)")
        end.intensity = 0.1
        let gentle = net.scores(end)
        expect(gentle[RemixAction.stutter.rawValue] < wild[RemixAction.stutter.rawValue] - 0.1 && gentle[RemixAction.loopRoll.rawValue] < wild[RemixAction.loopRoll.rawValue] - 0.2, "…and much less so at a gentle setting: \(gentle)")
        // deterministic
        let b = RemixPolicy.fresh(); b.pretrain()
        expect(b.w == net.w)
    }

    func policyLearnsAndPersists() {
        let net = RemixPolicy.fresh(); net.pretrain()
        var c = RemixContext(); c.energyNow = 0.8; c.energyNext = 0.8; c.barInPhrase = 7; c.intensity = 0.8
        let before = net.scores(c)[RemixAction.stutter.rawValue], echoBefore = net.scores(c)[RemixAction.echoOut.rawValue]
        for _ in 0..<10 { net.feedback(c, action: .stutter, liked: false) }
        expect(net.scores(c)[RemixAction.stutter.rawValue] < before - 0.15, "a thumbs-down makes that move less likely: \(before) → \(net.scores(c)[RemixAction.stutter.rawValue])")
        expect(abs(net.scores(c)[RemixAction.echoOut.rawValue] - echoBefore) < 0.12, "the other moves are not disturbed: \(echoBefore) → \(net.scores(c)[RemixAction.echoOut.rawValue])")
        let dir = tempDir("remixpol"), url = dir.appendingPathComponent("p.json")
        net.save(to: url)
        let back = RemixPolicy.loadOrCreate(at: url)
        expect(back.w == net.w && back.feedbackCount == 10)
        try? Data("junk".utf8).write(to: url)
        expect(RemixPolicy.loadOrCreate(at: url).feedbackCount == 0, "a damaged file falls back to a fresh pretrained network")
        // choosing is sampled but favours the strong
        var rng = SplitMix(seed: 3)
        var ctx = RemixContext(); ctx.inOutro = true; ctx.energyNow = 0.4; ctx.barInPhrase = 7; ctx.intensity = 0.6
        let fresh = RemixPolicy.fresh(); fresh.pretrain()
        var counts: [RemixAction: Int] = [:]
        for _ in 0..<300 { counts[fresh.choose(ctx, using: &rng), default: 0] += 1 }
        expect((counts[.echoOut] ?? 0) > 60 && (counts[.echoOut] ?? 0) > (counts[.stutter] ?? 0) * 3, "echo is the usual pick in an outro: \(counts)")
    }
}

extension RemixTests {
    private func beatFile(_ name: String, bpm: Double, seconds: Double) -> URL {
        let rate = 48_000, beat = 60 / bpm * Double(rate), full = Double((1 << 23) - 1)
        return writeWAV(tempDir("remixfx").appendingPathComponent(name), rate: rate, bits: 24, frames: Int(Double(rate) * seconds)) { f, _ in
            let k = Double(f).truncatingRemainder(dividingBy: beat)
            return k < 0.12 * Double(rate) ? Int(0.7 * exp(-k / (0.04 * Double(rate))) * sin(2 * .pi * 55 * k / Double(rate)) * full) : 0
        }
    }

    private func spinFor(_ s: TimeInterval, until cond: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(s)
        while Date() < end && !cond() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    func controllerPerformsAndRestores() {
        MainActor.assumeIsolated {
            let m = DJModel()
            m.outputFactory = { core in let p = PullOutput(core: core, speed: 1); p.keep = false; return p }
            var o = PlayerOptions(); o.bufferSeconds = 0.25
            m.enter(options: o, rate: 48_000)
            defer { m.exit() }
            let f = beatFile("rm.wav", bpm: 120, seconds: 60)
            let t = DJTrack(path: f.path, title: "RM", artist: "")
            let a = AnalysisCache.shared.analysis(path: f.path)!
            m.a.load(t); m.a.setAnalysisForTests(a)
            spinFor(3) { m.a.isLoaded }
            m.a.play(); spinFor(8) { m.tick(); return m.a.playing }
            m.a.seek(to: 10); spinFor(6) { m.tick(); return m.a.position >= 10 }
            let r = m.remix
            r.persistence = false
            m.a.fxKind = .reverb; m.a.fxWet = 0.2; m.a.fxOn = false         // what the user had
            r.enabled = true
            expect(r.status == "Listening…" || r.status.hasPrefix("Next") || r.status.hasPrefix("Waiting"), r.status)

            r.perform(.echoOut, on: m.a)
            expect(m.a.fxOn && m.a.fxKind == .echo && r.current == .echoOut, "the echo is thrown")
            spinFor(1.0) { m.tick(); return false }
            expect(m.a.fxOn && m.a.fxWet > 0.25, "…and is on while the move runs: wet \(m.a.fxWet)")
            spinFor(6) { m.tick(); return r.current == .none }
            expect(!m.a.fxOn && m.a.fxKind == .reverb && abs(m.a.fxWet - 0.2) < 1e-9, "when it ends the deck's own effect settings are back: on \(m.a.fxOn) kind \(m.a.fxKind) wet \(m.a.fxWet)")
            expect(r.actionCount == 1 && r.canRate && r.history == [.echoOut])

            m.a.low = -3
            r.perform(.bassDrop, on: m.a)
            spinFor(0.4) { false }
            expect(m.a.low == DJMath.eqRange.lowerBound, "the bass drops out: \(m.a.low)")
            spinFor(5) { m.tick(); return r.current == .none }
            expect(m.a.low == -3, "and the user's EQ comes back: \(m.a.low)")

            r.perform(.loopRoll, on: m.a)
            spinFor(0.3) { false }
            expect(m.a.loopActive && abs((m.a.loopBeats ?? 0) - 1) < 0.01, "a one-beat loop: \(String(describing: m.a.loopBeats))")
            spinFor(6) { m.tick(); return r.current == .none }
            expect(!m.a.loopActive, "the loop is released")

            r.perform(.riser, on: m.a)
            spinFor(1.5) { m.tick(); return false }
            expect(m.a.filter > 0.05, "the filter climbs: \(m.a.filter)")
            r.enabled = false
            expect(m.a.filter == 0 && !m.a.fxOn && r.current == .none && r.status == "Off", "switching the remixer off in the middle of a move puts everything back")

            let n = r.feedbackCount
            r.rate(liked: false)
            expect(r.feedbackCount == n + 1 && !r.canRate)
            // (the remixer always works on the deck that is playing)
            expect(m.a.low == -3 && m.a.fxKind == .reverb)
        }
    }
}

import Foundation

struct AutoDJTests {
    private func an(bpm: Double, key: MusicalKey?, energy: Double, loud: Double = -14, duration: Double = 240) -> DJTrackAnalysis {
        var a = DJTrackAnalysis(peaks: [], bpm: bpm, confidence: 0.6, duration: duration)
        a.key = key; a.keyStrength = 0.6; a.energy = energy; a.loudness = loud; a.firstBeat = 0.3; a.introEnd = 16; a.outroStart = duration - 30
        return a
    }
    private let cMaj = MusicalKey(pitchClass: 0, minor: false), gMaj = MusicalKey(pitchClass: 7, minor: false), fsMaj = MusicalKey(pitchClass: 6, minor: false), aMin = MusicalKey(pitchClass: 9, minor: true)

    func netSeparatesGoodFromBadMixes() {
        let net = TransitionNet.fresh(); net.pretrain()
        let cur = an(bpm: 124, key: cMaj, energy: 0.6)
        func s(_ b: DJTrackAnalysis) -> Float { net.score(TransitionFeatures(from: cur, to: b)!) }
        let good = s(an(bpm: 126, key: gMaj, energy: 0.65)), relative = s(an(bpm: 123, key: aMin, energy: 0.6))
        let wrongKey = s(an(bpm: 125, key: fsMaj, energy: 0.6)), wrongTempo = s(an(bpm: 98, key: cMaj, energy: 0.6)), both = s(an(bpm: 98, key: fsMaj, energy: 0.1, loud: -26))
        expect(good > 0.75 && relative > 0.75, "compatible tracks score high: \(good), \(relative)")
        expect(good > wrongKey + 0.1, "a clashing key is worse: \(good) vs \(wrongKey)")
        expect(good > wrongTempo + 0.1, "an unmixable tempo is worse: \(good) vs \(wrongTempo)")
        expect(both < wrongKey && both < wrongTempo && both < 0.5, "and both together is the worst: \(both)")
        // half and double time count as matches
        expect(s(an(bpm: 62, key: cMaj, energy: 0.6)) > 0.75 && s(an(bpm: 248, key: cMaj, energy: 0.6)) > 0.75, "half and double time still mix")
        // tracks without a tempo cannot be scored
        var none = cur; none.bpm = nil
        expect(TransitionFeatures(from: cur, to: none) == nil)
        // the network is deterministic
        let n2 = TransitionNet.fresh(); n2.pretrain()
        expect(n2.w == net.w, "pretraining is reproducible")
    }

    func netLearnsFromFeedback() {
        let net = TransitionNet.fresh(); net.pretrain()
        let cur = an(bpm: 124, key: cMaj, energy: 0.5)
        // the listener hates mixes into much louder, higher-energy tracks even when they match on paper
        let loudB = an(bpm: 125, key: gMaj, energy: 0.95, loud: -6)
        let calmB = an(bpm: 125, key: gMaj, energy: 0.5, loud: -14)
        let fL = TransitionFeatures(from: cur, to: loudB)!, fC = TransitionFeatures(from: cur, to: calmB)!
        let before = net.score(fL), calmBefore = net.score(fC)
        for _ in 0..<12 { net.feedback(fL, liked: false); net.feedback(fC, liked: true) }
        expect(net.score(fL) < before - 0.25, "thumbs-down lowers the score of that kind of mix: \(before) → \(net.score(fL))")
        expect(net.score(fC) > 0.75 && net.score(fC) > net.score(fL) + 0.3, "while a liked one stays high: \(calmBefore) → \(net.score(fC))")
        expect(net.feedbackCount == 24)
        // a few opinions do not wreck what it already knew
        let clash = TransitionFeatures(from: cur, to: an(bpm: 90, key: fsMaj, energy: 0.5))!
        expect(net.score(clash) < 0.5, "it still knows a clash when it hears one: \(net.score(clash))")
    }

    func netPersists() {
        let dir = tempDir("autodj"), url = dir.appendingPathComponent("net.json")
        let net = TransitionNet.fresh(); net.pretrain()
        let f = TransitionFeatures(from: an(bpm: 120, key: cMaj, energy: 0.5), to: an(bpm: 124, key: aMin, energy: 0.7))!
        net.feedback(f, liked: false)
        net.save(to: url)
        let back = TransitionNet.loadOrCreate(at: url)
        expect(back.w == net.w && back.feedbackCount == 1 && back.score(f) == net.score(f), "saved and restored exactly")
        try? Data("not json".utf8).write(to: url)
        let rebuilt = TransitionNet.loadOrCreate(at: url)
        expect(rebuilt.feedbackCount == 0 && rebuilt.score(f) > 0.1, "a damaged file falls back to a pretrained network")
        expect(TransitionNet.load(Data("{\"w\":[[1]],\"feedback\":0,\"version\":1}".utf8)) == nil, "wrong shapes are rejected")
        // inference is cheap enough to score a whole library
        let t = Date(); for _ in 0..<20_000 { _ = net.score(f) }
        expect(Date().timeIntervalSince(t) < 2.0, "20 000 scores in \(Date().timeIntervalSince(t)) s")
    }

    func plannerPicksTheBestNextTrack() {
        let net = TransitionNet.fresh(); net.pretrain()
        let cur = an(bpm: 124, key: cMaj, energy: 0.6)
        func c(_ n: String, _ a: DJTrackAnalysis) -> AutoCandidate { AutoCandidate(track: DJTrack(path: "/\(n)", title: n, artist: ""), analysis: a) }
        let pool = [c("clash", an(bpm: 124, key: fsMaj, energy: 0.6)), c("slow", an(bpm: 95, key: cMaj, energy: 0.6)), c("perfect", an(bpm: 125, key: gMaj, energy: 0.62)),
                    c("played", an(bpm: 124, key: cMaj, energy: 0.6)), c("hot", an(bpm: 125, key: aMin, energy: 0.95, loud: -7))]
        let r = AutoPlanner.rank(current: cur, candidates: pool, recent: ["/played"], vibe: .steady, strictKey: false, net: net)
        expect(r.first?.candidate.track.title == "perfect", "the best fit comes first: \(r.map { $0.candidate.track.title })")
        expect(!r.contains { $0.candidate.track.title == "played" }, "recently played tracks are never repeated")
        expect(r.last?.candidate.track.title == "clash" || r.last?.candidate.track.title == "slow", "the worst fits come last")
        let strict = AutoPlanner.rank(current: cur, candidates: pool, recent: [], vibe: .steady, strictKey: true, net: net)
        expect(!strict.contains { $0.candidate.track.title == "clash" }, "strict key mode drops clashing keys")
        let hotter = c("hot", an(bpm: 125, key: aMin, energy: 0.75, loud: -12))
        let build = AutoPlanner.rank(current: cur, candidates: [hotter, c("calm", an(bpm: 125, key: aMin, energy: 0.3))], recent: [], vibe: .build, strictKey: false, net: net)
        let wind = AutoPlanner.rank(current: cur, candidates: [hotter, c("calm", an(bpm: 125, key: aMin, energy: 0.3))], recent: [], vibe: .wind, strictKey: false, net: net)
        expect(build.first?.candidate.track.title == "hot" && wind.first?.candidate.track.title == "calm", "build-up and wind-down steer the energy: \(build.map { $0.candidate.track.title }) / \(wind.map { $0.candidate.track.title })")
        expect(AutoPlanner.rank(current: cur, candidates: [], recent: [], vibe: .steady, strictKey: false, net: net).isEmpty)
    }

    func mixPlanGeometry() {
        let a = an(bpm: 120, key: cMaj, energy: 0.6, duration: 200)
        var a2 = a; a2.firstBeat = 0.1
        let b = an(bpm: 126, key: gMaj, energy: 0.6)
        guard let p = AutoMixer.plan(a: a2, aRatio: 1, b: b, beats: 32) else { expect(false, "a plan exists"); return }
        expect(abs(p.duration - 16) < 1e-9, "32 beats at 120 BPM is 16 s: \(p.duration)")
        expect(p.aStart + p.duration <= 200 + 1e-6 && p.aStart > 100, "the blend fits inside the outgoing track: \(p.aStart)")
        let phase = a2.beatPhase(at: p.aStart)!
        expect(phase < 0.01 || phase > 0.99, "and starts on a beat of its grid: \(phase)")
        expect(abs(p.bRatio - 120.0 / 126) < 1e-9, "B is slowed to A's tempo: \(p.bRatio)")
        expect(p.bStart == 0.3, "B starts on its first beat")
        // a pitch change on A changes the length of a beat
        let fast = AutoMixer.plan(a: a2, aRatio: 1.05, b: b, beats: 32)!
        expect(abs(fast.duration - 32 * 60 / 126) < 1e-9, "beats are counted at the playing tempo: \(fast.duration)")
        // pitch is limited to what the deck can do
        let far = AutoMixer.plan(a: a2, aRatio: 1, b: an(bpm: 160, key: cMaj, energy: 0.5), beats: 16)!
        expect(far.bRatio >= 0.84 && far.bRatio <= 1.16, "clamped to ±16 %: \(far.bRatio)")
        // half/double time
        expect(abs(AutoMixer.plan(a: a2, aRatio: 1, b: an(bpm: 62, key: cMaj, energy: 0.5), beats: 16)!.bRatio - 120.0 / 124) < 1e-9, "half-time tracks are doubled up")
        var none = b; none.bpm = nil
        expect(AutoMixer.plan(a: a2, aRatio: 1, b: none, beats: 16) == nil, "without a tempo there is nothing to plan")
        // very short tracks never start the blend before they begin
        let short = an(bpm: 120, key: cMaj, energy: 0.5, duration: 10)
        let ps = AutoMixer.plan(a: short, aRatio: 1, b: b, beats: 64)!
        expect(ps.aStart >= 0, "start is never negative: \(ps.aStart)")
    }

    func blendAutomation() {
        var prevA = 2.0, prevB = -1.0
        for i in 0...200 {
            let f = AutoMixer.frame(Double(i) / 200)
            expect(f.gainA <= prevA + 1e-12 && f.gainB >= prevB - 1e-12, "monotonic crossfade")
            expect(abs(f.gainA * f.gainA + f.gainB * f.gainB - 1) < 1e-9, "equal power throughout")
            prevA = f.gainA; prevB = f.gainB
            // the two basses never both play: when one is open the other is cut
            expect(f.lowA <= -26 + 1e-9 || f.lowB <= -26 + 1e-9 || (f.lowA < -1 && f.lowB < -1) || i >= 80 && i <= 120, "bass swap at \(i)")
        }
        let s = AutoMixer.frame(0), e = AutoMixer.frame(1)
        expect(s.gainA == 1 && s.gainB == 0 && s.lowA == 0 && s.lowB == -26 && s.filterA == 0, "starts on A with B's bass cut")
        expect(abs(e.gainB - 1) < 1e-12 && e.lowA == -26 && e.lowB == 0 && e.filterA > 0.5, "ends on B with the bass swapped")
        expect(AutoMixer.frame(-3) == s && AutoMixer.frame(9) == e && AutoMixer.frame(.nan) == s, "progress is clamped")
    }
}

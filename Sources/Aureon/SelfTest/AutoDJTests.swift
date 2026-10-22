import Foundation

/// The transition network that orders a smart shuffle (it used to drive Auto DJ too).
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
}

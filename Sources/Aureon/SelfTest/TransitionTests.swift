import Foundation

/// Transitions: the planner, the edge analysis, the mixer on its own, and end-to-end playback through the real Player into a
/// RecordingSink, so the delivered samples are checked exactly.
struct TransitionTests {
    let dir = tempDir("transitions")
    static let full24 = Double((1 << 23) - 1)

    // MARK: helpers

    /// 24-bit stereo file made of constant (DC) parts: (seconds, level as a fraction of full scale). Exact values make the mix checkable.
    func dc(_ name: String, rate: Int = 8000, _ parts: [(Double, Double)], folder: String? = nil) -> URL {
        var ends: [(Int, Int)] = [], at = 0
        for (sec, lvl) in parts { at += Int(sec * Double(rate)); ends.append((at, Int((lvl * Self.full24).rounded()))) }
        var d = dir
        if let folder { d = dir.appendingPathComponent(folder, isDirectory: true); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return writeWAV(d.appendingPathComponent(name), rate: rate, bits: 24, frames: at) { f, _ in ends.first { f < $0.0 }?.1 ?? 0 }
    }

    /// The Int32 sample a DC level becomes after decoding (24-bit, left-justified).
    func sample(_ lvl: Double) -> Int32 { Int32(Int((lvl * Self.full24).rounded())) << 8 }

    func settings(_ mode: TransitionMode = .crossfade, seconds: Double = 2, curve: TransitionCurve = .linear) -> TransitionSettings {
        var t = TransitionSettings()
        t.mode = mode; t.seconds = seconds; t.curve = curve
        t.skipSameAlbum = false; t.matchLevels = false; t.trimSilence = false
        return t
    }

    func make(_ t: TransitionSettings, speed: Double = 0) -> (Player, RecordingSink, PlayerOptions) {
        let sink = RecordingSink(speed: speed)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let p = Player()
        p.edges = EdgeCache(directory: tempDir("edges-\(UUID().uuidString.prefix(8))"))
        var s = p.settings; s.transition = t; p.settings = s
        return (p, sink, o)
    }

    func left(_ x: [Int32]) -> [Int32] { stride(from: 0, to: x.count, by: 2).map { x[$0] } }

    // MARK: planner

    func plannerRules() {
        let base = TransitionInput(rate: 1000, outgoingFrames: 100_000, incomingFrames: 100_000, outgoing: nil, incoming: nil)
        var s = settings(seconds: 6)
        let p = TransitionPlanner.plan(s, base)!
        expect(p.overlapFrames == 6000 && p.mixStart == 94_000 && p.incomingStart == 0 && p.incomingLevelDB == 0 && !p.holdOutgoing, "plain crossfade: \(p)")

        expect(TransitionPlanner.plan(settings(.off), base) == nil, "off plans nothing")

        var short = base; short.outgoingFrames = 10_000
        s.seconds = 12
        expect(TransitionPlanner.plan(s, short)?.overlapFrames == 4500, "the overlap never takes more than 45 % of a track")
        short.outgoingFrames = 1000
        expect(TransitionPlanner.plan(s, short) == nil, "a track too short for half a second of overlap stays gapless")

        func edge(lead: Double = 0, trail: Double = 0, head: Double? = nil, tail: Double? = nil, fade: Double? = nil) -> EdgeProfile {
            EdgeProfile(duration: 100, leadSilence: lead, trailSilence: trail, headLUFS: head, tailLUFS: tail, tailFadeSeconds: fade)
        }
        var trim = base; trim.outgoing = edge(trail: 2); trim.incoming = edge(lead: 1.5)
        s = settings(seconds: 6); s.trimSilence = true
        let t = TransitionPlanner.plan(s, trim)!
        expect(t.outgoingEnd == 98_000 && t.incomingStart == 1500 && t.mixStart == 92_000, "silence is trimmed at both ends: \(t)")
        s.trimSilence = false
        expect(TransitionPlanner.plan(s, trim)!.outgoingEnd == 100_000, "trimming is a setting")

        var lv = base; lv.outgoing = edge(tail: -30); lv.incoming = edge(head: -12)
        s = settings(seconds: 6); s.matchLevels = true; s.maxMatchDB = 6
        expect(TransitionPlanner.plan(s, lv)!.incomingLevelDB == -6, "a loud intro after a quiet ending starts turned down, by at most the limit")
        lv.outgoing = edge(tail: -12); lv.incoming = edge(head: -30)
        expect(TransitionPlanner.plan(s, lv)!.incomingLevelDB == 3, "a quiet intro is lifted by at most half the limit")
        lv.outgoing = edge(tail: -20); lv.incoming = edge(head: -21.5); lv.outgoingGainDB = -2; lv.incomingGainDB = -1
        expect(TransitionPlanner.plan(s, lv)!.incomingLevelDB == 0.5, "ReplayGain already applied is part of the comparison")
        lv.outgoingGainDB = 0; lv.incomingGainDB = 0; lv.incoming = edge(head: -20.3)
        expect(TransitionPlanner.plan(s, lv)!.incomingLevelDB == 0, "a difference under half a dB is left alone")
        s.matchLevels = false; lv.incoming = edge(head: -40)
        expect(TransitionPlanner.plan(s, lv)!.incomingLevelDB == 0, "matching is a setting")

        var fade = base; fade.outgoing = edge(fade: 3)
        s = settings(.smart, seconds: 6)
        let f = TransitionPlanner.plan(s, fade)!
        expect(f.holdOutgoing && f.overlapFrames == 3000, "smart: a song that fades out keeps its fade and the overlap fits inside it: \(f)")
        s.mode = .crossfade
        let c = TransitionPlanner.plan(s, fade)!
        expect(!c.holdOutgoing && c.overlapFrames == 6000, "crossfade mode ignores the fade-out")
    }

    func settingsDecodeFromOldSaves() {
        let data = try! JSONEncoder().encode(PlaybackSettings())
        var obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "transition")
        let old = try! JSONDecoder().decode(PlaybackSettings.self, from: try! JSONSerialization.data(withJSONObject: obj))
        expect(old.transition == TransitionSettings() && old.transition.mode == .off, "a save without transitions loads them off")
        let partial = try! JSONDecoder().decode(TransitionSettings.self, from: Data(#"{"mode":"smart"}"#.utf8))
        expect(partial.mode == .smart && partial.seconds == 6 && partial.matchLevels, "missing keys take their defaults")
        var a = PlaybackSettings(), b = a; b.transition.mode = .smart; b.transition.seconds = 9
        expect(a.streamKey == b.streamKey, "transition settings never rebuild the stream")
        a.transition.mode = .crossfade
        expect(a != b)
    }

    // MARK: edge analysis

    func edgeAnalysisFindsSilenceLoudnessAndFades() {
        let rate = 16_000, amp = 0.25 * Self.full24
        // 1.5 s silence, 20 s of 1 kHz at −12 dBFS peak, a 6 s fade of 40 dB, 3 s silence
        let lead = Int(1.5 * Double(rate)), body = 20 * rate, fadeLen = 6 * rate, tailSil = 3 * rate
        let faded = writeWAV(dir.appendingPathComponent("fade.wav"), rate: rate, bits: 24, frames: lead + body + fadeLen + tailSil) { f, _ in
            if f < lead || f >= lead + body + fadeLen { return 0 }
            var a = amp
            if f >= lead + body { a *= pow(10, -40.0 / 20 * Double(f - lead - body) / Double(fadeLen)) }
            return Int((a * sin(2 * .pi * 1000 * Double(f) / Double(rate))).rounded())
        }
        let flat = writeWAV(dir.appendingPathComponent("flat.wav"), rate: rate, bits: 24, frames: 25 * rate) { f, _ in
            Int((amp * sin(2 * .pi * 1000 * Double(f) / Double(rate))).rounded())
        }
        guard let p = EdgeAnalyzer.analyze(path: faded.path), let q = EdgeAnalyzer.analyze(path: flat.path) else { expect(false, "analysis failed"); return }
        expect(abs(p.leadSilence - 1.5) < 0.02, "leading silence \(p.leadSilence)")
        expect(abs(p.trailSilence - 3) < 0.02, "trailing silence \(p.trailSilence)")
        expect(p.tailFadeSeconds.map { $0 >= 4 && $0 <= 7 } == true, "fade-out found: \(String(describing: p.tailFadeSeconds))")
        expect(p.headLUFS != nil && p.tailLUFS != nil && p.tailLUFS! < p.headLUFS! - 5, "the faded ending measures quieter: \(String(describing: p.headLUFS)) / \(String(describing: p.tailLUFS))")
        expect(q.tailFadeSeconds == nil && q.leadSilence < 0.011 && q.trailSilence < 0.011, "a steady track has no fade and no silence: \(q)")
        expect(q.headLUFS != nil && q.tailLUFS != nil && abs(q.headLUFS! - q.tailLUFS!) < 0.3 && abs(q.headLUFS! - (p.headLUFS ?? 0)) < 0.3, "same tone, same loudness")

        let cache = EdgeCache(directory: tempDir("edges-cache"))
        expect(cache.cached(path: flat.path) == nil)
        cache.prefetch(paths: [flat.path]); cache.waitForPending()
        expect(cache.cached(path: flat.path) == q, "prefetch stores the analysis")
        let again = EdgeCache(directory: tempDir("edges-cache"))
        expect(again.cached(path: flat.path) == q, "it survives on disk")
        usleep(1_100_000)
        try! FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: flat.path)
        expect(again.cached(path: flat.path) == nil, "a changed file is analysed again")
    }

    // MARK: the mixer

    /// Two identical full-level sines summed with equal power reach +3 dB in the middle; the guard must keep every sample in range,
    /// only ever turn the mix down, and never step its gain.
    func mixerNeverClipsAndNeverSteps() {
        let a = sineWAV(dir.appendingPathComponent("ma.wav"), rate: 8000, freq: 500, amp: 0.9, seconds: 3)
        let b = sineWAV(dir.appendingPathComponent("mb.wav"), rate: 8000, freq: 500, amp: 0.9, seconds: 3)
        let fa = try! LosslessFile(path: a.path), fb = try! LosslessFile(path: b.path)
        fa.seek(to: 8000)
        let plan = TransitionPlan(rate: 8000, overlapFrames: 16_000, outgoingEnd: 24_000, incomingStart: 0, curve: .equalPower, holdOutgoing: false, incomingLevelDB: 0)
        let m = TransitionMixer(outgoing: fa, incoming: fb, plan: plan, info: fa.info)
        let out = readAll(m)
        expect(out.count == 16_000 * 2, "the mixer delivers exactly the overlap: \(out.count / 2)")
        expect(m.guardedBlocks > 0, "the middle of this overlap needs the guard")
        let ra = readAll(try! LosslessFile(path: a.path)), rb = readAll(try! LosslessFile(path: b.path))
        var prevG: Double? = nil, maxStep = 0.0, overshoot = 0.0, railRuns = 0
        for f in 0..<16_000 {
            let (ga, gb) = TransitionCurve.equalPower.gains((Double(f) + 0.5) / 16_000)
            let y = Double(ra[(8000 + f) * 2]) * ga + Double(rb[f * 2]) * gb
            let d = Double(out[f * 2])
            overshoot = max(overshoot, abs(d) - abs(y))
            if abs(y) > 0.2 * 2_147_483_648 {
                let g = d / y
                if let p = prevG { maxStep = max(maxStep, abs(g - p)) }
                prevG = g
            }
            if f > 0, abs(Int64(out[f * 2])) >= Int64(Int32.max), abs(Int64(out[(f - 1) * 2])) >= Int64(Int32.max) { railRuns += 1 }
        }
        expect(overshoot <= 2, "the guard only ever turns down: \(overshoot)")
        expect(maxStep < 0.01, "the guard's gain moves smoothly: largest step between samples \(maxStep)")
        expect(railRuns == 0, "no flat tops")
    }

    // MARK: end to end

    func crossfadeIsExactOutsideTheOverlap() {
        let a = dc("xa.wav", [(6, 0.2)]), b = dc("xb.wav", [(6, 0.6)])
        let (p, sink, o) = make(settings(seconds: 2))
        p.setQueue([a.path, b.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 15))
        let x = left(sink.samples)
        expect(x.count == 48_000 + 48_000 - 16_000, "length is A + B − overlap: \(x.count)")
        guard x.count == 80_000 else { return }
        let sa = sample(0.2), sb = sample(0.6)
        expect(x[0..<32_000].allSatisfy { $0 == sa }, "before the overlap the stream is A, bit for bit")
        expect(x[48_000...].allSatisfy { $0 == sb }, "after the overlap the stream is B, bit for bit")
        var worst: Int64 = 0
        for i in 0..<16_000 {
            let t = (Double(i) + 0.5) / 16_000
            let want = (Double(sa) * (1 - t) + Double(sb) * t).rounded()
            worst = max(worst, abs(Int64(x[32_000 + i]) - Int64(want)))
        }
        expect(worst <= 2, "the overlap follows the linear curve (worst error \(worst))")
        expect(sink.configured.count == 1, "one group, one device configuration")
    }

    func statusFollowsTheOverlap() {
        // 5 s each, so the 2 s overlap stays under the planner's 45 % share of a track and is not shortened
        let a = dc("sa.wav", [(5, 0.2)]), b = dc("sb.wav", [(5, 0.6)])
        let (p, _, o) = make(settings(seconds: 2), speed: 4)
        let q = p.setQueue([a.path, b.path]); p.start(options: o)
        var sawMixA = false, sawMixB = false, sawPlainA = false, opaque = true, note = false
        let end = Date().addingTimeInterval(10)
        while Date() < end && !p.status.finished {
            let s = p.status
            if s.mixingInto == q[1].id {
                if s.trackID == q[0].id { sawMixA = true }
                if s.trackID == q[1].id { sawMixB = true }
                opaque = opaque && !s.transparentStream && s.mixProgress != nil
                note = note || s.pipeline.contains { $0.hasPrefix("Crossfade 2.0 s") }
            } else if s.state == .playing && s.trackID == q[0].id && s.transparentStream { sawPlainA = true }
            usleep(5_000)
        }
        expect(sawPlainA, "A plays bit-transparent before the overlap")
        expect(sawMixA && sawMixB, "the audible track flips from A to B in the middle of the overlap (\(sawMixA), \(sawMixB))")
        expect(opaque, "while two tracks overlap the stream is reported as processed")
        expect(note, "the signal path names the crossfade")
        expect(p.status.mixingInto == nil)
    }

    func silenceIsTrimmed() {
        // A: 4 s of music then 2 s of digital silence; B: 1 s of silence then 4 s of music
        let a = dc("ta.wav", [(4, 0.3), (2, 0)]), b = dc("tb.wav", [(1, 0), (4, 0.5)])
        var t = settings(seconds: 1); t.trimSilence = true
        let (p, sink, o) = make(t)
        _ = p.edges.profile(path: a.path); _ = p.edges.profile(path: b.path)
        p.setQueue([a.path, b.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 15))
        let x = left(sink.samples)
        expect(x.count == 32_000 + 32_000 - 8000, "both silences are left out: \(x.count) frames")
        var run = 0, longest = 0
        for v in x { run = v == 0 ? run + 1 : 0; longest = max(longest, run) }
        expect(longest == 0, "no dead air between the songs (longest silence \(longest) frames)")
        expect(x.last == sample(0.5))
    }

    func albumsStayGapless() {
        let a = dc("aa.wav", [(3, 0.2)], folder: "album"), b = dc("ab.wav", [(3, 0.6)], folder: "album")
        var t = settings(seconds: 1); t.skipSameAlbum = true
        let (p, sink, o) = make(t)
        p.setQueue([a.path, b.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 15))
        let want = [Int32](repeating: sample(0.2), count: 24_000) + [Int32](repeating: sample(0.6), count: 24_000)
        expect(left(sink.samples) == want, "songs from one folder follow gapless, bit for bit")
    }

    func formatChangeStaysGapless() {
        let a = dc("fa.wav", rate: 8000, [(3, 0.2)]), b = dc("fb.wav", rate: 16_000, [(3, 0.6)])
        let (p, sink, o) = make(settings(seconds: 1))
        p.setQueue([a.path, b.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 15))
        let x = left(sink.samples)
        expect(sink.configured.map(\.sampleRate) == [8000, 16_000], "two groups: \(sink.configured.map(\.sampleRate))")
        expect(x.count == 24_000 + 48_000 && x[..<24_000].allSatisfy { $0 == sample(0.2) } && x[24_000...].allSatisfy { $0 == sample(0.6) },
               "a rate change is never crossfaded")
    }

    /// The overlap into B is already in the ring when B is removed: it must be undone, A's tail written again, and A blended into C.
    func removingTheNextTrackUndoesTheBufferedOverlap() {
        let a = dc("qa.wav", [(3, 0.1)]), b = dc("qb.wav", [(3, 0.5)]), c = dc("qc.wav", [(3, 0.3)])
        let (p, sink, o) = make(settings(seconds: 1), speed: 2)
        let q = p.setQueue([a.path, b.path, c.path]); p.start(options: o)
        let end = Date().addingTimeInterval(5)
        while sink.frameCount < 800 && Date() < end { usleep(2_000) }
        p.remove(ids: [q[1].id])
        expect(p.waitUntilFinished(timeout: 20))
        let x = left(sink.samples)
        expect(x.count == 24_000 + 24_000 - 8000, "A + C − overlap: \(x.count)")
        guard x.count == 40_000 else { return }
        let hi = sample(0.3)
        expect(x.allSatisfy { $0 <= hi }, "nothing of the removed track is heard")
        expect(x[..<16_000].allSatisfy { $0 == sample(0.1) } && x[24_000...].allSatisfy { $0 == hi }, "A, then C, exact outside the overlap")
        let mid = Double(x[20_000]), want = (Double(sample(0.1)) + Double(hi)) / 2
        expect(abs(mid - want) < 0.01 * Double(hi), "A is blended into C instead")
    }

    func seekDuringTheOverlapStaysConsistent() {
        let a = dc("ka.wav", [(4, 0.2)]), b = dc("kb.wav", [(4, 0.6)])
        let (p, sink, o) = make(settings(seconds: 2), speed: 2)
        let q = p.setQueue([a.path, b.path]); p.start(options: o)
        let end = Date().addingTimeInterval(10)
        while p.status.mixingInto == nil && Date() < end { usleep(2_000) }
        let heardWhenSeeking = p.status.trackID
        p.send(.seekTo(0.5))
        expect(p.waitUntilFinished(timeout: 20))
        let x = left(sink.samples)
        expect(heardWhenSeeking == q[0].id, "the overlap starts while A is heard")
        // after the seek A plays from 0.5 s (exact samples), and the transition into B happens again
        expect(x.last == sample(0.6) && x.contains(sample(0.2)), "playback carries on into B")
        let tail = x.suffix(16_000)
        expect(tail.allSatisfy { $0 == sample(0.6) }, "B's second half is exact after the repeated overlap")
    }
}

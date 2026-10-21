import Foundation

/// End-to-end tests: real files → real Player → RecordingSink (which consumes the ring like a DAC), so the exact
/// delivered sample stream can be inspected. No audio hardware is touched.
struct PlayerTests {
    let dir = tempDir("player")

    /// 24-bit stereo test track. Left = constant `id`, right = frame index: any dropped, repeated or reordered frame is visible.
    func track(_ name: String, id: Int, frames: Int, rate: Int = 8000) -> URL {
        writeWAV(dir.appendingPathComponent(name), rate: rate, bits: 24, frames: frames) { f, c in c == 0 ? id : f }
    }

    struct Segment { var id: Int; var ramp: [Int] }

    /// Splits delivered audio into runs of constant track id.
    func segments(_ x: [Int32]) -> [Segment] {
        var out: [Segment] = []
        for f in 0..<(x.count / 2) {
            let id = Int(x[f * 2] >> 8), r = Int(x[f * 2 + 1] >> 8)
            if out.last?.id != id { out.append(Segment(id: id, ramp: [])) }
            out[out.count - 1].ramp.append(r)
        }
        return out
    }
    func complete(_ s: Segment, _ n: Int) -> Bool { s.ramp.count == n && s.ramp == Array(0..<n) }

    func make(rates: [Double] = [], speed: Double = 0) -> (Player, RecordingSink, PlayerOptions) {
        let sink = RecordingSink(rates: rates, speed: speed)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        return (Player(), sink, o)
    }

    func waitFrames(_ sink: RecordingSink, _ n: Int, timeout: TimeInterval = 5) {
        let end = Date().addingTimeInterval(timeout)
        while sink.frameCount < n && Date() < end { usleep(2_000) }
    }

    // MARK: gapless & formats

    func gaplessIsBitExact() {
        let a = track("g1.wav", id: 1, frames: 20_000, rate: 44_100), b = track("g2.wav", id: 2, frames: 30_000, rate: 44_100), c = track("g3.wav", id: 3, frames: 10_000, rate: 44_100)
        let (p, sink, o) = make()
        p.setQueue([a, b, c].map(\.path)); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 15))
        var want: [Int32] = []
        for (id, n) in [(1, 20_000), (2, 30_000), (3, 10_000)] { for f in 0..<n { want += [Int32(id) << 8, Int32(f) << 8] } }
        expect(sink.samples == want, "delivered \(sink.frameCount) frames; stream differs from the concatenated sources")
        expect(sink.configured.count == 1, "same format must stay in one gapless group, got \(sink.configured.count)")
    }

    func flacDeliversExactSamples() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return }
        let wav = writeWAV(dir.appendingPathComponent("f.wav"), rate: 96_000, bits: 24, frames: 40_000) { f, c in (f * 7919 + c * 104729) % 8_000_000 - 4_000_000 }
        let flac = dir.appendingPathComponent("f.flac")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert"); p.arguments = ["-f", "flac", "-d", "flac", wav.path, flac.path]
        try! p.run(); p.waitUntilExit()
        let (pl, sink, o) = make()
        pl.setQueue([flac.path]); pl.start(options: o)
        expect(pl.waitUntilFinished(timeout: 15))
        expect(sink.samples == readAll(try! LosslessFile(path: wav.path)), "FLAC playback must be bit-identical to the original PCM")
        expect(sink.configured.first?.codec == "FLAC" && sink.configured.first?.sourceBits == 24)
    }

    func formatChangeStartsNewGroup() {
        let a = track("c1.wav", id: 1, frames: 8_000, rate: 44_100), b = track("c2.wav", id: 2, frames: 8_000, rate: 48_000), c = track("c3.wav", id: 3, frames: 8_000, rate: 48_000)
        let (p, sink, o) = make()
        p.setQueue([a, b, c].map(\.path)); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 15))
        expect(sink.configured.map(\.sampleRate) == [44_100, 48_000], "rates \(sink.configured.map(\.sampleRate))")
        let s = segments(sink.samples)
        expect(s.map(\.id) == [1, 2, 3] && s.allSatisfy { complete($0, 8_000) }, "segments \(s.map { ($0.id, $0.ramp.count) })")
    }

    func unreadableFileIsSkipped() {
        let good = track("ok.wav", id: 5, frames: 4_000)
        let bad = dir.appendingPathComponent("missing.flac")
        let (p, sink, o) = make()
        p.setQueue([bad.path, good.path, bad.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 10))
        let s = segments(sink.samples)
        expect(s.count == 1 && s[0].id == 5 && complete(s[0], 4_000), "good track must play completely")
        expect(!p.status.errors.isEmpty, "the skipped file must be reported")
    }

    // MARK: transport

    func pauseHoldsAndResumes() {
        let t = track("p.wav", id: 1, frames: 80_000)           // 10 s
        let (p, sink, o) = make(speed: 8)
        p.setQueue([t.path]); p.start(options: o)
        waitFrames(sink, 4_000)
        p.send(.setPaused(true)); usleep(150_000)
        let c1 = sink.frameCount; usleep(400_000)
        expect(sink.frameCount == c1, "no audio may be delivered while paused (\(c1) → \(sink.frameCount))")
        expect(p.status.state == .paused)
        p.send(.setPaused(false)); usleep(300_000)
        expect(sink.frameCount > c1, "playback must resume")
        expect(p.waitUntilFinished(timeout: 20))
        expect(complete(segments(sink.samples)[0], 80_000), "pausing must not lose or repeat a frame")
    }

    func seekRepositionsAndPositionTracks() {
        let t = track("s.wav", id: 1, frames: 80_000)
        let (p, sink, o) = make(speed: 8)
        p.setQueue([t.path]); p.start(options: o)
        waitFrames(sink, 4_000)
        p.send(.seekTo(7.0)); usleep(400_000)
        let st = p.status
        expect(st.position >= 6.9 && st.position < 9.9, "status position \(st.position) after seeking to 7 s")
        expect(p.waitUntilFinished(timeout: 20))
        let r = segments(sink.samples)[0].ramp
        expect(r.contains(56_000), "first frame after the seek must be exactly frame 56000")
        let i = r.firstIndex(of: 56_000)!
        expect(Array(r[i...]) == Array(56_000..<80_000), "after the seek playback is continuous to the end")
        expect(r.last == 79_999)
    }

    func nextAndJumpRestartAtTheRightTrack() {
        let ts = (1...3).map { track("n\($0).wav", id: $0, frames: 16_000) }
        let (p, sink, o) = make(speed: 2)
        let q = p.setQueue(ts.map(\.path)); p.start(options: o)
        waitFrames(sink, 1_500)
        p.send(.next); usleep(300_000)
        expect(p.status.trackIndex == 1, "next moved to \(p.status.trackIndex)")
        p.send(.jump(q[0].id)); usleep(300_000)
        expect(p.status.trackIndex == 0, "jump moved to \(p.status.trackIndex)")
        p.send(.stop)
        expect(p.waitUntilFinished(timeout: 5))
    }

    // MARK: live queue editing

    /// At 8 kHz the 5 s ring holds ~2.5 tracks, so upcoming tracks are already buffered when we edit.
    func editHarness(_ n: Int = 3) -> (Player, RecordingSink, [QueueEntry], PlayerOptions) {
        let (p, sink, o) = make(speed: 2)
        let q = p.setQueue((1...n).map { track("q\($0).wav", id: $0, frames: 16_000).path })
        return (p, sink, q, o)
    }

    func removeBufferedUpcomingTrack() {
        let (p, sink, q, o) = editHarness()
        p.start(options: o); waitFrames(sink, 2_000)
        p.remove(ids: [q[1].id])
        expect(p.waitUntilFinished(timeout: 20))
        let s = segments(sink.samples)
        expect(s.map(\.id) == [1, 3] && s.allSatisfy { complete($0, 16_000) }, "got \(s.map { ($0.id, $0.ramp.count) }); the audible track must be untouched")
    }

    func reorderBufferedUpcomingTracks() {
        let (p, sink, q, o) = editHarness()
        p.start(options: o); waitFrames(sink, 2_000)
        p.move(from: IndexSet(integer: 2), to: 1)                  // [1,2,3] → [1,3,2]
        expect(p.queue.map(\.id) == [q[0].id, q[2].id, q[1].id])
        expect(p.waitUntilFinished(timeout: 20))
        let s = segments(sink.samples)
        expect(s.map(\.id) == [1, 3, 2] && s.allSatisfy { complete($0, 16_000) }, "got \(s.map { ($0.id, $0.ramp.count) })")
    }

    func insertAndAppendWhilePlaying() {
        let (p, sink, _, o) = editHarness()
        p.start(options: o); waitFrames(sink, 2_000)
        p.insert([track("q9.wav", id: 9, frames: 16_000).path], at: 1)
        p.append([track("q8.wav", id: 8, frames: 16_000).path])
        expect(p.waitUntilFinished(timeout: 30))
        let s = segments(sink.samples)
        expect(s.map(\.id) == [1, 9, 2, 3, 8] && s.allSatisfy { complete($0, 16_000) }, "got \(s.map { ($0.id, $0.ramp.count) })")
    }

    func removeThePlayingTrackAdvances() {
        let (p, sink, q, o) = editHarness()
        p.start(options: o); waitFrames(sink, 2_000)
        p.remove(ids: [q[0].id])
        expect(p.waitUntilFinished(timeout: 20))
        let s = segments(sink.samples)
        expect(s.map(\.id) == [1, 2, 3], "got \(s.map(\.id))")
        expect(s[0].ramp.count < 16_000 && s[0].ramp == Array(0..<s[0].ramp.count), "removed track stops where it was, without glitches")
        expect(complete(s[1], 16_000) && complete(s[2], 16_000))
    }

    func clearingTheQueueStops() {
        let (p, sink, _, o) = editHarness()
        p.start(options: o); waitFrames(sink, 2_000)
        p.clearQueue()
        expect(p.waitUntilFinished(timeout: 10), "an emptied queue must end playback")
    }

    // MARK: memory playback

    func ramPlaybackIsIdenticalAndStopsDiskReads() {
        let t = writeWAV(dir.appendingPathComponent("ram.wav"), rate: 44_100, bits: 24, frames: 220_500) { f, c in (f * 4099 + c * 77) % 6_000_000 - 3_000_000 }
        let (d, dsink, o1) = make()
        d.setQueue([t.path]); d.start(options: o1)
        expect(d.waitUntilFinished(timeout: 20))

        let (p, sink, o2) = make(speed: 8)
        var s = PlaybackSettings(); s.ram.enabled = true
        p.settings = s
        p.setQueue([t.path]); p.start(options: o2)
        let end = Date().addingTimeInterval(10)
        while !(p.status.state == .playing && p.status.ramBytes > 0) && Date() < end { usleep(2_000) }
        expect(p.status.ramBytes == 220_500 * 8, "track must be fully in RAM before playback (\(p.status.ramBytes) bytes)")
        expect(p.status.pipeline.contains { $0.hasPrefix("RAM") })
        let before = DiskStats.readCalls
        expect(p.waitUntilFinished(timeout: 20))
        expect(DiskStats.readCalls == before, "disk reads during RAM playback: \(DiskStats.readCalls - before)")
        expect(sink.samples == dsink.samples && !sink.samples.isEmpty, "RAM playback must deliver exactly the same samples as disk playback")
    }

    func ramPrefetchesTheNextTrack() {
        let a = track("pa.wav", id: 1, frames: 40_000, rate: 8000), b = track("pb.wav", id: 2, frames: 40_000, rate: 8000)
        let (p, sink, o) = make(speed: 4)
        var s = PlaybackSettings(); s.ram.enabled = true
        p.settings = s
        p.setQueue([a.path, b.path]); p.start(options: o)
        let end = Date().addingTimeInterval(10)
        while p.cache.usedBytes < 2 * 40_000 * 8 && Date() < end { usleep(5_000) }
        expect(p.cache.usedBytes == 2 * 40_000 * 8, "both tracks should be resident, have \(p.cache.usedBytes) bytes")
        expect(p.waitUntilFinished(timeout: 20))
        let seg = segments(sink.samples)
        expect(seg.map(\.id) == [1, 2] && seg.allSatisfy { complete($0, 40_000) })
    }

    // MARK: processing stages

    func upsamplingReachesTheDeviceMaximum() {
        let t = sineWAV(dir.appendingPathComponent("up.wav"), rate: 44_100, freq: 1000, amp: 0.5, seconds: 1.0)
        let (p, sink, o) = make(rates: [44_100, 88_200, 176_400, 192_000])
        var s = PlaybackSettings(); s.upsampling.mode = .deviceMax
        p.settings = s; p.setQueue([t.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 20))
        expect(sink.configured.first?.sampleRate == 176_400, "device was asked for \(String(describing: sink.configured.first?.sampleRate))")
        expect(sink.frameCount == 176_400, "frames \(sink.frameCount)")
        let a = amplitude(sink.samples, channels: 2, rate: 176_400, freq: 1000, skip: 8000, count: 100_000)
        expect(abs(db(a / 0.5)) < 0.01, "level error \(db(a / 0.5)) dB")
        expect(sink.configured.first?.transparent == false && p.status.bitPerfect == false, "resampled audio must not be reported as bit-perfect")
    }

    func unsupportedRateIsBroughtDownByUs() {
        let t = sineWAV(dir.appendingPathComponent("down.wav"), rate: 96_000, freq: 1000, amp: 0.5, seconds: 1.0)
        let (p, sink, o) = make(rates: [44_100, 48_000])
        p.setQueue([t.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 20))
        expect(sink.configured.first?.sampleRate == 48_000, "got \(String(describing: sink.configured.first?.sampleRate))")
        expect(sink.frameCount == 48_000)
    }

    func nativeRateStaysBitPerfect() {
        let t = sineWAV(dir.appendingPathComponent("native.wav"), rate: 44_100, freq: 1000, amp: 0.5, seconds: 0.5)
        let (p, sink, o) = make(rates: [44_100, 88_200])
        p.setQueue([t.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 20))
        expect(sink.samples == readAll(try! LosslessFile(path: t.path)))
    }

    func replayGainLevelsUntaggedFiles() {
        let t = sineWAV(dir.appendingPathComponent("rg.wav"), rate: 44_100, freq: 997, amp: 0.1, seconds: 6)
        let (p, sink, o) = make()
        var s = PlaybackSettings(); s.replayGain.mode = .track
        p.settings = s; p.setQueue([t.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 30))
        let a = amplitude(sink.samples, channels: 2, rate: 44_100, freq: 997, skip: 20_000, count: 200_000)
        expect(abs(db(a / 0.1) - 2.0) < 0.15, "applied \(db(a / 0.1)) dB, wanted +2 dB (−20 → −18 LUFS)")
    }

    func polarityInversionNegatesSamples() {
        let t = sineWAV(dir.appendingPathComponent("pol.wav"), rate: 44_100, freq: 440, amp: 0.4, seconds: 0.5)
        let (p, sink, o) = make()
        var s = PlaybackSettings(); s.polarityInverted = true
        p.settings = s; p.setQueue([t.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 10))
        let orig = readAll(try! LosslessFile(path: t.path))
        expect(sink.samples == orig.map { $0 == .min ? .max : -$0 })
    }

    func settingsChangeAppliesWithoutLosingPlace() {
        let t = sineWAV(dir.appendingPathComponent("live.wav"), rate: 8_000, freq: 440, amp: 0.4, seconds: 10)
        let (p, sink, o) = make(speed: 4)
        p.setQueue([t.path]); p.start(options: o)
        waitFrames(sink, 6_000)
        var s = PlaybackSettings(); s.polarityInverted = true
        p.settings = s
        expect(p.waitUntilFinished(timeout: 20))
        expect(abs(sink.frameCount - 80_000) < 6_000, "frames delivered \(sink.frameCount)")
        let orig = readAll(try! LosslessFile(path: t.path))
        // tail of the delivered stream is the negated tail of the file: playback resumed at the same position
        let n = 20_000 * 2
        let tail = Array(sink.samples.suffix(n)), want = Array(orig.suffix(n)).map { $0 == .min ? Int32.max : -$0 }
        expect(tail == want, "after the change the stream continues, inverted, from the same position")
    }

    // MARK: DSD through the player

    func dsdPlaysAsDoPWithContinuousMarkers() {
        let d = DSDTests()
        let f1 = dir.appendingPathComponent("p1.dsf"), f2 = dir.appendingPathComponent("p2.dsf")
        let c1 = d.channels(seed: 1), c2 = d.channels(seed: 2)
        writeDSF(f1, rate: d.rate, channelBytes: c1); writeDSF(f2, rate: d.rate, channelBytes: c2)
        let (p, sink, o) = make(rates: [44_100, 176_400])
        var s = PlaybackSettings(); s.dsd.mode = .dop; s.replayGain.mode = .track; s.polarityInverted = true; s.upsampling.mode = .deviceMax
        p.settings = s; p.setQueue([f1.path, f2.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 20))
        expect(sink.configured.count == 1 && sink.configured[0].isDoP && sink.configured[0].sampleRate == 176_400, "\(sink.configured)")
        let x = sink.samples, frames = x.count / 2
        expect(frames == c1[0].count / 2 + c2[0].count / 2, "frames \(frames)")
        var wrong = 0
        for f in 0..<frames {
            let w = UInt32(bitPattern: x[f * 2])
            if UInt8(w >> 24) != (f % 2 == 0 ? 0x05 : 0xFA) { wrong += 1 }
            let first = f < c1[0].count / 2, i = first ? f : f - c1[0].count / 2, src = first ? c1 : c2
            if UInt8((w >> 16) & 255) != src[0][2 * i] || UInt8((w >> 8) & 255) != src[0][2 * i + 1] { wrong += 1 }
        }
        expect(wrong == 0, "\(wrong) DoP words wrong; DSD bits must pass untouched, even with gain/polarity/upsampling enabled")
        expect(p.status.bitPerfect || p.status.transparentStream, "DoP stream stays transparent")
    }

    func dsdFallsBackToPcmWhenDeviceCannotDoP() {
        let d = DSDTests()
        let f = dir.appendingPathComponent("fb.dsf"); writeDSF(f, rate: d.rate, channelBytes: d.channels())
        let (p, sink, o) = make(rates: [44_100, 88_200])
        var s = PlaybackSettings(); s.dsd.mode = .dop
        p.settings = s; p.setQueue([f.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 20))
        expect(sink.configured.first?.isDoP == false && sink.configured.first?.sampleRate == 88_200, "\(String(describing: sink.configured.first))")
    }
}

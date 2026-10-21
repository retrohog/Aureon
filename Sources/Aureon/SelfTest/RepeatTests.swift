import Foundation

struct RepeatTests {
    let dir = tempDir("repeat")

    private func tone(_ name: String, freq: Double, seconds: Double) -> URL { sineWAV(dir.appendingPathComponent(name), rate: 44_100, bits: 16, freq: freq, amp: 0.4, seconds: seconds, channels: 2) }

    private func run(_ files: [URL], mode: RepeatMode, seconds: Double, then: ((Player) -> Void)? = nil) -> (Player, RecordingSink) {
        let sink = RecordingSink(speed: 8)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.2; o.rateSwitch = false
        let p = Player(); p.repeatMode = mode
        p.setQueue(files.map(\.path)); p.start(options: o)
        let end = Date().addingTimeInterval(20)
        while Double(sink.frameCount) < seconds * 44_100 && Date() < end { usleep(5_000); then?(p) }
        return (p, sink)
    }

    func repeatOffEnds() {
        let a = tone("a.wav", freq: 500, seconds: 0.5), b = tone("b.wav", freq: 900, seconds: 0.5)
        let sink = RecordingSink(speed: 0)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.2; o.rateSwitch = false
        let p = Player(); p.setQueue([a.path, b.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 10) && abs(Double(sink.frameCount) - 44_100) < 600, "without repeat the queue plays once: \(sink.frameCount)")
    }

    func repeatAllWrapsAround() {
        let a = tone("ra.wav", freq: 500, seconds: 0.5), b = tone("rb.wav", freq: 900, seconds: 0.5)
        let (p, sink) = run([a, b], mode: .all, seconds: 3.0)
        p.send(.stop); _ = p.waitUntilFinished(timeout: 5)
        expect(sink.frameCount >= 3 * 44_100, "kept playing past the end of the queue: \(sink.frameCount)")
        let x = sink.samples
        // the first second is A then B; the next second must be A then B again
        let a1 = amplitude(x, channels: 2, rate: 44_100, freq: 500, skip: 4_000, count: 15_000), a2 = amplitude(x, channels: 2, rate: 44_100, freq: 500, skip: 44_100 + 4_000, count: 15_000)
        let b2 = amplitude(x, channels: 2, rate: 44_100, freq: 900, skip: 44_100 + 26_000, count: 15_000)
        expect(a1 > 0.3 && a2 > 0.3 && b2 > 0.3, "A B A B: \(a1) \(a2) \(b2)")
    }

    func repeatOneStaysOnTheTrack() {
        let a = tone("oa.wav", freq: 500, seconds: 0.5), b = tone("ob.wav", freq: 900, seconds: 0.5)
        let (p, sink) = run([a, b], mode: .one, seconds: 2.5)
        let x = sink.samples
        let b1 = amplitude(x, channels: 2, rate: 44_100, freq: 900, skip: 0, count: x.count / 2)
        expect(b1 < 0.02, "the second track never starts: \(b1)")
        p.repeatMode = .off
        p.send(.next)
        let end = Date().addingTimeInterval(6)
        while p.status.trackIndex < 1 && Date() < end { usleep(5_000) }
        expect(p.status.trackIndex == 1 || p.status.finished, "Next still moves on")
        p.send(.stop); _ = p.waitUntilFinished(timeout: 5)
    }

    func reorderingTheQueue() {
        let p = Player()
        let es = p.setQueue(["/a", "/b", "/c", "/d"])
        p.setOrder([es[2].id, es[0].id])
        expect(p.queue.map(\.path) == ["/c", "/a", "/b", "/d"], "\(p.queue.map(\.path))")
        let v = p.queueRevision
        p.setOrder(p.queue.map(\.id))
        expect(p.queueRevision == v, "an identical order is not an edit")
        p.setOrder([UUID(), es[3].id])
        expect(p.queue.map(\.path) == ["/d", "/c", "/a", "/b"], "unknown ids are ignored: \(p.queue.map(\.path))")
    }
}

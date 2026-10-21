import Foundation
import Synchronization

struct RingTests {
    final class Flag: @unchecked Sendable { let on = Atomic<Bool>(true) }

    /// Stand-in for the real-time callback: acknowledges requests by calling read().
    func startConsumer(_ ring: RingBuffer, flag: Flag) {
        Thread {
            var d = [Int32](repeating: 0, count: 8)
            while flag.on.load(ordering: .relaxed) { _ = ring.read(into: &d, frames: 0); usleep(100) }
        }.start()
    }

    func writeReadRoundTrip() {
        let ring = RingBuffer(frames: 64, channels: 2)
        let src: [Int32] = (0..<40).map { Int32($0) }
        expect(ring.write(src, frames: 20) == 20)
        var out = [Int32](repeating: 0, count: 40)
        expect(ring.read(into: &out, frames: 30) == 20)
        expect(Array(out) == src)
        expect(ring.availableToRead == 0)
    }

    func wrapAround() {
        let ring = RingBuffer(frames: 8, channels: 1)
        var out = [Int32](repeating: 0, count: 8)
        var next: Int32 = 0
        for _ in 0..<50 {
            let chunk: [Int32] = (0..<5).map { _ in defer { next += 1 }; return next }
            expect(ring.write(chunk, frames: 5) == 5)
            expect(ring.read(into: &out, frames: 5) == 5)
            expect(Array(out[0..<5]) == chunk)
        }
    }

    func truncateDropsOnlyTheTail() {
        let ring = RingBuffer(frames: 4096, channels: 1)
        let flag = Flag(); startConsumer(ring, flag: flag); defer { flag.on.store(false, ordering: .relaxed) }
        let a: [Int32] = (0..<1000).map { Int32($0) }
        _ = ring.write(a, frames: 1000)
        expect(ring.truncate(to: 500))
        expect(ring.availableToRead == 500)
        let b: [Int32] = (5000..<5100).map { Int32($0) }
        _ = ring.write(b, frames: 100)
        var out = [Int32](repeating: 0, count: 700)
        expect(ring.read(into: &out, frames: 700) == 600)
        expect(Array(out[0..<500]) == Array(a[0..<500]))
        expect(Array(out[500..<600]) == b)
    }

    func truncateRefusedWhenAlreadyPlayed() {
        let ring = RingBuffer(frames: 4096, channels: 1)
        let flag = Flag(); startConsumer(ring, flag: flag); defer { flag.on.store(false, ordering: .relaxed) }
        let a: [Int32] = (0..<1000).map { Int32($0) }
        _ = ring.write(a, frames: 1000)
        var out = [Int32](repeating: 0, count: 600)
        _ = ring.read(into: &out, frames: 600)
        expect(!ring.truncate(to: 500))
        expect(ring.availableToRead == 400)       // nothing changed
    }

    func flushDiscardsEverything() {
        let ring = RingBuffer(frames: 256, channels: 2)
        let flag = Flag(); startConsumer(ring, flag: flag); defer { flag.on.store(false, ordering: .relaxed) }
        let a = [Int32](repeating: 7, count: 200)
        _ = ring.write(a, frames: 100)
        ring.flush()
        expect(ring.availableToRead == 0)
        expect(ring.totalConsumed == ring.totalWritten)
    }

    /// Hammer the ring from two threads and check every sample arrives once, in order.
    func concurrentProducerConsumerKeepsOrder() {
        let ring = RingBuffer(frames: 1024, channels: 1)
        let total = 400_000
        let ok = Atomic<Bool>(true)
        let done = DispatchSemaphore(value: 0)
        Thread {
            var out = [Int32](repeating: 0, count: 256), expect: Int32 = 0
            while Int(expect) < total {
                let n = ring.read(into: &out, frames: 256)
                for i in 0..<n { if out[i] != expect { ok.store(false, ordering: .relaxed) }; expect += 1 }
                if n == 0 { usleep(20) }
            }
            done.signal()
        }.start()
        var v: Int32 = 0
        var chunk = [Int32](repeating: 0, count: 100)
        while Int(v) < total {
            for i in 0..<100 { chunk[i] = v + Int32(i) }
            let n = ring.write(chunk, frames: min(100, total - Int(v)))
            v += Int32(n)
            if n < 100 { usleep(20); v -= Int32(n); v += Int32(n) }   // partial writes advance by n; re-offer the rest next loop
            if n == 0 { continue }
        }
        expect(done.wait(timeout: .now() + 20) == .success)
        expect(ok.load(ordering: .relaxed))
    }
}

import Foundation
import Synchronization

/// The only thing the audio thread does for the visualisers: copy the frames it just rendered into a lock-free ring.
/// All FFT, metering and drawing work happens on other threads. If the analysis side falls behind, frames are dropped —
/// the audio thread never waits.
final class AnalysisTap: @unchecked Sendable {
    let capacity = 1 << 17                          // frames (~3 s at 44.1 kHz)
    private let data: UnsafeMutablePointer<Float>   // interleaved L, R
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    /// Copying is skipped entirely while nothing is looking.
    let enabled = Atomic<Bool>(false)
    let sampleRate = Atomic<Int>(44_100)
    let dropped = Counter()

    init() { data = .allocate(capacity: capacity * 2); data.initialize(repeating: 0, count: capacity * 2) }
    deinit { data.deallocate() }

    /// Real-time safe.
    @inline(__always)
    func write(_ src: UnsafePointer<Int32>, frames: Int, channels: Int) {
        guard enabled.load(ordering: .relaxed) else { return }
        let w = written.load(ordering: .relaxed), c = consumed.load(ordering: .acquiring)
        let n = min(frames, capacity - (w - c))
        if n < frames { _ = dropped.n.add(frames - n, ordering: .relaxed) }
        let scale: Float = 1.0 / 2_147_483_648.0
        for i in 0..<n {
            let l = Float(src[i * channels]) * scale
            let r = channels > 1 ? Float(src[i * channels + 1]) * scale : l
            let d = ((w + i) & (capacity - 1)) * 2
            data[d] = l; data[d + 1] = r
        }
        written.store(w + n, ordering: .releasing)
    }

    var available: Int { written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring) }

    /// Analysis thread: copies up to `maxFrames` interleaved L/R frames, returns how many.
    func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let c = consumed.load(ordering: .relaxed)
        let n = min(maxFrames, written.load(ordering: .acquiring) - c)
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let s = ((c + i) & (capacity - 1)) * 2
            dst[i * 2] = data[s]; dst[i * 2 + 1] = data[s + 1]
        }
        consumed.store(c + n, ordering: .releasing)
        return n
    }

    /// Drop anything buffered (used when the visualiser is first shown, so it starts from "now").
    func discard() { consumed.store(written.load(ordering: .acquiring), ordering: .releasing) }
}

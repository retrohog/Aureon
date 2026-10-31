import Foundation

/// Lock-free single-producer / single-consumer ring of interleaved Int32 frames.
/// Producer = decode thread. Consumer = the real-time render callback (no locks, no allocation).
///
/// Besides plain write/read the ring supports two producer→consumer requests that are executed by the
/// consumer, so the consumer never races with the producer:
///   • flush     — drop everything buffered (used by seek and settings changes)
///   • truncate  — drop only the tail beyond an absolute frame (used when the queue is edited while
///                 the next track is already buffered: the audible track keeps playing untouched)
final class RingBuffer: @unchecked Sendable {
    let capacity: Int, channels: Int
    private let data: UnsafeMutablePointer<Int32>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let truncateTarget = Atomic<Int>(-1)
    private let readLimit = Atomic<Int>(Int.max)

    /// Set by the UI/engine thread; the consumer outputs silence and stops consuming while true.
    let paused = Atomic<Bool>(false)
    let flushRequested = Atomic<Bool>(false)
    /// True while the ring is intentionally not delivering audio (paused / seeking): not an underrun.
    var intentionallySilent: Bool { paused.load(ordering: .relaxed) || flushRequested.load(ordering: .relaxed) }

    init(frames: Int, channels: Int) {
        capacity = frames; self.channels = channels
        data = .allocate(capacity: frames * channels)
        data.initialize(repeating: 0, count: frames * channels)
    }
    deinit { data.deallocate() }

    /// Monotonic frame counters, used to map "what is audible now" back to a track.
    var totalWritten: Int { written.load(ordering: .acquiring) }
    var totalConsumed: Int { consumed.load(ordering: .acquiring) }

    // `limit` is loaded before `written`: the producer lowers `written` first and lifts the limit second.
    private func readable(_ r: Int) -> Int {
        let lim = readLimit.load(ordering: .acquiring)
        return max(0, min(written.load(ordering: .acquiring), lim) - r)
    }

    var availableToRead: Int { readable(consumed.load(ordering: .acquiring)) }
    var availableToWrite: Int { capacity - (written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring)) }

    func write(_ src: UnsafePointer<Int32>, frames: Int) -> Int {
        let n = min(frames, availableToWrite)
        let w = written.load(ordering: .relaxed)
        for i in 0..<n {
            let dst = ((w + i) % capacity) * channels
            for c in 0..<channels { data[dst + c] = src[i * channels + c] }
        }
        written.store(w + n, ordering: .releasing)
        return n
    }

    /// Real-time safe. Returns frames copied (the caller zero-fills the rest).
    func read(into dst: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        // Acknowledge a truncate request first, so it completes even while paused.
        let tt = truncateTarget.load(ordering: .acquiring)
        if tt >= 0 {
            readLimit.store(tt, ordering: .releasing)
            truncateTarget.store(-1, ordering: .releasing)
        }
        if flushRequested.load(ordering: .acquiring) {
            consumed.store(max(consumed.load(ordering: .relaxed), min(written.load(ordering: .acquiring), readLimit.load(ordering: .acquiring))), ordering: .releasing)
            flushRequested.store(false, ordering: .releasing)
            return 0
        }
        if paused.load(ordering: .relaxed) { return 0 }
        let r = consumed.load(ordering: .relaxed)
        let n = min(frames, readable(r))
        for i in 0..<n {
            let s = ((r + i) % capacity) * channels
            for c in 0..<channels { dst[i * channels + c] = data[s + c] }
        }
        consumed.store(r + n, ordering: .releasing)
        return n
    }

    /// Producer side: discards everything buffered. Returns once the consumer executed it (or after a timeout).
    func flush(timeoutMs: Int = 400) {
        flushRequested.store(true, ordering: .releasing)
        var waited = 0
        while flushRequested.load(ordering: .acquiring) && waited < timeoutMs * 2 { usleep(500); waited += 1 }
        if flushRequested.load(ordering: .acquiring) {   // consumer not running: do it ourselves
            flushRequested.store(false, ordering: .releasing)
            consumed.store(written.load(ordering: .acquiring), ordering: .releasing)
        }
    }

    /// Producer side: drops everything at or after absolute frame `frame` without disturbing audio before it.
    /// Returns false when that audio was already consumed (or the consumer did not respond); nothing changes then.
    func truncate(to frame: Int, timeoutMs: Int = 200) -> Bool {
        guard frame >= totalConsumed else { return false }
        truncateTarget.store(frame, ordering: .releasing)
        var waited = 0
        while truncateTarget.load(ordering: .acquiring) >= 0 && waited < timeoutMs * 2 { usleep(500); waited += 1 }
        if truncateTarget.load(ordering: .acquiring) >= 0 {
            // No consumer is running. Cancel the request; if the consumer acknowledged meanwhile, carry on.
            if truncateTarget.compareExchange(expected: frame, desired: -1, ordering: .acquiringAndReleasing).exchanged {
                // Safe to edit directly: nobody consumes.
                guard frame >= totalConsumed else { return false }
                written.store(frame, ordering: .releasing)
                return true
            }
        }
        guard totalConsumed <= frame else { readLimit.store(Int.max, ordering: .releasing); return false }
        written.store(frame, ordering: .releasing)       // lower `written` first …
        readLimit.store(Int.max, ordering: .releasing)   // … then lift the limit
        return true
    }
}

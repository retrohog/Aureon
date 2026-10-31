import Foundation

/// Waveform-similarity overlap-add (WSOLA): changes how long a stream takes without changing its pitch. It cuts the input into Hann-windowed grains,
/// places them at a fixed output hop, and chooses each grain's exact start (within a small search range) where it continues the previous grain most
/// smoothly, so the waves line up and no clicks or flutter appear. A stretch of 1.0 is the original speed; 1.1 consumes the input 10 % faster.
///
/// This runs on the decode thread (the producer side of the deck), never inside a Core Audio callback, so it may use ordinary arrays.
final class TimeStretcher {
    let channels: Int
    private let n: Int                  // grain length
    private let hop: Int                // output hop (half a grain)
    private let search: Int             // how far a grain may move from its nominal start, either way
    private let window: [Float]
    private var input: [Float] = []     // interleaved frames [inStart, inStart + count)
    private var inStart = 0
    private var inEnd: Int { inStart + input.count / channels }
    private var pos = 0.0               // nominal start of the next grain
    private var previous: Int?          // where the last grain started
    private var overlap: [Float]        // the second half of the last grain, still waiting for the next one
    private var ready: [Float] = []     // finished output, interleaved
    private var readyHead = 0
    private var ended = false
    private let pullChunk = 2048
    private var pulled: [Float]

    init(channels: Int, grain: Int = 2048) {
        self.channels = max(1, channels); n = grain; hop = grain / 2; search = grain / 5
        window = (0..<grain).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(grain))) }
        overlap = [Float](repeating: 0, count: grain * max(1, channels))
        pulled = [Float](repeating: 0, count: 2048 * max(1, channels))
        input.reserveCapacity(grain * 8 * max(1, channels))
    }

    func reset() {
        input.removeAll(keepingCapacity: true); inStart = 0; pos = 0; previous = nil; ended = false
        for i in overlap.indices { overlap[i] = 0 }
        ready.removeAll(keepingCapacity: true); readyHead = 0
    }

    /// Fills `out` (interleaved) with up to `frames` frames. `pull` supplies the input: it writes interleaved frames to its first argument (at most the
    /// second argument) and returns how many, 0 at the end. Returns the number of frames produced (fewer than asked only at the end of the input).
    func render(into out: UnsafeMutablePointer<Float>, frames: Int, stretch: Double, pull: (UnsafeMutablePointer<Float>, Int) -> Int) -> Int {
        let s = max(0.25, min(4, stretch.isFinite ? stretch : 1))
        var produced = 0
        while produced < frames {
            let available = ready.count / channels - readyHead
            if available > 0 {
                let take = min(available, frames - produced)
                for i in 0..<(take * channels) { out[produced * channels + i] = ready[readyHead * channels + i] }
                readyHead += take; produced += take
                if readyHead * channels >= ready.count { ready.removeAll(keepingCapacity: true); readyHead = 0 }
                continue
            }
            if !makeGrain(stretch: s, pull: pull) { break }
        }
        return produced
    }

    @inline(__always) private func sample(_ frame: Int, _ c: Int) -> Float {
        let i = frame - inStart
        if i < 0 || i >= input.count / channels { return 0 }
        return input[i * channels + c]
    }

    private func fill(until end: Int, pull: (UnsafeMutablePointer<Float>, Int) -> Int) {
        while !ended && inEnd < end {
            let got = pulled.withUnsafeMutableBufferPointer { pull($0.baseAddress!, pullChunk) }
            if got <= 0 { ended = true; break }
            input.append(contentsOf: pulled[0..<(got * channels)])
        }
    }

    private func makeGrain(stretch s: Double, pull: (UnsafeMutablePointer<Float>, Int) -> Int) -> Bool {
        let nominal = Int(pos.rounded())
        fill(until: nominal + search + n, pull: pull)
        if ended && nominal >= inEnd { return false }
        var start = nominal
        if let prev = previous {
            // the continuation of the last grain is what the new one should begin like
            let target = prev + hop
            var best = -Float.infinity
            let lo = max(inStart, nominal - search), hi = nominal + search
            var cand = lo
            while cand <= hi {
                var dot: Float = 0, energy: Float = 1e-9
                var k = 0
                while k < hop {
                    var a: Float = 0, b: Float = 0
                    for c in 0..<channels { a += sample(target + k, c); b += sample(cand + k, c) }
                    dot += a * b; energy += b * b
                    k += 4
                }
                let score = dot / energy.squareRoot()
                if score > best { best = score; start = cand }
                cand += 2
            }
        }
        // add the grain to what is waiting, hand out the finished first half, keep the second half
        for i in 0..<n {
            let w = window[i]
            for c in 0..<channels { overlap[i * channels + c] += sample(start + i, c) * w }
        }
        ready.append(contentsOf: overlap[0..<(hop * channels)])
        overlap.withUnsafeMutableBufferPointer { p in
            for i in 0..<(hop * channels) { p[i] = p[i + hop * channels] }
            for i in (hop * channels)..<p.count { p[i] = 0 }
        }
        previous = start
        pos += s * Double(hop)
        // forget input that no later grain can reach
        let keepFrom = min(start + hop, Int(pos) - search) - 8
        if keepFrom - inStart > 16_384 {
            let drop = keepFrom - inStart
            input.removeFirst(drop * channels); inStart += drop
        }
        return true
    }
}

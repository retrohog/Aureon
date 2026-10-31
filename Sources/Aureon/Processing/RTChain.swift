import Foundation

/// A stage that runs on the real-time thread on interleaved Float32 audio, in place.
/// Implementations must not lock, allocate, log or touch the disk inside `process`.
protocol RTProcessor: AnyObject {
    var name: String { get }
    /// Delay this stage adds, in frames.
    var latencyFrames: Int { get }
    func process(_ x: UnsafeMutablePointer<Float>, frames: Int)
}

/// An immutable-after-publication set of processors for one stream format, plus the conversion scratch.
final class RTChainState {
    let processors: [RTProcessor]
    let channels: Int
    let rate: Double
    private let scratch: UnsafeMutablePointer<Float>
    private let capacity: Int

    init(processors: [RTProcessor], channels: Int, rate: Double, maxFrames: Int = 65_536) {
        self.processors = processors; self.channels = channels; self.rate = rate; capacity = maxFrames
        scratch = .allocate(capacity: maxFrames * channels)
        scratch.initialize(repeating: 0, count: maxFrames * channels)
    }
    deinit { scratch.deallocate() }

    var latencyFrames: Int { processors.reduce(0) { $0 + $1.latencyFrames } }
    var description: [String] { processors.map(\.name) }

    /// Int32 (left-justified) → Float → processors → Int32 with rounding. Real-time safe.
    func run(_ dst: UnsafeMutablePointer<Int32>, frames: Int) {
        var done = 0
        while done < frames {
            let n = min(capacity, frames - done)
            let base = dst + done * channels, count = n * channels
            for i in 0..<count { scratch[i] = Float(base[i]) * (1.0 / 2_147_483_648.0) }
            for p in processors { p.process(scratch, frames: n) }
            for i in 0..<count {
                let v = (Double(scratch[i]) * 2_147_483_648.0).rounded()
                base[i] = v >= 2_147_483_647 ? .max : (v <= -2_147_483_648 ? .min : Int32(v))
            }
            done += n
        }
    }
}

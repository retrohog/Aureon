import Foundation
import Synchronization

// Word-length reduction with dither. The engine carries left-justified Int32 (≥ 24 significant bits); a legacy 16- or 20-bit DAC, or
// the system mixer, truncates those. Without dither the quantisation error is correlated with the music (harmonic distortion that
// grows relative to the signal as it gets quieter). TPDF dither of ±1 LSB makes the error signal-independent white noise; the
// noise-shaped mode additionally moves that noise to high frequencies, where hearing is least sensitive.

enum DitherMode: String, Codable, CaseIterable, Equatable {
    case off, tpdf, highPassTPDF, noiseShaped
    var title: String {
        switch self {
        case .off: "Off"
        case .tpdf: "TPDF"
        case .highPassTPDF: "High-pass TPDF"
        case .noiseShaped: "Noise-shaped TPDF"
        }
    }
}

struct DitherSettings: Codable, Equatable {
    var mode: DitherMode = .off
    /// Output word length the samples are rounded to: 16, 20 or 24.
    var bits = 16
    var enabled: Bool { mode != .off }
    var clampedBits: Int { min(24, max(8, bits)) }
}

/// Real-time stage. All state is preallocated; `process` does integer arithmetic only (no locks, allocation or I/O).
final class DitherStage: @unchecked Sendable {
    let mode: DitherMode
    let bits: Int
    let channels: Int
    private let shift: Int64
    private let step: Int64
    private let half: Int64
    private let hi: Int64, lo: Int64
    private var rng: UInt32
    private var prev: UnsafeMutablePointer<Int64>        // per channel: last random value (high-pass)
    private var e1: UnsafeMutablePointer<Int64>          // per channel: error history (noise shaping)
    private var e2: UnsafeMutablePointer<Int64>

    init(settings s: DitherSettings, channels: Int, seed: UInt32 = 0x9E37_79B9) {
        mode = s.mode; bits = s.clampedBits; self.channels = max(1, channels)
        shift = Int64(32 - s.clampedBits); step = Int64(1) << shift; half = step >> 1
        hi = Int64(Int32.max) - (step - 1); lo = Int64(Int32.min)       // largest and smallest representable multiples of `step`
        rng = seed | 1
        prev = .allocate(capacity: self.channels); prev.initialize(repeating: 0, count: self.channels)
        e1 = .allocate(capacity: self.channels); e1.initialize(repeating: 0, count: self.channels)
        e2 = .allocate(capacity: self.channels); e2.initialize(repeating: 0, count: self.channels)
    }
    deinit { prev.deallocate(); e1.deallocate(); e2.deallocate() }

    var name: String {
        switch mode {
        case .off: "Dither off"
        case .tpdf: "Dither: TPDF → \(bits)-bit"
        case .highPassTPDF: "Dither: high-pass TPDF → \(bits)-bit"
        case .noiseShaped: "Dither: noise-shaped → \(bits)-bit"
        }
    }

    @inline(__always) private func next() -> UInt32 { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng }
    /// Uniform in [-step/2, step/2).
    @inline(__always) private func uniform() -> Int64 { Int64(Int32(bitPattern: next())) >> (32 - shift) }
    @inline(__always) private func quantise(_ v: Int64) -> Int64 { min(hi, max(lo, ((v + half) >> shift) << shift)) }   // arithmetic shift floors: round to nearest

    func process(_ buf: UnsafeMutablePointer<Int32>, frames: Int) {
        let ch = channels
        switch mode {
        case .off: return
        case .tpdf:
            for i in 0..<(frames * ch) { buf[i] = Int32(quantise(Int64(buf[i]) + uniform() + uniform())) }
        case .highPassTPDF:
            for f in 0..<frames {
                for c in 0..<ch {
                    let i = f * ch + c, r = uniform()
                    buf[i] = Int32(quantise(Int64(buf[i]) + r - prev[c])); prev[c] = r        // r[n] - r[n-1]: triangular, zero at DC
                }
            }
        case .noiseShaped:
            for f in 0..<frames {
                for c in 0..<ch {
                    let i = f * ch + c
                    let v = Int64(buf[i]) - 2 * e1[c] + e2[c]                                  // NTF = (1 - z⁻¹)²
                    let q = quantise(v + uniform() + uniform())
                    e2[c] = e1[c]; e1[c] = min(2 * step, max(-2 * step, q - v))               // bounded so clipping cannot wind the loop up
                    buf[i] = Int32(q)
                }
            }
        }
    }
}

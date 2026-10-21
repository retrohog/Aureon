import Foundation
import Accelerate

/// A musical key as pitch class (0 = C … 11 = B) and mode.
struct MusicalKey: Equatable, Codable, Hashable {
    var pitchClass: Int
    var minor: Bool

    static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    var name: String { Self.names[((pitchClass % 12) + 12) % 12] + (minor ? " minor" : " major") }

    /// The Camelot wheel position, "1A"…"12B" (A = minor, B = major). 8B is C major, 8A is A minor.
    var camelot: String {
        let major = minor ? (pitchClass + 3) % 12 : pitchClass
        let n = ((major * 7) % 12 + 7) % 12 + 1
        return "\(n)\(minor ? "A" : "B")"
    }

    var camelotNumber: Int { Int(camelot.dropLast())! }

    /// 0 = identical, 1 = adjacent on the wheel or the relative major/minor (mixes cleanly), 2+ = clashing.
    func distance(to o: MusicalKey) -> Int {
        let a = camelotNumber, b = o.camelotNumber
        let d = min((a - b + 12) % 12, (b - a + 12) % 12)
        if minor == o.minor { return d }
        return d == 0 ? 1 : d + 1
    }

    func compatible(with o: MusicalKey) -> Bool { distance(to: o) <= 1 }
}

/// Estimates the key from a chroma vector (energy per pitch class) by correlating it with the Krumhansl-Kessler major and minor profiles.
enum KeyEstimator {
    static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func estimate(chroma: [Double]) -> (key: MusicalKey, strength: Double)? {
        guard chroma.count == 12, chroma.reduce(0, +) > 1e-9 else { return nil }
        func corr(_ p: [Double], _ shift: Int) -> Double {
            let xm = chroma.reduce(0, +) / 12, pm = p.reduce(0, +) / 12
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for i in 0..<12 { let x = chroma[(i + shift) % 12] - xm, y = p[i] - pm; sxy += x * y; sxx += x * x; syy += y * y }
            return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
        }
        var best: (MusicalKey, Double) = (MusicalKey(pitchClass: 0, minor: false), -2)
        var second = -2.0
        for k in 0..<12 {
            for (mode, p) in [(false, major), (true, minor)] {
                let c = corr(p, k)
                if c > best.1 { second = best.1; best = (MusicalKey(pitchClass: k, minor: mode), c) } else if c > second { second = c }
            }
        }
        return (best.0, max(0, min(1, (best.1 - second) * 4 + 0.2 * best.1)))
    }
}

/// Accumulates a chroma vector from a stream of mono samples. Sparse by design: one 8192-point transform every `skip` blocks is plenty for a key.
final class ChromaAccumulator {
    static let n = 8192
    private let sampleRate: Double
    private var buf = [Float](repeating: 0, count: ChromaAccumulator.n)
    private var fill = 0
    private var blocks = 0
    private let skip: Int
    private let setup: FFTSetup
    private let log2n = vDSP_Length(13)
    private var window = [Float](repeating: 0, count: ChromaAccumulator.n)
    private var re = [Float](repeating: 0, count: ChromaAccumulator.n / 2), im = [Float](repeating: 0, count: ChromaAccumulator.n / 2)
    private let binClass: [Int8]               // pitch class for each FFT bin, -1 outside the useful range
    private(set) var chroma = [Double](repeating: 0, count: 12)

    init(sampleRate: Double, skip: Int = 2) {
        self.sampleRate = sampleRate; self.skip = max(1, skip)
        setup = vDSP_create_fftsetup(13, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(ChromaAccumulator.n), Int32(vDSP_HANN_NORM))
        var map = [Int8](repeating: -1, count: ChromaAccumulator.n / 2)
        for b in 1..<(ChromaAccumulator.n / 2) {
            let f = Double(b) * sampleRate / Double(ChromaAccumulator.n)
            guard f >= 65, f <= 2_100 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            map[b] = Int8(((Int(midi.rounded()) % 12) + 12) % 12)
        }
        binClass = map
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func feed(_ x: UnsafePointer<Float>, count: Int) {
        var i = 0
        while i < count {
            let k = min(count - i, ChromaAccumulator.n - fill)
            for j in 0..<k { buf[fill + j] = x[i + j] }
            fill += k; i += k
            if fill == ChromaAccumulator.n { fill = 0; blocks += 1; if blocks % skip == 0 { transform() } }
        }
    }

    private func transform() {
        let n = ChromaAccumulator.n
        var w = [Float](repeating: 0, count: n)
        vDSP_vmul(buf, 1, window, 1, &w, 1, vDSP_Length(n))
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            w.withUnsafeBufferPointer { wp in wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) } }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        } }
        for b in 1..<(n / 2) {
            let c = Int(binClass[b]); if c < 0 { continue }
            let mag = (re[b] * re[b] + im[b] * im[b]).squareRoot()
            chroma[c] += Double(mag.squareRoot())               // compressed, so a loud bass note does not swamp the harmony
        }
    }
}

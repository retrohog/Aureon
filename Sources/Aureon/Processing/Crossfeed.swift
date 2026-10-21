import Foundation

/// Bauer stereophonic-to-binaural crossfeed (the BS2B design).
///
/// Headphones put each channel only in one ear, which exaggerates stereo width. Crossfeed feeds a low-passed,
/// attenuated copy of each channel to the opposite ear and compensates the near ear, approximating loudspeaker listening.
///
/// Per output sample (L' and R' are the outputs):
///     L' = ( lowpass(R) + highboost(L) ) · gain
///     R' = ( lowpass(L) + highboost(R) ) · gain
/// with one-pole filters derived from the cut frequency and the feed level (dB), normalised so that a centred (mono)
/// low-frequency signal passes at unity.
struct CrossfeedSettings: Codable, Equatable {
    var enabled = false
    var cutoffHz = 700.0      // 300 … 2000
    var feedDB = 4.5          // 1 … 15

    static let presets: [(name: String, cutoff: Double, feed: Double)] = [
        ("Default (700 Hz, 4.5 dB)", 700, 4.5), ("Chu Moy (700 Hz, 6 dB)", 700, 6.0), ("Jan Meier (650 Hz, 9.5 dB)", 650, 9.5)
    ]
}

final class BS2BCrossfeed: RTProcessor {
    let name: String
    let latencyFrames = 0
    private let a0lo, b1lo, a0hi, a1hi, b1hi, gain: Double
    private var loL = 0.0, loR = 0.0, hiL = 0.0, hiR = 0.0, xL = 0.0, xR = 0.0

    init(sampleRate fs: Double, cutoffHz: Double, feedDB: Double) {
        let fc = min(max(cutoffHz, 300), 2000), feed = min(max(feedDB, 1), 15)
        let gbLo = feed * -5.0 / 6.0 - 3.0
        let gbHi = feed / 6.0 - 3.0
        let gLo = pow(10, gbLo / 20)
        let gHi = 1 - pow(10, gbHi / 20)
        let fcLo = fc
        let fcHi = fcLo * pow(2, (gbLo - 20 * log10(gHi)) / 12)
        var x = exp(-2 * Double.pi * fcLo / fs)
        b1lo = x; a0lo = gLo * (1 - x)
        x = exp(-2 * Double.pi * fcHi / fs)
        b1hi = x; a0hi = 1 - gHi * (1 - x); a1hi = -x
        gain = 1 / (1 - gHi + gLo)
        name = String(format: "Crossfeed BS2B (%.0f Hz, %.1f dB)", fc, feed)
    }

    func process(_ p: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let l = Double(p[i * 2]), r = Double(p[i * 2 + 1])
            // one-pole low-pass of each input (transposed: state = previous output)
            loL = a0lo * l + b1lo * loL
            loR = a0lo * r + b1lo * loR
            // one-pole high-boost of each input
            hiL = a0hi * l + a1hi * xL + b1hi * hiL
            hiR = a0hi * r + a1hi * xR + b1hi * hiR
            xL = l; xR = r
            p[i * 2] = Float((loR + hiL) * gain)
            p[i * 2 + 1] = Float((loL + hiR) * gain)
        }
    }
}

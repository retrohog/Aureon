import Foundation

// Parametric EQ profiles for headphone correction (the AutoEQ ParametricEQ.txt format) and the biquad engine that applies them.

struct EQFilter: Codable, Equatable {
    enum Kind: String, Codable { case peak, lowShelf, highShelf, lowPass, highPass }
    var kind: Kind
    var fc: Double
    var gainDB: Double = 0
    var q: Double = 0.707
    var enabled = true
}

struct HeadphoneProfile: Codable, Equatable, Identifiable {
    var name: String
    var source: String = ""
    var preampDB: Double = 0
    var filters: [EQFilter] = []
    var id: String { source + "/" + name }

    /// Largest boost of the combined response, found on a dense log grid. Used to keep the chain from clipping.
    func peakGainDB(sampleRate: Double) -> Double {
        var m = -200.0
        var f = 15.0
        while f < sampleRate * 0.45 { m = max(m, responseDB(atHz: f, sampleRate: sampleRate, includePreamp: false)); f *= 1.02 }
        return m
    }

    /// The preamp actually used: the profile's own, lowered further if its response would still exceed 0 dBFS.
    func effectivePreampDB(sampleRate: Double) -> Double { min(preampDB, -max(0, peakGainDB(sampleRate: sampleRate))) }

    func responseDB(atHz f: Double, sampleRate: Double, includePreamp: Bool = true) -> Double {
        var db = includePreamp ? preampDB : 0
        for flt in filters where flt.enabled { if let c = BiquadSection.coefficients(flt, sampleRate: sampleRate) { db += c.responseDB(atHz: f, sampleRate: sampleRate) } }
        return db
    }
}

enum AutoEQParser {
    /// "Preamp: -6.2 dB" and "Filter 1: ON PK Fc 105 Hz Gain 4.0 dB Q 0.70" (Equalizer APO syntax as written by AutoEQ).
    static func parse(_ text: String, name: String, source: String = "") -> HeadphoneProfile? {
        var p = HeadphoneProfile(name: name, source: source)
        func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("preamp") {
                let t = line.split(whereSeparator: { " :".contains($0) })
                if t.count >= 2, let v = number(String(t[1])) { p.preampDB = v }
            } else if line.lowercased().hasPrefix("filter") {
                let t = line.split(whereSeparator: { " :".contains($0) }).map(String.init)
                guard let onIdx = t.firstIndex(where: { $0.uppercased() == "ON" || $0.uppercased() == "OFF" }), onIdx + 1 < t.count else { continue }
                let on = t[onIdx].uppercased() == "ON"
                let kind: EQFilter.Kind
                switch t[onIdx + 1].uppercased() {
                case "PK", "PEQ", "MODAL": kind = .peak
                case "LSC", "LS", "LSQ": kind = .lowShelf
                case "HSC", "HS", "HSQ": kind = .highShelf
                case "LP", "LPQ": kind = .lowPass
                case "HP", "HPQ": kind = .highPass
                default: continue
                }
                var f = EQFilter(kind: kind, fc: 1000, enabled: on)
                var i = onIdx + 2
                while i < t.count {
                    switch t[i].lowercased() {
                    case "fc": if i + 1 < t.count, let v = number(t[i + 1]) { f.fc = v; i += 1 }
                    case "gain": if i + 1 < t.count, let v = number(t[i + 1]) { f.gainDB = v; i += 1 }
                    case "q": if i + 1 < t.count, let v = number(t[i + 1]) { f.q = v; i += 1 }
                    case "bw": // "BW Oct 0.5": bandwidth in octaves → Q
                        if i + 2 < t.count, let bw = number(t[i + 2]), bw > 0 { f.q = 1 / (2 * sinh(M_LN2 / 2 * bw)); i += 2 }
                    default: break
                    }
                    i += 1
                }
                p.filters.append(f)
            }
        }
        return p.filters.isEmpty ? nil : p
    }
}

/// One second-order section (RBJ audio-EQ-cookbook design).
struct BiquadSection {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0     // normalised: a0 = 1

    static func coefficients(_ f: EQFilter, sampleRate fs: Double) -> BiquadSection? {
        guard f.fc > 0, f.fc < fs * 0.49, f.q > 0 else { return nil }
        let w0 = 2 * Double.pi * f.fc / fs, cs = cos(w0), sn = sin(w0)
        let A = pow(10, f.gainDB / 40), alpha = sn / (2 * f.q)
        var b0, b1, b2, a0, a1, a2: Double
        switch f.kind {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cs; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cs; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * A.squareRoot() * alpha
            b0 = A * ((A + 1) - (A - 1) * cs + s); b1 = 2 * A * ((A - 1) - (A + 1) * cs); b2 = A * ((A + 1) - (A - 1) * cs - s)
            a0 = (A + 1) + (A - 1) * cs + s; a1 = -2 * ((A - 1) + (A + 1) * cs); a2 = (A + 1) + (A - 1) * cs - s
        case .highShelf:
            let s = 2 * A.squareRoot() * alpha
            b0 = A * ((A + 1) + (A - 1) * cs + s); b1 = -2 * A * ((A - 1) + (A + 1) * cs); b2 = A * ((A + 1) + (A - 1) * cs - s)
            a0 = (A + 1) - (A - 1) * cs + s; a1 = 2 * ((A - 1) - (A + 1) * cs); a2 = (A + 1) - (A - 1) * cs - s
        case .lowPass:
            b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        }
        return BiquadSection(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Magnitude response in dB.
    func responseDB(atHz f: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

/// Real-time cascade of biquads (+ preamp) for any channel count. Double-precision, transposed direct form II.
final class BiquadChainProcessor: RTProcessor {
    let name: String
    let latencyFrames = 0
    private let sections: [BiquadSection]
    private let channels: Int
    private let preamp: Double
    private var z1: [Double], z2: [Double]     // [section * channels + channel]

    init(profile: HeadphoneProfile, sampleRate: Double, channels: Int) {
        sections = profile.filters.filter(\.enabled).compactMap { BiquadSection.coefficients($0, sampleRate: sampleRate) }
        self.channels = channels
        let db = profile.effectivePreampDB(sampleRate: sampleRate)
        preamp = pow(10, db / 20)
        z1 = [Double](repeating: 0, count: max(1, sections.count) * channels); z2 = [Double](repeating: 0, count: max(1, sections.count) * channels)
        name = String(format: "Headphone EQ: %@ (%d filters, %+.1f dB pre-amp)", profile.name, sections.count, db)
    }

    func process(_ x: UnsafeMutablePointer<Float>, frames: Int) {
        let n = sections.count
        for f in 0..<frames {
            for c in 0..<channels {
                var v = Double(x[f * channels + c]) * preamp
                for s in 0..<n {
                    let b = sections[s], k = s * channels + c
                    let y = b.b0 * v + z1[k]
                    z1[k] = b.b1 * v - b.a1 * y + z2[k]
                    z2[k] = b.b2 * v - b.a2 * y
                    v = y
                }
                x[f * channels + c] = Float(v)
            }
        }
    }
}

struct HeadphoneEQSettings: Codable, Equatable {
    var enabled = false
    var profile: HeadphoneProfile?
}

import Foundation

/// What a deck needs to know about a track: a waveform overview and the tempo.
struct DJTrackAnalysis: Equatable {
    var peaks: [Float]            // 0…1 per bucket, left to right across the whole track
    var bpm: Double?
    var confidence: Double        // 0…1: how clearly periodic the beat is
    var duration: Double
}

enum DJAnalysis {
    /// Decodes the file once and returns its waveform overview and estimated tempo. Runs off the main thread.
    static func analyze(path: String, buckets: Int = 1200, cancelled: () -> Bool = { false }) -> DJTrackAnalysis? {
        guard let f = try? LosslessFile(path: path), f.info.totalFrames > 0 else { return nil }
        let info = f.info, ch = info.channels, total = Int(info.totalFrames), hop = 256
        let per = max(1, total / buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        var energy = [Float](); energy.reserveCapacity(total / hop + 1)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 16_384 * ch); defer { buf.deallocate() }
        var frame = 0, hopSum = 0.0, hopN = 0
        while true {
            if cancelled() { return nil }
            let n = f.read(into: buf, frames: 16_384)
            if n == 0 { break }
            for i in 0..<n {
                var pk = 0.0, mono = 0.0
                for c in 0..<ch { let v = Double(buf[i * ch + c]) / 2_147_483_648; pk = max(pk, abs(v)); mono += v }
                mono /= Double(ch)
                let b = min(buckets - 1, (frame + i) / per)
                peaks[b] = max(peaks[b], Float(pk))
                hopSum += mono * mono; hopN += 1
                if hopN == hop { energy.append(Float(hopSum / Double(hop))); hopSum = 0; hopN = 0 }
            }
            frame += n
        }
        let est = estimateBPM(energy: energy, hopRate: info.sampleRate / Double(hop))
        return DJTrackAnalysis(peaks: peaks, bpm: est?.bpm, confidence: est?.confidence ?? 0, duration: info.duration)
    }

    /// Tempo from the autocorrelation of the onset strength (rises in energy). Folded into 75…180 BPM.
    static func estimateBPM(energy: [Float], hopRate: Double) -> (bpm: Double, confidence: Double)? {
        guard energy.count > Int(hopRate * 8) else { return nil }
        let env = energy.map { log(1 + 1000 * Double($0)) }
        var flux = [Double](repeating: 0, count: env.count)
        for i in 1..<env.count { flux[i] = max(0, env[i] - env[i - 1]) }
        // remove the slowly varying part so only the rhythmic structure is left
        let w = max(2, Int(hopRate * 0.5))
        var mean = [Double](repeating: 0, count: flux.count)
        var run = 0.0
        for i in 0..<flux.count {
            run += flux[i]; if i >= 2 * w { run -= flux[i - 2 * w] }
            mean[i] = run / Double(min(i + 1, 2 * w))
        }
        let x = zip(flux, mean).map { max(0, $0 - $1) }
        let n = x.count
        let lagMin = max(2, Int(hopRate * 60 / 200)), lagMax = Int(hopRate * 60 / 55)
        guard lagMax * 2 + 2 < n else { return nil }
        func acf(_ lag: Int) -> Double {
            var s = 0.0
            for i in 0..<(n - lag) { s += x[i] * x[i + lag] }
            return s / Double(n - lag)
        }
        let a0 = acf(0)
        guard a0 > 1e-9 else { return nil }
        var cache = [Double](repeating: 0, count: lagMax * 2 + 2)
        for l in 1..<cache.count where l >= lagMin - 1 { cache[l] = acf(l) }
        var best = lagMin, bestScore = -Double.infinity
        for l in lagMin...lagMax {
            // a beat period should also repeat at twice the lag; favour that over its sub-multiples
            let score = cache[l] + 0.5 * cache[2 * l] + 0.25 * cache[min(cache.count - 1, 4 * l)]
            if score > bestScore { bestScore = score; best = l }
        }
        // parabolic refinement of the peak
        let y0 = cache[best - 1], y1 = cache[best], y2 = cache[best + 1]
        let denom = y0 - 2 * y1 + y2
        let lag = denom < 0 ? Double(best) + 0.5 * (y0 - y2) / denom : Double(best)
        var bpm = 60 * hopRate / lag
        while bpm < 75 { bpm *= 2 }
        while bpm >= 180 { bpm /= 2 }
        return (bpm, max(0, min(1, cache[best] / a0)))
    }
}

enum CrossfaderCurve: String, CaseIterable, Identifiable, Codable {
    case smooth, linear, sharp
    var id: String { rawValue }
    var title: String { switch self { case .smooth: "Smooth"; case .linear: "Blend"; case .sharp: "Cut" } }

    /// Gains for deck A and deck B at crossfader position x (-1 = all A, +1 = all B).
    func gains(_ x: Double) -> (a: Double, b: Double) {
        let x = max(-1, min(1, x.isFinite ? x : 0))
        switch self {
        case .smooth:                                  // equal power: constant loudness through the middle
            let t = (x + 1) * .pi / 4
            return (cos(t), sin(t))
        case .linear:                                  // both decks at full in the middle (the sum can be louder)
            return (min(1, 1 - x), min(1, 1 + x))
        case .sharp:                                   // cut: each deck at full until the very end
            return (x < 0.9 ? 1 : max(0, (1 - x) / 0.1), x > -0.9 ? 1 : max(0, (1 + x) / 0.1))
        }
    }
}

enum DJMath {
    /// The channel fader's taper: finer control at the quiet end.
    static func channelGain(_ fader: Double) -> Double { let f = max(0, min(1, fader)); return f * f }

    static let eqRange: ClosedRange<Double> = -26...6
    /// At the bottom of the knob a band is fully cut.
    static let killDB = -60.0
    static func eqGainDB(_ knob: Double) -> Double { knob <= eqRange.lowerBound + 0.5 ? killDB : max(eqRange.lowerBound, min(eqRange.upperBound, knob)) }

    /// Low shelf, mid peak and high shelf as one profile; nil when all three are flat (the deck then skips the processor).
    static func eqProfile(low: Double, mid: Double, high: Double) -> HeadphoneProfile? {
        let g = [eqGainDB(low), eqGainDB(mid), eqGainDB(high)]
        guard g.contains(where: { abs($0) > 0.05 }) else { return nil }
        return HeadphoneProfile(name: "DJ EQ", source: "deck", preampDB: 0, filters: [
            EQFilter(kind: .lowShelf, fc: 120, gainDB: g[0], q: 0.707),
            EQFilter(kind: .peak, fc: 1_000, gainDB: g[1], q: 0.6),
            EQFilter(kind: .highShelf, fc: 6_000, gainDB: g[2], q: 0.707)])
    }

    static func effectiveBPM(_ bpm: Double?, pitch: Double) -> Double? { bpm.map { $0 * (1 + pitch) } }

    /// The pitch (fraction, ±) that makes `bpm` play at `target`, using half or double time when that is closer. nil if out of the ±16 % range.
    static func syncPitch(bpm: Double, target: Double) -> Double? {
        guard bpm > 0, target > 0 else { return nil }
        let candidates = [target, target / 2, target * 2].map { $0 / bpm - 1 }
        guard let best = candidates.min(by: { abs($0) < abs($1) }), abs(best) <= 0.16 else { return nil }
        return best
    }
}

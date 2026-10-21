import Foundation

struct DJAnalysisTests {
    let dir = tempDir("djan")

    private func chord(_ name: String, midi: [Int], seconds: Double = 12) -> URL {
        let rate = 44_100, full = Double((1 << 23) - 1)
        return writeWAV(dir.appendingPathComponent(name), rate: rate, bits: 24, frames: Int(Double(rate) * seconds)) { f, _ in
            let t = Double(f) / Double(rate)
            var v = 0.0
            for m in midi { let fr = 440 * pow(2, Double(m - 69) / 12); for h in 1...4 { v += sin(2 * .pi * fr * Double(h) * t) / Double(h) } }
            return Int(v / Double(midi.count) * 0.4 * full)
        }
    }

    func camelotWheel() {
        expect(MusicalKey(pitchClass: 0, minor: false).camelot == "8B", "C major is 8B")
        expect(MusicalKey(pitchClass: 9, minor: true).camelot == "8A", "A minor is 8A")
        expect(MusicalKey(pitchClass: 7, minor: false).camelot == "9B" && MusicalKey(pitchClass: 2, minor: false).camelot == "10B", "fifths climb the wheel")
        expect(MusicalKey(pitchClass: 4, minor: true).camelot == "9A" && MusicalKey(pitchClass: 1, minor: true).camelot == "12A")
        expect(MusicalKey(pitchClass: 6, minor: false).camelot == "2B" && MusicalKey(pitchClass: 11, minor: false).camelot == "1B", "and wrap at 12")
        let c = MusicalKey(pitchClass: 0, minor: false), am = MusicalKey(pitchClass: 9, minor: true), g = MusicalKey(pitchClass: 7, minor: false), fs = MusicalKey(pitchClass: 6, minor: false)
        expect(c.distance(to: c) == 0 && c.distance(to: am) == 1 && c.distance(to: g) == 1 && c.distance(to: fs) == 6, "distances: \(c.distance(to: fs))")
        expect(c.compatible(with: am) && c.compatible(with: g) && !c.compatible(with: fs))
        expect(c.name == "C major" && am.name == "A minor")
    }

    func keyDetection() {
        let cases: [(String, [Int], MusicalKey)] = [
            ("cmaj", [48, 60, 64, 67, 72], MusicalKey(pitchClass: 0, minor: false)),
            ("amin", [45, 57, 60, 64, 69], MusicalKey(pitchClass: 9, minor: true)),
            ("dmaj", [50, 62, 66, 69], MusicalKey(pitchClass: 2, minor: false)),
            ("fsmin", [42, 54, 57, 61, 66], MusicalKey(pitchClass: 6, minor: true))]
        for (n, notes, want) in cases {
            let a = DJAnalysis.analyze(path: chord(n + ".wav", midi: notes).path)
            expect(a?.key == want, "\(n): detected \(String(describing: a?.key?.name)), expected \(want.name)")
        }
        // a cadence is a better test of a real key than one chord
        let rate = 44_100, full = Double((1 << 23) - 1)
        let prog: [[Int]] = [[60, 64, 67], [57, 60, 64], [65, 69, 72], [67, 71, 74]]       // I vi IV V
        let f = writeWAV(dir.appendingPathComponent("cad.wav"), rate: rate, bits: 24, frames: rate * 16) { fr, _ in
            let t = Double(fr) / Double(rate), ch = prog[min(3, Int(t / 4))]
            var v = 0.0; for m in ch { let fq = 440 * pow(2, Double(m - 69) / 12); for h in 1...2 { v += sin(2 * .pi * fq * Double(h) * t) / Double(h * h) } }
            return Int(v / 3 * 0.4 * full)
        }
        let ck = DJAnalysis.analyze(path: f.path)?.key
        expect(ck == MusicalKey(pitchClass: 0, minor: false), "I–vi–IV–V is C major, got \(String(describing: ck?.name))")
        // noise has no key worth the name
        expect(KeyEstimator.estimate(chroma: Array(repeating: 0, count: 12)) == nil)
    }

    func beatGridAndSections() {
        let rate = 44_100, full = Double((1 << 23) - 1), bpm = 120.0, offset = 0.23, beat = 60 / bpm
        let f = writeWAV(dir.appendingPathComponent("grid.wav"), rate: rate, bits: 24, frames: rate * 40) { fr, _ in
            let t = Double(fr) / Double(rate)
            // quiet bed for the first 8 s and the last 6 s, kicks (loud) in between
            let loud = t >= 8 && t < 34
            let k = (t - offset).truncatingRemainder(dividingBy: beat)
            var v = 0.03 * sin(2 * .pi * 220 * t)
            if t >= offset, k < 0.12 { v += (loud ? 0.8 : 0.0) * exp(-k / 0.04) * sin(2 * .pi * 55 * k) }
            if t >= offset, k < 0.12, !loud, Int((t - offset) / beat) % 2 == 0 { v += 0.12 * exp(-k / 0.03) * sin(2 * .pi * 55 * k) }
            return Int(v * full)
        }
        let a = DJAnalysis.analyze(path: f.path)!
        expect(a.bpm != nil && abs(a.bpm! - bpm) < 1, "tempo \(String(describing: a.bpm))")
        if let fb = a.firstBeat {
            let off = fb - offset, p = beat
            let wrapped = off - (off / p).rounded() * p
            expect(abs(wrapped) < 0.05, "first beat lands on the grid within 50 ms: \(fb) vs \(offset) (error \(wrapped))")
        } else { expect(false, "a first beat is found") }
        expect(a.introEnd != nil && abs(a.introEnd! - 8) < 3, "intro ends near 8 s: \(String(describing: a.introEnd))")
        expect(a.outroStart != nil && abs(a.outroStart! - 34) < 3, "outro starts near 34 s: \(String(describing: a.outroStart))")
        expect(a.energy > 0 && a.energy <= 1)
        let period = 60 / a.bpm!
        if let p = a.beatPhase(at: a.firstBeat! + period * 3) { expect(p < 0.02 || p > 0.98, "phase is 0 on a beat: \(p)") }
        if let n = a.nearestBeat(to: a.firstBeat! + period * 3 + 0.1) { expect(abs(n - (a.firstBeat! + period * 3)) < 1e-9, "nearest beat snaps") }
        // louder, busier music scores higher
        let quiet = writeWAV(dir.appendingPathComponent("q.wav"), rate: rate, bits: 24, frames: rate * 20) { fr, _ in Int(0.02 * full * sin(2 * .pi * 200 * Double(fr) / Double(rate))) }
        expect((DJAnalysis.analyze(path: quiet.path)?.energy ?? 1) < a.energy, "a quiet drone is lower energy than the kick track")
    }

    func analysisCache() {
        let cache = AnalysisCache(directory: dir.appendingPathComponent("cache"))
        let f = chord("cache.wav", midi: [48, 60, 64, 67], seconds: 10)
        expect(cache.cached(path: f.path) == nil, "empty to begin with")
        let a = cache.analysis(path: f.path)
        expect(a != nil && cache.cached(path: f.path) == a, "stored after the first analysis")
        let again = AnalysisCache(directory: dir.appendingPathComponent("cache"))
        expect(again.cached(path: f.path) == a, "and survives a restart")
        // changing the file invalidates the entry
        Thread.sleep(forTimeInterval: 1.1)
        _ = chord("cache.wav", midi: [45, 57, 60, 64], seconds: 11)
        expect(again.cached(path: f.path) == nil, "a modified file is analysed again")
        expect(again.analysis(path: f.path)?.key == MusicalKey(pitchClass: 9, minor: true), "…and gets its new key")
        expect(cache.analysis(path: "/nonexistent.wav") == nil)
    }
}

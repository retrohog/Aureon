import Foundation

struct ResamplerTests {
    let dir = tempDir()

    func resampled(_ rate: Int, to out: Double, freq: Double, amp: Double = 0.5, seconds: Double = 1.0,
                   config: ResamplerConfig = .standard) -> (samples: [Int32], info: StreamInfo) {
        let url = sineWAV(dir.appendingPathComponent("rs-\(rate)-\(Int(freq)).wav"), rate: rate, freq: freq, amp: amp, seconds: seconds)
        let f = try! LosslessFile(path: url.path)
        let r = ResamplingSource(f, outRate: out, config: config)!
        return (readAll(r), r.info)
    }

    func sineIsPreservedAndTimeAligned() {
        for (inRate, outRate) in [(44_100, 176_400.0), (44_100, 88_200.0), (48_000, 44_100.0), (44_100, 48_000.0), (96_000, 44_100.0), (44_100, 192_000.0)] {
            check(inRate, outRate)
        }
    }

    func check(_ inRate: Int, _ outRate: Double) {
                let (y, info) = resampled(inRate, to: outRate, freq: 1000)
        let (l, m) = PolyphaseDesign.ratio(Double(inRate), outRate)!
        expect(y.count / 2 == Int(info.totalFrames), "produced \(y.count / 2) frames, expected \(info.totalFrames)")
        expect(info.totalFrames == Int64((inRate * l + m - 1) / m))
        // amplitude within 0.01 dB
        let a = amplitude(y, channels: 2, rate: outRate, freq: 1000, skip: 4000, count: Int(outRate) / 2)
        expect(abs(db(a / 0.5)) < 0.01)
        // error against the ideal, aligned sine (linear phase compensates its delay)
        var err = 0.0, n = 0
        let skip = 4000, end = y.count / 2 - 4000
        for i in skip..<end {
            let ideal = 0.5 * sin(2 * Double.pi * 1000 * Double(i) / outRate)
            let d = Double(y[i * 2]) / 2_147_483_648.0 - ideal
            err += d * d; n += 1
        }
        let rms = (err / Double(n)).squareRoot()
        expect(db(rms) < -100, "error floor \(db(rms)) dBFS")
        }

    func passbandIsFlat() {
        for f in [100.0, 1_000, 5_000, 10_000, 15_000, 18_000, 20_000] {
            let (y, _) = resampled(44_100, to: 88_200, freq: f)
            let a = amplitude(y, channels: 2, rate: 88_200, freq: f, skip: 6000, count: 40_000)
            expect(abs(db(a / 0.5)) < 0.01, "\(Int(f)) Hz off by \(db(a / 0.5)) dB")
        }
    }

    func imagesAreRejected() {
        let (y, _) = resampled(44_100, to: 88_200, freq: 20_000)
        for image in [24_100.0, 30_000.0, 40_000.0] {
            let a = amplitude(y, channels: 2, rate: 88_200, freq: image, skip: 6000, count: 40_000)
            expect(db(a / 0.5) < -105, "image at \(Int(image)) Hz only \(db(a / 0.5)) dB down")
        }
    }

    func minimumPhaseKeepsMagnitude() {
        var cfg = ResamplerConfig.standard; cfg.phase = .minimum
        for f in [100.0, 1_000, 10_000, 18_000] {
            let (y, _) = resampled(44_100, to: 88_200, freq: f, config: cfg)
            let a = amplitude(y, channels: 2, rate: 88_200, freq: f, skip: 6000, count: 40_000)
            expect(abs(db(a / 0.5)) < 0.02, "\(Int(f)) Hz off by \(db(a / 0.5)) dB")
        }
    }

    /// An impulse reveals phase behaviour: minimum phase has no pre-ringing, linear phase does.
    func preRingingDiffersByPhase() {
        let url = writeWAV(dir.appendingPathComponent("impulse.wav"), rate: 44_100, bits: 24, frames: 12_000) { f, _ in f == 4000 ? 4_000_000 : 0 }
        func run(_ phase: ResamplerConfig.Phase) -> (before: Double, after: Double) {
            var cfg = ResamplerConfig.standard; cfg.phase = phase
            let r = ResamplingSource(try! LosslessFile(path: url.path), outRate: 176_400, config: cfg)!
            let y = readAll(r)
            let onset = 4000 * 4
            var before = 0.0, after = 0.0
            for i in 0..<(y.count / 2) {
                let v = abs(Double(y[i * 2]) / 2_147_483_648.0)
                if i < onset - 8 { before = max(before, v) } else { after = max(after, v) }
            }
            return (before, after)
        }
        let lin = run(.linear), minp = run(.minimum)
        expect(lin.before > 1e-4, "linear phase should ring before the impulse")
        expect(minp.before == 0, "minimum phase must not ring before the impulse, got \(minp.before)")
        expect(minp.after > 1e-3)
    }

    func seekIsDeterministic() {
        let url = sineWAV(dir.appendingPathComponent("seek.wav"), rate: 44_100, freq: 440, amp: 0.4, seconds: 1.0)
        for (rate, phase) in [(48_000.0, ResamplerConfig.Phase.linear), (176_400.0, .minimum)] {
            var cfg = ResamplerConfig.standard; cfg.phase = phase
            let a = ResamplingSource(try! LosslessFile(path: url.path), outRate: rate, config: cfg)!
            let all = readAll(a)
            let b = ResamplingSource(try! LosslessFile(path: url.path), outRate: rate, config: cfg)!
            b.seek(to: 12_345)
            let tail = readAll(b)
            expect(tail == Array(all[(12_345 * 2)...]), "seek to 12345 at \(Int(rate)) Hz must reproduce the same samples")
        }
    }

    func targetSelection() {
        let dev: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        expect(upsamplingTarget(source: 44_100, mode: .double, deviceRates: dev, maxRate: 0) == 88_200)
        expect(upsamplingTarget(source: 44_100, mode: .powerOfTwo, deviceRates: dev, maxRate: 0) == 176_400)
        expect(upsamplingTarget(source: 44_100, mode: .deviceMax, deviceRates: dev, maxRate: 0) == 176_400)
        expect(upsamplingTarget(source: 48_000, mode: .deviceMax, deviceRates: dev, maxRate: 0) == 192_000)
        expect(upsamplingTarget(source: 44_100, mode: .deviceMax, deviceRates: dev, maxRate: 100_000) == 88_200)
        expect(upsamplingTarget(source: 44_100, mode: .off, deviceRates: dev, maxRate: 0) == nil)
        expect(upsamplingTarget(source: 192_000, mode: .deviceMax, deviceRates: dev, maxRate: 0) == nil)
        expect(fitRate(source: 96_000, deviceRates: [44_100, 48_000]) == 48_000)
        expect(fitRate(source: 352_800, deviceRates: [44_100, 48_000, 88_200, 96_000]) == 88_200)
        expect(fitRate(source: 96_000, deviceRates: dev) == nil)
    }
}

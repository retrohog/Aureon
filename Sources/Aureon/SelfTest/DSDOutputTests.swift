import Foundation

/// PCM → DSD (modulators, interpolation, planner), the oversampling filters and the live filter swap.
private final class TestTone: FrameSource {
    let info: StreamInfo
    private let freqs: [Double], amp: Double
    private var pos = 0
    init(rate: Double, frames: Int, freqs: [Double], amp: Double) {
        info = StreamInfo(sampleRate: rate, channels: freqs.count, sourceBits: 24, totalFrames: Int64(frames), codec: "test tone")
        self.freqs = freqs; self.amp = amp
    }
    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let n = max(0, min(frames, Int(info.totalFrames) - pos)), ch = freqs.count
        for f in 0..<n { for c in 0..<ch { buf[f * ch + c] = Int32(amp * 2_147_483_647 * sin(2 * Double.pi * freqs[c] * Double(pos + f) / info.sampleRate)) } }
        pos += n; return n
    }
    func seek(to frame: Int64) { pos = max(0, min(Int(frame), Int(info.totalFrames))) }
}

struct DSDOutputTests {
    /// In-band signal-to-noise of a one-bit stream: Blackman-windowed FFT, tone bins against everything else below `band`.
    private func inBandSNR(_ x: [Double], rate: Double, freq: Double, band: Double) -> Double {
        let n = x.count
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = 2 * Double.pi * Double(i) / Double(n - 1)
            re[i] = x[i] * (0.42 - 0.5 * cos(t) + 0.08 * cos(2 * t))
        }
        DSPMath.fft(&re, &im, inverse: false)
        let kc = Int((freq / rate * Double(n)).rounded()), kb = Int(band / rate * Double(n))
        var sig = 0.0, all = 0.0
        for k in 3..<kb { let p = re[k] * re[k] + im[k] * im[k]; all += p; if abs(k - kc) <= 3 { sig += p } }
        return 10 * log10(sig / max(1e-300, all - sig))
    }

    /// Hann-windowed single-bin amplitude of a tone in a real signal.
    private func toneAmp(_ x: [Double], rate: Double, freq: Double) -> Double {
        var re = 0.0, im = 0.0, ws = 0.0
        let m = x.count
        for i in 0..<m {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * (Double(i) + 0.5) / Double(m))
            let ph = 2 * Double.pi * freq * Double(i) / rate
            re += x[i] * w * cos(ph); im += x[i] * w * sin(ph); ws += w
        }
        return 2 * (re * re + im * im).squareRoot() / ws
    }

    private func bits(_ bytes: [UInt8]) -> [Double] {
        var out: [Double] = []; out.reserveCapacity(bytes.count * 8)
        for b in bytes { for k in (0..<8).reversed() { out.append((b >> UInt8(k)) & 1 == 1 ? 1 : -1) } }
        return out
    }

    private func modulate(_ order: DSDModulatorOrder, _ rate: DSDOutputRate, count: Int, _ gen: (Int) -> Double) -> (bits: [Double], overloads: Int) {
        let m = SigmaDeltaModulator(order: order, osr: rate.rawValue)!
        let x = (0..<count).map(gen)
        var bytes = [UInt8](repeating: 0, count: count / 8)
        x.withUnsafeBufferPointer { xp in bytes.withUnsafeMutableBufferPointer { m.process(xp.baseAddress!, count: count, into: $0.baseAddress!) } }
        return (bits(bytes), m.overloads)
    }

    // MARK: modulator

    func tablesAreComplete() {
        for order in DSDModulatorOrder.allCases { for rate in DSDOutputRate.allCases {
            guard let e = ModulatorTables.entries.first(where: { $0.order == order.rawValue && $0.osr == rate.rawValue }) else { expect(false, "no table for \(order) \(rate)"); continue }
            expect(e.b.count == order.rawValue && e.a.count == order.rawValue, "coefficient counts")
            expect(e.hinf >= 1.2 && e.hinf <= 1.5, "out-of-band gain \(e.hinf) of order \(order.rawValue) at OSR \(rate.rawValue) is outside Lee's limit")
            // magnitude of NTF = b/a at angle w
            func mag(_ w: Double) -> Double {
                var nr = 1.0, ni = 0.0, dr = 1.0, di = 0.0
                for k in 0..<e.b.count {
                    nr += e.b[k] * cos(Double(k + 1) * w); ni -= e.b[k] * sin(Double(k + 1) * w)
                    dr += e.a[k] * cos(Double(k + 1) * w); di -= e.a[k] * sin(Double(k + 1) * w)
                }
                return ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
            }
            var worst = 0.0
            for i in 1..<2000 { worst = max(worst, mag(Double.pi * Double(i) / 2000)) }
            expect(abs(worst - e.hinf) < 0.02, "tabulated gain \(e.hinf), measured \(worst)")
            expect(db(mag(0.9 * Double.pi / Double(rate.rawValue))) < -60, "in-band suppression at the band edge")
            // the denominator must be stable: its impulse response decays
            var h = [Double](repeating: 0, count: e.a.count)
            var peak = 0.0
            for n in 0..<20_000 {
                var y = n == 0 ? 1.0 : 0.0
                for k in 0..<e.a.count { y -= e.a[k] * h[k] }
                h.removeLast(); h.insert(y, at: 0)
                if n > 15_000 { peak = max(peak, abs(y)) }
            }
            expect(peak < 1e-6, "denominator impulse response has not decayed (\(peak))")
        } }
    }

    func modulatorIsQuietInBand() {
        let n = 1 << 18, cycles = 191.0
        for (order, rate, need) in [(DSDModulatorOrder.fifth, DSDOutputRate.dsd64, 100.0), (.seventh, .dsd64, 108), (.fifth, .dsd128, 120), (.seventh, .dsd128, 125)] {
            let fs = rate.hz(base: 44_100)
            let r = modulate(order, rate, count: n) { 0.5 * sin(2 * Double.pi * cycles * Double($0) / Double(n)) }
            let snr = inBandSNR(r.bits, rate: fs, freq: cycles / Double(n) * fs, band: 22_050)
            expect(snr >= need, "\(order.title) \(rate.name): \(String(format: "%.1f", snr)) dB in band, wanted \(need)")
            expect(r.overloads == 0, "\(order.title) \(rate.name) overloaded \(r.overloads) times")
        }
    }

    func modulatorStaysStable() {
        let n = 1 << 18
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Double { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Double(Int64(bitPattern: seed) >> 11) / Double(1 << 52) }
        for order in DSDModulatorOrder.allCases { for rate in [DSDOutputRate.dsd64, .dsd512] {
            var lp = 0.0
            let loud: [(String, (Int) -> Double)] = [
                ("0.6 sine", { 0.6 * sin(2 * Double.pi * 191 * Double($0) / Double(n)) }),
                ("square", { sin(2 * Double.pi * 40 * Double($0) / Double(n)) >= 0 ? 0.6 : -0.6 }),
                ("high tone", { 0.6 * sin(2 * Double.pi * 191 * 20 * Double($0) / Double(n)) }),
                ("noise", { _ in lp = 0.98 * lp + 0.02 * noise() * 8; return max(-0.6, min(0.6, lp)) }),
                ("over-range", { 3 * sin(2 * Double.pi * 191 * Double($0) / Double(n)) }),
            ]
            for (name, gen) in loud {
                let r = modulate(order, rate, count: n, gen)
                expect(r.overloads == 0, "\(order.title) \(rate.name) overloaded on \(name)")
                let ones = r.bits.filter { $0 > 0 }.count
                expect(ones > n / 10 && ones < n * 9 / 10, "\(order.title) \(rate.name) stuck on \(name)")
            }
        } }
        // DC: the density of ones is (1 + x) / 2
        let dc = modulate(.seventh, .dsd64, count: n) { _ in 0.25 }
        let mean = dc.bits.reduce(0, +) / Double(n)
        expect(abs(mean - 0.25) < 2e-3, "mean of a 0.25 input is \(mean)")
        let silence = modulate(.seventh, .dsd64, count: n) { _ in 0 }
        expect(abs(silence.bits.reduce(0, +) / Double(n)) < 2e-3, "silence has no DC")
    }

    func streamingEqualsOneShot() {
        let n = 1 << 14
        let x = (0..<n).map { 0.5 * sin(2 * Double.pi * 37 * Double($0) / Double(n)) }
        func run(_ blocks: [Int]) -> [UInt8] {
            let m = SigmaDeltaModulator(order: .seventh, osr: 64)!
            var out = [UInt8](repeating: 0, count: n / 8)
            var p = 0
            for b in blocks { x.withUnsafeBufferPointer { xp in out.withUnsafeMutableBufferPointer { m.process(xp.baseAddress! + p, count: b, into: $0.baseAddress! + p / 8) } }; p += b }
            return out
        }
        expect(run([n]) == run([8, 4096, 1024, n - 8 - 4096 - 1024]), "the modulator keeps its state between calls")
    }

    // MARK: interpolation

    func halfbandInterpolates() {
        let rate = 705_600.0, n = 1 << 14
        let h = HalfbandInterpolator(inputRate: rate, bandEdge: 24_000, maxBlock: n)
        let f = 20_000.0
        let x = (0..<n).map { 0.5 * sin(2 * Double.pi * f * Double($0) / rate) }
        var y = [Double](repeating: 0, count: 2 * n)
        x.withUnsafeBufferPointer { xp in y.withUnsafeMutableBufferPointer { h.process(xp.baseAddress!, count: n, into: $0.baseAddress!) } }
        let body = Array(y[2000..<(2 * n - 2000)])
        let a = toneAmp(body, rate: 2 * rate, freq: f)
        expect(abs(db(a / 0.5)) < 0.001, "pass-band gain off by \(db(a / 0.5)) dB")
        let image = toneAmp(body, rate: 2 * rate, freq: rate - f)
        expect(db(image / 0.5) < -110, "image of 20 kHz only \(db(image / 0.5)) dB down")
        // the same, fed in pieces
        let h2 = HalfbandInterpolator(inputRate: rate, bandEdge: 24_000, maxBlock: n)
        var z = [Double](repeating: 0, count: 2 * n)
        var p = 0
        for b in [1, 7, 4096, 333, n - 1 - 7 - 4096 - 333] {
            x.withUnsafeBufferPointer { xp in z.withUnsafeMutableBufferPointer { h2.process(xp.baseAddress! + p, count: b, into: $0.baseAddress! + 2 * p) } }; p += b
        }
        expect(zip(y, z).allSatisfy { abs($0 - $1) < 1e-12 }, "interpolating in pieces gives the same samples")
    }

    // MARK: the source

    private func dopBits(_ words: [Int32], channels: Int, channel: Int, from: Int, count: Int) -> [Double] {
        var out: [Double] = []; out.reserveCapacity(count)
        var f = from / 16
        while out.count < count + (from % 16) {
            let w = words[f * channels + channel]
            let b1 = UInt8((w >> 16) & 0xFF), b2 = UInt8((w >> 8) & 0xFF)
            out += bits([b1, b2]); f += 1
        }
        return Array(out[(from % 16)..<(from % 16 + count)])
    }

    func sourceMakesCleanDoP() {
        let plan = DSDOutputPlan(rate: .dsd64, base: 44_100, order: .seventh)
        expect(plan.carrier == 176_400 && plan.intermediateRate == 705_600 && plan.interpolation == 4, "DSD64 plan")
        let n = 1 << 17, k = [95.0, 137.0]
        let freqs = k.map { $0 * plan.dsdRate / Double(n) }
        let tone = TestTone(rate: plan.intermediateRate, frames: 176_400, freqs: freqs, amp: 0.5)
        let src = PCMToDSDSource(tone, plan: plan)!
        expect(src.info.isDoP && src.info.sampleRate == 176_400 && src.info.channels == 2 && !src.info.transparent, "stream info")
        let words = readAll(src)
        expect(words.count / 2 == Int(src.info.totalFrames), "produced \(words.count / 2) frames, announced \(src.info.totalFrames)")
        expect(words.allSatisfy { $0 & ~0x00FF_FF00 == 0 }, "marker and low byte are left clear for the DoP stamp")
        for c in 0..<2 {
            let b = dopBits(words, channels: 2, channel: c, from: 1 << 15, count: n)
            let snr = inBandSNR(b, rate: plan.dsdRate, freq: freqs[c], band: 22_050)
            expect(snr >= 105, "channel \(c): \(String(format: "%.1f", snr)) dB in band")
            let a = toneAmp(b, rate: plan.dsdRate, freq: freqs[c])
            expect(abs(db(a / 0.25)) < 0.1, "channel \(c): level \(db(a / 0.25)) dB off")
            let other = toneAmp(b, rate: plan.dsdRate, freq: freqs[1 - c])
            expect(db(other / 0.25) < -95, "channel \(c) carries \(db(other / 0.25)) dB of the other channel")
        }
        expect(src.overloads == 0, "no overloads")
        // stamped, the markers alternate and the payload survives
        let stamped = readAll(DoPStampSource(PCMToDSDSource(TestTone(rate: plan.intermediateRate, frames: 16_384, freqs: freqs, amp: 0.5), plan: plan)!, clock: DoPClock()))
        expect((0..<(stamped.count / 2)).allSatisfy { (stamped[$0 * 2] >> 24) & 0xFF == ($0 % 2 == 0 ? 0x05 : 0xFA) }, "DoP markers alternate")
    }

    func sourceSeeks() {
        for rate in [DSDOutputRate.dsd64, .dsd128, .dsd512] {
            let plan = DSDOutputPlan(rate: rate, base: 44_100, order: .fifth)
            let I = plan.intermediateRate
            let f = 1_000 * 2.0
            let src = PCMToDSDSource(TestTone(rate: I, frames: Int(I * 0.05), freqs: [f, f], amp: 0.4), plan: plan)!
            let total = Int(src.info.totalFrames)
            _ = readAll(src)
            let at = total / 3
            src.seek(to: Int64(at))
            let rest = readAll(src)
            expect(rest.count / 2 == total - at, "\(rate.name): \(rest.count / 2) frames after a seek to \(at) of \(total)")
            src.seek(to: 0)
            expect(readAll(src).count / 2 == total, "\(rate.name): rewinds")
        }
    }

    func speedIsMeasured() {
        let v = PCMToDSDSource.benchmarkBitsPerSecond()
        expect((v ?? 0) > 5_000_000, "measured \(String(describing: v)) bits per second")
    }

    // MARK: choosing a rate

    private func machine(modulator: Double? = 3e8, resample: Double = 9e6) -> PerformanceProfile {
        PerformanceProfile(architecture: "arm64", model: "Test Mac", cores: 8, memoryBytes: 16 << 30, outFramesPerSecond: resample, dsdBitsPerSecond: 9e8, modulatorBitsPerSecond: modulator)
    }

    func plannerPicksTheRate() {
        var s = DSDOutputSettings(); s.enabled = true
        let all: [Double] = [44_100, 88_200, 176_400, 352_800, 705_600, 1_411_200, 48_000, 96_000, 192_000, 384_000, 768_000, 1_536_000]
        func plan(_ s: DSDOutputSettings, _ rate: Double = 44_100, _ ch: Int = 2, rates: [Double] = all, _ m: PerformanceProfile? = nil, cost: Double = 1) -> DSDOutputPlan? {
            DSDOutputPlanner.plan(settings: s, sourceRate: rate, channels: ch, deviceRates: rates, profile: m ?? machine(), filterCost: cost).plan
        }
        var p = plan(s)
        expect(p?.rate == .dsd512 && p?.base == 44_100 && p?.carrier == 1_411_200 && p?.intermediateRate == 1_411_200, "a DAC with 1.4112 MHz DoP gets DSD512")
        expect(plan(s, rates: all.filter { $0 != 1_411_200 && $0 != 1_536_000 })?.rate == .dsd256, "without it, DSD256")
        expect(plan(s, rates: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000])?.rate == .dsd64, "a DAC that stops at 192 kHz gets DSD64")
        expect(plan(s, rates: [44_100, 48_000, 88_200, 96_000])?.rate == nil, "no DoP rate at all: PCM")
        expect(plan(s, rates: [])?.rate == .dsd64, "an unknown device is trusted with DSD64 only")
        var cap = s; cap.maxRate = .dsd128
        expect(plan(cap)?.rate == .dsd128 && plan(cap)?.intermediateRate == 705_600, "the setting caps the rate")
        p = plan(s, 48_000)
        expect(p?.base == 48_000 && p?.carrier == 1_536_000, "48 kHz material stays in the 48 kHz family when the DAC offers it")
        expect(plan(s, 48_000, rates: all.filter { $0 != 1_536_000 && $0 != 768_000 && $0 != 384_000 && $0 != 192_000 })?.base == 44_100, "and falls back to the 44.1 kHz family when it does not")
        expect(plan(s, 44_100, 1) == nil && plan(s, 44_100, 6) == nil, "only stereo is converted")
        expect(plan(s, 1_411_200)?.rate == .dsd512, "material already at the intermediate rate needs no resampling")
        // the machine decides
        expect(plan(s, 44_100, 2, rates: all, machine(modulator: 4e7))?.rate != .dsd512, "a slow modulator lowers the rate")
        expect(plan(s, 44_100, 2, rates: all, machine(resample: 2e6)) == nil || plan(s, 44_100, 2, rates: all, machine(resample: 2e6))?.rate != .dsd512, "a slow resampler lowers the rate")
        expect(plan(s, cost: 6)?.rate != .dsd512, "a long filter costs processing, so DSD512 gives way")
        let r = DSDOutputPlanner.plan(settings: s, sourceRate: 44_100, channels: 2, deviceRates: all, profile: machine(modulator: 4e7), filterCost: 1)
        expect(r.note?.contains("too heavy") == true, "the lower rate is explained: \(String(describing: r.note))")
        expect(DSDOutputPlanner.plan(settings: s, sourceRate: 44_100, channels: 1, deviceRates: all, profile: machine(), filterCost: 1).note != nil, "mono is explained")
    }

    func settingsAreTolerant() {
        let d = JSONDecoder()
        let s = try! d.decode(PlaybackSettings.self, from: Data("{}".utf8))
        expect(s.dsdOutput == DSDOutputSettings() && !s.dsdOutput.enabled, "old settings load with PCM-to-DSD off")
        let o = try! d.decode(DSDOutputSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        expect(o.enabled && o.maxRate == .dsd512 && o.modulator == .seventh, "missing keys take their defaults")
        let c = try! d.decode(ResamplerConfig.self, from: Data(#"{"phase":"minimum","passband":0.9,"stopbandDB":96}"#.utf8))
        expect(c.phase == .minimum && c.shape == .plain && c.passband == 0.9, "a filter saved before the shapes existed still loads")
        var a = PlaybackSettings(), b = a
        b.upsampling.chosenFilter = .brickwall
        expect(a.streamKey == b.streamKey, "changing the filter never rebuilds the stream")
        a.dsdOutput.enabled = true
        expect(a.streamKey != b.streamKey, "turning DSD output on does")
        let back = try! d.decode(PlaybackSettings.self, from: try! JSONEncoder().encode(a))
        expect(back == a, "round trip")
    }

    func conflictsAreAnnounced() {
        var base = PlaybackSettings(); base.dsd.mode = .dop
        var on = base; on.dsdOutput.enabled = true
        expect(SettingRules.check(old: base, new: on) == nil, "nothing in the way: no question")
        var withRoom = on; withRoom.rt.convolution.enabled = true
        let c = SettingRules.check(old: on, new: withRoom)
        expect(c != nil, "room correction clashes with DSD output")
        if let c { var fixed = withRoom; c.fix(&fixed); expect(!fixed.rt.convolution.enabled && SettingRules.check(old: on, new: fixed) == nil, "the fix removes the clash") }
        var noDoP = PlaybackSettings(); noDoP.dsdOutput.enabled = true
        let d = SettingRules.check(old: PlaybackSettings(), new: noDoP)
        expect(d != nil, "DSD output without DoP is questioned")
        if let d { var fixed = noDoP; d.fix(&fixed); expect(fixed.dsd.mode == .dop, "the fix enables DoP") }
    }

    // MARK: filters

    func filtersHaveTheirCharacter() {
        for f in OversamplingFilter.allCases { expect(OversamplingFilter(f.applied(to: .standard)) == f, "\(f.title) round trip") }
        let std = ResamplerConfig.standard.tapsPerPhase
        let apo = OversamplingFilter.apodizing.applied(to: .standard).tapsPerPhase, brick = OversamplingFilter.brickwall.applied(to: .standard).tapsPerPhase
        expect(apo < std && std < brick, "apodizing \(apo), standard \(std), brickwall \(brick) taps per phase")
        let cost = OversamplingFilter.brickwall.applied(to: .standard).costFactor
        expect(cost > 4.5 && cost < 8, "brickwall costs \(cost)× the standard filter")
        // the design really has that many taps per phase
        let d = PolyphaseDesign(L: 2, M: 1, config: OversamplingFilter.brickwall.applied(to: .standard))
        expect(abs(d.taps - brick) <= 4, "\(d.taps) built, \(brick) estimated")
    }

    private func through(_ filter: OversamplingFilter, freq: Double, from: Int = 44_100, to: Double = 88_200) -> Double {
        let url = sineWAV(tempDir().appendingPathComponent("flt-\(filter.rawValue)-\(Int(freq)).wav"), rate: from, freq: freq, amp: 0.5, seconds: 1.0)
        let r = ResamplingSource(try! LosslessFile(path: url.path), outRate: to, config: filter.applied(to: .standard))!
        let y = readAll(r)
        return amplitude(y, channels: 2, rate: to, freq: freq, skip: 8000, count: Int(to) / 2) / 0.5
    }

    func filterResponses() {
        // the apodizing filter is flat to about 17 kHz, well down by 21 kHz
        expect(abs(db(through(.apodizing, freq: 10_000))) < 0.01 && abs(db(through(.apodizing, freq: 17_000))) < 0.05, "apodizing pass-band")
        expect(db(through(.apodizing, freq: 21_500)) < -40, "apodizing at 21.5 kHz: \(db(through(.apodizing, freq: 21_500))) dB")
        // brickwall is flat to the very edge
        expect(abs(db(through(.brickwall, freq: 21_500))) < 0.01, "brickwall at 21.5 kHz: \(db(through(.brickwall, freq: 21_500))) dB")
        // the standard filter has started to fall there
        expect(db(through(.linearPhase, freq: 21_900)) < db(through(.brickwall, freq: 21_900)) - 3, "brickwall is flatter than linear phase near Nyquist")
        for f in OversamplingFilter.allCases {
            let url = tempDir().appendingPathComponent("flt-\(f.rawValue)-img.wav")
            _ = sineWAV(url, rate: 44_100, freq: 20_000, amp: 0.5, seconds: 1.0)
            let y = readAll(ResamplingSource(try! LosslessFile(path: url.path), outRate: 88_200, config: f.applied(to: .standard))!)
            let a = amplitude(y, channels: 2, rate: 88_200, freq: 24_100, skip: 8000, count: 40_000) / 0.5
            expect(db(a) < -105, "\(f.title): image at 24.1 kHz only \(db(a)) dB down")
        }
    }

    // MARK: swapping the filter of a running resampler

    private func wait(_ timeout: TimeInterval = 20, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    }

    func filterSwapsWhilePlaying() {
        let url = sineWAV(tempDir().appendingPathComponent("swap.wav"), rate: 44_100, freq: 1_000, amp: 0.5, seconds: 2.0)
        let target = OversamplingFilter.apodizing.applied(to: .standard)
        let reference = readAll(ResamplingSource(try! LosslessFile(path: url.path), outRate: 88_200, config: target)!)
        let original = readAll(ResamplingSource(try! LosslessFile(path: url.path), outRate: 88_200, config: .standard)!)
        expect(reference != original, "the two filters differ")

        let sw = FilterSwitch(.standard)
        let r = ResamplingSource(try! LosslessFile(path: url.path), outRate: 88_200, config: .standard, control: sw)!
        var out: [Int32] = []
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 512 * 2); defer { buf.deallocate() }
        func pull() -> Int { let n = r.read(into: buf, frames: 512); out.append(contentsOf: UnsafeBufferPointer(start: buf, count: n * 2)); return n }
        for _ in 0..<20 { _ = pull() }
        expect(Array(out[0..<out.count]) == Array(original[0..<out.count]), "before the request nothing changes")
        expect(sw.request(target) && !sw.request(target), "a request is counted once")
        var guardCount = 0
        while !sw.isReady && guardCount < 3000 { _ = pull(); Thread.sleep(forTimeInterval: 0.005); guardCount += 1 }
        expect(sw.isReady, "the design is built in the background")
        let readyAt = out.count / 2
        _ = pull()
        while pull() > 0 {}
        let fade = Int(88_200 * 0.02)
        let from = readyAt + 512 + fade + 8
        expect(out.count == reference.count, "same length: \(out.count / 2) / \(reference.count / 2)")
        if from < reference.count / 2 {
            expect(Array(out[(from * 2)...]) == Array(reference[(from * 2)...]), "after the crossfade the output is exactly the new filter's")
        }
        var step: Int64 = 0
        for i in 1..<(out.count / 2) { step = max(step, abs(Int64(out[i * 2]) - Int64(out[(i - 1) * 2]))) }
        let sineStep = 0.5 * 2 * Double.pi * 1000 / 88_200 * 2_147_483_648
        expect(Double(step) < sineStep * 1.25, "no click at the swap: largest step \(Double(step) / sineStep) of a sine's")

        // repositioning swaps at once, with no fade
        let sw2 = FilterSwitch(.standard)
        let r2 = ResamplingSource(try! LosslessFile(path: url.path), outRate: 88_200, config: .standard, control: sw2)!
        sw2.request(target)
        r2.seek(to: 0)                                    // starts the build
        wait { sw2.isReady }
        expect(sw2.isReady, "built")
        r2.seek(to: 30_000)
        let got = UnsafeMutablePointer<Int32>.allocate(capacity: 1000 * 2); defer { got.deallocate() }
        let n = r2.read(into: got, frames: 1000)
        expect(n == 1000 && (0..<2000).allSatisfy { got[$0] == reference[60_000 + $0] }, "after a seek the new filter is in place from the first sample")
    }

    func filterTooHeavyIsDeclined() {
        let slow = PerformanceProfile(architecture: "x86_64", model: "slow", cores: 2, memoryBytes: 8 << 30, outFramesPerSecond: 150_000, dsdBitsPerSecond: 1e8)
        PerformanceProfile.testOverride = slow
        defer { PerformanceProfile.testOverride = nil }
        let url = sineWAV(tempDir().appendingPathComponent("heavy.wav"), rate: 44_100, freq: 1_000, amp: 0.5, seconds: 1.0)
        let sw = FilterSwitch(.standard)
        let r = ResamplingSource(try! LosslessFile(path: url.path), outRate: 88_200, config: .standard, control: sw)!
        let original = readAll(ResamplingSource(try! LosslessFile(path: url.path), outRate: 88_200, config: .standard)!)
        sw.request(OversamplingFilter.brickwall.applied(to: .standard))
        let out = readAll(r)
        expect(out == original, "a filter the Mac cannot afford is not switched to")
        expect(sw.takeRefusal()?.contains("brickwall") == true && sw.takeRefusal() == nil, "and the reason is given once")
    }
}

func dsdOutputTests() -> [(String, TestFn)] {
    let t = DSDOutputTests()
    return [("dsdOut.tables", t.tablesAreComplete), ("dsdOut.modulatorSNR", t.modulatorIsQuietInBand), ("dsdOut.modulatorStable", t.modulatorStaysStable),
            ("dsdOut.modulatorStreaming", t.streamingEqualsOneShot), ("dsdOut.halfband", t.halfbandInterpolates), ("dsdOut.sourceDoP", t.sourceMakesCleanDoP),
            ("dsdOut.sourceSeek", t.sourceSeeks), ("dsdOut.speed", t.speedIsMeasured), ("dsdOut.planner", t.plannerPicksTheRate),
            ("dsdOut.settings", t.settingsAreTolerant), ("dsdOut.conflicts", t.conflictsAreAnnounced), ("filters.character", t.filtersHaveTheirCharacter),
            ("filters.responses", t.filterResponses), ("filters.liveSwap", t.filterSwapsWhilePlaying), ("filters.tooHeavy", t.filterTooHeavyIsDeclined)]
}

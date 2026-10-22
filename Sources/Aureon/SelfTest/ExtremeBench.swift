import Foundation

struct ExtremeBench {
    let dir = tempDir("extreme")

    private func randomDSF(_ name: String, rate: Int, seconds: Double, channels: Int = 2) -> URL {
        var rng = SplitMix(seed: 5)
        let n = Int(Double(rate) * seconds) / 8 / 4096 * 4096
        let bytes = (0..<channels).map { _ in (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }
        let f = dir.appendingPathComponent(name); writeDSF(f, rate: rate, channelBytes: bytes)
        return f
    }

    func bench() {
        for (name, rate, target) in [("DSD64", 2_822_400, 176_400.0), ("DSD256", 11_289_600, 176_400), ("DSD512", 22_579_200, 176_400), ("DSD1024", 45_158_400, 176_400)] {
            let f = randomDSF("b\(name).dsf", rate: rate, seconds: 1.0)
            let c = try! DsdContainer(path: f.path)
            guard let src = DsdToPcmSource(c, codec: name, pcmRate: target, gainDB: 0) else { print("BENCH \(name): no source"); continue }
            let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * 2); defer { buf.deallocate() }
            let t0 = Date(); var frames = 0
            while true { let n = src.read(into: buf, frames: 4096); if n == 0 { break }; frames += n }
            let took = Date().timeIntervalSince(t0)
            print(String(format: "BENCH %@ → %.1f kHz: %d frames in %.2f s = %.1f× real time", name, target / 1000, frames, took, Double(frames) / target / took))
        }
    }
}

extension ExtremeBench {
    func benchFast() {
        for (name, rate, target) in [("DSD64", 2_822_400, 176_400.0), ("DSD128", 5_644_800, 176_400), ("DSD256", 11_289_600, 176_400), ("DSD512", 22_579_200, 176_400), ("DSD1024", 45_158_400, 176_400), ("DSD1024", 45_158_400, 352_800)] {
            let f = randomDSF("f\(name).dsf", rate: rate, seconds: 1.0)
            let c = try! DsdContainer(path: f.path)
            guard let src = FastDsdToPcmSource(c, codec: name, pcmRate: target, gainDB: 0) else { print("FAST \(name): no source"); continue }
            let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * 2); defer { buf.deallocate() }
            let t0 = Date(); var frames = 0
            while true { let n = src.read(into: buf, frames: 4096); if n == 0 { break }; frames += n }
            let took = Date().timeIntervalSince(t0)
            print(String(format: "FAST %@ → %.1f kHz: %d frames in %.2f s = %.1f× real time", name, target / 1000, frames, took, Double(frames) / target / took))
        }
    }
}

extension ExtremeBench {
    private func toneDSF(_ name: String, rate: Int, freqs: [Double], amp: Double, seconds: Double) -> URL {
        let f = dir.appendingPathComponent(name)
        writeDSF(f, rate: rate, channelBytes: freqs.enumerated().map { dsdBytes(rate: Double(rate), freq: $1, amp: amp, seconds: seconds, seed: $0) }.map { b in Array(b.prefix(b.count / 4096 * 4096)) })
        return f
    }

    private func readAllFrames(_ s: FrameSource) -> [Int32] {
        let ch = s.info.channels, buf = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * ch); defer { buf.deallocate() }
        var out: [Int32] = []
        while true { let n = s.read(into: buf, frames: 4096); if n == 0 { break }; out.append(contentsOf: UnsafeBufferPointer(start: buf, count: n * ch)) }
        return out
    }

    func ratesAreSupportedOrNot() {
        expect(FastDsdToPcmSource.supports(dsdRate: 2_822_400, pcmRate: 176_400) && FastDsdToPcmSource.supports(dsdRate: 45_158_400, pcmRate: 176_400) && FastDsdToPcmSource.supports(dsdRate: 45_158_400, pcmRate: 352_800))
        expect(FastDsdToPcmSource.supports(dsdRate: 3_072_000, pcmRate: 192_000) && FastDsdToPcmSource.supports(dsdRate: 11_289_600, pcmRate: 88_200))
        expect(!FastDsdToPcmSource.supports(dsdRate: 2_822_400, pcmRate: 44_100 * 3) && !FastDsdToPcmSource.supports(dsdRate: 2_822_400, pcmRate: 2_822_400) && !FastDsdToPcmSource.supports(dsdRate: 2_822_400, pcmRate: 352_800 * 4))
        expect(!FastDsdToPcmSource.supports(dsdRate: 2_822_400, pcmRate: 2_822_400 / 24), "ratio 24 is not 8 × a power of two")
    }

    func cascadeMatchesTheSingleFilter() {
        // DSD256, 1 kHz and 7 kHz tones on two channels
        let f = toneDSF("cmp.dsf", rate: 11_289_600, freqs: [1000, 7000], amp: 0.4, seconds: 1.0)
        let c1 = try! DsdContainer(path: f.path), c2 = try! DsdContainer(path: f.path)
        let old = readAllFrames(DsdToPcmSource(c1, codec: "DSD256", pcmRate: 176_400, gainDB: 0)!), new = readAllFrames(FastDsdToPcmSource(c2, codec: "DSD256", pcmRate: 176_400, gainDB: 0)!)
        expect(old.count == new.count, "same length: \(old.count) vs \(new.count)")
        for (ch, freq) in [(0, 1000.0), (1, 7000.0)] {
            let a = amplitude(old, channels: 2, channel: ch, rate: 176_400, freq: freq, skip: 20_000, count: 100_000), b = amplitude(new, channels: 2, channel: ch, rate: 176_400, freq: freq, skip: 20_000, count: 100_000)
            expect(abs(db(a / b)) < 0.02 && abs(b - 0.4) < 0.01, "channel \(ch): the tone is \(b) (single filter \(a))")
            let other = amplitude(new, channels: 2, channel: ch, rate: 176_400, freq: ch == 0 ? 7000 : 1000, skip: 20_000, count: 100_000)
            expect(other < 2e-4, "the channels stay separate: \(other)")
        }
        // the same moment in time: the 1 kHz phase agrees to well under half an output sample
        func phase(_ x: [Int32]) -> Double {
            var re = 0.0, im = 0.0
            for i in 0..<100_000 { let v = Double(x[(20_000 + i) * 2]) / 2_147_483_648; let ph = 2 * Double.pi * 1000 * Double(20_000 + i) / 176_400; re += v * cos(ph); im += v * sin(ph) }
            return atan2(im, re)
        }
        expect(abs(phase(old) - phase(new)) < 0.03, "aligned in time: \(phase(old)) vs \(phase(new)) rad")
    }

    func cascadeRejectsWhatItShould() {
        // A tone at 110 kHz in DSD256 must not fold back into the audio band of a 176.4 kHz stream (it would appear at 66.4 kHz)
        let f = toneDSF("alias.dsf", rate: 11_289_600, freqs: [110_000, 1000], amp: 0.3, seconds: 0.6)
        let out = readAllFrames(FastDsdToPcmSource(try! DsdContainer(path: f.path), codec: "DSD256", pcmRate: 176_400, gainDB: 0)!)
        let folded = amplitude(out, channels: 2, channel: 0, rate: 176_400, freq: 66_400, skip: 8_000, count: 60_000)
        expect(db(folded / 0.3) < -95, "the alias is \(db(folded / 0.3)) dB down")
        let direct = amplitude(out, channels: 2, channel: 0, rate: 176_400, freq: 110_000, skip: 8_000, count: 60_000)
        expect(direct < 1e-3, "nothing at 110 kHz either")
        // passband: 60 kHz is inside 0.4 × fs and survives at full level
        let g = toneDSF("pass.dsf", rate: 11_289_600, freqs: [60_000, 20_000], amp: 0.3, seconds: 0.6)
        let p = readAllFrames(FastDsdToPcmSource(try! DsdContainer(path: g.path), codec: "DSD256", pcmRate: 176_400, gainDB: 0)!)
        expect(abs(db(amplitude(p, channels: 2, channel: 0, rate: 176_400, freq: 60_000, skip: 8_000, count: 60_000) / 0.3)) < 0.3, "60 kHz is flat")
        expect(abs(db(amplitude(p, channels: 2, channel: 1, rate: 176_400, freq: 20_000, skip: 8_000, count: 60_000) / 0.3)) < 0.05, "20 kHz is flat")
    }

    func seekingGivesTheSameSamples() {
        let f = toneDSF("seek.dsf", rate: 11_289_600, freqs: [1500, 2500], amp: 0.4, seconds: 1.0)
        let whole = readAllFrames(FastDsdToPcmSource(try! DsdContainer(path: f.path), codec: "DSD256", pcmRate: 176_400, gainDB: 0)!)
        let s = FastDsdToPcmSource(try! DsdContainer(path: f.path), codec: "DSD256", pcmRate: 176_400, gainDB: 0)!
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 2 * 3000); defer { buf.deallocate() }
        for start in [0, 1, 5_000, 60_001, 150_000] {
            s.seek(to: Int64(start))
            let n = s.read(into: buf, frames: 3000)
            var worst: Int32 = 0
            for i in 0..<(n * 2) { worst = max(worst, abs(buf[i] &- whole[start * 2 + i])) }
            expect(n == 3000 && worst <= 2, "seek to \(start): largest difference \(worst) of 2^31")
        }
        // and the very end of the file is silence-padded to the exact length
        s.seek(to: Int64(whole.count / 2 - 100))
        expect(s.read(into: buf, frames: 3000) == 100, "the tail ends at the exact frame count")
        expect(s.read(into: buf, frames: 10) == 0)
    }

    func hugeRatesRunFasterThanRealTime() {
        var rng = SplitMix(seed: 11)
        for (name, rate, floor) in [("DSD512", 22_579_200, 3.0), ("DSD1024", 45_158_400, 2.0)] {
            let n = Int(Double(rate) * 0.5) / 8 / 4096 * 4096
            let f = dir.appendingPathComponent("huge\(name).dsf"); writeDSF(f, rate: rate, channelBytes: (0..<2).map { _ in (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) } })
            let src = DsdToPcm.make(try! DsdContainer(path: f.path), codec: name, pcmRate: 176_400, gainDB: 0)!
            expect(src is FastDsdToPcmSource, "\(name) uses the cascade")
            let t = Date(); let frames = readAllFrames(src).count / 2
            let rt = Double(frames) / 176_400 / Date().timeIntervalSince(t)
            expect(rt > floor, "\(name) → 176.4 kHz at \(rt)× real time")
        }
    }

    func multichannelDSDWorksThroughTheCascade() {
        let f = dir.appendingPathComponent("six.dsf")
        writeDSF(f, rate: 11_289_600, channelBytes: (0..<6).map { dsdBytes(rate: 11_289_600, freq: 1000 + Double($0) * 700, amp: 0.3, seconds: 0.4, seed: $0).prefix(11_289_600 * 4 / 10 / 8 / 4096 * 4096).map { $0 } })
        let out = readAllFrames(FastDsdToPcmSource(try! DsdContainer(path: f.path), codec: "DSD256", pcmRate: 88_200, gainDB: 0)!)
        for c in 0..<6 {
            let a = amplitude(out, channels: 6, channel: c, rate: 88_200, freq: 1000 + Double(c) * 700, skip: 4_000, count: 20_000)
            expect(abs(a - 0.3) < 0.01, "channel \(c) carries its own tone: \(a)")
        }
    }
}

extension ExtremeBench {
    func benchResampler() {
        for (from, to) in [(44_100.0, 352_800.0), (44_100, 1_411_200), (48_000, 1_536_000), (96_000, 1_536_000), (192_000, 1_536_000)] {
            let f = sineWAV(dir.appendingPathComponent("rs\(Int(from)).wav"), rate: Int(from), bits: 24, freq: 1000, amp: 0.5, seconds: 2)
            let base = try! LosslessFile(path: f.path)
            guard let r = ResamplingSource(base, outRate: to, config: .standard) else { print("RESAMPLE \(from)→\(to): none"); continue }
            let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 8192 * 2); defer { buf.deallocate() }
            let t = Date(); var frames = 0
            while true { let n = r.read(into: buf, frames: 8192); if n == 0 { break }; frames += n }
            let took = Date().timeIntervalSince(t)
            print(String(format: "RESAMPLE %.1f → %.1f kHz: %.1f× real time", from / 1000, to / 1000, Double(frames) / to / took))
        }
    }
}

extension ExtremeBench {
    private func machine(_ framesPerSecond: Double, dsd: Double, memoryGB: Double = 16) -> PerformanceProfile {
        PerformanceProfile(architecture: "x86_64", model: "Test Mac", cores: 4, memoryBytes: UInt64(memoryGB * 1_073_741_824), outFramesPerSecond: framesPerSecond, dsdBitsPerSecond: dsd)
    }

    func theProfileDecidesWhatIsSustainable() {
        let m4 = machine(9_000_000, dsd: 900_000_000), oldIntel = machine(1_500_000, dsd: 90_000_000), mid = machine(4_000_000, dsd: 300_000_000)
        expect(m4.tier == .high && mid.tier == .medium && oldIntel.tier == .low, "\(m4.tier) \(mid.tier) \(oldIntel.tier)")
        expect(m4.canResample(to: 1_536_000, channels: 2) && !oldIntel.canResample(to: 1_536_000, channels: 2) && oldIntel.canResample(to: 352_800, channels: 2), "what each can resample to")
        expect(!m4.canResample(to: 1_536_000, channels: 8), "eight channels cost four times as much: \(m4.resampleFactor(rate: 1_536_000, channels: 8))")
        expect(oldIntel.capped(1_536_000, channels: 2, floor: 44_100) == 384_000, "the old Mac is held at \(oldIntel.capped(1_536_000, channels: 2, floor: 44_100))")
        expect(m4.capped(1_536_000, channels: 2, floor: 44_100) == 1_536_000 && oldIntel.capped(88_200, channels: 2, floor: 88_200) == 88_200)
        expect(m4.canDecodeDSD(rate: 45_158_400, channels: 2) && !oldIntel.canDecodeDSD(rate: 45_158_400, channels: 2) && oldIntel.canDecodeDSD(rate: 11_289_600, channels: 2), "DSD1024 vs DSD256")
        // buffers grow where the machine has less to spare, and only at high rates
        expect(m4.bufferSeconds(base: 5, rate: 1_536_000, channels: 2) == 5 && oldIntel.bufferSeconds(base: 5, rate: 1_536_000, channels: 2) == 10 && oldIntel.bufferSeconds(base: 5, rate: 96_000, channels: 2) == 5)
        expect(mid.bufferSeconds(base: 5, rate: 1_536_000, channels: 2) == 7.5 && mid.bufferSeconds(base: 5, rate: 192_000, channels: 2) == 5)
        expect(oldIntel.prefillSeconds(rate: 1_536_000) > m4.prefillSeconds(rate: 1_536_000) && m4.prefillSeconds(rate: 44_100) == 0.05)
        // the ring stays inside a share of the memory
        let small = machine(9_000_000, dsd: 9e8, memoryGB: 4)
        let frames = small.ringFrames(rate: 1_536_000, channels: 8, seconds: 10)
        expect(frames * 8 * 4 <= Int(4 * 1_073_741_824 / 6) && frames > 8192, "8 × 1536 kHz × 10 s would be 3.9 GB; the ring holds \(frames * 8 * 4 / 1_048_576) MB")
        expect(m4.ringFrames(rate: 44_100, channels: 2, seconds: 5) == 220_500, "an ordinary stream is untouched")
    }

    func measuringIsQuickAndSane() {
        let t = Date()
        let p = PerformanceProfile.measure()
        let took = Date().timeIntervalSince(t)
        expect(took < 3, "the benchmark takes \(took) s")
        expect(p.outFramesPerSecond > 500_000 && p.dsdBitsPerSecond > 20_000_000, "plausible figures: \(p.outFramesPerSecond) frames/s, \(p.dsdBitsPerSecond / 1e6) Mbit/s")
        expect(p.cores >= 1 && p.memoryBytes > 1 << 30 && !p.model.isEmpty && !p.summary.isEmpty, p.summary)
        expect(PerformanceProfile.fallback.outFramesPerSecond > 0)
    }

    private func play(_ f: URL, rates: [Double], settings: PlaybackSettings = PlaybackSettings(), channels: Int = 0) -> (Player, RecordingSink) {
        let sink = RecordingSink(rates: rates, speed: 0, outputChannels: channels)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.4; o.rateSwitch = false
        let p = Player(); p.settings = settings; p.setQueue([f.path]); p.start(options: o)
        _ = p.waitUntilFinished(timeout: 60)
        return (p, sink)
    }

    func upsamplingIsHeldBackOnAWeakMachine() {
        let f = sineWAV(dir.appendingPathComponent("up.wav"), rate: 44_100, bits: 24, freq: 1000, amp: 0.4, seconds: 1)
        var s = PlaybackSettings(); s.upsampling.mode = .deviceMax
        let rates = [44_100.0, 88_200, 176_400, 352_800, 705_600, 1_411_200]
        PerformanceProfile.testOverride = machine(9_000_000, dsd: 9e8)
        let (_, strong) = play(f, rates: rates, settings: s)
        expect(strong.configured.first?.sampleRate == 1_411_200, "a strong machine goes to the device maximum: \(String(describing: strong.configured.first?.sampleRate))")
        PerformanceProfile.testOverride = machine(1_500_000, dsd: 9e7)
        let (p, weak) = play(f, rates: rates, settings: s)
        let r = weak.configured.first?.sampleRate ?? 0
        expect(r > 44_100 && r <= 705_600, "a weak one is held to \(r)")
        expect(p.status.pipeline.contains { $0.contains("too heavy") } && weak.frameCount > 0, "and the path says why: \(p.status.pipeline)")
        PerformanceProfile.testOverride = nil
    }

    func dsd1024PlaysThroughTheEngine() {
        let n = 45_158_400 / 4 / 8 / 4096 * 4096
        var rng = SplitMix(seed: 3)
        let f = dir.appendingPathComponent("e1024.dsf"); writeDSF(f, rate: 45_158_400, channelBytes: (0..<2).map { _ in (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) } })
        let t = Date()
        let (p, sink) = play(f, rates: [44_100, 88_200, 176_400, 352_800])
        expect(sink.configured.first?.sampleRate == 176_400 && sink.configured.first?.sourceRate == 45_158_400, "converted to 176.4 kHz: \(String(describing: sink.configured.first))")
        expect(p.status.pipeline.contains { $0.contains("multi-stage") }, "\(p.status.pipeline)")
        expect(abs(Double(sink.frameCount) - 176_400.0 / 4) < 600, "a quarter of a second arrives: \(sink.frameCount) frames")
        expect(Date().timeIntervalSince(t) < 4, "in \(Date().timeIntervalSince(t)) s")
    }

    func megahertzPCMPassesThroughUnchanged() {
        let f = sineWAV(dir.appendingPathComponent("m1536.wav"), rate: 1_536_000, bits: 24, freq: 20_000, amp: 0.5, seconds: 1)
        let t = Date()
        let (p, sink) = play(f, rates: [1_536_000])
        expect(sink.configured.first?.sampleRate == 1_536_000, "the stream stays at 1536 kHz")
        expect(sink.samples == readAll(try! LosslessFile(path: f.path)), "and arrives sample for sample")
        expect(p.status.underruns == 0 && p.status.errors.isEmpty, "no underruns: \(p.status.underruns) \(p.status.errors)")
        expect(Date().timeIntervalSince(t) < 5, "a second of 1536 kHz stereo moved in \(Date().timeIntervalSince(t)) s")
    }

    func eightChannelsAtHighRates() {
        // 8 × 705.6 kHz: 5.6 million samples a second through the ring
        let full = Double((1 << 23) - 1)
        let f = writeWAV(dir.appendingPathComponent("e8.wav"), rate: 705_600, bits: 24, channels: 8, frames: 705_600) { fr, c in Int(0.3 * full * sin(2 * .pi * (1000 + Double(c) * 500) * Double(fr) / 705_600)) }
        let (p, sink) = play(f, rates: [705_600], channels: 8)
        expect(sink.configured.first?.channels == 8 && sink.samples == readAll(try! LosslessFile(path: f.path)), "eight channels at 705.6 kHz untouched")
        expect(p.status.underruns == 0, "no underruns")
    }
}

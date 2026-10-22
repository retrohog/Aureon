import Foundation

struct LoudnessTests {
    let dir = tempDir("r128")

    private func sine(_ seconds: Double, freq: Double, dB: Double, fs: Double = 48_000, channels: Int = 2, phase: Double = 0, start: Double = 0) -> [Float] {
        let n = Int(seconds * fs), a = pow(10, dB / 20)
        var out = [Float](repeating: 0, count: n * channels)
        for i in 0..<n { let v = Float(a * sin(2 * .pi * freq * (Double(i) / fs + start) + phase)); for c in 0..<channels { out[i * channels + c] = v } }
        return out
    }

    func filterMatchesTheReferenceBiquad() {
        let k = Loudness.kWeighting(sampleRate: 48_000)
        var ref = k.0
        let f = DeqBiquad(b0: k.0.b0, b1: k.0.b1, b2: k.0.b2, a1: k.0.a1, a2: k.0.a2, capacity: 1000)
        var rng = SplitMix(seed: 9)
        let x = (0..<10_000).map { _ in Double.random(in: -1...1, using: &rng) }
        var want = [Double](); for v in x { want.append(ref.process(v)) }
        var got = [Double](repeating: 0, count: x.count)
        var i = 0
        let sizes = [1, 7, 300, 1000, 513, 2048]
        var k2 = 0
        while i < x.count {
            let n = min(sizes[k2 % sizes.count], x.count - i); k2 += 1
            x.withUnsafeBufferPointer { xp in got.withUnsafeMutableBufferPointer { gp in f.run(xp.baseAddress! + i, gp.baseAddress! + i, n) } }
            i += n
        }
        let err = zip(want, got).map { abs($0 - $1) }.max() ?? 1
        expect(err < 1e-9, "vDSP biquad agrees with the scalar one across odd block sizes: \(err)")
    }

    func integratedLoudnessFollowsTheStandard() {
        // EBU Tech 3341, case 1: a 1 kHz stereo sine at −23 dBFS reads −23.0 LUFS
        let a = R128.analyze(samples: sine(30, freq: 1000, dB: -23), sampleRate: 48_000, channels: 2)
        expect(abs((a.integratedLUFS ?? 0) + 23) < 0.1, "−23 dBFS sine: \(String(describing: a.integratedLUFS))")
        expect(abs((a.momentaryMaxLUFS ?? 0) + 23) < 0.15 && abs((a.shortTermMaxLUFS ?? 0) + 23) < 0.15, "momentary and short-term agree on a steady tone")
        // other rates and levels
        for (fs, dB) in [(44_100.0, -20.0), (96_000, -30), (192_000, -14.5)] {
            let r = R128.analyze(samples: sine(20, freq: 997, dB: dB, fs: fs), sampleRate: fs, channels: 2)
            expect(abs((r.integratedLUFS ?? 0) - dB) < 0.15, "\(fs) Hz at \(dB): \(String(describing: r.integratedLUFS))")
        }
        // one channel only is 3 dB quieter than both
        var mono = sine(20, freq: 1000, dB: -23)
        for i in stride(from: 1, to: mono.count, by: 2) { mono[i] = 0 }
        let m = R128.analyze(samples: mono, sampleRate: 48_000, channels: 2)
        expect(abs((m.integratedLUFS ?? 0) + 26.01) < 0.12, "one of two channels silent: \(String(describing: m.integratedLUFS))")
        // silence and very short files
        let silent = R128.analyze(samples: [Float](repeating: 0, count: 48_000 * 4), sampleRate: 48_000, channels: 2)
        expect(silent.integratedLUFS == nil && silent.truePeakDB < -150, "silence has no loudness")
        expect(R128.analyze(samples: sine(0.3, freq: 1000, dB: -20), sampleRate: 48_000, channels: 2).integratedLUFS == nil, "shorter than one gating block")
    }

    func gatingIgnoresQuietPassages() {
        // 20 s of −40 then 20 s of −23: the quiet part is below the relative gate (EBU Tech 3341 case 3 in spirit)
        let x = sine(20, freq: 1000, dB: -40) + sine(20, freq: 1000, dB: -23)
        let r = R128.analyze(samples: x, sampleRate: 48_000, channels: 2)
        expect(abs((r.integratedLUFS ?? 0) + 23) < 0.15, "only the loud part counts: \(String(describing: r.integratedLUFS))")
        // below the absolute gate nothing counts at all
        let q = R128.analyze(samples: sine(20, freq: 1000, dB: -75), sampleRate: 48_000, channels: 2)
        expect(q.integratedLUFS == nil, "−75 dB is below −70 LUFS")
    }

    func loudnessRange() {
        // Tech 3342, case 1: 20 s at −20 LUFS followed by 20 s at −30 LUFS is 10 LU
        let r = R128.analyze(samples: sine(20, freq: 1000, dB: -20) + sine(20, freq: 1000, dB: -30), sampleRate: 48_000, channels: 2)
        expect(abs(r.loudnessRange - 10) < 1.0, "LRA \(r.loudnessRange)")
        expect(R128.analyze(samples: sine(30, freq: 1000, dB: -20), sampleRate: 48_000, channels: 2).loudnessRange < 0.3, "a steady tone has no range")
        let wide = R128.analyze(samples: sine(15, freq: 1000, dB: -15) + sine(15, freq: 1000, dB: -35) + sine(15, freq: 1000, dB: -22), sampleRate: 48_000, channels: 2)
        expect(wide.loudnessRange > 15 && wide.loudnessRange < 21, "a wide programme: \(wide.loudnessRange)")
    }

    func truePeakSeesBetweenTheSamples() {
        // a sine at a quarter of the sample rate with a 45° phase has samples of ±0.707 but peaks at 1.0 in between
        let x = sine(2, freq: 12_000, dB: 0, phase: .pi / 4)
        let r = R128.analyze(samples: x, sampleRate: 48_000, channels: 2)
        expect(abs(r.samplePeakDB + 3.01) < 0.05, "the samples peak at −3 dBFS: \(r.samplePeakDB)")
        expect(r.truePeakDB > -0.35 && r.truePeakDB < 0.25, "the true peak is 0 dBTP: \(r.truePeakDB)")
        let y = R128.analyze(samples: sine(2, freq: 11_025, dB: -6, fs: 44_100, phase: .pi / 4), sampleRate: 44_100, channels: 2)
        expect(abs(y.truePeakDB + 6) < 0.3, "at 44.1 kHz: \(y.truePeakDB)")
        // an ordinary low tone is the same by either measure
        let low = R128.analyze(samples: sine(2, freq: 440, dB: -10), sampleRate: 48_000, channels: 2)
        expect(abs(low.truePeakDB - low.samplePeakDB) < 0.1 && abs(low.truePeakDB + 10) < 0.1, "\(low.truePeakDB) vs \(low.samplePeakDB)")
        // high rates need no oversampling
        expect(TruePeakDetector.oversampling(for: 44_100) == 4 && TruePeakDetector.oversampling(for: 96_000) == 2 && TruePeakDetector.oversampling(for: 192_000) == 1)
    }

    func dynamicRangeScore() {
        // an impulse train: peak 1.0, TT-scaled RMS √(2/100) → DR 17
        var x = [Float](repeating: 0, count: 48_000 * 30 * 2)
        for i in stride(from: 0, to: 48_000 * 30, by: 100) { x[i * 2] = 1; x[i * 2 + 1] = 1 }
        let r = R128.analyze(samples: x, sampleRate: 48_000, channels: 2)
        expect(r.dynamicRange == 17, "impulse train DR \(r.dynamicRange)")
        // a steady sine has no dynamic range at all
        expect(R128.analyze(samples: sine(30, freq: 1000, dB: -12), sampleRate: 48_000, channels: 2).dynamicRange == 0, "a sine is DR0")
        // quiet passages do not count: the loudest fifth of the blocks decides
        let mixed = sine(6, freq: 1000, dB: -6) + sine(24, freq: 1000, dB: -40)
        expect(R128.analyze(samples: mixed, sampleRate: 48_000, channels: 2).dynamicRange == 0, "the loud blocks are all sine, peak against rms is 0 dB")
    }

    func surroundChannelsAreWeighted() {
        // 5.1: a tone only in the LFE is ignored; the same tone in the front left counts
        func six(_ ch: Int, _ dB: Double) -> [Float] {
            let m = sine(10, freq: 1000, dB: dB, channels: 1)
            var out = [Float](repeating: 0, count: m.count * 6)
            for i in 0..<m.count { out[i * 6 + ch] = m[i] }
            return out
        }
        expect(R128.analyze(samples: six(3, -10), sampleRate: 48_000, channels: 6).integratedLUFS == nil, "the LFE is left out of the measurement")
        let front = R128.analyze(samples: six(0, -20), sampleRate: 48_000, channels: 6).integratedLUFS ?? 0, surround = R128.analyze(samples: six(4, -20), sampleRate: 48_000, channels: 6).integratedLUFS ?? 0
        expect(abs((surround - front) - 1.5) < 0.05, "surrounds count +1.5 dB: \(surround - front)")
        expect(R128Weights.forChannels(2) == [1, 1] && R128Weights.forChannels(1) == [1] && R128Weights.forChannels(8).count == 8)
    }

    func analysesFilesAndStaysFast() {
        let f = sineWAV(dir.appendingPathComponent("l.wav"), rate: 96_000, bits: 24, freq: 1000, amp: pow(10, -23.0 / 20), seconds: 60)
        let t = Date()
        guard let r = R128.analyze(path: f.path) else { expect(false, "analysis failed"); return }
        let took = Date().timeIntervalSince(t)
        expect(abs((r.integratedLUFS ?? 0) + 23) < 0.15 && r.sampleRate == 96_000 && r.channels == 2 && abs(r.duration - 60) < 0.01, "\(r)")
        expect(took < 4, "a minute of 96 kHz / 24-bit stereo analysed in \(took) s (\(60 / max(took, 1e-6))× real time)")
        expect(R128.analyze(path: "/nonexistent.flac") == nil)
        var polls = 0
        expect(R128.analyze(path: f.path, cancelled: { polls += 1; return polls > 3 }) == nil, "cancelling stops it")
    }
}

extension LoudnessTests {
    func theCacheKeepsAndForgets() {
        let c = LoudnessCache(directory: dir.appendingPathComponent("cache"))
        let f = sineWAV(dir.appendingPathComponent("c.wav"), rate: 44_100, bits: 16, freq: 1000, amp: pow(10, -20.0 / 20), seconds: 6)
        expect(c.cached(path: f.path) == nil)
        let r = c.analysis(path: f.path)
        expect(r != nil && abs((r!.integratedLUFS ?? 0) + 20) < 0.2 && c.cached(path: f.path) == r, "stored after the first analysis")
        expect(LoudnessCache(directory: dir.appendingPathComponent("cache")).cached(path: f.path) == r, "and survives a restart")
        Thread.sleep(forTimeInterval: 1.1)
        _ = sineWAV(dir.appendingPathComponent("c.wav"), rate: 44_100, bits: 16, freq: 1000, amp: pow(10, -10.0 / 20), seconds: 6)
        expect(c.cached(path: f.path) == nil, "a changed file is measured again")
        expect(abs((c.analysis(path: f.path)?.integratedLUFS ?? 0) + 10) < 0.2, "…and gets its new figure")
    }

    func theLibraryRemembersTheFigures() {
        let lib = try! LibraryStore()
        func item(_ n: Int) -> (facts: FileFacts, tags: TrackMetadata) {
            var m = TrackMetadata(); m.title = "T\(n)"; m.credits = [Credit(role: .artist, name: "A")]
            return (FileFacts(path: "/l/\(n).flac", duration: 100, sampleRate: 44_100, bitDepth: 16, channels: 2, codec: "FLAC", mtime: 1, size: 1), m)
        }
        lib.upsert([item(1), item(2), item(3)])
        expect(lib.pathsNeedingLoudness().count == 3 && lib.loudnessProgress() == (0, 3))
        let r = R128Result(integratedLUFS: -9.5, loudnessRange: 6.2, truePeakDB: 0.4, samplePeakDB: -0.1, momentaryMaxLUFS: -6, shortTermMaxLUFS: -8, dynamicRange: 7, duration: 100, sampleRate: 44_100, channels: 2)
        lib.setLoudness(path: "/l/2.flac", r)
        let t = lib.track(path: "/l/2.flac")!
        expect(t.lufs == -9.5 && t.truePeakDB == 0.4 && t.lra == 6.2 && t.dr == 7, "\(t)")
        expect(lib.pathsNeedingLoudness() == ["/l/1.flac", "/l/3.flac"] && lib.loudnessProgress() == (1, 3))
        var silent = r; silent.integratedLUFS = nil
        lib.setLoudness(path: "/l/3.flac", silent)
        expect(lib.track(path: "/l/3.flac")!.lufs == nil && lib.pathsNeedingLoudness() == ["/l/1.flac"], "a silent file counts as measured")
        lib.clearLoudness()
        expect(lib.pathsNeedingLoudness().count == 3 && lib.track(path: "/l/2.flac")!.lufs == nil)
    }

    func levelingEquallyLoudensDifferentMasters() {
        // a quiet and a loud master, 6 s each; with the target at −18 LUFS both must come out at −18 LUFS
        func play(_ dB: Double, name: String, mode: ReplayGainMode) -> [Int32] {
            let f = sineWAV(dir.appendingPathComponent(name), rate: 44_100, bits: 24, freq: 997, amp: pow(10, dB / 20), seconds: 6)
            let sink = RecordingSink(speed: 0)
            var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.5; o.rateSwitch = false
            let p = Player()
            var s = PlaybackSettings(); s.replayGain.mode = mode; s.replayGain.referenceLUFS = -18
            p.settings = s
            p.setQueue([f.path]); p.start(options: o)
            _ = p.waitUntilFinished(timeout: 20)
            return sink.samples
        }
        func lufs(_ x: [Int32]) -> Double { R128.analyze(samples: x.map { Float($0) / 2_147_483_648 }, sampleRate: 44_100, channels: 2).integratedLUFS ?? -99 }
        for dB in [-32.0, -23, -12] {
            let out = play(dB, name: "lv\(Int(-dB)).wav", mode: .loudness)
            expect(abs(lufs(out) + 18) < 0.25, "a \(dB) dBFS master plays at \(lufs(out)) LUFS")
        }
        let off = play(-32, name: "off.wav", mode: .off)
        expect(abs(lufs(off) + 32) < 0.25, "with leveling off the file is untouched: \(lufs(off)) LUFS")
        // the true-peak limit: a loud, peaky file is not boosted beyond full scale
        var peaky = [Float](repeating: 0, count: 44_100 * 8 * 2)
        for i in 0..<(44_100 * 8) { let v = Float(0.02 * sin(2 * .pi * 300 * Double(i) / 44_100)); peaky[i * 2] = v; peaky[i * 2 + 1] = v }
        for k in stride(from: 4_410, to: 44_100 * 8, by: 22_050) { peaky[k * 2] = 0.95; peaky[k * 2 + 1] = 0.95 }
        let pf = writeWAV(dir.appendingPathComponent("peaky.wav"), rate: 44_100, bits: 24, frames: 44_100 * 8) { f, c in Int(Double(peaky[f * 2 + c]) * 8_388_607) }
        let rg = ReplayGainStore().resolve(path: pf.path, settings: { var s = ReplayGainSettings(); s.mode = .loudness; s.referenceLUFS = -10; return s }(), allowMeasuring: true)
        expect(rg.limitedByPeak && rg.linear < 1.2 && rg.origin == "measured", "gain is held back by the peak: \(rg)")
    }
}

import Foundation

/// Float32 (or int) WAV writer for impulse-response files, as Room EQ Wizard exports them.
func writeFloatWAV(_ url: URL, rate: Int, channels: [[Float]], format: String = "float32") {
    let ch = channels.count, frames = channels[0].count
    var data = Data()
    for f in 0..<frames { for c in 0..<ch {
        switch format {
        case "float32": var v = channels[c][f].bitPattern.littleEndian; data.append(Data(bytes: &v, count: 4))
        case "int24":
            let x = Int32(max(-1, min(0.9999999, channels[c][f])) * 8_388_607)
            data.append(contentsOf: [UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x >> 16)])
        default: var v = Int16(max(-1, min(0.9999, channels[c][f])) * 32_767).littleEndian; data.append(Data(bytes: &v, count: 2))
        }
    } }
    let bits = format == "float32" ? 32 : (format == "int24" ? 24 : 16), tag = format == "float32" ? 3 : 1
    func le32(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
    func le16(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255)]) }
    var h = Data("RIFF".utf8); h += le32(36 + data.count); h += Data("WAVEfmt ".utf8); h += le32(16)
    h += le16(tag) + le16(ch) + le32(rate) + le32(rate * ch * bits / 8) + le16(ch * bits / 8) + le16(bits)
    h += Data("data".utf8) + le32(data.count)
    try! (h + data).write(to: url)
}

struct ConvolutionTests {
    let dir = tempDir("conv")

    func random(_ n: Int, seed: UInt64) -> [Float] {
        var s = seed; return (0..<n).map { _ in s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Float(Double(s % 2_000_001) / 1_000_000 - 1) }
    }

    func run(_ ir: ImpulseResponse, _ input: [Float], channels: Int = 1, block: Int = 512, chunk: Int = 4096, normalize: Bool = false, gainDB: Double = 0) -> (out: [Float], proc: ConvolutionProcessor) {
        let prepared = PreparedIR(ir, block: block, gainDB: gainDB, normalize: normalize)
        let p = ConvolutionProcessor(ir: prepared, channels: channels)
        var buf = input
        let frames = input.count / channels
        var i = 0
        while i < frames { let m = min(chunk, frames - i); buf.withUnsafeMutableBufferPointer { p.process($0.baseAddress! + i * channels, frames: m) }; i += m }
        return (buf, p)
    }

    func direct(_ h: [Float], _ x: [Float]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        for n in 0..<x.count { var s = 0.0; for k in 0..<min(h.count, n + 1) { s += Double(h[k]) * Double(x[n - k]) }; y[n] = s }
        return y
    }

    func deltaIsIdentityDelayedByOneBlock() {
        for B in [256, 512] {
            let x = random(20_000, seed: 7)
            let (y, p) = run(ImpulseResponse(channels: [[1]], sampleRate: 48_000), x, block: B)
            var worst: Float = 0
            for n in 0..<(x.count - B) { worst = max(worst, abs(y[n + B] - x[n])) }
            expect(worst < 1e-6, "B=\(B): delta IR off by \(worst)")
            expect(p.latencyFrames == B)
            expect(y[0..<B].allSatisfy { $0 == 0 }, "the first block is the latency")
        }
    }

    func matchesDirectConvolution() {
        for (len, B) in [(3000, 512), (3000, 256), (777, 512), (4096, 512), (1, 512)] {
            let h = random(len, seed: UInt64(len)).map { $0 * 0.1 }
            let x = random(15_000, seed: 99)
            let ref = direct(h, x)
            let (y, _) = run(ImpulseResponse(channels: [h], sampleRate: 48_000), x, block: B)
            var worst = 0.0
            for n in 0..<(x.count - B) { worst = max(worst, abs(Double(y[n + B]) - ref[n])) }
            expect(worst < 2e-5, "IR \(len) taps, B=\(B): max error \(worst)")
        }
    }

    func callbackSizeDoesNotMatter() {
        let h = random(2500, seed: 5).map { $0 * 0.05 }, x = random(30_000, seed: 11)
        let ir = ImpulseResponse(channels: [h], sampleRate: 44_100)
        let base = run(ir, x, chunk: 4096).out
        for chunk in [1, 37, 512, 1000, 777] {
            expect(run(ir, x, chunk: chunk).out == base, "chunk \(chunk) must give bit-identical output")
        }
    }

    func stereoUsesOneIrPerChannel() {
        var l = [Float](repeating: 0, count: 600), r = l
        l[0] = 0.5; r[100] = 0.8
        let n = 8000
        var x = [Float](repeating: 0, count: n * 2)
        let src = random(n, seed: 3)
        for i in 0..<n { x[i * 2] = src[i]; x[i * 2 + 1] = src[i] }
        let (y, _) = run(ImpulseResponse(channels: [l, r], sampleRate: 48_000), x, channels: 2)
        var eL: Float = 0, eR: Float = 0
        for i in 0..<(n - 1000) {
            eL = max(eL, abs(y[(i + 512) * 2] - 0.5 * src[i]))
            eR = max(eR, abs(y[(i + 512 + 100) * 2 + 1] - 0.8 * src[i]))
        }
        expect(eL < 1e-5 && eR < 1e-5, "left \(eL), right \(eR)")
        // a mono IR is shared by both channels
        let mono = run(ImpulseResponse(channels: [l], sampleRate: 48_000), x, channels: 2).out
        var worst: Float = 0
        for i in 0..<(n - 600) { worst = max(worst, abs(mono[(i + 512) * 2] - mono[(i + 512) * 2 + 1])) }
        expect(worst < 1e-6, "mono IR on a stereo stream must treat both channels alike")
    }

    func frequencyResponseOfASimpleFilter() {
        // y[n] = 0.5 x[n] + 0.5 x[n-1] : unity at DC, null at Nyquist
        let ir = ImpulseResponse(channels: [[0.5, 0.5]], sampleRate: 48_000)
        for (f, want) in [(100.0, 1.0), (12_000, cos(.pi * 12_000 / 48_000)), (20_000, cos(.pi * 20_000 / 48_000))] {
            let n = 30_000
            var x = (0..<n).map { Float(0.5 * sin(2 * .pi * f * Double($0) / 48_000)) }
            let p = ConvolutionProcessor(ir: PreparedIR(ir, gainDB: 0, normalize: false), channels: 1)
            x.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, frames: n) }
            var re = 0.0, im = 0.0
            for k in 5000..<n { let ph = 2 * .pi * f * Double(k - 512) / 48_000; re += Double(x[k]) * cos(ph); im += Double(x[k]) * sin(ph) }
            let amp = 2 * (re * re + im * im).squareRoot() / Double(n - 5000)
            expect(abs(amp / 0.5 - want) < 0.002, "\(Int(f)) Hz: \(amp / 0.5), expected \(want)")
        }
    }

    func wavReaderHandlesRewStyleFiles() {
        let h: [Float] = [0.0, 0.25, -0.5, 1.5, 0.125]                  // note: 1.5 — float WAVs may exceed full scale
        let f = dir.appendingPathComponent("rew.wav")
        writeFloatWAV(f, rate: 48_000, channels: [h, h.map { -$0 }])
        let ir = try! IRLoader.readWAV(path: f.path)
        expect(ir.sampleRate == 48_000 && ir.channels.count == 2 && ir.channels[0] == h && ir.channels[1] == h.map { -$0 }, "float32 stereo: \(ir.channels)")
        writeFloatWAV(f, rate: 44_100, channels: [[0.5, -0.25, 0.125]], format: "int24")
        let i24 = try! IRLoader.readWAV(path: f.path)
        expect(i24.channels[0].enumerated().allSatisfy { abs($1 - [0.5, -0.25, 0.125][$0]) < 1e-5 })
        writeFloatWAV(f, rate: 44_100, channels: [[0.5, -0.25]], format: "int16")
        expect(abs(try! IRLoader.readWAV(path: f.path).channels[0][1] - -0.25) < 1e-3)
        expect((try? IRLoader.readWAV(path: dir.appendingPathComponent("nope.wav").path)) == nil)
        try! Data("not a wav at all, just some text padding padding padding padding".utf8).write(to: f)
        expect((try? IRLoader.readWAV(path: f.path)) == nil)
    }

    func trimmingAndResamplingKeepTiming() {
        var h = [Float](repeating: 0, count: 30_000)
        h[480] = 0.8; h[900] = -0.3; h[1000] = 1e-7
        let ir = ImpulseResponse(channels: [h], sampleRate: 48_000)
        let t = IRLoader.trimmed(ir)
        expect(t.length == 901, "tail below −100 dB is trimmed, got \(t.length)")
        let r = IRLoader.resampled(t, to: 44_100)!
        let peak = r.channels[0].enumerated().max { abs($0.element) < abs($1.element) }!
        expect(abs(peak.offset - 441) <= 1 && peak.element > 0.74 && peak.element < 0.82, "main arrival at \(peak.offset) (want 441), level \(peak.element)")
        let second = r.channels[0].enumerated().filter { $0.offset > 600 }.min { $0.element < $1.element }!
        expect(abs(second.offset - 827) <= 1 && second.element < -0.26 && second.element > -0.32, "second arrival at \(second.offset) (want 827), level \(second.element)")
        // the filter's gain (sum of taps) must survive a change of sample rate in either direction
        let smooth = ImpulseResponse(channels: [(0..<2400).map { Float(0.01 * exp(-Double($0) / 100) * (1 + 0.5 * cos(Double($0) / 7))) }], sampleRate: 48_000)
        let want = smooth.channels[0].reduce(0, +)
        for rate in [44_100.0, 96_000, 192_000, 32_000] {
            let got = IRLoader.resampled(smooth, to: rate)!.channels[0].reduce(0, +)
            expect(abs(got / want - 1) < 0.01, "DC gain after 48 → \(Int(rate)) kHz: \(got) vs \(want)")
        }
        // end to end: a tone through the original IR and through its resampled twin gets the same gain
        func toneGain(_ ir: ImpulseResponse, _ f: Double) -> Double {
            let n = 40_000
            var x = (0..<n).map { Float(0.3 * sin(2 * .pi * f * Double($0) / ir.sampleRate)) }
            let p = ConvolutionProcessor(ir: PreparedIR(ir, gainDB: 0, normalize: false), channels: 1)
            x.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, frames: n) }
            var re = 0.0, im = 0.0
            for k in 20_000..<n { let ph = 2 * .pi * f * Double(k - 512) / ir.sampleRate; re += Double(x[k]) * cos(ph); im += Double(x[k]) * sin(ph) }
            return 2 * (re * re + im * im).squareRoot() / 20_000 / 0.3
        }
        let g48 = toneGain(smooth, 200), g96 = toneGain(IRLoader.resampled(smooth, to: 96_000)!, 200)
        expect(abs(g96 / g48 - 1) < 0.02, "200 Hz gain \(g48) at 48 kHz vs \(g96) after resampling to 96 kHz")
        expect(IRLoader.resampled(ir, to: 48_000)?.length == ir.length)
    }

    func normalizationPreventsBoost() {
        // an IR that boosts: gain of 4 at DC
        let ir = ImpulseResponse(channels: [[2, 2]], sampleRate: 48_000)
        let loud = PreparedIR(ir, gainDB: 0, normalize: false), safe = PreparedIR(ir, gainDB: 0, normalize: true)
        expect(loud.appliedGainDB == 0, "no normalisation, no change")
        expect(abs(safe.appliedGainDB - -12.04) < 0.05, "applied \(safe.appliedGainDB) dB, expected −12.04")
        let (y, _) = run(ir, [Float](repeating: 0.1, count: 8000), normalize: true)
        expect(abs(y[4000] - 0.1) < 1e-4, "constant input stays at 0.1 after normalisation, got \(y[4000])")
        let g = PreparedIR(ImpulseResponse(channels: [[0.25, 0.25]], sampleRate: 48_000), gainDB: 6, normalize: true)
        expect(abs(g.appliedGainDB - 6) < 0.01, "a +6 dB trim on a quiet IR is kept")
    }

    /// 8 seconds of stereo IR (384 000 taps): must run far faster than real time.
    func longIRRunsMuchFasterThanRealTime() {
        let rate = 48_000.0
        let h = random(Int(rate * 8), seed: 1).enumerated().map { Float(exp(-Double($0.offset) / (rate * 1.5))) * $0.element * 0.05 }
        let prepared = PreparedIR(ImpulseResponse(channels: [h, h], sampleRate: rate), gainDB: 0, normalize: false)
        expect(prepared.partitions == 750, "partitions \(prepared.partitions)")
        let p = ConvolutionProcessor(ir: prepared, channels: 2)
        let noise = random(1024 * 2, seed: 2)
        var buf = noise
        let seconds = 10.0, blocks = Int(rate * seconds) / 1024
        let t0 = Date()
        for _ in 0..<blocks { buf = noise; buf.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, frames: 1024) } }
        let took = Date().timeIntervalSince(t0)
        expect(seconds / took > 8, "processed \(seconds) s of stereo audio in \(String(format: "%.2f", took)) s (\(String(format: "%.0f", seconds / took))× real time)")
        expect(buf.allSatisfy { $0.isFinite })
    }
}

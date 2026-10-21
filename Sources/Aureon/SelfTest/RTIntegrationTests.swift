import Foundation

/// The real-time processors inside a full Player → Renderer → sink run.
struct RTIntegrationTests {
    let dir = tempDir("rtint")

    func hardLeft(_ name: String, rate: Int, freq: Double, seconds: Double, amp: Double = 0.5) -> URL {
        let full = Double((1 << 23) - 1)
        return writeWAV(dir.appendingPathComponent(name), rate: rate, bits: 24, frames: Int(Double(rate) * seconds)) { f, c in
            c == 0 ? Int(amp * full * sin(2 * .pi * freq * Double(f) / Double(rate))) : 0
        }
    }

    func play(_ files: [URL], _ rt: RTSettings, speed: Double = 0) -> (Player, RecordingSink) {
        let sink = RecordingSink(speed: speed)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let p = Player()
        var s = PlaybackSettings(); s.rt = rt
        p.settings = s; p.setQueue(files.map(\.path)); p.start(options: o)
        return (p, sink)
    }

    func crossfeedThroughThePlayer() {
        let f = hardLeft("xf.wav", rate: 44_100, freq: 100, seconds: 3)
        var rt = RTSettings(); rt.crossfeed = CrossfeedSettings(enabled: true, cutoffHz: 700, feedDB: 4.5)
        let (p, sink) = play([f], rt)
        expect(p.waitUntilFinished(timeout: 20))
        let l = amplitude(sink.samples, channels: 2, channel: 0, rate: 44_100, freq: 100, skip: 60_000, count: 60_000)
        let r = amplitude(sink.samples, channels: 2, channel: 1, rate: 44_100, freq: 100, skip: 60_000, count: 60_000)
        expect(abs(db(l / r) - 4.5) < 0.2, "near/far ear differ by \(db(l / r)) dB, expected 4.5")
        expect(r > 0.05, "the far ear must receive signal")
        expect(!p.status.rtStages.isEmpty || p.status.finished)
        expect(sink.configured.first?.transparent == true, "the stream itself is still transparent; the chain is flagged separately")
    }

    func statusReportsTheChainAndBitPerfectFlag() {
        let f = hardLeft("st.wav", rate: 8_000, freq: 100, seconds: 6)
        var rt = RTSettings(); rt.crossfeed.enabled = true
        let (p, _) = play([f], rt, speed: 2)
        let end = Date().addingTimeInterval(5)
        while p.status.state != .playing && Date() < end { usleep(5_000) }
        usleep(200_000)
        let st = p.status
        expect(st.rtStages.contains { $0.hasPrefix("Crossfeed BS2B") }, "stages \(st.rtStages)")
        expect(!st.transparentStream && !st.bitPerfect, "audio altered by a processor must not be reported as bit-perfect")
        p.send(.stop); _ = p.waitUntilFinished(timeout: 5)

        let (q, _) = play([f], RTSettings(), speed: 2)
        let end2 = Date().addingTimeInterval(5)
        while q.status.state != .playing && Date() < end2 { usleep(5_000) }
        usleep(200_000)
        expect(q.status.rtStages.isEmpty && q.status.transparentStream, "no processors: the direct path stays transparent")
        q.send(.stop); _ = q.waitUntilFinished(timeout: 5)
    }

    func switchingOnAndOffMidPlaybackIsClean() {
        let f = hardLeft("live.wav", rate: 8_000, freq: 100, seconds: 12)
        let src = readAll(try! LosslessFile(path: f.path))
        let (p, sink) = play([f], RTSettings(), speed: 4)
        let wait = { (n: Int) in let end = Date().addingTimeInterval(8); while sink.frameCount < n && Date() < end { usleep(2_000) } }
        wait(6_000)
        var s = p.settings; s.rt.crossfeed.enabled = true; p.settings = s
        wait(40_000)
        let mid = sink.samples
        let l = amplitude(mid, channels: 2, channel: 0, rate: 8_000, freq: 100, skip: 30_000, count: 8_000)
        let r = amplitude(mid, channels: 2, channel: 1, rate: 8_000, freq: 100, skip: 30_000, count: 8_000)
        expect(r > 0.05 && abs(db(l / r) - 4.5) < 0.3, "crossfeed engaged live: ear difference \(db(l / r)) dB")
        s.rt.crossfeed.enabled = false; p.settings = s
        expect(p.waitUntilFinished(timeout: 30))
        let out = sink.samples
        expect(abs(out.count - src.count) < 2_000, "length \(out.count / 2) vs \(src.count / 2)")
        let n = 20_000 * 2
        expect(Array(out.suffix(n)) == Array(src.suffix(n)), "after switching off, the tail must be bit-exact again")
        expect(!p.status.errors.contains { $0.contains("crash") })
    }

    func headphoneEQThroughThePlayer() {
        let text = "Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1.0"
        let prof = AutoEQParser.parse(text, name: "test")!
        var rt = RTSettings(); rt.headphoneEQ = HeadphoneEQSettings(enabled: true, profile: prof)
        for (freq, want) in [(1000.0, 0.0), (100.0, -6.0)] {         // the safety pre-amp (−6 dB) offsets the +6 dB boost
            let f = sineWAV(dir.appendingPathComponent("hp\(Int(freq)).wav"), rate: 44_100, freq: freq, amp: 0.25, seconds: 2)
            let (p, sink) = play([f], rt)
            expect(p.waitUntilFinished(timeout: 20))
            let a = amplitude(sink.samples, channels: 2, rate: 44_100, freq: freq, skip: 20_000, count: 60_000)
            expect(abs(db(a / 0.25) - want) < 0.3, "\(Int(freq)) Hz: \(db(a / 0.25)) dB, expected \(want)")
        }
    }

    func convolutionThroughThePlayer() {
        let rate = 44_100
        var ir = [Float](repeating: 0, count: 600); ir[100] = 0.5
        let irURL = dir.appendingPathComponent("rew-ir.wav"); writeFloatWAV(irURL, rate: rate, channels: [ir])
        let noise = writeWAV(dir.appendingPathComponent("noise.wav"), rate: rate, bits: 24, frames: 30_000) { f, c in
            Int(Double(((f &* 2654435761 &+ c &* 40503) % 4_000_001)) - 2_000_000) }
        let src = readAll(try! LosslessFile(path: noise.path))
        var rt = RTSettings(); rt.convolution = ConvolutionSettings(enabled: true, irPath: irURL.path, gainDB: 0, normalize: false)
        let (p, sink) = play([noise], rt)
        expect(p.waitUntilFinished(timeout: 20))
        let y = sink.samples
        let lag = 512 + 100                                  // one block of latency + the IR's own delay
        var worst = 0.0
        for n in 0..<(src.count / 2 - lag - 600) {
            for c in 0..<2 { worst = max(worst, abs(Double(y[(n + lag) * 2 + c]) - 0.5 * Double(src[n * 2 + c])) / 2_147_483_648) }
        }
        expect(worst < 3e-7, "delayed 0.5× copy differs by \(worst)")
        expect(p.status.rtStages.contains { $0.hasPrefix("Room correction") } || p.status.finished)
    }

    func impulseResponseAtAnotherRateIsConverted() {
        var ir = [Float](repeating: 0, count: 1200); ir[480] = 1.0                       // 10 ms at 48 kHz
        let irURL = dir.appendingPathComponent("ir48.wav"); writeFloatWAV(irURL, rate: 48_000, channels: [ir])
        let f = writeWAV(dir.appendingPathComponent("pulse.wav"), rate: 44_100, bits: 24, frames: 20_000) { n, _ in n == 1000 ? 4_000_000 : 0 }
        var rt = RTSettings(); rt.convolution = ConvolutionSettings(enabled: true, irPath: irURL.path, gainDB: 0, normalize: false)
        let (p, sink) = play([f], rt)
        expect(p.waitUntilFinished(timeout: 20))
        let y = sink.samples
        let peak = (0..<(y.count / 2)).max { abs(y[$0 * 2]) < abs(y[$1 * 2]) }!
        expect(abs(peak - (1000 + 441 + 512)) <= 2, "pulse arrives at \(peak), expected ≈ \(1000 + 441 + 512)")
        expect(abs(Double(y[peak * 2]) / 2_147_483_648 / (4_000_000.0 / 8_388_608) - 1) < 0.08, "gain preserved across the rate change")
    }

    func filtersAreRebuiltAtAFormatChange() {
        let a = hardLeft("ra.wav", rate: 44_100, freq: 100, seconds: 2), b = hardLeft("rb.wav", rate: 48_000, freq: 100, seconds: 2)
        var rt = RTSettings(); rt.crossfeed = CrossfeedSettings(enabled: true, cutoffHz: 700, feedDB: 6)
        let (p, sink) = play([a, b], rt)
        expect(p.waitUntilFinished(timeout: 30))
        expect(sink.configured.map(\.sampleRate) == [44_100, 48_000])
        let x = sink.samples
        let first = Array(x.prefix(88_200 * 2)), second = Array(x.suffix(96_000 * 2))
        for (seg, rate) in [(first, 44_100.0), (second, 48_000.0)] {
            let l = amplitude(seg, channels: 2, channel: 0, rate: rate, freq: 100, skip: 40_000, count: 40_000)
            let r = amplitude(seg, channels: 2, channel: 1, rate: rate, freq: 100, skip: 40_000, count: 40_000)
            expect(abs(db(l / r) - 6) < 0.3, "\(Int(rate)) Hz segment: \(db(l / r)) dB, expected 6")
        }
    }

    func unsupportedCombinationsAreReportedNotCrashed() {
        let f = hardLeft("m.wav", rate: 8_000, freq: 100, seconds: 1)
        var rt = RTSettings()
        rt.convolution = ConvolutionSettings(enabled: true, irPath: "/nonexistent/ir.wav")
        rt.headphoneEQ = HeadphoneEQSettings(enabled: true, profile: nil)
        let (p, sink) = play([f], rt)
        expect(p.waitUntilFinished(timeout: 10))
        expect(p.status.errors.contains { $0.contains("Room correction") }, "errors \(p.status.errors)")
        expect(sink.samples == readAll(try! LosslessFile(path: f.path)), "a failed processor must leave the audio untouched")
    }

    func oldSavedSettingsStillDecode() {
        let old = #"{"polarityInverted":true,"ram":{"enabled":true,"budgetMB":512}}"#
        let s = try? JSONDecoder().decode(PlaybackSettings.self, from: Data(old.utf8))
        expect(s?.polarityInverted == true && s?.ram.budgetMB == 512 && s?.rt == RTSettings(), "tolerant decoding failed: \(String(describing: s))")
        let round = try! JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(PlaybackSettings()))
        expect(round == PlaybackSettings())
    }
}

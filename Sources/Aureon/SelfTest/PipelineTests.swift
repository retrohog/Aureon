import Foundation

struct DSDTests {
    let dir = tempDir()
    let rate = 2_822_400

    /// Stereo DSD64 with an odd number of DoP frames (so marker parity continuity across tracks is observable).
    func channels(seconds: Double = 0.2, seed: Int = 0) -> [[UInt8]] {
        let a = dsdBytes(rate: Double(rate), freq: 1000, amp: 0.5, seconds: seconds, seed: seed)
        let b = dsdBytes(rate: Double(rate), freq: 2000, amp: 0.25, seconds: seconds, seed: seed)
        let n = (a.count / 4) * 4 - 2
        return [Array(a.prefix(n)), Array(b.prefix(n))]
    }

    func stampedDoP(_ c: DsdContainer, clock: DoPClock) -> [Int32] { readAll(DoPStampSource(DoPSource(c, codec: "DSD64"), clock: clock)) }

    func dsfParsesAndDoPPacksExactly() {
        let ch = channels()
        let url = dir.appendingPathComponent("a.dsf"); writeDSF(url, rate: rate, channelBytes: ch)
        let c = try! DsdContainer(path: url.path)
        expect(c.channels == 2 && Int(c.dsdRate) == rate && c.bytesPerChannel == ch[0].count, "header: \(c.channels) ch, \(c.dsdRate), \(c.bytesPerChannel)")
        let src = DoPSource(c, codec: "DSD64")
        expect(Int(src.info.sampleRate) == 176_400 && src.info.isDoP)
        let out = stampedDoP(c, clock: DoPClock())
        let frames = out.count / 2
        expect(frames == ch[0].count / 2, "frames \(frames)")
        var bad = 0
        for f in 0..<frames {
            for k in 0..<2 {
                let w = UInt32(bitPattern: out[f * 2 + k])
                let marker = UInt8(w >> 24), b1 = UInt8((w >> 16) & 255), b2 = UInt8((w >> 8) & 255), low = UInt8(w & 255)
                if marker != (f % 2 == 0 ? 0x05 : 0xFA) || b1 != ch[k][2 * f] || b2 != ch[k][2 * f + 1] || low != 0 { bad += 1 }
            }
        }
        expect(bad == 0, "\(bad) DoP words differ from the DSD bit stream")
    }

    func dffAndDsfGiveIdenticalBits() {
        let ch = channels(seed: 3)
        let f1 = dir.appendingPathComponent("b.dsf"), f2 = dir.appendingPathComponent("b.dff")
        writeDSF(f1, rate: rate, channelBytes: ch); writeDFF(f2, rate: rate, channelBytes: ch)
        let a = stampedDoP(try! DsdContainer(path: f1.path), clock: DoPClock())
        let b = stampedDoP(try! DsdContainer(path: f2.path), clock: DoPClock())
        expect(a.count > 0 && a == b, "DFF (MSB-first) and DSF (LSB-first) must normalise to the same stream")
    }

    func dopMarkerContinuesAcrossTracks() {
        let t1 = dir.appendingPathComponent("c1.dsf"), t2 = dir.appendingPathComponent("c2.dsf")
        writeDSF(t1, rate: rate, channelBytes: channels(seed: 1)); writeDSF(t2, rate: rate, channelBytes: channels(seed: 2))
        let clock = DoPClock()
        let a = stampedDoP(try! DsdContainer(path: t1.path), clock: clock)
        let b = stampedDoP(try! DsdContainer(path: t2.path), clock: clock)
        let all = a + b
        let n = all.count / 2
        expect((a.count / 2) % 2 == 1, "test needs an odd frame count to expose parity breaks")
        var breaks = 0
        for f in 1..<n where (all[f * 2] >> 24) & 0xFF == (all[(f - 1) * 2] >> 24) & 0xFF { breaks += 1 }
        expect(breaks == 0, "\(breaks) places where the 0x05/0xFA marker did not alternate")
    }

    func dsdToPcmRecoversTheSignal() {
        let ch = channels(seconds: 0.3)
        let url = dir.appendingPathComponent("d.dsf"); writeDSF(url, rate: rate, channelBytes: ch)
        let c = try! DsdContainer(path: url.path)
        let s = DsdToPcmSource(c, codec: "DSD64", pcmRate: 176_400, gainDB: 0)!
        let y = readAll(s)
        expect(y.count / 2 == ch[0].count * 8 / 16, "frame count \(y.count / 2)")
        let a1 = amplitude(y, channels: 2, channel: 0, rate: 176_400, freq: 1000, skip: 3000, count: 40_000)
        let a2 = amplitude(y, channels: 2, channel: 1, rate: 176_400, freq: 2000, skip: 3000, count: 40_000)
        expect(abs(db(a1 / 0.5)) < 0.3, "1 kHz level \(db(a1 / 0.5)) dB off")
        expect(abs(db(a2 / 0.25)) < 0.3, "2 kHz level \(db(a2 / 0.25)) dB off")
        let stray = amplitude(y, channels: 2, channel: 0, rate: 176_400, freq: 3000, skip: 3000, count: 40_000)
        expect(db(stray / 0.5) < -60, "unrelated 3 kHz content only \(db(stray / 0.5)) dB down")
        // gain option
        let g = DsdToPcmSource(try! DsdContainer(path: url.path), codec: "DSD64", pcmRate: 176_400, gainDB: -6.0206)!
        let ya = amplitude(readAll(g), channels: 2, rate: 176_400, freq: 1000, skip: 3000, count: 40_000)
        expect(abs(db(ya / 0.25)) < 0.3, "−6 dB gain gave \(db(ya / 0.25)) dB error")
    }

    func dsdToPcmSeekIsDeterministic() {
        let url = dir.appendingPathComponent("e.dsf"); writeDSF(url, rate: rate, channelBytes: channels(seconds: 0.2))
        for target in [176_400.0, 88_200] {
            let a = readAll(DsdToPcmSource(try! DsdContainer(path: url.path), codec: "DSD64", pcmRate: target, gainDB: 0)!)
            let b = DsdToPcmSource(try! DsdContainer(path: url.path), codec: "DSD64", pcmRate: target, gainDB: 0)!
            b.seek(to: 5_000)
            expect(readAll(b) == Array(a[(5_000 * 2)...]), "seek mismatch at \(Int(target)) Hz")
        }
    }

    func rejectsBadRatios() {
        let url = dir.appendingPathComponent("f.dsf"); writeDSF(url, rate: rate, channelBytes: channels())
        let c = try! DsdContainer(path: url.path)
        expect(DsdToPcmSource(c, codec: "x", pcmRate: 192_000, gainDB: 0) == nil)
        expect(DsdToPcmSource(c, codec: "x", pcmRate: 1_411_200, gainDB: 0) == nil, "decimation by 2 is below the supported minimum of 8")
    }
}

struct ReplayGainTests {
    let dir = tempDir()

    /// A FLAC container with only a STREAMINFO placeholder and a Vorbis comment block: enough for the tag parser.
    func taggedFLAC(_ name: String, _ comments: [String]) -> String {
        var d = Data("fLaC".utf8)
        d += Data([0x00, 0, 0, 34]) + Data(count: 34)
        var body = Data()
        func le32(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
        body += le32(4) + Data("test".utf8) + le32(comments.count)
        for c in comments { body += le32(c.utf8.count) + Data(c.utf8) }
        d += Data([0x84, UInt8((body.count >> 16) & 255), UInt8((body.count >> 8) & 255), UInt8(body.count & 255)]) + body
        let url = dir.appendingPathComponent(name); try! d.write(to: url)
        return url.path
    }

    func parsesVorbisReplayGain() {
        let p = taggedFLAC("rg.flac", ["TITLE=x", "REPLAYGAIN_TRACK_GAIN=-7.25 dB", "replaygain_track_peak=0.987654", "REPLAYGAIN_ALBUM_GAIN=+2.50 dB", "REPLAYGAIN_ALBUM_PEAK=1.000000"])
        let t = ReplayGainReader.read(path: p)
        expect(t.trackGain == -7.25 && t.trackPeak == 0.987654 && t.albumGain == 2.5 && t.albumPeak == 1.0, "\(t)")
        expect(ReplayGainReader.read(path: taggedFLAC("none.flac", ["TITLE=x"])).isEmpty)
    }

    func resolutionRules() {
        let store = ReplayGainStore()
        let p = taggedFLAC("r2.flac", ["REPLAYGAIN_TRACK_GAIN=-6.5 dB", "REPLAYGAIN_TRACK_PEAK=0.99", "REPLAYGAIN_ALBUM_GAIN=-3.0 dB", "REPLAYGAIN_ALBUM_PEAK=0.99"])
        var s = ReplayGainSettings(); s.mode = .off
        expect(store.resolve(path: p, settings: s, allowMeasuring: false).linear == 1)
        s.mode = .track
        var r = store.resolve(path: p, settings: s, allowMeasuring: false)
        expect(abs(r.appliedDB - -6.5) < 1e-9 && r.origin == "tag" && !r.limitedByPeak)
        s.mode = .album
        expect(abs(store.resolve(path: p, settings: s, allowMeasuring: false).appliedDB - -3.0) < 1e-9)
        s.mode = .track; s.preampDB = 2
        expect(abs(store.resolve(path: p, settings: s, allowMeasuring: false).appliedDB - -4.5) < 1e-9, "preamp adds")
        // positive gain that would clip is limited by the peak tag
        let loud = taggedFLAC("r3.flac", ["REPLAYGAIN_TRACK_GAIN=+6.0 dB", "REPLAYGAIN_TRACK_PEAK=0.90"])
        s.preampDB = 0
        r = store.resolve(path: loud, settings: s, allowMeasuring: false)
        expect(r.limitedByPeak && abs(r.linear - 1 / 0.9) < 1e-9, "limited to \(r.linear)")
        s.preventClipping = false
        r = store.resolve(path: loud, settings: s, allowMeasuring: false)
        expect(!r.limitedByPeak && abs(r.appliedDB - 6) < 1e-9)
        // no tag, no analysis → untouched
        s.analyzeUntagged = false
        expect(store.resolve(path: taggedFLAC("r4.flac", []), settings: s, allowMeasuring: true).linear == 1)
    }

    /// EBU test signal: a 997 Hz sine in both channels at −20 dBFS reads −20.0 LUFS (±0.1) at any sample rate.
    func loudnessMatchesEBUReference() {
        for rate in [44_100, 48_000, 96_000] {
            let url = sineWAV(dir.appendingPathComponent("l\(rate).wav"), rate: rate, freq: 997, amp: 0.1, seconds: 6)
            let r = Loudness.analyze(path: url.path)
            expect(r != nil && abs(r!.lufs - -20.0) < 0.1, "\(rate) Hz: \(String(describing: r?.lufs)) LUFS")
            expect(r != nil && abs(r!.peak - 0.1) < 1e-4)
        }
        // −10 dB louder reads −10 LUFS; one channel only is 3 dB quieter
        let loud = sineWAV(dir.appendingPathComponent("l2.wav"), rate: 48_000, freq: 997, amp: 0.316227766, seconds: 6)
        expect(abs(Loudness.analyze(path: loud.path)!.lufs - -10.0) < 0.1)
        let mono = writeWAV(dir.appendingPathComponent("l3.wav"), rate: 48_000, bits: 24, frames: 48_000 * 6) { f, c in
            c == 0 ? Int(0.1 * 8_388_607 * sin(2 * Double.pi * 997 * Double(f) / 48_000)) : 0 }
        expect(abs(Loudness.analyze(path: mono.path)!.lufs - -23.01) < 0.1, "single channel \(Loudness.analyze(path: mono.path)!.lufs)")
        // digital silence has no loudness
        let silence = writeWAV(dir.appendingPathComponent("l4.wav"), rate: 44_100, bits: 16, frames: 44_100 * 3) { _, _ in 0 }
        expect(Loudness.analyze(path: silence.path) == nil)
    }

    func measuredGainTargetsMinus18() {
        let url = sineWAV(dir.appendingPathComponent("m.wav"), rate: 44_100, freq: 997, amp: 0.1, seconds: 6)
        var s = ReplayGainSettings(); s.mode = .track
        let r = ReplayGainStore().resolve(path: url.path, settings: s, allowMeasuring: true)
        expect(r.origin == "measured" && abs(r.appliedDB - 2.0) < 0.1, "gain \(r.appliedDB) dB, origin \(r.origin)")
    }
}

struct StageTests {
    let dir = tempDir()

    func gainStage() {
        let url = writeWAV(dir.appendingPathComponent("g.wav"), rate: 44_100, bits: 24, frames: 5000) { f, c in (f * 997 + c * 31) % 4_000_000 - 2_000_000 }
        let plain = readAll(try! LosslessFile(path: url.path))
        let unity = GainSource(try! LosslessFile(path: url.path), gain: 1)
        expect(unity.info.transparent && readAll(unity) == plain, "unity gain must be byte-exact and stay transparent")
        let half = GainSource(try! LosslessFile(path: url.path), gain: 0.5)
        expect(!half.info.transparent)
        let h = readAll(half)
        expect(zip(h, plain).allSatisfy { abs(Int64($0) - Int64($1) / 2) <= 1 })
        let clip = readAll(GainSource(try! LosslessFile(path: url.path), gain: 1000))
        expect(clip.contains(.max) && clip.contains(.min), "clips instead of wrapping")
        let inv = readAll(InvertSource(try! LosslessFile(path: url.path)))
        expect(zip(inv, plain).allSatisfy { $0 == -$1 })
    }

    func memoryTrackIsExactAndBudgeted() {
        let url = writeWAV(dir.appendingPathComponent("mem.wav"), rate: 44_100, bits: 24, frames: 30_000) { f, c in f * 211 % 7_000_000 - c * 5000 }
        let disk = readAll(try! LosslessFile(path: url.path))
        let t = MemoryTrack.load(from: try! LosslessFile(path: url.path), budgetBytes: 10_000_000)
        expect(t != nil && t!.frames == 30_000 && t!.bytes == 30_000 * 8)
        let src = MemorySource(t!)
        expect(readAll(src) == disk, "RAM copy must equal the decoded file")
        src.seek(to: 1234)
        expect(readAll(src) == Array(disk[(1234 * 2)...]))
        expect(MemoryTrack.load(from: try! LosslessFile(path: url.path), budgetBytes: 1000) == nil, "over-budget tracks are refused")
        let before = DiskStats.readCalls
        _ = readAll(MemorySource(t!))
        expect(DiskStats.readCalls == before, "reading from RAM must not touch the disk")
        let cache = TrackCache(budgetBytes: 300_000)
        cache.put(url.path + "|pcm", t!)
        expect(cache.get(url.path + "|pcm") != nil)
        cache.retain(onlyPaths: ["/other"])
        expect(cache.get(url.path + "|pcm") == nil)
    }
}

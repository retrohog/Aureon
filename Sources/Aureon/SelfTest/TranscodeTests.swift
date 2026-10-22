import Foundation
import AVFoundation

struct TranscodeTests {
    /// A FLAC file of generated 16-bit audio, tagged.
    @discardableResult
    private func makeFLAC(_ url: URL, seconds: Double, rate: Double = 44_100, channels: Int = 2, tagged: Bool = true, _ gen: (Int, Int) -> Int16) -> URL {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16]
        do {
        let f = try! AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let total = Int(seconds * rate), chunk = 8192
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var i = 0
        while i < total {
            let n = min(chunk, total - i)
            buf.frameLength = AVAudioFrameCount(n)
            let p = buf.int16ChannelData![0]
            for k in 0..<n { for c in 0..<channels { p[k * channels + c] = gen(i + k, c) } }
            try! f.write(from: buf)
            i += n
        }
        }                                                                                   // closing the file finishes its header
        if tagged {
            try! FLACTagWriter.write(path: url.path, comments: [("TITLE", "Test Tone"), ("ARTIST", "The Sines"), ("ALBUMARTIST", "Various"), ("ALBUM", "Waves"), ("TRACKNUMBER", "3"), ("TRACKTOTAL", "9"),
                                                                 ("DATE", "2004"), ("GENRE", "Test"), ("MUSICBRAINZ_ALBUMID", "11111111-2222-3333-4444-555555555555")],
                                     picture: .init(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4, 5, 6, 7, 8]), mime: "image/png"))
        }
        return url
    }

    private func sine(_ db: Double, _ hz: Double = 1000, rate: Double = 44_100) -> (Int, Int) -> Int16 {
        let a = pow(10, db / 20) * 32767
        return { i, c in Int16(a * sin(2 * .pi * hz * Double(i) / rate + Double(c) * 0.3)) }
    }

    private func samples(_ url: URL) -> [Int32] {
        let f = try! LosslessFile(path: url.path)
        var out: [Int32] = [], buf = [Int32](repeating: 0, count: 4096 * f.info.channels)
        while true { let n = f.read(into: &buf, frames: 4096); if n == 0 { break }; out += buf[0..<(n * f.info.channels)] }
        return out
    }

    func gainMath() {
        func m(_ i: Double?, _ tp: Double) -> R128Result { R128Result(integratedLUFS: i, loudnessRange: 0, truePeakDB: tp, samplePeakDB: tp, momentaryMaxLUFS: nil, shortTermMaxLUFS: nil, dynamicRange: 0, duration: 10, sampleRate: 44_100, channels: 2) }
        let t = LoudnessTarget(lufs: -16, truePeakCeilingDB: -1, allowBoost: true)
        var g = Transcoder.gain(for: m(-20, -10), target: t)
        expect(abs(g.db - 4) < 1e-9 && !g.limited, "\(g)")
        g = Transcoder.gain(for: m(-30, -8), target: t)
        expect(abs(g.db - 7) < 1e-9 && g.limited, "boost is held back by the peak ceiling: \(g)")
        g = Transcoder.gain(for: m(-10, -0.2), target: t)
        expect(abs(g.db + 6) < 1e-9 && !g.limited, "loud tracks are turned down: \(g)")
        var noBoost = t; noBoost.allowBoost = false
        expect(Transcoder.gain(for: m(-30, -20), target: noBoost).db == 0, "no boost when quiet tracks are to be left alone")
        expect(Transcoder.gain(for: m(nil, -20), target: t).db == 0, "silence gets no gain")
        expect(Transcoder.outputRate(for: 96_000, options: TranscodeOptions(format: .aac)) == 48_000 && Transcoder.outputRate(for: 88_200, options: TranscodeOptions(format: .aac)) == 44_100 && Transcoder.outputRate(for: 352_800, options: TranscodeOptions(format: .aac)) == 44_100)
        expect(Transcoder.outputRate(for: 96_000, options: TranscodeOptions(format: .flac)) == 96_000)
        var cap = TranscodeOptions(format: .flac); cap.maxSampleRate = 48_000
        expect(Transcoder.outputRate(for: 192_000, options: cap) == 48_000 && Transcoder.outputRate(for: 176_400, options: cap) == 44_100 && Transcoder.outputRate(for: 44_100, options: cap) == 44_100)
    }

    func aacLevelledWithTags() {
        let dir = tempDir("tc-aac")
        let src = makeFLAC(dir.appendingPathComponent("tone.flac"), seconds: 8, sine(-30))
        let dst = dir.appendingPathComponent("out/tone.m4a")
        var o = TranscodeOptions(); o.normalize = LoudnessTarget(lufs: -16)
        var seen: [Double] = []
        let r = Transcoder.transcode(TranscodeJob(source: src, destination: dst), options: o, progress: { seen.append($0) })
        expect(r.ok, "\(r.outcome)")
        expect(FileManager.default.fileExists(atPath: dst.path) && r.outputSampleRate == 44_100)
        expect(seen == seen.sorted() && seen.last == 1 && seen.count > 4, "progress runs forward to 1")
        guard let out = R128.analyze(path: dst.path) else { expect(false, "the output can be analysed"); return }
        expect(abs((out.integratedLUFS ?? 0) + 16) < 0.6, "levelled to -16 LUFS, got \(out.integratedLUFS ?? 0)")
        expect(abs(out.duration - 8) < 0.1, "duration \(out.duration)")
        let kbps = Double(r.outputBytes) * 8 / out.duration / 1000
        expect(kbps > 235 && kbps < 285, "about 256 kbps, got \(kbps)")
        expect(abs(r.appliedGainDB - 14) < 1.5 && !r.gainLimitedByPeak, "gain \(r.appliedGainDB)")
        let t = MetadataEngine.native(path: dst.path)
        expect(t.title == "Test Tone" && t.artist == "The Sines" && t.albumArtist == "Various" && t.album == "Waves" && t.trackNumber == 3 && t.trackTotal == 9 && t.year == 2004 && t.genre == "Test", "\(t)")
        expect(t.picture?.data.count == 16, "the cover art is carried over")
        let mb = TagInterpreter.interpret(TagReader.readAll(path: dst.path).tags).mbReleaseID
        expect(mb == "11111111-2222-3333-4444-555555555555", "MusicBrainz release id: \(mb ?? "nil")")
        expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("out/.tone.m4a.partial.m4a").path), "no temporary file is left")
    }

    func peaksStayUnderTheCeiling() {
        let dir = tempDir("tc-peak")
        // quiet material with rare loud clicks: the loudness target asks for a big boost the peaks cannot take
        let src = makeFLAC(dir.appendingPathComponent("clicks.flac"), seconds: 6) { i, c in
            let hum = 0.004 * 32767 * sin(2 * .pi * 100 * Double(i) / 44_100)
            return Int16(hum + (i % 22_050 == 5 ? 0.9 * 32767 : 0))
        }
        var o = TranscodeOptions(format: .flac); o.normalize = LoudnessTarget(lufs: -14, truePeakCeilingDB: -1)
        let dst = dir.appendingPathComponent("clicks-out.flac")
        let r = Transcoder.transcode(TranscodeJob(source: src, destination: dst), options: o)
        expect(r.ok && r.gainLimitedByPeak, "limited by the peak, not by the target: \(r.appliedGainDB) dB")
        let out = R128.analyze(path: dst.path)!
        expect(out.truePeakDB <= -0.85 && out.truePeakDB > -1.5, "true peak \(out.truePeakDB) dBTP")
        expect(abs(out.truePeakDB - (r.measured!.truePeakDB + r.appliedGainDB)) < 0.3, "the peak moved by exactly the applied gain")
    }

    func losslessIsBitExact() {
        let dir = tempDir("tc-lossless")
        var x: UInt64 = 7
        func noise(_ i: Int, _ c: Int) -> Int16 { x = x &* 6364136223846793005 &+ 1442695040888963407; return Int16(truncatingIfNeeded: Int(x >> 40) % 20_000) }
        let src = makeFLAC(dir.appendingPathComponent("noise.flac"), seconds: 3, noise)
        let truth = samples(src)
        for fmt in [TranscodeFormat.flac, .alac] {
            let dst = dir.appendingPathComponent("noise-out.\(fmt.fileExtension)")
            let r = Transcoder.transcode(TranscodeJob(source: src, destination: dst), options: TranscodeOptions(format: fmt))
            expect(r.ok && r.appliedGainDB == 0 && r.measured == nil, "\(fmt): \(r.outcome)")
            let got = samples(dst)
            expect(got.count == truth.count && got == truth, "\(fmt) is bit-exact (\(got.count) vs \(truth.count) samples)")
            expect(MetadataEngine.native(path: dst.path).title == "Test Tone", "\(fmt) keeps its tags")
            try? FileManager.default.removeItem(at: dst)
        }
    }

    func ratesAreConverted() {
        let dir = tempDir("tc-rate")
        let src = makeFLAC(dir.appendingPathComponent("hi.flac"), seconds: 4, rate: 96_000, sine(-12, 3000, rate: 96_000))
        let aac = dir.appendingPathComponent("hi.m4a")
        let r = Transcoder.transcode(TranscodeJob(source: src, destination: aac), options: TranscodeOptions(format: .aac))
        expect(r.ok && r.outputSampleRate == 48_000, "\(r.outcome) \(r.outputSampleRate)")
        let a = R128.analyze(path: aac.path)!
        expect(a.sampleRate == 48_000 && abs(a.duration - 4) < 0.1, "\(a.sampleRate) Hz, \(a.duration) s")
        expect(abs(a.samplePeakDB - (-12)) < 1.5, "level survives the conversion: \(a.samplePeakDB)")
        var cap = TranscodeOptions(format: .flac); cap.maxSampleRate = 44_100
        let src2 = makeFLAC(dir.appendingPathComponent("hi2.flac"), seconds: 2, rate: 88_200, sine(-6, 1000, rate: 88_200))
        let flac = dir.appendingPathComponent("lo.flac")
        let r2 = Transcoder.transcode(TranscodeJob(source: src2, destination: flac), options: cap)
        let b = R128.analyze(path: flac.path)!
        expect(r2.ok && b.sampleRate == 44_100 && abs(b.duration - 2) < 0.05 && abs(b.samplePeakDB + 6) < 0.8, "\(r2.outcome) \(b.sampleRate) \(b.duration) \(b.samplePeakDB)")
    }

    func batchesRunInParallel() {
        let dir = tempDir("tc-batch")
        let jobs = (0..<7).map { i in TranscodeJob(source: makeFLAC(dir.appendingPathComponent("t\(i).flac"), seconds: 10, sine(-20 - Double(i), 440 + Double(i) * 50)), destination: dir.appendingPathComponent("out/t\(i).m4a")) }
        var o = TranscodeOptions(); o.concurrency = 3; o.normalize = LoudnessTarget(lufs: -16)
        let lock = NSLock()
        var active = Set<Int>(), maxActive = 0, last = [Double](repeating: 0, count: 7), regress = false, finishedCount = 0
        let results = Transcoder.run(jobs: jobs, options: o, progress: { i, p in
            lock.lock(); active.insert(i); maxActive = max(maxActive, active.count); if p < last[i] { regress = true }; last[i] = p; lock.unlock()
        }, finished: { i, _ in lock.lock(); active.remove(i); finishedCount += 1; lock.unlock() })
        expect(results.count == 7 && results.allSatisfy(\.ok), "\(results.map(\.outcome))")
        expect(maxActive >= 2 && maxActive <= 3, "ran \(maxActive) at a time, asked for 3")
        expect(!regress && finishedCount == 7 && last.allSatisfy { $0 == 1 })
        // every file ended up at the same loudness although they started 6 LU apart
        let loud = jobs.map { R128.analyze(path: $0.destination.path)!.integratedLUFS! }
        expect(loud.allSatisfy { abs($0 + 16) < 0.7 }, "\(loud)")
        expect(results.map { $0.job.source.lastPathComponent } == (0..<7).map { "t\($0).flac" }, "results keep the order of the jobs")
    }

    func failuresAndCancelling() {
        let dir = tempDir("tc-fail")
        let good = makeFLAC(dir.appendingPathComponent("good.flac"), seconds: 2, sine(-20))
        let junk = dir.appendingPathComponent("junk.flac"); try! Data(repeating: 7, count: 5000).write(to: junk)
        let rs = Transcoder.run(jobs: [TranscodeJob(source: dir.appendingPathComponent("missing.flac"), destination: dir.appendingPathComponent("o/m.m4a")),
                                       TranscodeJob(source: junk, destination: dir.appendingPathComponent("o/j.m4a")),
                                       TranscodeJob(source: good, destination: dir.appendingPathComponent("o/g.m4a"))], options: TranscodeOptions())
        if case .failed = rs[0].outcome, case .failed = rs[1].outcome { } else { expect(false, "bad inputs must fail: \(rs.map(\.outcome))") }
        expect(rs[2].ok && FileManager.default.fileExists(atPath: dir.appendingPathComponent("o/g.m4a").path), "one bad file does not stop the others")
        expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("o/j.m4a").path) && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("o/m.m4a").path))

        let long = makeFLAC(dir.appendingPathComponent("long.flac"), seconds: 30, sine(-20))
        let dst = dir.appendingPathComponent("o/long.m4a")
        var calls = 0
        let r = Transcoder.transcode(TranscodeJob(source: long, destination: dst), options: TranscodeOptions(), progress: { _ in }, cancelled: { calls += 1; return calls > 4 })
        expect(r.outcome == .cancelled && !FileManager.default.fileExists(atPath: dst.path), "cancelled midway leaves nothing behind")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("o").path)) ?? []
        expect(!left.contains { $0.contains("partial") }, "\(left)")
        var stop = false
        let rs2 = Transcoder.run(jobs: (0..<4).map { TranscodeJob(source: good, destination: dir.appendingPathComponent("c/\($0).m4a")) }, options: { var o = TranscodeOptions(); o.concurrency = 1; return o }(),
                                 finished: { _, _ in stop = true }, cancelled: { stop })
        expect(rs2[0].ok && rs2.dropFirst().allSatisfy { $0.outcome == .cancelled }, "after cancelling, the rest are skipped: \(rs2.map(\.outcome))")
    }

    func namingAndFolders() {
        let dir = tempDir("tc-names")
        let album = dir.appendingPathComponent("Music/Artist/Album", isDirectory: true)
        try! FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        for n in ["02 b.flac", "01 a.flac", "cover.jpg", "notes.txt"] { try! Data([1]).write(to: album.appendingPathComponent(n)) }
        let found = Transcoder.expand([dir.appendingPathComponent("Music")])
        expect(found.map(\.lastPathComponent) == ["01 a.flac", "02 b.flac"], "\(found.map(\.lastPathComponent))")
        let out = dir.appendingPathComponent("Out")
        let d1 = Transcoder.destination(for: found[0], in: out, format: .aac, relativeTo: dir.appendingPathComponent("Music"))
        expect(d1.path == out.appendingPathComponent("Artist/Album/01 a.m4a").path, d1.path)
        try! FileManager.default.createDirectory(at: d1.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data([1]).write(to: d1)
        expect(Transcoder.destination(for: found[0], in: out, format: .aac, relativeTo: dir.appendingPathComponent("Music")).lastPathComponent == "01 a (2).m4a", "an existing file is never overwritten")
        expect(Transcoder.destination(for: found[0], in: out, format: .aac, taken: [out.appendingPathComponent("01 a.m4a").path]).lastPathComponent == "01 a (2).m4a", "nor one already planned in this batch")
        expect(Transcoder.destination(for: found[1], in: out, format: .flac).lastPathComponent == "02 b.flac")
    }

    func surroundBecomesStereo() {
        let dir = tempDir("tc-51")
        let src = dir.appendingPathComponent("six.caf")
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        do {
        let f = try! AVAudioFile(forWriting: src, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 48_000)!
        buf.frameLength = 48_000
        for c in 0..<6 { for i in 0..<48_000 { buf.floatChannelData![c][i] = c == 3 ? 0.5 * Float(sin(Double(i) * 0.01)) : (c == 0 ? 0.3 * Float(sin(Double(i) * 0.05)) : 0) } }
        try! f.write(from: buf)
        }
        let dst = dir.appendingPathComponent("two.m4a")
        let r = Transcoder.transcode(TranscodeJob(source: src, destination: dst), options: TranscodeOptions())
        expect(r.ok, "\(r.outcome)")
        let out = R128.analyze(path: dst.path)
        expect(out?.channels == 2 && abs((out?.duration ?? 0) - 1) < 0.1, "\(String(describing: out?.channels)) channels")
        expect((out?.samplePeakDB ?? 0) > -20 && (out?.samplePeakDB ?? 0) < -16, "the front-left tone (scaled by the downmix) is there, the louder LFE is left out: \(out?.samplePeakDB ?? 0)")
    }
}

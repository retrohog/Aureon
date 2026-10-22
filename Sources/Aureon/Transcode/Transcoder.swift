import Foundation
import AVFoundation
import Accelerate

// Batch transcoding: any file Aureon can play → 256 kbps AAC, Apple Lossless or FLAC, optionally levelled to a loudness target
// (EBU R128 integrated loudness, never past a true-peak ceiling), with tags and cover art carried over.
// Each file is independent, so a batch runs on as many cores as the Mac can spare.

enum TranscodeFormat: String, Codable, CaseIterable, Identifiable {
    case aac, alac, flac
    var id: String { rawValue }
    var title: String { switch self { case .aac: "AAC 256 kbps"; case .alac: "Apple Lossless"; case .flac: "FLAC" } }
    var fileExtension: String { self == .flac ? "flac" : "m4a" }
    var isLossless: Bool { self != .aac }
}

struct LoudnessTarget: Codable, Equatable {
    var lufs: Double = -16
    /// Gain is reduced until the true peak stays under this ceiling, so nothing ever clips and no limiter colours the sound.
    var truePeakCeilingDB: Double = -1
    /// Quiet tracks are brought up to the target; with this off only loud tracks are turned down.
    var allowBoost = true
    static let streaming = LoudnessTarget(lufs: -14), apple = LoudnessTarget(lufs: -16), broadcast = LoudnessTarget(lufs: -23, truePeakCeilingDB: -1)
}

struct TranscodeOptions: Codable, Equatable {
    var format = TranscodeFormat.aac
    var bitrate = 256_000                       // AAC, per stereo pair
    var normalize: LoudnessTarget? = nil
    /// Hard cap for the output sample rate; AAC is always kept at or below 48 kHz.
    var maxSampleRate: Double? = nil
    /// 0 means "as many as this Mac can spare".
    var concurrency = 0
    var includeLFEInDownmix = false
}

struct TranscodeJob: Equatable {
    var source: URL
    var destination: URL
}

struct TranscodeResult: Equatable {
    enum Outcome: Equatable { case done, failed(String), cancelled }
    var job: TranscodeJob
    var outcome: Outcome
    var measured: R128Result? = nil
    var appliedGainDB = 0.0
    var gainLimitedByPeak = false
    var outputSampleRate = 0.0
    var outputBytes = 0
    var duration = 0.0
    var ok: Bool { outcome == .done }
}

/// The tags worth keeping, as read from any container.
struct SourceTags {
    var basic: TrackTags
    var meta: TrackMetadata
    var raw: RawTags
}

enum Transcoder {
    static func defaultConcurrency() -> Int { max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)) }

    static let supportedExtensions: Set<String> = ["flac", "wav", "aif", "aiff", "aifc", "m4a", "mp4", "alac", "caf", "mp3", "aac", "dsf", "dff", "ogg", "opus"]

    /// The output file for a source: same name, new extension, never overwriting an existing file.
    static func destination(for source: URL, in folder: URL, format: TranscodeFormat, relativeTo base: URL? = nil, taken: Set<String> = []) -> URL {
        var dir = folder
        if let base {
            let sp = source.deletingLastPathComponent().standardizedFileURL.pathComponents, bp = base.standardizedFileURL.pathComponents
            if sp.count > bp.count, Array(sp.prefix(bp.count)) == bp { for c in sp[bp.count...] { dir.appendPathComponent(c, isDirectory: true) } }
        }
        let stem = source.deletingPathExtension().lastPathComponent
        var url = dir.appendingPathComponent(stem).appendingPathExtension(format.fileExtension), n = 2
        while FileManager.default.fileExists(atPath: url.path) || taken.contains(url.path) {
            url = dir.appendingPathComponent("\(stem) (\(n))").appendingPathExtension(format.fileExtension); n += 1
        }
        return url
    }

    /// Everything playable under these URLs (folders are searched recursively), in a stable order.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var found: [URL] = []
                while let f = e?.nextObject() as? URL { if supportedExtensions.contains(f.pathExtension.lowercased()) { found.append(f) } }
                out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if supportedExtensions.contains(u.pathExtension.lowercased()) { out.append(u) }
        }
        return out
    }

    // MARK: batch

    /// Runs the whole batch and returns when every job has finished. Call it off the main thread. `progress` gets (job index, 0…1).
    @discardableResult
    static func run(jobs: [TranscodeJob], options: TranscodeOptions, progress: @escaping @Sendable (Int, Double) -> Void = { _, _ in },
                    finished: @escaping @Sendable (Int, TranscodeResult) -> Void = { _, _ in }, cancelled: @escaping @Sendable () -> Bool = { false }) -> [TranscodeResult] {
        let n = options.concurrency > 0 ? options.concurrency : defaultConcurrency()
        let queue = DispatchQueue(label: "aureon.transcode", qos: .utility, attributes: .concurrent)
        let slots = DispatchSemaphore(value: n), group = DispatchGroup()
        let lock = NSLock()
        var results = [TranscodeResult?](repeating: nil, count: jobs.count)
        for (i, job) in jobs.enumerated() {
            slots.wait()
            if cancelled() {
                lock.lock(); results[i] = TranscodeResult(job: job, outcome: .cancelled); lock.unlock(); finished(i, results[i]!); slots.signal(); continue
            }
            group.enter()
            queue.async {
                let r = autoreleasepool { transcode(job, options: options, progress: { progress(i, $0) }, cancelled: cancelled) }
                lock.lock(); results[i] = r; lock.unlock()
                finished(i, r)
                slots.signal(); group.leave()
            }
        }
        group.wait()
        return results.enumerated().map { $1 ?? TranscodeResult(job: jobs[$0], outcome: .cancelled) }
    }

    // MARK: one file

    private static func openSource(_ url: URL) throws -> FrameSource {
        let ext = url.pathExtension.lowercased()
        if ext == "dsf" || ext == "dff" {
            let c = try DsdContainer(path: url.path)
            let codec = "DSD\(Int((c.dsdRate / 44_100).rounded()))"
            guard let s = DsdToPcm.make(c, codec: codec, pcmRate: c.dsdRate >= 5_644_800 ? 176_400 : 88_200, gainDB: 0) else { throw AureonError.message("cannot convert DSD") }
            return s
        }
        return try openLossless(path: url.path)
    }

    static func readTags(_ url: URL) -> SourceTags {
        let ext = url.pathExtension.lowercased()
        let file = ext == "dsf" || ext == "dff" ? FileTags() : TagReader.readAll(path: url.path)
        return SourceTags(basic: MetadataEngine.native(path: url.path), meta: TagInterpreter.interpret(file.tags, fileName: url.lastPathComponent), raw: file.tags)
    }

    static func outputRate(for source: Double, options: TranscodeOptions) -> Double {
        var r = source
        if options.format == .aac && r > 48_000 { r = r.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000 }
        if let cap = options.maxSampleRate, r > cap {
            let family: [Double] = source.truncatingRemainder(dividingBy: 44_100) == 0 ? [44_100, 88_200, 176_400, 352_800, 705_600] : [48_000, 96_000, 192_000, 384_000]
            r = family.filter { $0 <= cap }.max() ?? cap
        }
        return r
    }

    /// Gain that brings `measured` to the target without letting the true peak pass the ceiling.
    static func gain(for measured: R128Result, target t: LoudnessTarget) -> (db: Double, limited: Bool) {
        guard let i = measured.integratedLUFS, i.isFinite else { return (0, false) }
        var g = t.lufs - i
        if !t.allowBoost { g = min(g, 0) }
        let headroom = t.truePeakCeilingDB - measured.truePeakDB
        return g > headroom ? (headroom, true) : (g, false)
    }

    static func transcode(_ job: TranscodeJob, options: TranscodeOptions, progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> TranscodeResult {
        var result = TranscodeResult(job: job, outcome: .done)
        let fm = FileManager.default
        let partial = job.destination.deletingLastPathComponent().appendingPathComponent(".\(job.destination.lastPathComponent).partial.\(options.format.fileExtension)")
        defer { try? fm.removeItem(at: partial) }
        do {
            try fm.createDirectory(at: job.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            var source = try openSource(job.source)
            let sourceInfo = source.info
            guard sourceInfo.totalFrames > 0 else { throw AureonError.message("the file has no audio") }
            let sourceBits = sourceInfo.sourceBits == 1 ? 24 : sourceInfo.sourceBits
            if sourceInfo.channels > 2 {
                source = DownmixSource(source, target: [.fl, .fr], includeLFE: options.includeLFEInDownmix)
            }
            let ch = source.info.channels, inRate = source.info.sampleRate
            let total = Double(source.info.totalFrames)
            let outRate = outputRate(for: inRate, options: options)
            result.outputSampleRate = outRate
            result.duration = total / inRate

            let chunk = 16_384
            let ints = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * ch), floats = UnsafeMutablePointer<Float>.allocate(capacity: chunk * ch)
            defer { ints.deallocate(); floats.deallocate() }
            let toUnit: Float = 1 / 2_147_483_648

            // pass 1: loudness (only when levelling)
            var gainLinear: Float = 1
            if let target = options.normalize {
                let meter = R128Meter(sampleRate: inRate, channels: ch, chunk: chunk)
                var done = 0.0
                while true {
                    if cancelled() { result.outcome = .cancelled; return result }
                    let n = source.read(into: ints, frames: chunk)
                    if n == 0 { break }
                    vDSP_vflt32(ints, 1, floats, 1, vDSP_Length(n * ch))
                    var s = toUnit; vDSP_vsmul(floats, 1, &s, floats, 1, vDSP_Length(n * ch))
                    meter.feed(floats, frames: n)
                    done += Double(n); progress(min(0.45, 0.45 * done / total))
                }
                let m = meter.finish(duration: result.duration)
                result.measured = m
                let g = gain(for: m, target: target)
                result.appliedGainDB = g.db; result.gainLimitedByPeak = g.limited
                gainLinear = Float(pow(10, g.db / 20))
                source.seek(to: 0)
            }

            // pass 2: gain, rate conversion, encode
            var settings: [String: Any]
            let bitDepth = min(sourceBits, 24) <= 16 ? 16 : 24
            switch options.format {
            case .aac: settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: outRate, AVNumberOfChannelsKey: ch, AVEncoderBitRateKey: options.bitrate * ch / 2]
            case .alac: settings = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: outRate, AVNumberOfChannelsKey: ch, AVEncoderBitDepthHintKey: bitDepth]
            case .flac: settings = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: outRate, AVNumberOfChannelsKey: ch, AVLinearPCMBitDepthKey: bitDepth]
            }
            var out: AVAudioFile? = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let outFormat = out!.processingFormat
            guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inRate, channels: AVAudioChannelCount(ch), interleaved: false),
                  let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(chunk)) else { throw AureonError.message("no audio buffer") }
            var converter: AVAudioConverter?
            if abs(inRate - outRate) > 0.5 {
                converter = AVAudioConverter(from: inFormat, to: outFormat)
                converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
                guard converter != nil else { throw AureonError.message("cannot convert \(inRate) Hz to \(outRate) Hz") }
            }
            // TPDF dither when a gain change meets a 16-bit file; otherwise the samples are written as they are
            let dither = options.format.isLossless && bitDepth == 16 && abs(gainLinear - 1) > 1e-6
            var rng = SystemRandomNumberGenerator()
            var written = 0.0, framesIn = 0.0
            let outCap = AVAudioFrameCount(Double(chunk) * outRate / inRate + 4096)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { throw AureonError.message("no audio buffer") }
            let base = options.normalize == nil ? 0.0 : 0.45

            func write(_ b: AVAudioPCMBuffer) throws { if b.frameLength > 0 { try out!.write(from: b) } }

            while true {
                if cancelled() { result.outcome = .cancelled; return result }
                let n = source.read(into: ints, frames: chunk)
                if n == 0 { break }
                vDSP_vflt32(ints, 1, floats, 1, vDSP_Length(n * ch))
                var s = toUnit * gainLinear
                inBuf.frameLength = AVAudioFrameCount(n)
                for c in 0..<ch { vDSP_vsmul(floats + c, ch, &s, inBuf.floatChannelData![c], 1, vDSP_Length(n)) }
                if dither {
                    for c in 0..<ch { let p = inBuf.floatChannelData![c]; for k in 0..<n { p[k] += (Float.random(in: -0.5..<0.5, using: &rng) + Float.random(in: -0.5..<0.5, using: &rng)) / 32_768 } }
                }
                framesIn += Double(n)
                if let converter {
                    var supplied = false
                    var err: NSError?
                    outBuf.frameLength = 0
                    let status = converter.convert(to: outBuf, error: &err) { _, st in
                        if supplied { st.pointee = .noDataNow; return nil }
                        supplied = true; st.pointee = .haveData; return inBuf
                    }
                    if status == .error { throw err ?? AureonError.message("sample-rate conversion failed") }
                    try write(outBuf)
                } else {
                    try write(inBuf)
                }
                written += Double(n)
                progress(min(0.99, base + (1 - base) * written / total))
            }
            if let converter {                                              // flush the converter's tail
                var err: NSError?
                outBuf.frameLength = 0
                let status = converter.convert(to: outBuf, error: &err) { _, st in st.pointee = .endOfStream; return nil }
                if status != .error { try write(outBuf) }
            }
            out = nil                                                       // closes the file

            try writeTags(readTags(job.source), to: partial, format: options.format)
            try? fm.removeItem(at: job.destination)
            try fm.moveItem(at: partial, to: job.destination)
            result.outputBytes = (try? fm.attributesOfItem(atPath: job.destination.path)[.size] as? Int) ?? 0
            progress(1)
            return result
        } catch {
            result.outcome = .failed("\(error.localizedDescription)")
            return result
        }
    }

    // MARK: tags

    static func writeTags(_ t: SourceTags, to url: URL, format: TranscodeFormat) throws {
        let b = t.basic, m = t.meta
        let picture = b.picture
        switch format {
        case .flac:
            var c: [(String, String)] = []
            func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { c.append((k, v)) } }
            add("TITLE", b.title); add("ARTIST", b.artist); add("ALBUMARTIST", b.albumArtist); add("ALBUM", b.album); add("COMPOSER", b.composer)
            for g in m.genres { add("GENRE", g) }
            if m.genres.isEmpty { add("GENRE", b.genre) }
            add("DATE", m.date ?? b.year.map(String.init))
            if let n = b.trackNumber { add("TRACKNUMBER", "\(n)") }
            if let n = b.trackTotal { add("TRACKTOTAL", "\(n)") }
            if let n = b.discNumber { add("DISCNUMBER", "\(n)") }
            if let n = m.discTotal { add("DISCTOTAL", "\(n)") }
            add("LABEL", m.label); add("CATALOGNUMBER", m.releaseCatalogNumber)
            add("WORK", m.workTitle); add("MUSICBRAINZ_TRACKID", m.mbRecordingID); add("MUSICBRAINZ_RELEASETRACKID", m.mbTrackID)
            add("MUSICBRAINZ_ALBUMID", m.mbReleaseID); add("MUSICBRAINZ_RELEASEGROUPID", m.mbReleaseGroupID); add("MUSICBRAINZ_WORKID", m.mbWorkID)
            add("ENCODER", "Aureon")
            try FLACTagWriter.write(path: url.path, comments: c, picture: picture.map { .init(data: $0.data, mime: $0.mime, width: $0.width, height: $0.height) })
        case .aac, .alac:
            var tags = MP4TagWriter.Tags()
            tags.title = b.title; tags.artist = b.artist; tags.albumArtist = b.albumArtist; tags.album = b.album; tags.composer = b.composer
            tags.genre = b.genre; tags.year = m.date ?? b.year.map(String.init)
            tags.track = b.trackNumber ?? 0; tags.trackTotal = b.trackTotal ?? 0; tags.disc = b.discNumber ?? 0; tags.discTotal = m.discTotal ?? 0
            func free(_ k: String, _ v: String?) { if let v, !v.isEmpty { tags.freeform.append((k, v)) } }
            free("MusicBrainz Track Id", m.mbRecordingID); free("MusicBrainz Release Track Id", m.mbTrackID); free("MusicBrainz Album Id", m.mbReleaseID)
            free("MusicBrainz Release Group Id", m.mbReleaseGroupID); free("MusicBrainz Work Id", m.mbWorkID); free("LABEL", m.label); free("CATALOGNUMBER", m.releaseCatalogNumber)
            if let p = picture { tags.cover = p.data; tags.coverIsPNG = p.mime.lowercased().contains("png") || p.data.starts(with: [0x89, 0x50]) }
            try MP4TagWriter.write(path: url.path, tags: tags)
        }
    }
}

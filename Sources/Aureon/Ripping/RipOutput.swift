import Foundation
import AVFoundation

enum RipFormat: String, Codable, CaseIterable, Identifiable {
    case flac, alac, wav
    var id: String { rawValue }
    var title: String { switch self { case .flac: "FLAC"; case .alac: "Apple Lossless (ALAC)"; case .wav: "WAV" } }
    var ext: String { switch self { case .flac: "flac"; case .alac: "m4a"; case .wav: "wav" } }
}

/// What is known about the disc as a whole and about each track (from MusicBrainz or typed in).
struct RipMetadata: Equatable {
    struct Track: Equatable { var title: String; var artist: String; var recordingID: String? = nil }
    var album = ""
    var albumArtist = ""
    var year = ""
    var genre = ""
    var releaseID: String?
    var discID: String?
    var tracks: [Int: Track] = [:]
    var cover: Data?

    func title(_ n: Int) -> String { tracks[n]?.title ?? String(format: "Track %02d", n) }
    func artist(_ n: Int) -> String { tracks[n]?.artist ?? albumArtist }
}

enum RipOutput {
    /// A file name safe on every file system.
    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let t = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return t.isEmpty ? "untitled" : String(t.prefix(120))
    }

    static func fileName(track n: Int, meta: RipMetadata, format: RipFormat) -> String {
        String(format: "%02d - ", n) + safeName(meta.title(n)) + "." + format.ext
    }

    /// Writes the track as 16-bit / 44.1 kHz stereo and tags it.
    static func write(_ track: RippedTrack, to url: URL, format: RipFormat, meta: RipMetadata, trackCount: Int, comment: String? = nil) throws {
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .wav: try writeWAV(track.samples, to: url)
        case .flac, .alac:
            let settings: [String: Any] = format == .flac
                ? [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16]
                : [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let chunk = 44_100
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else { throw CDReadError.unsupported("no PCM buffer") }
            var i = 0
            while i < track.samples.count {
                let n = min(chunk, track.samples.count - i)
                buf.frameLength = AVAudioFrameCount(n)
                let p = buf.int16ChannelData![0]
                for k in 0..<n { let s = track.samples[i + k]; p[2 * k] = Int16(truncatingIfNeeded: s); p[2 * k + 1] = Int16(truncatingIfNeeded: s >> 16) }
                try f.write(from: buf)
                i += n
            }
        }
        let n = track.number
        switch format {
        case .flac:
            var c: [(String, String)] = [("TITLE", meta.title(n)), ("ARTIST", meta.artist(n)), ("ALBUM", meta.album), ("ALBUMARTIST", meta.albumArtist),
                                         ("TRACKNUMBER", "\(n)"), ("TRACKTOTAL", "\(trackCount)")]
            if !meta.year.isEmpty { c.append(("DATE", meta.year)) }
            if !meta.genre.isEmpty { c.append(("GENRE", meta.genre)) }
            if let r = meta.releaseID { c.append(("MUSICBRAINZ_ALBUMID", r)) }
            if let r = meta.tracks[n]?.recordingID { c.append(("MUSICBRAINZ_TRACKID", r)) }
            if let d = meta.discID { c.append(("MUSICBRAINZ_DISCID", d)) }
            if let k = comment { c.append(("COMMENT", k)) }
            c.append(("ENCODER", "Aureon"))
            try FLACTagWriter.write(path: url.path, comments: c, picture: meta.cover.map { .init(data: $0, mime: $0.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg") })
        case .alac:
            var t = MP4TagWriter.Tags()
            t.title = meta.title(n); t.artist = meta.artist(n); t.albumArtist = meta.albumArtist; t.album = meta.album
            t.year = meta.year.isEmpty ? nil : meta.year; t.genre = meta.genre.isEmpty ? nil : meta.genre; t.comment = comment
            t.track = n; t.trackTotal = trackCount
            if let r = meta.releaseID { t.freeform.append(("MusicBrainz Album Id", r)) }
            if let r = meta.tracks[n]?.recordingID { t.freeform.append(("MusicBrainz Track Id", r)) }
            t.cover = meta.cover; t.coverIsPNG = meta.cover?.starts(with: [0x89, 0x50]) ?? false
            try MP4TagWriter.write(path: url.path, tags: t)
        case .wav: break
        }
    }

    static func writeWAV(_ samples: [UInt32], to url: URL) throws {
        func le(_ v: Int, _ n: Int) -> Data { Data((0..<n).map { UInt8((v >> (8 * $0)) & 255) }) }
        let bytes = samples.count * 4
        var d = Data("RIFF".utf8); d += le(36 + bytes, 4); d += Data("WAVEfmt ".utf8); d += le(16, 4) + le(1, 2) + le(2, 2) + le(44_100, 4) + le(44_100 * 4, 4) + le(4, 2) + le(16, 2)
        d += Data("data".utf8) + le(bytes, 4)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }                      // little-endian on every Mac
        try d.write(to: url)
    }

    // MARK: cue sheet and log

    static func cueSheet(toc: CDTOC, meta: RipMetadata, files: [Int: String]) -> String {
        var s = "REM DISCID \(String(format: "%08X", toc.cddbID))\nREM MUSICBRAINZ_DISCID \(toc.musicBrainzDiscID)\n"
        if !meta.year.isEmpty { s += "REM DATE \(meta.year)\n" }
        s += "PERFORMER \"\(meta.albumArtist)\"\nTITLE \"\(meta.album)\"\n"
        for t in toc.audioTracks {
            guard let f = files[t.number] else { continue }
            s += "FILE \"\(f)\" WAVE\n  TRACK \(String(format: "%02d", t.number)) AUDIO\n    TITLE \"\(meta.title(t.number))\"\n    PERFORMER \"\(meta.artist(t.number))\"\n    INDEX 01 00:00:00\n"
        }
        return s
    }

    static func msf(_ sectors: Int) -> String { String(format: "%d:%02d.%02d", sectors / 75 / 60, sectors / 75 % 60, (sectors % 75) * 100 / 75) }

    static func log(toc: CDTOC, drive: String, options: RipOptions, meta: RipMetadata, reports: [TrackRipReport], date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var s = "Aureon CD ripper — log of \(f.string(from: date))\n\n"
        s += "\(meta.albumArtist) / \(meta.album)\n\nDrive              : \(drive)\nRead mode          : \(options.mode.title) (\(options.mode.blurb))\n"
        s += "C2 error pointers  : \(options.useC2 ? "used when the drive offers them" : "not used")\nRead offset        : \(options.readOffset > 0 ? "+" : "")\(options.readOffset) samples\n"
        s += "MusicBrainz disc ID: \(toc.musicBrainzDiscID)\nAccurateRip IDs    : \(String(format: "%08x-%08x-%08x", toc.accurateRipIDs.id1, toc.accurateRipIDs.id2, toc.accurateRipIDs.cddb))\n\nTOC\n"
        s += "  Track   Start       Length      Sectors\n"
        for t in toc.tracks { s += String(format: "  %3d%@   %@   %@   %d\n", t.number, t.isAudio ? " " : "D", msf(t.startLBA).padding(toLength: 10, withPad: " ", startingAt: 0), msf(toc.sectorCount(of: t)).padding(toLength: 10, withPad: " ", startingAt: 0), toc.sectorCount(of: t)) }
        s += "\n"
        var accurate = 0, bad = 0
        for r in reports {
            s += "Track \(String(format: "%02d", r.number)): \(meta.title(r.number))\n"
            s += "  Peak level           : \(String(format: "%.1f %%", r.peak * 100))\n"
            s += "  First-read CRC       : \(String(format: "%08X", r.firstReadCRC))\n  Copy CRC             : \(String(format: "%08X", r.finalCRC))\n"
            s += "  AccurateRip v1 / v2  : \(String(format: "%08X / %08X", r.checksums.v1, r.checksums.v2))\n"
            s += "  Sectors read / extra : \(r.reads) / \(r.rereads)\n  C2 errors            : \(r.c2Sectors) sectors\n"
            if let v = r.accurateRip { s += "  AccurateRip          : \(v.summary)\n"; if v.kind == .accurate { accurate += 1 } }
            if !r.unresolvedSectors.isEmpty { s += "  UNRESOLVED sectors   : \(r.unresolvedSectors.prefix(20).map(String.init).joined(separator: ", "))\(r.unresolvedSectors.count > 20 ? ", …" : "")\n"; bad += 1 }
            let disagreed = r.issues.filter { $0.kind == .disagreed }.count
            if disagreed > 0 { s += "  Decided by vote      : \(disagreed) sectors (their reads did not all agree)\n" }
            s += r.perfect ? "  Result               : read cleanly\n\n" : "  Result               : needed re-reads or has questionable sectors\n\n"
        }
        s += "\(accurate) of \(reports.count) tracks accurately ripped according to AccurateRip; \(bad) with unresolved sectors.\n"
        return s
    }
}

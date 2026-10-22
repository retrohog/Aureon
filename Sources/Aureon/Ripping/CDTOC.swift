import Foundation
import CryptoKit

/// One track of a compact disc.
struct CDTrack: Codable, Equatable {
    var number: Int
    var startLBA: Int                       // sector number counted from the start of the program area (track 1 usually 0)
    var isAudio: Bool
}

/// The table of contents of a disc, and the identifiers derived from it (MusicBrainz, FreeDB/CDDB, AccurateRip).
struct CDTOC: Codable, Equatable {
    static let sectorSamples = 588                   // stereo frames per sector
    static let sectorBytes = 2352
    static let pregap = 150                          // the 2 s every absolute address carries

    var tracks: [CDTrack]
    var leadoutLBA: Int

    var audioTracks: [CDTrack] { tracks.filter(\.isAudio) }

    /// Offsets as printed on a disc-ID page: LBA + 150, per track, then the lead-out.
    init(offsets: [Int], leadout: Int) {
        tracks = offsets.enumerated().map { CDTrack(number: $0 + 1, startLBA: $1 - Self.pregap, isAudio: true) }
        leadoutLBA = leadout - Self.pregap
    }

    init(tracks: [CDTrack], leadoutLBA: Int) { self.tracks = tracks; self.leadoutLBA = leadoutLBA }

    /// The lead-out as the identifiers see it: on an Enhanced CD (a data track after the audio) the audio ends 11 400 sectors before the data session begins.
    var effectiveLeadoutLBA: Int {
        if let lastAudio = audioTracks.last, let data = tracks.first(where: { !$0.isAudio && $0.startLBA > lastAudio.startLBA }) { return data.startLBA - 11_400 }
        return leadoutLBA
    }

    /// Where track `n` ends (exclusive): the start of the next track, or the lead-out.
    func endLBA(of track: CDTrack) -> Int {
        if let next = tracks.first(where: { $0.startLBA > track.startLBA }) { return track.isAudio && !next.isAudio ? next.startLBA - 11_400 : next.startLBA }
        return leadoutLBA
    }

    func sectorCount(of track: CDTrack) -> Int { max(0, endLBA(of: track) - track.startLBA) }
    func seconds(of track: CDTrack) -> Double { Double(sectorCount(of: track)) / 75 }
    var totalAudioSectors: Int { audioTracks.reduce(0) { $0 + sectorCount(of: $1) } }

    /// The disc's audio tracks must be numbered from 1 without gaps for the identifiers below to be meaningful.
    var hasStandardNumbering: Bool { audioTracks.enumerated().allSatisfy { $1.number == $0 + 1 } && !audioTracks.isEmpty }

    // MARK: MusicBrainz disc ID

    /// SHA-1 of the first and last track numbers, the lead-out and the 99 track offsets (all +150, as 2- and 8-digit hex), in MusicBrainz's base64 alphabet.
    var musicBrainzDiscID: String {
        let a = audioTracks
        var s = String(format: "%02X%02X%08X", 1, a.count, effectiveLeadoutLBA + Self.pregap)
        for i in 0..<99 { s += String(format: "%08X", i < a.count ? a[i].startLBA + Self.pregap : 0) }
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: ".").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "-")
    }

    // MARK: FreeDB / CDDB id

    var cddbID: UInt32 {
        func digitSum(_ n: Int) -> Int { String(n).reduce(0) { $0 + Int(String($1))! } }
        let a = audioTracks
        guard let first = a.first else { return 0 }
        let n = a.reduce(0) { $0 + digitSum(($1.startLBA + Self.pregap) / 75) }
        let t = (effectiveLeadoutLBA + Self.pregap) / 75 - (first.startLBA + Self.pregap) / 75
        return UInt32(truncatingIfNeeded: ((n % 255) << 24) | (t << 8) | a.count)
    }

    // MARK: AccurateRip

    /// The two disc IDs AccurateRip derives from the sector offsets, and the CDDB id.
    var accurateRipIDs: (id1: UInt32, id2: UInt32, cddb: UInt32) {
        var id1: UInt64 = 0, id2: UInt64 = 0
        let a = audioTracks
        for (i, t) in a.enumerated() { id1 += UInt64(t.startLBA); id2 += UInt64(max(t.startLBA, 1)) * UInt64(i + 1) }
        id1 += UInt64(effectiveLeadoutLBA); id2 += UInt64(effectiveLeadoutLBA) * UInt64(a.count + 1)
        return (UInt32(truncatingIfNeeded: id1), UInt32(truncatingIfNeeded: id2), cddbID)
    }

    /// Where the database keeps the checksums of this disc.
    func accurateRipURL(base: URL = URL(string: "https://www.accuraterip.com/accuraterip")!) -> URL {
        let ids = accurateRipIDs
        let path = String(format: "%x/%x/%x/dBAR-%03d-%08x-%08x-%08x.bin", ids.id1 & 0xF, (ids.id1 >> 4) & 0xF, (ids.id1 >> 8) & 0xF, audioTracks.count, ids.id1, ids.id2, ids.cddb)
        return base.appendingPathComponent(path)
    }

    /// The query string MusicBrainz takes to look a disc up by its table of contents.
    var musicBrainzTOCString: String {
        let a = audioTracks
        return ([1, a.count, effectiveLeadoutLBA + Self.pregap] + a.map { $0.startLBA + Self.pregap }).map(String.init).joined(separator: "+")
    }

    // MARK: reading a TOC from the system

    /// Parses the `TOC` property of an IOCDMedia (or the answer to READ TOC, format 2): 4 header bytes, then 11-byte descriptors.
    static func parse(raw d: Data) -> CDTOC? {
        guard d.count >= 4 else { return nil }
        let length = Int(d[d.startIndex]) << 8 | Int(d[d.startIndex + 1])
        let end = min(d.count, length + 2)
        var tracks: [Int: CDTrack] = [:]
        var leadout: Int?
        var p = 4
        while p + 11 <= end {
            let o = d.startIndex + p
            let control = d[o + 1] & 0x0F, point = Int(d[o + 3])
            let lba = (Int(d[o + 8]) * 60 + Int(d[o + 9])) * 75 + Int(d[o + 10]) - pregap
            if point >= 1 && point <= 99 { tracks[point] = CDTrack(number: point, startLBA: lba, isAudio: control & 0x04 == 0) }
            else if point == 0xA2 { leadout = lba }
            p += 11
        }
        guard let leadout, !tracks.isEmpty else { return nil }
        return CDTOC(tracks: tracks.values.sorted { $0.number < $1.number }, leadoutLBA: leadout)
    }
}

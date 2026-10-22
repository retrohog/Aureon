import Foundation

// AccurateRip: a database of checksums of tracks as ripped by many people. A rip whose checksum matches an entry is, with that many witnesses, bit-identical to the pressing.
//
// A track's checksum treats it as 32-bit stereo samples (left in the low half). Sample number i (counting from 1) is weighted by i; the first track of a disc
// leaves out its first 2 938 samples and the last track its final 2 940, where drives are least reliable.
//   v1:  Σ i × sample                                  (mod 2³²)
//   v2:  Σ (high half + low half of the 64-bit i × sample)   (mod 2³²)   — corrects v1's loss of the high bits

struct ARChecksums: Equatable { var v1: UInt32, v2: UInt32 }

struct ARAccumulator {
    let totalSamples: Int
    private let from: Int, to: Int
    private var position = 0                         // samples consumed
    private(set) var v1: UInt32 = 0
    private(set) var v2: UInt32 = 0

    init(totalSamples: Int, isFirstTrack: Bool, isLastTrack: Bool) {
        self.totalSamples = totalSamples
        from = isFirstTrack ? 5 * CDTOC.sectorSamples - 1 : 0
        to = isLastTrack ? totalSamples - 5 * CDTOC.sectorSamples : totalSamples
    }

    mutating func add(_ samples: UnsafeBufferPointer<UInt32>) {
        var a1 = v1, a2 = v2
        var m = position + 1
        for s in samples {
            if m >= from && m <= to {
                let mult = UInt32(truncatingIfNeeded: m)
                a1 = a1 &+ mult &* s
                let p = UInt64(s) &* UInt64(m)
                a2 = a2 &+ UInt32(truncatingIfNeeded: p >> 32) &+ UInt32(truncatingIfNeeded: p)
            }
            m += 1
        }
        v1 = a1; v2 = a2; position += samples.count
    }

    mutating func add(_ samples: [UInt32]) { samples.withUnsafeBufferPointer { add($0) } }
    var result: ARChecksums { ARChecksums(v1: v1, v2: v2) }

    static func checksums(of samples: [UInt32], isFirst: Bool, isLast: Bool) -> ARChecksums {
        var a = ARAccumulator(totalSamples: samples.count, isFirstTrack: isFirst, isLastTrack: isLast)
        a.add(samples)
        return a.result
    }
}

struct ARPressing: Equatable {
    struct Entry: Equatable { var confidence: Int; var crc: UInt32; var crc450: UInt32 }
    var trackCount: Int
    var id1: UInt32, id2: UInt32, cddb: UInt32
    var tracks: [Entry]
}

struct ARTrackVerdict: Equatable {
    enum Kind: String { case accurate, notInDatabase, mismatch }
    var kind: Kind
    var confidence: Int                  // how many rippers agree with the matching entry
    var version: Int                     // 1 or 2: which checksum matched (0 when none)
    var pressingsChecked: Int
    var summary: String {
        switch kind {
        case .accurate: "Accurately ripped (v\(version), confidence \(confidence))"
        case .notInDatabase: "Not in the AccurateRip database"
        case .mismatch: "Does not match the database (\(pressingsChecked) pressing\(pressingsChecked == 1 ? "" : "s") checked)"
        }
    }
}

enum AccurateRip {
    /// The database's answer for a disc: a series of pressings, each a 13-byte header and then `trackCount` × (confidence, checksum, checksum-of-frame-450).
    static func parse(_ d: Data) -> [ARPressing] {
        var out: [ARPressing] = []
        var p = d.startIndex
        func u32(_ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 }
        while p + 13 <= d.endIndex {
            let n = Int(d[p])
            let need = 13 + n * 9
            guard n > 0, p + need <= d.endIndex else { break }
            var tracks: [ARPressing.Entry] = []
            for i in 0..<n { let o = p + 13 + i * 9; tracks.append(.init(confidence: Int(d[o]), crc: u32(o + 1), crc450: u32(o + 5))) }
            out.append(ARPressing(trackCount: n, id1: u32(p + 1), id2: u32(p + 5), cddb: u32(p + 9), tracks: tracks))
            p += need
        }
        return out
    }

    /// Does the checksum of track `number` (1-based) agree with any pressing?
    static func verify(track number: Int, checksums c: ARChecksums, in pressings: [ARPressing]?) -> ARTrackVerdict {
        guard let pressings, !pressings.isEmpty else { return ARTrackVerdict(kind: .notInDatabase, confidence: 0, version: 0, pressingsChecked: 0) }
        var best: (conf: Int, version: Int)?
        for p in pressings where number >= 1 && number <= p.tracks.count {
            let e = p.tracks[number - 1]
            if e.crc != 0 {
                if e.crc == c.v2 { if best == nil || e.confidence > best!.conf { best = (e.confidence, 2) } }
                else if e.crc == c.v1 { if best == nil || e.confidence > best!.conf { best = (e.confidence, 1) } }
            }
        }
        if let b = best { return ARTrackVerdict(kind: .accurate, confidence: b.conf, version: b.version, pressingsChecked: pressings.count) }
        return ARTrackVerdict(kind: .mismatch, confidence: 0, version: 0, pressingsChecked: pressings.count)
    }
}

final class AccurateRipClient: @unchecked Sendable {
    private let http: HTTPClient
    private let base: URL
    private let identity: ClientIdentity

    init(http: HTTPClient = URLSessionClient(), base: URL = URL(string: "https://www.accuraterip.com/accuraterip")!, identity: ClientIdentity = ClientIdentity()) {
        self.http = http; self.base = base; self.identity = identity
    }

    /// The pressings the database knows for this disc, or nil when it has none (404).
    func lookup(_ toc: CDTOC) async throws -> [ARPressing]? {
        guard toc.hasStandardNumbering else { return nil }
        var req = URLRequest(url: toc.accurateRipURL(base: base))
        req.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        let (d, status) = try await http.send(req)
        if status == 404 { return nil }
        guard status == 200 else { throw NetworkError.status(status, "AccurateRip") }
        let ids = toc.accurateRipIDs
        // keep only pressings that really are this disc
        return AccurateRip.parse(d).filter { $0.id1 == ids.id1 && $0.id2 == ids.id2 && $0.trackCount == toc.audioTracks.count }
    }
}

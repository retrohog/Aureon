import Foundation
import AVFoundation

// Secure ripping.
//
// A CD player is allowed to guess when the laser cannot read a sector (error concealment); a ripper must not. Every chunk of sectors is therefore read
// until the same data has come back clean (no C2 error pointers, when the drive has them) the required number of times. When a chunk will not settle, it
// is read again sector by sector and each sector is decided by a vote among all its reads; sectors that still have no majority are reported, never hidden.
// The result is then checked against AccurateRip: a match means other rippers, with other drives, got exactly the same bits.

enum RipMode: String, Codable, CaseIterable, Identifiable {
    case burst, secure, paranoid
    var id: String { rawValue }
    var title: String { switch self { case .burst: "Fast"; case .secure: "Secure"; case .paranoid: "Paranoid" } }
    var blurb: String {
        switch self {
        case .burst: "One pass. Quick, and fine for a clean disc; checked afterwards by AccurateRip."
        case .secure: "Every chunk is read until two clean reads agree."
        case .paranoid: "Every chunk is read until three clean reads agree. Slow; for damaged discs."
        }
    }
    var requiredMatches: Int { switch self { case .burst: 1; case .secure: 2; case .paranoid: 3 } }
}

struct RipOptions: Codable, Equatable {
    var mode = RipMode.secure
    var useC2 = true
    /// Tries per chunk before it is split into single sectors.
    var maxReadsPerChunk = 12
    var maxReadsPerSector = 24
    var chunkSectors = 13
    /// The drive's read offset in samples: sample `i` of the true audio is the drive's sample `i + readOffset`.
    var readOffset = 0
}

struct SectorIssue: Equatable {
    enum Kind: String { case c2, disagreed, readError, unresolved }
    var lba: Int
    var kind: Kind
}

struct TrackRipReport: Equatable {
    var number: Int
    var sectors = 0
    var reads = 0                                 // sector reads performed (the minimum is `sectors × required matches`)
    var rereads = 0                               // reads beyond what a clean disc needs
    var c2Sectors = 0
    var issues: [SectorIssue] = []
    var unresolvedSectors: [Int] { issues.filter { $0.kind == .unresolved || $0.kind == .readError }.map(\.lba) }
    var firstReadCRC: UInt32 = 0                  // of the audio as first read
    var finalCRC: UInt32 = 0                      // of the audio as delivered
    var peak: Double = 0
    var checksums = ARChecksums(v1: 0, v2: 0)
    var accurateRip: ARTrackVerdict?
    /// Everything was read clean and agreed, with nothing guessed.
    var perfect: Bool { unresolvedSectors.isEmpty && firstReadCRC == finalCRC }
}

struct RippedTrack {
    var number: Int
    var samples: [UInt32]                         // stereo frames, left in the low half
    var report: TrackRipReport
    var duration: Double { Double(samples.count) / 44_100 }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in var c = UInt32(i); for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; return c }
    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
    static func of(_ data: [UInt8]) -> UInt32 { data.withUnsafeBytes { update(0, $0) } }
}

final class DiscRipper {
    let source: CDSource
    var options: RipOptions

    init(source: CDSource, options: RipOptions = RipOptions()) { self.source = source; self.options = options }

    private var useC2: Bool { options.useC2 && source.supportsC2 }

    /// One read attempt of `count` sectors: the data, and whether any sector carried error pointers.
    private func attempt(_ lba: Int, _ count: Int, _ report: inout TrackRipReport) -> (block: SectorBlock, clean: Bool)? {
        report.reads += count
        guard let b = try? source.read(lba: lba, count: count, c2: useC2) else { return nil }
        return (b, !(0..<count).contains { b.c2Bad(sector: $0) })
    }

    /// The decided audio for `count` sectors starting at `lba`, with issues noted in the report.
    private func readChunk(_ lba: Int, _ count: Int, _ report: inout TrackRipReport, firstRead: inout [UInt8]) -> [UInt8] {
        let need = options.mode.requiredMatches
        var attempts: [(block: SectorBlock, clean: Bool)] = []
        if let first = attempt(lba, count, &report) {
            firstRead += first.block.audio
            if need == 1 {
                for i in 0..<count where first.block.c2Bad(sector: i) { report.c2Sectors += 1; report.issues.append(SectorIssue(lba: lba + i, kind: .c2)) }
                return first.block.audio
            }
            attempts.append(first)
        } else { firstRead += [UInt8](repeating: 0, count: count * CDTOC.sectorBytes) }
        // read until `need` clean attempts are identical
        func agreed() -> [UInt8]? {
            var counts: [[UInt8]: Int] = [:]
            for a in attempts where a.clean { counts[a.block.audio, default: 0] += 1 }
            return counts.first { $0.value >= need }?.key
        }
        var tries = attempts.count
        while agreed() == nil && tries < options.maxReadsPerChunk {
            if tries >= 1 { source.flushCache() }                       // the next read must come from the disc, not the drive's cache
            if let a = attempt(lba, count, &report) { attempts.append(a) }
            tries += 1
        }
        report.rereads += max(0, tries - need) * count
        if let ok = agreed() {
            for a in attempts where !a.clean { for i in 0..<count where a.block.c2Bad(sector: i) { report.c2Sectors += 1; report.issues.append(SectorIssue(lba: lba + i, kind: .c2)) } }
            return ok
        }
        // the chunk will not settle: decide sector by sector
        var out: [UInt8] = []
        for i in 0..<count { out += readSector(lba + i, &report) }
        return out
    }

    private func readSector(_ lba: Int, _ report: inout TrackRipReport) -> [UInt8] {
        let need = max(2, options.mode.requiredMatches)
        var seen: [(data: [UInt8], clean: Bool)] = []
        var failures = 0
        for n in 0..<options.maxReadsPerSector {
            if n > 0 { source.flushCache() }
            if let a = attempt(lba, 1, &report) { seen.append((Array(a.block.audio), a.clean)) } else { failures += 1 }
            report.rereads += 1
            var counts: [[UInt8]: Int] = [:]
            for s in seen where s.clean { counts[s.data, default: 0] += 1 }
            if let best = counts.first(where: { $0.value >= need }) { return best.key }
        }
        // no clean majority: take the most frequent pattern of all reads, and say so
        var counts: [[UInt8]: Int] = [:]
        for s in seen { counts[s.data, default: 0] += 1 }
        if let best = counts.max(by: { $0.value < $1.value }), best.value >= 2 {
            report.issues.append(SectorIssue(lba: lba, kind: .disagreed)); return best.key
        }
        report.issues.append(SectorIssue(lba: lba, kind: seen.isEmpty ? .readError : .unresolved))
        return seen.first?.data ?? [UInt8](repeating: 0, count: CDTOC.sectorBytes)
    }

    func ripTrack(_ track: CDTrack, progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> RippedTrack {
        let toc = source.toc
        let nSectors = toc.sectorCount(of: track)
        guard track.isAudio, nSectors > 0 else { throw CDReadError.unsupported("track \(track.number) is not an audio track") }
        let spt = CDTOC.sectorSamples
        let startSample = track.startLBA * spt, total = nSectors * spt
        let wantFrom = startSample + options.readOffset                        // first drive sample that is the track's first sample
        func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
        let firstSector = floorDiv(wantFrom, spt)
        let lastSector = (wantFrom + total + spt - 1) / spt                    // exclusive
        var report = TrackRipReport(number: track.number, sectors: nSectors)
        var bytes = [UInt8](); bytes.reserveCapacity((lastSector - firstSector) * CDTOC.sectorBytes)
        var firstRead = [UInt8](); firstRead.reserveCapacity(bytes.capacity)
        var lba = firstSector
        while lba < lastSector {
            if cancelled() { throw CancellationError() }
            let n = min(options.chunkSectors, lastSector - lba)
            // sectors outside the disc's program area read as silence
            let lo = max(lba, 0), hi = min(lba + n, toc.leadoutLBA)
            if lo >= hi { bytes += [UInt8](repeating: 0, count: n * CDTOC.sectorBytes); firstRead += [UInt8](repeating: 0, count: n * CDTOC.sectorBytes) }
            else {
                if lo > lba { bytes += [UInt8](repeating: 0, count: (lo - lba) * CDTOC.sectorBytes); firstRead += [UInt8](repeating: 0, count: (lo - lba) * CDTOC.sectorBytes) }
                bytes += readChunk(lo, hi - lo, &report, firstRead: &firstRead)
                if hi < lba + n { bytes += [UInt8](repeating: 0, count: (lba + n - hi) * CDTOC.sectorBytes); firstRead += [UInt8](repeating: 0, count: (lba + n - hi) * CDTOC.sectorBytes) }
            }
            lba += n
            progress(Double(lba - firstSector) / Double(lastSector - firstSector))
        }
        // cut out the track's samples (the offset decides where they start inside what was read)
        let skip = wantFrom - firstSector * spt
        var samples = [UInt32](repeating: 0, count: total)
        bytes.withUnsafeBytes { raw in
            for i in 0..<total { samples[i] = raw.loadUnaligned(fromByteOffset: (skip + i) * 4, as: UInt32.self).littleEndian }
        }
        var first = [UInt32](repeating: 0, count: total)
        firstRead.withUnsafeBytes { raw in for i in 0..<total where (skip + i) * 4 + 4 <= raw.count { first[i] = raw.loadUnaligned(fromByteOffset: (skip + i) * 4, as: UInt32.self).littleEndian } }
        report.firstReadCRC = first.withUnsafeBytes { CRC32.update(0, $0) }
        report.finalCRC = samples.withUnsafeBytes { CRC32.update(0, $0) }
        var peak: Int32 = 0
        for s in samples { peak = max(peak, abs(Int32(Int16(truncatingIfNeeded: s)))); peak = max(peak, abs(Int32(Int16(truncatingIfNeeded: s >> 16)))) }
        report.peak = Double(peak) / 32768
        let audio = toc.audioTracks
        report.checksums = ARAccumulator.checksums(of: samples, isFirst: track.number == audio.first?.number, isLast: track.number == audio.last?.number)
        return RippedTrack(number: track.number, samples: samples, report: report)
    }
}

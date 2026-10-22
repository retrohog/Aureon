import Foundation

struct RipTests {
    // two real discs: OK Computer (MusicBrainz release 3c8cbdc8-555f-3987-8f03-6baf9488d1b0) — offsets are LBA + 150
    private let discA = (id: "1zOfzhFgYPD05pEMZa8j5o.dR.g-", leadout: 242_041, offsets: [150, 21632, 50476, 70697, 90709, 113245, 133019, 141971, 159413, 180955, 198196, 217701])
    private let discB = (id: "3xTotO45b24DM2BjEPnoMVN7crI-", leadout: 240_791, offsets: [150, 21482, 50264, 70319, 90180, 112624, 132248, 141049, 158346, 179733, 196865, 216370])

    private func samples(_ n: Int, seed: UInt64) -> [UInt32] {
        var x = seed, out: [UInt32] = []; out.reserveCapacity(n)
        for _ in 0..<n { x = x &* 6364136223846793005 &+ 1442695040888963407; out.append(UInt32(truncatingIfNeeded: x >> 32)) }
        return out
    }

    func discIdentifiersMatchTheDatabases() {
        for d in [discA, discB] {
            let toc = CDTOC(offsets: d.offsets, leadout: d.leadout)
            expect(toc.musicBrainzDiscID == d.id, "MusicBrainz disc ID \(toc.musicBrainzDiscID) vs \(d.id)")
            expect(toc.audioTracks.count == 12 && toc.audioTracks[0].startLBA == 0 && toc.leadoutLBA == d.leadout - 150 && toc.hasStandardNumbering)
        }
        // the AccurateRip database holds files under exactly these names (both were fetched from www.accuraterip.com when this test was written)
        let a = CDTOC(offsets: discA.offsets, leadout: discA.leadout)
        expect(a.accurateRipURL().absoluteString == "https://www.accuraterip.com/accuraterip/f/4/1/dBAR-012-0018b14f-00e28d21-a20c990c.bin", a.accurateRipURL().absoluteString)
        let ids = a.accurateRipIDs
        expect(ids.id1 == 0x0018b14f && ids.id2 == 0x00e28d21 && ids.cddb == 0xa20c990c, "\(String(ids.id1, radix: 16)) \(String(ids.id2, radix: 16)) \(String(ids.cddb, radix: 16))")
        let b = CDTOC(offsets: discB.offsets, leadout: discB.leadout)
        expect(b.accurateRipURL().absoluteString == "https://www.accuraterip.com/accuraterip/7/1/b/dBAR-012-00188b17-00e12c7b-9d0c880c.bin", b.accurateRipURL().absoluteString)
        expect(a.musicBrainzTOCString.hasPrefix("1+12+242041+150+21632"), a.musicBrainzTOCString)
        // lengths
        expect(a.sectorCount(of: a.audioTracks[0]) == 21_482 && a.sectorCount(of: a.audioTracks[11]) == 242_041 - 217_701)
        expect(abs(a.seconds(of: a.audioTracks[0]) - 286.4) < 0.1)
    }

    func enhancedDiscsLoseTheirDataTrack() {
        // 3 audio tracks and a data session: the audio ends 11 400 sectors before the data track
        let toc = CDTOC(tracks: [CDTrack(number: 1, startLBA: 0, isAudio: true), CDTrack(number: 2, startLBA: 20_000, isAudio: true), CDTrack(number: 3, startLBA: 40_000, isAudio: true), CDTrack(number: 4, startLBA: 70_000, isAudio: false)], leadoutLBA: 90_000)
        expect(toc.audioTracks.count == 3 && toc.effectiveLeadoutLBA == 58_600 && toc.endLBA(of: toc.tracks[2]) == 58_600, "\(toc.effectiveLeadoutLBA)")
        let plain = CDTOC(offsets: [150, 20_150, 40_150], leadout: 58_750)
        expect(toc.musicBrainzDiscID == plain.musicBrainzDiscID && toc.accurateRipIDs.id1 == plain.accurateRipIDs.id1, "its identifiers are those of the audio-only disc")
        expect(!CDTOC(tracks: [CDTrack(number: 2, startLBA: 0, isAudio: true)], leadoutLBA: 1000).hasStandardNumbering)
    }

    func rawTOCParses() {
        // READ TOC (format 2) response: header, then session/adr+ctl/tno/point/min/sec/frame/zero/pmin/psec/pframe per descriptor
        func desc(_ ctl: UInt8, _ point: UInt8, _ lba: Int) -> [UInt8] {
            let abs = lba + 150, m = abs / 75 / 60, s = abs / 75 % 60, f = abs % 75
            return [1, 0x10 | ctl, 0, point, 0, 0, 0, 0, UInt8(m), UInt8(s), UInt8(f)]
        }
        var body: [UInt8] = [1, 1]
        body += desc(0, 0xA0, 0) + desc(0, 0xA1, 0)
        body += desc(0, 0xA2, 242_041 - 150)
        for (i, o) in discA.offsets.enumerated() { body += desc(i == 11 ? 0x04 : 0, UInt8(i + 1), o - 150) }
        let raw = Data([UInt8((body.count) >> 8), UInt8(body.count & 255)] + body)
        guard let toc = CDTOC.parse(raw: raw) else { expect(false, "parsed"); return }
        expect(toc.tracks.count == 12 && toc.leadoutLBA == 242_041 - 150 && toc.tracks[3].startLBA == 70_697 - 150, "\(toc.tracks.count) tracks")
        expect(toc.tracks[11].isAudio == false && toc.audioTracks.count == 11, "the data flag is read from the control nibble")
        expect(CDTOC.parse(raw: Data([0, 2])) == nil && CDTOC.parse(raw: Data()) == nil)
    }

    func checksumsMatchAnIndependentImplementation() {
        // expected values computed with a separate (Python) implementation of the reference algorithm
        let d = samples(20_000, seed: 12345)
        let cases: [(Bool, Bool, UInt32, UInt32)] = [(false, false, 0x35ced40f, 0x3bccccd0), (true, false, 0x39f07286, 0x3fcd3f78), (false, true, 0x37d85dcf, 0x3c2fae66), (true, true, 0x3bf9fc46, 0x4030210e)]
        // the generator above differs from the reference's by seeding: the reference uses (x * a + c) >> 32 over 64-bit state, which is what `samples` does
        for (first, last, v1, v2) in cases {
            let c = ARAccumulator.checksums(of: d, isFirst: first, isLast: last)
            expect(c.v1 == v1 && c.v2 == v2, "first \(first) last \(last): \(String(c.v1, radix: 16)) \(String(c.v2, radix: 16))")
        }
        let short = ARAccumulator.checksums(of: samples(5_880, seed: 777), isFirst: true, isLast: true)
        expect(short.v1 == 0x3556a304 && short.v2 == 0x3556a664, "a short track: \(String(short.v1, radix: 16)) \(String(short.v2, radix: 16))")
        // chunked accumulation gives the same answer as one go, whatever the chunk size
        for chunk in [1, 588, 1000, 4097] {
            var a = ARAccumulator(totalSamples: d.count, isFirstTrack: true, isLastTrack: false)
            var i = 0
            while i < d.count { let n = min(chunk, d.count - i); a.add(Array(d[i..<(i + n)])); i += n }
            expect(a.result == ARAccumulator.checksums(of: d, isFirst: true, isLast: false), "chunks of \(chunk)")
        }
    }

    func musicBrainzKnowsTheDisc() {
        let json = #"{"id":"1zOfzhFgYPD05pEMZa8j5o.dR.g-","releases":[{"id":"6a09041b-0f79-3278-88d9-0552dd28d37f","title":"OK Computer","date":"1997-07-01","country":"US","artist-credit":[{"name":"Radiohead","joinphrase":""}],"cover-art-archive":{"front":true},"label-info":[{"label":{"name":"Capitol Records"}}],"release-group":{"genres":[{"name":"rock"}]},"media":[{"position":1,"discs":[{"id":"1zOfzhFgYPD05pEMZa8j5o.dR.g-"}],"tracks":[{"number":"1","title":"Airbag","length":284400,"recording":{"id":"4a7fea2e-545b-4c63-bc9a-9943cc3a29d7","title":"Airbag"},"artist-credit":[{"name":"Radiohead","joinphrase":""}]},{"number":"2","title":"Paranoid Android","length":383493,"recording":{"id":"9f9cf187-d6f9-437f-9d98-d59cdbd52757","title":"Paranoid Android"},"artist-credit":[{"name":"Radiohead","joinphrase":""}]},{"number":"3","title":"Subterranean Homesick Alien","length":267706,"recording":{"id":"bd82738d-163c-4b1a-bfaf-7acffe30e68a","title":"Subterranean Homesick Alien"},"artist-credit":[{"name":"Radiohead","joinphrase":""}]}]}]}]}"#
        let id = "1zOfzhFgYPD05pEMZa8j5o.dR.g-"
        let rs = try! MusicBrainzParser.discReleases(Data(json.utf8), discID: id)
        expect(rs.count == 1 && rs[0].title == "OK Computer" && rs[0].artist == "Radiohead" && rs[0].label == "Capitol Records" && rs[0].genre == "rock" && rs[0].hasFrontCover, "\(rs)")
        expect(rs[0].tracks.count == 3 && rs[0].tracks[1].title == "Paranoid Android" && rs[0].tracks[1].number == 2 && rs[0].tracks[0].recordingID != nil, "tracks")
        let meta = rs[0].metadata(discID: id)
        expect(meta.album == "OK Computer" && meta.albumArtist == "Radiohead" && meta.year == "1997" && meta.tracks[3]?.title == "Subterranean Homesick Alien" && meta.releaseID == rs[0].id, "\(meta.album) \(meta.year)")
        expect((try? MusicBrainzParser.discReleases(Data("{}".utf8), discID: id))?.isEmpty ?? true, "an answer without releases is empty, not an error")

        // the client asks by disc ID with the table of contents, and caches the answer
        let disc = FakeDisc(trackSectors: [300, 400, 500])
        let http = StubHTTP(); http.on("discid/\(disc.toc.musicBrainzDiscID)", json)
        let c = MusicBrainzClient(http: http, cache: MetadataCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("rip-mb-\(UUID().uuidString.prefix(6))")), minInterval: 0)
        let got = try! runAsync { try await c.discReleases(for: disc.toc) }.get()
        expect(got.count == 1 && got[0].title == "OK Computer")
        let url = http.urls().first ?? ""
        expect(url.contains("toc=") && url.contains("fmt=json") && url.contains("recordings"), url)
        _ = try! runAsync { try await c.discReleases(for: disc.toc) }.get()
        expect(http.count == 1, "the second lookup is served from the cache")
        let none = StubHTTP()
        expect((try? runAsync { try await MusicBrainzClient(http: none, cache: MetadataCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("rip-mb-\(UUID().uuidString.prefix(6))")), minInterval: 0).discReleases(for: disc.toc) }.get()) == nil, "404 for an unknown disc surfaces as an error the UI treats as 'no matches'")
    }

    func theDatabaseAnswerParsesAndVerifies() {
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
        func pressing(_ crcs: [(UInt8, UInt32)]) -> [UInt8] {
            [UInt8(crcs.count)] + u32(0x0018b14f) + u32(0x00e28d21) + u32(0xa20c990c) + crcs.flatMap { [$0.0] + u32($0.1) + u32(0x11111111) }
        }
        let data = Data(pressing([(10, 0xAAAA0001), (7, 0xBBBB0002), (0, 0)]) + pressing([(3, 0xAAAA0001), (50, 0xCCCC0003), (2, 0xDDDD0004)]))
        let r = AccurateRip.parse(data)
        expect(r.count == 2 && r[0].trackCount == 3 && r[0].tracks[1].crc == 0xBBBB0002 && r[1].tracks[1].confidence == 50 && r[0].id2 == 0x00e28d21, "two pressings")
        let hit = AccurateRip.verify(track: 1, checksums: ARChecksums(v1: 1, v2: 0xAAAA0001), in: r)
        expect(hit.kind == .accurate && hit.confidence == 10 && hit.version == 2, "the best matching pressing wins: \(hit)")
        expect(AccurateRip.verify(track: 2, checksums: ARChecksums(v1: 0xCCCC0003, v2: 9), in: r).version == 1, "a v1 match is a match")
        expect(AccurateRip.verify(track: 2, checksums: ARChecksums(v1: 5, v2: 6), in: r).kind == .mismatch)
        expect(AccurateRip.verify(track: 3, checksums: ARChecksums(v1: 0, v2: 0), in: r).kind == .mismatch, "an empty entry matches nothing, not even a zero checksum")
        expect(AccurateRip.verify(track: 9, checksums: ARChecksums(v1: 1, v2: 1), in: r).kind == .mismatch)
        expect(AccurateRip.verify(track: 1, checksums: ARChecksums(v1: 1, v2: 1), in: nil).kind == .notInDatabase)
        expect(AccurateRip.parse(Data([5, 1, 2, 3])).isEmpty && AccurateRip.parse(Data()).isEmpty, "truncated and empty answers")
        expect(hit.summary.contains("confidence 10"))
    }
}

/// A pretend disc: three tracks of synthetic audio, served the way a drive would serve them, with the failures a real drive has.
final class FakeDisc: CDSource {
    let name = "Fake drive"
    let toc: CDTOC
    var supportsC2 = true
    let truth: [UInt8]                       // every sector of the program area, as the disc really holds it
    /// The drive's read offset: it returns the true sample j − offset at position j.
    var driveOffset = 0
    /// Sectors (LBA) that come back damaged for their first `n` reads; `flagged` says whether the drive admits it with C2 pointers.
    var damaged: [Int: Int] = [:]
    var flagged = true
    /// Sectors that are damaged differently on every read, for ever.
    var hopeless: Set<Int> = []
    /// Sectors whose read fails outright, for their first `n` attempts.
    var failing: [Int: Int] = [:]
    /// A repeated read is answered from the "cache" until something else is read in between.
    var cache = false
    private(set) var reads = 0, sectorReads = 0, flushes = 0
    private var attemptsPerSector: [Int: Int] = [:]
    private var lastRequest: (lba: Int, count: Int, block: SectorBlock)?
    private var rng = SplitMix(seed: 99)

    init(trackSectors: [Int]) {
        var tracks: [CDTrack] = [], start = 0
        for (i, n) in trackSectors.enumerated() { tracks.append(CDTrack(number: i + 1, startLBA: start, isAudio: true)); start += n }
        toc = CDTOC(tracks: tracks, leadoutLBA: start)
        var rng = SplitMix(seed: 5)
        var bytes = [UInt8](repeating: 0, count: start * CDTOC.sectorBytes)
        // music-like content: a few tones plus noise, 16-bit stereo
        var phase = 0.0
        for s in 0..<(start * CDTOC.sectorSamples) {
            phase += 0.031
            let l = Int16(8_000 * sin(phase) + 3_000 * sin(phase * 3.1) + Double(Int(rng.next() % 600)) - 300), r = Int16(7_000 * sin(phase * 1.01) + Double(Int(rng.next() % 600)) - 300)
            bytes[s * 4] = UInt8(truncatingIfNeeded: l); bytes[s * 4 + 1] = UInt8(truncatingIfNeeded: l >> 8); bytes[s * 4 + 2] = UInt8(truncatingIfNeeded: r); bytes[s * 4 + 3] = UInt8(truncatingIfNeeded: r >> 8)
        }
        truth = bytes
    }

    /// The true samples of a track, for comparison.
    func trueSamples(_ n: Int) -> [UInt32] {
        let t = toc.audioTracks[n - 1], count = toc.sectorCount(of: t) * CDTOC.sectorSamples, base = t.startLBA * CDTOC.sectorSamples * 4
        return (0..<count).map { i in truth.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self).littleEndian } }
    }

    /// The drive's stream at sample position j (what it really delivers, offset included).
    private func driveSample(_ j: Int) -> [UInt8] {
        let t = j - driveOffset
        guard t >= 0, (t + 1) * 4 <= truth.count else { return [0, 0, 0, 0] }
        return Array(truth[(t * 4)..<(t * 4 + 4)])
    }

    func flushCache() { flushes += 1; lastRequest = nil }

    func read(lba: Int, count: Int, c2: Bool) throws -> SectorBlock {
        reads += 1
        guard lba >= 0, lba + count <= toc.leadoutLBA else { throw CDReadError.outOfRange }
        if cache, let l = lastRequest, l.lba == lba, l.count == count { return l.block }
        var audio = [UInt8](repeating: 0, count: count * CDTOC.sectorBytes)
        var flags = [UInt8](repeating: 0, count: count * 294)
        for k in 0..<count {
            let sector = lba + k
            sectorReads += 1
            if let n = failing[sector], n > 0 { failing[sector] = n - 1; throw CDReadError.io(EIO) }
            for i in 0..<CDTOC.sectorSamples { audio.replaceSubrange((k * CDTOC.sectorBytes + i * 4)..<(k * CDTOC.sectorBytes + i * 4 + 4), with: driveSample(sector * CDTOC.sectorSamples + i)) }
            let n = attemptsPerSector[sector, default: 0]; attemptsPerSector[sector] = n + 1
            let bad = hopeless.contains(sector) || n < (damaged[sector] ?? 0)
            if bad {
                for i in stride(from: 100, to: 1500, by: 7) { audio[k * CDTOC.sectorBytes + i] = UInt8(truncatingIfNeeded: rng.next()) }
                if flagged { for i in 0..<20 { flags[k * 294 + 20 + i] = 0xFF } }
            }
        }
        let b = SectorBlock(audio: audio, c2: c2 && supportsC2 ? flags : nil, count: count)
        if cache { lastRequest = (lba, count, b) }
        return b
    }
}

extension RipTests {
    private func rip(_ disc: FakeDisc, _ n: Int, mode: RipMode = .secure, offset: Int = 0, chunk: Int = 13) -> RippedTrack {
        var o = RipOptions(); o.mode = mode; o.readOffset = offset; o.chunkSectors = chunk
        return try! DiscRipper(source: disc, options: o).ripTrack(disc.toc.audioTracks[n - 1])
    }

    func aCleanDiscRipsExactly() {
        let disc = FakeDisc(trackSectors: [120, 300, 200])
        for n in 1...3 {
            let r = rip(disc, n)
            expect(r.samples == disc.trueSamples(n), "track \(n) is bit-identical to what is on the disc")
            expect(r.report.perfect && r.report.rereads == 0 && r.report.c2Sectors == 0 && r.report.sectors == disc.toc.sectorCount(of: disc.toc.audioTracks[n - 1]), "\(r.report)")
            let ar = ARAccumulator.checksums(of: disc.trueSamples(n), isFirst: n == 1, isLast: n == 3)
            expect(r.report.checksums == ar, "AccurateRip checksums agree with the reference")
        }
        // secure mode reads every sector twice, burst once, paranoid three times
        let a = FakeDisc(trackSectors: [100, 100]), b = FakeDisc(trackSectors: [100, 100]), c = FakeDisc(trackSectors: [100, 100])
        _ = rip(a, 1, mode: .burst); _ = rip(b, 1, mode: .secure); _ = rip(c, 1, mode: .paranoid)
        expect(a.sectorReads == 100 && b.sectorReads == 200 && c.sectorReads == 300, "sectors read: \(a.sectorReads) / \(b.sectorReads) / \(c.sectorReads)")
        // chunk size does not change the result
        for ch in [1, 7, 26, 500] { expect(rip(FakeDisc(trackSectors: [100, 100]), 2, chunk: ch).samples == a.trueSamples(2), "chunks of \(ch)") }
    }

    func theDrivesOffsetIsCorrected() {
        for offset in [667, -30, 6, 1500] {
            let disc = FakeDisc(trackSectors: [150, 300, 200]); disc.driveOffset = offset
            let wrong = rip(disc, 2, offset: 0)
            expect(wrong.samples != disc.trueSamples(2), "without the correction track 2 is shifted by \(offset) samples")
            let right = rip(disc, 2, offset: offset)
            expect(right.samples == disc.trueSamples(2), "with +\(offset) it is exact")
            // the first track starts at the very beginning of the disc: shifting back needs data before it, which is silence
            let first = rip(disc, 1, offset: offset), truth1 = disc.trueSamples(1)
            // (with a negative offset the first |offset| samples would have to come from before the disc starts: silence)
            let lost = max(0, -offset)
            expect(Array(first.samples.dropFirst(lost)) == Array(truth1.dropFirst(lost)) && first.samples.prefix(lost).allSatisfy { $0 == 0 }, "track 1 with offset \(offset)")
            // the last track needs `offset` samples that lie beyond the lead-out: they are silence
            let last = rip(disc, 3, offset: offset), truth3 = disc.trueSamples(3)
            if offset > 0 { expect(Array(last.samples.prefix(truth3.count - offset)) == Array(truth3.prefix(truth3.count - offset)) && last.samples.suffix(offset).allSatisfy { $0 == 0 }, "track 3: the unreadable tail is silent") }
            else { expect(last.samples == truth3 || Array(last.samples.suffix(truth3.count + offset)) == Array(truth3.suffix(truth3.count + offset)), "track 3 with a negative offset") }
        }
    }

    func errorsThatTheDriveAdmitsAreRetried() {
        let disc = FakeDisc(trackSectors: [200, 200]); disc.damaged = [40: 2, 41: 2, 90: 1]
        let r = rip(disc, 1)
        expect(r.samples == disc.trueSamples(1), "the damaged sectors were re-read until they were right")
        expect(r.report.c2Sectors > 0 && r.report.rereads > 0 && r.report.unresolvedSectors.isEmpty, "\(r.report)")
        expect(!r.report.perfect, "the first read was not clean, and the log says so (\(String(r.report.firstReadCRC, radix: 16)) vs \(String(r.report.finalCRC, radix: 16)))")
        expect(r.report.issues.contains { $0.lba == 40 && $0.kind == .c2 })
        // the same disc in fast mode keeps the damage: that is what the secure mode is for
        let d2 = FakeDisc(trackSectors: [200, 200]); d2.damaged = [40: 2]
        expect(rip(d2, 1, mode: .burst).samples != d2.trueSamples(1), "a single pass takes the bad sector as it comes")
    }

    func errorsTheDriveHidesAreCaughtByRereading() {
        // no C2 pointers at all, a drive cache that repeats its last answer, and a sector that is wrong on the first read only
        let disc = FakeDisc(trackSectors: [200, 200]); disc.supportsC2 = false; disc.cache = true; disc.damaged = [70: 1, 71: 1]
        let r = rip(disc, 1)
        expect(r.samples == disc.trueSamples(1), "two reads that disagree are never accepted, and the cache is flushed before re-reading")
        expect(disc.flushes > 0 && !r.report.perfect)
        // without flushing, a caching drive would have agreed with itself: prove the cache really would fool a naive ripper
        let naive = FakeDisc(trackSectors: [200, 200]); naive.supportsC2 = false; naive.cache = true; naive.damaged = [70: 1]
        let a = try! naive.read(lba: 65, count: 13, c2: false), b = try! naive.read(lba: 65, count: 13, c2: false)
        expect(a.audio == b.audio && a.audio != Array(naive.truth[(65 * 2352)..<(78 * 2352)]), "the simulated cache repeats a wrong answer")
    }

    func sectorsThatNeverSettleAreReportedNotHidden() {
        let disc = FakeDisc(trackSectors: [200, 200]); disc.hopeless = [100]
        let r = rip(disc, 1)
        expect(r.report.unresolvedSectors == [100] && !r.report.perfect, "\(r.report.issues)")
        let truth = disc.trueSamples(1)
        let bad = 100 * CDTOC.sectorSamples
        expect(Array(r.samples[0..<bad]) == Array(truth[0..<bad]) && Array(r.samples[(bad + CDTOC.sectorSamples)...]) == Array(truth[(bad + CDTOC.sectorSamples)...]), "every other sector is exact")
        expect(r.report.reads > 200 + 24, "it tried hard: \(r.report.reads) sector reads")
    }

    func readErrorsAreSurvivedOrReported() {
        let disc = FakeDisc(trackSectors: [200, 200]); disc.failing = [50: 3, 51: 1]
        let r = rip(disc, 1)
        expect(r.samples == disc.trueSamples(1) && r.report.unresolvedSectors.isEmpty, "transient read failures are retried: \(r.report.issues)")
        let hard = FakeDisc(trackSectors: [200, 200]); hard.failing = [60: 10_000]
        let h = rip(hard, 1)
        expect(h.report.unresolvedSectors == [60] && h.report.issues.contains { $0.lba == 60 && $0.kind == .readError }, "a sector that can never be read is flagged: \(h.report.issues)")
    }

    func cancellingStopsTheRip() {
        let disc = FakeDisc(trackSectors: [300, 100])
        var calls = 0
        let r = DiscRipper(source: disc)
        do { _ = try r.ripTrack(disc.toc.audioTracks[0], cancelled: { calls += 1; return calls > 5 }); expect(false, "should have stopped") } catch { expect(error is CancellationError) }
        expect(disc.sectorReads < 300 * 2, "and it stopped early: \(disc.sectorReads)")
    }

    func filesAreBitExactAndTagged() {
        let disc = FakeDisc(trackSectors: [150, 400, 250])
        let dir = tempDir("ripout")
        var meta = RipMetadata(); meta.album = "Test Album"; meta.albumArtist = "Test Artist"; meta.year = "2001"; meta.genre = "Rock"; meta.releaseID = "rel-1"; meta.discID = disc.toc.musicBrainzDiscID
        meta.tracks = [1: .init(title: "One", artist: "Test Artist", recordingID: "rec-1"), 2: .init(title: "Two: the Sequel?", artist: "Guest & Co"), 3: .init(title: "Three", artist: "Test Artist")]
        meta.cover = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 7, count: 200))
        let r = rip(disc, 2)
        for fmt in RipFormat.allCases {
            let url = dir.appendingPathComponent(RipOutput.fileName(track: 2, meta: meta, format: fmt))
            expect(url.lastPathComponent == "02 - Two_ the Sequel_." + fmt.ext, url.lastPathComponent)
            try! RipOutput.write(r, to: url, format: fmt, meta: meta, trackCount: 3, comment: "Ripped by Aureon")
            let decoded = readAll(try! LosslessFile(path: url.path))
            var back = [UInt32](repeating: 0, count: decoded.count / 2)
            for i in 0..<back.count { back[i] = UInt32(UInt16(truncatingIfNeeded: decoded[i * 2] >> 16)) | UInt32(UInt16(truncatingIfNeeded: decoded[i * 2 + 1] >> 16)) << 16 }
            expect(back == r.samples, "\(fmt.title): the decoded file is identical to the rip (\(back.count) vs \(r.samples.count) frames)")
            expect(ARAccumulator.checksums(of: back, isFirst: false, isLast: false) == ARAccumulator.checksums(of: r.samples, isFirst: false, isLast: false), "\(fmt.title): AccurateRip checksums survive the file")
            if fmt != .wav {
                let tags = TagInterpreter.interpret(TagReader.read(path: url.path))
                expect(tags.title == "Two: the Sequel?" && tags.album == "Test Album" && tags.trackNumber == 2 && tags.credits(.artist).first?.name == "Guest & Co" && tags.credits(.albumArtist).first?.name == "Test Artist", "\(fmt.title): tags \(tags.title ?? "-") \(tags.album ?? "-") \(String(describing: tags.trackNumber))")
                expect(tags.year == 2001 && tags.genres == ["Rock"], "\(fmt.title): year and genre")
            }
        }
        let flac = dir.appendingPathComponent(RipOutput.fileName(track: 2, meta: meta, format: .flac))
        expect(FileManager.default.contents(atPath: flac.path)!.range(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 7, 7, 7])) != nil, "the cover is inside the FLAC file")
    }

    func cueAndLogDescribeTheRip() {
        let disc = FakeDisc(trackSectors: [150, 400])
        var meta = RipMetadata(); meta.album = "Album"; meta.albumArtist = "Artist"; meta.year = "1999"
        meta.tracks = [1: .init(title: "First", artist: "Artist"), 2: .init(title: "Second", artist: "Artist")]
        let cue = RipOutput.cueSheet(toc: disc.toc, meta: meta, files: [1: "01 - First.flac", 2: "02 - Second.flac"])
        expect(cue.contains("TRACK 02 AUDIO") && cue.contains("FILE \"02 - Second.flac\" WAVE") && cue.contains("REM MUSICBRAINZ_DISCID \(disc.toc.musicBrainzDiscID)") && cue.contains("TITLE \"First\""), cue)
        var r1 = rip(disc, 1).report; r1.accurateRip = ARTrackVerdict(kind: .accurate, confidence: 12, version: 2, pressingsChecked: 3)
        var r2 = rip(disc, 2).report; r2.issues = [SectorIssue(lba: 200, kind: .unresolved)]
        let log = RipOutput.log(toc: disc.toc, drive: "Fake drive", options: RipOptions(), meta: meta, reports: [r1, r2], date: Date(timeIntervalSince1970: 0))
        expect(log.contains("Accurately ripped (v2, confidence 12)") && log.contains("UNRESOLVED sectors   : 200") && log.contains("1 of 2 tracks accurately ripped") && log.contains("Secure") && log.contains(disc.toc.musicBrainzDiscID), log)
        expect(RipOutput.msf(75 * 61 + 30) == "1:01.40", RipOutput.msf(75 * 61 + 30))
    }

    func aDiscImageRipsLikeADisc() {
        let disc = FakeDisc(trackSectors: [120, 220, 180])
        let dir = tempDir("image")
        try! Data(disc.truth).write(to: dir.appendingPathComponent("disc.bin"))
        func idx(_ lba: Int) -> String { String(format: "%02d:%02d:%02d", lba / 75 / 60, lba / 75 % 60, lba % 75) }
        let cue = "REM test\nFILE \"disc.bin\" BINARY\n" + disc.toc.audioTracks.map { "  TRACK \(String(format: "%02d", $0.number)) AUDIO\n    INDEX 01 \(idx($0.startLBA))\n" }.joined()
        try! cue.write(to: dir.appendingPathComponent("disc.cue"), atomically: true, encoding: .utf8)
        let img = try! DiscImageSource.image(cue: dir.appendingPathComponent("disc.cue"))
        expect(img.toc == disc.toc && img.name == "disc", "the table of contents comes from the CUE sheet and the file size")
        for n in 1...3 { expect(try! DiscRipper(source: img).ripTrack(img.toc.audioTracks[n - 1]).samples == disc.trueSamples(n), "track \(n) from the image") }
        expect((try? img.read(lba: 5_000, count: 1, c2: false)) == nil, "reading past the end fails")
        expect((try? DiscImageSource.image(cue: dir.appendingPathComponent("nothing.cue"))) == nil)
    }

    func tagWritersKeepTheAudioAndTheRestOfTheTags() {
        let dir = tempDir("tagw")
        let wav = sineWAV(dir.appendingPathComponent("t.wav"), rate: 44_100, bits: 16, freq: 440, amp: 0.4, seconds: 1)
        let flac = dir.appendingPathComponent("t.flac")
        expect(encode(wav, to: flac, alac: false))
        let before = readAll(try! LosslessFile(path: flac.path))
        try! FLACTagWriter.write(path: flac.path, comments: [("TITLE", "A"), ("ARTIST", "B")])
        try! FLACTagWriter.write(path: flac.path, comments: [("TITLE", "Changed"), ("ARTIST", "B"), ("ARTIST", "C"), ("WORK", "W")], picture: .init(data: Data([1, 2, 3]), mime: "image/png"))
        try! FLACTagWriter.write(path: flac.path, comments: [("TITLE", "Final")], picture: .init(data: Data([9, 9]), mime: "image/png"))
        let t = TagInterpreter.interpret(TagReader.read(path: flac.path))
        expect(t.title == "Final" && t.credits(.artist).isEmpty, "the comments are replaced, not accumulated")
        expect(readAll(try! LosslessFile(path: flac.path)) == before, "the audio is bit-identical after three rewrites")
        expect((try? FLACTagWriter.write(path: wav.path, comments: [])) == nil, "a WAV is refused")
        expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".t.flac.tmp").path), "no temporary file is left behind")
        // MP4: two writes, the second replaces the first
        let m4a = dir.appendingPathComponent("t.m4a")
        expect(encode(wav, to: m4a, alac: true))
        let audio = readAll(try! LosslessFile(path: m4a.path))
        var tags = MP4TagWriter.Tags(); tags.title = "Song"; tags.artist = "Artist"; tags.album = "Album"; tags.track = 3; tags.trackTotal = 9; tags.freeform = [("MusicBrainz Track Id", "abc")]
        try! MP4TagWriter.write(path: m4a.path, tags: tags)
        tags.title = "Song 2"; tags.cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        try! MP4TagWriter.write(path: m4a.path, tags: tags)
        let m = TagInterpreter.interpret(TagReader.read(path: m4a.path))
        expect(m.title == "Song 2" && m.album == "Album" && m.trackNumber == 3 && m.trackTotal == 9 && m.mbRecordingID == "abc", "\(m.title ?? "-") \(m.album ?? "-")")
        expect(readAll(try! LosslessFile(path: m4a.path)) == audio, "ALAC audio untouched, with the chunk offsets fixed")
        expect(FileManager.default.contents(atPath: m4a.path)!.range(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])) != nil)
    }
}

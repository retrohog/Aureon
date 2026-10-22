import Foundation
import AppKit
import CoreGraphics

// Startup and scrolling performance: the artwork cache, delta updates, the paged album list and the analyser's frame hand-off.
// `Aureon selftest perf.report` also prints timings (set AUREON_PERF_ALBUMS for the library size, default 800).

/// Lock-protected collection of what the watcher reports.
final class BatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [LibraryChangeBatch] = []
    private var caught = false
    func add(_ b: LibraryChangeBatch) { lock.lock(); all.append(b); lock.unlock() }
    func markCaughtUp() { lock.lock(); caught = true; lock.unlock() }
    var batches: [LibraryChangeBatch] { lock.lock(); defer { lock.unlock() }; return all }
    var paths: Set<String> { batches.reduce(into: Set<String>()) { $0.formUnion($1.paths); $0.formUnion($1.rescan) } }
    var caughtUp: Bool { lock.lock(); defer { lock.unlock() }; return caught }
    var lastEventID: UInt64 { batches.map(\.eventID).max() ?? 0 }
}

/// Runs the main run loop (where the interface's asynchronous results arrive) until `cond` holds or the time is up.
@discardableResult
func spinMain(timeout: TimeInterval = 10, until cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    return cond()
}

enum PerfData {
    /// Albums with distinct titles (so every sort order is total), several artists, years, genres and resolutions; every 23rd is DSD.
    static func item(album a: Int, track n: Int, as other: Int? = nil) -> (facts: FileFacts, tags: TrackMetadata) {
        let k = other ?? a
        var m = TrackMetadata()
        m.title = "Song \(n)"; m.album = "Album \(String(format: "%03d", k))" + (k % 7 == 0 ? " Étude" : ""); m.year = 1950 + (k * 7) % 70; m.trackNumber = n; m.discNumber = 1
        let artist = "Artist \(k * 5 % 37)"
        m.credits = [Credit(role: .artist, name: artist), Credit(role: .albumArtist, name: artist)]
        m.genres = [["Jazz", "Classical", "Rock", "Pop", "Electronic", "Folk"][k % 6]]
        let dsd = k % 23 == 0, hires = k % 5 == 0
        let facts = FileFacts(path: "/perf/a\(String(format: "%04d", a))/\(n).flac", duration: 200, sampleRate: dsd ? 2_822_400 : (hires ? 96_000 : 44_100),
                              bitDepth: dsd ? 1 : (hires ? 24 : 16), channels: 2, codec: "FLAC", mtime: Double(1000 + a * 3 + n), size: Int64(5000 + n))
        return (facts, m)
    }

    static func items(albums: Int) -> [(facts: FileFacts, tags: TrackMetadata)] {
        (0..<albums).flatMap { a in (1...(2 + a % 3)).map { item(album: a, track: $0) } }
    }

    /// A tagged cover (procedural, no copyrighted art).
    static func cover(_ i: Int, size: Int = 1400) -> Data {
        MainActor.assumeIsolated {
            let h = Double(i % 16) / 16
            return DemoData.coverPNG(NSColor(hue: h, saturation: 0.75, brightness: 0.3, alpha: 1), NSColor(hue: (h + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.85, alpha: 1),
                                     accent: NSColor(hue: (h + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 1, alpha: 1), size: size)
        }
    }

    /// A short FLAC to copy and tag (needs afconvert).
    static func baseFLAC(in dir: URL) -> URL? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("base.wav"), flac = dir.appendingPathComponent("base.flac")
        sineWAV(wav, rate: 44_100, bits: 16, freq: 440, amp: 0.3, seconds: 0.3)
        guard encode(wav, to: flac, alac: false) else { return nil }
        try? FileManager.default.removeItem(at: wav)
        return flac
    }

    @discardableResult
    static func track(from base: URL, at url: URL, album: Int, number n: Int, title: String? = nil, cover: Data? = nil) -> URL {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.copyItem(at: base, to: url)
        try! FLACTagWriter.write(path: url.path, comments: [("TITLE", title ?? "Track \(n)"), ("ARTIST", "Artist \(album / 2)"), ("ALBUMARTIST", "Artist \(album / 2)"), ("ALBUM", "Album \(album)"),
                                                            ("TRACKNUMBER", "\(n)"), ("DATE", "\(1960 + album % 60)"), ("GENRE", ["Jazz", "Classical", "Rock", "Pop"][album % 4])],
                                 picture: cover.map { .init(data: $0, mime: "image/png") })
        return url
    }

    /// `albums` folders of `tracks` files each under `root`; the first track of every album carries a cover.
    static func library(albums: Int, tracks: Int, root: URL, base: URL, covers: Int = 16) {
        let pics = (0..<covers).map { cover($0, size: 1000) }
        for a in 0..<albums {
            let dir = root.appendingPathComponent(String(format: "Artist %04d/Album %04d", a / 2, a), isDirectory: true)
            for n in 1...tracks { track(from: base, at: dir.appendingPathComponent(String(format: "%02d Track.flac", n)), album: a, number: n, cover: n == 1 ? pics[a % covers] : nil) }
        }
    }
}

struct PerformanceTests {
    // MARK: stored album figures

    func storedFiguresStayInStepWithTheTracks() {
        let lib = try! LibraryStore()
        lib.upsert(PerfData.items(albums: 60))
        func check(_ why: String) {
            let all = lib.releases(limit: 10_000)
            expect(!all.isEmpty && lib.releasesWithoutFigures() == 0, "\(why): every album has figures (\(lib.releasesWithoutFigures()) without)")
            for r in all {
                let s = lib.storedFigures(releaseID: r.id), c = lib.computedFigures(releaseID: r.id)
                expect(s != nil && s == c, "\(why): \(r.title) stored \(String(describing: s)) but its tracks say \(String(describing: c))")
            }
        }
        check("after import")
        let before = lib.releases(limit: 10_000)
        expect(before.contains { $0.isDSD } && before.contains { $0.isHiRes && !$0.isDSD } && before.contains { !$0.isHiRes }, "the data covers every resolution class")
        expect(before.allSatisfy { $0.artStamp != nil && $0.trackCount >= 2 && !$0.artistNames.isEmpty }, "the DTO carries count, artists and the cover stamp")

        // a track moves to another album (re-tagged): both albums are refreshed
        lib.upsert([PerfData.item(album: 4, track: 1, as: 9)])
        check("after a track moved to another album")
        expect(lib.releases(limit: 10_000).first { $0.title.hasPrefix("Album 004") }?.trackCount == before.first { $0.title.hasPrefix("Album 004") }.map { $0.trackCount - 1 })
        // a file is removed: the album it was on loses a track, but stays
        expect(lib.removeTracks(paths: ["/perf/a0010/1.flac"]) == 1)
        check("after a removal")
        // a changed file raises the album's cover stamp
        let stampBefore = lib.releases(limit: 10_000).first { $0.title.hasPrefix("Album 012") }?.artStamp
        var changed = PerfData.item(album: 12, track: 1); changed.facts.mtime += 5000
        lib.upsert([changed])
        let stampAfter = lib.releases(limit: 10_000).first { $0.title.hasPrefix("Album 012") }?.artStamp
        expect(stampBefore != nil && stampAfter != nil && stampAfter! > stampBefore!, "re-tagging a file changes the album's stamp (\(String(describing: stampBefore)) → \(String(describing: stampAfter)))")
        // "A feat. B" folds into A: the albums' artist lines change
        var f1 = PerfData.item(album: 200, track: 1), f2 = PerfData.item(album: 201, track: 1)
        f1.tags.album = "Duet"; f2.tags.album = "Duet"
        f1.tags.credits = [Credit(role: .artist, name: "Solo A feat. Guest B"), Credit(role: .albumArtist, name: "Solo A feat. Guest B")]
        f2.tags.credits = [Credit(role: .artist, name: "Solo A"), Credit(role: .albumArtist, name: "Solo A")]
        lib.upsert([f1, f2])
        lib.normalizeArtists()
        check("after folding featured artists")
        expect(lib.releases(limit: 10_000).filter { $0.title == "Duet" }.count == 1, "the two spellings became one album")

        // a library written before the figures existed still reads correctly, and is filled in once
        let beforeClear = lib.releases(limit: 10_000)
        lib.debugClearFigures()
        expect(lib.releasesWithoutFigures() == beforeClear.count, "all albums are without figures after clearing")
        expect(lib.releases(limit: 10_000) == beforeClear, "reading without stored figures gives the same albums")
        expect(lib.backfillReleaseFigures(batch: 7) == beforeClear.count && lib.releasesWithoutFigures() == 0, "the backfill fills every album (in small batches)")
        check("after the backfill")
        expect(lib.backfillReleaseFigures() == 0, "a second backfill finds nothing to do")
    }

    // MARK: paging

    func pagesFollowTheOrdersAndFilters() {
        let lib = try! LibraryStore()
        lib.upsert(PerfData.items(albums: 230))
        let all = lib.releases(limit: 10_000)
        expect(all.count == 230)
        let keys: [(SortKey, AlbumSortKey)] = [(.title, .title), (.artist, .artist), (.year, .year), (.added, .added), (.count, .count), (.genre, .genre), (.quality, .quality)]
        for (sort, _) in keys {
            for asc in [true, false] {
                for quality in QualityFilter.allCases {
                    var o = ViewOptions(); o.sort = sort; o.ascending = asc; o.quality = quality
                    let want = LibraryOrdering.albums(all, o).map(\.id)
                    let q = AlbumQuery(o, search: "")
                    var got: [String] = [], off = 0
                    while true { let p = lib.releasePage(q, offset: off, limit: AlbumPager.pageSize); if p.isEmpty { break }; got += p.map(\.id); off += AlbumPager.pageSize }
                    expect(got == want, "\(sort) \(asc ? "up" : "down") \(quality): pages differ from the in-memory order (\(got.count) vs \(want.count) albums)")
                    expect(lib.releaseCount(q) == want.count, "\(sort) \(quality): count \(lib.releaseCount(q)) vs \(want.count)")
                }
            }
        }
        // the filter box is folded the same way as before (case and accents ignored)
        let q = AlbumQuery(search: "ETUDE")
        expect(lib.releaseCount(q) == lib.releases(search: "etude", limit: 10_000).count && lib.releaseCount(q) > 0, "search finds the accented titles: \(lib.releaseCount(q))")
        expect(lib.releasePage(AlbumQuery(), offset: 10_000, limit: 48).isEmpty, "a page past the end is empty")
        expect(lib.releasePage(AlbumQuery(), offset: 0, limit: 5).count == 5)
        // "recently added" and "hi-res" rails are a page each, not a scan of the library
        let recent = lib.releasePage(AlbumQuery(sort: .added, ascending: false), offset: 0, limit: 16)
        expect(recent.map(\.id) == Array(all.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(16)).map(\.id), "recent")
        let hires = lib.releasePage(AlbumQuery(sort: .added, ascending: false, tier: .hiRes), offset: 0, limit: 16)
        expect(hires.allSatisfy { $0.isHiRes && !$0.isDSD } && hires.count == 16, "hi-res rail")
    }

    func pagerHoldsOnlyTheNeighbourhood() {
        let lib = try! LibraryStore()
        lib.upsert(PerfData.items(albums: 400))
        MainActor.assumeIsolated {
            let pager = AlbumPager()
            pager.store = lib
            var o = ViewOptions(); o.sort = .title
            pager.configure(AlbumQuery(o, search: ""))
            expect(spinMain { pager.total == 400 && pager.peek(0) != nil }, "the count and first page arrive")
            expect(pager.residentCount <= AlbumPager.pageSize, "only the first page is held at first: \(pager.residentCount)")
            let all = LibraryOrdering.albums(lib.releases(limit: 10_000), o)
            // scroll through the whole list, a screenful at a time
            var maxHeld = 0
            for i in stride(from: 0, to: 400, by: 20) {
                pager.ensure(i)
                expect(spinMain { pager.peek(i) != nil }, "the page for album \(i) arrives")
                expect(pager.peek(i)?.id == all[i].id, "album \(i) is in the right place")
                maxHeld = max(maxHeld, pager.residentCount)
            }
            expect(maxHeld <= pager.maxPages * AlbumPager.pageSize, "never more than \(pager.maxPages) pages held: \(maxHeld) albums of 400")
            expect(pager.peek(0) == nil, "the first page was let go when the list scrolled away")
            expect(pager.resident.count == pager.residentCount)
            // a new question: old answers must not leak in
            pager.configure(AlbumQuery(sort: .year, ascending: false))
            pager.configure(AlbumQuery(sort: .title, ascending: false))
            let want = LibraryOrdering.albums(lib.releases(limit: 10_000), { var d = ViewOptions(); d.ascending = false; return d }()).map(\.id)
            expect(spinMain { pager.peek(0)?.id == want[0] }, "the newest question wins")
            expect(pager.query == AlbumQuery(sort: .title, ascending: false))
            // the library changes: the page in view is fetched again
            lib.upsert([PerfData.item(album: 500, track: 1), PerfData.item(album: 501, track: 1)])
            pager.reload()
            expect(spinMain { pager.total == 402 }, "reload picks up new albums: \(pager.total)")
            // an empty filter
            pager.configure(AlbumQuery(search: "no such album"))
            expect(spinMain { pager.total == 0 }, "no match")
        }
    }

    // MARK: artwork cache

    func artCacheKeepsTwoSizesAndThePalette() {
        let dir = tempDir("artcache-\(UUID().uuidString.prefix(6))")
        let cache = ArtCache(root: dir)
        let png = PerfData.cover(3, size: 1400)
        let src = ArtCache.Source.album(id: "A1", stamp: 1234.5)
        expect(cache.lookup(src) == .miss, "nothing yet")
        guard let hash = cache.store(src, data: png) else { expect(false, "a cover is stored"); return }
        expect(cache.lookup(src) == .hit(hash) && cache.extractions == 1)
        let thumb = cache.thumbnail(hash), large = cache.large(hash)
        expect(thumb != nil && max(thumb!.width, thumb!.height) == ArtCache.thumbPixels, "the thumbnail is \(ArtCache.thumbPixels) px: \(String(describing: thumb?.width))")
        expect(large != nil && max(large!.width, large!.height) == ArtCache.largePixels, "the large picture is \(ArtCache.largePixels) px: \(String(describing: large?.width))")
        let thumbBytes = (try? Data(contentsOf: dir.appendingPathComponent("v1/img/\(hash).t.jpg")).count) ?? 0
        expect(thumbBytes > 0 && thumbBytes < 80_000, "a thumbnail is a few kilobytes, not a bitmap: \(thumbBytes) bytes")
        // the palette is the one the colour maths gives, kept exactly
        let direct = ArtPalette.extract(from: ImageTools.cgImage(png, maxPixel: ArtCache.largePixels)!)
        expect(cache.palette(hash) == direct, "the stored palette equals the extracted one")
        let loaded = cache.loaded(src)
        expect(loaded?.palette == direct && loaded?.hash == hash, "Now Playing gets picture and palette from the cache")
        // the same picture under another source (the same cover on another album, or the file itself) is stored once
        let other = ArtCache.Source.file(path: "/m/x.flac", mtime: 5, size: 9)
        expect(cache.store(other, data: png) == hash && cache.extractions == 1, "identical pictures share their files")
        expect(cache.lookup(other) == .hit(hash))
        // a changed file or album is a different source
        expect(cache.lookup(.album(id: "A1", stamp: 1235)) == .miss && cache.lookup(.file(path: "/m/x.flac", mtime: 6, size: 9)) == .miss, "editing makes a new entry")
        // no cover: remembered for a while, then asked again
        let none = ArtCache.Source.album(id: "A2", stamp: 1)
        cache.storeNone(none)
        expect(cache.lookup(none) == .empty && cache.lookup(none, now: Date().addingTimeInterval(ArtCache.negativeLifetime - 60)) == .empty, "known to have no cover")
        expect(cache.lookup(none, now: Date().addingTimeInterval(ArtCache.negativeLifetime + 60)) == .miss, "tried again after a while")
        // bytes that are no picture
        let junk = ArtCache.Source.album(id: "A3", stamp: 1)
        expect(cache.store(junk, data: Data([1, 2, 3, 4])) == nil && cache.lookup(junk) == .miss, "garbage is not stored")
        // an entry whose files were trimmed away is a miss, not an error
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("v1/img/\(hash).t.jpg"))
        expect(cache.lookup(src) == .miss, "a half-deleted entry is rebuilt")
        // housekeeping keeps the cache under its budget, dropping the oldest first
        for i in 0..<12 { cache.store(.album(id: "T\(i)", stamp: 1), data: PerfData.cover(i + 20, size: 900)) }
        let total = cache.size()
        expect(total > 0)
        let removed = cache.trim(maxBytes: total / 2)
        expect(removed > 0 && cache.size() <= total / 2, "trimmed from \(total) to \(cache.size()) bytes")
        cache.removeAll()
        expect(cache.size() == 0 && cache.lookup(src) == .miss, "the cache can be emptied")
    }

    func aCoverIsReadFromTheFilesOnlyOnce() {
        guard let base = PerfData.baseFLAC(in: tempDir("onceart-\(UUID().uuidString.prefix(6))")) else { return }
        let root = realPath(base.deletingLastPathComponent()).appendingPathComponent("Music")
        let png = PerfData.cover(5, size: 1200)
        PerfData.track(from: base, at: root.appendingPathComponent("01.flac"), album: 7, number: 1, cover: png)
        PerfData.track(from: base, at: root.appendingPathComponent("02.flac"), album: 7, number: 2)
        let lib = try! LibraryStore()
        expect(lib.importFolder(root).added == 2)
        guard let rel = lib.releases(limit: 5).first else { expect(false, "an album"); return }
        let cache = ArtCache(root: tempDir("onceart-cache-\(UUID().uuidString.prefix(6))"))
        let first = runAsync { let i = await AlbumArt.cover(for: rel, store: lib, fetcher: nil, online: false, cache: cache); return (i.image.map { Double($0.size.width) } ?? 0, i.hd) }
        guard case .success(let a) = first else { expect(false, "cover load failed"); return }
        expect(a.0 > 0 && a.0 <= Double(ArtCache.thumbPixels) && cache.extractions == 1, "extracted once into a thumbnail: \(a.0) px, \(cache.extractions) extraction(s)")
        // the audio files go away: the cover still loads, because the cache has it
        try? FileManager.default.removeItem(at: root)
        let again = runAsync { let i = await AlbumArt.cover(for: rel, store: lib, fetcher: nil, online: false, cache: cache); return (i.image.map { Double($0.size.width) } ?? 0, i.hd) }
        guard case .success(let b) = again else { expect(false, "second load failed"); return }
        expect(b.0 == a.0 && cache.extractions == 1, "the second load never touched the files: \(b.0) px")
        // an album with no cover is remembered as such: no tag reads at every launch
        var bare = rel; bare.id = "no-cover"; bare.artStamp = 99
        let r1 = runAsync { let i = await AlbumArt.cover(for: bare, store: lib, fetcher: nil, online: false, cache: cache); return i.image == nil }
        expect((try? r1.get()) == true && cache.lookup(.album(id: "no-cover", stamp: 99)) == .empty, "no cover is cached too")
    }

    // MARK: delta updates

    func deltaUpdatesTouchOnlyWhatChanged() {
        guard let base = PerfData.baseFLAC(in: tempDir("delta-base-\(UUID().uuidString.prefix(6))")) else { return }
        let top = realPath(tempDir("delta-\(UUID().uuidString.prefix(6))"))
        let root = top.appendingPathComponent("Music")
        for a in 0..<3 { for n in 1...3 { PerfData.track(from: base, at: root.appendingPathComponent("Album \(a)/\(n).flac"), album: a, number: n) } }
        let lib = try! LibraryStore()
        func apply(_ paths: [URL], reconcile: Bool = false) -> ImportReport {
            var b = LibraryChangeBatch(root: root.path); b.paths = Set(paths.map(\.path)); b.reconcileRoot = reconcile
            return LibraryDelta.apply(b, to: lib)
        }
        expect(lib.importFolder(root).added == 9)
        let rev = lib.revision

        var r = apply([root.appendingPathComponent("Album 0/1.flac")])
        expect(r.skipped == 1 && r.added == 0 && r.updated == 0 && lib.revision == rev, "an event for an unchanged file costs a comparison and changes nothing: \(r)")
        r = apply([root.appendingPathComponent("Album 0/.DS_Store"), root.appendingPathComponent("Album 0/.hidden.flac"), root.appendingPathComponent("Album 0/cover.jpg")])
        expect(r.scanned == 0 && lib.revision == rev, "hidden files and non-audio files mean nothing")

        let added = PerfData.track(from: base, at: root.appendingPathComponent("Album 0/4.flac"), album: 0, number: 4)
        r = apply([added])
        expect(r.added == 1 && lib.stats().tracks == 10, "a new file is added: \(r)")

        let edited = root.appendingPathComponent("Album 1/2.flac")
        PerfData.track(from: base, at: edited, album: 1, number: 2, title: "Edited")
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: edited.path)
        r = apply([edited])
        expect(r.updated == 1 && lib.track(path: edited.path)?.title == "Edited", "an edited file is updated: \(r)")

        let gone = root.appendingPathComponent("Album 2/3.flac")
        try? FileManager.default.removeItem(at: gone)
        r = apply([gone])
        expect(r.removed == 1 && lib.track(path: gone.path) == nil && lib.stats().tracks == 9, "a deleted file is removed: \(r)")

        // a folder arrives without events for its files (a move, or a copy FSEvents merged): it is walked once
        let dropped = root.appendingPathComponent("Album 9")
        for n in 1...2 { PerfData.track(from: base, at: dropped.appendingPathComponent("\(n).flac"), album: 9, number: n) }
        r = apply([dropped])
        expect(r.added == 2 && lib.stats().tracks == 11, "a new folder is imported: \(r)")
        // ... and leaves
        try? FileManager.default.removeItem(at: dropped)
        r = apply([dropped])
        expect(r.removed == 2 && lib.stats().tracks == 9, "a removed folder takes its tracks with it: \(r)")
        expect(lib.stats().releases == 3, "its album is pruned: \(lib.stats())")

        // events inside a folder that is walked anyway are not handled twice
        let nested = root.appendingPathComponent("Album 8")
        for n in 1...2 { PerfData.track(from: base, at: nested.appendingPathComponent("\(n).flac"), album: 8, number: n) }
        r = apply([nested, nested.appendingPathComponent("1.flac"), nested.appendingPathComponent("2.flac")])
        expect(r.added == 2 && lib.stats().tracks == 11, "\(r)")

        // history lost: the whole folder is compared, and finds nothing new
        r = apply([], reconcile: true)
        expect(r.skipped == 11 && r.added == 0 && r.removed == 0, "a full comparison: \(r)")

        // an unplugged drive loses nothing
        var offline = LibraryChangeBatch(root: top.appendingPathComponent("Gone").path); offline.reconcileRoot = true
        let before = lib.stats().tracks
        _ = LibraryDelta.apply(offline, to: lib)
        expect(lib.stats().tracks == before, "a folder that is not there is left alone")
        // a library folder that lists as empty (an unmounted volume's mount point) keeps its tracks on a full rescan
        let empty = top.appendingPathComponent("Empty"); try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        lib.upsert([PerfData.item(album: 70, track: 1)])
        var fake = PerfData.item(album: 71, track: 1); fake.facts.path = empty.path + "/ghost.flac"
        lib.upsert([fake])
        let rr = lib.importFolder(empty)
        expect(rr.removed == 0 && lib.track(path: fake.facts.path) != nil, "an empty folder does not wipe what the library knows about it: \(rr)")
    }

    func bulkLookupMatchesSingleLookups() {
        let lib = try! LibraryStore()
        lib.upsert(PerfData.items(albums: 30))
        let all = lib.knownFiles(under: "/perf")
        expect(all.count == lib.stats().tracks, "\(all.count) vs \(lib.stats().tracks)")
        for (p, v) in all.prefix(20) { let k = lib.knownFile(p); expect(k?.mtime == v.mtime && k?.size == v.size, p) }
        expect(lib.knownFiles(under: "/perf/a0003").count == 2, "album 3 has 2 + 3 % 3 tracks: \(lib.knownFiles(under: "/perf/a0003").count)")
        let some = lib.knownFiles(paths: ["/perf/a0001/1.flac", "/perf/nope.flac", "/perf/a0002/1.flac"])
        expect(some.count == 2 && some["/perf/nope.flac"] == nil)
        expect(lib.knownFiles(paths: []).isEmpty)
        let many = lib.knownFiles(paths: Array(all.keys))
        expect(many.count == all.count, "more paths than one query chunk: \(many.count)")
    }

    func watcherReplaysWhatHappenedWhileClosed() {
        guard let base = PerfData.baseFLAC(in: tempDir("watch-base-\(UUID().uuidString.prefix(6))")) else { return }
        let top = realPath(tempDir("watch-\(UUID().uuidString.prefix(6))"))
        let root = top.appendingPathComponent("Music"), stateURL = top.appendingPathComponent("watch.json")
        for n in 1...2 { PerfData.track(from: base, at: root.appendingPathComponent("A/\(n).flac"), album: 1, number: n) }
        let lib = try! LibraryStore()

        // first run: no history, so the folder is compared once and live events follow
        let w1 = LibraryWatcher(stateURL: stateURL, settle: 0.3)
        let box1 = BatchBox()
        w1.onBatch = { box1.add($0) }
        guard case .needsReconcile(let since) = w1.start(root: root.path) else { expect(false, "a folder watched for the first time needs a comparison"); return }
        expect(w1.needsSweep(root: root.path), "no comparison on record yet")
        expect(lib.importFolder(root).added == 2)
        w1.markReconciled(root: root.path, eventID: since)
        expect(!w1.needsSweep(root: root.path) && w1.state(of: root.path)?.eventID == since, "the comparison is on record")
        expect(w1.needsSweep(root: root.path, now: Date().addingTimeInterval(LibraryWatcher.reconcileInterval + 3600)), "an old comparison is repeated")
        expect(w1.watchedRoots == [root.path])

        let live = PerfData.track(from: base, at: root.appendingPathComponent("A/3.flac"), album: 1, number: 3)
        expect(spinMain(timeout: 15) { box1.paths.contains(live.path) }, "a new file is reported as it appears: \(box1.paths)")
        let applied = LibraryDelta.apply(box1.batches.last!, to: lib)
        expect(applied.added == 1 && lib.stats().tracks == 3, "\(applied)")
        w1.commit(root: root.path, eventID: box1.lastEventID)
        let committed = w1.state(of: root.path)?.eventID ?? 0
        expect(committed >= box1.lastEventID && committed > since, "the handled event is remembered: \(committed)")
        w1.stopAll()
        expect(w1.watchedRoots.isEmpty)

        // the app is closed; the folder changes
        let whileClosed = PerfData.track(from: base, at: root.appendingPathComponent("A/4.flac"), album: 1, number: 4)
        let removedFile = root.appendingPathComponent("A/1.flac")
        try? FileManager.default.removeItem(at: removedFile)
        Thread.sleep(forTimeInterval: 1.5)                                      // FSEvents writes its history in batches

        // next launch: the stream resumes from the stored event, nothing is scanned
        let w2 = LibraryWatcher(stateURL: stateURL, settle: 0.3)
        let box2 = BatchBox()
        w2.onBatch = { box2.add($0) }
        w2.onCaughtUp = { _ in box2.markCaughtUp() }
        guard case .replaying(let from) = w2.start(root: root.path) else { expect(false, "the history is trusted on the next launch"); return }
        expect(from == committed, "it resumes from the stored event")
        expect(!w2.needsSweep(root: root.path))
        expect(spinMain(timeout: 20) { box2.paths.contains(whileClosed.path) && box2.paths.contains(removedFile.path) }, "changes made while closed arrive as events: \(box2.paths)")
        expect(spinMain(timeout: 5) { box2.caughtUp }, "the replay announces that it has caught up")
        var merged = LibraryChangeBatch(root: root.path)
        for b in box2.batches { merged.paths.formUnion(b.paths); merged.rescan.formUnion(b.rescan); merged.reconcileRoot = merged.reconcileRoot || b.reconcileRoot }
        let rep = LibraryDelta.apply(merged, to: lib)
        expect(lib.track(path: whileClosed.path) != nil && lib.track(path: removedFile.path) == nil && lib.stats().tracks == 3, "the library is current: \(rep) \(lib.stats())")
        expect(rep.scanned < 10, "only what the events named was looked at: \(rep)")
        w2.commit(root: root.path, eventID: box2.lastEventID)
        w2.stopAll()

        // a different volume (or no record) means the history cannot be trusted
        var states = (try? JSONDecoder().decode([String: LibraryWatcher.State].self, from: Data(contentsOf: stateURL))) ?? [:]
        states[root.path]?.volume = "00000000-0000-0000-0000-000000000000"
        try? JSONEncoder().encode(states).write(to: stateURL)
        let w3 = LibraryWatcher(stateURL: stateURL, settle: 0.3)
        if case .needsReconcile = w3.start(root: root.path) {} else { expect(false, "a replaced volume is compared in full") }
        w3.stopAll()
        let w4 = LibraryWatcher(stateURL: nil, settle: 0.3)
        if case .needsReconcile = w4.start(root: root.path) {} else { expect(false, "no state, no trust") }
        w4.stopAll()
    }

    // MARK: analyser hand-off

    func theInterfaceSeesFramesNotAudioBuffers() {
        expect(UIRate.analyser == 60 && abs(UIRate.analyserInterval - 1.0 / 60) < 1e-12, "the analyser is capped at 60 redraws a second")
        let tap = AnalysisTap(); tap.sampleRate.store(44_100, ordering: .relaxed); tap.enabled.store(true, ordering: .relaxed)
        let eng = AnalysisEngine(tap: tap)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 256 * 2); defer { buf.deallocate() }
        for k in 0..<256 { let v = Int32(sin(2 * .pi * 1000 * Double(k) / 44_100) * 0.5 * 2_147_483_647); buf[k * 2] = v; buf[k * 2 + 1] = v }
        let f0 = eng.frame()
        expect(f0.id == 0)
        // the audio side delivers hundreds of buffers; nothing is published until the analysis thread's own step
        for _ in 0..<500 { tap.write(buf, frames: 256, channels: 2) }
        expect(eng.frame().id == f0.id && eng.frame() === f0, "audio buffers do not produce interface updates")
        var clock = Date()
        clock = clock.addingTimeInterval(1.0 / 60); eng.tick(now: clock)
        let f1 = eng.frame()
        expect(f1.id == f0.id + 1 && f1 !== f0, "one analysis step publishes one frame")
        expect(eng.frame() === f1, "every view in a frame is handed the same object")
        expect(f1.bars == eng.snapshot().bars && f1.meters == eng.snapshot().meters, "the snapshot is the frame")
        for _ in 0..<59 { clock = clock.addingTimeInterval(1.0 / 60); tap.write(buf, frames: 256, channels: 2); eng.tick(now: clock) }
        expect(eng.frame().id == f1.id + 59, "sixty steps a second, however many buffers arrive: \(eng.frame().id)")
        expect(f1.bars.count == AnalysisEngine.bands, "frames are immutable values: an old one is unchanged")

        // the spectrogram image is built once per frame, and is the picture the old path drew
        MainActor.assumeIsolated {
            guard let a = Heat.spectrogram(of: eng), let b = Heat.spectrogram(of: eng) else { expect(false, "an image"); return }
            expect(a === b, "views asking twice in a frame share one image")
            let sg = eng.spectrogram()
            if let old = Heat.image(pixels: sg.pixels, width: sg.width, height: sg.height) {
                expect(a.width == old.width && a.height == old.height && (a.dataProvider?.data as Data?) == (old.dataProvider?.data as Data?), "identical pixels to the previous construction")
            } else { expect(false, "the old image") }
            clock = clock.addingTimeInterval(1.0 / 60); tap.write(buf, frames: 256, channels: 2); eng.tick(now: clock)
            expect(Heat.spectrogram(of: eng) !== a, "a new frame gives a new image")
        }
    }

    // MARK: timings

    /// Prints the same measurements as the baseline run (before the changes), for the new code. Not a pass/fail test beyond sanity checks.
    func report() {
        guard let base = PerfData.baseFLAC(in: tempDir("perf-base-\(UUID().uuidString.prefix(6))")) else { return }
        let albums = Int(ProcessInfo.processInfo.environment["AUREON_PERF_ALBUMS"] ?? "") ?? 800, tracks = 6
        let top = realPath(tempDir("perf-\(UUID().uuidString.prefix(6))")), root = top.appendingPathComponent("music", isDirectory: true)
        func time<T>(_ name: String, _ body: () -> T) -> T {
            let t0 = CFAbsoluteTimeGetCurrent(); let r = body()
            print(String(format: "PERF %@ = %.1f ms", name, (CFAbsoluteTimeGetCurrent() - t0) * 1000)); return r
        }
        time("fixture.build (\(albums) albums, \(albums * tracks) files)") { PerfData.library(albums: albums, tracks: tracks, root: root, base: base) }
        let lib = try! LibraryStore()
        var rep = ImportReport()
        time("scan.full.cold") { rep = lib.importFolder(root) }
        print("PERF scan.full.cold.files = \(rep.scanned) (added \(rep.added))")
        time("scan.full.unchanged (a manual rescan; startup no longer does this)") { rep = lib.importFolder(root) }
        print("PERF scan.full.unchanged.skipped = \(rep.skipped) of \(rep.scanned)")
        expect(rep.skipped == rep.scanned && rep.added == 0)

        // a change since the last close
        let one = PerfData.track(from: base, at: root.appendingPathComponent("Artist 0000/Album 0000/99 New.flac"), album: 0, number: 99)
        var batch = LibraryChangeBatch(root: root.path); batch.paths = [one.path]
        time("startup.delta.oneNewFile (what a launch costs when one file changed)") { rep = LibraryDelta.apply(batch, to: lib) }
        expect(rep.added == 1)
        batch.paths = [one.path]
        time("startup.delta.nothingChanged (event for a file the library has)") { rep = LibraryDelta.apply(batch, to: lib) }
        let dir = top.appendingPathComponent("w"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = LibraryWatcher(stateURL: top.appendingPathComponent("w.json"), settle: 0.2)
        if case .needsReconcile(let id) = w.start(root: root.path) { w.markReconciled(root: root.path, eventID: id) }
        w.stopAll()
        let w2 = LibraryWatcher(stateURL: top.appendingPathComponent("w.json"), settle: 0.2)
        let box = BatchBox(); w2.onCaughtUp = { _ in box.markCaughtUp() }
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = w2.start(root: root.path)
        _ = spinMain(timeout: 10) { box.caughtUp }
        print(String(format: "PERF startup.watcher.replayNothingChanged = %.1f ms (history replayed; caught up: %@)", (CFAbsoluteTimeGetCurrent() - t0) * 1000, box.caughtUp ? "yes" : "no"))
        w2.stopAll()

        // the library as the albums page and the home page load it
        var o = ViewOptions(); o.sort = .artist
        let q = AlbumQuery(o, search: "")
        time("library.pager.first (count + first page of \(AlbumPager.pageSize))") { _ = lib.releaseCount(q); _ = lib.releasePage(q, offset: 0, limit: AlbumPager.pageSize) }
        time("library.pager.sortChange (artist, count + page)") { var d = ViewOptions(); d.sort = .year; let k = AlbumQuery(d, search: ""); _ = lib.releaseCount(k); _ = lib.releasePage(k, offset: 0, limit: AlbumPager.pageSize) }
        time("library.pager.deepPage (page 10)") { _ = lib.releasePage(q, offset: 10 * AlbumPager.pageSize, limit: AlbumPager.pageSize) }
        time("library.home.recents (two rails of 16)") {
            _ = lib.releasePage(AlbumQuery(sort: .added, ascending: false), offset: 0, limit: 16)
            _ = lib.releasePage(AlbumQuery(sort: .added, ascending: false, tier: .hiRes), offset: 0, limit: 16)
        }
        let all = lib.releases(limit: albums + 10)
        let sample = Array(all.prefix(min(200, all.count)))

        // covers for the grid: first load extracts, later loads come from the cache
        let cache = ArtCache(root: top.appendingPathComponent("artcache"))
        time("art.grid.cold.perAlbum x\(sample.count) (tracks + tag read + decode + write both sizes)") {
            for r in sample { _ = try? runAsync { let i = await AlbumArt.cover(for: r, store: lib, fetcher: nil, online: false, cache: cache); return i.hd }.get() }
        }
        let coldExtractions = cache.extractions
        print("PERF art.cache.size = \(cache.size() / 1024) KB for \(cache.extractions) covers (\(cache.extractions == 0 ? 0 : cache.size() / 1024 / max(1, cache.extractions)) KB each)")
        time("art.grid.warm.perAlbum x\(sample.count) (cache lookup + decode thumbnail)") {
            for r in sample { _ = try? runAsync { let i = await AlbumArt.cover(for: r, store: lib, fetcher: nil, online: false, cache: cache); return i.hd }.get() }
        }
        let beforeBytes = albums * 480 * 480 * 4, afterBytes = min(albums, AlbumArt.resident) * ArtCache.thumbPixels * ArtCache.thumbPixels * 4
        print("PERF art.grid.resident = \(afterBytes >> 20) MB at most (before: every album ever scrolled to, \(beforeBytes >> 20) MB for \(albums) albums)")
        expect(coldExtractions == min(sample.count, 16) && cache.extractions == coldExtractions, "each distinct cover (the fixture shares 16 across its albums) was extracted exactly once, and the warm pass extracted nothing: cold \(coldExtractions), after warm \(cache.extractions), albums \(sample.count)")

        // Now Playing and its colours
        let firstPaths = sample.prefix(20).compactMap { lib.tracks(releaseID: $0.id, limit: 1).first?.path }
        let heroCache = ArtCache(root: top.appendingPathComponent("herocache"))
        time("hero.fromTags.x\(firstPaths.count) (tag read + decode + palette + write; the first play of a track)") {
            for p in firstPaths { if let s = ArtCache.Source.localFile(p), let d = try? runAsync({ await MetadataEngine.artwork(path: p) }).get() { _ = heroCache.ingest(s, data: d) } }
        }
        time("hero.fromCache.x\(firstPaths.count) (decode + stored palette; every later play)") {
            for p in firstPaths { if let s = ArtCache.Source.localFile(p) { _ = heroCache.loaded(s) } }
        }

        // analyser frames
        let tap = AnalysisTap(); tap.sampleRate.store(44_100, ordering: .relaxed); tap.enabled.store(true, ordering: .relaxed)
        let eng = AnalysisEngine(tap: tap)
        var clock = Date()
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 1024 * 2); defer { buf.deallocate() }
        for i in 0..<800 {
            for k in 0..<1024 { let v = Int32(sin(2 * .pi * 880 * Double(i * 1024 + k) / 44_100) * 0.4 * 2_147_483_647); buf[k * 2] = v; buf[k * 2 + 1] = v }
            tap.write(buf, frames: 1024, channels: 2); clock = clock.addingTimeInterval(1024.0 / 44_100); eng.tick(now: clock)
        }
        MainActor.assumeIsolated {
            time("viz.frame x200 (one frame + one spectrogram image per new frame)") {
                for _ in 0..<200 {
                    clock = clock.addingTimeInterval(1.0 / 60); tap.write(buf, frames: 1024, channels: 2); eng.tick(now: clock)
                    _ = eng.frame(); _ = Heat.spectrogram(of: eng)
                }
            }
            time("viz.frame.repeat x200 (several views asking within the same frame)") {
                for _ in 0..<200 { _ = eng.frame(); _ = eng.frame(); _ = Heat.spectrogram(of: eng); _ = Heat.spectrogram(of: eng) }
            }
        }
        try? FileManager.default.removeItem(at: top)
    }
}

func performanceTests() -> [(String, TestFn)] {
    let p = PerformanceTests()
    return [("perf.figures", p.storedFiguresStayInStepWithTheTracks), ("perf.paging", p.pagesFollowTheOrdersAndFilters), ("perf.pager", p.pagerHoldsOnlyTheNeighbourhood),
            ("perf.artCache", p.artCacheKeepsTwoSizesAndThePalette), ("perf.artOnce", p.aCoverIsReadFromTheFilesOnlyOnce), ("perf.delta", p.deltaUpdatesTouchOnlyWhatChanged),
            ("perf.bulkLookup", p.bulkLookupMatchesSingleLookups), ("perf.watcher", p.watcherReplaysWhatHappenedWhileClosed), ("perf.frames", p.theInterfaceSeesFramesNotAudioBuffers),
            ("perf.report", p.report)]
}

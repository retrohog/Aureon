import Foundation
import CoreGraphics
import CoreText
import PDFKit

// Folder browser, Boolean search, tag editing, the PDF booklet and the ABX comparator.

func powerFeatureTests() -> [(String, TestFn)] {
    let t = PowerFeatureTests()
    return [
        ("folders.listing", t.folderListing), ("folders.audioWalk", t.audioWalkFollowsLinksOnce),
        ("query.parse", t.queryParsing), ("query.sqlMatchesMemory", t.querySQLMatchesMemory), ("query.tagTree", t.tagTree),
        ("tags.flac", t.flacTagWrite), ("tags.m4a", t.mp4TagWrite), ("tags.mp3", t.id3TagWrite), ("tags.busy", t.tagWriteRefusesFilesInUse),
        ("tags.libraryUpdate", t.libraryFollowsTagEdits), ("tags.replayGainMath", t.replayGainMath),
        ("booklet.detection", t.bookletDetection), ("booklet.anchors", t.bookletAnchors), ("booklet.pdf", t.bookletFromRealPDF),
        ("abx.stats", t.abxStatistics), ("abx.session", t.abxSession), ("abx.loudnessMatch", t.abxLoudnessMatch),
        ("abx.clickFreeSwitch", t.abxClickFreeSwitch), ("abx.alignment", t.abxAlignmentKeepsStreamsInSync),
    ]
}

struct PowerFeatureTests {
    private func fresh(_ name: String) -> URL {
        let d = tempDir("power").appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func touch(_ u: URL, _ bytes: Int = 16) { FileManager.default.createFile(atPath: u.path, contents: Data(repeating: 7, count: bytes)) }

    private func decode(_ path: String) -> [Int32] { let f = try! LosslessFile(path: path); return readAll(f) }

    private func leftovers(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".aureon-") }
    }

    // MARK: - Folders

    func folderListing() {
        let d = fresh("list")
        let fm = FileManager.default
        try! fm.createDirectory(at: d.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: d.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        touch(d.appendingPathComponent("Track 10.flac")); touch(d.appendingPathComponent("Track 2.flac"))
        touch(d.appendingPathComponent("song.mp3")); touch(d.appendingPathComponent("Booklet.pdf"))
        touch(d.appendingPathComponent("cover.jpg")); touch(d.appendingPathComponent("notes.txt"))
        try! fm.createSymbolicLink(atPath: d.appendingPathComponent("link.flac").path, withDestinationPath: d.appendingPathComponent("Track 2.flac").path)
        try! fm.createSymbolicLink(atPath: d.appendingPathComponent("broken.flac").path, withDestinationPath: d.appendingPathComponent("gone.flac").path)
        try! fm.createSymbolicLink(atPath: d.appendingPathComponent("Album/Up").path, withDestinationPath: d.path)

        let e = try! FolderScanner.list(d)
        expect(e.first?.name == "Album" && e.first?.kind == .folder, "folders come first: \(e.map(\.name))")
        expect(!e.contains { $0.name.hasPrefix(".") }, "hidden entries are skipped")
        let names = e.filter { $0.kind == .audio }.map(\.name)
        expect(names.firstIndex(of: "Track 2.flac")! < names.firstIndex(of: "Track 10.flac")!, "Finder order: \(names)")
        func entry(_ n: String) -> FolderEntry { e.first { $0.name == n }! }
        expect(entry("Booklet.pdf").kind == .booklet && entry("cover.jpg").kind == .image && entry("notes.txt").kind == .other)
        expect(entry("song.mp3").kind == .audio && !entry("song.mp3").isPlayable && entry("song.mp3").isTaggable, "MP3 is listed and taggable, not played")
        expect(entry("Track 2.flac").isPlayable && entry("Track 2.flac").isTaggable)
        let link = entry("link.flac")
        expect(link.isSymlink && !link.isBroken && link.target?.path == realPath(d.appendingPathComponent("Track 2.flac")).path, "a link shows its target: \(String(describing: link.target))")
        expect(entry("broken.flac").isBroken, "a dangling link is marked broken")

        let inner = try! FolderScanner.list(d.appendingPathComponent("Album"))
        let up = inner.first { $0.name == "Up" }!
        expect(up.kind == .folder && up.isSymlink, "a link to a folder is a folder")
        let ancestry = [realPath(d).path, realPath(d.appendingPathComponent("Album")).path]
        expect(FolderScanner.isLoop(up, ancestors: ancestry), "a link back to an ancestor is a loop")
        expect(!FolderScanner.isLoop(up, ancestors: ["/somewhere/else"]), "elsewhere it is not")
        let root = FolderEntry(url: URL(fileURLWithPath: "/tmp/rootlink"), name: "rootlink", kind: .folder, isSymlink: true, target: URL(fileURLWithPath: "/"), size: 0, modified: nil)
        expect(FolderScanner.isLoop(root, ancestors: ["/Users/me/Music"]), "a link to / contains every ancestor")
    }

    func audioWalkFollowsLinksOnce() {
        let d = fresh("walk")
        let fm = FileManager.default
        for sub in ["A", "A/CD1", "B"] { try! fm.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true) }
        for f in ["A/1.flac", "A/2.flac", "A/CD1/1.flac", "B/x.wav", "B/skip.mp3"] { touch(d.appendingPathComponent(f)) }
        try! fm.createSymbolicLink(atPath: d.appendingPathComponent("B/loop").path, withDestinationPath: d.path)
        try! fm.createSymbolicLink(atPath: d.appendingPathComponent("B/again").path, withDestinationPath: d.appendingPathComponent("A").path)
        let files = FolderScanner.audioFiles(under: d).map { u in String(u.path[u.path.range(of: d.lastPathComponent + "/")!.upperBound...]) }
        expect(files == ["A/1.flac", "A/2.flac", "A/CD1/1.flac", "B/x.wav"], "each folder once, links do not repeat or loop, MP3 is not queued: \(files)")
        expect(FolderScanner.audioFiles(under: d.appendingPathComponent("A"), recursive: false).count == 2)
        expect(FolderScanner.audioFiles(under: d, limit: 2).count == 2, "the limit holds")
        var calls = 0
        expect(FolderScanner.audioFiles(under: d, cancelled: { calls += 1; return calls > 1 }).count <= 2, "cancelling stops the walk")
    }

    // MARK: - Query

    func queryParsing() {
        expect(!LibraryQuery.looksAdvanced("miles davis") && !LibraryQuery.looksAdvanced("AC/DC") && !LibraryQuery.looksAdvanced("blue-eyed soul"))
        expect(LibraryQuery.looksAdvanced("genre:jazz") && LibraryQuery.looksAdvanced("-live") && LibraryQuery.looksAdvanced("\"so what\"") && LibraryQuery.looksAdvanced("a OR b"))
        let q = try! LibraryQuery(parsing: "Genre: Jazz AND Year: 1955..1965 NOT Artist: \"Miles Davis\"")
        let want = QueryNode.and([.term(QueryTerm(field: .genre, value: .text("Jazz", exact: false, pattern: false))),
                                  .term(QueryTerm(field: .year, value: .range(1955, 1965))),
                                  .not(.term(QueryTerm(field: .artist, value: .text("Miles Davis", exact: true, pattern: false))))])
        expect(q.root == want, "the example parses as written: \(q.root)")
        let p = try! LibraryQuery(parsing: "a OR b c")
        expect(p.root == .or([.term(QueryTerm(field: .any, value: .text("a", exact: false, pattern: false))),
                              .and([.term(QueryTerm(field: .any, value: .text("b", exact: false, pattern: false))), .term(QueryTerm(field: .any, value: .text("c", exact: false, pattern: false)))])]),
               "AND binds tighter than OR: \(p.root)")
        expect(LibraryQuery.numericRange(.year, "1955-1965")! == (1955, 1965) && LibraryQuery.numericRange(.rate, ">=96k")! == (96_000, nil))
        expect(LibraryQuery.numericRange(.duration, "<3:30")!.1! < 210 && LibraryQuery.numericRange(.duration, "<3:30")!.0 == nil)
        expect(LibraryQuery.numericRange(.bits, "24bit")! == (24, 24) && LibraryQuery.numericRange(.year, "abc") == nil)
        func failure(_ s: String) -> QueryError? { do { _ = try LibraryQuery(parsing: s); return nil } catch { return error as? QueryError } }
        expect(failure("\"so what")?.position == 0, "an open quote is reported where it starts")
        expect(failure("Genre: (Jazz")?.position == 7, "a field without a value: \(String(describing: failure("Genre: (Jazz")))")
        expect(failure("(jazz OR blues")?.message.contains("bracket") == true && failure("year:soon") != nil && failure("jazz )") != nil && failure("AND jazz") != nil)
        expect(LibraryQuery.tagPath("Classical > Beethoven / Symphonies") == ["Classical", "Beethoven", "Symphonies"])
    }

    private func libraryFixture() -> LibraryStore {
        let lib = try! LibraryStore()
        func t(_ title: String, _ artist: String, _ genres: [String], _ year: Int, _ path: String) -> (facts: FileFacts, tags: TrackMetadata) {
            var m = TrackMetadata(); m.title = title; m.album = title + " (album)"; m.year = year; m.trackNumber = 1
            m.credits = [Credit(role: .artist, name: artist), Credit(role: .albumArtist, name: artist)]
            m.genres = genres
            return (FileFacts(path: path, duration: 300, sampleRate: 44_100, bitDepth: 16, channels: 2, codec: "FLAC", mtime: 1, size: 1), m)
        }
        _ = lib.upsert([
            t("So What", "Miles Davis", ["Jazz"], 1959, "/q/sowhat.flac"),
            t("Waltz for Debby", "Bill Evans", ["Jazz"], 1961, "/q/waltz.flac"),
            t("Giant Steps", "John Coltrane", ["Jazz"], 1960, "/q/giant.flac"),
            t("Take Five", "Dave Brubeck", ["Jazz"], 1959, "/q/take5.flac"),
            t("Bitches Brew", "Miles Davis", ["Jazz"], 1970, "/q/brew.flac"),
            t("Symphony No. 5", "Herbert von Karajan", ["Classical/Beethoven/Symphonies"], 1962, "/q/sym5.flac"),
            t("Goldberg Variations", "Glenn Gould", ["Classical/Bach"], 1955, "/q/goldberg.flac"),
            t("Blue Monday", "New Order", ["Electronic"], 1983, "/q/blue.flac"),
        ])
        return lib
    }

    func querySQLMatchesMemory() {
        let lib = libraryFixture()
        let all = lib.allTracks(offset: 0, limit: 1000)
        expect(all.count == 8)
        let cases: [(String, Set<String>)] = [
            ("Genre: Jazz AND Year: 1955..1965 NOT Artist: \"Miles Davis\"", ["waltz", "giant", "take5"]),
            ("tag:Classical", ["sym5", "goldberg"]),
            ("tag:\"Classical/Beethoven\"", ["sym5"]),
            ("tag:\"classical > beethoven > symphonies\"", ["sym5"]),
            ("tag:Class", []),
            ("genre:jazz OR genre:electronic", ["sowhat", "waltz", "giant", "take5", "brew", "blue"]),
            ("(artist:\"Bill Evans\" OR artist:coltrane) year:>=1961", ["waltz"]),
            ("-genre:jazz year:<1960", ["goldberg"]),
            ("title:\"so what\"", ["sowhat"]),
            ("artist:miles*", ["sowhat", "brew"]),
            ("year:1955-1965 NOT tag:classical", ["sowhat", "waltz", "giant", "take5"]),
            ("\"giant steps\" OR five", ["giant", "take5"]),
        ]
        for (text, expected) in cases {
            guard let q = try? LibraryQuery(parsing: text) else { expect(false, "“\(text)” should parse"); continue }
            let sql = Set(lib.tracks(matching: q).map { ($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".flac", with: "") })
            let mem = Set(all.filter(q.matches).map { ($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".flac", with: "") })
            expect(sql == expected, "“\(text)” in the database: \(sql.sorted())")
            expect(mem == expected, "“\(text)” in memory: \(mem.sorted())")
            expect(lib.count(matching: q) == expected.count, "count of “\(text)”")
        }
    }

    func tagTree() {
        let lib = libraryFixture()
        let tree = TagTreeNode.build(lib.genreCounts())
        expect(tree.map(\.name) == ["Classical", "Electronic", "Jazz"], "\(tree.map(\.name))")
        let classical = tree[0]
        expect(classical.count == 2 && classical.children.map(\.name) == ["Bach", "Beethoven"] && classical.query == "tag:\"Classical\"", "\(classical)")
        let beethoven = classical.children[1]
        expect(beethoven.path == ["Classical", "Beethoven"] && beethoven.children.first?.name == "Symphonies" && beethoven.children.first?.childrenOrNil == nil)
        expect(tree[2].count == 5 && tree[2].childrenOrNil == nil)
        let merged = TagTreeNode.build([("Rock/Prog", 2), ("rock > prog", 1), ("Rock", 4)])
        expect(merged.count == 1 && merged[0].count == 7 && merged[0].children.count == 1 && merged[0].children[0].count == 3, "spellings of one level merge: \(merged)")
    }

    // MARK: - Tags

    private func flacFixture(_ dir: URL, _ name: String = "t.flac") -> String {
        let wav = sineWAV(dir.appendingPathComponent(name + ".wav"), rate: 44_100, bits: 16, freq: 440, amp: 0.4, seconds: 1)
        let out = dir.appendingPathComponent(name)
        expect(encode(wav, to: out, alac: false), "afconvert makes a FLAC")
        try? FileManager.default.removeItem(at: wav)
        return out.path
    }

    func flacTagWrite() {
        let d = fresh("flac")
        let p = flacFixture(d)
        injectVorbisComments(p, [("TITLE", "Old"), ("ARTIST", "A"), ("ARTIST", "B"), ("CUSTOMKEY", "keep me"), ("TRACKNUMBER", "3/12"),
                                 ("REPLAYGAIN_TRACK_GAIN", "+1.00 dB")])
        let audio = decode(p)
        try! TagEditing.write(path: p, edits: [.title: "New", .artist: "X; Y", .genre: "Classical/Bach", .trackNumber: "4",
                                              .rgTrackGain: "-6.50 dB", .rgTrackPeak: "0.891251", .year: "1999"])
        let raw = TagReader.read(path: p)
        expect(raw.first("TITLE") == "New" && raw.all("ARTIST") == ["X", "Y"] && raw.first("GENRE") == "Classical/Bach", "\(raw)")
        expect(raw.first("CUSTOMKEY") == "keep me", "fields nobody edited stay")
        expect(raw.all("REPLAYGAIN_TRACK_GAIN") == ["-6.50 dB"] && raw.first("REPLAYGAIN_TRACK_PEAK") == "0.891251", "ReplayGain replaced, not doubled")
        let v = TagEditing.read(path: p)
        expect(v[.trackNumber] == "4" && v[.trackTotal] == "12" && v[.year] == "1999", "the track total survives a new track number: \(v)")
        expect(decode(p) == audio, "the audio is bit-identical after the edit")
        // clearing a field removes it
        try! TagEditing.write(path: p, edits: [.genre: ""])
        expect(TagReader.read(path: p).first("GENRE") == nil && TagReader.read(path: p).first("TITLE") == "New")
        expect(decode(p) == audio && leftovers(d).isEmpty, "no temporary files are left behind: \(leftovers(d))")
    }

    func mp4TagWrite() {
        let d = fresh("m4a")
        let wav = sineWAV(d.appendingPathComponent("t.wav"), rate: 48_000, bits: 24, freq: 997, amp: 0.3, seconds: 1)
        let m4a = d.appendingPathComponent("t.m4a")
        expect(encode(wav, to: m4a, alac: true), "afconvert makes an ALAC file")
        injectMP4Tags(m4a.path, items: [mp4Text("\u{A9}nam", ["Old"]), mp4Text("\u{A9}ART", ["A"]), mp4Freeform("MOOD", ["calm"]), mp4Pair("trkn", 2, 9)])
        let audio = decode(m4a.path)
        try! TagEditing.write(path: m4a.path, edits: [.title: "New", .album: "Alb", .trackNumber: "5", .rgAlbumGain: "-4.00 dB", .rgAlbumPeak: "0.5"])
        var raw = TagReader.read(path: m4a.path)
        expect(raw.first("TITLE") == "New" && raw.first("ALBUM") == "Alb" && raw.first("ARTIST") == "A" && raw.first("MOOD") == "calm", "\(raw)")
        expect(raw.first("REPLAYGAIN_ALBUM_GAIN") == "-4.00 dB" && raw.first("REPLAYGAIN_ALBUM_PEAK") == "0.5", "\(raw)")
        let v = TagEditing.read(path: m4a.path)
        expect(v[.trackNumber] == "5" && v[.trackTotal] == "9", "\(v)")
        expect(decode(m4a.path) == audio, "ALAC audio is untouched (chunk offsets follow the bigger moov)")
        // a second edit grows the tag again
        try! TagEditing.write(path: m4a.path, edits: [.artist: "Someone; Else", .genre: "Ambient"])
        raw = TagReader.read(path: m4a.path)
        expect(raw.all("ARTIST") == ["Someone", "Else"] && raw.first("GENRE") == "Ambient" && raw.first("TITLE") == "New", "\(raw)")
        expect(decode(m4a.path) == audio && leftovers(d).isEmpty)
        // a file without any metadata box gets one
        let bare = d.appendingPathComponent("bare.m4a")
        expect(encode(wav, to: bare, alac: true))
        try! TagEditing.write(path: bare.path, edits: [.title: "Fresh"])
        expect(TagReader.read(path: bare.path).first("TITLE") == "Fresh" && decode(bare.path) == decode(m4a.path))
    }

    private func id3Frame23(_ id: String, _ body: Data) -> Data { Data(id.utf8) + be32(body.count) + Data([0, 0]) + body }
    private func id3Syncsafe(_ v: Int) -> Data { Data([UInt8((v >> 21) & 0x7f), UInt8((v >> 14) & 0x7f), UInt8((v >> 7) & 0x7f), UInt8(v & 0x7f)]) }

    func id3TagWrite() {
        let d = fresh("mp3")
        let frames = id3Frame23("TIT2", Data([3]) + Data("Old".utf8)) + id3Frame23("TPE1", Data([0]) + Data("Artist".utf8))
            + id3Frame23("TXXX", Data([3]) + Data("MOOD".utf8) + Data([0]) + Data("calm".utf8)) + id3Frame23("TRCK", Data([0]) + Data("2/10".utf8))
            + id3Frame23("TYER", Data([0]) + Data("1980".utf8))
        let body = frames + Data(count: 100)
        let tag = Data("ID3".utf8) + Data([3, 0, 0]) + id3Syncsafe(body.count) + body
        var rng = SplitMix(seed: 7)
        var audio = Data([0xFF, 0xFB, 0x90, 0x64])
        for _ in 0..<8192 { audio.append(UInt8(truncatingIfNeeded: rng.next())) }
        let p = d.appendingPathComponent("t.mp3").path
        FileManager.default.createFile(atPath: p, contents: tag + audio)

        try! TagEditing.write(path: p, edits: [.title: "Nouveau titre", .year: "2001", .rgTrackGain: "-3.20 dB", .trackNumber: "7"])
        let raw = TagReader.read(path: p)
        expect(raw.first("TITLE") == "Nouveau titre" && raw.first("ARTIST") == "Artist" && raw.first("MOOD") == "calm", "\(raw)")
        expect(raw.first("REPLAYGAIN_TRACK_GAIN") == "-3.20 dB", "\(raw)")
        let v = TagEditing.read(path: p)
        expect(v[.year] == "2001" && v[.trackNumber] == "7" && v[.trackTotal] == "10", "the old TYER is replaced and the total kept: \(v)")
        let out = try! Data(contentsOf: URL(fileURLWithPath: p))
        expect(out.prefix(3) == Data("ID3".utf8) && out[3] == 4, "written as ID3v2.4")
        let size = Int(out[6]) << 21 | Int(out[7]) << 14 | Int(out[8]) << 7 | Int(out[9])
        expect(out.subdata(in: (10 + size)..<out.count) == audio, "the MPEG frames after the tag are byte-identical")
        expect(leftovers(d).isEmpty)
    }

    func tagWriteRefusesFilesInUse() {
        let d = fresh("busy")
        let p = flacFixture(d)
        do {
            let open = try! LosslessFile(path: p)
            do { try TagEditing.write(path: p, edits: [.title: "No"]); expect(false, "a file being decoded must not be written") }
            catch let e as TagEditError { expect(e.isBusy, "\(e)") } catch { expect(false, "\(error)") }
            withExtendedLifetime(open) {}
        }
        expect(FileUse.shared.busyReason(p) == nil, "closing the decoder frees the file")
        let link = d.appendingPathComponent("alias.flac").path
        try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: p)
        FileUse.shared.setEngineHeld([link])
        do { try TagEditing.write(path: p, edits: [.title: "No"]); expect(false, "the playing track (held under another spelling) must not be written") }
        catch let e as TagEditError { expect(e.isBusy) } catch { expect(false, "\(error)") }
        FileUse.shared.setEngineHeld([])
        try! TagEditing.write(path: p, edits: [.title: "Yes"])
        expect(TagReader.read(path: p).first("TITLE") == "Yes" && leftovers(d).isEmpty)
        do { try TagEditing.write(path: d.appendingPathComponent("x.ogg").path, edits: [.title: "?"]); expect(false) }
        catch let e as TagEditError { if case .unsupported = e {} else if case .io = e {} else { expect(false, "\(e)") } } catch { expect(false, "\(error)") }
    }

    func libraryFollowsTagEdits() {
        let d = fresh("libtags")
        let p = flacFixture(d, "song.flac")
        injectVorbisComments(p, [("TITLE", "Before"), ("ARTIST", "Someone"), ("GENRE", "Jazz")])
        let lib = try! LibraryStore()
        let r = lib.importFolder(d)
        let stored = realPath(URL(fileURLWithPath: p)).path      // a folder import stores resolved paths (/private/var/…)
        expect(r.added == 1 && lib.track(path: stored)?.title == "Before", "\(r)")
        expect(lib.contains(path: p), "the editor's spelling of the path finds the library's")
        try! TagEditing.write(path: p, edits: [.title: "After", .genre: "Classical/Bach"])
        expect(lib.update(path: p, tags: TagReader.read(path: p)), "the library takes the new tags")
        let t = lib.track(path: stored)
        expect(t?.title == "After" && t?.genres == ["Classical/Bach"] && (p == stored || lib.track(path: p) == nil), "updated in place, not added twice: \(String(describing: t))")
        let q = try! LibraryQuery(parsing: "tag:Classical")
        expect(lib.tracks(matching: q).map(\.path) == [stored], "and the search sees it at once")
        // library-only edits leave the file alone
        let onlyLibrary = TagEditing.applying([.title: "Library title"], to: TagReader.read(path: p))
        expect(lib.update(path: p, tags: onlyLibrary) && lib.track(path: stored)?.title == "Library title" && TagReader.read(path: p).first("TITLE") == "After")
    }

    func replayGainMath() {
        let v = ReplayGainMath.value(lufs: -14, peak: 0.9)
        expect(v.gain == "-4.00 dB" && v.peak == "0.900000" && abs(v.gainDB + 4) < 1e-9)
        let r = ReplayGainMath.values([(lufs: -14, peak: 0.5, duration: 100), (lufs: -20, peak: 0.95, duration: 100), (lufs: nil, peak: 0, duration: 5)])
        let album = 10 * log10((pow(10, -1.4) + pow(10, -2.0)) / 2)
        expect(r.tracks.count == 3 && r.tracks[2] == nil && r.tracks[1]?.gain == "+2.00 dB", "\(r.tracks)")
        expect(abs(r.album!.gainDB - (-18 - album)) < 1e-9 && r.album!.peakLinear == 0.95, "album gain is the energy mean, album peak the highest: \(String(describing: r.album))")
        let weighted = ReplayGainMath.values([(lufs: -10, peak: 1, duration: 10), (lufs: -30, peak: 1, duration: 990)])
        // 10 s at -10 LUFS and 990 s at -30 LUFS: energy mean ≈ -27.0 LUFS, so about +9 dB (a plain average of -20 LUFS would give +2)
        let mean = 10 * log10((10 * pow(10, -1.0) + 990 * pow(10, -3.0)) / 1000)
        expect(abs(weighted.album!.gainDB - (-18 - mean)) < 1e-9 && weighted.album!.gainDB > 8, "duration weights the album mean: \(weighted.album!.gainDB)")
    }

    // MARK: - Booklet

    func bookletDetection() {
        let d = fresh("booklet")
        let album = d.appendingPathComponent("Kind of Blue")
        let fm = FileManager.default
        for sub in ["Scans", "CD1"] { try! fm.createDirectory(at: album.appendingPathComponent(sub), withIntermediateDirectories: true) }
        touch(album.appendingPathComponent("Scans/back.pdf"), 5000)
        touch(album.appendingPathComponent("Scans/Digital Booklet - Kind of Blue.pdf"), 1000)
        touch(album.appendingPathComponent("tiny.pdf"), 10)
        touch(album.appendingPathComponent("CD1/01 - So What.flac"))
        let found = FolderScanner.booklets(in: album).map(\.lastPathComponent)
        expect(found == ["Digital Booklet - Kind of Blue.pdf", "back.pdf", "tiny.pdf"], "anything called booklet first, then by size: \(found)")
        expect(BookletIndex.booklets(forTrack: album.appendingPathComponent("CD1/01 - So What.flac").path).count == 3, "a disc folder uses the album's booklets")
        expect(BookletIndex.booklets(forTrack: "cloud://bucket/x.flac").isEmpty)
        expect(BookletIndex.albumFolder(for: album.appendingPathComponent("Scans/back.pdf")).lastPathComponent == "Kind of Blue")
        expect(BookletIndex.albumFolder(for: album.appendingPathComponent("tiny.pdf")).lastPathComponent == "Kind of Blue")
        expect(BookletIndex.titleFromFileName("03 - Blue in Green") == (3, "Blue in Green") && BookletIndex.titleFromFileName("1-04 All Blues") == (4, "All Blues"))
        expect(BookletIndex.titleFromFileName("05. Flamenco Sketches") == (5, "Flamenco Sketches") && BookletIndex.titleFromFileName("Intro") == (nil, "Intro"))
        let tracks = BookletIndex.tracks(forBooklet: album.appendingPathComponent("Scans/back.pdf"), store: nil)
        expect(tracks.count == 1 && tracks[0].number == 1 && tracks[0].title == "So What", "tracks found under the album, titled from the file name: \(tracks)")
    }

    private let kindOfBlue = ["So What", "Freddie Freeloader", "Blue in Green", "All Blues", "Flamenco Sketches"].enumerated().map { BookletTrack(number: $0.offset + 1, title: $0.element, path: "/kob/\($0.offset + 1).flac") }

    private var kindOfBluePages: [String] {
        ["KIND OF BLUE  Miles Davis",
         "Tracks: 1. So What 9:22  2. Freddie Freeloader 9:46  3. Blue in Green 5:37  4. All Blues 11:33  5. Flamenco Sketches 9:26",
         "So what? Recorded March 2, 1959. The opening bass figure …",
         "Freddie Freeloader features Wynton Kelly. Blue in Green is a ten-bar form.",
         "All Blues, a 6/8 blues …",
         "Flamenco Sketches: five scales, each played as long as the soloist wishes.",
         "Personnel and credits"]
    }

    func bookletAnchors() {
        let a = BookletIndex.anchors(pageTexts: kindOfBluePages, outline: [(title: "Liner Notes", page: 2), (title: "Personnel", page: 6)], tracks: kindOfBlue)
        let pages = Dictionary(uniqueKeysWithValues: a.compactMap { x in x.trackIndex.map { ($0, x.page) } })
        expect(pages == [0: 2, 1: 3, 2: 3, 3: 4, 4: 5], "each track lands on its own page, not the track list: \(pages)")
        expect(a.contains { $0.trackIndex == nil && $0.title == "Liner Notes" && $0.page == 2 } && a.contains { $0.title == "Personnel" && $0.page == 6 }, "outline chapters stay: \(a)")
        expect(a.map(\.page) == a.map(\.page).sorted(), "anchors in page order")

        // the outline wins over the text, by title or by number
        let b = BookletIndex.anchors(pageTexts: kindOfBluePages, outline: [(title: "3. Blue in Green (lyrics)", page: 6), (title: "Track 4", page: 5)], tracks: kindOfBlue)
        expect(b.first { $0.trackIndex == 2 }?.page == 6 && b.first { $0.trackIndex == 2 }?.source == .outline, "\(b)")
        expect(b.first { $0.trackIndex == 3 }?.page == 5 && b.first { $0.trackIndex == 3 }?.source == .outline, "\(b)")

        // only a track list: that is where the tracks are
        let c = BookletIndex.anchors(pageTexts: Array(kindOfBluePages.prefix(2)), outline: [], tracks: kindOfBlue)
        expect(c.filter { $0.trackIndex != nil }.allSatisfy { $0.page == 1 } && c.count == 5)

        // suffixes are ignored, very short titles never match by chance, words match whole
        let d = BookletIndex.anchors(pageTexts: ["cover", "Go and So What, the live take", "Gone"], outline: [],
                                     tracks: [BookletTrack(number: 1, title: "So What (Live)", path: nil), BookletTrack(number: 2, title: "Go", path: nil), BookletTrack(number: 3, title: "One", path: nil)])
        expect(d.count == 1 && d[0].trackIndex == 0 && d[0].page == 1, "\(d)")
        expect(BookletIndex.normalize("Blue-in  Green!") == " blue in green " && BookletIndex.leadingNumber("Track 03 - x") == 3 && BookletIndex.leadingNumber("1959 notes") == nil)
    }

    /// Writes a PDF with CoreText so that its text can be extracted, then reads it back through PDFKit.
    private func makePDF(_ url: URL, pages: [String], outline: [(title: String, page: Int)] = []) {
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        for text in pages {
            ctx.beginPDFPage(nil)
            let s = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 30, dy: 40), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        if !outline.isEmpty {                                    // a table of contents, written into the file the way publishing tools write it
            let children: [[String: Any]] = outline.map { [kCGPDFOutlineTitle as String: $0.title, kCGPDFOutlineDestination as String: $0.page + 1] }   // 1-based page
            CGPDFContextSetOutline(ctx, [kCGPDFOutlineChildren as String: children] as CFDictionary)
        }
        ctx.closePDF()
    }

    func bookletFromRealPDF() {
        let d = fresh("pdf")
        let u = d.appendingPathComponent("Digital Booklet.pdf")
        makePDF(u, pages: kindOfBluePages, outline: [(title: "Liner Notes", page: 2)])
        guard let again = PDFDocument(url: u) else { expect(false, "PDFKit opens the booklet"); return }
        expect(again.pageCount == kindOfBluePages.count)
        let (texts, outline) = BookletIndex.extract(again)
        expect(texts.count == kindOfBluePages.count && texts[3].contains("Freddie"), "page text comes back: \(texts.map { $0.prefix(20) })")
        expect(outline.count == 1 && outline[0].title == "Liner Notes" && outline[0].page == 2, "\(outline)")
        let anchors = BookletIndex.anchors(pageTexts: texts, outline: outline, tracks: kindOfBlue)
        expect(anchors.first { $0.trackIndex == 4 }?.page == 5 && anchors.first { $0.trackIndex == 0 }?.page == 2, "\(anchors)")
        var calls = 0
        expect(BookletIndex.extract(again, cancelled: { calls += 1; return calls > 2 }).texts.count == 2, "indexing stops when the booklet changes")
    }

    // MARK: - ABX

    func abxStatistics() {
        expect(abs(ABXStats.pValue(correct: 12, trials: 16) - 0.0384063720703125) < 1e-12, "\(ABXStats.pValue(correct: 12, trials: 16))")
        expect(abs(ABXStats.pValue(correct: 16, trials: 16) - 1.0 / 65536) < 1e-15 && ABXStats.pValue(correct: 0, trials: 10) == 1)
        expect(abs(ABXStats.pValue(correct: 9, trials: 10) - 11.0 / 1024) < 1e-12 && ABXStats.pValue(correct: 5, trials: 0) == 1)
        expect(ABXStats.needed(trials: 16) == 12 && ABXStats.needed(trials: 10) == 9 && ABXStats.needed(trials: 20) == 15, "\(ABXStats.needed(trials: 16)) \(ABXStats.needed(trials: 10)) \(ABXStats.needed(trials: 20))")
        let w = ABXStats.wilson(correct: 8, trials: 10)
        expect(abs(w.low - 0.4901) < 0.001 && abs(w.high - 0.9433) < 0.001, "Wilson 8/10: \(w)")
        let all = ABXStats.wilson(correct: 20, trials: 20), none = ABXStats.wilson(correct: 0, trials: 20)
        expect(all.high > 0.999_999 && all.low > 0.8 && none.low < 1e-9 && none.high < 0.2, "\(all) \(none)")
        for n in [10, 16, 20] { for c in 0...n {
            let ci = ABXStats.wilson(correct: c, trials: n), p = Double(c) / Double(n)
            expect(ci.low <= p + 1e-12 && p <= ci.high + 1e-12 && ci.low >= 0 && ci.high <= 1)
        } }
    }

    func abxSession() {
        var g1 = SplitMix(seed: 42), g2 = SplitMix(seed: 42)
        let s1 = ABXSession(count: 16, rng: &g1), s2 = ABXSession(count: 16, rng: &g2)
        expect(s1.trials == s2.trials && s1.total == 16, "a seed gives the same X sequence")
        expect(Set(s1.trials.map(\.x)).count == 2, "X is sometimes A and sometimes B")
        var g3 = SplitMix(seed: 1)
        expect(ABXSession(count: 3, rng: &g3).total == 10 && ABXSession(count: 99, rng: &g3).total == 20, "10 to 20 trials")
        var s = s1
        for _ in 0..<16 { s.noteSwitch(); s.noteSwitch(); s.answer(s.currentX!, seconds: 4) }
        expect(s.finished && s.correct == 16 && s.answered == 16 && s.pValue < 0.001 && s.currentX == nil, "a perfect run")
        expect(s.trials.allSatisfy { $0.switches == 2 && $0.seconds == 4 } && s.verdict.contains("heard a difference"))
        expect(!s.answer(.a, seconds: 1), "no answers after the end")
        var wrong = s2
        for _ in 0..<16 { wrong.answer(wrong.currentX!.other, seconds: 1) }
        expect(wrong.correct == 0 && wrong.pValue == 1 && wrong.verdict.contains("No proof"), "\(wrong.correct)/16 → \(wrong.pValue)")
    }

    /// Renders `frames` stereo frames from the engine's core on this thread, waiting for the producer when it is behind.
    private func render(_ e: ABXEngine, frames: Int, block: Int = 512, before: (Int) -> Void = { _ in }) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(frames * 2)
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { buf.deallocate() }
        while out.count < frames * 2 {
            let deadline = Date().addingTimeInterval(5)
            while e.core.ring.availableToRead < block && Date() < deadline { usleep(500) }
            before(out.count / 2)
            e.core.process(buf, frames: block)
            out.append(contentsOf: UnsafeBufferPointer(start: buf, count: block * 2))
        }
        return Array(out.prefix(frames * 2))
    }

    private func toneWAV(_ url: URL, rate: Int, seconds: Double, parts: [(freq: Double, amp: Double)]) -> URL {
        let full = Double((1 << 23) - 1)
        return writeWAV(url, rate: rate, bits: 24, frames: Int(Double(rate) * seconds)) { f, _ in
            Int((parts.reduce(0) { $0 + $1.amp * sin(2 * .pi * $1.freq * Double(f) / Double(rate)) } * full).rounded())
        }
    }

    func abxLoudnessMatch() {
        let d = fresh("abxlufs")
        let a = toneWAV(d.appendingPathComponent("a.wav"), rate: 44_100, seconds: 3, parts: [(100, 0.2), (1000, 0.2), (5000, 0.1)])
        // a "different master": 7 dB quieter overall and with extra treble
        let b = toneWAV(d.appendingPathComponent("b.wav"), rate: 44_100, seconds: 3, parts: [(100, 0.08), (1000, 0.08), (5000, 0.04), (9000, 0.05)])
        let sa = try! ABXStream(path: a.path, rate: 44_100), sb = try! ABXStream(path: b.path, rate: 44_100)
        let la = ABXLoudness.measure(sa)!.integratedLUFS!, lb = ABXLoudness.measure(sb)!.integratedLUFS!
        expect(la - lb > 4, "the fixture really differs: \(la) vs \(lb)")
        let g = ABXLoudness.gains(lufsA: la, lufsB: lb)
        expect(g.b == 1 && g.a < 1, "only the louder file is turned down: \(g)")

        func playedLUFS(_ slot: ABXSlot) -> Double {
            let e = try! ABXEngine(pathA: a.path, pathB: b.path, rate: 44_100)
            e.core.setGains(a: g.a, b: g.b)
            e.core.select(slot)
            e.core.playing.store(true, ordering: .releasing)
            e.startProducer()
            let out = render(e, frames: 44_100 * 2)
            e.stop()
            return R128.analyze(samples: Array(out.dropFirst(2 * 4410)), sampleRate: 44_100, channels: 2).integratedLUFS!
        }
        let pa = playedLUFS(.a), pb = playedLUFS(.b)
        expect(abs(pa - pb) < 0.1, String(format: "what the listener hears is matched within 0.1 LU: A %.3f, B %.3f", pa, pb))
        expect(abs(pb - lb) < 0.2, "the quieter file plays at its own level")
        let off = ABXLoudness.gains(lufsA: nil, lufsB: lb)
        expect(off == (1, 1), "nothing is changed when a side cannot be measured")
    }

    func abxClickFreeSwitch() {
        let d = fresh("abxclick")
        let a = sineWAV(d.appendingPathComponent("a.wav"), rate: 44_100, bits: 24, freq: 1000, amp: 0.5, seconds: 2)
        let b = sineWAV(d.appendingPathComponent("b.wav"), rate: 44_100, bits: 24, freq: 1000, amp: 0.25, seconds: 2)
        let e = try! ABXEngine(pathA: a.path, pathB: b.path, rate: 44_100)
        e.core.setGains(a: 1, b: 1)
        e.core.playing.store(true, ordering: .releasing)
        e.startProducer()
        let switchAt = 22_016                          // the sine is near its crest here: a hard cut would jump by 0.25
        let out = render(e, frames: 33_075) { at in if at == switchAt { e.core.select(.b) } }
        e.stop()
        let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
        var maxStep: Float = 0
        for i in 1024..<left.count { maxStep = max(maxStep, abs(left[i] - left[i - 1])) }
        let sineStep = Float(2 * Double.pi * 1000 / 44_100 * 0.5)
        expect(maxStep < sineStep + 0.004, "no step larger than the sine's own slope: \(maxStep) vs \(sineStep)")
        func peak(_ r: Range<Int>) -> Float { left[r].map(abs).max() ?? 0 }
        let fade = e.core.fadeFrames
        expect(fade == 441, "10 ms at 44.1 kHz: \(fade)")
        expect(abs(peak(15_000..<20_000) - 0.5) < 0.002, "A before: \(peak(15_000..<20_000))")
        expect(peak((switchAt + 100)..<(switchAt + 200)) > 0.3, "still crossfading 2-4 ms after the switch")
        expect(abs(peak((switchAt + fade + 1)..<(switchAt + fade + 2000)) - 0.25) < 0.002, "all B once the 10 ms are over: \(peak((switchAt + fade + 1)..<(switchAt + fade + 2000)))")
        let rampIn = left[0..<64].map(abs).max() ?? 1
        expect(rampIn < 0.2, "playback starts with a ramp, not a click: \(rampIn)")
        expect(e.core.underruns.load(ordering: .relaxed) == 0, "the producer kept up")
    }

    func abxAlignmentKeepsStreamsInSync() {
        let d = fresh("abxsync")
        var rng = SplitMix(seed: 99)
        let n = 44_100 * 3
        var noise = [Int](repeating: 0, count: n)
        var lp = 0.0
        for i in 0..<n { lp = lp * 0.7 + Double(Int64(bitPattern: rng.next()) >> 41) * 0.3; noise[i] = Int(lp) }    // coloured noise, 24-bit
        let a = writeWAV(d.appendingPathComponent("a.wav"), rate: 44_100, bits: 24, frames: n) { f, c in noise[f] / (c + 1) }
        let delay = 1234
        let late = writeWAV(d.appendingPathComponent("late.wav"), rate: 44_100, bits: 24, frames: n) { f, c in f < delay ? 0 : noise[f - delay] / (c + 1) }
        let early = writeWAV(d.appendingPathComponent("early.wav"), rate: 44_100, bits: 24, frames: n - 500) { f, c in noise[f + 500] / (c + 1) }

        for (file, expected) in [(late, delay), (early, -500)] {
            let sa = try! ABXStream(path: a.path, rate: 44_100), sb = try! ABXStream(path: file.path, rate: 44_100)
            let r = ABXAlign.measure(sa, sb)
            expect(r.offset == expected && r.confidence > 0.95, "offset found to the sample: \(r) for \(expected)")

            let e = try! ABXEngine(pathA: a.path, pathB: file.path, rate: 44_100)
            e.setOffset(r.offset)
            e.startProducer()
            // read the ring directly: every frame carries A and B for the same instant
            let quad = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * 4)
            var frames = 0, mismatches = 0, compared = 0
            let deadline = Date().addingTimeInterval(10)
            while frames < 44_100 && Date() < deadline {
                let got = e.core.ring.read(into: quad, frames: 4096)
                if got == 0 { usleep(1000); continue }
                for i in 0..<got {
                    let t = frames + i, bIndex = t + r.offset
                    guard bIndex >= 0, bIndex < n - 500 else { continue }
                    compared += 1
                    if quad[i * 4] != quad[i * 4 + 2] || quad[i * 4 + 1] != quad[i * 4 + 3] { mismatches += 1 }
                }
                frames += got
            }
            quad.deallocate()
            e.stop()
            expect(compared > 40_000 && mismatches == 0, "A and B are sample-identical frame by frame: \(mismatches) of \(compared) differ")
        }
        // unrelated material is not "aligned"
        let other = sineWAV(d.appendingPathComponent("sine.wav"), rate: 44_100, freq: 333, amp: 0.3, seconds: 3)
        let r = ABXAlign.measure(try! ABXStream(path: a.path, rate: 44_100), try! ABXStream(path: other.path, rate: 44_100))
        expect(r.confidence < ABXAlign.minimumConfidence, "noise against a sine has no offset worth trusting: \(r)")
    }
}

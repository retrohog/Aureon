import Foundation
import AppKit

/// A PNG split into a left and a right colour.
func testPNG(_ w: Int = 600, _ h: Int = 600, left: NSColor = .red, right: NSColor = .blue) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(left.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    ctx.setFillColor(right.cgColor); ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

// MARK: ID3 building

private func syncsafe(_ v: Int) -> Data { Data([UInt8((v >> 21) & 0x7f), UInt8((v >> 14) & 0x7f), UInt8((v >> 7) & 0x7f), UInt8(v & 0x7f)]) }

private func id3Frame(_ id: String, _ body: Data, v24: Bool) -> Data {
    Data(id.utf8) + (v24 ? syncsafe(body.count) : be32(body.count)) + Data([0, 0]) + body
}
private func id3Text(_ enc: UInt8, _ s: String) -> Data {
    switch enc {
    case 1: return Data([1, 0xFF, 0xFE]) + (s.data(using: .utf16LittleEndian) ?? Data())
    case 3: return Data([3]) + Data(s.utf8)
    default: return Data([0]) + (s.data(using: .isoLatin1) ?? Data())
    }
}
private func id3Tag(version: UInt8, frames: [Data], padding: Int = 64) -> Data {
    let body = frames.reduce(Data(), +) + Data(count: padding)
    return Data("ID3".utf8) + Data([version, 0, 0]) + syncsafe(body.count) + body
}
private func apic(_ img: Data, mime: String = "image/png", type: UInt8 = 3, desc: String = "") -> Data {
    Data([0]) + Data(mime.utf8) + Data([0, type]) + Data(desc.utf8) + Data([0]) + img
}

struct ArtworkTests {
    let dir = tempDir("artwork")

    // MARK: ID3

    func id3v23FramesAndPicture() {
        let png = testPNG(40, 40)
        let tag = id3Tag(version: 3, frames: [
            id3Frame("TIT2", id3Text(0, "Blue in Green"), v24: false), id3Frame("TPE1", id3Text(1, "Miles Davis ♪"), v24: false),
            id3Frame("TALB", id3Text(0, "Kind of Blue"), v24: false), id3Frame("TRCK", id3Text(0, "3/5"), v24: false), id3Frame("TPOS", id3Text(0, "1/2"), v24: false),
            id3Frame("TYER", id3Text(0, "1959"), v24: false), id3Frame("TCON", id3Text(0, "(8)"), v24: false), id3Frame("TCOM", id3Text(0, "Bill Evans"), v24: false),
            id3Frame("TXXX", Data([0]) + Data("ReplayGain_Track_Gain".utf8) + Data([0]) + Data("-6.5 dB".utf8), v24: false),
            id3Frame("APIC", apic(png), v24: false)])
        let f = ID3v2.parse(tag)!
        let m = TagInterpreter.interpret(f.tags)
        expect(m.title == "Blue in Green" && m.album == "Kind of Blue" && m.trackNumber == 3 && m.trackTotal == 5 && m.discNumber == 1 && m.year == 1959, "\(m)")
        expect(m.credits(.artist).map(\.name) == ["Miles Davis ♪"], "UTF-16 with BOM: \(m.credits(.artist))")
        expect(m.genres == ["Jazz"], "ID3v1 genre reference (8) is Jazz: \(m.genres)")
        expect(m.credits(.composer).map(\.name) == ["Bill Evans"])
        expect(f.tags.first("REPLAYGAIN_TRACK_GAIN") == "-6.5 dB", "TXXX keys come through")
        expect(f.bestPicture?.data == png && f.bestPicture?.mime == "image/png")
    }

    func id3v24AndV22() {
        let tag4 = id3Tag(version: 4, frames: [
            id3Frame("TIT2", id3Text(3, "Größe — Ünïcode"), v24: true), id3Frame("TPE1", id3Text(3, "A\u{0}B"), v24: true),
            id3Frame("TDRC", id3Text(3, "2021-05-07"), v24: true), id3Frame("TCON", id3Text(3, "Rock\u{0}Pop"), v24: true)], padding: 0)
        let t4 = ID3v2.parse(tag4)!.tags
        expect(t4.first("TITLE") == "Größe — Ünïcode" && t4.all("ARTIST") == ["A", "B"] && t4.first("DATE") == "2021-05-07" && t4.all("GENRE") == ["Rock", "Pop"], "\(t4.values)")
        // v2.2: three-letter ids, three-byte sizes
        func f2(_ id: String, _ body: Data) -> Data { Data(id.utf8) + Data([UInt8((body.count >> 16) & 255), UInt8((body.count >> 8) & 255), UInt8(body.count & 255)]) + body }
        let png = testPNG(20, 20)
        let body2 = f2("TT2", id3Text(0, "Old Song")) + f2("TP1", id3Text(0, "Old Band")) + f2("TAL", id3Text(0, "Old Album")) + f2("TRK", id3Text(0, "7")) + f2("TYE", id3Text(0, "1985"))
            + f2("PIC", Data([0]) + Data("PNG".utf8) + Data([3, 0]) + png)
        let tag2 = Data("ID3".utf8) + Data([2, 0, 0]) + syncsafe(body2.count) + body2
        let r = ID3v2.parse(tag2)!
        expect(r.tags.first("TITLE") == "Old Song" && r.tags.first("ALBUM") == "Old Album" && r.tags.first("TRACKNUMBER") == "7" && r.tags.first("DATE") == "1985", "\(r.tags.values)")
        expect(r.bestPicture?.data == png)
        expect(ID3v2.parse(Data("not a tag at all".utf8)) == nil)
    }

    func truncatedAndHostileTagsDoNotCrash() {
        var rng = SystemRandomNumberGenerator()
        let good = id3Tag(version: 3, frames: [id3Frame("TIT2", id3Text(0, "x"), v24: false), id3Frame("APIC", apic(testPNG(8, 8)), v24: false)])
        for cut in stride(from: 0, to: good.count, by: 3) { _ = ID3v2.parse(good.prefix(cut)) }
        for _ in 0..<300 {
            var d = good
            for _ in 0..<5 { d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = ID3v2.parse(d)
        }
        expect(true)
    }

    // MARK: Containers

    private func flac(_ name: String) -> URL? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return nil }
        let wav = sineWAV(dir.appendingPathComponent(name + ".wav"), rate: 44_100, freq: 440, amp: 0.4, seconds: 1)
        let f = dir.appendingPathComponent(name + ".flac")
        return encode(wav, to: f, alac: false) ? f : nil
    }

    func flacAlbumTrackYearGenreAndHiResCover() {
        guard let f = flac("full") else { return }
        injectVorbisComments(f.path, [("TITLE", "So What"), ("ARTIST", "Miles Davis"), ("ALBUM", "Kind of Blue"), ("TRACKNUMBER", "1"), ("TRACKTOTAL", "5"),
                                      ("DATE", "1959-08-17"), ("GENRE", "Jazz"), ("COMPOSER", "Miles Davis")])
        let big = testPNG(1500, 1500)
        injectFLACPicture(f.path, image: big)
        let t = MetadataEngine.native(path: f.path)
        expect(t.title == "So What" && t.album == "Kind of Blue" && t.trackNumber == 1 && t.trackTotal == 5 && t.year == 1959 && t.genre == "Jazz" && t.artist == "Miles Davis" && t.composer == "Miles Davis", "\(t)")
        expect(t.picture?.data == big, "the full-resolution picture is returned untouched")
        expect(ImageTools.size(t.picture!.data)! == (1500, 1500))
        let small = ImageTools.cgImage(big, maxPixel: 300)!
        expect(max(small.width, small.height) == 300, "decoding for display is bounded: \(small.width)×\(small.height)")
        // adding tags and a picture must not change a single decoded sample
        let clean = flac("clean")!
        expect(readAll(try! LosslessFile(path: f.path)) == readAll(try! LosslessFile(path: clean.path)))
    }

    func flacPictureTypesAndBase64Comment() {
        guard let f = flac("pics") else { return }
        let front = testPNG(300, 300, left: .green, right: .green), back = testPNG(900, 900)
        injectFLACPicture(f.path, image: back)           // helper writes type 3; craft the rest by hand
        let pics = FLACMetadata.read(path: f.path)!.pictures
        expect(pics.count == 1 && pics[0].type == 3 && pics[0].width == 64)
        let block = { (type: Int, img: Data) -> Data in be32(type) + be32(9) + Data("image/png".utf8) + be32(0) + be32(10) + be32(10) + be32(24) + be32(0) + be32(img.count) + img }
        let fp = FileTags(tags: RawTags(), pictures: [EmbeddedPicture(data: back, mime: "image/png", type: 4), EmbeddedPicture(data: front, mime: "image/png", type: 3)])
        expect(fp.bestPicture?.data == front, "front cover wins over a bigger back cover")
        expect(FileTags(tags: RawTags(), pictures: [EmbeddedPicture(data: front, mime: "", type: 0), EmbeddedPicture(data: back, mime: "", type: 0)]).bestPicture?.data == back, "else the biggest")
        // base64 METADATA_BLOCK_PICTURE inside a Vorbis comment
        let b64 = block(3, front).base64EncodedString()
        let tags = VorbisTags.parseCommentsWithPictures(vorbisBlock([("TITLE", "T"), ("METADATA_BLOCK_PICTURE", b64)]))
        expect(tags.tags.first("TITLE") == "T" && tags.pictures.first?.data == front && tags.tags.first("METADATA_BLOCK_PICTURE") == nil)
        expect(FLACMetadata.parsePicture(Data([0, 0, 0, 3, 0, 0, 0, 200])) == nil, "a corrupt picture block is ignored")
    }

    func flacBehindALeadingID3Tag() {
        guard let f = flac("lead") else { return }
        injectVorbisComments(f.path, [("TITLE", "Native")])
        let plain = try! Data(contentsOf: f)
        let png = testPNG(64, 64)
        // 1) ID3 in front, Vorbis block present: Vorbis wins
        let tag = id3Tag(version: 3, frames: [id3Frame("TIT2", id3Text(0, "FromID3"), v24: false), id3Frame("TALB", id3Text(0, "ID3 Album"), v24: false), id3Frame("APIC", apic(png), v24: false)])
        let lead = dir.appendingPathComponent("lead_id3.flac")
        try! (tag + plain).write(to: lead)
        let t = TagReader.readAll(path: lead.path)
        expect(t.tags.first("TITLE") == "Native", "Vorbis comments take precedence")
        expect(t.bestPicture?.data == png, "the ID3 picture is still found")
        // 2) no Vorbis block at all: ID3 supplies the tags
        let bare = flac("bare")!
        let lead2 = dir.appendingPathComponent("lead2.flac")
        try! (tag + (try! Data(contentsOf: bare))).write(to: lead2)
        let m = MetadataEngine.native(path: lead2.path)
        expect(m.title == "FromID3" && m.album == "ID3 Album" && m.picture?.data == png, "\(m)")
        // before the fix a leading tag hid "fLaC" and every tag was lost
        expect(VorbisTags.readFLAC(path: lead2.path) != nil)
    }

    func alacCoverAndAtoms() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return }
        let wav = sineWAV(dir.appendingPathComponent("a.wav"), rate: 48_000, freq: 330, amp: 0.4, seconds: 1)
        let m4a = dir.appendingPathComponent("a.m4a")
        expect(encode(wav, to: m4a, alac: true))
        let before = readAll(try! LosslessFile(path: m4a.path))
        let jpegLike = testPNG(500, 500)
        injectMP4Tags(m4a.path, items: [mp4Text("\u{A9}nam", ["Andante"]), mp4Text("\u{A9}alb", ["The Album"]), mp4Text("\u{A9}ART", ["The Artist"]), mp4Text("\u{A9}day", ["2003-04-01"]),
                                        mp4Text("\u{A9}gen", ["Classical"]), mp4Text("\u{A9}wrt", ["Composer C"]), mp4Pair("trkn", 4, 9), mp4Pair("disk", 2, 2),
                                        mp4Box("covr", mp4Data(14, jpegLike))])
        let t = MetadataEngine.native(path: m4a.path)
        expect(t.title == "Andante" && t.album == "The Album" && t.artist == "The Artist" && t.year == 2003 && t.genre == "Classical" && t.composer == "Composer C", "\(t)")
        expect(t.trackNumber == 4 && t.trackTotal == 9 && t.discNumber == 2, "\(t)")
        expect(t.picture?.data == jpegLike, "covr atom")
        expect(readAll(try! LosslessFile(path: m4a.path)) == before, "ALAC audio intact")
    }

    func wavAndAiffID3Chunks() {
        let png = testPNG(32, 32)
        let tag = id3Tag(version: 3, frames: [id3Frame("TIT2", id3Text(0, "Wave Song"), v24: false), id3Frame("TALB", id3Text(0, "Wave Album"), v24: false), id3Frame("APIC", apic(png), v24: false)], padding: 0)
        let wav = sineWAV(dir.appendingPathComponent("w.wav"), rate: 44_100, freq: 440, amp: 0.3, seconds: 0.2)
        var d = try! Data(contentsOf: wav)
        d += Data("id3 ".utf8) + le32(tag.count) + tag + (tag.count % 2 == 1 ? Data([0]) : Data())
        let w2 = dir.appendingPathComponent("w2.wav"); try! d.write(to: w2)
        let t = MetadataEngine.native(path: w2.path)
        expect(t.title == "Wave Song" && t.album == "Wave Album" && t.picture?.data == png, "\(t)")
        // AIFF: big-endian chunk sizes
        let comm = Data("COMM".utf8) + be32(18) + Data(count: 18)
        var form = Data("AIFF".utf8) + comm + Data("ID3 ".utf8) + be32(tag.count) + tag + (tag.count % 2 == 1 ? Data([0]) : Data())
        form = Data("FORM".utf8) + be32(form.count) + form
        let a = dir.appendingPathComponent("x.aiff"); try! form.write(to: a)
        expect(MetadataEngine.native(path: a.path).title == "Wave Song")
    }

    func untaggedFilesAreHandledGracefully() {
        guard let f = flac("none") else { return }
        let t = try! runAsync { await MetadataEngine.load(path: f.path) }.get()
        expect(t.title == nil && t.picture == nil && t.isEmpty, "\(t)")
        expect(MetadataEngine.native(path: "/nonexistent/file.flac").isEmpty)
        let junk = dir.appendingPathComponent("junk.flac"); try! Data("this is not flac".utf8).write(to: junk)
        expect(MetadataEngine.native(path: junk.path).isEmpty)
    }

    // MARK: matching

    func matchingRules() {
        expect(ArtworkMatch.normalize("Kind Of Blue (Legacy Edition) [Remastered]") == "kind of blue")
        expect(ArtworkMatch.normalize("Beyoncé & Jay‑Z: Café") == ArtworkMatch.normalize("beyonce and jay z cafe"))
        expect(ArtworkMatch.score(wantAlbum: "Kind of Blue", wantArtist: "Miles Davis", gotAlbum: "Kind of Blue (Legacy Edition)", gotArtist: "Miles Davis")! > 0.95)
        expect(ArtworkMatch.score(wantAlbum: "Kind of Blue", wantArtist: "Miles Davis", gotAlbum: "Kind of Blue", gotArtist: "Some Cover Band") == nil, "right album, wrong artist")
        expect(ArtworkMatch.score(wantAlbum: "Kind of Blue", wantArtist: "Miles Davis", gotAlbum: "Sketches of Spain", gotArtist: "Miles Davis") == nil, "right artist, wrong album")
        expect(ArtworkMatch.score(wantAlbum: "Abbey Road", wantArtist: "Various Artists", gotAlbum: "Abbey Road", gotArtist: "The Beatles") != nil, "compilations skip the artist check")
        expect(ArtworkMatch.score(wantAlbum: "Abbey Road", wantArtist: "The Beatles, George Martin", gotAlbum: "Abbey Road", gotArtist: "The Beatles") != nil, "any of several artists matches")
        expect(ArtworkMatch.key_equalForCosmeticChanges())
    }

    // MARK: fetching

    private func get(_ f: ArtworkFetcher, _ artist: String?, _ album: String) -> Data? {
        ((try? runAsync { await f.cover(artist: artist, album: album) }.get()) ?? nil)
    }

    private func itunesJSON(_ rows: [(album: String, artist: String)]) -> String {
        let r = rows.enumerated().map { "{\"collectionName\":\"\($1.album)\",\"artistName\":\"\($1.artist)\",\"artworkUrl100\":\"https://is1-ssl.mzstatic.com/image/thumb/Music/\($0)/100x100bb.jpg\"}" }
        return "{\"resultCount\":\(rows.count),\"results\":[\(r.joined(separator: ","))]}"
    }

    private func fetcher(_ http: StubHTTP, name: String) -> ArtworkFetcher {
        let d = dir.appendingPathComponent(name); try? FileManager.default.removeItem(at: d)
        return ArtworkFetcher(http: http, directory: d, musicBrainzInterval: 0.01)
    }

    func iTunesHitIsUpscaledAndCached() {
        let http = StubHTTP(); let img = testPNG(1200, 1200)
        http.on("itunes.apple.com/search", itunesJSON([("Kind of Blue (Legacy Edition)", "Miles Davis"), ("Kind of Blue", "Not Miles")]))
        http.on("mzstatic.com", [(img, 200)])
        let f = fetcher(http, name: "itunes")
        let a = get(f, "Miles Davis", "Kind of Blue")
        expect(a == img, "the matching album's art is returned")
        let urls = http.urls()
        expect(urls.first?.contains("term=Miles%20Davis%20Kind%20of%20Blue") == true && urls.first?.contains("entity=album") == true, "\(urls)")
        expect(urls.contains { $0.contains("/0/1200x1200bb.jpg") }, "the 100 px thumbnail URL is upgraded to the full size: \(urls)")
        expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Aureon/") == true }, "identifies itself")
        let n = http.count
        let b = get(f, "Miles Davis", "kind of blue")
        expect(b == img && http.count == n, "second ask (even with different case) is served from the cache with no request")
        // survives a restart: a new fetcher over the same directory
        let again = ArtworkFetcher(http: StubHTTP(), directory: f.directory)
        expect((try? runAsync { await again.cached(artist: "Miles Davis", album: "Kind of Blue") }.get()) == img)
    }

    func fallsBackToMusicBrainzAndCoverArtArchive() {
        let http = StubHTTP(); let img = testPNG(800, 800)
        http.on("itunes.apple.com/search", itunesJSON([("Totally Different Album", "Someone Else")]))
        http.on("musicbrainz.org/ws/2/release", """
        {"releases":[{"id":"aaaa-1111","title":"Obscure Record","score":100,"artist-credit":[{"name":"Obscure Band","artist":{"name":"Obscure Band"}}]},
                     {"id":"bbbb-2222","title":"Other","score":90,"artist-credit":[{"name":"Obscure Band"}]}]}
        """)
        http.on("coverartarchive.org/release/aaaa-1111/front-1200", [(Data(), 404)])
        http.on("coverartarchive.org/release/aaaa-1111/front", [(img, 200)])
        let f = fetcher(http, name: "mb")
        let a = get(f, "Obscure Band", "Obscure Record")
        expect(a == img, "found via MusicBrainz + Cover Art Archive")
        let urls = http.urls()
        expect(urls.contains { $0.contains("musicbrainz.org") && $0.contains("fmt=json") }, "\(urls)")
        expect(!urls.contains { $0.contains("bbbb-2222") }, "a wrong release is never tried")
        expect(http.requests.filter { $0.url?.host == "musicbrainz.org" }.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent")?.contains("Aureon") == true })
        let q = http.requests.first { $0.url?.host == "musicbrainz.org" }?.url?.absoluteString.removingPercentEncoding ?? ""
        expect(q.contains("release:\"Obscure Record\" AND artist:\"Obscure Band\""), "Lucene query is quoted: \(q)")
    }

    func rejectsWrongMatchesAndRemembersNothingFound() {
        let http = StubHTTP()
        http.on("itunes.apple.com/search", itunesJSON([("Greatest Hits", "Wrong Artist")]))
        http.on("musicbrainz.org/ws/2/release", "{\"releases\":[]}")
        let f = fetcher(http, name: "none")
        expect(get(f, "Real Artist", "Greatest Hits") == nil, "a same-named album by someone else is not accepted")
        let n = http.count
        expect(n >= 2)
        expect(get(f, "Real Artist", "Greatest Hits") == nil)
        expect(http.count == n, "\"nothing found\" is remembered: no second lookup")
        expect(get(f, "x", "  ") == nil && http.count == n, "an empty album name asks nobody")
    }

    func offlineIsNotRemembered() {
        final class Flaky: HTTPClient, @unchecked Sendable {
            let lock = NSLock(); var down = true; var hits = 0; let img: Data
            init(_ i: Data) { img = i }
            func send(_ r: URLRequest) async throws -> (Data, Int) {
                lock.lock(); hits += 1; let d = down; lock.unlock()
                if d { throw URLError(.notConnectedToInternet) }
                let u = r.url!.absoluteString
                if u.contains("itunes.apple.com/search") { return (Data("{\"results\":[{\"collectionName\":\"Album\",\"artistName\":\"Band\",\"artworkUrl100\":\"https://x.mzstatic.com/100x100bb.jpg\"}]}".utf8), 200) }
                return (img, 200)
            }
        }
        let flaky = Flaky(testPNG(500, 500))
        let d = dir.appendingPathComponent("flaky"); try? FileManager.default.removeItem(at: d)
        let f = ArtworkFetcher(http: flaky, directory: d, musicBrainzInterval: 0.01)
        expect(get(f, "Band", "Album") == nil, "offline → nil, no crash")
        flaky.lock.lock(); flaky.down = false; flaky.lock.unlock()
        expect(get(f, "Band", "Album") != nil, "works as soon as the network is back: failure was not cached")
    }

    func concurrentRequestsForOneAlbumShareOneLookup() {
        let http = StubHTTP(); let img = testPNG(700, 700)
        http.on("itunes.apple.com/search", itunesJSON([("Album", "Band")]))
        http.on("mzstatic.com", [(img, 200)])
        let f = fetcher(http, name: "dedupe")
        let results: [Data?] = (try? runAsync { await withTaskGroup(of: Data?.self) { g in
            for _ in 0..<12 { g.addTask { await f.cover(artist: "Band", album: "Album") } }
            var out: [Data?] = []; for await r in g { out.append(r) }; return out
        } }.get()) ?? []
        expect(results.count == 12 && results.allSatisfy { $0 == img })
        expect(http.urls().filter { $0.contains("itunes.apple.com/search") }.count == 1, "twelve tracks of one album cause one search: \(http.urls())")
    }

    func tooSmallImagesAreSkipped() {
        let http = StubHTTP()
        http.on("itunes.apple.com/search", itunesJSON([("Album", "Band")]))
        http.on("mzstatic.com", [(testPNG(64, 64), 200)])
        http.on("musicbrainz.org", "{\"releases\":[]}")
        let f = fetcher(http, name: "small")
        expect(get(f, "Band", "Album") == nil, "a 64 px thumbnail is not good enough")
    }
}

extension ArtworkMatch { static func key_equalForCosmeticChanges() -> Bool {
    ArtworkFetcher.key(artist: "Miles Davis", album: "Kind of Blue") == ArtworkFetcher.key(artist: "miles  davis", album: "Kind Of Blue (Remastered)")
        && ArtworkFetcher.key(artist: "Miles Davis", album: "A") != ArtworkFetcher.key(artist: "Miles Davis", album: "B")
} }

struct InterfaceTests {
    func paletteFollowsTheCover() {
        let png = testPNG(300, 300, left: NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1), right: NSColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        let cg = ImageTools.cgImage(png, maxPixel: 300)!
        let p = ArtPalette.extract(from: cg)
        expect(p.grid.count == 9)
        expect(p.grid[0].r > p.grid[0].b && p.grid[3].r > p.grid[3].b && p.grid[6].r > p.grid[6].b, "left column is red")
        expect(p.grid[2].b > p.grid[2].r && p.grid[5].b > p.grid[5].r && p.grid[8].b > p.grid[8].r, "right column is blue")
        expect(p.grid.allSatisfy { $0.hsb.v >= 0.23 && $0.hsb.v <= 0.79 }, "tuned for use behind white text")
        expect(p.accent.hsb.v >= 0.8, "the accent is bright enough for a dark background")
        // a top/bottom split must not be flipped
        let ctx = CGContext(data: nil, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.green.cgColor); ctx.fill(CGRect(x: 0, y: 30, width: 60, height: 30))        // CoreGraphics y grows upwards: this is the TOP half
        ctx.setFillColor(NSColor.magenta.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 30))
        let q = ArtPalette.extract(from: ctx.makeImage()!)
        expect(q.grid[1].g > q.grid[1].r && q.grid[7].r > q.grid[7].g, "row 0 is the top of the picture")
    }

    func greyAndTinyImagesAreSafe() {
        let grey = ArtPalette.extract(from: ImageTools.cgImage(testPNG(8, 8, left: .gray, right: .gray), maxPixel: 8)!)
        expect(grey.grid.allSatisfy { $0.hsb.s < 0.15 }, "grey art stays grey instead of turning garish")
        expect(ArtPalette.fallback(seed: "Kind of Blue") == ArtPalette.fallback(seed: "Kind of Blue") && ArtPalette.fallback(seed: "A") != ArtPalette.fallback(seed: "B"))
        expect(ArtPalette.fallback(seed: "").grid.count == 9)
    }

    func signalPathStations() {
        var s = PlayerStatus()
        expect(SignalPath.nodes(s).isEmpty, "nothing playing: no path")
        s.sourceInfo = StreamInfo(sampleRate: 44_100, channels: 2, sourceBits: 16, totalFrames: 1000, codec: "FLAC")
        s.info = StreamInfo(sampleRate: 96_000, channels: 2, sourceBits: 16, totalFrames: 2000, codec: "FLAC", transparent: false)
        s.pipeline = ["RAM: preloaded, no disk reads", "Upsampling 44100 → 96000 Hz (linear phase)", "ReplayGain -3.2 dB"]
        s.rtStages = ["Room correction: room.wav", "Crossfeed BS2B 700 Hz", "Headphone EQ: HD 650"]
        s.dspSummary = "Parametric EQ"; s.deviceName = "Test DAC"; s.bufferedSeconds = 4.2; s.replayGainDB = -3.2
        let n = SignalPath.nodes(s)
        expect(n.map(\.title) == ["FLAC", "Decoder", "RAM", "Resampler", "Level", "Ring buffer", "Room", "Crossfeed", "AutoEQ", "DSP", "Test DAC"], "\(n.map(\.title))")
        expect(n.first?.kind == .source && n.last?.kind == .output)
        expect(n.filter(\.alters).map(\.title) == ["Resampler", "Level", "Room", "Crossfeed", "AutoEQ", "DSP"], "only sample-changing stations are flagged")
        expect(n.first { $0.id == "buffer" }?.subtitle == "4.2 s ahead")
        // a transparent DoP chain has no altering station
        var d = PlayerStatus()
        d.sourceInfo = StreamInfo(sampleRate: 2_822_400, channels: 2, sourceBits: 1, totalFrames: 10, codec: "DSD")
        d.info = StreamInfo(sampleRate: 176_400, channels: 2, sourceBits: 24, totalFrames: 10, codec: "DoP", isDoP: true)
        d.pipeline = ["DSD → DoP at 176400 Hz (DSD bits untouched)", "Upsampling, ReplayGain and polarity are bypassed for DoP"]; d.deviceName = "DAC"
        let dn = SignalPath.nodes(d)
        expect(dn.map(\.title) == ["DSD", "DSD reader", "DoP", "Ring buffer", "DAC"] && !dn.contains { $0.alters }, "\(dn.map(\.title))")
    }

    func navigationStructure() {
        let cats = Tab.allCases.compactMap(\.libraryCategory)
        expect(Set(cats).count == cats.count, "every library page has its own category")
        expect(Tab.allCases.filter { $0.section == .library }.map(\.rawValue) == ["Liked Songs", "Playlists", "Albums", "Artists", "Songs"] && Tab.allCases.filter { $0.section == .classical }.count == 4)
        expect(Tab.allCases.filter { $0.section == .listen }.map(\.rawValue) == ["Home", "Now Playing", "Search", "Radio", "Podcasts"], "radio and podcasts sit with Now Playing")
        let order = [Tab.Section.listen, .library, .classical, .discover, .sound, .tools].flatMap { sec in Tab.allCases.filter { $0.section == sec }.map(\.rawValue) }
        expect(order.firstIndex(of: "Deep Dive")! < order.firstIndex(of: "Audio")!, "Deep Dive sits above the Sound section")
        expect(Tab.allCases.filter { $0.section == .tools }.map(\.rawValue) == ["Rip CD", "Convert", "Cloud"], "ripping and converting live under Tools")
        expect(Tab.settings.section == .footer && Tab.allCases.filter { $0.section == .footer } == [.settings], "Settings lives at the foot of the sidebar")
        expect(SettingsSection.allCases.map(\.rawValue) == ["General", "Connect", "System"], "Connect and System moved into Settings")
        expect(Tab.search.libraryCategory == nil && Tab.player.libraryCategory == nil && Tab.audio.libraryCategory == nil)
        expect(Set(Tab.allCases.map(\.icon)).count == Tab.allCases.count, "no two destinations share an icon")
        expect(Set(Tab.allCases.map(\.rawValue)).count == Tab.allCases.count)
        expect(Set(LibraryModel.Category.allCases) == Set(cats), "every category is reachable from the sidebar")
    }

    func liveStationsInTheSignalPath() {
        var s = PlayerStatus()
        s.sourceInfo = StreamInfo(sampleRate: 44_100, channels: 2, sourceBits: 16, totalFrames: 1, codec: "AAC (lossy)", transparent: false, isLive: true)
        s.info = StreamInfo(sampleRate: 176_400, channels: 2, sourceBits: 16, totalFrames: 1, codec: "AAC (lossy)", transparent: false, isLive: true)
        s.pipeline = ["Internet radio: AAC, 96 kbps, lossy", "Resample 44100 → 176400 Hz, linear phase, 144 dB stop-band"]
        s.deviceName = "DAC"
        let n = SignalPath.nodes(s)
        expect(n.map(\.title) == ["AAC", "Stream decoder", "Resampler", "Ring buffer", "DAC"], "\(n.map(\.title))")
        expect(n[0].subtitle == "Live · 44.1 kHz" && n[0].alters, "a lossy live source is flagged as altering from the start")
        expect(n[2].subtitle == "→ 176.4 kHz")
    }

    func navigationHistory() {
        MainActor.assumeIsolated {
        let nav = Navigator()
        expect(!nav.canGoBack && !nav.canGoForward)
        var visited: [Place] = []
        nav.restore = { visited.append($0) }
        nav.visit(Place(tab: .albums)); nav.visit(Place(tab: .albums, library: "a1")); nav.visit(Place(tab: .radio, radio: "By genre|jazz"))
        expect(nav.canGoBack && !nav.canGoForward)
        nav.visit(Place(tab: .radio, radio: "By genre|jazz"))
        nav.goBack()
        expect(visited.last == Place(tab: .albums, library: "a1") && nav.canGoForward, "Back returns to the album page, \(String(describing: visited.last))")
        nav.goBack(); nav.goBack()
        expect(visited.last == Place(tab: .player) && !nav.canGoBack, "back to the start")
        nav.goBack()
        expect(visited.count == 3, "Back at the start does nothing")
        nav.goForward()
        expect(visited.last == Place(tab: .albums) && nav.canGoForward && nav.canGoBack)
        nav.visit(Place(tab: .songs))
        expect(!nav.canGoForward, "a new destination discards the forward trail")
        // visits made while a step is being applied (the interface restoring itself) must not be recorded
        let n2 = Navigator()
        n2.visit(Place(tab: .albums)); n2.visit(Place(tab: .artists))
        n2.restore = { p in n2.visit(Place(tab: .songs)); _ = p }
        n2.goBack()
        n2.restore = nil
        n2.goForward()
        expect(n2.current == Place(tab: .artists), "history stays consistent: \(n2.current)")
        }
    }

    func playheadChangesDoNotRepublish() {
        var a = PlayerStatus(); a.state = .playing; a.deviceName = "DAC"; a.position = 1; a.bufferedSeconds = 2.0
        var b = a; b.position = 1.1; b.bufferedSeconds = 2.2
        expect(a.sameStructure(as: b), "the playhead and a small buffer change are not structural")
        b.bufferedSeconds = 3.1
        expect(!a.sameStructure(as: b), "a half-second change in the buffer is")
        var c = a; c.position = 5; c.state = .paused
        expect(!a.sameStructure(as: c))
        var d = a; d.live = LiveMetadata.Snapshot(station: "x", title: "New song", bitrate: 96, codec: "AAC", genre: nil)
        expect(!a.sameStructure(as: d), "a new radio title must reach the interface")
        var e = a; e.underruns = 1
        expect(!a.sameStructure(as: e))
    }

    func sortingFilteringAndGrouping() {
        func album(_ t: String, _ artist: String, _ year: Int, rate: Double, bits: Int, added: Double, tracks: Int = 5) -> ReleaseDTO {
            ReleaseDTO(id: t, title: t, year: year, trackCount: tracks, artistNames: [artist], mbReleaseID: nil, maxSampleRate: rate, maxBitDepth: bits, genre: nil, addedAt: added)
        }
        let a = [album("Écume", "Zed", 2001, rate: 44_100, bits: 16, added: 3), album("alpha", "Mia", 1999, rate: 96_000, bits: 24, added: 1, tracks: 12), album("Beta", "Abe", 2010, rate: 2_822_400, bits: 1, added: 2)]
        var o = ViewOptions()
        expect(LibraryOrdering.albums(a, o).map(\.title) == ["alpha", "Beta", "Écume"], "title order folds case and accents")
        o.ascending = false; expect(LibraryOrdering.albums(a, o).map(\.title) == ["Écume", "Beta", "alpha"])
        o = ViewOptions(); o.sort = .artist; expect(LibraryOrdering.albums(a, o).map(\.title) == ["Beta", "alpha", "Écume"])
        o.sort = .year; expect(LibraryOrdering.albums(a, o).map(\.title) == ["alpha", "Écume", "Beta"])
        o.sort = .added; o.ascending = false; expect(LibraryOrdering.albums(a, o).map(\.title) == ["Écume", "Beta", "alpha"], "recently added first")
        o.sort = .count; o.ascending = false; expect(LibraryOrdering.albums(a, o).first?.title == "alpha")
        o = ViewOptions(); o.quality = .hiRes; expect(LibraryOrdering.albums(a, o).map(\.title) == ["alpha"], "Hi-Res excludes DSD and CD")
        o.quality = .dsd; expect(LibraryOrdering.albums(a, o).map(\.title) == ["Beta"])
        o.quality = .cd; expect(LibraryOrdering.albums(a, o).map(\.title) == ["Écume"])
        func song(_ t: String, _ artist: String, _ album: String, _ dur: Double, rate: Double = 44_100, bits: Int = 16) -> TrackDTO {
            TrackDTO(id: t, path: "/\(t)", title: t, trackNumber: nil, discNumber: nil, duration: dur, codec: "FLAC", sampleRate: rate, bitDepth: bits, channels: 2, year: nil, releaseID: nil, releaseTitle: album,
                     workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil, credits: [CreditDTO(role: "artist", name: artist, instrument: nil, partyID: artist)], genres: [], mbRecordingID: nil)
        }
        let s = [song("b", "Y", "A2", 200), song("a", "Z", "A1", 100, rate: 192_000, bits: 24), song("c", "X", "A3", 300)]
        o = ViewOptions(); expect(LibraryOrdering.songs(s, o).map(\.title) == ["a", "b", "c"])
        o.sort = .artist; expect(LibraryOrdering.songs(s, o).map(\.title) == ["c", "b", "a"])
        o.sort = .album; expect(LibraryOrdering.songs(s, o).map(\.title) == ["a", "b", "c"])
        o.sort = .duration; o.ascending = false; expect(LibraryOrdering.songs(s, o).map(\.title) == ["c", "b", "a"])
        o = ViewOptions(); o.sort = .quality; o.ascending = false; expect(LibraryOrdering.songs(s, o).first?.title == "a")
        o = ViewOptions(); o.quality = .hiRes; expect(LibraryOrdering.songs(s, o).map(\.title) == ["a"])
        let rows = [LibraryModel.Row(id: "1", title: "Zoë", subtitle: "", count: 3), LibraryModel.Row(id: "2", title: "Ábel", subtitle: "", count: 9), LibraryModel.Row(id: "3", title: "123 Band", subtitle: "", count: 1)]
        expect(LibraryOrdering.rows(rows, ViewOptions()).map(\.title) == ["123 Band", "Ábel", "Zoë"])
        var by = ViewOptions(); by.sort = .count; by.ascending = false
        expect(LibraryOrdering.rows(rows, by).map(\.title) == ["Ábel", "Zoë", "123 Band"])
        let g = LibraryOrdering.grouped(LibraryOrdering.rows(rows, ViewOptions()), title: \.title)
        expect(g.map(\.letter) == ["#", "A", "Z"] && LibraryOrdering.letter("éclair") == "E" && LibraryOrdering.letter("日本") == "#" && LibraryOrdering.letter("") == "#", "\(g.map(\.letter))")
        expect(ViewOptions.defaults(for: .songs).list && !ViewOptions.defaults(for: .albums).list)
        expect(ViewOptions.available(for: .albums).contains(.added) && ViewOptions.available(for: .songs).contains(.quality) && ViewOptions.available(for: .composers) == [.title, .count])
        expect((try? JSONDecoder().decode(ViewOptions.self, from: JSONEncoder().encode(by))) == by, "options persist as JSON")
    }

    func volumeSliderCannotJump() {
        // the original bug: the volume showed 100 % and a click anywhere near the end set it to 100 %
        let current = 0.20
        // pressing never changes the value; only movement does, by the distance moved, from wherever the press was
        expect(SliderDrag.relative(start: current, dx: 0) == current, "a press alone changes nothing")
        expect(abs(SliderDrag.relative(start: current, dx: 0.15) - 0.35) < 1e-9, "dragging right by 15 % of the track adds 15 %")
        expect(abs(SliderDrag.relative(start: current, dx: -0.05) - 0.15) < 1e-9)
        expect(SliderDrag.relative(start: current, dx: 5) == 1 && SliderDrag.relative(start: current, dx: -5) == 0, "clamped at the ends")
        // the second bug: dragging stopped after a short distance. A long drag from anywhere keeps following the pointer
        var v = current
        for i in 1...40 { v = SliderDrag.relative(start: current, dx: Double(i) * 0.01) }
        expect(abs(v - 0.60) < 1e-9, "a long continuous drag keeps going: \(v)")
        // a click without movement nudges toward the press by one step at most
        expect(abs(SliderDrag.clickNudge(current: current, press: 0.97, step: 0.04) - 0.24) < 1e-9, "a click near the far end moves 4 %, not to 97 %")
        expect(abs(SliderDrag.clickNudge(current: 0.5, press: 0.0, step: 0.04) - 0.46) < 1e-9)
        expect(SliderDrag.clickNudge(current: 0.99, press: 1, step: 0.04) == 1 && SliderDrag.clickNudge(current: 0.5, press: 0.51, step: 0.04) == 0.51, "a click right next to the knob lands there")
        var x = 0.0
        for _ in 0..<5 { x = SliderDrag.clickNudge(current: x, press: 1, step: 0.04) }
        expect(abs(x - 0.20) < 1e-9, "five stray clicks at the far end give 20 %, not 100 %: \(x)")
    }

    func scrollWheelSteps() {
        expect(ScrollStep.notches(deltaY: 3, precise: false) == 3 && abs(ScrollStep.notches(deltaY: 28, precise: true) - 2) < 1e-9, "a wheel click is one unit; a trackpad needs ~14 points")
        let r = 0.0...100.0
        expect(abs(ScrollStep.apply(value: 50, notches: 1, range: r) - 52) < 1e-9, "one click moves 2 % of the range")
        expect(abs(ScrollStep.apply(value: 50, notches: -3, range: r) - 44) < 1e-9)
        expect(ScrollStep.apply(value: 99, notches: 5, range: r) == 100 && ScrollStep.apply(value: 1, notches: -5, range: r) == 0, "clamped")
        expect(abs(ScrollStep.apply(value: 50, notches: 100, range: r, perNotch: 0.01, maxMove: 0.03) - 53) < 1e-9, "a fling can never move a guarded slider more than 3 % in one event")
        expect(ScrollStep.apply(value: 5, notches: .nan, range: r) == 5 && ScrollStep.apply(value: 5, notches: 1, range: 3...3) == 5, "degenerate input is ignored")
        expect(abs(ScrollStep.apply(value: 0.3, notches: 1, range: -26...6, perNotch: 0.03) - (0.3 + 0.96)) < 1e-9, "works on any range")
    }

    func qualityTiers() {
        func tier(_ r: Double, _ b: Int) -> QualityTier { qualityTier(StreamInfo(sampleRate: r, channels: 2, sourceBits: b, totalFrames: 1, codec: "FLAC")) }
        expect(tier(44_100, 16).name == "CD quality" && !tier(44_100, 16).hiRes)
        expect(tier(44_100, 24).hiRes && tier(96_000, 16).hiRes && tier(192_000, 24).name == "Hi-Res")
        expect(tier(48_000, 16).name == "Lossless")
    }
}

struct ArtistImageTests {
    let dir = tempDir("artistimg")

    private func fetcher(_ http: StubHTTP, _ name: String) -> ArtistImageFetcher {
        let d = dir.appendingPathComponent(name); try? FileManager.default.removeItem(at: d)
        return ArtistImageFetcher(http: http, directory: d, wikipedia: WikipediaClient(http: http, cache: MetadataCache(directory: dir.appendingPathComponent(name + "-wiki"))))
    }
    private func get(_ f: ArtistImageFetcher, _ n: String) -> Data? { ((try? runAsync { await f.image(for: n) }.get()) ?? nil) }

    func deezerParsing() {
        let json = "{\"data\":[{\"name\":\"Drake\",\"nb_fan\":900,\"picture_xl\":\"https://cdn/drake_big.jpg\"},{\"name\":\"Drake Bell\",\"nb_fan\":50000,\"picture_xl\":\"https://cdn/bell.jpg\"},{\"name\":\"drake\",\"nb_fan\":10,\"picture_xl\":\"https://cdn/fake.jpg\"},{\"name\":\"Drake\",\"nb_fan\":5000,\"picture_xl\":\"https://cdn/images/artist//1000x1000-000000-80-0-0.jpg\"}]}"
        expect(ArtistImageFetcher.parseDeezer(Data(json.utf8), wanted: "Drake") == "https://cdn/drake_big.jpg", "exact name, most followers, and never Deezer's blank placeholder")
        expect(ArtistImageFetcher.parseDeezer(Data(json.utf8), wanted: "Nobody") == nil)
        expect(ArtistImageFetcher.parseDeezer(Data("x".utf8), wanted: "Drake") == nil)
    }

    func portraitFromDeezerThenCache() {
        let http = StubHTTP(); let img = testPNG(1000, 1000)
        http.on("api.deezer.com/search/artist", "{\"data\":[{\"name\":\"Miles Davis\",\"nb_fan\":100,\"picture_xl\":\"https://cdn-images.dzcdn.net/miles.jpg\"}]}")
        http.on("dzcdn.net/miles.jpg", [(img, 200)])
        let f = fetcher(http, "dz")
        expect(get(f, "Miles Davis") == img)
        expect(http.urls().first?.contains("q=Miles%20Davis") == true && http.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Aureon/") == true })
        let n = http.count
        expect(get(f, "miles  davis") == img && http.count == n, "served from the cache, whatever the spelling of the key")
        expect(get(f, "Various Artists") == nil && get(f, "  ") == nil && http.count == n, "compilation placeholders are never looked up")
    }

    func wikipediaIsTheSecondChoice() {
        let http = StubHTTP(); let img = testPNG(600, 600)
        http.on("api.deezer.com", "{\"data\":[]}")
        http.on("wikipedia.org/api/rest_v1/page/summary/Ensemble_Nord", "{\"title\":\"Ensemble Nord\",\"description\":\"Norwegian chamber orchestra\",\"extract\":\"Ensemble Nord is a chamber orchestra.\",\"thumbnail\":{\"source\":\"https://upload.wikimedia.org/nord.jpg\"}}")
        http.on("wikimedia.org/nord.jpg", [(img, 200)])
        http.on("wikipedia.org/api/rest_v1/page/summary/Mercury", "{\"title\":\"Mercury\",\"description\":\"Chemical element\",\"extract\":\"Mercury is a planet.\",\"thumbnail\":{\"source\":\"https://upload.wikimedia.org/hg.jpg\"}}")
        http.on("wikimedia.org/hg.jpg", [(img, 200)])
        let f = fetcher(http, "wk")
        expect(get(f, "Ensemble Nord") == img, "found through Wikipedia")
        expect(get(f, "Mercury") == nil, "an article that is not about a musician is not used")
    }

    func missingAndOfflineAreHandled() {
        let none = StubHTTP()
        none.on("api.deezer.com", "{\"data\":[]}")
        let f = fetcher(none, "none")
        expect(get(f, "Unknown Person") == nil)
        let n = none.count
        expect(get(f, "Unknown Person") == nil && none.count == n, "\"no portrait\" is remembered")
        final class Down: HTTPClient { func send(_ r: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) } }
        let d = dir.appendingPathComponent("down"); try? FileManager.default.removeItem(at: d)
        let off = ArtistImageFetcher(http: Down(), directory: d)
        expect(get(off, "Someone") == nil)
        let up = StubHTTP(); let img = testPNG(500, 500)
        up.on("api.deezer.com", "{\"data\":[{\"name\":\"Someone\",\"nb_fan\":1,\"picture_xl\":\"https://cdn/s.jpg\"}]}"); up.on("cdn/s.jpg", [(img, 200)])
        let back = ArtistImageFetcher(http: up, directory: d)
        expect(get(back, "Someone") == img, "being offline once is not remembered as \"no portrait\"")
        expect(get(fetcher(StubHTTP(), "tiny"), "x") == nil)
        let small = StubHTTP(); small.on("api.deezer.com", "{\"data\":[{\"name\":\"Tiny\",\"nb_fan\":1,\"picture_xl\":\"https://cdn/t.jpg\"}]}"); small.on("cdn/t.jpg", [(testPNG(60, 60), 200)])
        expect(get(fetcher(small, "small"), "Tiny") == nil, "a thumbnail-sized image is not a portrait")
    }

    func mosaicLayouts() {
        let red = ImageTools.cgImage(testPNG(300, 300, left: .red, right: .red), maxPixel: 300)!
        let blue = ImageTools.cgImage(testPNG(300, 300, left: .blue, right: .blue), maxPixel: 300)!
        let green = ImageTools.cgImage(testPNG(300, 300, left: .green, right: .green), maxPixel: 300)!
        expect(ArtistMosaic.render([]) == nil)
        func color(_ img: NSImage, _ fx: Double, _ fy: Double) -> (r: Double, g: Double, b: Double) {
            let rep = NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            let c = rep.colorAt(x: Int(Double(rep.pixelsWide - 1) * fx), y: Int(Double(rep.pixelsHigh - 1) * fy))!.usingColorSpace(.sRGB)!
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        let one = ArtistMosaic.render([red])!
        expect(color(one, 0.1, 0.1).r > 0.8 && color(one, 0.9, 0.9).r > 0.8, "one cover fills the frame")
        let four = ArtistMosaic.render([red, blue, green, red, blue])!
        expect(color(four, 0.2, 0.2).r > 0.8 && color(four, 0.8, 0.2).b > 0.8 && color(four, 0.2, 0.8).g > 0.8 && color(four, 0.8, 0.8).r > 0.8, "four covers in reading order, a fifth is ignored")
        let two = ArtistMosaic.render([red, blue])!
        expect(color(two, 0.2, 0.5).r > 0.8 && color(two, 0.8, 0.5).b > 0.8, "two covers side by side")
        let three = ArtistMosaic.render([red, blue, green])!
        expect(color(three, 0.2, 0.5).r > 0.8 && color(three, 0.8, 0.2).b > 0.8 && color(three, 0.8, 0.8).g > 0.8)
    }
}

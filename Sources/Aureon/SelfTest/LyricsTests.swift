import Foundation
import SwiftUI
import AppKit

// Lyrics: the LRC reader and writer, ID3 USLT/SYLT, files and tags, LRCLIB, the cache, the speech-model pipeline and the service that ties them
// together. All text in these fixtures is made up.

/// A speech model stand-in: returns a canned transcription, can be slow, and counts what happens to it.
final class ScriptedTranscriber: LyricsTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0, cancels = 0, unloads = 0
    private(set) var lastModel: WhisperModelSize?, lastLanguage: String?
    private var cancelled = false
    var result = Transcription(segments: [], language: "en", model: .base)
    var duration: TimeInterval = 0
    var error: Error?
    var onFinish: (() -> Void)?

    func transcribe(audio: URL, model: WhisperModelSize, language: String?, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcription {
        lock.lock(); calls += 1; lastModel = model; lastLanguage = language; cancelled = false; lock.unlock()
        progress(0.3, "Listening to the song")
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            lock.lock(); let c = cancelled; lock.unlock()
            if c { throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if let error { throw error }
        onFinish?()
        var r = result; r.model = model
        return r
    }
    func cancel() { lock.lock(); cancels += 1; cancelled = true; lock.unlock() }
    func unload() async { lock.lock(); unloads += 1; lock.unlock() }
}

final class DownHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) { lock.lock(); count += 1; lock.unlock(); throw URLError(.notConnectedToInternet) }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

struct LyricsTests {
    private func fresh(_ name: String) -> URL {
        let d = tempDir("lyrics").appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func near(_ a: Double, _ b: Double, _ tol: Double = 0.002) -> Bool { abs(a - b) <= tol }

    private let sampleLRC = "[00:05.00]Alpha beta gamma\n[00:10.00]Delta epsilon\n[00:20.00]Zeta eta theta\n[00:30.50]Iota kappa\n"

    // MARK: - LRC

    func lrcTimestamps() {
        expect(LRCParser.timestamp("00:12.00") == 12 && LRCParser.timestamp("1:02.5") == 62.5, "mm:ss.xx")
        expect(LRCParser.timestamp("00:12:50") == 12.5, "the older mm:ss:xx")
        expect(LRCParser.timestamp("01:02:03.5") == 3723.5, "h:mm:ss.x")
        expect(near(LRCParser.timestamp("00:01.123") ?? -1, 1.123, 0.0001), "milliseconds")
        for bad in ["ar:Name", "00:12.5x", "12", "-1:00", "", "00:", ":10", "1:2:3:4", "00:123"] { expect(LRCParser.timestamp(bad) == nil, "“\(bad)” is not a timestamp") }
    }

    func lrcParsing() {
        let text = "\u{FEFF}[ti:Made Up]\r\n[ar:Nobody]\r\n[al:Nothing]\r\n[offset:+500]\r\n[00:12.00]First line\r\n[00:17.50] Second line \r\n[00:20.5][01:00.25]Refrain\r\n[01:05]\r\n[01:10.123]Last one\r\n"
        guard let l = LRCParser.parse(text) else { expect(false, "parses"); return }
        expect(l.synced && l.origin == .sidecar, "synced")
        expect(l.title == "Made Up" && l.artist == "Nobody" && l.album == "Nothing", "header tags")
        expect(l.lines.count == 6, "\(l.lines.count) lines")
        // [offset:+500] shows every line half a second sooner
        let times = l.lines.map(\.time)
        for (a, b) in zip(times, [11.5, 17.0, 20.0, 59.75, 64.5, 69.623]) { expect(near(a, b), "time \(a) vs \(b)") }
        expect(l.lines[1].text == "Second line", "text is trimmed")
        expect(l.lines[2].text == "Refrain" && l.lines[3].text == "Refrain", "a line with two stamps appears twice")
        expect(l.lines[4].isBreak, "an empty stamped line is an instrumental break")
        expect(l.lines.map(\.id) == Array(0..<6), "ids follow the order")
        expect(LRCParser.looksSynced(sampleLRC) && !LRCParser.looksSynced("[00:01.00]only one") && !LRCParser.looksSynced("just words"), "looksSynced")

        // equal times keep file order; a negative result is clamped
        let tie = LRCParser.parse("[offset:5000]\n[00:03.00]one\n[00:03.00]two\n[00:08.00]three")!
        expect(tie.lines.map(\.text) == ["one", "two", "three"] && tie.lines[0].time == 0, "stable order, clamped at zero")
        // [offset] with a minus shows lines later
        let late = LRCParser.parse("[offset:-1000]\n[00:03.00]one\n[00:08.00]two")!
        expect(near(late.lines[0].time, 4), "negative offset delays")
    }

    func lrcWords() {
        let l = LRCParser.parse("[00:10.00]<00:10.00>Hello <00:10.50>made <00:11.00>up\n[00:14.00]<chorus>plain <00:14.50>tail")!
        expect(l.lines[0].text == "Hello made up" && l.lines[0].words.count == 3, "\(l.lines[0])")
        expect(l.lines[0].words.map(\.start) == [10, 10.5, 11] && l.lines[0].words[0].text == "Hello " && l.lines[0].words[2].text == "up", "word times and spacing")
        expect(l.wordSynced, "word-synced")
        expect(l.lines[1].text.contains("<chorus>") && l.lines[1].words.count == 1, "only valid time tags are word tags: \(l.lines[1])")
    }

    func lrcPlainText() {
        let p = LRCParser.parse("[ti:Placeholder]\nLine one\nLine two\n\n\n\nLine three\n")!
        expect(!p.synced && p.lines.map(\.text) == ["Line one", "Line two", "", "Line three"] && p.title == "Placeholder", "\(p.lines.map(\.text))")
        expect(p.plainText == "Line one\nLine two\n\nLine three" && p.activeIndex(at: 10) == nil, "plain text has no active line")
        expect(!LRCParser.parse("[00:05.00]single\nplain")!.synced, "one stamp is not enough to call it synced")
        expect(LRCParser.parse("") == nil && LRCParser.parse("\n\n") == nil && LRCParser.parse("[00:01.00]\n[00:02.00]") == nil, "nothing to show")
    }

    func lrcWriting() {
        expect(Lyrics.stamp(0) == "00:00.00" && Lyrics.stamp(61.999) == "01:02.00" && Lyrics.stamp(600) == "10:00.00" && Lyrics.stamp(3599.994) == "59:59.99" && Lyrics.stamp(-3) == "00:00.00", "stamps")
        var l = LRCParser.parse("[00:10.00]<00:10.00>Hello <00:10.50>there\n[00:15.25]Second\n[00:20.00]\n[00:25.00]Third")!
        l.title = "Made Up"; l.artist = "Nobody"
        let text = l.lrc()
        let back = LRCParser.parse(text)!
        expect(back.title == "Made Up" && back.artist == "Nobody" && back.lines.count == l.lines.count, "round trip keeps the header and lines")
        for (a, b) in zip(l.lines, back.lines) { expect(near(a.time, b.time, 0.011) && a.text == b.text && a.words.count == b.words.count, "line \(a) vs \(b)") }
        expect(!l.lrc(words: false).contains("<"), "no word tags on request")
        l.origin = .generated; l.source = "Whisper base"
        expect(l.lrc().contains("[by:Aureon · Whisper base]"), "generated lyrics say so")
        let plain = LRCParser.parse("one\ntwo")!
        expect(plain.lrc() == "one\ntwo", "plain lyrics stay plain")
    }

    func lrcCursor() {
        let l = LRCParser.parse("[00:05.00]a\n[00:10.00]b\n[00:10.00]c\n[00:20.00]d")!
        expect(l.activeIndex(at: 0) == nil && l.activeIndex(at: 4.99) == nil, "before the first line")
        expect(l.activeIndex(at: 5) == 0 && l.activeIndex(at: 9.99) == 0 && l.activeIndex(at: 10) == 2 && l.activeIndex(at: 19) == 2 && l.activeIndex(at: 500) == 3, "binary search")
        expect(l.end(ofLine: 0) == 10 && l.end(ofLine: 1) == 20 && l.end(ofLine: 3) == 26 && l.end(ofLine: 99) == 0, "line ends")
        let w = LRCParser.parse("[00:10.00]<00:10.00>x <00:10.50>y <00:11.00>z\n[00:12.00]next")!
        expect(w.wordEnds(ofLine: 0) == [10.5, 11, 12], "word ends: \(w.wordEnds(ofLine: 0))")
        let big = LRCParser.parse((0..<5000).map { "[\(String(format: "%02d:%02d.00", $0 / 60, $0 % 60))]line \($0)" }.joined(separator: "\n"))!
        expect(big.activeIndex(at: 1234.5) == 1234, "long lyrics")
    }

    func playheadClock() {
        let c = PlayheadClock()
        c.set(position: 10, playing: false)
        usleep(60_000)
        expect(c.now() == 10, "paused: the clock stands still")
        c.set(position: 10, playing: true)
        usleep(80_000)
        let t = c.now()
        expect(t > 10.05 && t < 10.5, "playing: extended by the wall clock: \(t)")
    }

    @MainActor func cursorPublishesLineChangesOnly() {
        let l = LRCParser.parse(sampleLRC)!
        let cur = LyricsCursor()
        var changes = 0
        let sub = cur.$active.dropFirst().sink { _ in changes += 1 }
        for p in stride(from: 0.0, to: 9.9, by: 0.033) { cur.update(position: p, playing: true, lyrics: l) }
        expect(changes == 1 && cur.active == 0, "thirty updates a second, one change: \(changes)")
        cur.update(position: 12, playing: true, lyrics: l)
        expect(cur.active == 1 && cur.isPlaying, "next line")
        cur.update(position: 12, playing: false, lyrics: l)
        expect(!cur.isPlaying, "paused")
        sub.cancel()
    }

    // MARK: - ID3

    private func tag24(_ frames: [(String, Data)]) -> Data {
        let body = frames.reduce(Data()) { $0 + ID3TagEditor.frame($1.0, $1.1) } + Data(count: 16)
        return Data("ID3".utf8) + Data([4, 0, 0]) + ID3TagEditor.syncsafe(body.count) + body
    }

    func id3Lyrics() {
        let text = "First made-up line\nSecond made-up line"
        // UTF-8
        var utf8Body = Data([3])
        utf8Body.append(Data("eng".utf8)); utf8Body.append(0); utf8Body.append(Data(text.utf8))
        var tag = ID3v2.parse(tag24([("USLT", utf8Body)]))!
        expect(tag.tags.first("LYRICS") == text, "USLT in UTF-8: \(tag.tags)")
        // Latin-1 with an accent, and a description
        var latin = Data([0])
        for part in [Data("fra".utf8), Data("desc".utf8), Data([0]), Data("Caf".utf8), Data([0xE9]), Data(" ligne".utf8)] { latin.append(part) }
        tag = ID3v2.parse(tag24([("USLT", latin)]))!
        expect(tag.tags.first("LYRICS") == "Café ligne", "Latin-1: \(tag.tags)")
        // UTF-16 with a byte-order mark and an empty description
        var u16 = Data([1])
        for part in [Data("eng".utf8), Data([0, 0]), Data([0xFF, 0xFE]), text.data(using: .utf16LittleEndian) ?? Data()] { u16.append(part) }
        tag = ID3v2.parse(tag24([("USLT", u16)]))!
        expect(tag.tags.first("LYRICS") == text, "UTF-16: \(tag.tags)")
        // ID3v2.2 names the frame ULT
        let body = Data([3]) + Data("eng".utf8) + Data([0]) + Data("old style".utf8)
        let v22frames = Data("ULT".utf8) + Data([0, 0, UInt8(body.count)]) + body + Data(count: 8)
        let v22 = Data("ID3".utf8) + Data([2, 0, 0]) + ID3TagEditor.syncsafe(v22frames.count) + v22frames
        expect(ID3v2.parse(v22)?.tags.first("LYRICS") == "old style", "ULT")

        // SYLT: one line per piece
        func sylt(_ pieces: [(String, Int)], format: UInt8 = 2) -> Data {
            var d = Data([3]) + Data("eng".utf8) + Data([format, 1]) + Data([0])
            for (s, ms) in pieces { d += Data(s.utf8) + Data([0]) + be32(ms) }
            return d
        }
        tag = ID3v2.parse(tag24([("SYLT", sylt([("Alpha line\n", 1000), ("Beta line\n", 5500), ("Gamma", 9000)]))]))!
        let lrc = tag.tags.first("SYNCEDLYRICS") ?? ""
        let parsed = LRCParser.parse(lrc)
        expect(parsed?.synced == true && parsed?.lines.map(\.text) == ["Alpha line", "Beta line", "Gamma"] && near(parsed?.lines[1].time ?? 0, 5.5), "SYLT lines: \(lrc)")
        // SYLT in syllables: a line break ends the line
        tag = ID3v2.parse(tag24([("SYLT", sylt([("Hel", 1000), ("lo ", 1200), ("there\n", 1500), ("Next", 4000)]))]))!
        let syl = LRCParser.parse(tag.tags.first("SYNCEDLYRICS") ?? "")
        expect(syl?.lines.map(\.text) == ["Hello there", "Next"] && syl?.lines[0].words.count == 3, "syllables: \(String(describing: syl?.lines))")
        // timestamps counted in MPEG frames cannot be placed: left out
        tag = ID3v2.parse(tag24([("SYLT", sylt([("Alpha\n", 10), ("Beta\n", 20)], format: 1)), ("TIT2", Data([3]) + Data("T".utf8))]))!
        expect(tag.tags.first("SYNCEDLYRICS") == nil && tag.tags.first("TITLE") == "T", "frame-counted SYLT is ignored, the rest still reads")
        // a damaged frame does not stop the others
        tag = ID3v2.parse(tag24([("USLT", Data([3, 0x65])), ("TIT2", Data([3]) + Data("Still read".utf8))]))!
        expect(tag.tags.first("TITLE") == "Still read" && tag.tags.first("LYRICS") == nil, "damaged USLT")
    }

    // MARK: - Files and tags

    private func req(_ path: String, title: String = "Title", artist: String = "Band") -> LyricsRequest { LyricsRequest(path: path, title: title, artist: artist, album: "Album", duration: 200) }

    func lyricsFiles() {
        let d = fresh("sidecar")
        func put(_ name: String, _ text: String, in dir: URL? = nil) {
            let folder = dir ?? d
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try! Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        let p = d.appendingPathComponent("Song.flac").path
        expect(LocalLyrics.sidecar(for: req(p)) == nil, "nothing there")
        put("Song.lrc", sampleLRC)
        let a = LocalLyrics.sidecar(for: req(p))
        expect(a?.synced == true && a?.source == "Song.lrc" && a?.origin == .sidecar && a?.lines.count == 4, "same name")
        put("Song.txt", "plain words\nmore plain words")
        expect(LocalLyrics.sidecar(for: req(p))?.synced == true, ".lrc comes before .txt")
        try? FileManager.default.removeItem(at: d.appendingPathComponent("Song.lrc"))
        expect(LocalLyrics.sidecar(for: req(p))?.synced == false, ".txt gives plain lyrics")

        // spelled differently: case, track numbers, “Artist - Title”
        let d2 = fresh("loose")
        put("title.LRC", sampleLRC, in: d2)
        expect(LocalLyrics.sidecar(for: req(d2.appendingPathComponent("01 Title.flac").path)) != nil, "track number and case ignored")
        let d3 = fresh("loose2")
        put("Band - Title.lrc", sampleLRC, in: d3)
        expect(LocalLyrics.sidecar(for: req(d3.appendingPathComponent("07 - Something Else.flac").path)) != nil, "Artist - Title matches the tags")
        expect(LocalLyrics.sidecar(for: req(d3.appendingPathComponent("a.flac").path, title: "Unrelated", artist: "Someone")) == nil, "an unrelated name does not match")
        let d4 = fresh("folder")
        put("Song.lrc", sampleLRC, in: d4.appendingPathComponent("Lyrics"))
        expect(LocalLyrics.sidecar(for: req(d4.appendingPathComponent("Song.flac").path)) != nil, "a Lyrics folder")

        // text encodings
        let d5 = fresh("enc")
        let lrcE = "[00:01.00]Caf\u{E9} un\n[00:03.00]deux"
        try! (Data([0xFF, 0xFE]) + lrcE.data(using: .utf16LittleEndian)!).write(to: d5.appendingPathComponent("a.lrc"))
        try! (Data([0xEF, 0xBB, 0xBF]) + Data(lrcE.utf8)).write(to: d5.appendingPathComponent("b.lrc"))
        try! lrcE.data(using: .isoLatin1)!.write(to: d5.appendingPathComponent("c.lrc"))
        for n in ["a", "b", "c"] { expect(LocalLyrics.sidecar(for: req(d5.appendingPathComponent("\(n).flac").path))?.lines.first?.text == "Café un", "encoding of \(n).lrc") }
        // size limits
        let d6 = fresh("big")
        try! Data(repeating: 65, count: LocalLyrics.maxFileBytes + 10).write(to: d6.appendingPathComponent("x.lrc"))
        expect(LocalLyrics.sidecar(for: req(d6.appendingPathComponent("x.flac").path)) == nil, "a huge file is not lyrics")
        put("y.txt", String(repeating: "word ", count: 12_000), in: d6)
        expect(LocalLyrics.sidecar(for: req(d6.appendingPathComponent("y.flac").path)) == nil, "a long text note is not lyrics")
        // remote tracks are not searched
        expect(!req("cloud://x/y.flac").isLocalFile && LocalLyrics.find(req("cloud://x/y.flac")).best == nil, "remote")
        expect(req("/a/b.flac", title: "Né Titre").cacheKey == req("/z/q.flac", title: "ne  titre!").cacheKey, "the cache key ignores accents, case and punctuation")
        expect(["LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS", "LYRICSENG", "LYRIC"].allSatisfy(LocalLyrics.isLyricsKey) && !["LYRICIST", "TITLE", "COMMENT"].contains(where: LocalLyrics.isLyricsKey), "which tags hold lyrics")
    }

    private func flac(_ d: URL, _ name: String = "t.flac") -> String {
        let wav = sineWAV(d.appendingPathComponent(name + ".wav"), rate: 44_100, bits: 16, freq: 440, amp: 0.4, seconds: 1)
        let out = d.appendingPathComponent(name)
        expect(encode(wav, to: out, alac: false), "afconvert makes a FLAC")
        try? FileManager.default.removeItem(at: wav)
        return out.path
    }

    func lyricsInTags() {
        let d = fresh("tags")
        let p = flac(d)
        injectVorbisComments(p, [("TITLE", "Title"), ("LYRICS", sampleLRC), ("LYRICIST", "Someone")])
        var r = LocalLyrics.find(req(p))
        expect(r.synced?.origin == .embedded && r.synced?.lines.count == 4 && r.plain == nil, "LRC in a LYRICS comment is synced lyrics")
        injectVorbisComments(p, [("UNSYNCEDLYRICS", "plain one\nplain two"), ("LYRICIST", "Someone")])
        r = LocalLyrics.find(req(p))
        expect(r.synced == nil && r.plain?.lines.count == 2, "plain lyrics from UNSYNCEDLYRICS, not from LYRICIST")
        // a plain sidecar and synced tags: both are kept, synced is the best
        injectVorbisComments(p, [("LYRICS", sampleLRC)])
        try! Data("plain from a file\nsecond".utf8).write(to: d.appendingPathComponent("t.txt"))
        r = LocalLyrics.find(req(p))
        expect(r.synced?.origin == .embedded && r.plain?.origin == .sidecar && r.best?.synced == true, "best of both")
        // a synced sidecar beats synced tags
        try! Data("[00:01.00]from the file\n[00:02.00]again".utf8).write(to: d.appendingPathComponent("t.lrc"))
        r = LocalLyrics.find(req(p))
        expect(r.synced?.origin == .sidecar, "the sidecar wins")
    }

    func lyricsTagWriting() {
        let d = fresh("write")
        let lrc = LRCParser.parse(sampleLRC)!.lrc()
        // FLAC
        let p = flac(d)
        injectVorbisComments(p, [("TITLE", "Keep"), ("UNSYNCEDLYRICS", "old words"), ("LYRICS", "older words")])
        let before = readAll(try! LosslessFile(path: p))
        try! TagEditing.write(path: p, edits: [.lyrics: lrc])
        var raw = TagReader.read(path: p)
        expect(raw.first("TITLE") == "Keep" && raw.all("LYRICS").count == 1 && raw.first("UNSYNCEDLYRICS") == nil, "old lyrics replaced, other tags kept: \(raw.keys)")
        expect(LocalLyrics.find(req(p)).synced?.lines.count == 4, "what was written reads back as synced lyrics")
        expect(readAll(try! LosslessFile(path: p)) == before, "audio untouched")
        try! TagEditing.write(path: p, edits: [.lyrics: ""])
        expect(TagReader.read(path: p).first("LYRICS") == nil, "empty text removes them")
        // ALAC
        let wav = sineWAV(d.appendingPathComponent("a.wav"), rate: 48_000, bits: 24, freq: 997, amp: 0.3, seconds: 1)
        let m4a = d.appendingPathComponent("a.m4a")
        expect(encode(wav, to: m4a, alac: true), "afconvert makes ALAC")
        injectMP4Tags(m4a.path, items: [mp4Text("\u{A9}nam", ["Keep"]), mp4Text("\u{A9}lyr", ["old words"])])
        let audio = readAll(try! LosslessFile(path: m4a.path))
        try! TagEditing.write(path: m4a.path, edits: [.lyrics: lrc])
        raw = TagReader.read(path: m4a.path)
        expect(raw.first("TITLE") == "Keep" && raw.all("LYRICS").count == 1 && LocalLyrics.find(req(m4a.path)).synced != nil, "M4A: \(raw.keys)")
        expect(readAll(try! LosslessFile(path: m4a.path)) == audio, "ALAC audio untouched")
        // MP3: USLT written, a stale SYLT dropped
        func frame23(_ id: String, _ body: Data) -> Data { Data(id.utf8) + be32(body.count) + Data([0, 0]) + body }
        var sylt = Data([3]) + Data("eng".utf8) + Data([2, 1, 0]); sylt += Data("old".utf8) + Data([0]) + be32(1000)
        let frames = frame23("TIT2", Data([3]) + Data("Keep".utf8)) + frame23("SYLT", sylt) + frame23("USLT", Data([3]) + Data("eng".utf8) + Data([0]) + Data("older".utf8))
        let body = frames + Data(count: 64)
        let audioBytes = Data([0xFF, 0xFB, 0x90, 0x64]) + Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let mp3 = d.appendingPathComponent("t.mp3").path
        FileManager.default.createFile(atPath: mp3, contents: Data("ID3".utf8) + Data([3, 0, 0]) + ID3TagEditor.syncsafe(body.count) + body + audioBytes)
        try! TagEditing.write(path: mp3, edits: [.lyrics: lrc])
        raw = TagReader.read(path: mp3)
        expect(raw.first("TITLE") == "Keep" && raw.all("LYRICS").count == 1 && raw.first("SYNCEDLYRICS") == nil, "MP3: \(raw.keys)")
        expect(LocalLyrics.find(req(mp3)).synced?.lines.count == 4, "MP3 lyrics read back synced")
        let out = try! Data(contentsOf: URL(fileURLWithPath: mp3))
        let size = Int(out[6]) << 21 | Int(out[7]) << 14 | Int(out[8]) << 7 | Int(out[9])
        expect(out.subdata(in: (10 + size)..<out.count) == audioBytes, "MPEG frames byte-identical")
    }

    // MARK: - LRCLIB

    private let exactJSON = #"{"id":1,"trackName":"Title","artistName":"Band","albumName":"Album","duration":200.0,"instrumental":false,"plainLyrics":"plain one\nplain two","syncedLyrics":"[00:05.00]Alpha beta\n[00:10.00]Gamma delta"}"#

    func lrclibLookup() {
        // exact match
        var http = StubHTTP()
        http.on("api/get", exactJSON)
        var client = LRCLIBClient(http: http)
        var r = runAsync { try await client.lookup(self.req("/m/a.flac")) }
        guard case .success(let found) = r, let f = found else { expect(false, "exact match: \(r)"); return }
        expect(f.synced?.hasPrefix("[00:05.00]") == true && f.plain != nil && !f.instrumental, "synced and plain")
        let url = http.urls().first ?? ""
        expect(url.contains("track_name=Title") && url.contains("artist_name=Band") && url.contains("album_name=Album") && url.contains("duration=200"), url)
        expect(http.requests.first?.value(forHTTPHeaderField: "User-Agent")?.contains("Aureon") == true, "identifies itself")

        // not found by exact match: search, and pick the right one
        http = StubHTTP()
        http.on("api/get", "{}", status: 404)
        let wrongArtist = #"{"trackName":"Title","artistName":"Another Act","duration":200,"syncedLyrics":"[00:01.00]x\n[00:02.00]y"}"#
        let plainOnly = #"{"trackName":"Title","artistName":"Band","duration":201,"plainLyrics":"just text"}"#
        let tooLong = #"{"trackName":"Title","artistName":"Band","duration":260,"syncedLyrics":"[00:01.00]x\n[00:02.00]y"}"#
        let good = #"{"trackName":"Title (Remastered)","artistName":"Band","duration":199,"syncedLyrics":"[00:01.00]good\n[00:02.00]one"}"#
        http.on("api/search", "[\(wrongArtist),\(plainOnly),\(tooLong),\(good)]")
        client = LRCLIBClient(http: http)
        r = runAsync { try await client.lookup(self.req("/m/a.flac")) }
        if case .success(let s) = r { expect(s?.synced?.contains("good") == true, "search picks the synced match of the right artist and length: \(String(describing: s))") } else { expect(false, "\(r)") }

        // no album or length: straight to search
        http = StubHTTP()
        http.on("api/search", "[\(good)]")
        client = LRCLIBClient(http: http)
        r = runAsync { try await client.lookup(LyricsRequest(path: "/m/a.flac", title: "Title", artist: "Band")) }
        expect(http.count == 1 && http.urls()[0].contains("api/search"), "search only: \(http.urls())")

        // instrumental
        http = StubHTTP()
        http.on("api/get", #"{"trackName":"Title","artistName":"Band","duration":200,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#)
        client = LRCLIBClient(http: http)
        r = runAsync { try await client.lookup(self.req("/m/a.flac")) }
        if case .success(let s) = r { expect(s?.instrumental == true && s?.synced == nil, "instrumental") } else { expect(false, "\(r)") }

        // nothing
        http = StubHTTP()
        http.on("api/get", "{}", status: 404); http.on("api/search", "[]")
        client = LRCLIBClient(http: http)
        r = runAsync { try await client.lookup(self.req("/m/a.flac")) }
        if case .success(let s) = r { expect(s == nil, "no result") } else { expect(false, "\(r)") }

        // failures are errors, not “not found”
        let down = DownHTTP()
        client = LRCLIBClient(http: down)
        let e1 = runAsync { try await client.lookup(self.req("/m/a.flac")) }
        if case .failure = e1 {} else { expect(false, "a network failure throws") }
        http = StubHTTP(); http.on("api/get", "oops", status: 500)
        client = LRCLIBClient(http: http)
        let e2 = runAsync { try await client.lookup(self.req("/m/a.flac")) }
        if case .failure = e2 {} else { expect(false, "a server error throws") }
    }

    // MARK: - Store

    func lyricsStore() {
        let d = fresh("store")
        let s = LyricsStore(directory: d)
        let l = LRCParser.parse(sampleLRC, origin: .online, source: "LRCLIB")!
        expect(s.found("k") == nil)
        s.store(l, key: "k")
        expect(s.found("k") == l, "kept")
        expect(LyricsStore(directory: d).found("k") == l, "kept on disk, read by a new store")
        // a miss lasts a week
        s.storeMiss(key: "m")
        expect(s.entry("m")?.kind == .miss && s.entry("m", now: Date().addingTimeInterval(6 * 86_400))?.kind == .miss, "fresh miss")
        expect(s.entry("m", now: Date().addingTimeInterval(8 * 86_400)) == nil, "an old miss is forgotten")
        // found never expires
        expect(s.entry("k", now: Date().addingTimeInterval(400 * 86_400))?.kind == .found, "found stays")
        s.storeInstrumental(key: "i")
        expect(s.entry("i")?.kind == .instrumental)
        expect(!s.isDeclined("k")); s.decline("k"); expect(s.isDeclined("k") && LyricsStore(directory: d).isDeclined("k") && s.found("k") != nil, "declined is separate from found")
        s.undecline("k"); expect(!s.isDeclined("k"))
        s.remove("k"); expect(s.found("k") == nil && LyricsStore(directory: d).found("k") == nil, "removed")
    }

    // MARK: - Speech model pipeline

    func whisperText() {
        expect(WhisperLyrics.clean("<|startoftranscript|><|0.00|> ♪ Hello   there ♪ <|3.20|>") == "Hello there", "markers, notes and spaces removed")
        for cue in ["[Music]", "(upbeat music)", "[BLANK_AUDIO]", "*instrumental*", "♪♪", "  ", "...", "[ Guitar ]", "(piano playing)"] { expect(WhisperLyrics.isMusicCue(cue), "“\(cue)” is a cue") }
        for words in ["hello there", "(whispering) hello", "[Chorus] sing along", "♪ la la la ♪"] { expect(!WhisperLyrics.isMusicCue(words), "“\(words)” is words") }
        expect(WhisperLyrics.isInvention("Thanks for watching!") && WhisperLyrics.isInvention("Subtitles by the Amara.org community") && !WhisperLyrics.isInvention("watching the sun go down"), "inventions")
        expect(SpeechAudio.languageCode("eng") == "en" && SpeechAudio.languageCode("FRA") == "fr" && SpeechAudio.languageCode("de") == "de" && SpeechAudio.languageCode("xyz") == nil && SpeechAudio.languageCode(nil) == nil && SpeechAudio.languageCode(" ") == nil, "language codes")
        let long = "this is a rather long made up sentence, which goes on and on for a good while, and then some more words follow to make it longer still"
        let parts = WhisperLyrics.splitText(long)
        expect(parts.count >= 3 && parts.allSatisfy { $0.count <= WhisperLyrics.maxLineCharacters } && parts.joined(separator: " ").replacingOccurrences(of: "  ", with: " ") == long, "\(parts)")
        expect(WhisperLyrics.splitText("short line") == ["short line"] && WhisperLyrics.splitText("  ").isEmpty, "short text")
    }

    private func seg(_ start: Double, _ end: Double, _ text: String, words: [(Double, Double, String)] = [], lp: Double? = nil, ns: Double? = nil) -> TranscribedSegment {
        TranscribedSegment(start: start, end: end, text: text, words: words.map { TranscribedWord(start: $0.0, end: $0.1, text: $0.2) }, avgLogprob: lp, noSpeechProb: ns)
    }

    func whisperLyricsBuild() {
        var segs = [
            seg(2, 5, " First made-up line", words: [(2, 2.4, " First"), (2.4, 2.8, " made-up"), (2.8, 3.2, " line")]),
            seg(6, 8, "<|6.00|> Second made-up line <|8.00|>"),
            seg(9, 12, "[Music]"),
            seg(30, 33, " Far later line"),                          // 18 s of silence before it: an instrumental stretch
            seg(34, 36, "Thanks for watching!"),                       // an invention: dropped
            seg(40, 42, "quiet nonsense", lp: -2.0, ns: 0.95),         // the model heard no speech: a pause
            seg(50, 52, "Final line"),
        ]
        guard let l = WhisperLyrics.build(Transcription(segments: segs, language: "en", model: .small), title: "T", artist: "A") else { expect(false, "builds"); return }
        expect(l.synced && l.origin == .generated && l.source == "Whisper small" && l.language == "en" && l.title == "T", "metadata")
        let texts = l.lines.map(\.text)
        expect(texts == ["First made-up line", "Second made-up line", "", "Far later line", "", "Final line"], "\(texts)")
        expect(l.lines[0].words.count == 3 && l.lines[0].words[1].text == " made-up" && l.lines[0].words[0].text == "First", "words carry spacing: \(l.lines[0].words)")
        expect(zip(l.lines, l.lines.dropFirst()).allSatisfy { $0.time <= $1.time } && l.lines.map(\.id) == Array(0..<6), "in order")
        expect(near(l.lines[0].time, 2) && near(l.lines[1].time, 6), "times come from the segments")
        // out of order input is sorted
        segs.reverse()
        expect(WhisperLyrics.build(Transcription(segments: segs, language: "en", model: .base))?.lines.first?.text == "First made-up line", "sorted")
        // a long silence before a line closes the line before with a break
        let gap = WhisperLyrics.build(Transcription(segments: [seg(1, 3, "one"), seg(20, 22, "two")], language: nil, model: .base))!
        expect(gap.lines.map(\.text) == ["one", "", "two"] && near(gap.lines[1].time, 4), "instrumental gap: \(gap.lines)")
        // only music and silence: nothing
        expect(WhisperLyrics.build(Transcription(segments: [seg(0, 30, "[Music]"), seg(30, 60, "♪")], language: nil, model: .base)) == nil, "no singing")
        expect(WhisperLyrics.build(Transcription(segments: [], language: nil, model: .base)) == nil, "empty")
        // the model stuck on one line: a run keeps four
        let loop = (0..<30).map { seg(Double($0) * 2, Double($0) * 2 + 2, "stuck on this line") } + [seg(70, 72, "after the loop")]
        let stuck = WhisperLyrics.build(Transcription(segments: loop, language: nil, model: .base))!
        expect(stuck.lines.filter { $0.text == "stuck on this line" }.count == 4 && stuck.lines.last?.text == "after the loop", "loop collapsed")
        // a real repeated chorus with other lines between is kept
        let chorus = WhisperLyrics.build(Transcription(segments: [seg(0, 2, "la la"), seg(2, 4, "verse"), seg(4, 6, "la la"), seg(6, 8, "verse two"), seg(8, 10, "la la")], language: nil, model: .base))!
        expect(chorus.lines.filter { $0.text == "la la" }.count == 3, "choruses stay")
        // words without times in a long segment: split by length, times shared out
        let longSeg = WhisperLyrics.build(Transcription(segments: [seg(10, 20, "this is a rather long made up sentence, which goes on and on for a good while, and then some more words")], language: nil, model: .base))!
        expect(longSeg.lines.count >= 2 && longSeg.lines.allSatisfy { $0.text.count <= WhisperLyrics.maxLineCharacters } && near(longSeg.lines[0].time, 10) && longSeg.lines[1].time > 10, "\(longSeg.lines.map(\.text))")
        // a pause between words splits a segment's line
        let paused = WhisperLyrics.build(Transcription(segments: [seg(0, 6, "one two three four", words: [(0, 0.4, "one"), (0.5, 0.9, "two"), (3.0, 3.4, "three"), (3.5, 3.9, "four")])], language: nil, model: .base))!
        expect(paused.lines.map(\.text) == ["one two", "three four"], "\(paused.lines.map(\.text))")
        // languages written without spaces
        let ja = WhisperLyrics.build(Transcription(segments: [seg(0, 2, "春が来た", words: [(0, 1, "春"), (1, 2, "が来た")])], language: "ja", model: .base))!
        expect(ja.lines[0].text == "春が来た", "no spaces added for Japanese: \(ja.lines[0].text)")
        // it reads back through the LRC text it is saved as
        let again = LRCParser.parse(l.lrc())!
        expect(again.lines.count == l.lines.count && again.wordSynced, "round trip through LRC")
    }

    func helperProtocol() {
        let any: Any = [["start": 1.5, "end": 3, "text": "hello", "words": [["start": 1.5, "end": 2.0, "text": "hel"], ["start": 2, "end": 3, "text": "lo"]], "avgLogprob": -0.4, "noSpeechProb": 0.1],
                        ["start": 4, "end": 5, "text": "no words"], ["bad": 1]]
        let segs = WhisperHelperProcess.segments(any)
        expect(segs.count == 2 && segs[0].words.count == 2 && segs[0].avgLogprob == -0.4 && segs[1].words.isEmpty && segs[1].noSpeechProb == nil, "\(segs)")
        expect(WhisperHelperProcess.segments(nil).isEmpty && WhisperHelperProcess.segments("x").isEmpty)
        expect(WhisperHelperLocator.find(environment: ["AUREON_WHISPER_HELPER": "/nonexistent/AureonWhisper"], bundle: Bundle(for: DownHTTP.self), cwd: "/nonexistent") == nil, "missing helper is nil")
        let fake = fresh("helper").appendingPathComponent("AureonWhisper")
        FileManager.default.createFile(atPath: fake.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        expect(WhisperHelperLocator.find(environment: ["AUREON_WHISPER_HELPER": fake.path], cwd: "/nonexistent") == fake, "the override is found")
        for m in WhisperModelSize.allCases { expect(m.parametersMillions < 1000 && m.approxMB > 0 && !m.detail.isEmpty, "\(m) is under the 1B cap") }
    }

    /// Runs the helper protocol against a shell script that speaks it.
    func helperConversation() {
        let d = fresh("fakehelper")
        let script = d.appendingPathComponent("AureonWhisper")
        let body = """
        #!/bin/bash
        while IFS= read -r line; do
          case "$line" in
            *'"op":"transcribe"'*)
              id=$(echo "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
              if echo "$line" | grep -q '"model":"small"'; then echo '{"event":"error","id":'$id',"message":"no small today"}'; continue; fi
              echo '{"event":"progress","id":'$id',"fraction":0.5,"message":"Listening"}'
              echo '{"event":"result","id":'$id',"language":"en","segments":[{"start":1,"end":2,"text":"made up","words":[]}]}' ;;
            *'"op":"unload"'*) echo '{"event":"unloaded"}'; exit 0 ;;
          esac
        done
        """
        try! body.write(to: script, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let helper = WhisperHelperProcess(executable: script)
        helper.modelFolder = d
        let seen = FlagBox(false)
        let wav = d.appendingPathComponent("x.wav")
        FileManager.default.createFile(atPath: wav.path, contents: SpeechAudio.wavHeader(samples: 0))
        let ok = runAsync(timeout: 20) { try await helper.transcribe(audio: wav, model: .base, language: "en") { f, _ in if f == 0.5 { seen.value = true } } }
        if case .success(let t) = ok { expect(t.segments.count == 1 && t.segments[0].text == "made up" && t.language == "en" && t.model == .base && seen.value, "\(t)") } else { expect(false, "\(ok)") }
        let bad = runAsync(timeout: 20) { try await helper.transcribe(audio: wav, model: .small, language: nil) { _, _ in } }
        if case .failure(let e) = bad { expect(e.localizedDescription == "no small today", "\(e)") } else { expect(false, "an error answer throws") }
        _ = runAsync(timeout: 10) { await helper.unload() }
        expect(!helper.isRunning, "unloaded")
        // a helper that is not there
        let none = WhisperHelperProcess(executable: d.appendingPathComponent("missing"))
        let r = runAsync(timeout: 10) { try await none.transcribe(audio: wav, model: .base, language: nil) { _, _ in } }
        if case .failure = r {} else { expect(false, "a missing program throws") }
    }

    private func readSamples(_ url: URL) -> (rate: Int, channels: Int, samples: [Int16]) {
        let d = try! Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        expect(d.prefix(4) == Data("RIFF".utf8) && d.subdata(in: 8..<16) == Data("WAVEfmt ".utf8) && d.subdata(in: 36..<40) == Data("data".utf8), "WAV header")
        let n = u32(40) / 2
        expect(u32(4) == 36 + n * 2 && d.count == 44 + n * 2, "sizes in the header match the data")
        let s = (0..<n).map { Int16(bitPattern: UInt16(d[44 + $0 * 2]) | UInt16(d[45 + $0 * 2]) << 8) }
        return (u32(24), Int(d[22]), s)
    }

    func speechAudio() {
        let d = fresh("speech")
        for rate in [44_100, 48_000, 96_000, 16_000] {
            let src = sineWAV(d.appendingPathComponent("s\(rate).wav"), rate: rate, bits: 16, freq: 1000, amp: 0.5, seconds: 2)
            let out = d.appendingPathComponent("o\(rate).wav")
            var last = 0.0, monotonic = true
            let secs = try? SpeechAudio.prepare(path: src.path, to: out, progress: { if $0 < last { monotonic = false }; last = $0 })
            expect(near(secs ?? 0, 2, 0.01) && monotonic && last == 1, "\(rate) Hz: \(String(describing: secs)), progress \(last)")
            let (r, ch, s) = readSamples(out)
            expect(r == 16_000 && ch == 1 && abs(s.count - 32_000) <= 2, "\(rate) Hz → 16 kHz mono, \(s.count) samples")
            let peak = s.dropFirst(400).dropLast(400).map { abs(Int($0)) }.max() ?? 0
            expect(peak > 15_000 && peak < 17_800, "a 1 kHz tone at half scale keeps its level: \(peak)")
        }
        // a tone above the new Nyquist (8 kHz) must not come back as an alias
        let hi = sineWAV(d.appendingPathComponent("hi.wav"), rate: 48_000, bits: 16, freq: 12_000, amp: 0.5, seconds: 1)
        _ = try? SpeechAudio.prepare(path: hi.path, to: d.appendingPathComponent("hi16.wav"))
        let hs = readSamples(d.appendingPathComponent("hi16.wav")).samples
        expect((hs.dropFirst(400).dropLast(400).map { abs(Int($0)) }.max() ?? 0) < 600, "frequencies above 8 kHz are filtered out, not folded down")
        // stereo is mixed, opposite phases cancel
        let anti = writeWAV(d.appendingPathComponent("anti.wav"), rate: 16_000, bits: 16, channels: 2, frames: 16_000) { f, c in Int(10_000 * sin(Double(f) * 0.1)) * (c == 0 ? 1 : -1) }
        _ = try? SpeechAudio.prepare(path: anti.path, to: d.appendingPathComponent("anti16.wav"))
        expect((readSamples(d.appendingPathComponent("anti16.wav")).samples.map { abs(Int($0)) }.max() ?? 0) < 4, "channels are averaged")
        // cancellation and bad input
        do { _ = try SpeechAudio.prepare(path: hi.path, to: d.appendingPathComponent("c.wav"), cancelled: { true }); expect(false, "cancelled") } catch { expect(error is CancellationError, "\(error)") }
        do { _ = try SpeechAudio.prepare(path: d.appendingPathComponent("nothing.flac").path, to: d.appendingPathComponent("n.wav")); expect(false, "missing file") } catch { expect(error is LyricsError, "\(error)") }
    }

    // MARK: - Service

    @MainActor private func wait(_ timeout: Double = 8, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func suite() -> UserDefaults { UserDefaults(suiteName: "aureon.lyricstest.\(UUID().uuidString.prefix(8))")! }

    @MainActor private func service(_ http: HTTPClient, store: LyricsStore? = nil, local: LocalLyricsResult = LocalLyricsResult(), allowGeneration: FlagBox = FlagBox(true)) -> LyricsService {
        let s = LyricsService(defaults: suite(), observesSettings: false)
        s.online = LRCLIBClient(http: http)
        s.store = store ?? LyricsStore(directory: fresh("svc"))
        s.isOnlineAllowed = { true }
        s.isGenerationAllowed = { allowGeneration.value }
        s.whisperModel = { .base }
        s.findLocal = { _ in local }
        s.idleUnload = 0.05
        s.saveRetryDelay = 0.02
        s.languageHint = { _ in "en" }
        s.prepareAudio = { _, url, _, progress in progress(0.5); progress(1); FileManager.default.createFile(atPath: url.path, contents: Data([1])); return 180 }
        return s
    }

    @MainActor private func isMissing(_ s: LyricsService) -> Bool { if case .missing = s.phase { return true }; return false }

    @MainActor func serviceFindsLyrics() {
        let local = LocalLyricsResult(synced: LRCParser.parse(sampleLRC), plain: nil)
        // local lyrics: no network at all
        var http = StubHTTP()
        var s = service(http, local: local)
        s.show(req("/m/a.flac"))
        wait { s.phase == .ready }
        expect(s.phase == .ready && s.lyrics?.synced == true && http.count == 0, "local lyrics need no network")
        s.show(nil)
        expect(s.phase == .idle && s.lyrics == nil, "nothing playing")

        // online, then from the cache without the network
        let store = LyricsStore(directory: fresh("online"))
        http = StubHTTP(); http.on("api/get", exactJSON)
        s = service(http, store: store)
        s.show(req("/m/a.flac"))
        wait { s.phase == .ready }
        expect(s.lyrics?.origin == .online && s.lyrics?.source == "LRCLIB" && s.lyrics?.synced == true && store.found(req("/m/a.flac").cacheKey) != nil, "found online and kept")
        let down = DownHTTP()
        s = service(down, store: store)
        s.show(req("/other/place/a.flac"))
        wait { s.phase == .ready }
        expect(s.phase == .ready && down.count == 0, "the same song elsewhere comes from the cache")

        // not found: remembered, asked again only on request
        let store2 = LyricsStore(directory: fresh("miss"))
        http = StubHTTP(); http.on("api/get", "{}", status: 404); http.on("api/search", "[]")
        s = service(http, store: store2)
        s.show(req("/m/a.flac"))
        wait { isMissing(s) }
        let asked = http.count
        expect(isMissing(s) && asked == 2 && !s.onlineUnreachable, "missing after asking: \(asked)")
        s = service(http, store: store2)
        s.show(req("/m/a.flac"))
        wait { isMissing(s) }
        expect(isMissing(s) && http.count == asked, "a remembered miss is not asked again")
        s.reload()
        wait { http.count > asked }
        wait { isMissing(s) }
        expect(http.count == asked * 2, "reload asks again: \(http.count)")

        // unreachable: nothing remembered
        let store3 = LyricsStore(directory: fresh("down"))
        let dead = DownHTTP()
        s = service(dead, store: store3)
        s.show(req("/m/a.flac"))
        wait { isMissing(s) }
        expect(isMissing(s) && s.onlineUnreachable && store3.entry(req("/m/a.flac").cacheKey) == nil, "unreachable is not “not found”")

        // switches
        http = StubHTTP(); http.on("api/get", exactJSON)
        s = service(http); s.onlineLookup = false
        s.show(req("/m/a.flac"))
        wait { isMissing(s) }
        expect(isMissing(s) && http.count == 0, "online lookup off: no request")
        s = service(http); s.isOnlineAllowed = { false }
        s.show(req("/m/a.flac"))
        wait { isMissing(s) }
        expect(isMissing(s) && http.count == 0, "offline: no request")
        s.onlineLookup = true; s.isOnlineAllowed = { true }
        s.reload()
        wait { s.phase == .ready }
        expect(s.phase == .ready, "turning it back on and looking again finds them")

        // plain lyrics are shown while a synced version is fetched, and replaced by it
        http = StubHTTP(); http.on("api/get", exactJSON)
        s = service(http, local: LocalLyricsResult(synced: nil, plain: LRCParser.parse("plain one\nplain two")))
        s.show(req("/m/a.flac"))
        wait { s.lyrics?.synced == true }
        expect(s.lyrics?.origin == .online && !s.upgrading, "synced replaces plain")
        http = StubHTTP(); http.on("api/get", #"{"trackName":"Title","artistName":"Band","duration":200,"plainLyrics":"other plain"}"#)
        s = service(http, local: LocalLyricsResult(synced: nil, plain: LRCParser.parse("plain one\nplain two")))
        s.show(req("/m/a.flac"))
        wait { http.count > 0 && !s.upgrading }
        expect(s.lyrics?.plainText == "plain one\nplain two", "the file's own plain lyrics are not replaced by other plain lyrics")

        // instrumental
        http = StubHTTP(); http.on("api/get", #"{"trackName":"Title","artistName":"Band","duration":200,"instrumental":true}"#)
        s = service(http)
        s.show(req("/m/a.flac"))
        wait { s.phase == .instrumental }
        expect(s.phase == .instrumental, "instrumental")

        // a slow answer for a song that has been left is dropped
        let slow = LocalLyricsResult(synced: LRCParser.parse("[00:01.00]slow\n[00:02.00]one"), plain: nil)
        s = service(StubHTTP())
        s.findLocal = { r in if r.path.contains("slow") { Thread.sleep(forTimeInterval: 0.2); return slow }; return LocalLyricsResult(synced: LRCParser.parse("[00:01.00]quick\n[00:02.00]one"), plain: nil) }
        s.show(req("/m/slow.flac"))
        s.show(req("/m/quick.flac", title: "Quick"))
        wait { s.phase == .ready }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        expect(s.lyrics?.lines.first?.text == "quick", "the song that is playing wins: \(String(describing: s.lyrics?.lines.first?.text))")
        // asking again for the same song changes nothing
        let before = s.lyrics
        s.show(req("/m/quick.flac", title: "Quick"))
        expect(s.lyrics == before && s.phase == .ready, "same song, same state")
    }

    @MainActor func serviceGeneratesLyrics() {
        let http = StubHTTP(); http.on("api/get", "{}", status: 404); http.on("api/search", "[]")
        let allow = FlagBox(true)
        let store = LyricsStore(directory: fresh("gen"))
        let model = ScriptedTranscriber()
        model.result = Transcription(segments: [seg(2, 5, "Made up first line"), seg(6, 9, "Made up second line")], language: "en", model: .base)
        let s = service(http, store: store, allowGeneration: allow)
        s.makeTranscriber = { model }
        let r = req("/m/a.flac")
        s.show(r)
        wait { isMissing(s) }
        expect(isMissing(s) && s.canOfferGeneration && !s.declined, "nothing found: the page may offer to write them")
        expect(model.calls == 0, "nothing runs until the owner agrees")

        s.generate()
        expect(s.isGenerating, "generating")
        wait { s.phase == .ready }
        expect(s.lyrics?.origin == .generated && s.lyrics?.lines.map(\.text) == ["Made up first line", "Made up second line"] && s.unsaved, "generated and unsaved")
        expect(model.calls == 1 && model.lastModel == .base && model.lastLanguage == "en", "the chosen model and the file's language were used")
        expect(store.found(r.cacheKey)?.origin == .generated, "kept, so it is never generated twice")
        wait { model.unloads == 1 }
        expect(model.unloads == 1, "the model is unloaded after a short idle time")
        // next time it comes from the cache, with no model at all
        let again = service(http, store: store, allowGeneration: allow)
        again.makeTranscriber = { model }
        again.show(r)
        wait { again.phase == .ready }
        expect(again.lyrics?.origin == .generated && model.calls == 1, "from the cache")

        // the owner says no: remembered
        let s2 = service(http, store: LyricsStore(directory: fresh("decline")), allowGeneration: allow)
        s2.show(r)
        wait { isMissing(s2) }
        s2.decline()
        expect(s2.declined && model.calls == 1, "declined")
        let s2b = service(http, store: s2.store, allowGeneration: allow)
        s2b.show(r)
        wait { isMissing(s2b) }
        expect(s2b.declined, "the refusal is remembered for that song")

        // the feature is off
        let off = FlagBox(false)
        let s3 = service(http, store: LyricsStore(directory: fresh("off")), allowGeneration: off)
        s3.makeTranscriber = { model }
        s3.show(r)
        wait { isMissing(s3) }
        expect(!s3.canOfferGeneration, "not offered when Intelligence has it off")
        s3.generate()
        if case .failed(let m) = s3.phase { expect(m.contains("switched off"), m) } else { expect(false, "generate() refuses: \(s3.phase)") }
        expect(model.calls == 1, "the model was not touched")

        // streams and cloud tracks are never offered
        let s4 = service(http, store: LyricsStore(directory: fresh("remote")))
        s4.show(LyricsRequest(path: "cloud://bucket/a.flac", title: "T", artist: "A", duration: 100))
        wait { isMissing(s4) }
        expect(!s4.canOfferGeneration, "only files on this Mac")

        // cancelling
        let slowModel = ScriptedTranscriber(); slowModel.duration = 5
        slowModel.result = model.result
        let s5 = service(http, store: LyricsStore(directory: fresh("cancel")))
        s5.makeTranscriber = { slowModel }
        s5.show(r)
        wait { isMissing(s5) }
        s5.generate()
        wait { slowModel.calls == 1 }
        s5.cancelGeneration()
        expect(isMissing(s5) && s5.lyrics == nil, "cancelled")
        wait { slowModel.cancels >= 1 }
        expect(slowModel.cancels >= 1, "the model was told to stop")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        expect(isMissing(s5) && s5.lyrics == nil, "nothing arrives after cancelling")

        // switching the feature off while it listens: the result is dropped
        let flip = FlagBox(true)
        let flipModel = ScriptedTranscriber(); flipModel.result = model.result
        let flipStore = LyricsStore(directory: fresh("flip"))
        flipModel.onFinish = { flip.value = false }
        let s6 = service(http, store: flipStore, allowGeneration: flip)
        s6.makeTranscriber = { flipModel }
        s6.show(r)
        wait { isMissing(s6) }
        s6.generate()
        wait { flipModel.calls == 1 }
        wait { isMissing(s6) }
        expect(isMissing(s6) && s6.lyrics == nil && flipStore.found(r.cacheKey) == nil, "nothing is kept once the switch is off")

        // failures
        let broken = ScriptedTranscriber(); broken.error = LyricsError.helperMissing
        let s7 = service(http, store: LyricsStore(directory: fresh("broken")))
        s7.makeTranscriber = { broken }
        s7.show(r)
        wait { isMissing(s7) }
        s7.generate()
        wait { if case .failed = s7.phase { return true }; return false }
        if case .failed(let m) = s7.phase { expect(m.contains("not installed"), m) } else { expect(false, "failed: \(s7.phase)") }
        let music = ScriptedTranscriber(); music.result = Transcription(segments: [seg(0, 60, "[Music]")], language: nil, model: .base)
        let s8 = service(http, store: LyricsStore(directory: fresh("music")))
        s8.makeTranscriber = { music }
        s8.show(r)
        wait { isMissing(s8) }
        s8.generate()
        wait { if case .failed = s8.phase { return true }; return false }
        if case .failed(let m) = s8.phase { expect(m.contains("No singing"), m) } else { expect(false, "failed: \(s8.phase)") }
        let noHelper = service(http, store: LyricsStore(directory: fresh("nohelper")))
        noHelper.makeTranscriber = { throw LyricsError.helperMissing }
        noHelper.show(r)
        wait { isMissing(noHelper) }
        noHelper.generate()
        wait { if case .failed = noHelper.phase { return true }; return false }
        if case .failed = noHelper.phase {} else { expect(false, "a missing helper is a clear failure") }
    }

    @MainActor func serviceSavesLyrics() {
        let d = fresh("save")
        let path = d.appendingPathComponent("song.flac").path
        let local = LocalLyricsResult(synced: LRCParser.parse(sampleLRC, origin: .embedded, source: "x"), plain: nil)
        let s = service(StubHTTP(), local: local)
        let r = req(path)
        s.show(r)
        wait { s.phase == .ready }
        // .lrc next to the song, never over an existing file
        s.saveAsLRC()
        let lrcURL = d.appendingPathComponent("song.lrc")
        expect(FileManager.default.fileExists(atPath: lrcURL.path) && s.saveNote == "Saved as song.lrc.", "\(String(describing: s.saveNote))")
        expect(LRCParser.parse(try! String(contentsOf: lrcURL, encoding: .utf8))?.lines.count == 4, "what was written is the lyrics")
        try! Data("mine".utf8).write(to: lrcURL)
        s.saveAsLRC()
        expect(s.saveNote?.contains("already exists") == true && (try? String(contentsOf: lrcURL, encoding: .utf8)) == "mine", "an existing file is never replaced")

        // tags: busy while playing, written once free
        let calls = FlagBox(false)
        final class Counter2: @unchecked Sendable { var n = 0; let lock = NSLock(); func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n } }
        let c = Counter2()
        s.writeTags = { p, text in
            let n = c.next()
            if n <= 2 { throw TagEditError.busy("playing") }
            calls.value = true
            expect(p == path && LRCParser.looksSynced(text), "the lyrics are written as LRC text")
        }
        s.saveToTags()
        wait { s.saveNote?.contains("cannot change yet") == true }
        expect(c.n == 1 && s.saveNote?.contains("cannot change yet") == true, "busy while the song is current: \(String(describing: s.saveNote))")
        s.show(req(d.appendingPathComponent("next.flac").path, title: "Next"))     // the song is left: the write goes ahead
        wait { calls.value }
        expect(calls.value && c.n == 3, "written after the song was left: \(c.n) attempts")
        expect(s.saveNote == nil, "the old song's note does not follow to the next song")

        // immediate success on the current song
        let s2 = service(StubHTTP(), local: local)
        s2.writeTags = { _, _ in }
        s2.show(r)
        wait { s2.phase == .ready }
        s2.saveToTags()
        wait { s2.saveNote != nil }
        expect(s2.saveNote == "Saved in the file's tags." && !s2.unsaved, "saved")
        // file types the tag writer does not handle
        let s3 = service(StubHTTP(), local: local)
        s3.show(req(d.appendingPathComponent("a.ogg").path))
        wait { s3.phase == .ready }
        s3.saveToTags()
        expect(s3.saveNote?.contains(".lrc") == true, "points to the .lrc instead")
    }

    // MARK: - Intelligence

    func lyricsGeneration_switches() {
        let hw = IntelligenceTests.appleM
        var settings = IntelligenceSettings(masterEnabled: true)
        var gate = IntelligenceGate(hardware: hw, settings: settings)
        expect(gate.isEnabled(.lyricsGeneration) && !IntelligenceFeature.lyricsGeneration.allowsAPI, "on, and never sent to an API")
        settings.set(.lyricsGeneration, false)
        gate = IntelligenceGate(hardware: hw, settings: settings)
        expect(!gate.isEnabled(.lyricsGeneration) && gate.isEnabled(.smartDJ), "its own switch")
        settings.set(.lyricsGeneration, true); settings.masterEnabled = false
        expect(!IntelligenceGate(hardware: hw, settings: settings).isEnabled(.lyricsGeneration), "the master switch")
        let intel = IntelligenceSettings(masterEnabled: true)
        expect(!IntelligenceGate(hardware: IntelligenceTests.intel, settings: intel).isEnabled(.lyricsGeneration), "Intel waits for the warning to be accepted")
        let bits = IntelligenceFeature.allCases.map { f -> UInt32 in var s = IntelligenceSettings(masterEnabled: false); s.masterEnabled = true; for g in IntelligenceFeature.allCases { s.set(g, g == f) }; return IntelligenceGate.mask(for: s, hardware: hw) }
        expect(Set(bits).count == IntelligenceFeature.allCases.count, "every feature has its own bit")
        let decoded = try? JSONDecoder().decode(IntelligenceSettings.self, from: Data(#"{"masterEnabled":true,"naturalPlaylists":false}"#.utf8))
        expect(decoded?.lyricsGeneration == true && decoded?.whisperModel == .base && decoded?.naturalPlaylists == false, "settings from before decode with the defaults")
        let round = try? JSONDecoder().decode(IntelligenceSettings.self, from: JSONEncoder().encode({ var s = IntelligenceSettings(masterEnabled: true); s.whisperModel = .small; return s }()))
        expect(round?.whisperModel == .small, "the model choice is saved")
    }
}

// MARK: - What starts the lookup

nonisolated(unsafe) private var lyricsKeepAlive: [AnyObject] = []

/// The song in focus without the app model; also stands in for it where the stage needs a host.
@MainActor private final class StubFocus: LyricsFocus, StageHost {
    var focusItem: QueueItem?
    var lyricsDuration = 0.0
    var tab: Tab = .albums
    var djMode = false
    init(_ item: QueueItem?) { focusItem = item }
}

extension LyricsTests {
    /// A short WAV with a made-up .lrc next to it.
    private func songWithLRC(_ name: String) -> QueueItem {
        let d = fresh(name)
        let song = d.appendingPathComponent("Zorblax Invented Tune.wav")
        writeWAV(song, rate: 8000, bits: 16, frames: 16_000) { f, _ in Int(6000 * sin(Double(f) * 0.2)) }
        let lrc = "[ti:Zorblax Invented Tune]\n[00:02.00]Quixotic marmalade over the hills\n[00:07.00]Invented words for a test of the lights\n[00:14.00]Fnord wibble sprocket\n[00:22.00]Final invented line\n"
        try! Data(lrc.utf8).write(to: d.appendingPathComponent("Zorblax Invented Tune.lrc"))
        return QueueItem(id: UUID(), url: song, title: "Zorblax Invented Tune")
    }

    /// A service that reads the real files and never goes online.
    @MainActor private func offlineService() -> LyricsService {
        let s = LyricsService(defaults: UserDefaults(suiteName: "aureon.lyricstest.\(UUID().uuidString.prefix(8))")!, observesSettings: false)
        s.store = LyricsStore(directory: fresh("driver-store"))
        s.isOnlineAllowed = { false }
        s.isGenerationAllowed = { false }
        return s
    }

    @MainActor func driverStartsTheLookup() {
        let item = songWithLRC("driver")
        // what is asked for
        let r = LyricsDriver.request(for: item, duration: 40)
        expect(r?.title == "Zorblax Invented Tune" && r?.path == item.path && r?.duration == 40 && r?.isLocalFile == true, "\(String(describing: r))")
        expect(LyricsDriver.request(for: nil, duration: 3) == nil, "nothing playing: nothing to look up")
        var radio = item; radio.isStream = true
        expect(LyricsDriver.request(for: radio, duration: 0) == nil, "radio has no lyrics")
        var tagged = item; tagged.artist = ""; tagged.albumArtist = "Nobody Real"
        expect(LyricsDriver.request(for: tagged, duration: 0)?.artist == "Nobody Real", "the album artist stands in for a missing artist")

        // start: from idle to the lyrics of the sidecar, with tags unread and no length yet
        let s = offlineService()
        let focus = StubFocus(item)
        expect(s.phase == .idle)
        LyricsDriver.start(focus, service: s)
        expect(s.phase != .idle, "asking leaves idle at once")
        wait { s.phase == .ready }
        expect(s.phase == .ready && s.lyrics?.synced == true && s.lyrics?.lines.count == 4 && s.lyrics?.origin == .sidecar, "\(s.phase)")
        expect(s.lyrics?.source == "Zorblax Invented Tune.lrc", "\(String(describing: s.lyrics?.source))")
        // the length arriving later does not throw synced lyrics away
        focus.lyricsDuration = 40
        LyricsDriver.start(focus, service: s)
        expect(s.phase == .ready && s.lyrics?.synced == true, "asking again with the length keeps what was found")

        // ask (the Now Playing page's path): starts without waiting for the tags or the length
        let s2 = offlineService()
        let f2 = StubFocus(item)
        let finished = FlagBox(false)
        let t = Task { @MainActor in await LyricsDriver.ask(f2, show: true, service: s2, maxWait: 2); finished.value = true }
        wait(1) { s2.phase != .idle }
        expect(s2.phase != .idle && !finished.value, "ask starts at once: \(s2.phase)")
        wait { s2.phase == .ready }
        expect(s2.phase == .ready, "\(s2.phase)")
        f2.lyricsDuration = 40
        var read = item; read.artSource = .none; f2.focusItem = read
        wait(3) { finished.value }
        expect(finished.value && s2.phase == .ready, "ask finishes once the tags are read and the length is known")
        t.cancel()

        // lyrics switched off, a stream, nothing: the page's lyrics are cleared
        var cleared: [(String, StubFocus, Bool)] = [("off", StubFocus(item), false), ("radio", StubFocus(radio), true), ("nothing", StubFocus(nil), true)]
        for (name, f, show) in cleared {
            let sv = offlineService()
            LyricsDriver.start(StubFocus(item), service: sv)
            wait { sv.phase == .ready }
            let done = FlagBox(false)
            Task { @MainActor in await LyricsDriver.ask(f, show: show, service: sv, maxWait: 0.2); done.value = true }
            wait(2) { done.value }
            expect(done.value && sv.phase == .idle && sv.request == nil && sv.lyrics == nil, "\(name): \(sv.phase)")
        }
        cleared.removeAll()

        // the trigger changes with the song, its tags and the switch, and with nothing else
        let tf = StubFocus(item)
        let a = LyricsDriver.trigger(for: tf, show: true)
        expect(a == LyricsDriver.trigger(for: tf, show: true) && a != LyricsDriver.trigger(for: tf, show: false), "the switch")
        var other = item; other.artSource = .embedded
        tf.focusItem = other
        expect(LyricsDriver.trigger(for: tf, show: true) != a, "reading the tags")
        tf.focusItem = radio
        expect(LyricsDriver.trigger(for: tf, show: true).path == nil, "radio")
    }

    /// The Lyrics buttons: whatever else happens on the page, the lookup for the song in focus starts.
    @MainActor func lyricsButtonStartsTheLookup() {
        let shared = LyricsService.shared
        let online = shared.isOnlineAllowed, gen = shared.isGenerationAllowed
        let ud = UserDefaults.standard
        let savedShow = ud.object(forKey: "aureon.lyrics.show"), savedExpanded = ud.object(forKey: "aureon.lyrics.expanded")
        defer {
            shared.isOnlineAllowed = online; shared.isGenerationAllowed = gen; shared.show(nil)
            ud.set(savedShow, forKey: "aureon.lyrics.show"); ud.set(savedExpanded, forKey: "aureon.lyrics.expanded")
        }
        shared.isOnlineAllowed = { false }; shared.isGenerationAllowed = { false }
        shared.show(nil)
        expect(shared.phase == .idle)
        let item = songWithLRC("button")
        let host = StubFocus(item), stage = StageModel()
        stage.showLyrics(host, reduceMotion: true)
        expect(host.tab == .player && stage.lyricsPending, "the page opens and is asked to scroll")
        expect(shared.phase != .idle && shared.request?.path == item.path, "pressing the button starts the lookup for the song: \(shared.phase)")
        wait { shared.phase == .ready }
        expect(shared.phase == .ready && shared.lyrics?.synced == true && shared.lyrics?.lines.first?.text == "Quixotic marmalade over the hills", "\(shared.phase)")
        // nothing playing: nothing to look up, and nothing breaks
        host.focusItem = nil
        stage.showLyrics(host, reduceMotion: true)
        expect(shared.request == nil && shared.phase == .idle, "no song, no lookup: \(shared.phase)")
    }

    /// The real Now Playing page in a real window (ordered in, far off screen): with a song in focus it starts the lookup by itself. This is the
    /// test that fails when the trigger lives on the lyrics panel, which is empty, and so never on screen, until lyrics exist.
    @MainActor func nowPlayingStartsTheLookup() {
        guard !NSScreen.screens.isEmpty else { return }
        let shared = LyricsService.shared
        let online = shared.isOnlineAllowed, gen = shared.isGenerationAllowed
        let ud = UserDefaults.standard
        let savedShow = ud.object(forKey: "aureon.lyrics.show")
        ud.set(true, forKey: "aureon.lyrics.show")
        shared.isOnlineAllowed = { false }; shared.isGenerationAllowed = { false }
        shared.show(nil)
        let item = songWithLRC("hosted")
        let m = PlayerModel()
        lyricsKeepAlive.append(m)
        m.add(urls: [item.url])
        m.tab = .player
        let view = ContentView().environmentObject(m).frame(width: 1100, height: 900).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        win.orderFront(nil)
        defer {
            win.orderOut(nil); win.contentView = nil
            shared.isOnlineAllowed = online; shared.isGenerationAllowed = gen; shared.show(nil)
            ud.set(savedShow, forKey: "aureon.lyrics.show")
        }
        wait(10) { shared.phase == .ready }
        expect(m.focusItem?.path == item.path, "the song is in focus")
        expect(shared.phase == .ready && shared.lyrics?.synced == true, "Now Playing started the lookup by itself: \(shared.phase)")
    }

    /// Queries are percent-encoded, so spaces, "+", "&" and accents reach the service as typed.
    func lrclibQueryEncoding() {
        let http = StubHTTP()
        http.on("lrclib.net", "{}", status: 404)
        let client = LRCLIBClient(http: http)
        let r = LyricsRequest(path: "/m/a.flac", title: "Florence + the Machine / Café #1?", artist: "Beyoncé & Jay-Z", album: "Rock n Roll", duration: 201.4)
        let done = FlagBox(false)
        Task { _ = try? await client.lookup(r); done.value = true }
        let end = Date().addingTimeInterval(5)
        while !done.value && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        expect(http.requests.count == 2, "exact match, then search: \(http.requests.count)")
        for req in http.requests {
            let text = req.url?.absoluteString ?? ""
            expect(!text.contains(" ") && !text.contains("+") && text.contains("%20") && text.contains("%2B") && text.contains("%26") && text.contains("%C3%A9") && text.contains("%23") && text.contains("%3F"), text)
            let items = URLComponents(string: text)?.queryItems ?? []
            expect(items.first { $0.name == "track_name" }?.value == r.title && items.first { $0.name == "artist_name" }?.value == r.artist, "the service decodes what was typed: \(items)")
        }
        expect(http.requests.first?.url?.path == "/api/get" && http.requests.last?.url?.path == "/api/search")
        expect(http.requests.first?.url?.query?.contains("duration=201") == true, "the length is whole seconds")

        // a busy service (503) is tried once more; two in a row is an error, which is not remembered as "no lyrics"
        let busy = StubHTTP()
        busy.on("/api/get", [(Data(), 503), (Data("{\"syncedLyrics\":\"[00:01.00]made up one\\n[00:03.00]made up two\",\"trackName\":\"T\",\"artistName\":\"A\"}".utf8), 200)])
        var c2 = LRCLIBClient(http: busy); c2.retryDelay = 0.01
        let got = FlagBox(false)
        Task { if let l = try? await c2.lookup(r), l.synced != nil { got.value = true } }
        let end2 = Date().addingTimeInterval(5)
        while !got.value && Date() < end2 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        expect(got.value && busy.requests.count == 2, "one 503 is retried and then answered: \(busy.requests.count) requests")
        let down = StubHTTP()
        down.on("/api", [(Data(), 503)])
        var c3 = LRCLIBClient(http: down); c3.retryDelay = 0.01
        let threw = FlagBox(false), finished = FlagBox(false)
        Task { do { _ = try await c3.lookup(r) } catch { threw.value = true }; finished.value = true }
        let end3 = Date().addingTimeInterval(5)
        while !finished.value && Date() < end3 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        expect(threw.value && down.requests.count == 2, "a service that stays busy is an error, after one retry: \(down.requests.count)")
    }

    /// Only with AUREON_TEST_NETWORK=1: the real service from this Mac. Prints status facts, never lyric text.
    func lrclibLive() {
        guard ProcessInfo.processInfo.environment["AUREON_TEST_NETWORK"] != nil else { return }
        final class Box: @unchecked Sendable { var invented: OnlineLyrics??; var invErr: Error?; var known: OnlineLyrics??; var knownErr: Error? }
        let box = Box()
        let done = FlagBox(false)
        let client = LRCLIBClient()
        Task {
            do { box.invented = .some(try await client.lookup(LyricsRequest(path: "/m/a.flac", title: "Zzqx Nonsense Invented Title 987", artist: "Nobody Real", album: "None", duration: 123))) } catch { box.invErr = error }
            do { box.known = .some(try await client.lookup(LyricsRequest(path: "/m/b.flac", title: "Yesterday", artist: "The Beatles", album: "Help!", duration: 125))) } catch { box.knownErr = error }
            done.value = true
        }
        let end = Date().addingTimeInterval(40)
        while !done.value && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let known: String = box.knownErr.map { "error \($0)" } ?? ((box.known ?? nil).map { "found (synced: \($0.synced != nil), plain: \($0.plain != nil))" } ?? "nothing")
        FileHandle.standardError.write(Data("LRCLIB live: invented title -> \(box.invErr.map { "error \($0)" } ?? ((box.invented ?? nil) == nil ? "nothing (expected)" : "something")); well-known title -> \(known)\n".utf8))
        // the service is sometimes busy (5xx, even after the retry): that is reported above, not a failure of Aureon
        func busy(_ e: Error?) -> Bool { if case .status(let c, _)? = e as? NetworkError { return (500...599).contains(c) }; return false }
        expect(box.invErr == nil || busy(box.invErr), "an invented song is a clean miss, not an error: \(String(describing: box.invErr))")
        expect((box.invented ?? nil) == nil, "and finds nothing")
        expect(box.knownErr == nil || busy(box.knownErr), "the service answers from this Mac: \(String(describing: box.knownErr))")
    }
}

func lyricsTests() -> [(String, TestFn)] {
    let t = LyricsTests()
    return [("lyrics.timestamps", t.lrcTimestamps), ("lyrics.lrc", t.lrcParsing), ("lyrics.words", t.lrcWords), ("lyrics.plain", t.lrcPlainText), ("lyrics.writing", t.lrcWriting),
            ("lyrics.cursor", t.lrcCursor), ("lyrics.clock", t.playheadClock), ("lyrics.cursorPublishes", { MainActor.assumeIsolated { t.cursorPublishesLineChangesOnly() } }),
            ("lyrics.id3", t.id3Lyrics), ("lyrics.files", t.lyricsFiles), ("lyrics.tags", t.lyricsInTags), ("lyrics.tagWriting", t.lyricsTagWriting),
            ("lyrics.lrclib", t.lrclibLookup), ("lyrics.store", t.lyricsStore), ("lyrics.whisperText", t.whisperText), ("lyrics.whisperBuild", t.whisperLyricsBuild),
            ("lyrics.helperProtocol", t.helperProtocol), ("lyrics.helperConversation", t.helperConversation), ("lyrics.speechAudio", t.speechAudio),
            ("lyrics.service", { MainActor.assumeIsolated { t.serviceFindsLyrics() } }), ("lyrics.generate", { MainActor.assumeIsolated { t.serviceGeneratesLyrics() } }),
            ("lyrics.save", { MainActor.assumeIsolated { t.serviceSavesLyrics() } }), ("lyrics.switches", t.lyricsGeneration_switches),
            ("lyrics.driver", { MainActor.assumeIsolated { t.driverStartsTheLookup() } }), ("lyrics.button", { MainActor.assumeIsolated { t.lyricsButtonStartsTheLookup() } }),
            ("lyrics.nowPlaying", { MainActor.assumeIsolated { t.nowPlayingStartsTheLookup() } }), ("lyrics.queryEncoding", t.lrclibQueryEncoding), ("lyrics.live", t.lrclibLive)]
}

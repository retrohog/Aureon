import Foundation
import AVFoundation
import CryptoKit

/// A Subsonic-compatible server in memory.
final class FakeSubsonic: HTTPClient, @unchecked Sendable {
    struct Song { var id: String; var title: String; var album: String; var albumID: String; var artist: String; var track: Int; var year: Int; var genre: String; var suffix: String; var data: Data; var duration: Double }
    let user = "listener", password = "pa+ss word", salt = "c19b2d"
    private let lock = NSLock()
    var songs: [Song] = []
    var supportsRange = true
    private(set) var log: [String] = []
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return log.count }
    var openSubsonic = true

    private func json(_ body: [String: Any], status: String = "ok") -> (Data, Int) {
        var r = body; r["status"] = status; r["version"] = "1.16.1"; r["type"] = "navidrome"; r["serverVersion"] = "0.52"; r["openSubsonic"] = openSubsonic
        return (try! JSONSerialization.data(withJSONObject: ["subsonic-response": r]), 200)
    }
    private func fail(_ code: Int, _ msg: String) -> (Data, Int) { json(["error": ["code": code, "message": msg]], status: "failed") }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock(); log.append(request.url?.path ?? "" ); let songs = self.songs; lock.unlock()
        guard let url = request.url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (Data(), 400) }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { $1 }
        guard c.path.hasPrefix("/rest/") else { return (Data("<html>not a subsonic server</html>".utf8), 200) }
        let method = String(c.path.dropFirst("/rest/".count))
        let want = Insecure.MD5.hash(data: Data((password + (q["s"] ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
        guard q["u"] == user, q["t"] == want else { return method == "download" || method == "getCoverArt" ? (Data(), 401) : fail(40, "Wrong username or password") }
        switch method {
        case "ping": return json([:])
        case "getAlbumList2":
            var albums: [[String: Any]] = []
            var seen = Set<String>()
            for s in songs where seen.insert(s.albumID).inserted { albums.append(["id": s.albumID, "name": s.album, "artist": s.artist, "songCount": songs.filter { $0.albumID == s.albumID }.count]) }
            albums.sort { ($0["name"] as! String) < ($1["name"] as! String) }
            let off = Int(q["offset"] ?? "0") ?? 0, size = Int(q["size"] ?? "10") ?? 10
            return json(["albumList2": ["album": Array(albums.dropFirst(off).prefix(size))]])
        case "getAlbum":
            let list = songs.filter { $0.albumID == q["id"] }
            guard let first = list.first else { return fail(70, "Album not found") }
            return json(["album": ["id": first.albumID, "name": first.album, "song": list.sorted { $0.track < $1.track }.map(entry)]])
        case "getSong":
            guard let s = songs.first(where: { $0.id == q["id"] }) else { return fail(70, "Song not found") }
            return json(["song": entry(s)])
        case "download":
            guard let s = songs.first(where: { $0.id == q["id"] }) else { return (Data(), 404) }
            if let r = request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes="), supportsRange {
                let n = r.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard n.count == 2, n[0] < s.data.count else { return (Data(), 416) }
                return (s.data.subdata(in: n[0]..<min(n[1] + 1, s.data.count)), 206)
            }
            return (s.data, 200)
        case "getCoverArt": return songs.contains { $0.id == q["id"] || "al-\($0.albumID)" == q["id"] } ? (Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]), 200) : (Data(), 404)
        default: return fail(0, "unknown method")
        }
    }

    private func entry(_ s: Song) -> [String: Any] {
        ["id": s.id, "title": s.title, "album": s.album, "albumId": s.albumID, "artist": s.artist, "track": s.track, "year": s.year, "genre": s.genre, "duration": Int(s.duration), "size": s.data.count,
         "suffix": s.suffix, "samplingRate": 44_100, "bitDepth": 16, "channelCount": 2, "coverArt": "al-\(s.albumID)", "musicBrainzId": "mbid-\(s.id)", "albumArtists": [["name": s.artist]]]
    }
}

struct StreamingTests {
    let dir = tempDir("streaming")

    private func flacFile() -> URL {
        let url = dir.appendingPathComponent("stream.flac")
        do {
            let f = try! AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16], commonFormat: .pcmFormatInt16, interleaved: true)
            let n = 44_100 * 12
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!; b.frameLength = AVAudioFrameCount(n)
            var x: UInt64 = 5
            for i in 0..<(n * 2) { x = x &* 6364136223846793005 &+ 1; b.int16ChannelData![0][i] = Int16(truncatingIfNeeded: Int(x >> 52) + Int(8000 * sin(Double(i / 2) * 0.02))) }
            try! f.write(from: b)
        }
        return url
    }

    private func library(_ data: Data) -> FakeSubsonic {
        let s = FakeSubsonic()
        var n = 0
        for (album, artist, year, genre) in [("Alpha", "Ada", 1999, "Rock"), ("Beta", "Bo", 2005, "Jazz"), ("Gamma", "Cy", 2011, "Electronic")] {
            for t in 1...3 { n += 1; s.songs.append(.init(id: "s\(n)", title: "\(album) \(t)", album: album, albumID: "a-\(album)", artist: artist, track: t, year: year, genre: genre, suffix: "flac", data: data, duration: 12)) }
        }
        return s
    }

    private func registry(_ s: FakeSubsonic, password: String? = nil) -> (SubsonicRegistry, SubsonicProfile) {
        let reg = SubsonicRegistry()
        reg.secrets = MemorySecretStore(); reg.http = s
        reg.defaults = UserDefaults(suiteName: "aureon.subsonictest.\(UUID().uuidString.prefix(6))")!
        var p = SubsonicProfile(); p.name = "Home"; p.url = "https://music.example.com"; p.username = s.user
        reg.save(p, password: password ?? s.password)
        return (reg, p)
    }

    func subsonicClientTalksToTheServer() {
        let s = library(Data([1, 2, 3]))
        let c = SubsonicClient(urlString: "music.example.com/", username: s.user, password: s.password, http: s)!
        c.salt = { s.salt }
        expect(c.base.absoluteString == "https://music.example.com", "scheme added, trailing slash dropped: \(c.base)")
        let info = try! runAsync { try await c.ping() }.get()
        expect(info.apiVersion == "1.16.1" && info.type == "navidrome" && info.openSubsonic, "\(info)")
        let u = c.url("download", [URLQueryItem(name: "id", value: "a+b c")]).absoluteString
        expect(u.contains("/rest/download?") && u.contains("u=listener") && u.contains("v=1.16.1") && u.contains("c=Aureon") && u.contains("id=a%2Bb%20c") && !u.contains("pa+ss") && !u.contains("pa%2Bss"), "the password itself is never in the address: \(u)")
        let t = u.components(separatedBy: "&t=")[1].prefix(32)
        expect(String(t) == Insecure.MD5.hash(data: Data((s.password + s.salt).utf8)).map { String(format: "%02x", $0) }.joined(), "token = md5(password + salt)")

        let all = try! runAsync { try await c.albums(offset: 0, size: 2) }.get(), rest = try! runAsync { try await c.albums(offset: 2, size: 2) }.get()
        expect(all.map(\.name) == ["Alpha", "Beta"] && rest.map(\.name) == ["Gamma"] && all[0].songCount == 3, "paging")
        let songs = try! runAsync { try await c.songs(inAlbum: "a-Beta") }.get()
        expect(songs.map(\.title) == ["Beta 1", "Beta 2", "Beta 3"] && songs[0].artist == "Bo" && songs[0].year == 2005 && songs[0].genre == "Jazz" && songs[0].suffix == "flac" && songs[0].sampleRate == 44_100 && songs[0].bitDepth == 16 && songs[0].musicBrainzID == "mbid-s4" && songs[0].albumArtist == "Bo", "\(songs[0])")

        func problem(_ user: String, _ pw: String, _ url: String = "https://music.example.com") -> String {
            let bad = SubsonicClient(urlString: url, username: user, password: pw, http: s)!
            if case .failure(let e) = runAsync({ try await bad.ping() }) { return e.localizedDescription }
            return "no error"
        }
        expect(problem(s.user, "nope").contains("user name or password"), problem(s.user, "nope"))
        let html = SubsonicClient(urlString: "https://x", username: "u", password: "p", http: { final class H: HTTPClient, @unchecked Sendable { func send(_ r: URLRequest) async throws -> (Data, Int) { (Data("<html></html>".utf8), 200) } }; return H() }())!
        if case .failure(let e) = runAsync({ try await html.ping() }) { expect(e.localizedDescription.contains("Subsonic"), e.localizedDescription) } else { expect(false, "html must fail") }
        expect(SubsonicClient(urlString: "", username: "", password: "") == nil && SubsonicClient(urlString: "http://", username: "", password: "") == nil, "empty addresses are rejected")
        let parsed = SubsonicPath.parse(SubsonicPath.make(profile: "p1", song: "al-9f.3", suffix: "flac"))
        expect(parsed?.profile == "p1" && parsed?.song == "al-9f.3" && SubsonicPath.parse("/x/y.flac") == nil)
    }

    func importingAServer() {
        let s = library(Data([1, 2, 3]))
        let (reg, p) = registry(s)
        let lib = try! LibraryStore()
        let r1 = try! SubsonicImporter.run(profile: p, registry: reg, store: lib)
        expect(r1.albums == 3 && r1.songs == 9 && r1.failed == 0, "\(r1)")
        let t = lib.track(path: SubsonicPath.make(profile: p.id, song: "s5", suffix: "flac"))
        expect(t?.title == "Beta 2" && t?.artistLine == "Bo" && t?.releaseTitle == "Beta" && t?.trackNumber == 2 && t?.year == 2005 && t?.codec == "FLAC" && t?.duration == 12 && t?.sampleRate == 44_100 && t?.genres == ["Jazz"] && t?.mbRecordingID == "mbid-s5", "\(String(describing: t))")
        expect(lib.stats().tracks == 9 && lib.stats().releases == 3, "\(lib.stats())")
        // again: nothing doubles; then one album disappears from the server
        _ = try! SubsonicImporter.run(profile: p, registry: reg, store: lib)
        expect(lib.stats().tracks == 9, "importing twice does not duplicate")
        s.songs.removeAll { $0.albumID == "a-Gamma" }
        let r3 = try! SubsonicImporter.run(profile: p, registry: reg, store: lib)
        expect(r3.removed == 3 && lib.stats().tracks == 6, "\(r3) \(lib.stats())")
        // wrong password
        let (reg2, p2) = registry(s, password: "wrong")
        do { _ = try SubsonicImporter.run(profile: p2, registry: reg2, store: lib); expect(false, "must throw") } catch { expect(error.localizedDescription.contains("password"), error.localizedDescription) }
        expect(lib.stats().tracks == 6, "a failed import changes nothing")
    }

    func serverTracksPlayLikeFiles() {
        let file = flacFile()
        let data = try! Data(contentsOf: file)
        let s = library(data)
        let (reg, p) = registry(s)
        let shared = SubsonicRegistry.shared
        shared.secrets = reg.secrets; shared.http = s; shared.defaults = reg.defaults
        shared.save(p, password: s.password)
        defer { shared.remove(p.id) }
        let path1 = SubsonicPath.make(profile: p.id, song: "s1", suffix: "flac"), path2 = SubsonicPath.make(profile: p.id, song: "s2", suffix: "flac")

        let local = readAll(try! LosslessFile(path: file.path))
        let sink = RecordingSink(speed: 20)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let pl = Player()
        pl.setQueue([path1, path2]); pl.start(options: o)
        _ = pl.waitUntilFinished(timeout: 20)
        let got = sink.samples, lead = got.firstIndex { $0 != 0 } ?? 0
        expect(pl.status.finished && pl.status.errors.isEmpty, "\(pl.status.errors)")
        expect(got.count >= local.count * 2 && Array(got[lead..<(lead + local.count)]) == local && Array(got[(lead + local.count)..<(lead + 2 * local.count)]) == local, "two tracks from the server arrive bit for bit, back to back")
        expect(s.log.filter { $0 == "/rest/download" }.count >= 2, "the audio came from the server")

        // analysers and artwork
        let r = R128.analyze(path: path1), r0 = R128.analyze(path: file.path)
        expect(r != nil && r?.integratedLUFS == r0?.integratedLUFS, "loudness from the stream equals the local figure")
        if case .success(let art) = runAsync({ await MetadataEngine.artwork(path: path1) }) { expect(art == Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]), "cover art comes from the server") } else { expect(false, "art") }

        // problems
        s.supportsRange = false
        shared.remove(p.id); shared.save(p, password: s.password)
        let noRange = SubsonicPath.make(profile: p.id, song: "s3", suffix: "flac")
        let truncated: Bool = {
            guard let f = try? openLossless(path: noRange) else { return true }                         // refused outright
            return readAll(f).count < local.count                                                        // or cut short, never misread
        }()
        expect(truncated, "a server that cannot serve ranges is refused or cut short, never misread")
        s.supportsRange = true
        expect((try? openLossless(path: SubsonicPath.make(profile: p.id, song: "nope", suffix: "flac"))) == nil, "an unknown song cannot be opened")
        expect((try? openLossless(path: SubsonicPath.make(profile: "gone", song: "s1", suffix: "flac"))) == nil, "neither can one from a server that was removed")
    }
}

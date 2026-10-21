import Foundation
import Darwin

/// A stand-in for Discord: listens on a real Unix socket and speaks the IPC framing.
final class FakeDiscord: @unchecked Sendable {
    let dir: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var _frames: [(op: UInt32, json: [String: Any])] = []
    private var _connections = 0
    var errorReply: (Int, String)? = nil
    var dropAfterFirstActivity = false
    private var running = true

    init() {
        dir = "/tmp/aur-\(getpid())-\(UInt32.random(in: 0..<1_000_000))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array("\(dir)/discord-ipc-0".utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in path.enumerated() { p[i] = UInt8(bitPattern: b) } }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(listenFD, 4)
        Thread { [self] in acceptLoop() }.start()
    }

    var frames: [(op: UInt32, json: [String: Any])] { lock.lock(); defer { lock.unlock() }; return _frames }
    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }

    private func readExactly(_ fd: Int32, _ n: Int) -> Data? {
        var out = Data(); var buf = [UInt8](repeating: 0, count: n)
        while out.count < n { let r = recv(fd, &buf, n - out.count, 0); if r <= 0 { return nil }; out.append(contentsOf: buf.prefix(r)) }
        return out
    }
    private func readFrame(_ fd: Int32) -> (UInt32, [String: Any])? {
        guard let h = readExactly(fd, 8) else { return nil }
        let op = h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let len = Int(h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }.littleEndian)
        guard let body = len == 0 ? Data() : readExactly(fd, len) else { return nil }
        return (op, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
    }
    private func write(_ fd: Int32, _ d: Data) { _ = d.withUnsafeBytes { send(fd, $0.baseAddress!, d.count, 0) } }

    private func acceptLoop() {
        while running {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }
            lock.lock(); _connections += 1; lock.unlock()
            var activities = 0
            while let (op, json) = readFrame(c) {
                lock.lock(); _frames.append((op, json)); lock.unlock()
                if op == 0 { write(c, DiscordFrame.encode(op: 1, json: ["cmd": "DISPATCH", "evt": "READY", "data": ["v": 1], "nonce": NSNull()])) }
                else if op == 1, (json["cmd"] as? String) == "SET_ACTIVITY" {
                    activities += 1
                    if let (code, msg) = errorReply { write(c, DiscordFrame.encode(op: 1, json: ["cmd": "SET_ACTIVITY", "evt": "ERROR", "data": ["code": code, "message": msg], "nonce": json["nonce"] ?? NSNull()])) }
                    else { write(c, DiscordFrame.encode(op: 1, json: ["cmd": "SET_ACTIVITY", "evt": NSNull(), "data": [:], "nonce": json["nonce"] ?? NSNull()])) }
                    if dropAfterFirstActivity && activities == 1 { break }          // Discord quits after the first update
                }
            }
            close(c)
        }
    }

    func stop() { running = false; close(listenFD); try? FileManager.default.removeItem(atPath: dir) }
}

/// A scripted scrobble service for queue tests.
final class FakeService: ScrobbleService, @unchecked Sendable {
    let name: String
    var isConfigured = true
    var behaviour: ([(track: ScrobbleTrack, playedAt: Date)]) -> ScrobbleError? = { _ in nil }
    private let lock = NSLock()
    private(set) var batches: [[ScrobbleTrack]] = []
    init(_ name: String = "Fake") { self.name = name }
    func nowPlaying(_ t: ScrobbleTrack) async throws {}
    func scrobble(_ plays: [(track: ScrobbleTrack, playedAt: Date)]) async throws {
        lock.lock(); batches.append(plays.map(\.track)); lock.unlock()
        if let e = behaviour(plays) { throw e }
    }
    var sent: [ScrobbleTrack] { lock.lock(); defer { lock.unlock() }; return batches.flatMap { $0 } }
}

struct DiscordTests {
    func np(_ codec: String, _ bits: Int, _ rate: Double) -> NowPlayingInfo { NowPlayingInfo(id: "1", title: "So What", artist: "Miles Davis", album: "Kind of Blue", duration: 562, codec: codec, bitDepth: bits, sampleRate: rate) }

    func qualityLabels() {
        expect(np("FLAC", 24, 192_000).qualityLabel == "FLAC · 24-bit / 192 kHz", np("FLAC", 24, 192_000).qualityLabel)
        expect(np("ALAC", 16, 44_100).qualityLabel == "ALAC · 16-bit / 44.1 kHz" && np("FLAC", 24, 88_200).qualityLabel == "FLAC · 24-bit / 88.2 kHz")
        expect(np("DSD64", 1, 2_822_400).qualityLabel == "DSD64 · 2.8 MHz" && np("DSD128", 1, 5_644_800).qualityLabel == "DSD128 · 5.6 MHz", np("DSD128", 1, 5_644_800).qualityLabel)
        expect(np("", 0, 0).qualityLabel == "")
    }

    func textRules() {
        expect(DiscordActivity.clean("A").count >= 2 && DiscordActivity.clean("").count >= 2, "Discord rejects fields shorter than 2 characters")
        expect(DiscordActivity.clean(String(repeating: "x", count: 300)).count <= 128)
        expect(DiscordActivity.clean("  Hello  ") == "Hello")
    }

    func presenceBuilder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var t = np("FLAC", 24, 192_000); t.coverURL = "https://coverartarchive.org/release-group/x/front-500"
        let a = DiscordPresence.activity(for: t, position: 100, playing: true, now: now)
        expect(a.kind == .listening && a.details == "So What" && a.state == "by Miles Davis")
        expect(a.start == 1_699_999_900 && a.end == 1_699_999_900 + 562, "elapsed time is derived from the playback position: \(String(describing: a.start))")
        expect(a.largeImage == t.coverURL && a.largeText == "Kind of Blue" && a.smallText == "FLAC · 24-bit / 192 kHz" && a.smallImage == "hires")
        let p = DiscordPresence.activity(for: t, position: 100, playing: false, now: now)
        expect(p.start == nil && p.end == nil && p.state.hasPrefix("Paused"), "no timestamps while paused, or Discord would keep counting")
        var d = np("DSD64", 1, 2_822_400); d.coverURL = nil; d.duration = 0
        let ds = DiscordPresence.activity(for: d, position: 5, playing: true, now: now, fallbackImage: "aureon")
        expect(ds.largeImage == "aureon" && ds.smallImage == "dsd" && ds.end == nil && ds.start != nil)
        let j = a.json
        expect((j["type"] as? Int) == 2 && (j["timestamps"] as? [String: Any])?["start"] as? Int == 1_699_999_900 && ((j["assets"] as? [String: Any])?["small_text"] as? String) == "FLAC · 24-bit / 192 kHz")
    }

    func frameEncoding() {
        let d = DiscordFrame.encode(op: 1, json: ["a": 1])
        expect(d.count == 8 + 7 && d[0] == 1 && d[1] == 0 && d[2] == 0 && d[3] == 0 && d[4] == 7 && d[5] == 0, "opcode and length are little-endian UInt32: \(Array(d.prefix(8)))")
        expect(String(data: d.dropFirst(8), encoding: .utf8) == "{\"a\":1}")
    }

    func handshakeAndActivityOverARealSocket() {
        let srv = FakeDiscord(); defer { srv.stop() }
        let ipc = DiscordIPC(clientID: "123456789", directories: { [srv.dir] })
        try! ipc.connect()
        expect(ipc.isConnected)
        var a = DiscordActivity(details: "So What", state: "by Miles Davis", start: 1_700_000_000, end: 1_700_000_562)
        a.largeImage = "https://example.com/c.jpg"; a.smallText = "FLAC · 24-bit / 192 kHz"
        try! ipc.setActivity(a)
        try! ipc.setActivity(nil)
        let f = srv.frames
        expect(f.count == 3 && f[0].op == 0 && (f[0].json["client_id"] as? String) == "123456789" && (f[0].json["v"] as? Int) == 1, "handshake: \(f.first?.json ?? [:])")
        let args = f[1].json["args"] as? [String: Any]
        expect(f[1].op == 1 && (f[1].json["cmd"] as? String) == "SET_ACTIVITY" && (args?["pid"] as? Int) == Int(getpid()), "SET_ACTIVITY carries our pid")
        let act = args?["activity"] as? [String: Any]
        expect((act?["details"] as? String) == "So What" && (act?["state"] as? String) == "by Miles Davis" && (act?["type"] as? Int) == 2, "\(act ?? [:])")
        expect(((act?["timestamps"] as? [String: Any])?["end"] as? Int) == 1_700_000_562 && ((act?["assets"] as? [String: Any])?["large_image"] as? String) == "https://example.com/c.jpg")
        expect((f[2].json["args"] as? [String: Any])?["activity"] == nil, "clearing the presence sends no activity")
        expect(!((f[1].json["nonce"] as? String) ?? "").isEmpty && (f[1].json["nonce"] as? String) != (f[2].json["nonce"] as? String), "every request has its own nonce")
        ipc.close(); expect(!ipc.isConnected)
    }

    func discordNotRunning() {
        let empty = "/tmp/aur-empty-\(getpid())"; try? FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let ipc = DiscordIPC(clientID: "1", directories: { [empty] })
        do { try ipc.setActivity(nil); expect(false, "must throw") } catch { expect(error.localizedDescription.contains("not running"), "\(error.localizedDescription)") }
        try? FileManager.default.removeItem(atPath: empty)
    }

    func discordErrorsAreSurfaced() {
        let srv = FakeDiscord(); srv.errorReply = (4000, "Invalid activity"); defer { srv.stop() }
        let ipc = DiscordIPC(clientID: "1", directories: { [srv.dir] })
        do { try ipc.setActivity(DiscordActivity(details: "ab", state: "cd")); expect(false, "must throw") }
        catch let e as DiscordError { if case .rpc(let c, let m) = e { expect(c == 4000 && m == "Invalid activity") } else { expect(false, "\(e)") } }
        catch { expect(false, "\(error)") }
    }

    func reconnectsWhenDiscordRestarts() {
        let srv = FakeDiscord(); srv.dropAfterFirstActivity = true; defer { srv.stop() }
        let ipc = DiscordIPC(clientID: "1", directories: { [srv.dir] })
        try! ipc.setActivity(DiscordActivity(details: "one", state: "x1"))        // server then hangs up
        usleep(100_000)
        try! ipc.setActivity(DiscordActivity(details: "two", state: "x2"))        // must reconnect transparently
        expect(srv.connections == 2, "connections \(srv.connections)")
        let acts = srv.frames.filter { ($0.json["cmd"] as? String) == "SET_ACTIVITY" }
        expect(acts.count == 2 && ((acts[1].json["args"] as? [String: Any])?["activity"] as? [String: Any])?["details"] as? String == "two")
    }
}

struct ScrobbleServiceTests {
    func form(_ r: URLRequest) -> [String: String] {
        var out: [String: String] = [:]
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        let query = r.url?.query ?? ""
        for kv in (body.isEmpty ? query : body).split(separator: "&") {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            out[p[0].removingPercentEncoding ?? p[0]] = (p.count > 1 ? p[1] : "").removingPercentEncoding ?? ""
        }
        return out
    }

    /// MD5 by macOS's own tool, as an independent oracle. The text goes through stdin: Foundation's Process would decompose a non-ASCII
    /// argument to NFD ("ó" → "o" + U+0301) and change the bytes being hashed.
    func md5Tool(_ s: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/sbin/md5"); p.arguments = ["-q"]
        let inp = Pipe(), out = Pipe(); p.standardInput = inp; p.standardOutput = out
        try? p.run()
        inp.fileHandleForWriting.write(Data(s.utf8)); try? inp.fileHandleForWriting.close()
        p.waitUntilExit()
        return (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func lastfmSignature() {
        let params = ["method": "track.scrobble", "artist[0]": "Sigur Rós", "track[0]": "Svefn-g-englar", "timestamp[0]": "1700000000", "api_key": "KEY", "sk": "SESSION", "format": "json", "callback": "x"]
        let base0 = "api_keyKEYartist[0]Sigur Rósmethodtrack.scrobbleskSESSIONtimestamp[0]1700000000track[0]Svefn-g-englarSECRET"
        let sig = LastFMClient.signature(params, secret: "SECRET")
        expect(LastFMClient.signatureBase(params, secret: "SECRET") == base0, "signed string: \(LastFMClient.signatureBase(params, secret: "SECRET"))")
        // Documented construction: sort by name, concatenate name+value, append the secret, md5. format/callback are excluded.
        let base = "api_keyKEYartist[0]Sigur Rósmethodtrack.scrobbleskSESSIONtimestamp[0]1700000000track[0]Svefn-g-englarSECRET"
        expect(sig == md5Tool(base), "\(sig) vs the md5 tool's \(md5Tool(base))")
        expect(sig.count == 32 && sig == sig.lowercased())
        expect(LastFMClient.signature(["a": "1", "b": "2"], secret: "s") == LastFMClient.signature(["b": "2", "a": "1"], secret: "s"), "order-independent")
        expect(LastFMClient.signature(params, secret: "OTHER") != sig)
    }

    func lastfmRequests() {
        let http = StubHTTP(); http.on("audioscrobbler.com", #"{"nowplaying":{}}"#)
        let c = LastFMClient(apiKey: "KEY", secret: "SECRET", sessionKey: "SK", http: http)
        expect(c.isConfigured && !LastFMClient(apiKey: "KEY", secret: "S", http: http).isConfigured)
        var t = ScrobbleTrack(artist: "Miles Davis", title: "So What", album: "Kind of Blue", duration: 562, trackNumber: 1, mbRecordingID: "rec-1"); t.albumArtist = "Miles Davis"
        _ = try! runAsync { try await c.nowPlaying(t) }.get()
        let r = http.requests[0], f = form(r)
        expect(r.httpMethod == "POST" && f["method"] == "track.updateNowPlaying" && f["api_key"] == "KEY" && f["sk"] == "SK" && f["format"] == "json", "\(f)")
        expect(f["artist"] == "Miles Davis" && f["track"] == "So What" && f["album"] == "Kind of Blue" && f["duration"] == "562" && f["mbid"] == "rec-1" && f["trackNumber"] == "1")
        var signed = f; signed.removeValue(forKey: "api_sig")
        expect(f["api_sig"] == LastFMClient.signature(signed, secret: "SECRET"), "the signature covers every sent parameter")

        // batch of 120 plays → three requests of 50, 50, 20 with indexed fields
        let plays = (0..<120).map { (ScrobbleTrack(artist: "A\($0)", title: "T\($0)"), Date(timeIntervalSince1970: 1_700_000_000 + Double($0))) }
        _ = try! runAsync { try await c.scrobble(plays) }.get()
        let reqs = http.requests.dropFirst().map(form)
        expect(reqs.count == 3 && reqs[0]["artist[49]"] == "A49" && reqs[0]["artist[50]"] == nil && reqs[2]["artist[19]"] == "A119" && reqs[1]["timestamp[0]"] == "1700000050" && reqs[0]["method"] == "track.scrobble", "\(reqs.count) requests")
        // the sign-in step is refused politely
        if case .failure(let e) = runAsync({ try await LastFMClient(apiKey: "K", secret: "S", http: http).nowPlaying(t) }) { expect((e as? ScrobbleError) == .auth("not signed in to Last.fm")) } else { expect(false) }
    }

    func lastfmErrorMapping() {
        func result(_ body: String, status: Int = 200) -> ScrobbleError? {
            let h = StubHTTP(); h.on("audioscrobbler.com", body, status: status)
            if case .failure(let e) = runAsync({ try await LastFMClient(apiKey: "K", secret: "S", sessionKey: "SK", http: h).scrobble([(ScrobbleTrack(artist: "a", title: "b"), Date())]) }) { return e as? ScrobbleError }
            return nil
        }
        expect(result(#"{"error":9,"message":"Invalid session key"}"#) == .auth("Invalid session key"))
        expect(result(#"{"error":4,"message":"Auth failed"}"#) == .auth("Auth failed") && result(#"{"error":26,"message":"suspended"}"#) == .auth("suspended"))
        expect(result(#"{"error":11,"message":"Service offline"}"#) == .temporary("Service offline") && result(#"{"error":29,"message":"Rate limit"}"#) == .temporary("Rate limit"))
        expect(result(#"{"error":6,"message":"Invalid parameters"}"#) == .rejected("Invalid parameters"))
        expect(result("", status: 503) == .temporary("Last.fm answered HTTP 503"))
        expect(result(#"{"scrobbles":{}}"#) == nil, "success")
        final class Down: HTTPClient { func send(_ r: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) } }
        if case .failure(let e) = runAsync({ try await LastFMClient(apiKey: "K", secret: "S", sessionKey: "SK", http: Down()).scrobble([(ScrobbleTrack(artist: "a", title: "b"), Date())]) }) {
            if case .temporary = (e as? ScrobbleError) ?? .rejected("") { } else { expect(false, "offline is temporary: \(e)") }
        } else { expect(false) }
    }

    func lastfmSignIn() {
        let http = StubHTTP()
        http.on("method=auth.getToken", #"{"token":"TOK123"}"#)
        http.on("method=auth.getSession", #"{"session":{"name":"alice","key":"SESSKEY","subscriber":0}}"#)
        let c = LastFMClient(apiKey: "KEY", secret: "SECRET", http: http)
        let (token, url) = try! runAsync { try await c.authToken() }.get()
        expect(token == "TOK123" && url.absoluteString == "https://www.last.fm/api/auth/?api_key=KEY&token=TOK123", url.absoluteString)
        let f1 = form(http.requests[0])
        expect(f1["api_sig"] == LastFMClient.signature(["method": "auth.getToken", "api_key": "KEY"], secret: "SECRET"), "getToken is signed")
        let (key, user) = try! runAsync { try await c.session(token: token) }.get()
        expect(key == "SESSKEY" && user == "alice" && c.sessionKey == "SESSKEY" && c.isConfigured)
        expect(form(http.requests[1])["token"] == "TOK123")
    }

    func listenbrainz() {
        let http = StubHTTP(); http.on("listenbrainz", #"{"status":"ok"}"#)
        let c = ListenBrainzClient(token: "tok-1", http: http)
        let t = ScrobbleTrack(artist: "Miles Davis", title: "So What", album: "Kind of Blue", duration: 562, trackNumber: 1, mbRecordingID: "rec-1", mbReleaseID: "rel-1")
        _ = try! runAsync { try await c.nowPlaying(t) }.get()
        _ = try! runAsync { try await c.scrobble([(t, Date(timeIntervalSince1970: 1_700_000_000))]) }.get()
        _ = try! runAsync { try await c.scrobble([(t, Date(timeIntervalSince1970: 1_700_000_000)), (t, Date(timeIntervalSince1970: 1_700_000_900))]) }.get()
        func body(_ i: Int) -> [String: Any] { (try? JSONSerialization.jsonObject(with: http.requests[i].httpBody ?? Data())) as? [String: Any] ?? [:] }
        expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == "Token tok-1" && http.requests[0].url?.path == "/1/submit-listens")
        expect((body(0)["listen_type"] as? String) == "playing_now" && (body(1)["listen_type"] as? String) == "single" && (body(2)["listen_type"] as? String) == "import")
        let pl = (body(1)["payload"] as? [[String: Any]])?.first, md = pl?["track_metadata"] as? [String: Any], info = md?["additional_info"] as? [String: Any]
        expect((pl?["listened_at"] as? Int) == 1_700_000_000 && (md?["artist_name"] as? String) == "Miles Davis" && (md?["track_name"] as? String) == "So What" && (md?["release_name"] as? String) == "Kind of Blue", "\(String(describing: pl))")
        expect((info?["media_player"] as? String) == "Aureon" && (info?["duration_ms"] as? Int) == 562_000 && (info?["recording_mbid"] as? String) == "rec-1" && (info?["release_mbid"] as? String) == "rel-1" && (info?["tracknumber"] as? Int) == 1)
        expect((body(0)["payload"] as? [[String: Any]])?.first?["listened_at"] == nil, "playing_now carries no timestamp")
        expect(((body(2)["payload"] as? [[String: Any]])?.count ?? 0) == 2)

        func status(_ code: Int) -> ScrobbleError? {
            let h = StubHTTP(); h.on("listenbrainz", #"{"code":1,"error":"nope"}"#, status: code)
            if case .failure(let e) = runAsync({ try await ListenBrainzClient(token: "t", http: h).scrobble([(t, Date())]) }) { return e as? ScrobbleError }; return nil
        }
        expect(status(401) == .auth("nope") && status(400) == .rejected("nope") && status(429) == .temporary("nope") && status(500) == .temporary("nope") && status(200) == nil)
        let v = StubHTTP(); v.on("validate-token", #"{"code":200,"message":"Token valid.","valid":true,"user_name":"alice"}"#)
        expect(runAsync({ try await ListenBrainzClient(token: "t", http: v).validate() }).isSuccessWith { $0 == "alice" })
        let bad = StubHTTP(); bad.on("validate-token", #"{"code":200,"message":"Token invalid.","valid":false}"#)
        expect(runAsync({ try await ListenBrainzClient(token: "t", http: bad).validate() }).isFailure)
        expect(runAsync({ try await ListenBrainzClient(token: "", http: v).scrobble([(t, Date())]) }).isFailure && !ListenBrainzClient(token: "").isConfigured)
    }
}

struct ScrobbleTrackerTests {
    func info(_ id: String, duration: Double, artist: String = "Artist") -> NowPlayingInfo { NowPlayingInfo(id: id, title: "T-\(id)", artist: artist, duration: duration) }

    /// Drives the tracker with a simulated clock at 10 updates per second.
    final class Sim {
        let t = ScrobbleTracker(); var now = Date(timeIntervalSince1970: 1_700_000_000)
        var nowPlaying: [String] = [], scrobbles: [(String, Date)] = [], scrobbleAt: [Double] = []
        var elapsed = 0.0
        init() { t.onNowPlaying = { [unowned self] in nowPlaying.append($0.title) }; t.onScrobble = { [unowned self] tr, d in scrobbles.append((tr.title, d)); scrobbleAt.append(elapsed) } }
        func run(_ n: NowPlayingInfo?, from: Double, seconds: Double, playing: Bool = true) {
            var p = from; let steps = Int(seconds * 10)
            for _ in 0..<steps { now = now.addingTimeInterval(0.1); elapsed += 0.1; if playing { p += 0.1 }; t.update(n, position: p, playing: playing, now: now) }
        }
    }

    func thresholdRule() {
        expect(ScrobbleTracker.threshold(duration: 200) == 100 && ScrobbleTracker.threshold(duration: 600) == 240 && ScrobbleTracker.threshold(duration: 480) == 240)
        expect(ScrobbleTracker.threshold(duration: 29) == nil && ScrobbleTracker.threshold(duration: 30) == 15, "tracks under 30 s never scrobble")
        expect(ScrobbleTracker.threshold(duration: 0) == 240, "unknown length: the 4-minute rule")
    }

    func scrobblesAtHalfOrFourMinutes() {
        let a = Sim(); let n = info("a", duration: 200)
        a.run(n, from: 0, seconds: 99); expect(a.scrobbles.isEmpty, "not yet at 99 s")
        a.run(n, from: 99, seconds: 3)
        expect(a.scrobbles.count == 1 && abs(a.scrobbleAt[0] - 100) < 0.3 && a.nowPlaying == ["T-a"], "scrobbled at \(a.scrobbleAt) s")
        a.run(n, from: 102, seconds: 98); expect(a.scrobbles.count == 1, "only once per play")
        expect(a.scrobbles[0].1 == Date(timeIntervalSince1970: 1_700_000_000), "the timestamp is when the play started")

        let b = Sim(); let long = info("b", duration: 900)
        b.run(long, from: 0, seconds: 300)
        expect(b.scrobbles.count == 1 && abs(b.scrobbleAt[0] - 240) < 0.3, "long tracks scrobble after 4 minutes: \(b.scrobbleAt)")
        let c = Sim(); c.run(info("c", duration: 25), from: 0, seconds: 25); expect(c.scrobbles.isEmpty && c.nowPlaying.count == 1, "short tracks only announce now-playing")
    }

    func pausingAndSeekingDoNotCount() {
        let s = Sim(); let n = info("a", duration: 200)
        s.run(n, from: 0, seconds: 40)
        s.run(n, from: 40, seconds: 100, playing: false)
        expect(s.scrobbles.isEmpty, "100 s of pause is not listening")
        s.run(n, from: 40, seconds: 59)
        expect(s.scrobbles.isEmpty, "99 s listened so far")
        s.run(n, from: 99, seconds: 2)
        expect(s.scrobbles.count == 1 && abs(s.scrobbleAt[0] - 200) < 0.5, "counted only playing time (40 s + 60 s of playing, 100 s paused = 200 s of wall clock): at \(s.scrobbleAt)")

        let k = Sim(); k.run(n, from: 0, seconds: 5)
        k.run(n, from: 190, seconds: 5)                                                   // skipping to the end is not listening either
        expect(k.scrobbles.isEmpty, "a forward seek does not make the song count")
    }

    func changingTracksAndRepeats() {
        let s = Sim(); let a = info("a", duration: 200), b = info("b", duration: 200)
        s.run(a, from: 0, seconds: 50)
        s.run(b, from: 0, seconds: 110)
        expect(s.nowPlaying == ["T-a", "T-b"] && s.scrobbles.map(\.0) == ["T-b"], "skipping A early gives no scrobble for A: \(s.scrobbles.map(\.0))")
        // B plays on to its end, then repeats from the start: a new play, announced and counted again
        s.run(b, from: 110, seconds: 90)
        s.run(b, from: 0, seconds: 110)
        expect(s.nowPlaying == ["T-a", "T-b", "T-b"] && s.scrobbles.map(\.0) == ["T-b", "T-b"], "repeat: \(s.nowPlaying) \(s.scrobbles.map(\.0))")
        s.run(nil, from: 0, seconds: 1)
        s.run(a, from: 0, seconds: 1)
        expect(s.nowPlaying.count == 4, "after playback stopped, a new track announces again")
    }

    func gapsAndMissingTags() {
        let t = ScrobbleTracker(); var scrobbled = 0
        t.onScrobble = { _, _ in scrobbled += 1 }
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let n = NowPlayingInfo(id: "a", title: "T", artist: "A", duration: 100)
        t.update(n, position: 0, playing: true, now: now)
        now = now.addingTimeInterval(3600); t.update(n, position: 1, playing: true, now: now)            // the Mac slept for an hour
        expect(scrobbled == 0, "a long gap counts for at most 2 s")
        var calls = 0
        let u = ScrobbleTracker(); u.onNowPlaying = { _ in calls += 1 }; u.onScrobble = { _, _ in calls += 1 }
        let noArtist = NowPlayingInfo(id: "x", title: "T", artist: "", duration: 100)
        var tt = Date(); for _ in 0..<2000 { tt = tt.addingTimeInterval(0.1); u.update(noArtist, position: 1, playing: true, now: tt) }
        expect(calls == 0, "services require artist and title: nothing is sent for untagged tracks")
        expect(ScrobbleTrack(NowPlayingInfo(id: "1", title: "T", artist: "A", album: "", duration: 0))?.album == nil && ScrobbleTrack(NowPlayingInfo(id: "1", title: "T", artist: "A", duration: 200.4))?.duration == 200)
    }
}

struct ScrobbleQueueTests {
    let dir = tempDir("sq")
    func queue() -> (ScrobbleQueue, URL) { let u = dir.appendingPathComponent("q-\(UUID().uuidString.prefix(6)).json"); return (ScrobbleQueue(url: u), u) }
    func tr(_ i: Int) -> ScrobbleTrack { ScrobbleTrack(artist: "A", title: "T\(i)") }
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func persistsAndSends() {
        let (q, url) = queue()
        q.add(tr(2), playedAt: t0.addingTimeInterval(200), services: ["Fake", "Other"])
        q.add(tr(1), playedAt: t0.addingTimeInterval(100), services: ["Fake"])
        expect(ScrobbleQueue(url: url).pending.count == 3, "survives a restart")
        let svc = FakeService()
        let r = runAsync { await q.flush(svc, now: self.t0.addingTimeInterval(300)) }.value
        expect(r?.sent == 2 && svc.sent.map(\.title) == ["T1", "T2"], "oldest first: \(svc.sent.map(\.title))")
        expect(q.count(for: "Fake") == 0 && q.count(for: "Other") == 1, "other services keep their own copies")
        expect(ScrobbleQueue(url: url).pending.count == 1)
    }

    func temporaryFailuresBackOff() {
        let (q, _) = queue(); let svc = FakeService()
        svc.behaviour = { _ in .temporary("offline") }
        q.add(tr(1), playedAt: t0, services: ["Fake"])
        var now = t0.addingTimeInterval(10)
        let r1 = runAsync { await q.flush(svc, now: now) }.value
        expect(r1?.retryLater == 1 && q.pending[0].attempts == 1 && q.pending[0].nextTry == now.addingTimeInterval(30), "first retry in 30 s")
        let calls = svc.batches.count
        _ = runAsync { await q.flush(svc, now: now.addingTimeInterval(10)) }.value
        expect(svc.batches.count == calls, "nothing is sent before the back-off expires")
        now = now.addingTimeInterval(31)
        _ = runAsync { await q.flush(svc, now: now) }.value
        expect(q.pending[0].attempts == 2 && q.pending[0].nextTry == now.addingTimeInterval(60), "then 60 s")
        for _ in 0..<10 { now = now.addingTimeInterval(4000); _ = runAsync { await q.flush(svc, now: now) }.value }
        expect(q.pending[0].nextTry.timeIntervalSince(now) <= 3600, "back-off is capped at an hour")
        svc.behaviour = { _ in nil }
        now = now.addingTimeInterval(4000)
        let ok = runAsync { await q.flush(svc, now: now) }.value
        expect(ok?.sent == 1 && q.pending.isEmpty, "delivered once the service is back")
    }

    func permanentRejectionsAreDropped() {
        let (q, _) = queue(); let svc = FakeService()
        for i in 1...3 { q.add(tr(i), playedAt: t0.addingTimeInterval(Double(i)), services: ["Fake"]) }
        svc.behaviour = { plays in plays.contains { $0.track.title == "T2" } ? .rejected("bad track") : nil }
        let r = runAsync { await q.flush(svc, now: self.t0.addingTimeInterval(100)) }.value
        expect(r?.sent == 2 && r?.dropped == 1 && q.pending.isEmpty, "the offending play is isolated and dropped: \(String(describing: r))")
        expect(Set(svc.sent.map(\.title)).isSuperset(of: ["T1", "T3"]))
    }

    func authProblemsKeepEverything() {
        let (q, _) = queue(); let svc = FakeService()
        svc.behaviour = { _ in .auth("Invalid session key") }
        q.add(tr(1), playedAt: t0, services: ["Fake"]); q.add(tr(2), playedAt: t0.addingTimeInterval(1), services: ["Fake"])
        let r = runAsync { await q.flush(svc, now: self.t0.addingTimeInterval(10)) }.value
        expect(r?.needsAuth == true && r?.lastError == "Invalid session key" && q.pending.count == 2, "plays wait until the user signs in again")
        svc.behaviour = { _ in nil }
        let r2 = runAsync { await q.flush(svc, now: self.t0.addingTimeInterval(20)) }.value
        expect(r2?.sent == 2 && q.pending.isEmpty, "and are delivered afterwards")
    }

    func oldPlaysAndBatching() {
        let (q, _) = queue(); let svc = FakeService()
        q.add(tr(0), playedAt: t0.addingTimeInterval(-20 * 86_400), services: ["Fake"])
        for i in 1...120 { q.add(tr(i), playedAt: t0.addingTimeInterval(Double(i)), services: ["Fake"]) }
        let r = runAsync { await q.flush(svc, now: self.t0.addingTimeInterval(200)) }.value
        expect(r?.sent == 120 && !svc.sent.contains { $0.title == "T0" }, "plays older than two weeks are discarded (Last.fm refuses them)")
        expect(svc.batches.map(\.count) == [50, 50, 20], "batches of 50: \(svc.batches.map(\.count))")
    }

    func secretStoreRoundTrip() {
        let s = MemorySecretStore()
        s.set("abc", for: "lastfm.secret"); expect(s.get("lastfm.secret") == "abc")
        s.set(nil, for: "lastfm.secret"); expect(s.get("lastfm.secret") == nil)
    }
}

extension Result where Success == ScrobbleQueue.Outcome { var value: ScrobbleQueue.Outcome? { if case .success(let v) = self { return v }; return nil } }

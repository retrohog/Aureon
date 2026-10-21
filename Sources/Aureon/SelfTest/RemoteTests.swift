import Foundation
import AppKit

final class RemoteFixture: @unchecked Sendable {
    let dir: URL
    let player = Player()
    let sink = RecordingSink(speed: 4)
    let library: LibraryStore
    let controller: RemoteController
    var server: RemoteServer?
    var paths: [String] = []

    init(roots: [String] = []) {
        let d = realPath(tempDir("remote-\(UUID().uuidString.prefix(6))"))
        dir = d
        library = try! LibraryStore()
        var o = PlayerOptions(); let s = sink; o.sinkFactory = { _ in s }
        controller = RemoteController(player: player, library: library, options: o, name: "Test server", allowedRoots: roots.map { $0 == "ROOT" ? d.path : $0 })
        for n in 1...3 {
            let f = writeWAV(dir.appendingPathComponent("t\(n).wav"), rate: 8000, bits: 24, frames: 40_000) { i, c in c == 0 ? n : i }
            paths.append(f.path)
        }
        var items: [(facts: FileFacts, tags: TrackMetadata)] = []
        for (i, p) in paths.enumerated() {
            var m = TrackMetadata(); m.title = ["So What", "Blue in Green", "Freddie Freeloader"][i]; m.album = "Kind of Blue"; m.year = 1959; m.trackNumber = i + 1
            m.credits = [Credit(role: .artist, name: "Miles Davis"), Credit(role: .albumArtist, name: "Miles Davis")]
            items.append((FileFacts(path: p, duration: 5, sampleRate: 8000, bitDepth: 24, channels: 2, codec: "PCM", mtime: 1, size: 1), m))
        }
        library.upsert(items)
    }

    func start(token: String = "secret-token", authTimeout: TimeInterval = 5) -> URL {
        let s = RemoteServer(controller: controller, token: token)
        s.authTimeout = authTimeout
        let port = try! s.start()
        server = s
        return URL(string: "ws://127.0.0.1:\(port)/")!
    }
    func stop() { server?.stop(); player.stop() }
}

struct RemoteTests {
    func handle(_ c: RemoteController, _ m: String, _ p: JSONObject = [:]) -> Result<Data, Error> { runAsync { try await c.handle(method: m, params: p) } }
    func json(_ d: Data) -> Any { (try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)) ?? NSNull() }
    func code(_ r: Result<Data, Error>) -> Int? { if case .failure(let e) = r { return (e as? RemoteError)?.code }; return nil }

    func protocolAuthentication() {
        let nonce = RemoteProtocol.newNonce()
        let good = RemoteProtocol.hmac(token: "tok", nonce: nonce)
        expect(good.count == 64 && RemoteProtocol.verify(token: "tok", nonce: nonce, response: good) && RemoteProtocol.verify(token: "tok", nonce: nonce, response: good.uppercased()))
        expect(!RemoteProtocol.verify(token: "other", nonce: nonce, response: good) && !RemoteProtocol.verify(token: "tok", nonce: "different", response: good) && !RemoteProtocol.verify(token: "tok", nonce: nonce, response: ""))
        expect(RemoteProtocol.newToken().count == 48 && RemoteProtocol.newToken() != RemoteProtocol.newToken(), "tokens are random")
        // RFC 4231 test case 2: HMAC-SHA256("Jefe", "what do ya want for nothing?")
        expect(RemoteProtocol.hmac(token: "Jefe", nonce: "what do ya want for nothing?") == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC matches the RFC 4231 vector")
        let r = RPC.response(id: 7, resultJSON: Data("{\"a\":1}".utf8)), e = RPC.error(id: "x", RemoteError.notFound("nope")), n = RPC.notification(method: "status", resultJSON: Data("[1]".utf8))
        expect((json(r) as? [String: Any])?["id"] as? Int == 7 && ((json(r) as? [String: Any])?["result"] as? [String: Any])?["a"] as? Int == 1)
        expect((((json(e) as? [String: Any])?["error"]) as? [String: Any])?["code"] as? Int == 404 && (json(e) as? [String: Any])?["id"] as? String == "x")
        expect((json(n) as? [String: Any])?["method"] as? String == "status" && (json(n) as? [String: Any])?["id"] == nil)
    }

    func controllerQueueAndErrors() {
        let f = RemoteFixture(roots: ["ROOT"]); defer { f.stop() }
        let c = f.controller
        expect(code(handle(c, "nonsense")) == RemoteErrorCode.methodNotFound)
        let ids = f.library.allTracks().map(\.id)
        let added = json(try! handle(c, "queue.add", ["trackIDs": ids]).get()) as? [[String: Any]]
        expect(added?.count == 3 && f.player.queue.count == 3 && added?[0]["title"] as? String != nil, "added \(String(describing: added?.count))")
        let snap = try! JSONDecoder().decode(QueueSnapshot.self, from: try! handle(c, "queue.get").get())
        expect(snap.entries.count == 3 && snap.entries.allSatisfy { $0.artist == "Miles Davis" && $0.trackID != nil && $0.duration == 5 }, "entries are enriched from the library")
        expect(code(handle(c, "queue.add", ["paths": ["/etc/hosts"]])) == RemoteErrorCode.forbidden, "paths outside the music folders are refused")
        expect(code(handle(c, "queue.add", ["paths": [f.dir.path + "/../../../etc/hosts"]])) == RemoteErrorCode.forbidden, "…including ../ tricks")
        expect(code(handle(c, "queue.add", ["trackIDs": ["nope"]])) == RemoteErrorCode.notFound && code(handle(c, "queue.add")) == RemoteErrorCode.invalidParams)
        _ = try! handle(c, "queue.add", ["paths": [f.paths[0]], "at": 0]).get()
        expect(f.player.queue.count == 4 && f.player.queue[0].path == f.paths[0], "inserted at the front")
        let move = try! JSONDecoder().decode(QueueSnapshot.self, from: try! handle(c, "queue.move", ["from": [0], "to": 4]).get())
        expect(move.entries.last?.path == f.paths[0], "moved to the end")
        expect(code(handle(c, "queue.move", ["from": [9], "to": 0])) == RemoteErrorCode.invalidParams && code(handle(c, "queue.move", ["from": [0], "to": 99])) == RemoteErrorCode.invalidParams)
        let rm = try! JSONDecoder().decode(QueueSnapshot.self, from: try! handle(c, "queue.remove", ["ids": [move.entries[0].id]]).get())
        expect(rm.entries.count == 3 && code(handle(c, "queue.remove", ["ids": ["not-a-uuid"]])) == RemoteErrorCode.invalidParams)
        _ = try! handle(c, "queue.clear").get()
        expect(f.player.queue.isEmpty)
    }

    func controllerSettings() {
        let f = RemoteFixture(roots: ["ROOT"]); defer { f.stop() }
        var s = PlaybackSettings(); s.replayGain.mode = .album; s.rt.crossfeed = CrossfeedSettings(enabled: true, cutoffHz: 650, feedDB: 9.5); s.ram.enabled = true
        let obj = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! JSONObject
        let back = try! JSONDecoder().decode(PlaybackSettings.self, from: try! handle(f.controller, "settings.set", ["settings": obj]).get())
        expect(back == s && f.player.settings == s, "settings.set applies")
        expect(try! JSONDecoder().decode(PlaybackSettings.self, from: try! handle(f.controller, "settings.get").get()) == s)
        expect(code(handle(f.controller, "settings.set", ["settings": ["ram": ["enabled": "banana"]]])) == RemoteErrorCode.invalidParams, "a malformed schema is rejected")
        expect(code(handle(f.controller, "settings.set")) == RemoteErrorCode.invalidParams)
        var bad = s; bad.rt.convolution = ConvolutionSettings(enabled: true, irPath: "/etc/passwd")
        let badObj = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(bad)) as! JSONObject
        expect(code(handle(f.controller, "settings.set", ["settings": badObj])) == RemoteErrorCode.forbidden, "an impulse response outside the music folders is refused")
        expect(f.player.settings == s, "refused settings change nothing")
    }

    func controllerTransport() {
        let f = RemoteFixture(); defer { f.stop() }
        let c = f.controller
        expect(code(handle(c, "player.play")) == RemoteErrorCode.invalidParams, "nothing to play")
        _ = try! handle(c, "queue.add", ["paths": f.paths]).get()
        let waitState = { (want: String) -> Bool in let end = Date().addingTimeInterval(5); while Date() < end { if f.controller.statusDTO().state == want { return true }; usleep(20_000) }; return false }
        _ = try! handle(c, "player.play").get()
        expect(waitState("playing"))
        var st = f.controller.statusDTO()
        expect(st.title == "So What" && st.artist == "Miles Davis" && st.codec == "PCM" && st.sampleRate == 8000 && st.bitDepth == 24 && st.duration > 4.9 && !st.deviceName.isEmpty, "\(st)")
        _ = try! handle(c, "player.pause").get(); expect(waitState("paused"))
        _ = try! handle(c, "player.resume").get(); expect(waitState("playing"))
        _ = try! handle(c, "player.next").get()
        let end = Date().addingTimeInterval(5); while f.controller.statusDTO().title != "Blue in Green" && Date() < end { usleep(20_000) }
        st = f.controller.statusDTO(); expect(st.title == "Blue in Green", "next → \(st.title)")
        _ = try! handle(c, "player.seek", ["seconds": 3.0]).get(); usleep(400_000)
        expect(f.controller.statusDTO().position >= 2.9, "seek: \(f.controller.statusDTO().position)")
        expect(code(handle(c, "player.seek", ["seconds": -1])) == RemoteErrorCode.invalidParams && code(handle(c, "player.play", ["entryID": UUID().uuidString])) == RemoteErrorCode.notFound)
        let third = f.player.queue[2].id.uuidString
        _ = try! handle(c, "player.play", ["entryID": third]).get()
        let end2 = Date().addingTimeInterval(5); while f.controller.statusDTO().title != "Freddie Freeloader" && Date() < end2 { usleep(20_000) }
        expect(f.controller.statusDTO().title == "Freddie Freeloader", "jump by entry id")
        _ = try! handle(c, "player.stop").get(); expect(f.controller.statusDTO().state == "idle")
        expect(code(handle(c, "volume.set", ["volume": 2])) == RemoteErrorCode.invalidParams)
    }

    func controllerLibrary() {
        let f = RemoteFixture(); defer { f.stop() }
        let c = f.controller
        expect(try! JSONDecoder().decode(LibraryStats.self, from: try! handle(c, "library.stats").get()).tracks == 3)
        expect(try! JSONDecoder().decode([PartyDTO].self, from: try! handle(c, "library.parties", ["role": "artist"]).get()).map(\.name) == ["Miles Davis"])
        expect(code(handle(c, "library.parties", ["role": "wizard"])) == RemoteErrorCode.invalidParams && code(handle(c, "library.search")) == RemoteErrorCode.invalidParams)
        let rel = try! JSONDecoder().decode([ReleaseDTO].self, from: try! handle(c, "library.releases", ["search": "kind of"]).get())
        expect(rel.count == 1 && rel[0].trackCount == 3)
        let tr = try! JSONDecoder().decode([TrackDTO].self, from: try! handle(c, "library.tracks", ["releaseID": rel[0].id]).get())
        expect(tr.map(\.title) == ["So What", "Blue in Green", "Freddie Freeloader"], "\(tr.map(\.title))")
        expect(try! JSONDecoder().decode(SearchResults.self, from: try! handle(c, "library.search", ["q": "blue in"]).get()).tracks.count == 1 && (try! JSONDecoder().decode(SearchResults.self, from: try! handle(c, "library.search", ["q": "blue"]).get())).tracks.count == 3, "the album name matches too")
        let first = try! JSONDecoder().decode(LibraryChangeSet.self, from: try! handle(c, "library.changes", ["cursor": 0, "limit": 2]).get())
        expect(first.changes.count == 2 && first.more && first.cursor == first.changes.last!.seq, "a page of 2 with more to come: \(first.changes.count), more \(first.more)")
        var seen = first.changes.map(\.seq), cursor = first.cursor, more = first.more
        while more {
            let page = try! JSONDecoder().decode(LibraryChangeSet.self, from: try! handle(c, "library.changes", ["cursor": cursor, "limit": 2]).get())
            seen += page.changes.map(\.seq); cursor = page.cursor; more = page.more
        }
        let all = try! JSONDecoder().decode(LibraryChangeSet.self, from: try! handle(c, "library.changes", ["cursor": 0]).get())
        expect(!all.more && all.revision == f.library.revision && seen == all.changes.map(\.seq), "paging visits every change exactly once, in order")
        expect(Set(seen).count == seen.count && seen == Array(1...Int64(seen.count)), "sequence numbers are unique and gap-free")
        let none = try! JSONDecoder().decode(LibraryChangeSet.self, from: try! handle(c, "library.changes", ["cursor": all.cursor]).get())
        expect(none.changes.isEmpty && !none.more && none.cursor == all.cursor)
    }

    func artworkThumbnails() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return }
        let f = RemoteFixture(); defer { f.stop() }
        let wav = sineWAV(f.dir.appendingPathComponent("art.wav"), rate: 44_100, freq: 440, amp: 0.3, seconds: 0.5)
        let flac = f.dir.appendingPathComponent("art.flac"); expect(encode(wav, to: flac, alac: false))
        let img = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<600 { for y in 0..<400 { img.setColor(NSColor(red: CGFloat(x) / 600, green: CGFloat(y) / 400, blue: 0.5, alpha: 1), atX: x, y: y) } }
        injectFLACPicture(flac.path, image: img.representation(using: .png, properties: [:])!)
        var m = TrackMetadata(); m.title = "Art"
        f.library.upsert([(FileFacts(path: flac.path, duration: 1, sampleRate: 44_100, bitDepth: 16, channels: 2, codec: "FLAC", mtime: 1, size: 1), m)])
        let id = f.library.track(path: flac.path)!.id
        let res = json(try! handle(f.controller, "art.get", ["trackID": id, "size": 128]).get()) as? [String: Any]
        let data = Data(base64Encoded: res?["base64"] as? String ?? "")
        let decoded = data.flatMap { NSImage(data: $0) }
        expect(res?["mime"] as? String == "image/jpeg" && decoded != nil, "a JPEG came back: \(String(describing: res?["mime"]))")
        if let rep = decoded?.representations.first { expect(max(rep.pixelsWide, rep.pixelsHigh) <= 128 && max(rep.pixelsWide, rep.pixelsHigh) >= 100, "scaled to ≤128 px, got \(rep.pixelsWide)×\(rep.pixelsHigh)") }
        let none = json(try! handle(f.controller, "art.get", ["trackID": f.library.allTracks().first { $0.title == "So What" }!.id]).get())
        expect(none is NSNull, "a track without art answers null")
        expect(code(handle(f.controller, "art.get", ["trackID": "missing"])) == RemoteErrorCode.notFound)
    }

    // MARK: over a real WebSocket

    func connect(_ url: URL, token: String) -> RemoteClient {
        let c = RemoteClient(url: url, token: token)
        try! runAsync { try await c.connect() }.get()
        return c
    }

    /// Waits for an event named `name` whose payload satisfies `where` (earlier, stale events are skipped).
    func waitEvent(_ c: RemoteClient, _ name: String, timeout: TimeInterval = 5, where match: @escaping @Sendable (Data) -> Bool = { _ in true }) -> Data? {
        (try? runAsync(timeout: timeout + 3) { () -> Data? in
            let deadline = Date().addingTimeInterval(timeout)
            for await e in c.events { if e.name == name && match(e.params) { return e.params }; if Date() > deadline { return nil } }
            return nil
        }.get()) ?? nil
    }
    func collect(_ c: RemoteClient, until names: Set<String>, timeout: TimeInterval = 5) -> [String: Data] {
        var out: [String: Data] = [:]
        for n in names { if let d = waitEvent(c, n, timeout: timeout) { out[n] = d } }
        return out
    }

    func authenticationOverTheSocket() {
        let f = RemoteFixture(); defer { f.stop() }
        let url = f.start(token: "secret-token", authTimeout: 0.6)
        let ok = RemoteClient(url: url, token: "secret-token")
        expect(runAsync { try await ok.connect() }.isSuccessWith { _ in true } && ok.serverName == "Test server")
        expect(runAsync { try await ok.call("ping", as: String.self) }.isSuccessWith { $0 == "pong" })
        expect(f.server?.authenticatedClients == 1)

        let bad = RemoteClient(url: url, token: "wrong")
        if case .failure(let e) = runAsync({ try await bad.connect() }) { expect((e as? RemoteError)?.code == 401, "wrong token: \(e)") } else { expect(false, "a wrong token must be refused") }

        // skipping authentication: the first request is answered with 401 and the socket is closed
        let raw = URLSession(configuration: .ephemeral).webSocketTask(with: url); raw.resume()
        let outcome = runAsync { () -> String in
            _ = try await raw.receive()                                                 // hello
            try await raw.send(.string(String(decoding: RPC.request(id: 1, method: "queue.get"), as: UTF8.self)))
            if case .string(let s) = try await raw.receive() { return s }
            return ""
        }
        expect(outcome.isSuccessWith { $0.contains("401") && $0.contains("authenticate first") }, "unauthenticated request: \(outcome)")
        // never authenticating: closed after the timeout
        let idle = URLSession(configuration: .ephemeral).webSocketTask(with: url); idle.resume()
        let t = runAsync { () -> Bool in _ = try await idle.receive(); if case .string(let s) = try await idle.receive() { return s.contains("timed out") }; return false }
        expect(t.isSuccessWith { $0 }, "an idle connection is dropped: \(t)")
        usleep(300_000)
        expect(f.server?.authenticatedClients == 1, "only the good client remains")
        ok.close()
    }

    func twoClientsStayInSync() {
        let f = RemoteFixture(); defer { f.stop() }
        let url = f.start()
        let a = connect(url, token: "secret-token"), b = connect(url, token: "secret-token")
        defer { a.close(); b.close() }
        let ids = f.library.allTracks().map(\.id)
        _ = try! runAsync { try await a.callData("queue.add", ["trackIDs": ids]) }.get()
        let snap = waitEvent(b, "queue.changed") { (try? JSONDecoder().decode(QueueSnapshot.self, from: $0))?.entries.count == 3 }.flatMap { try? JSONDecoder().decode(QueueSnapshot.self, from: $0) }
        expect(snap?.entries.count == 3 && snap?.entries.first?.title == "So What", "B hears about A's queue change: \(String(describing: snap?.entries.count))")
        let moved = try! runAsync { try await b.call("queue.move", ["from": [2], "to": 0], as: QueueSnapshot.self) }.get()
        expect(moved.entries.first?.title == "Freddie Freeloader" && moved.revision > (snap?.revision ?? 0))
        let again = waitEvent(a, "queue.changed") { (try? JSONDecoder().decode(QueueSnapshot.self, from: $0))?.entries.first?.title == "Freddie Freeloader" }
        expect(again != nil, "A hears about B's move")

        var s = PlaybackSettings(); s.polarityInverted = true
        _ = try! runAsync { try await a.callData("settings.set", ["settings": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s))]) }.get()
        let sc = waitEvent(b, "settings.changed") { (try? JSONDecoder().decode(PlaybackSettings.self, from: $0))?.polarityInverted == true }
        expect(sc != nil, "settings changes are broadcast")
    }

    func statusIsPushedDuringPlayback() {
        let f = RemoteFixture(); defer { f.stop() }
        let url = f.start()
        let a = connect(url, token: "secret-token"); defer { a.close() }
        _ = try! runAsync { try await a.callData("queue.add", ["paths": f.paths]) }.get()
        _ = try! runAsync { try await a.call("player.play", as: RemoteStatus.self) }.get()
        let positions = try! runAsync(timeout: 12) { () -> [Double] in
            var out: [Double] = []; let end = Date().addingTimeInterval(4)
            for await e in a.events where e.name == "status" {
                if let s = try? JSONDecoder().decode(RemoteStatus.self, from: e.params), s.state == "playing" { out.append(s.position) }
                if out.count >= 3 || Date() > end { break }
            }
            return out
        }.get()
        expect(positions.count >= 3 && positions == positions.sorted() && positions.last! > positions.first!, "playback position advances in pushed status: \(positions)")
        _ = try! runAsync { try await a.callData("player.pause") }.get()
        let paused = try! runAsync(timeout: 8) { () -> Bool in
            let end = Date().addingTimeInterval(4)
            for await e in a.events where e.name == "status" { if (try? JSONDecoder().decode(RemoteStatus.self, from: e.params))?.state == "paused" { return true }; if Date() > end { break } }
            return false
        }.get()
        expect(paused, "pausing is pushed immediately")
    }

    func manyConcurrentCalls() {
        let f = RemoteFixture(); defer { f.stop() }
        let a = connect(f.start(), token: "secret-token"); defer { a.close() }
        let r = runAsync { () -> Int in
            try await withThrowingTaskGroup(of: Int.self) { g in
                for i in 0..<40 { g.addTask { let s: LibraryStats = try await a.call("library.stats"); let p: String = try await a.call("ping"); return s.tracks + (p == "pong" ? i : -1000) } }
                var sum = 0; for try await v in g { sum += v }; return sum
            }
        }
        expect(r.isSuccessWith { $0 == 40 * 3 + (0..<40).reduce(0, +) }, "responses are matched to the right requests: \(r)")
        if case .failure(let e) = runAsync({ try await a.callData("queue.add", ["paths": ["x"], "trackIDs": []]) }) { _ = e } else { }
        if case .failure(let e) = runAsync({ try await a.callData("nonexistent") }) { expect((e as? RemoteError)?.code == RemoteErrorCode.methodNotFound, "\(e)") } else { expect(false) }
    }

    func libraryMirrorConverges() {
        let f = RemoteFixture(); defer { f.stop() }
        // a library big enough to need several pages: 1200 tracks over 40 albums / 60 artists
        var items: [(facts: FileFacts, tags: TrackMetadata)] = []
        for i in 0..<1200 {
            var m = TrackMetadata(); m.title = "Song \(i)"; m.album = "Album \(i / 30)"; m.trackNumber = i % 30 + 1; m.year = 1990 + i % 30
            m.credits = [Credit(role: .artist, name: "Artist \(i % 60)"), Credit(role: .albumArtist, name: "Artist \((i / 30) % 60)")]
            if i % 10 == 0 { m.workTitle = "Work \(i / 10)"; m.credits.append(Credit(role: .composer, name: "Composer \(i % 7)")) }
            items.append((FileFacts(path: "/lib/\(i).flac", duration: 200, sampleRate: 44_100, bitDepth: 16, channels: 2, codec: "FLAC", mtime: 1, size: 1), m))
        }
        f.library.upsert(items)
        let a = connect(f.start(), token: "secret-token"); defer { a.close() }
        let mirror = LibraryMirror()
        let t0 = Date()
        try! runAsync(timeout: 60) { try await a.syncLibrary(into: mirror) }.get()
        let took = Date().timeIntervalSince(t0)
        let stats = f.library.stats()
        expect(mirror.tracks.count == 1203 && mirror.tracks.count == stats.tracks && mirror.releases.count == stats.releases && mirror.works.count == stats.works, "mirror \(mirror.tracks.count)/\(mirror.releases.count)/\(mirror.works.count) vs server \(stats)")
        expect(mirror.revision == f.library.revision && Set(mirror.tracks.keys) == Set(f.library.allTracks(limit: 5000).map(\.id)), "same tracks, same revision, in \(String(format: "%.1f", took)) s")

        // the server library changes: new tracks, a re-tag, and deletions
        var m = TrackMetadata(); m.title = "Brand new"; m.album = "Fresh"; m.credits = [Credit(role: .artist, name: "New Artist")]
        var retag = items[5].tags; retag.title = "Renamed"
        f.library.upsert([(FileFacts(path: "/lib/new.flac", duration: 1, sampleRate: 44_100, bitDepth: 16, channels: 2, codec: "FLAC", mtime: 1, size: 1), m), (items[5].facts, retag)])
        f.library.removeTracks(under: "/lib", keeping: Set(items.prefix(1100).map(\.facts.path)) .union(["/lib/new.flac"]))
        let rev = f.library.revision
        let ev = waitEvent(a, "library.changed") { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["revision"] as? Int64 == rev || ((try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["revision"] as? Int).map(Int64.init) == rev }
        expect(ev != nil, "the server announces the new library revision")
        try! runAsync(timeout: 60) { try await a.syncLibrary(into: mirror) }.get()
        let server = f.library.allTracks(limit: 5000)
        expect(Set(mirror.tracks.keys) == Set(server.map(\.id)) && mirror.tracks.count == 1104, "after deletions and additions the mirror matches: \(mirror.tracks.count) vs \(server.count)")
        expect(mirror.tracks.values.contains { $0.title == "Renamed" } && !mirror.tracks.values.contains { $0.title == "Song 5" } && mirror.tracks.values.contains { $0.title == "Brand new" })
        let st2 = f.library.stats()
        expect(mirror.releases.count == st2.releases && mirror.works.count == st2.works && mirror.revision == f.library.revision, "orphaned albums and works were deleted on the client too")
        expect(Set(mirror.parties.keys).isSuperset(of: Set(server.flatMap { $0.credits.map(\.partyID) })), "every credited person is known to the client")
    }

    func serverStopDisconnectsClients() {
        let f = RemoteFixture(); defer { f.player.stop() }
        let a = connect(f.start(), token: "secret-token")
        f.server?.stop()
        usleep(300_000)
        if case .failure = runAsync({ try await a.callData("ping") }) { expect(true) } else { expect(false, "calls after the server stops must fail") }
        expect(f.server?.connectedClients == 0)
    }
}

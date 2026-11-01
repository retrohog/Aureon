import Foundation
import SwiftUI
import AppKit
import SlskCore

// Soulseek, with no internet: a fake server and fake peers on the loopback interface. The client itself refuses any other host while tests run.

private func wait(_ t: Double = 10, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(t)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
    return cond()
}

private final class SBox<T>: @unchecked Sendable {
    private let l = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
    func mutate(_ f: (inout T) -> Void) { l.lock(); f(&v); l.unlock() }
}

private final class FakeServer: @unchecked Sendable {
    let loop = SlskLoop()
    var port: UInt16 = 0
    let passwords: SBox<[String: String]> = SBox(["me": "secret"])
    let addresses: SBox<[String: (String, UInt16)]> = SBox([:])
    let codes: SBox<[UInt32]> = SBox([])
    let clientPort = SBox<UInt16>(0)
    let logins = SBox(0)
    let links = SBox<[SlskLink]>([])
    let onSearch = SBox<((UInt32, String) -> Void)?>(nil)

    init() {
        loop.start()
        port = loop.listen(port: 0, loopbackOnly: true) { [self] l in
            var parser = SlskFrameParser()
            links.mutate { $0.append(l) }
            l.onData = { d in for f in parser.feed(d) { self.handle(f, l) } }
        } ?? 0
    }
    func dropAll() { for l in links.value { l.close() }; links.value = [] }
    func stop() { dropAll(); loop.stop() }

    private func handle(_ f: SlskFrame, _ l: SlskLink) {
        codes.mutate { $0.append(f.code) }
        var r = SlskReader(f.payload)
        switch f.code {
        case SlskCode.login:
            let u = r.string() ?? "", p = r.string() ?? ""; _ = r.u32(); let h = r.string() ?? ""
            logins.mutate { $0 += 1 }
            var w = SlskWriter()
            if passwords.value[u] == p, h == SlskMessages.md5Hex(u + p) { w.bool(true); w.string("Welcome"); w.u32(0x7f000001); w.string(SlskMessages.md5Hex(p)); w.bool(false) }
            else { w.bool(false); w.string("INVALIDPASS") }
            l.send(SlskFrame(code: SlskCode.login, payload: w.data))
        case SlskCode.setListenPort: clientPort.value = UInt16(r.u32() ?? 0)
        case SlskCode.getPeerAddress:
            let u = r.string() ?? ""
            if let a = addresses.value[u] { l.send(SlskPeerAddress.encode(user: u, host: a.0, port: a.1)) }
            else { l.send(SlskPeerAddress.encode(user: u, host: "0.0.0.0", port: 0)) }
        case SlskCode.fileSearch: onSearch.value?(r.u32() ?? 0, r.string() ?? "")
        default: break
        }
    }
}

/// A peer that has files: answers QueueUpload, sends TransferRequest, opens the file link to the client and sends the bytes.
private final class FakeUploader: @unchecked Sendable {
    enum Mode { case normal, abortAfter(Int), short(Int), hold(Int) }
    /// How the file link gets to the client: the peer opens it itself, sends its first bytes in separate pieces, or has the server ask the client to open it.
    enum Link { case direct, splitStart, relayed }
    let link = SBox<Link>(.direct)
    let relay = SBox<((UInt16, UInt32) -> Void)?>(nil)
    let loop = SlskLoop()
    var port: UInt16 = 0
    let name: String
    let data: Data
    let announcedSize: UInt64
    let mode: SBox<Mode>
    let serverPort: SBox<UInt16>
    let offsets = SBox<[UInt64]>([])
    let queued = SBox<[String]>([])
    let gate = DispatchSemaphore(value: 0)
    let clientPort: () -> UInt16
    let denies: SBox<String?> = SBox(nil)
    let queueOnly = SBox(false)

    init(name: String, data: Data, announced: UInt64? = nil, mode: Mode = .normal, clientPort: @escaping () -> UInt16) {
        self.name = name; self.data = data; announcedSize = announced ?? UInt64(data.count); self.mode = SBox(mode); serverPort = SBox(0); self.clientPort = clientPort
        loop.start()
        port = loop.listen(port: 0, loopbackOnly: true) { [self] l in
            var buf = Data(), inited = false; var parser = SlskFrameParser()
            l.onData = { d in
                if !inited {
                    buf.append(d); guard buf.count >= 4, buf.count >= 4 + Int(buf.u32(at: 0)) else { return }
                    let n = 4 + Int(buf.u32(at: 0)); let rest = Data(buf.dropFirst(n)); inited = true; buf = Data()
                    for f in parser.feed(rest) { self.handle(f, l) }; return
                }
                for f in parser.feed(d) { self.handle(f, l) }
            }
        } ?? 0
    }
    func stop() { loop.stop() }

    private func handle(_ f: SlskFrame, _ l: SlskLink) {
        if f.code == SlskCode.queueUpload {
            var r = SlskReader(f.payload); let path = r.string() ?? ""
            queued.mutate { $0.append(path) }
            if let why = denies.value { l.send(SlskMessages.uploadDenied(path: path, reason: why)); return }
            l.send(SlskMessages.placeInQueue(path: path, place: 14))
            if queueOnly.value { return }
            Thread.sleep(forTimeInterval: 0.05)
            l.send(SlskMessages.transferRequest(direction: 1, token: 77, path: path, size: announcedSize))
        } else if f.code == SlskCode.transferResponse, let r = SlskTransferResponse.parse(f), r.allowed {
            DispatchQueue.global().async { self.sendFile(token: r.token) }
        }
    }

    private func sendFile(token: UInt32) {
        let offset = SBox<UInt64?>(nil); let buf = SBox(Data())
        let linkBox = SBox<SlskLink?>(nil)
        func onOffsetData(_ d: Data) { buf.mutate { $0.append(d) }; if buf.value.count >= 8, offset.value == nil { var r = SlskReader(buf.value); offset.value = r.u64() } }
        switch link.value {
        case .relayed:
            // the client is asked by the server to connect to us; we answer its PierceFirewall and then start the file link
            guard let port = loop.listen(port: 0, loopbackOnly: true, onAccept: { l in
                linkBox.value = l
                var first = Data(); var pierced = false
                l.onData = { d in
                    if !pierced { first.append(d); guard first.count >= 9 else { return }; pierced = true; var w = SlskWriter(); w.u32(token); l.send(w.data); onOffsetData(Data(first.dropFirst(9))); return }
                    onOffsetData(d)
                }
            }) else { return }
            relay.value?(port, 5150)
            guard wait(5, { linkBox.value != nil }) else { return }
        case .direct, .splitStart:
            guard let f = loop.connect(host: "127.0.0.1", port: clientPort(), label: "F") else { return }
            linkBox.value = f
            f.onData = { d in onOffsetData(d) }
            let split = link.value == .splitStart
            f.onConnect = {
                f.send(SlskMessages.peerInit(user: self.name, type: "F", token: 0))
                if split { Thread.sleep(forTimeInterval: 0.25) }
                var w = SlskWriter(); w.u32(token); f.send(w.data)
            }
        }
        guard let f = { () -> SlskLink? in _ = wait(5, { linkBox.value != nil }); return linkBox.value }() else { return }
        guard wait(5, { offset.value != nil }), let off = offset.value else { return }
        offsets.mutate { $0.append(off) }
        let body = data.dropFirst(Int(off))
        switch mode.value {
        case .normal: f.send(Data(body))
        case .abortAfter(let n):
            f.send(Data(body.prefix(n))); Thread.sleep(forTimeInterval: 0.2); f.close()
            mode.value = .normal                                    // the retry gets everything
        case .short(let n): f.send(Data(body.prefix(n))); Thread.sleep(forTimeInterval: 0.2); f.close()
        case .hold(let n): f.send(Data(body.prefix(n))); gate.wait(); f.send(Data(body.dropFirst(n)))
        }
    }
}

private func bytes(_ n: Int, seed: UInt8 = 7) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

private struct Rig {
    let dir: URL, server: FakeServer, client: SlskClient, downloads: URL, incomplete: URL
    var store: SlskStore { client.store }
    init(retryBase: Double = 0.05, maxAttempts: Int = 5) {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slsk-\(UUID().uuidString)")
        downloads = dir.appendingPathComponent("Downloads"); incomplete = dir.appendingPathComponent(".incomplete")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        server = FakeServer()
        var c = SlskConfig(downloadsDir: downloads, incompleteDir: incomplete)
        c.host = "127.0.0.1"; c.port = server.port; c.username = "me"; c.password = "secret"; c.retryBase = retryBase; c.maxAttempts = maxAttempts; c.reconnectBase = 0.1; c.peerTimeout = 3
        client = SlskClient(config: c, store: SlskStore(url: nil), log: SlskLog(), loop: SlskLoop())
        client.startPublishing()
    }
    func online() -> Bool { client.connect(); return wait { client.snapshotNow().state.isOnline } }
    func close() { client.shutdown(); server.stop(); try? FileManager.default.removeItem(at: dir) }
}

struct SoulseekTests {
    func wireFormat() {
        var w = SlskWriter(); w.u32(1); w.string("héllo"); w.u64(1 << 40); w.bool(true)
        var r = SlskReader(w.data)
        expect(r.u32() == 1 && r.string() == "héllo" && r.u64() == 1 << 40 && r.bool() == true && r.isAtEnd, "integers and strings round-trip, little endian")
        expect(SlskReader(Data([5, 0, 0])).remaining == 3)
        var short = SlskReader(Data([9, 0, 0, 0, 65])); expect(short.string() == nil, "a string longer than the data is refused")
        let a = SlskMessages.login(user: "me", password: "secret").encoded() + SlskMessages.ping.encoded() + SlskMessages.fileSearch(token: 5, query: "miles davis").encoded()
        for chunk in [1, 3, 7, 1000] {
            var p = SlskFrameParser(); var got: [SlskFrame] = []; var i = 0
            while i < a.count { got += p.feed(a.subdata(in: i..<min(a.count, i + chunk))); i += chunk }
            expect(got.map(\.code) == [1, 32, 26] && p.pending == 0, "frames survive chunks of \(chunk) bytes")
        }
        var big = SlskFrameParser(); var hdr = SlskWriter(); hdr.u32(0x7fff_ffff); hdr.u32(1); _ = big.feed(hdr.data); expect(big.failed, "an absurd frame length ends the stream")
        let login = SlskMessages.login(user: "me", password: "secret")
        var lr = SlskReader(login.payload); _ = lr.string(); _ = lr.string(); _ = lr.u32()
        expect(lr.string() == SlskMessages.md5Hex("mesecret"), "the login carries md5(username + password)")
        expect(SlskMessages.md5Hex("a") == "0cc175b9c0f1b6a831c399e269772661", "md5 matches the known value")
        let z = bytes(5000); expect(SlskZlib.inflate(SlskZlib.deflate(z)) == z, "zlib round-trip")
        var bad = SlskZlib.deflate(z); bad[bad.count - 1] ^= 0xff; expect(SlskZlib.inflate(bad) == nil, "a damaged checksum is refused")
        expect(SlskZlib.inflate(Data([1, 2, 3])) == nil, "garbage is refused")
        let res = SlskSearchResponse(user: "alice", token: 9, files: [SlskFileResult(path: "S\\Artist\\Album\\01 A.flac", size: 30_000_000, ext: "flac", bitrate: 900, duration: 200, sampleRate: 96000, bitDepth: 24, vbr: false)], freeSlot: true, speed: 1_000_000, queueLength: 3)
        expect(SlskSearchResponse.parse(SlskSearchResponse.encode(res)) == res, "a search response with attributes round-trips")
        // streams made by a real zlib (three compression levels), as other clients send them
        func hex(_ h: String) -> Data { Data(stride(from: 0, to: h.count, by: 2).map { UInt8(h[h.index(h.startIndex, offsetBy: $0)...h.index(h.startIndex, offsetBy: $0 + 1)], radix: 16)! }) }
        for h in ["78016365606048ccc94c4ee5043298809891074804c738c638c518eaa5e52426b75f13028a3030b00031880f5204020e8c40c540fa041033720309882623bddc0263981e66a030908b55cb8d6b0c0c207910000054bc12b6",
                  "789c6365606048ccc94c4ee5043298809891074804c738c638c518eaa5e52426b75f13620001162006f1991820c08111a818489f0069e2866b32d2cb2d3086e96106622017ab961bd720f220000054bc12b6",
                  "78da6365606048ccc94c4ee5043298809891074804c738c638c518eaa5e52426b75f13620001162006f1991820c08111a818489f0069e2866b32d2cb2d3086e96106622017ab961bd720f220000054bc12b6"] {
            let r = SlskSearchResponse.parse(SlskFrame(code: SlskCode.fileSearchResponse, payload: hex(h)))
            expect(r?.user == "alice" && r?.token == 9 && r?.files.count == 2 && r?.files[0].bitrate == 320 && r?.files[0].duration == 200 && r?.freeSlot == true && r?.speed == 55000 && r?.queueLength == 3, "a result made by the real zlib reads correctly: \(String(describing: r))")
        }
        let pa = SlskPeerAddress.encode(user: "u", host: "10.1.2.3", port: 2234)
        expect(SlskPeerAddress.parse(pa)?.host == "10.1.2.3" && SlskPeerAddress.parse(pa)?.port == 2234, "addresses keep their octet order")
        // the bytes a real server sends for 192.168.1.10 are 0a 01 a8 c0
        var rawAddr = SlskWriter(); rawAddr.string("u"); rawAddr.raw(Data([0x0a, 0x01, 0xa8, 0xc0])); rawAddr.u32(2234)
        expect(SlskPeerAddress.parse(SlskFrame(code: SlskCode.getPeerAddress, payload: rawAddr.data))?.host == "192.168.1.10", "an address read from the real wire bytes is 192.168.1.10")
        var rawConn = SlskWriter(); rawConn.string("u"); rawConn.string("P"); rawConn.raw(Data([0x0a, 0x01, 0xa8, 0xc0])); rawConn.u32(2234); rawConn.u32(7); rawConn.bool(false)
        expect(SlskConnectToPeer.parse(SlskFrame(code: SlskCode.connectToPeer, payload: rawConn.data))?.host == "192.168.1.10", "so is a ConnectToPeer address")
        let tr = SlskMessages.transferRequest(direction: 1, token: 4, path: "x\\y.flac", size: 99)
        expect(SlskTransferRequest.parse(tr) == SlskTransferRequest(direction: 1, token: 4, path: "x\\y.flac", size: 99))
        let d = SlskPaths.destination(remote: "Music\\Miles Davis\\Kind of Blue\\01 So What.flac", in: URL(fileURLWithPath: "/dl"))
        expect(d.path == "/dl/Miles Davis/Kind of Blue/01 So What.flac", "Artist/Album from the remote path: \(d.path)")
        expect(!SlskPaths.destination(remote: "..\\..\\x\\..\\etc\\passwd", in: URL(fileURLWithPath: "/dl")).path.contains(".."), "a path cannot climb out of the downloads folder")
        let shares = SlskShares.build(files: [("/Users/me/Music/Jazz/Album/01.flac", 10), ("/Users/me/Other/x.flac", 5)], folders: ["/Users/me/Music/Jazz"])
        expect(shares.count == 1 && shares[0].virtualPath == "Jazz\\Album\\01.flac" && !shares[0].virtualPath.contains("Users"), "only ticked folders, no local path in the name: \(shares.map(\.virtualPath))")
        expect(SlskShares.parseList(SlskShares.listResponse(shares))?.first?.path == "Jazz\\Album\\01.flac", "the share list round-trips")
    }

    func loginAndReconnect() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online(), "logs in to the fake server")
        expect(wait { rig.server.codes.value.contains(SlskCode.sharedFoldersFiles) && rig.server.codes.value.contains(SlskCode.haveNoParent) && rig.server.codes.value.contains(SlskCode.setStatus) }, "sends listen port, status, share counts and HaveNoParent after login")
        expect(rig.client.snapshotNow().listenPort != 0 && rig.server.clientPort.value == rig.client.snapshotNow().listenPort, "tells the server its listening port")
        rig.server.dropAll()
        expect(wait { rig.server.logins.value >= 2 && rig.client.snapshotNow().state.isOnline }, "logs in again after the server drops the link")
        expect(!rig.client.log.all().contains { $0.text.contains("secret") }, "the password is never in the protocol log")
        let bad = Rig(); defer { bad.close() }
        bad.client.config.password = "wrong"; bad.client.connect()
        expect(wait { if case .failed(let r) = bad.client.snapshotNow().state { return r == "INVALIDPASS" } else { return false } }, "a wrong password is reported, not retried forever")
        let n = bad.server.logins.value; Thread.sleep(forTimeInterval: 0.5); expect(bad.server.logins.value == n, "no retry after a refused login")
    }

    func realNetworkIsBlocked() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slsk-\(UUID().uuidString)")
        var c = SlskConfig(downloadsDir: dir, incompleteDir: dir); c.username = "x"; c.password = "y"
        let client = SlskClient(config: c, store: SlskStore(url: nil)); defer { client.shutdown() }
        client.connect()
        expect(wait(3) { if case .failed(let r) = client.snapshotNow().state { return r.hasPrefix("Blocked") } else { return false } }, "tests never connect to server.slsknet.org")
    }

    func searchResults() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        let res = SlskSearchResponse(user: "alice", token: 0, files: (0..<40).map { SlskFileResult(path: "S\\A\\B\\\($0).flac", size: 1000, ext: "flac", bitrate: nil, duration: nil, sampleRate: 44100, bitDepth: 16, vbr: false) }, freeSlot: true, speed: 5, queueLength: 0)
        rig.server.onSearch.value = nil
        rig.client.search("kind of blue")
        expect(wait { rig.client.log.all().contains { $0.text.hasPrefix("FileSearch") } })
        let token = UInt32(rig.client.log.all().last { $0.text.hasPrefix("FileSearch") }!.text.split(separator: " ").last!)!
        var mine = res; mine.token = token
        let loop = SlskLoop(); loop.start(); defer { loop.stop() }
        let l = loop.connect(host: "127.0.0.1", port: rig.client.listeningPort, label: "peer")!
        l.onConnect = { l.send(SlskMessages.peerInit(user: "alice", type: "P", token: 0)); l.send(SlskSearchResponse.encode(mine)) }
        expect(wait { rig.client.snapshotNow().resultCount == 40 }, "a zlib-compressed result from a peer who connects to us arrives")
        let snap = rig.client.snapshotNow()
        expect(snap.results.first?.user == "alice" && snap.results.first?.files.count == 40, "results are grouped by user")
        var stale = res; stale.token = token &+ 1
        l.send(SlskSearchResponse.encode(stale)); Thread.sleep(forTimeInterval: 0.3)
        expect(rig.client.snapshotNow().resultCount == 40, "results for an old search are dropped")
        rig.client.store.ban("alice", true); l.send(SlskSearchResponse.encode(mine)); Thread.sleep(forTimeInterval: 0.3)
        expect(rig.client.snapshotNow().resultCount == 40, "a blocked user's results are dropped")
    }

    /// A peer behind a firewall: it asks the server, the server tells us (code 18), we connect out and pierce, and its results arrive on our link.
    func searchResultsViaRelayedConnect() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        rig.client.search("relay test")
        expect(wait { rig.client.log.all().contains { $0.text.hasPrefix("FileSearch") } })
        let token = UInt32(rig.client.log.all().last { $0.text.hasPrefix("FileSearch") }!.text.split(separator: " ").last!)!
        let loop = SlskLoop(); loop.start(); defer { loop.stop() }
        let pierced = SBox<UInt32?>(nil)
        let res = SlskSearchResponse(user: "bob", token: token, files: [SlskFileResult(path: "S\\A\\B\\1.flac", size: 1000, ext: "flac", bitrate: nil, duration: nil, sampleRate: 44100, bitDepth: 16, vbr: false)], freeSlot: true, speed: 5, queueLength: 0)
        let port = loop.listen(port: 0, loopbackOnly: true) { l in
            var buf = Data()
            l.onData = { d in
                buf.append(d)
                guard buf.count >= 9, pierced.value == nil else { return }
                var r = SlskReader(buf); _ = r.u32(); if r.u8() == SlskCode.pierceFirewall { pierced.value = r.u32(); l.send(SlskSearchResponse.encode(res)) }
            }
        }!
        var w = SlskWriter(); w.string("bob"); w.string("P"); w.u32(0x7f000001); w.u32(UInt32(port)); w.u32(4242); w.bool(false)
        rig.server.links.value.first?.send(SlskFrame(code: SlskCode.connectToPeer, payload: w.data))
        expect(wait { pierced.value == 4242 }, "the client connects out and sends PierceFirewall with the server's token")
        expect(wait { rig.client.snapshotNow().resultCount == 1 }, "the result arrives over the link the client opened")
        let d = rig.client.snapshotNow().diag
        expect(d.relayRequests == 1 && d.relayConnected == 1 && d.responsesRead == 1 && d.searchesSent == 1 && d.listening && d.listenPort != 0, "the counters show where the search got to: \(d)")
    }

    /// Many peers answer at once, each sending its first bytes the moment it connects: none may be lost.
    func manyPeersAnswerAtOnce() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        rig.client.search("crowd")
        expect(wait { rig.client.log.all().contains { $0.text.hasPrefix("FileSearch") } })
        let token = UInt32(rig.client.log.all().last { $0.text.hasPrefix("FileSearch") }!.text.split(separator: " ").last!)!
        let loop = SlskLoop(); loop.start(); defer { loop.stop() }
        let port = rig.client.listeningPort
        for i in 0..<40 {
            let res = SlskSearchResponse(user: "peer\(i)", token: token, files: [SlskFileResult(path: "S\\A\\B\\\(i).flac", size: 1000, ext: "flac", bitrate: nil, duration: nil, sampleRate: 44100, bitDepth: 16, vbr: false)], freeSlot: true, speed: 5, queueLength: 0)
            guard let l = loop.connect(host: "127.0.0.1", port: port, label: "p\(i)") else { continue }
            l.onConnect = { l.send(SlskMessages.peerInit(user: "peer\(i)", type: "P", token: 0) + SlskSearchResponse.encode(res).encoded()) }
        }
        expect(wait { rig.client.snapshotNow().resultCount == 40 }, "all 40 answers arrive: \(rig.client.snapshotNow().resultCount)")
        expect(rig.client.snapshotNow().diag.incomingLinks == 40, "40 incoming links counted")
    }

    func downloadResumeAbortAndSize() {
        // 1. a plain download, held half way: nothing is in the library folder until the file is whole
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        let file = bytes(600_000)
        let up = FakeUploader(name: "alice", data: file, mode: .hold(300_000), clientPort: { rig.client.listeningPort }); defer { up.stop() }
        rig.server.addresses.value["alice"] = ("127.0.0.1", up.port)
        let path = "Share\\Miles Davis\\Kind of Blue\\01 So What.flac"
        rig.client.download(user: "alice", path: path, size: UInt64(file.count))
        expect(wait { if case .queued(let p) = rig.client.snapshotNow().downloads.first?.state { return p == 14 } else { return false } } || rig.client.snapshotNow().downloads.first?.state == .transferring, "shows 'Queued, #14' from PlaceInQueue")
        expect(wait { rig.client.snapshotNow().downloads.first?.done ?? 0 >= 300_000 }, "bytes arrive")
        let inLibrary = (try? FileManager.default.subpathsOfDirectory(atPath: rig.downloads.path)) ?? ["?"]
        expect(inLibrary.isEmpty, "nothing is created in the watched downloads folder before the rename: \(inLibrary)")
        expect((try? FileManager.default.contentsOfDirectory(atPath: rig.incomplete.path))?.contains { $0.hasSuffix(".part") } == true, "the part file is in the incomplete folder")
        up.gate.signal()
        expect(wait { rig.client.snapshotNow().downloads.first?.state == .finished }, "finishes")
        let dest = rig.downloads.appendingPathComponent("Miles Davis/Kind of Blue/01 So What.flac")
        expect((try? Data(contentsOf: dest)) == file, "the file is complete and byte-identical at Artist/Album")
        expect(!((try? FileManager.default.contentsOfDirectory(atPath: rig.incomplete.path)) ?? []).contains { $0.hasSuffix(".part") }, "the part file is gone")
        expect(rig.store.historyCount() == 1, "the history keeps it")
        up.stop()

        // 2. resume from an existing part file
        let rig2 = Rig(); defer { rig2.close() }
        expect(rig2.online())
        let up2 = FakeUploader(name: "bob", data: file, clientPort: { rig2.client.listeningPort }); defer { up2.stop() }
        rig2.server.addresses.value["bob"] = ("127.0.0.1", up2.port)
        try? FileManager.default.createDirectory(at: rig2.incomplete, withIntermediateDirectories: true)
        try? file.prefix(250_000).write(to: rig2.incomplete.appendingPathComponent(SlskPaths.partName(user: "bob", remote: path)))
        rig2.client.download(user: "bob", path: path, size: UInt64(file.count))
        expect(wait { rig2.client.snapshotNow().downloads.first?.state == .finished }, "the resumed download finishes")
        expect(up2.offsets.value == [250_000], "asks the peer to start at the part file's size: \(up2.offsets.value)")
        expect((try? Data(contentsOf: rig2.downloads.appendingPathComponent("Miles Davis/Kind of Blue/01 So What.flac"))) == file, "resumed file is identical")

        // 3. aborted mid-file: retried and completed from where it stopped
        let rig3 = Rig(); defer { rig3.close() }
        expect(rig3.online())
        let up3 = FakeUploader(name: "carol", data: file, mode: .abortAfter(200_000), clientPort: { rig3.client.listeningPort }); defer { up3.stop() }
        rig3.server.addresses.value["carol"] = ("127.0.0.1", up3.port)
        rig3.client.download(user: "carol", path: path, size: UInt64(file.count))
        expect(wait(15) { rig3.client.snapshotNow().downloads.first?.state == .finished }, "an aborted transfer is retried and completes")
        expect(up3.offsets.value.count == 2 && up3.offsets.value[1] > 0, "the retry resumes after the bytes that arrived: \(up3.offsets.value)")
        expect((try? Data(contentsOf: rig3.downloads.appendingPathComponent("Miles Davis/Kind of Blue/01 So What.flac"))) == file, "retried file is identical")

        // 4. a peer that sends fewer bytes than it announced: never accepted as a file
        let rig4 = Rig(maxAttempts: 2); defer { rig4.close() }
        expect(rig4.online())
        let up4 = FakeUploader(name: "dave", data: file, mode: .short(100_000), clientPort: { rig4.client.listeningPort }); defer { up4.stop() }
        rig4.server.addresses.value["dave"] = ("127.0.0.1", up4.port)
        up4.mode.value = .short(100_000)
        rig4.client.download(user: "dave", path: path, size: UInt64(file.count))
        expect(wait(15) { if case .needsAttention = rig4.client.snapshotNow().downloads.first?.state { return true } else { return false } }, "a peer that stops short ends as 'needs attention' after the retries")
        expect(!FileManager.default.fileExists(atPath: rig4.downloads.appendingPathComponent("Miles Davis/Kind of Blue/01 So What.flac").path), "a short file is never put in place under its name")

        // 5. denied
        let rig5 = Rig(); defer { rig5.close() }
        expect(rig5.online())
        let up5 = FakeUploader(name: "erin", data: file, clientPort: { rig5.client.listeningPort }); defer { up5.stop() }
        up5.denies.value = "File not shared."
        rig5.server.addresses.value["erin"] = ("127.0.0.1", up5.port)
        rig5.client.download(user: "erin", path: path, size: UInt64(file.count))
        expect(wait { rig5.client.snapshotNow().downloads.first?.state == .needsAttention("File not shared.") }, "UploadDenied shows its reason as 'needs attention'")
    }

    /// A download must also finish when the peer's first bytes arrive in pieces, and when the server has to ask the client to open the file link.
    func downloadsFinishWhenTheLinkArrivesInOtherWays() {
        let file = bytes(400_000)
        let path = "Share\\Artist\\Album\\01 Song.flac"
        for (name, link) in [("split first bytes", FakeUploader.Link.splitStart), ("relayed through the server", .relayed)] {
            let rig = Rig(); defer { rig.close() }
            expect(rig.online())
            let up = FakeUploader(name: "alice", data: file, clientPort: { rig.client.listeningPort }); defer { up.stop() }
            up.link.value = link
            rig.server.addresses.value["alice"] = ("127.0.0.1", up.port)
            up.relay.value = { port, token in
                var w = SlskWriter(); w.string("alice"); w.string("F"); w.u32(0x7f000001); w.u32(UInt32(port)); w.u32(token); w.bool(false)
                rig.server.links.value.first?.send(SlskFrame(code: SlskCode.connectToPeer, payload: w.data))
            }
            rig.client.download(user: "alice", path: path, size: UInt64(file.count))
            expect(wait(12) { rig.client.snapshotNow().downloads.first?.state == .finished }, "\(name): the download finishes (state \(String(describing: rig.client.snapshotNow().downloads.first?.state)))")
            expect((try? Data(contentsOf: rig.downloads.appendingPathComponent("Artist/Album/01 Song.flac"))) == file, "\(name): the file is whole")
        }
    }

    func peerUnreachable() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        rig.client.config.maxAttempts = 1; rig.client.config.peerTimeout = 0.3
        rig.client.download(user: "ghost", path: "S\\A\\B\\1.flac", size: 10)
        expect(wait(10) { if case .needsAttention(let r) = rig.client.snapshotNow().downloads.first?.state { return r.contains("ghost") } else { return false } }, "an unreachable user ends as 'needs attention' with a reason")
    }

    /// Songs waiting in another person's queue do not use up the three slots, so a long queue never blocks the rest.
    func queuedDownloadsDoNotBlockOthers() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        let file = bytes(1000)
        let up = FakeUploader(name: "alice", data: file, mode: .hold(0), clientPort: { rig.client.listeningPort }); defer { up.stop() }
        up.queueOnly.value = true                               // it answers QueueUpload with a place in the queue and nothing more
        rig.server.addresses.value["alice"] = ("127.0.0.1", up.port)
        for i in 0..<8 { rig.client.download(user: "alice", path: "S\\A\\B\\\(i).flac", size: 1000) }
        expect(wait { rig.client.snapshotNow().downloads.filter { if case .queued = $0.state { return true } else { return false } }.count == 8 }, "all eight are queued with the other side, none stuck waiting: \(rig.client.snapshotNow().downloads.map(\.state))")
    }

    /// Cancel all: unfinished downloads go (and their partial files), finished ones stay.
    func cancelAllRemovesUnfinishedAndKeepsFinished() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        let file = bytes(300_000)
        let up = FakeUploader(name: "alice", data: file, clientPort: { rig.client.listeningPort }); defer { up.stop() }
        rig.server.addresses.value["alice"] = ("127.0.0.1", up.port)
        rig.client.download(user: "alice", path: "S\\A\\B\\done.flac", size: UInt64(file.count))
        expect(wait(10) { rig.client.snapshotNow().downloads.first?.state == .finished }, "one download finishes first")
        let slow = FakeUploader(name: "bob", data: file, mode: .hold(100_000), clientPort: { rig.client.listeningPort }); defer { slow.stop(); slow.gate.signal() }
        rig.server.addresses.value["bob"] = ("127.0.0.1", slow.port)
        rig.client.download(user: "bob", path: "S\\C\\D\\slow.flac", size: UInt64(file.count))
        rig.client.download(user: "bob", path: "S\\C\\D\\later.flac", size: UInt64(file.count))
        expect(wait { rig.client.snapshotNow().downloads.contains { $0.name == "slow.flac" && $0.done >= 100_000 } }, "a second download is moving")
        let partsBefore = ((try? FileManager.default.contentsOfDirectory(atPath: rig.incomplete.path)) ?? []).filter { $0.hasSuffix(".part") }.count
        expect(partsBefore >= 1, "it has a partial file: \(partsBefore)")
        rig.client.cancelAllDownloads()
        expect(wait { rig.client.snapshotNow().downloads.count == 1 }, "only the finished download is left: \(rig.client.snapshotNow().downloads.map(\.name))")
        expect(rig.client.snapshotNow().downloads.first?.state == .finished, "and it is still finished")
        expect(wait { ((try? FileManager.default.contentsOfDirectory(atPath: rig.incomplete.path)) ?? []).filter { $0.hasSuffix(".part") }.isEmpty }, "the partial files are gone from the incomplete folder")
        expect((try? Data(contentsOf: rig.downloads.appendingPathComponent("A/B/done.flac"))) == file, "the finished file is untouched")
        rig.client.cancelAllDownloads()                         // nothing left to cancel: harmless
        Thread.sleep(forTimeInterval: 0.2)
        expect(rig.client.snapshotNow().downloads.count == 1, "cancelling again changes nothing")
    }

    func uploadsMirrorTheShareList() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        let tmp = rig.dir.appendingPathComponent("Music/Jazz/Album"); try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = bytes(400_000); let local = tmp.appendingPathComponent("01.flac"); try? file.write(to: local)
        rig.client.setShares(SlskShares.build(files: [(local.path, UInt64(file.count))], folders: [rig.dir.appendingPathComponent("Music/Jazz").path]))
        let loop = SlskLoop(); loop.start(); defer { loop.stop() }
        let received = SBox(Data()), listenerPort = SBox<UInt16>(0), denied = SBox<String?>(nil), listFrames = SBox(0)
        let lp = loop.listen(port: 0, loopbackOnly: true) { f in
            f.onData = { d in
                // the client's file link: init, then its token, then we answer with the offset and read the bytes
                received.mutate { $0.append(d) }
                if received.value.count == 4 + Int(received.value.u32(at: 0)) + 4 { var o = SlskWriter(); o.u64(0); f.send(o.data) }
            }
        }!
        listenerPort.value = lp
        rig.server.addresses.value["bob"] = ("127.0.0.1", lp)
        // bob connects to the client as a peer and asks for the file
        let p = loop.connect(host: "127.0.0.1", port: rig.client.listeningPort, label: "bob")!
        var parser = SlskFrameParser()
        p.onData = { d in for f in parser.feed(d) {
            if f.code == SlskCode.uploadDenied { var r = SlskReader(f.payload); _ = r.string(); denied.value = r.string() }
            if f.code == SlskCode.transferRequest, let t = SlskTransferRequest.parse(f) { p.send(SlskMessages.transferResponse(token: t.token, allowed: true)) }
            if f.code == SlskCode.sharedFileListResponse { listFrames.mutate { $0 += 1 } }
        } }
        p.onConnect = { p.send(SlskMessages.peerInit(user: "bob", type: "P", token: 0)); p.send(SlskMessages.queueUpload("Jazz\\Album\\01.flac")) }
        expect(wait { denied.value == "File not shared." }, "with sharing off (the default) every request is refused")
        rig.client.setSharing(true)
        p.send(SlskMessages.queueUpload("../../etc/passwd")); expect(wait { denied.value == "File not shared." })
        denied.value = nil
        p.send(SlskMessages.queueUpload("Jazz\\Album\\01.flac"))
        expect(wait(10) { received.value.count >= 4 + 4 && rig.client.snapshotNow().uploads.first?.state == .finished || received.value.count > file.count }, "the shared file is sent to the peer")
        expect(wait { rig.client.snapshotNow().uploads.first?.state == .finished }, "the upload finishes")
        let body = received.value
        expect(body.count > file.count && body.suffix(file.count) == file, "the bytes sent are the file's")
        p.send(SlskFrame(code: SlskCode.sharedFileListRequest, payload: Data()))
        expect(wait { listFrames.value == 1 }, "the share list is answered")
        rig.client.store.ban("bob", true)
        p.send(SlskMessages.queueUpload("Jazz\\Album\\01.flac"))
        expect(wait { denied.value == "Banned" }, "a blocked user is refused")
    }

    func protocolLogIsReadable() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        let lines = rig.client.log.all().map(\.text).joined(separator: "\n")
        expect(lines.contains("Login as me") && lines.contains("SetListenPort") && !lines.contains("secret"), "the log reads like sentences and hides the password")
    }

    func storeKeepsQueueAndLists() {
        let s = SlskStore(url: nil)
        s.save(SlskStore.Saved(id: 1, kind: "download", user: "a", path: "p", size: 5, done: 2, state: "waiting", reason: "", dest: "/d"))
        expect(s.load().count == 1 && s.load()[0].done == 2, "the queue persists")
        s.ban("x", true); s.setNote("x", "slow"); s.friend("y", true); s.wish("coltrane", true)
        expect(s.isBanned("x") && s.note("x") == "slow" && s.friends() == ["y"] && s.wishes() == ["coltrane"], "bans, notes, friends and wishes")
        s.ban("x", false); expect(!s.isBanned("x"))
    }

    func playbackProtectionPausesTransfers() {
        let rig = Rig(); defer { rig.close() }
        expect(rig.online())
        let file = bytes(2_000_000)
        let up = FakeUploader(name: "alice", data: file, clientPort: { rig.client.listeningPort }); defer { up.stop() }
        rig.server.addresses.value["alice"] = ("127.0.0.1", up.port)
        rig.client.pauseTransfers(for: 1.5)
        rig.client.download(user: "alice", path: "S\\A\\B\\1.flac", size: UInt64(file.count))
        Thread.sleep(forTimeInterval: 0.6)
        expect(rig.client.snapshotNow().downloads.first?.state == .waiting && rig.client.snapshotNow().protectionPause, "no transfer starts while playback protection holds")
        expect(wait(12) { rig.client.snapshotNow().downloads.first?.state == .finished }, "transfers resume when it ends")
    }
}

extension SoulseekTests {
    func rowsGroupFilterAndStayFast() {
        func resp(_ u: String, folders: Int, per: Int, lossless: Bool, free: Bool) -> SlskSearchResponse {
            SlskSearchResponse(user: u, token: 1, files: (0..<folders).flatMap { f in (0..<per).map { i in
                SlskFileResult(path: "S\\Artist\\Album \(f)\\\(i).\(lossless ? "flac" : "mp3")", size: 30_000_000, ext: lossless ? "flac" : "mp3", bitrate: lossless ? nil : 192, duration: 200, sampleRate: lossless ? 96000 : nil, bitDepth: lossless ? 24 : nil, vbr: false) } },
                               freeSlot: free, speed: 100, queueLength: 2)
        }
        let rs = [resp("a", folders: 2, per: 3, lossless: true, free: true), resp("b", folders: 1, per: 5, lossless: false, free: false)]
        let all = SlskRows.build(rs, filters: SlskFilters())
        expect(all.count == 3 && all.first?.user == "a", "grouped by user and folder, free slots first: \(all.map(\.id))")
        expect(all.first?.format == "FLAC 24-bit 96 kHz", "chips read FLAC 24-bit 96 kHz: \(all.first?.format ?? "")")
        expect(SlskRows.build(rs, filters: SlskFilters(losslessOnly: true)).allSatisfy { $0.user == "a" }, "lossless only drops lossy folders")
        expect(SlskRows.build(rs, filters: SlskFilters(freeSlotsOnly: true)).allSatisfy { $0.freeSlot }, "free slots only")
        expect(SlskRows.build(rs, filters: SlskFilters(minBitrate: 256)).allSatisfy { $0.user == "a" }, "a minimum bitrate drops 192 kbps files")
        // 20 000 files, a few thousand folders: collapsed, capped, and quick
        let big = (0..<400).map { resp("u\($0)", folders: 10, per: 5, lossless: $0 % 2 == 0, free: $0 % 3 == 0) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let rows = SlskRows.build(big, filters: SlskFilters())
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        expect(rows.count <= 5000 && rows.count == 4000, "20 000 files collapse to \(rows.count) folder rows")
        expect(ms < 400, "building the rows for 20 000 files takes \(Int(ms)) ms, off the main thread")
    }

    func soulseekIsOffUntilTurnedOn() {
        expect(RailDestination.rail(soulseek: false) == RailDestination.rail, "with Soulseek off the rail is unchanged")
        expect(RailDestination.rail(soulseek: true).last == .soulseek && RailDestination.rail(soulseek: true).count == RailDestination.rail.count + 1, "turned on, Soulseek is the last destination")
        expect(RailDestination.of(.soulseek) == .soulseek, "its page belongs to it")
        let fresh = SlskConfig(downloadsDir: URL(fileURLWithPath: "/tmp/d"), incompleteDir: URL(fileURLWithPath: "/tmp/i"))
        expect(!fresh.sharing && fresh.maxDownloads == 3 && fresh.uploadSlots == 3, "sharing is off and three downloads run at once by default")
        expect(SlskPaths.destination(remote: "a\\b\\c.flac", in: fresh.downloadsDir).path.hasPrefix("/tmp/d/") && fresh.incompleteDir.path != fresh.downloadsDir.path, "the unfinished folder is not inside the downloads folder")
    }
}

extension SoulseekTests {
    /// Opening result groups on a large result set must not stall the main thread: the page draws a bounded number of rows and files.
    @MainActor func expandingResultsStaysResponsive() {
        guard !NSScreen.screens.isEmpty else { return }
        let m = PlayerModel(); navKeepAlive.append(m)
        let s = SoulseekModel.shared
        s.loadSynthetic(users: 400, folders: 3, files: 40)
        let stage = StageModel(); navKeepAlive.append(stage)
        m.tab = .soulseek
        let host = NSHostingView(rootView: AnyView(ContentView(stage: stage).environmentObject(m).frame(width: 1440, height: 900).preferredColorScheme(.dark)))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -9000, y: -9000)); win.orderFront(nil)
        defer { win.orderOut(nil); win.contentView = nil; s.expanded = [] }
        func settle(_ secs: Double) { let end = Date().addingTimeInterval(secs); while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() } }
        let t0 = CFAbsoluteTimeGetCurrent(); settle(0.5); let first = CFAbsoluteTimeGetCurrent() - t0
        var worst = 0.0, last = CFAbsoluteTimeGetCurrent()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.004, repeats: true) { _ in let now = CFAbsoluteTimeGetCurrent(); worst = max(worst, now - last - 0.004); last = now }
        defer { timer.invalidate() }
        let ids = s.rows.prefix(6).map(\.id)
        let t1 = CFAbsoluteTimeGetCurrent()
        for id in ids { s.expanded.insert(id); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        settle(0.6)
        let expand = CFAbsoluteTimeGetCurrent() - t1
        FileHandle.standardError.write(Data(String(format: "soulseek page: first draw %.0f ms, opening %d groups %.0f ms, worst main-thread stall %.0f ms (%d rows)\n", first * 1000, ids.count, expand * 1000, worst * 1000, s.rows.count).utf8))
        expect(worst < 0.25, "opening groups on a large result set never stalls the main thread for long: \(Int(worst * 1000)) ms")
        expect(expand < 2.5, "opening six groups takes well under a few seconds: \(Int(expand * 1000)) ms")
    }
}

func soulseekTests() -> [(String, TestFn)] {
    let t = SoulseekTests()
    return [("slsk.wire", t.wireFormat), ("slsk.login", t.loginAndReconnect), ("slsk.noRealNetwork", t.realNetworkIsBlocked), ("slsk.search", t.searchResults),
            ("slsk.relay", t.searchResultsViaRelayedConnect), ("slsk.crowd", t.manyPeersAnswerAtOnce), ("slsk.download", t.downloadResumeAbortAndSize), ("slsk.downloadLinks", t.downloadsFinishWhenTheLinkArrivesInOtherWays), ("slsk.unreachable", t.peerUnreachable), ("slsk.slots", t.queuedDownloadsDoNotBlockOthers), ("slsk.cancelAll", t.cancelAllRemovesUnfinishedAndKeepsFinished),
            ("slsk.upload", t.uploadsMirrorTheShareList), ("slsk.log", t.protocolLogIsReadable), ("slsk.store", t.storeKeepsQueueAndLists), ("slsk.protection", t.playbackProtectionPausesTransfers), ("slsk.rows", t.rowsGroupFilterAndStayFast), ("slsk.off", t.soulseekIsOffUntilTurnedOn), ("slsk.expand", { MainActor.assumeIsolated { t.expandingResultsStaysResponsive() } })]
}

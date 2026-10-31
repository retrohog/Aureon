import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The Soulseek client: one long-lived server link, peer links opened on demand, searches, downloads that resume, and uploads of what the user chose to
// share. All state lives on one serial queue; the network loop only hands bytes over. Nothing here runs on, or calls into, the audio engine.

public struct SlskConfig {
    public var host = "server.slsknet.org"
    public var port: UInt16 = 2242
    public var username = ""
    public var password = ""
    public var listenPort: UInt16 = 0
    public var downloadsDir: URL
    public var incompleteDir: URL
    public var maxDownloads = 3
    public var uploadSlots = 3
    public var sharing = false
    /// Bytes per second for uploads; 0 is no limit.
    public var uploadLimit = 0
    public var retryBase: TimeInterval = 5
    public var reconnectBase: TimeInterval = 2
    public var maxAttempts = 5
    public var peerTimeout: TimeInterval = 10
    /// Called with the finished `.part` file before it is moved into place; false refuses it ("not a readable audio file").
    public var verifyFile: (@Sendable (URL) -> Bool)?
    public init(downloadsDir: URL, incompleteDir: URL) { self.downloadsDir = downloadsDir; self.incompleteDir = incompleteDir }
}

public enum SlskPaths {
    /// `<Artist>/<Album>/file` from the remote path (`Share\Artist\Album\01 Track.flac`); shorter paths use what is there.
    public static func destination(remote: String, in root: URL) -> URL {
        let parts = remote.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map { clean(String($0)) }.filter { !$0.isEmpty }
        let name = parts.last ?? "file"
        let dirs = Array(parts.dropLast())
        let keep = dirs.count >= 2 ? Array(dirs.suffix(2)) : (dirs.isEmpty ? ["Unknown"] : dirs)
        return keep.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }.appendingPathComponent(name)
    }
    public static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: ":", with: "-")
        t = String(t.unicodeScalars.filter { $0.value >= 32 && $0 != "/" && $0 != "\\" })
        t = t.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        return t == ".." ? "" : t
    }
    public static func partName(user: String, remote: String) -> String {
        let h = String(SlskMessages.md5Hex(user + "\u{0}" + remote).prefix(12))
        let n = remote.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map { clean(String($0)) } ?? "file"
        return "\(h)-\(n).part"
    }
}

/// Writes received bytes to the `.part` file on its own queue, in large chunks.
final class SlskFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "slsk.disk", qos: .utility)
    private var fd: Int32
    private var buffer = Data()
    private let lock = NSLock()
    private var pending = 0
    private(set) var failed = false
    static let chunk = 256 * 1024

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd < 0 { return nil }
        _ = fcntl(fd, F_NOCACHE, 1)
    }
    var pendingBytes: Int { lock.lock(); defer { lock.unlock() }; return pending }
    func append(_ d: Data, drained: @escaping @Sendable () -> Void) {
        lock.lock(); pending += d.count; lock.unlock()
        queue.async { [self] in
            buffer.append(d)
            if buffer.count >= Self.chunk { flushBuffer() }
            lock.lock(); pending -= d.count; lock.unlock()
            drained()
        }
    }
    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        let ok = buffer.withUnsafeBytes { p -> Bool in
            var off = 0
            while off < p.count { let n = write(fd, p.baseAddress! + off, p.count - off); if n <= 0 { return false }; off += n }
            return true
        }
        if !ok { failed = true }
        buffer.removeAll(keepingCapacity: true)
    }
    func finish(_ done: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in flushBuffer(); fsync(fd); close(fd); done(!failed) }
    }
}

public final class SlskClient: @unchecked Sendable {
    public var config: SlskConfig
    public let log: SlskLog
    public let store: SlskStore
    public var onSnapshot: ((SlskSnapshot) -> Void)?
    /// A download finished and sits at this URL.
    public var onDownloaded: ((SlskTransferInfo, URL) -> Void)?

    private let q = DispatchQueue(label: "slsk.client", qos: .utility)
    private let decodeQueue = DispatchQueue(label: "slsk.decode", qos: .utility)
    private let loop: SlskLoop
    private var timer: DispatchSourceTimer?

    // state, only touched on q
    private var state = SlskLinkState.offline
    private var server: SlskLink?
    private var serverParser = SlskFrameParser()
    private var wantOnline = false
    private var backoff: TimeInterval = 2
    private var listenPort: UInt16 = 0
    private var nextToken: UInt32 = UInt32.random(in: 1000..<1_000_000)
    private var dirty = false
    private var lastPing = Date()

    // peers
    private final class Peer {
        let link: SlskLink
        var user: String?
        var type: String?
        var buf = Data()
        var parser = SlskFrameParser()
        var ready = false
        var host = "", port: UInt16 = 0
        var fileToken: UInt32?          // F link: the transfer it carries
        var dl: Download?
        var received: UInt64 = 0
        var expected: UInt64 = 0
        var writer: SlskFileWriter?
        init(_ l: SlskLink) { link = l }
    }
    private var peers: [Int: Peer] = [:]
    private var peerByUser: [String: Peer] = [:]
    private var pendingConnect: [UInt32: String] = [:]          // reverse-connection tokens → user
    private var waiters: [String: [(Peer?, String?) -> Void]] = [:]
    private var addressQueries: Set<String> = []
    private var addressWaiters: [String: [((String, UInt16)?) -> Void]] = [:]

    // searches
    private var searchToken: UInt32 = 0
    private var searchUntil = Date.distantPast
    private var responses: [SlskSearchResponse] = []
    private var rowCount = 0
    static let rowCap = 5000

    // transfers
    final class Download {
        var info: SlskTransferInfo
        var token: UInt32?
        var dest: URL
        var part: URL
        var link: SlskLink?
        var retryAt: Date?
        var windowBytes: UInt64 = 0
        init(info: SlskTransferInfo, dest: URL, part: URL) { self.info = info; self.dest = dest; self.part = part }
    }
    final class Upload {
        var info: SlskTransferInfo
        let local: String
        var token: UInt32 = 0
        var windowBytes: UInt64 = 0
        init(info: SlskTransferInfo, local: String) { self.info = info; self.local = local }
    }
    private var downloads: [Download] = []
    private var uploads: [Upload] = []
    private var nextTransferID = 1
    private var uploadCursor = 0
    private var shares: [SlskShareFile] = []
    private var shareList: SlskFrame?
    private var rooms: [String: SlskRoomState] = [:]
    private var messages: [String: [String]] = [:]
    private var pausedUntil = Date.distantPast
    private var playbackGuard = false
    private var downSpeed = 0.0, upSpeed = 0.0
    private var browsed: [String: [SlskFileResult]] = [:]
    private var diag = SlskDiagnostics()

    public init(config: SlskConfig, store: SlskStore, log: SlskLog = SlskLog(), loop: SlskLoop = SlskLoop()) {
        self.config = config; self.store = store; self.log = log; self.loop = loop
        loop.start()
    }

    // MARK: guard against the real network in tests

    static func isLoopback(_ h: String) -> Bool { h == "127.0.0.1" || h == "localhost" || h == "::1" }
    static var testing: Bool {
        let e = ProcessInfo.processInfo.environment
        return ProcessInfo.processInfo.arguments.contains("selftest") || e["AUREON_TESTING"] != nil || e["AUREON_SNAPSHOT"] != nil
    }

    // MARK: public control

    public func connect() { q.async { self.wantOnline = true; self.backoff = self.config.reconnectBase; self.openServer() } }
    public func disconnect() { q.async { self.wantOnline = false; self.server?.close(); self.server = nil; self.setState(.offline) } }
    public func snapshotNow() -> SlskSnapshot { q.sync { self.makeSnapshot() } }

    public func search(_ query: String) {
        q.async {
            let t = self.token()
            self.searchToken = t; self.searchUntil = Date().addingTimeInterval(45); self.responses = []; self.rowCount = 0
            self.sendServer(SlskMessages.fileSearch(token: t, query: query), "FileSearch \"\(query)\" token \(t)")
            self.diag.searchesSent += 1
            self.dirty = true
        }
    }

    public func download(user: String, path: String, size: UInt64) {
        q.async {
            if self.downloads.contains(where: { $0.info.user == user && $0.info.path == path && $0.info.state != .finished }) { return }
            let dest = SlskPaths.destination(remote: path, in: self.config.downloadsDir)
            let part = self.config.incompleteDir.appendingPathComponent(SlskPaths.partName(user: user, remote: path))
            let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? UInt64) ?? 0
            let info = SlskTransferInfo(id: self.nextTransferID, kind: .download, user: user, path: path, size: size, done: min(have, size), state: .waiting, speed: 0, attempts: 0)
            self.nextTransferID += 1
            self.downloads.append(Download(info: info, dest: dest, part: part))
            self.persist(info, dest: dest)
            self.pump()
        }
    }

    public func cancel(id: Int) {
        q.async {
            if let d = self.downloads.first(where: { $0.info.id == id }) {
                d.link?.close(); d.info.state = .needsAttention("Cancelled"); self.persist(d.info, dest: d.dest); self.pump()
            }
            if let u = self.uploads.first(where: { $0.info.id == id }) { u.info.state = .needsAttention("Cancelled") }
            self.dirty = true
        }
    }
    public func retry(id: Int) { q.async { if let d = self.downloads.first(where: { $0.info.id == id }) { d.info.attempts = 0; d.info.state = .waiting; d.retryAt = nil; self.pump() } } }
    public func clearFinished() { q.async { self.downloads.removeAll { $0.info.state == .finished }; self.uploads.removeAll { $0.info.state == .finished }; self.dirty = true } }

    public func setShares(_ files: [SlskShareFile]) {
        q.async {
            self.shares = files; self.shareList = nil
            let c = SlskShares.counts(files)
            if self.config.sharing { self.sendServer(SlskMessages.sharedFoldersFiles(folders: c.folders, files: c.files), "SharedFoldersFiles \(c.folders) folders, \(c.files) files") }
        }
    }
    public func setSharing(_ on: Bool) { q.async { self.config.sharing = on; if !on { self.uploads.removeAll { !$0.info.state.isActive || $0.info.state == .waiting } }; self.dirty = true } }

    /// Playback protection: pause transfers for a while (a stall, a network cast, a live DJ deck).
    public func pauseTransfers(for seconds: TimeInterval) { q.async { self.pausedUntil = Date().addingTimeInterval(seconds); self.applyPause() } }
    /// Hi-res playback from the network: uploads drop to one slot while true.
    public func setPlaybackGuard(_ on: Bool) { q.async { self.playbackGuard = on } }
    public func pauseAll(_ on: Bool) { q.async { self.pausedUntil = on ? .distantFuture : .distantPast; self.applyPause() } }

    public func sendPrivateMessage(to user: String, _ text: String) { q.async { self.sendServer(SlskMessages.privateMessage(user: user, text: text), "PrivateMessage to \(user)"); self.messages[user, default: []].append("me: \(text)"); self.dirty = true } }
    public func joinRoom(_ r: String) { q.async { self.sendServer(SlskMessages.joinRoom(r), "JoinRoom \(r)") } }
    public func leaveRoom(_ r: String) { q.async { self.sendServer(SlskMessages.leaveRoom(r), "LeaveRoom \(r)"); self.rooms[r] = nil; self.dirty = true } }
    public func say(_ r: String, _ text: String) { q.async { self.sendServer(SlskMessages.sayInRoom(r, text), "SayInRoom \(r)") } }
    /// Asks a user for the list of what they share; the answer appears in the snapshot's `browsed`.
    public func browse(user: String) {
        q.async {
            self.browsed[user] = nil
            self.ensurePeer(user) { p, why in
                guard let p else { self.log.add("·", why ?? "Can't connect"); return }
                p.link.send(SlskFrame(code: SlskCode.sharedFileListRequest, payload: Data())); self.log.add("→", "SharedFileListRequest to \(user)")
            }
        }
    }
    public func runWishlist() { q.async { for w in self.store.wishes() { self.sendServer(SlskMessages.wishlistSearch(token: self.token(), query: w), "WishlistSearch \"\(w)\"") } } }

    // MARK: server link

    private func token() -> UInt32 { nextToken &+= 1; return nextToken }
    private func setState(_ s: SlskLinkState) { state = s; dirty = true; log.add("·", "State: \(s)") }

    private func openServer() {
        guard wantOnline, server == nil else { return }
        if Self.testing && !Self.isLoopback(config.host) {
            setState(.failed("Blocked: tests never connect to the real network")); wantOnline = false; return
        }
        setState(.connecting)
        let host = config.host, port = config.port
        // name resolution may block, so it happens off the queue
        DispatchQueue.global(qos: .utility).async {
            let l = self.loop.connect(host: host, port: port, label: "server")
            self.q.async {
                guard let l else { self.serverClosed("could not reach \(host)"); return }
                self.server = l; l.keepOpen = true; self.serverParser = SlskFrameParser()
                l.onConnect = { [weak self] in self?.q.async { self?.serverConnected() } }
                l.onData = { [weak self] d in self?.q.async { self?.serverData(d) } }
                l.onClose = { [weak self] why in self?.q.async { self?.serverClosed(why ?? "closed") } }
            }
        }
    }

    private func serverConnected() {
        setState(.loggingIn)
        if listenPort == 0 {
            // handlers are set on the network thread, before the first bytes can be read, so nothing a peer sends first is lost
            listenPort = loop.listen(port: config.listenPort, loopbackOnly: Self.isLoopback(config.host)) { [weak self] l in
                guard let self else { return }
                _ = self.makePeer(l, user: nil, type: nil)
                self.q.async { self.diag.incomingLinks += 1; self.log.add("←", "Incoming link"); self.dirty = true }
            } ?? 0
            diag.listening = listenPort != 0; diag.listenPort = listenPort
            if listenPort == 0 { log.add("·", "Could not open a listening port: others can only reach us through the server") }
        }
        log.add("→", "Login as \(config.username) (password hidden)")
        server?.send(SlskMessages.login(user: config.username, password: config.password))
    }

    private func serverClosed(_ why: String) {
        server = nil
        for p in peers.values { _ = p }
        guard wantOnline else { return }
        setState(.failed(why))
        let delay = backoff; backoff = min(60, backoff * 2)
        log.add("·", "Reconnecting in \(Int(delay)) s")
        q.asyncAfter(deadline: .now() + delay) { self.openServer() }
    }

    private func sendServer(_ f: SlskFrame, _ note: String) {
        guard let s = server, state.isOnline else { return }
        log.add("→", note); s.send(f)
    }

    private func serverData(_ d: Data) {
        for f in serverParser.feed(d) { serverFrame(f) }
        if serverParser.failed { server?.close() }
    }

    private func serverFrame(_ f: SlskFrame) {
        switch f.code {
        case SlskCode.login:
            guard let r = SlskLoginResult.parse(f) else { return }
            if r.success {
                backoff = config.reconnectBase; setState(.online(r.greeting)); log.add("←", "Login accepted")
                server?.send(SlskMessages.setListenPort(listenPort)); server?.send(SlskMessages.setStatus(2))
                let c = config.sharing ? SlskShares.counts(shares) : (0, 0)
                server?.send(SlskMessages.sharedFoldersFiles(folders: c.0, files: c.1)); server?.send(SlskMessages.haveNoParent(true))
                log.add("→", "SetListenPort \(listenPort), SetStatus online, SharedFoldersFiles, HaveNoParent")
                pump()
            } else { wantOnline = false; setState(.failed(r.reason)); log.add("←", "Login refused: \(r.reason)"); server?.close() }
        case SlskCode.getPeerAddress:
            guard let a = SlskPeerAddress.parse(f) else { return }
            log.add("←", "PeerAddress \(a.user) \(a.host):\(a.port)")
            addressQueries.remove(a.user)
            if let ws = addressWaiters[a.user] { addressWaiters[a.user] = nil; for w in ws { w(a.host != "0.0.0.0" && a.port != 0 ? (a.host, a.port) : nil) } }
            guard waiters[a.user] != nil else { return }
            if a.host != "0.0.0.0", a.port != 0 { openPeer(user: a.user, host: a.host, port: a.port) }
        case SlskCode.connectToPeer:
            guard let c = SlskConnectToPeer.parse(f) else { return }
            log.add("←", "ConnectToPeer \(c.user) \(c.type) \(c.host):\(c.port)")
            diag.relayRequests += 1; dirty = true
            if store.isBanned(c.user) { return }
            // they cannot reach us: we open the link and pierce their firewall
            DispatchQueue.global(qos: .utility).async {
                guard let l = self.loop.connect(host: c.host, port: c.port, label: "\(c.type) \(c.user)") else { return }
                let p = self.makePeer(l, user: c.user, type: c.type, host: c.host, port: c.port, ready: true)
                l.onConnect = { [weak self] in
                    l.send(SlskMessages.pierceFirewall(token: c.token))
                    self?.q.async { self?.diag.relayConnected += 1; self?.dirty = true; if c.type == "P" { self?.peerReady(p) } }
                }
            }
        case SlskCode.privateMessage:
            var r = SlskReader(f.payload)
            if let id = r.u32(), r.u32() != nil, let u = r.string(), let m = r.string() { messages[u, default: []].append("\(u): \(m)"); server?.send(SlskMessages.ackPrivateMessage(id: id)); log.add("←", "PrivateMessage from \(u)"); dirty = true }
        case SlskCode.sayInRoom:
            var r = SlskReader(f.payload)
            if let room = r.string(), let u = r.string(), let m = r.string() { rooms[room, default: SlskRoomState(name: room, lines: [], users: 0)].lines.append("\(u): \(m)"); if rooms[room]!.lines.count > 200 { rooms[room]!.lines.removeFirst() }; dirty = true }
        case SlskCode.joinRoom:
            var r = SlskReader(f.payload)
            if let room = r.string() { let n = r.u32() ?? 0; rooms[room, default: SlskRoomState(name: room, lines: [], users: 0)].users = Int(n); log.add("←", "JoinRoom \(room) (\(n) users)"); dirty = true }
        case SlskCode.ping: break
        default: log.add("←", "server code \(f.code) (\(f.payload.count) bytes)")
        }
    }

    // MARK: peers

    /// Registers a peer link and hooks its callbacks right away (callable from any thread): later bytes are handed to the client queue in order, and the
    /// registration is queued ahead of them.
    private func makePeer(_ l: SlskLink, user: String?, type: String?, host: String = "", port: UInt16 = 0, ready: Bool = false) -> Peer {
        let p = Peer(l); p.user = user; p.type = type; p.host = host; p.port = port; p.ready = ready
        let id = l.id
        q.async { self.peers[id] = p }
        l.onData = { [weak self] d in self?.q.async { if let p = self?.peers[id] { self?.peerData(p, d) } } }
        l.onClose = { [weak self] why in self?.q.async { if let p = self?.peers[id] { self?.peerClosed(p, why) } } }
        return p
    }

    private func peerClosed(_ p: Peer, _ why: String?) {
        peers[p.link.id] = nil
        if let u = p.user, peerByUser[u] === p { peerByUser[u] = nil }
        if let d = p.dl { transferLinkLost(d, p) }
        if let w = p.writer { w.finish { _ in } }
        for u in uploads where u.info.state == .transferring && p.fileToken == u.token { _ = u }
    }

    private func peerReady(_ p: Peer) {
        p.ready = true
        guard let u = p.user else { return }
        peerByUser[u] = p
        let ws = waiters[u] ?? []; waiters[u] = nil
        for w in ws { w(p, nil) }
    }

    /// Gives `done` a ready "P" link to `user`: an existing one, or a new one raced from both sides.
    private func ensurePeer(_ user: String, _ done: @escaping (Peer?, String?) -> Void) {
        if let p = peerByUser[user], p.ready, p.link.isOpen { done(p, nil); return }
        let first = waiters[user] == nil
        waiters[user, default: []].append(done)
        guard first else { return }
        if !addressQueries.contains(user) { addressQueries.insert(user); sendServer(SlskMessages.getPeerAddress(user), "GetPeerAddress \(user)") }
        let t = token(); pendingConnect[t] = user
        sendServer(SlskMessages.connectToPeer(token: t, user: user, type: "P"), "ConnectToPeer \(user) P token \(t)")
        q.asyncAfter(deadline: .now() + config.peerTimeout) {
            self.pendingConnect[t] = nil
            if let ws = self.waiters[user] { self.waiters[user] = nil; for w in ws { w(nil, "Can't connect to \(user)") } }
        }
    }

    private func openPeer(user: String, host: String, port: UInt16) {
        DispatchQueue.global(qos: .utility).async {
            guard let l = self.loop.connect(host: host, port: port, label: "P \(user)", timeout: self.config.peerTimeout) else { return }
            let p = self.makePeer(l, user: user, type: "P", host: host, port: port)
            l.onConnect = { [weak self] in
                l.send(SlskMessages.peerInit(user: self?.config.username ?? "", type: "P", token: 0))
                self?.q.async { self?.log.add("→", "PeerInit P to \(user)"); self?.peerReady(p) }
            }
        }
    }

    private func peerData(_ p: Peer, _ d: Data) {
        if p.type == "F" { fileData(p, d); return }
        if p.type == nil {
            // the opening message: length, one-byte code, fields
            p.buf.append(d)
            guard p.buf.count >= 5 else { return }
            let len = Int(p.buf.u32(at: 0))
            guard len >= 1, len < 4096 else { p.link.close(); return }
            guard p.buf.count >= 4 + len else { return }
            var r = SlskReader(Data(p.buf[(p.buf.startIndex + 4)..<(p.buf.startIndex + 4 + len)]))
            let rest = Data(p.buf.dropFirst(4 + len)); p.buf = Data()
            switch r.u8() {
            case SlskCode.pierceFirewall:
                guard let t = r.u32() else { p.link.close(); return }
                if let u = pendingConnect[t] { pendingConnect[t] = nil; p.user = u; p.type = "P"; log.add("←", "PierceFirewall from \(u)"); peerReady(p) }
                else { p.type = "F"; p.user = nil; log.add("←", "PierceFirewall for a file link") }
            case SlskCode.peerInit:
                guard let u = r.string(), let t = r.string(), r.u32() != nil else { p.link.close(); return }
                p.user = u; p.type = t; log.add("←", "PeerInit \(t) from \(u)")
                if t == "P" { peerReady(p) }
            default: p.link.close(); return
            }
            if !rest.isEmpty { peerData(p, rest) }
            return
        }
        for f in p.parser.feed(d) { peerFrame(p, f) }
        if p.parser.failed { p.link.close() }
    }

    private func peerFrame(_ p: Peer, _ f: SlskFrame) {
        let user = p.user ?? "?"
        switch f.code {
        case SlskCode.fileSearchResponse:
            let token = searchToken
            decodeQueue.async {
                guard let r = SlskSearchResponse.parse(f) else {
                    self.q.async { self.diag.responsesUnreadable += 1; self.log.add("·", "A search result from \(user) could not be read (\(f.payload.count) bytes)"); self.dirty = true }
                    return
                }
                self.q.async { self.diag.responsesRead += 1; self.take(r, current: token) }
            }
        case SlskCode.placeInQueue:
            var r = SlskReader(f.payload)
            if let path = r.string(), let place = r.u32(), let d = downloads.first(where: { $0.info.user == user && $0.info.path == path }) {
                d.info.state = .queued(place: Int(place)); log.add("←", "PlaceInQueue \(place) for \(path)"); dirty = true
            }
        case SlskCode.uploadDenied:
            var r = SlskReader(f.payload)
            if let path = r.string(), let why = r.string(), let d = downloads.first(where: { $0.info.user == user && $0.info.path == path }) {
                log.add("←", "UploadDenied \(why)"); fail(d, why, final: why == "File not shared." || why == "Banned" || why == "Cancelled" && false)
            }
        case SlskCode.uploadFailed:
            var r = SlskReader(f.payload)
            if let path = r.string(), let d = downloads.first(where: { $0.info.user == user && $0.info.path == path }) { log.add("←", "UploadFailed"); fail(d, "The other side failed the upload", final: false) }
        case SlskCode.transferRequest:
            guard let t = SlskTransferRequest.parse(f) else { return }
            log.add("←", "TransferRequest dir \(t.direction) \(t.path)")
            if t.direction == 1, let d = downloads.first(where: { $0.info.user == user && $0.info.path == t.path && $0.info.state != .finished }) {
                d.token = t.token
                if let s = t.size { d.info.size = s }
                if Date() < pausedUntil { p.link.send(SlskMessages.transferResponse(token: t.token, allowed: false, reason: "Queued")); return }
                d.info.state = .connecting
                p.link.send(SlskMessages.transferResponse(token: t.token, allowed: true)); log.add("→", "TransferResponse allowed"); dirty = true
            } else {
                p.link.send(SlskMessages.transferResponse(token: t.token, allowed: false, reason: "Cancelled"))
            }
        case SlskCode.transferResponse:
            guard let r = SlskTransferResponse.parse(f) else { return }
            if let u = uploads.first(where: { $0.token == r.token }) {
                if r.allowed { startUpload(u, via: p) } else { u.info.state = .needsAttention(r.reason ?? "Refused"); dirty = true; scheduleUploads() }
            }
        case SlskCode.queueUpload:
            var r = SlskReader(f.payload)
            guard let path = r.string() else { return }
            log.add("←", "QueueUpload \(path) from \(user)")
            queueUpload(from: user, path: path, via: p)
        case SlskCode.placeInQueueRequest:
            var r = SlskReader(f.payload)
            if let path = r.string(), let i = uploads.filter({ $0.info.state == .waiting }).firstIndex(where: { $0.info.user == user && $0.info.path == path }) { p.link.send(SlskMessages.placeInQueue(path: path, place: UInt32(i + 1))) }
        case SlskCode.sharedFileListResponse:
            decodeQueue.async {
                guard let list = SlskShares.parseList(f) else { return }
                self.q.async { self.browsed[user] = Array(list.prefix(Self.rowCap * 4)); self.log.add("←", "Share list of \(user): \(list.count) files"); self.dirty = true }
            }
        case SlskCode.sharedFileListRequest:
            log.add("←", "SharedFileListRequest from \(user)")
            if config.sharing {
                if shareList == nil { shareList = SlskShares.listResponse(shares) }
                p.link.send(shareList!)
            } else { p.link.send(SlskShares.listResponse([])) }
        default: log.add("←", "peer code \(f.code) from \(user)")
        }
    }

    // MARK: search results

    private func take(_ r: SlskSearchResponse, current: UInt32) {
        guard r.token == searchToken, Date() < searchUntil, !store.isBanned(r.user), rowCount < Self.rowCap else { return }
        var r = r
        if rowCount + r.files.count > Self.rowCap { r.files = Array(r.files.prefix(Self.rowCap - rowCount)) }
        rowCount += r.files.count; responses.append(r); dirty = true
    }

    // MARK: downloads

    private func persist(_ i: SlskTransferInfo, dest: URL) {
        let st: String
        switch i.state { case .finished: st = "finished"; case .needsAttention: st = "attention"; default: st = "waiting" }
        var reason = ""; if case .needsAttention(let r) = i.state { reason = r }
        store.save(SlskStore.Saved(id: i.id, kind: i.kind.rawValue, user: i.user, path: i.path, size: i.size, done: i.done, state: st, reason: reason, dest: dest.path))
    }

    /// Restores the queue saved by an earlier run; unfinished downloads wait to start again from their `.part` files.
    public func restoreQueue() {
        q.async {
            for s in self.store.load() where s.kind == "download" && s.state != "finished" {
                let part = self.config.incompleteDir.appendingPathComponent(SlskPaths.partName(user: s.user, remote: s.path))
                let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? UInt64) ?? 0
                let st: SlskTransferState = s.state == "attention" ? .needsAttention(s.reason) : .waiting
                let info = SlskTransferInfo(id: s.id, kind: .download, user: s.user, path: s.path, size: s.size, done: min(have, s.size), state: st, speed: 0, attempts: 0)
                self.nextTransferID = max(self.nextTransferID, s.id + 1)
                self.downloads.append(Download(info: info, dest: URL(fileURLWithPath: s.dest), part: part))
            }
            self.dirty = true; self.pump()
        }
    }

    /// Starts waiting downloads up to the limit.
    private func pump() {
        guard state.isOnline, Date() >= pausedUntil else { dirty = true; return }
        let running = downloads.filter { $0.info.state.isActive && $0.info.state != .waiting }.count
        var free = config.maxDownloads - running
        for d in downloads where free > 0 {
            if case .retrying = d.info.state, let at = d.retryAt, Date() < at { continue }
            guard d.info.state == .waiting || { if case .retrying = d.info.state { return true }; return false }() else { continue }
            free -= 1; begin(d)
        }
        dirty = true
    }

    private func begin(_ d: Download) {
        d.info.state = .connecting; d.info.attempts += 1; dirty = true
        let user = d.info.user
        ensurePeer(user) { [self] p, why in
            guard let p else { fail(d, why ?? "Can't connect", final: false); return }
            guard d.info.state == .connecting else { return }
            p.link.send(SlskMessages.queueUpload(d.info.path)); log.add("→", "QueueUpload \(d.info.path)")
            d.info.state = .queued(place: nil); dirty = true
            q.asyncAfter(deadline: .now() + 3) { if case .queued = d.info.state, p.link.isOpen { p.link.send(SlskMessages.placeInQueueRequest(d.info.path)) } }
        }
    }

    private func fail(_ d: Download, _ why: String, final: Bool) {
        d.link?.close(); d.link = nil; d.token = nil
        if final || d.info.attempts >= config.maxAttempts { d.info.state = .needsAttention(why) }
        else {
            d.info.state = .retrying(why)
            let delay = config.retryBase * pow(2, Double(d.info.attempts - 1)); d.retryAt = Date().addingTimeInterval(delay)
            q.asyncAfter(deadline: .now() + delay) { if case .retrying = d.info.state { self.pump() } }
        }
        persist(d.info, dest: d.dest); dirty = true; pump()
    }

    private func transferLinkLost(_ d: Download, _ p: Peer) {
        guard d.info.state == .transferring || d.info.state == .connecting else { return }
        if p.received + (d.info.done - p.received) >= d.info.size, d.info.size > 0 { return }
        fail(d, "Connection lost", final: false)
    }

    private func fileData(_ p: Peer, _ d: Data) {
        // first four bytes: the transfer token; then we answer with the offset and the data follows
        var data = d
        if p.dl == nil {
            p.buf.append(data); data = Data()
            guard p.buf.count >= 4 else { return }
            let t = p.buf.u32(at: 0)
            guard let dl = downloads.first(where: { $0.token == t && $0.info.state == .connecting }) else { log.add("·", "File link for an unknown transfer"); p.link.close(); return }
            data = Data(p.buf.dropFirst(4)); p.buf = Data()
            let have = (try? FileManager.default.attributesOfItem(atPath: dl.part.path)[.size] as? UInt64) ?? 0
            let offset = min(have, dl.info.size)
            guard let w = SlskFileWriter(url: dl.part) else { fail(dl, "Can't write to the incomplete folder", final: true); p.link.close(); return }
            p.dl = dl; p.writer = w; p.fileToken = t; p.received = 0; p.expected = dl.info.size - offset
            dl.link = p.link; dl.info.done = offset; dl.info.state = .transferring
            var o = SlskWriter(); o.u64(offset); p.link.send(o.data); log.add("→", "File offset \(offset)")
            applyPause(); dirty = true
        }
        guard let dl = p.dl, !data.isEmpty || p.expected == 0 else { return }
        let take = min(UInt64(data.count), p.expected - p.received)
        if take > 0 {
            let part = take == UInt64(data.count) ? data : data.prefix(Int(take))
            p.received += take; dl.info.done += take; dl.windowBytes += take
            let link = p.link
            p.writer?.append(Data(part)) { [weak self] in self?.q.async { if let w = p.writer, w.pendingBytes < 1_000_000, Date() >= (self?.pausedUntil ?? .distantPast) { link.readPaused = false } } }
            if p.writer!.pendingBytes > 4_000_000 { link.readPaused = true }
        }
        if p.received >= p.expected { completeDownload(dl, p) }
    }

    private func completeDownload(_ dl: Download, _ p: Peer) {
        guard let w = p.writer else { return }
        p.writer = nil; p.dl = nil
        w.finish { ok in self.q.async {
            p.link.close()
            let size = (try? FileManager.default.attributesOfItem(atPath: dl.part.path)[.size] as? UInt64) ?? 0
            guard ok else { self.fail(dl, "Disk error", final: true); return }
            guard size == dl.info.size else {
                try? FileManager.default.removeItem(at: dl.part)
                dl.info.done = 0; self.fail(dl, "Size does not match (\(size) of \(dl.info.size) bytes)", final: false); return
            }
            if let v = self.config.verifyFile, !v(dl.part) { try? FileManager.default.removeItem(at: dl.part); self.fail(dl, "Not a readable audio file", final: true); return }
            // the finished file appears in the downloads folder in one step
            var dest = dl.dest; var n = 2
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            while FileManager.default.fileExists(atPath: dest.path) { dest = dl.dest.deletingPathExtension().appendingPathExtension("").deletingLastPathComponent().appendingPathComponent("\(dl.dest.deletingPathExtension().lastPathComponent) (\(n)).\(dl.dest.pathExtension)"); n += 1 }
            if rename(dl.part.path, dest.path) != 0 { self.fail(dl, "Could not move the file into place", final: true); return }
            dl.dest = dest; dl.info.state = .finished; dl.info.done = dl.info.size; dl.link = nil
            self.store.addHistory(kind: "download", user: dl.info.user, path: dl.info.path, size: dl.info.size)
            self.persist(dl.info, dest: dest); self.log.add("·", "Finished \(dl.info.name)")
            self.onDownloaded?(dl.info, dest); self.dirty = true; self.pump()
        } }
    }

    private func applyPause() {
        let paused = Date() < pausedUntil
        for p in peers.values where p.dl != nil { p.link.readPaused = paused }
        dirty = true
        if paused && pausedUntil != .distantFuture { q.asyncAfter(deadline: .now() + max(0.05, pausedUntil.timeIntervalSinceNow + 0.05)) { self.applyPause(); self.pump() } }
        else if !paused { pump() }
    }

    // MARK: uploads

    private func queueUpload(from user: String, path: String, via p: Peer) {
        guard config.sharing else { p.link.send(SlskMessages.uploadDenied(path: path, reason: "File not shared.")); return }
        if store.isBanned(user) { p.link.send(SlskMessages.uploadDenied(path: path, reason: "Banned")); return }
        guard let f = shares.first(where: { $0.virtualPath == path }), FileManager.default.fileExists(atPath: f.localPath) else { p.link.send(SlskMessages.uploadDenied(path: path, reason: "File not shared.")); return }
        if uploads.contains(where: { $0.info.user == user && $0.info.path == path && $0.info.state.isActive }) { return }
        let info = SlskTransferInfo(id: nextTransferID, kind: .upload, user: user, path: path, size: f.size, done: 0, state: .waiting, speed: 0, attempts: 0)
        nextTransferID += 1; uploads.append(Upload(info: info, local: f.localPath)); dirty = true
        scheduleUploads()
    }

    /// Takes the next waiting upload in round-robin order over users, while a slot is free.
    private func scheduleUploads() {
        let slots = playbackGuard ? 1 : config.uploadSlots
        guard Date() >= pausedUntil else { return }
        while uploads.filter({ $0.info.state == .connecting || $0.info.state == .transferring }).count < slots {
            let waiting = uploads.filter { $0.info.state == .waiting }
            guard !waiting.isEmpty else { return }
            let users = Array(Set(waiting.map(\.info.user))).sorted()
            uploadCursor = (uploadCursor + 1) % users.count
            let u = waiting.first { $0.info.user == users[uploadCursor] }!
            u.info.state = .connecting; u.token = token(); dirty = true
            ensurePeer(u.info.user) { [self] p, _ in
                guard let p else { u.info.state = .needsAttention("Can't connect to \(u.info.user)"); scheduleUploads(); return }
                p.link.send(SlskMessages.transferRequest(direction: 1, token: u.token, path: u.info.path, size: u.info.size)); log.add("→", "TransferRequest upload \(u.info.path)")
            }
        }
    }

    private func startUpload(_ u: Upload, via p: Peer) {
        if p.host.isEmpty || p.port == 0 {
            // the peer reached us first: ask the server where it listens
            addressWaiters[u.info.user, default: []].append { [self] a in
                guard let a else { u.info.state = .needsAttention("No address for \(u.info.user)"); dirty = true; scheduleUploads(); return }
                openUploadLink(u, host: a.0, port: a.1)
            }
            sendServer(SlskMessages.getPeerAddress(u.info.user), "GetPeerAddress \(u.info.user)")
            return
        }
        openUploadLink(u, host: p.host, port: p.port)
    }

    private func openUploadLink(_ u: Upload, host: String, port: UInt16) {
        DispatchQueue.global(qos: .utility).async {
            guard let l = self.loop.connect(host: host, port: port, label: "F \(u.info.user)") else { self.q.async { u.info.state = .needsAttention("Can't connect to \(u.info.user)") }; return }
            do {
                let fp = Peer(l); fp.type = "F"; fp.user = u.info.user; fp.fileToken = u.token; self.q.async { self.peers[l.id] = fp }
                var offsetBuf = Data()
                l.onData = { d in
                    offsetBuf.append(d)
                    guard offsetBuf.count >= 8, fp.expected == 0 else { return }
                    var r = SlskReader(offsetBuf); let off = r.u64() ?? 0; fp.expected = 1
                    self.q.async { self.sendFile(u, over: l, from: off) }
                }
                l.onClose = { [weak self] _ in self?.q.async { self?.peers[l.id] = nil; if u.info.state == .transferring { u.info.state = .needsAttention("Connection lost"); self?.scheduleUploads() } } }
                l.onConnect = { l.send(SlskMessages.peerInit(user: self.config.username, type: "F", token: 0)); var w = SlskWriter(); w.u32(u.token); l.send(w.data) }
            }
        }
    }

    private func sendFile(_ u: Upload, over l: SlskLink, from offset: UInt64) {
        u.info.state = .transferring; u.info.done = offset; dirty = true
        let limit = config.uploadLimit
        DispatchQueue(label: "slsk.upload", qos: .utility).async {
            guard let h = FileHandle(forReadingAtPath: u.local) else { self.q.async { u.info.state = .needsAttention("File missing") }; l.close(); return }
            defer { try? h.close() }
            try? h.seek(toOffset: offset)
            var sent = offset
            while sent < u.info.size {
                guard l.isOpen else { return }
                let chunk = (try? h.read(upToCount: 64 * 1024)) ?? Data()
                if chunk.isEmpty { break }
                while l.queuedBytes > 1_000_000, l.isOpen { Thread.sleep(forTimeInterval: 0.01) }
                l.send(chunk); sent += UInt64(chunk.count)
                self.q.async { u.info.done = sent; u.windowBytes += UInt64(chunk.count) }
                if limit > 0 { Thread.sleep(forTimeInterval: Double(chunk.count) / Double(limit)) }
            }
            while l.queuedBytes > 0, l.isOpen { Thread.sleep(forTimeInterval: 0.01) }
            self.q.async {
                u.info.state = .finished; u.info.done = u.info.size
                self.store.addHistory(kind: "upload", user: u.info.user, path: u.info.path, size: u.info.size)
                self.dirty = true; self.scheduleUploads()
            }
            l.closeWhenFlushed()
        }
    }

    // MARK: snapshots

    /// Starts the 4 Hz publisher; call once after setting `onSnapshot`.
    public func startPublishing() {
        q.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 0.25, repeating: 0.25)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); self.timer = t
        }
    }

    private func tick() {
        // speeds over the last interval
        var down = 0.0, up = 0.0
        for d in downloads { let s = Double(d.windowBytes) / 0.25; d.info.speed = d.info.speed * 0.5 + s * 0.5; d.windowBytes = 0; if d.info.state == .transferring { down += d.info.speed } else { d.info.speed = 0 } }
        for u in uploads { let s = Double(u.windowBytes) / 0.25; u.info.speed = u.info.speed * 0.5 + s * 0.5; u.windowBytes = 0; if u.info.state == .transferring { up += u.info.speed } else { u.info.speed = 0 } }
        if down != downSpeed || up != upSpeed { dirty = true }
        downSpeed = down; upSpeed = up
        if state.isOnline, Date().timeIntervalSince(lastPing) > 300 { lastPing = Date(); server?.send(SlskMessages.ping) }
        if dirty { dirty = false; onSnapshot?(makeSnapshot()) }
    }

    private func makeSnapshot() -> SlskSnapshot {
        var s = SlskSnapshot()
        s.state = state; s.listenPort = listenPort
        s.downloads = downloads.map(\.info); s.uploads = uploads.map(\.info)
        s.downSpeed = downSpeed; s.upSpeed = upSpeed
        s.results = responses; s.resultCount = rowCount; s.searching = Date() < searchUntil
        s.rooms = rooms.values.sorted { $0.name < $1.name }; s.messages = messages; s.browsed = browsed
        diag.peerLinks = peers.count; s.diag = diag
        s.protectionPause = Date() < pausedUntil && pausedUntil != .distantFuture
        return s
    }

    /// For tests and shutdown.
    public func shutdown() { q.sync { self.wantOnline = false; self.timer?.cancel(); self.timer = nil }; server?.close(); for p in peers.values { p.link.close() }; loop.stopListening() }
    public var listeningPort: UInt16 { q.sync { listenPort } }
}

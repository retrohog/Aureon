import Foundation
import Network
import CryptoKit
import Security

// The local-network bridge between this Mac and a companion app (iPhone/iPad): the library's change log, playlists and likes, and the
// original audio files, over the local Wi-Fi only. No cloud, no account.
//
// Security: the link is TLS with a pre-shared key (cipher suite TLS_PSK_WITH_AES_128_GCM_SHA256), so only a peer holding the key can even
// finish the handshake. Pairing is a separate, short-lived listener whose key is a random 128-bit token shown on the Mac; the phone
// types or scans it, receives the Mac's long-term bridge key and a personal device token, and uses those from then on. A device can be
// revoked on its own (its token stops working). PSK suites have no forward secrecy; the bridge is meant for a trusted home network.
//
// Wire format: [type: 1 byte][length: 4 bytes, big endian][payload]. JSON payloads except file chunks (raw bytes).

enum BridgeMessage: UInt8 {
    case hello = 1, pair, pairOK, changesRequest, changes, collectionsRequest, collections, fileRequest, fileHead, fileChunk, fileEnd, error, bye
}

struct BridgeHello: Codable { var deviceID: String; var token: String; var version = 1 }
struct BridgePairRequest: Codable { var name: String }
struct BridgeCredentials: Codable, Equatable { var deviceID: String; var token: String; var key: String }       // key: base64 of the bridge key
struct BridgeChangesRequest: Codable { var after: Int64; var limit: Int }
struct BridgeChanges: Codable { var changes: [LibraryChange]; var lastSeq: Int64 }
struct BridgePlaylist: Codable, Equatable { var id: String; var name: String; var tracks: [String] }
struct BridgeCollections: Codable, Equatable { var playlists: [BridgePlaylist]; var liked: [String] }
struct BridgeFileRequest: Codable { var track: String; var offset: Int64 }
struct BridgeFileHead: Codable { var size: Int64; var offset: Int64; var name: String }
struct BridgeFileEnd: Codable { var sha256: String; var bytes: Int64 }          // hash of the bytes sent in this transfer
struct BridgeFailure: Codable { var message: String }

enum BridgeError: LocalizedError {
    case closed, protocolViolation(String), refused(String), integrity
    var errorDescription: String? {
        switch self {
        case .closed: "The connection closed."
        case .protocolViolation(let m): "Unexpected message: \(m)"
        case .refused(let m): m
        case .integrity: "The downloaded file did not match its checksum."
        }
    }
}

protocol BridgeSource: AnyObject, Sendable {
    var lastSeq: Int64 { get }
    func changes(afterSeq: Int64, limit: Int) -> [LibraryChange]
    func playlists() -> [BridgePlaylist]
    func likedIDs() -> [String]
    /// The local file for a track; nil for tracks that live in the cloud or on a server.
    func fileURL(trackID: String) -> URL?
}

final class StoreBridgeSource: BridgeSource, @unchecked Sendable {
    let store: LibraryStore
    init(store: LibraryStore) { self.store = store }
    var lastSeq: Int64 { store.lastSeq }
    func changes(afterSeq: Int64, limit: Int) -> [LibraryChange] { store.changes(afterSeq: afterSeq, limit: limit) }
    func playlists() -> [BridgePlaylist] { store.playlists().map { p in BridgePlaylist(id: p.id, name: p.name, tracks: store.playlistTracks(id: p.id).map(\.id)) } }
    func likedIDs() -> [String] { store.likedTracks().map(\.id) }
    func fileURL(trackID: String) -> URL? {
        guard let t = store.track(id: trackID), !RemoteMedia.isRemote(t.path), FileManager.default.fileExists(atPath: t.path) else { return nil }
        return URL(fileURLWithPath: t.path)
    }
}

// MARK: - Pairing registry

struct PairedDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var tokenHash: String
    var pairedAt: Double
}

final class BridgeRegistry: @unchecked Sendable {
    var secrets: SecretStore = KeychainSecretStore()
    var defaults = UserDefaults.standard
    private let lock = NSLock()

    var devices: [PairedDevice] {
        get { (defaults.data(forKey: "aureon.bridge.devices").flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) }) ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "aureon.bridge.devices") }
    }

    /// The Mac's long-term key: created on first use, kept in the Keychain.
    var bridgeKey: Data {
        lock.lock(); defer { lock.unlock() }
        if let s = secrets.get("bridge.key"), let d = Data(base64Encoded: s), d.count == 32 { return d }
        let d = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        secrets.set(d.base64EncodedString(), for: "bridge.key")
        return d
    }

    static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    func pair(name: String) -> BridgeCredentials {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let token = Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        lock.lock(); var all = devices; all.append(PairedDevice(id: id, name: name, tokenHash: Self.hash(token), pairedAt: Date().timeIntervalSince1970)); devices = all; lock.unlock()
        return BridgeCredentials(deviceID: id, token: token, key: bridgeKey.base64EncodedString())
    }

    func verify(id: String, token: String) -> Bool {
        let h = Self.hash(token)
        return devices.contains { $0.id == id && $0.tokenHash == h }
    }

    func revoke(_ id: String) { lock.lock(); devices = devices.filter { $0.id != id }; lock.unlock() }

    /// Starts over: every device must pair again.
    func rotateKey() { lock.lock(); secrets.set(nil, for: "bridge.key"); devices = []; lock.unlock() }
}

// MARK: - Connection with framing

enum BridgeTLS {
    static func parameters(key: Data, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let o = tls.securityProtocolOptions
        let k = key.withUnsafeBytes { DispatchData(bytes: $0) }, i = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(o, k as __DispatchData, i as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(o, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_tls_pre_shared_key_identity_hint(o, i as __DispatchData)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.enableKeepalive = true
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }
}

final class BridgeLink: @unchecked Sendable {
    let conn: NWConnection
    static let maxFrame = 8 << 20
    init(_ c: NWConnection) { conn = c }

    func start(queue: DispatchQueue) async throws {
        final class Once: @unchecked Sendable { let l = NSLock(); var done = false; func take() -> Bool { l.lock(); defer { l.unlock() }; if done { return false }; done = true; return true } }
        let once = Once()
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: if once.take() { k.resume() }
                case .failed(let e): if once.take() { k.resume(throwing: e) }
                case .cancelled: if once.take() { k.resume(throwing: BridgeError.closed) }
                case .waiting(let e): if once.take() { k.resume(throwing: e) }          // no route / handshake refused: do not wait forever
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    func send(_ type: BridgeMessage, _ payload: Data = Data()) async throws {
        var frame = Data([type.rawValue])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { e in if let e { k.resume(throwing: e) } else { k.resume() } })
        }
    }

    func send<T: Encodable>(_ type: BridgeMessage, json: T) async throws { try await send(type, try JSONEncoder().encode(json)) }

    private func readExactly(_ n: Int) async throws -> Data {
        if n == 0 { return Data() }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { d, _, _, e in
                if let e { k.resume(throwing: e) } else if let d, d.count == n { k.resume(returning: d) } else { k.resume(throwing: BridgeError.closed) }
            }
        }
    }

    func receive() async throws -> (BridgeMessage, Data) {
        let head = try await readExactly(5)
        let len = Int(head[1]) << 24 | Int(head[2]) << 16 | Int(head[3]) << 8 | Int(head[4])
        guard let type = BridgeMessage(rawValue: head[0]) else { throw BridgeError.protocolViolation("type \(head[0])") }
        guard len <= Self.maxFrame else { throw BridgeError.protocolViolation("frame of \(len) bytes") }
        return (type, try await readExactly(len))
    }

    func close() { conn.cancel() }
}

// MARK: - Server

final class BridgeServer: @unchecked Sendable {
    let source: BridgeSource
    let registry: BridgeRegistry
    let advertise: Bool
    let serviceName: String
    var onPaired: ((PairedDevice) -> Void)?
    var onActivity: ((String) -> Void)?

    private let queue = DispatchQueue(label: "aureon.bridge", qos: .utility)        // never competes with the audio threads
    private var session: NWListener?, pairing: NWListener?
    private var pairingToken: Data?
    private let lock = NSLock()
    private(set) var sessionPort: UInt16 = 0, pairingPort: UInt16 = 0
    static let sessionType = "_aureonsync._tcp", pairType = "_aureonpair._tcp"
    static let chunk = 1 << 20

    init(source: BridgeSource, registry: BridgeRegistry, serviceName: String = Host.current().localizedName ?? "Mac", advertise: Bool = true) {
        self.source = source; self.registry = registry; self.serviceName = serviceName; self.advertise = advertise
    }

    private func listener(params: NWParameters, type: String, txt: [String: String]) throws -> (NWListener, UInt16) {
        let l = try NWListener(using: params)
        if advertise { l.service = NWListener.Service(name: serviceName, type: type, domain: nil, txtRecord: NWTXTRecord(txt)) }
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { st in
            switch st { case .ready: ready.signal(); case .failed(let e): failure = e; ready.signal(); default: break }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c, pairing: type == Self.pairType) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, failure == nil, let p = l.port?.rawValue else { l.cancel(); throw failure ?? AureonError.message("the bridge did not start") }
        return (l, p)
    }

    @discardableResult
    func start() throws -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        if session != nil { return sessionPort }
        let (l, p) = try listener(params: BridgeTLS.parameters(key: registry.bridgeKey, identity: "aureon-session"), type: Self.sessionType, txt: ["v": "1"])
        session = l; sessionPort = p
        return p
    }

    /// Opens the pairing listener and returns the token to show on screen.
    func beginPairing() throws -> (token: String, port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        pairing?.cancel(); pairing = nil
        let token = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let (l, p) = try listener(params: BridgeTLS.parameters(key: token, identity: "aureon-pair"), type: Self.pairType, txt: ["v": "1"])
        pairing = l; pairingPort = p; pairingToken = token
        return (Self.display(token), p)
    }

    func endPairing() { lock.lock(); pairing?.cancel(); pairing = nil; pairingToken = nil; lock.unlock() }
    var isPairing: Bool { lock.lock(); defer { lock.unlock() }; return pairing != nil }

    func stop() { lock.lock(); session?.cancel(); pairing?.cancel(); session = nil; pairing = nil; pairingToken = nil; lock.unlock() }

    /// 4-character groups of hex: A1B2-C3D4-…
    static func display(_ token: Data) -> String {
        let hex = token.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { String(hex.dropFirst($0).prefix(4)) }.joined(separator: "-")
    }
    static func parse(_ text: String) -> Data? {
        let hex = text.uppercased().filter { $0.isHexDigit }
        guard hex.count == 32 else { return nil }
        var out = Data(), it = hex.makeIterator()
        while let a = it.next(), let b = it.next() { guard let v = UInt8(String([a, b]), radix: 16) else { return nil }; out.append(v) }
        return out
    }

    private func accept(_ c: NWConnection, pairing isPairing: Bool) {
        let link = BridgeLink(c)
        Task.detached(priority: .utility) { [self] in
            do {
                try await link.start(queue: queue)
                if isPairing { try await servePairing(link) } else { try await serveSession(link) }
            } catch {}
            link.close()
        }
    }

    private func servePairing(_ link: BridgeLink) async throws {
        let (type, payload) = try await link.receive()
        guard type == .pair, let req = try? JSONDecoder().decode(BridgePairRequest.self, from: payload) else { throw BridgeError.protocolViolation("expected pair") }
        let creds = registry.pair(name: String(req.name.prefix(60)))
        try await link.send(.pairOK, json: creds)
        if let d = registry.devices.first(where: { $0.id == creds.deviceID }) { onPaired?(d) }
        endPairing()                                                    // one device per token
        _ = try? await link.receive()                                   // let the phone read the answer before the socket closes
    }

    private func serveSession(_ link: BridgeLink) async throws {
        let (t0, p0) = try await link.receive()
        guard t0 == .hello, let hello = try? JSONDecoder().decode(BridgeHello.self, from: p0), registry.verify(id: hello.deviceID, token: hello.token) else {
            try? await link.send(.error, json: BridgeFailure(message: "This device is not paired (or was removed). Pair it again."))
            return
        }
        let name = registry.devices.first { $0.id == hello.deviceID }?.name ?? hello.deviceID
        onActivity?("\(name) connected")
        try await link.send(.hello, json: BridgeHello(deviceID: "mac", token: "", version: 1))
        while true {
            let (type, payload) = try await link.receive()
            switch type {
            case .changesRequest:
                guard let r = try? JSONDecoder().decode(BridgeChangesRequest.self, from: payload) else { throw BridgeError.protocolViolation("changesRequest") }
                try await link.send(.changes, json: BridgeChanges(changes: source.changes(afterSeq: r.after, limit: min(max(1, r.limit), 2000)), lastSeq: source.lastSeq))
            case .collectionsRequest:
                try await link.send(.collections, json: BridgeCollections(playlists: source.playlists(), liked: source.likedIDs()))
            case .fileRequest:
                guard let r = try? JSONDecoder().decode(BridgeFileRequest.self, from: payload) else { throw BridgeError.protocolViolation("fileRequest") }
                try await sendFile(link, request: r)
            case .bye: return
            default: throw BridgeError.protocolViolation("\(type)")
            }
        }
    }

    private func sendFile(_ link: BridgeLink, request r: BridgeFileRequest) async throws {
        guard let url = source.fileURL(trackID: r.track), let fh = try? FileHandle(forReadingFrom: url) else {
            try await link.send(.error, json: BridgeFailure(message: "That track is not a file on this Mac."))
            return
        }
        defer { try? fh.close() }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        let offset = min(max(0, r.offset), size)
        try await link.send(.fileHead, json: BridgeFileHead(size: size, offset: offset, name: url.lastPathComponent))
        try fh.seek(toOffset: UInt64(offset))
        var hasher = SHA256(), sent: Int64 = 0
        while true {
            let d = try fh.read(upToCount: Self.chunk) ?? Data()
            if d.isEmpty { break }
            hasher.update(data: d); sent += Int64(d.count)
            try await link.send(.fileChunk, d)                          // returns when the network has taken it: the file is never read faster than it is sent
        }
        try await link.send(.fileEnd, json: BridgeFileEnd(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes: sent))
    }
}

// MARK: - Client

final class BridgeClient: @unchecked Sendable {
    let endpoint: NWEndpoint
    let credentials: BridgeCredentials
    private var link: BridgeLink?
    private let queue = DispatchQueue(label: "aureon.bridge.client")

    init(endpoint: NWEndpoint, credentials: BridgeCredentials) { self.endpoint = endpoint; self.credentials = credentials }

    /// Trades the pairing token (typed from the Mac's screen) for credentials.
    static func pair(endpoint: NWEndpoint, tokenText: String, deviceName: String) async throws -> BridgeCredentials {
        guard let token = BridgeServer.parse(tokenText) else { throw BridgeError.refused("The pairing code should be 32 letters and digits (0–9, A–F).") }
        let link = BridgeLink(NWConnection(to: endpoint, using: BridgeTLS.parameters(key: token, identity: "aureon-pair")))
        defer { link.close() }
        try await link.start(queue: DispatchQueue(label: "aureon.bridge.pair"))
        try await link.send(.pair, json: BridgePairRequest(name: deviceName))
        let (t, p) = try await link.receive()
        guard t == .pairOK, let c = try? JSONDecoder().decode(BridgeCredentials.self, from: p) else { throw BridgeError.protocolViolation("expected pairOK") }
        try? await link.send(.bye)
        return c
    }

    func connect() async throws {
        guard let key = Data(base64Encoded: credentials.key) else { throw BridgeError.refused("The stored key is damaged. Pair again.") }
        let l = BridgeLink(NWConnection(to: endpoint, using: BridgeTLS.parameters(key: key, identity: "aureon-session")))
        try await l.start(queue: queue)
        try await l.send(.hello, json: BridgeHello(deviceID: credentials.deviceID, token: credentials.token))
        let (t, p) = try await l.receive()
        if t == .error { l.close(); throw BridgeError.refused((try? JSONDecoder().decode(BridgeFailure.self, from: p))?.message ?? "refused") }
        guard t == .hello else { l.close(); throw BridgeError.protocolViolation("expected hello") }
        link = l
    }

    func close() { Task { try? await link?.send(.bye); link?.close(); link = nil } }

    private func request<T: Decodable>(_ type: BridgeMessage, _ body: some Encodable, expect: BridgeMessage, as: T.Type) async throws -> T {
        guard let link else { throw BridgeError.closed }
        try await link.send(type, json: body)
        let (t, p) = try await link.receive()
        if t == .error { throw BridgeError.refused((try? JSONDecoder().decode(BridgeFailure.self, from: p))?.message ?? "refused") }
        guard t == expect else { throw BridgeError.protocolViolation("\(t)") }
        return try JSONDecoder().decode(T.self, from: p)
    }

    func changes(after: Int64, limit: Int = 500) async throws -> BridgeChanges { try await request(.changesRequest, BridgeChangesRequest(after: after, limit: limit), expect: .changes, as: BridgeChanges.self) }
    func collections() async throws -> BridgeCollections { try await request(.collectionsRequest, BridgeChangesRequest(after: 0, limit: 0), expect: .collections, as: BridgeCollections.self) }

    /// Every change since `cursor`, page by page. Returns them and the new cursor.
    func allChanges(after cursor: Int64) async throws -> (changes: [LibraryChange], cursor: Int64) {
        var out: [LibraryChange] = [], c = cursor
        while true {
            let page = try await changes(after: c)
            out += page.changes
            guard let last = page.changes.last else { return (out, c) }
            c = last.seq
            if page.changes.count < 500 { return (out, c) }
        }
    }

    /// Downloads one track to `url`, resuming a partial file there. Verifies the checksum of what was transferred.
    func download(track: String, to url: URL, progress: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let link else { throw BridgeError.closed }
        let fm = FileManager.default
        let have = Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        try await link.send(.fileRequest, try JSONEncoder().encode(BridgeFileRequest(track: track, offset: have)))
        let (t, p) = try await link.receive()
        if t == .error { throw BridgeError.refused((try? JSONDecoder().decode(BridgeFailure.self, from: p))?.message ?? "refused") }
        guard t == .fileHead, let head = try? JSONDecoder().decode(BridgeFileHead.self, from: p) else { throw BridgeError.protocolViolation("expected fileHead") }
        if head.offset == 0 || !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.truncate(atOffset: UInt64(head.offset)); try fh.seek(toOffset: UInt64(head.offset))
        var hasher = SHA256(), got: Int64 = 0
        while true {
            let (type, data) = try await link.receive()
            switch type {
            case .fileChunk:
                hasher.update(data: data); try fh.write(contentsOf: data); got += Int64(data.count)
                progress?(head.offset + got, head.size)
            case .fileEnd:
                let end = try JSONDecoder().decode(BridgeFileEnd.self, from: data)
                let mine = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard end.bytes == got, end.sha256 == mine, head.offset + got == head.size else { throw BridgeError.integrity }
                return
            case .error: throw BridgeError.refused((try? JSONDecoder().decode(BridgeFailure.self, from: data))?.message ?? "refused")
            default: throw BridgeError.protocolViolation("\(type)")
            }
        }
    }
}

/// Finds Macs sharing their library (and, while a pairing is open, the pairing listener).
final class BridgeBrowser: @unchecked Sendable {
    struct Found: Equatable, Sendable { var name: String; var endpoint: NWEndpoint }
    private var browsers: [NWBrowser] = []
    var onChange: (([Found], [Found]) -> Void)?       // (sessions, pairings)
    private var sessions: [Found] = [], pairings: [Found] = []
    private let queue = DispatchQueue(label: "aureon.bridge.browse")

    func start() {
        guard browsers.isEmpty else { return }
        for (type, isPair) in [(BridgeServer.sessionType, false), (BridgeServer.pairType, true)] {
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                let list = results.compactMap { r -> Found? in if case .service(let n, _, _, _) = r.endpoint { return Found(name: n, endpoint: r.endpoint) }; return nil }
                if isPair { self.pairings = list } else { self.sessions = list }
                self.onChange?(self.sessions, self.pairings)
            }
            b.start(queue: queue); browsers.append(b)
        }
    }
    func stop() { browsers.forEach { $0.cancel() }; browsers = [] }
}

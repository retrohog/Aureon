import Foundation
import Darwin

// Discord Rich Presence over Discord's local IPC (a Unix-domain socket, `discord-ipc-N`).
//
// Frame format (both directions): opcode (UInt32 LE) | payload length (UInt32 LE) | JSON payload.
//   opcode 0 HANDSHAKE   {"v":1,"client_id":"…"}                     → Discord answers with a FRAME {"cmd":"DISPATCH","evt":"READY",…}
//   opcode 1 FRAME       {"cmd":"SET_ACTIVITY","args":{"pid":…,"activity":{…}},"nonce":"…"}
//   opcode 2 CLOSE, 3 PING, 4 PONG
// Needs a Discord application ID (https://discord.com/developers/applications); no secrets, no OAuth.

struct DiscordActivity: Equatable {
    enum Kind: Int { case playing = 0, listening = 2 }
    var kind: Kind = .listening
    var details: String
    var state: String
    var start: Int? = nil                 // unix seconds
    var end: Int? = nil
    var largeImage: String? = nil         // an uploaded asset key or an https URL
    var largeText: String? = nil
    var smallImage: String? = nil
    var smallText: String? = nil

    /// Discord requires 2…128 characters for text fields.
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 128 { t = String(t.prefix(125)) + "…" }
        if t.count < 2 { t += String(repeating: " ", count: 2 - t.count) + "\u{200B}" }
        return t
    }

    var json: [String: Any] {
        var a: [String: Any] = ["type": kind.rawValue, "details": Self.clean(details), "state": Self.clean(state), "instance": false]
        var ts: [String: Any] = [:]
        if let start { ts["start"] = start }; if let end { ts["end"] = end }
        if !ts.isEmpty { a["timestamps"] = ts }
        var assets: [String: Any] = [:]
        if let largeImage { assets["large_image"] = largeImage }
        if let largeText { assets["large_text"] = Self.clean(largeText) }
        if let smallImage { assets["small_image"] = smallImage }
        if let smallText { assets["small_text"] = Self.clean(smallText) }
        if !assets.isEmpty { a["assets"] = assets }
        return a
    }
}

enum DiscordError: LocalizedError {
    case notRunning
    case handshakeFailed(String)
    case rpc(Int, String)
    case closed
    var errorDescription: String? {
        switch self {
        case .notRunning: "Discord is not running (no discord-ipc socket found)"
        case .handshakeFailed(let m): "Discord handshake failed: \(m)"
        case .rpc(let c, let m): "Discord error \(c): \(m)"
        case .closed: "Discord closed the connection"
        }
    }
}

enum DiscordFrame {
    static func encode(op: UInt32, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var d = Data()
        withUnsafeBytes(of: op.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { d.append(contentsOf: $0) }
        return d + body
    }
}

/// A connected Unix-domain stream socket with blocking reads and a timeout.
final class UnixSocket {
    private var fd: Int32

    init?(path: String, timeout: TimeInterval = 2) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() { p[i] = UInt8(bitPattern: b) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if ok != 0 { Darwin.close(fd); return nil }
    }

    func send(_ d: Data) throws {
        var off = 0
        try d.withUnsafeBytes { p in
            while off < d.count {
                let n = Darwin.send(fd, p.baseAddress! + off, d.count - off, 0)
                if n <= 0 { throw DiscordError.closed }
                off += n
            }
        }
    }

    func receive(_ count: Int) throws -> Data {
        var out = Data(capacity: count)
        var buf = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let n = recv(fd, &buf, count - out.count, 0)
            if n <= 0 { throw DiscordError.closed }
            out.append(contentsOf: buf.prefix(n))
        }
        return out
    }

    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    deinit { close() }
}

final class DiscordIPC: @unchecked Sendable {
    let clientID: String
    private let directories: () -> [String]
    private let lock = NSLock()
    private var socket: UnixSocket?
    private(set) var isConnected = false

    /// Where Discord puts its socket on macOS: $TMPDIR (and the usual fallbacks).
    static func defaultDirectories() -> [String] {
        let env = ProcessInfo.processInfo.environment
        var dirs = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { env[$0] }
        dirs.append("/tmp")
        return dirs.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    init(clientID: String, directories: @escaping () -> [String] = DiscordIPC.defaultDirectories) { self.clientID = clientID; self.directories = directories }
    deinit { close() }

    private func readFrame(_ s: UnixSocket) throws -> (op: UInt32, json: [String: Any]) {
        let h = try s.receive(8)
        let op = h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let len = Int(h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }.littleEndian)
        guard len < 1 << 20 else { throw DiscordError.handshakeFailed("oversized frame") }
        let body = len > 0 ? try s.receive(len) : Data()
        return (op, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
    }

    func connect() throws {
        lock.lock(); defer { lock.unlock() }
        try connectLocked()
    }

    private func connectLocked() throws {
        socket?.close(); socket = nil; isConnected = false
        var found: UnixSocket?
        search: for dir in directories() { for i in 0..<10 { if let s = UnixSocket(path: "\(dir)/discord-ipc-\(i)") { found = s; break search } } }
        guard let s = found else { throw DiscordError.notRunning }
        try s.send(DiscordFrame.encode(op: 0, json: ["v": 1, "client_id": clientID]))
        let (op, json) = try readFrame(s)
        if op == 2 { throw DiscordError.handshakeFailed((json["message"] as? String) ?? "closed by Discord") }
        guard (json["evt"] as? String) == "READY" else { throw DiscordError.handshakeFailed("unexpected reply \(json)") }
        socket = s; isConnected = true
    }

    /// Sets (or, with nil, clears) the activity. Reconnects once if Discord went away.
    func setActivity(_ activity: DiscordActivity?) throws {
        lock.lock(); defer { lock.unlock() }
        if !isConnected { try connectLocked() }
        do { try sendActivity(activity) }
        catch DiscordError.closed { try connectLocked(); try sendActivity(activity) }
    }

    private func sendActivity(_ a: DiscordActivity?) throws {
        guard let s = socket else { throw DiscordError.closed }
        let nonce = UUID().uuidString
        var args: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier)]
        if let a { args["activity"] = a.json }
        do { try s.send(DiscordFrame.encode(op: 1, json: ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce])) } catch { isConnected = false; throw error }
        for _ in 0..<6 {
            let (op, json): (UInt32, [String: Any])
            do { (op, json) = try readFrame(s) } catch { isConnected = false; throw error }
            if op == 3 { try? s.send(DiscordFrame.encode(op: 4, json: json)); continue }              // answer pings
            if op == 2 { isConnected = false; throw DiscordError.closed }
            if (json["nonce"] as? String) == nonce {
                if (json["evt"] as? String) == "ERROR", let d = json["data"] as? [String: Any] { throw DiscordError.rpc(d["code"] as? Int ?? 0, d["message"] as? String ?? "error") }
                return
            }
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        socket?.close(); socket = nil; isConnected = false
    }
}

enum DiscordPresence {
    /// The activity for the current playback state. While paused no timestamps are sent (Discord would keep counting).
    static func activity(for t: NowPlayingInfo, position: Double, playing: Bool, now: Date = Date(), fallbackImage: String? = "aureon") -> DiscordActivity {
        var a = DiscordActivity(details: t.title, state: playing ? (t.artist.isEmpty ? "Unknown artist" : "by \(t.artist)") : "Paused" + (t.artist.isEmpty ? "" : " · \(t.artist)"))
        if playing {
            let start = now.timeIntervalSince1970 - position
            a.start = Int(start)
            if t.duration > 0 { a.end = Int(start + t.duration) }
        }
        a.largeImage = t.coverURL ?? fallbackImage
        a.largeText = t.album.isEmpty ? "Aureon" : t.album
        a.smallText = t.qualityLabel.isEmpty ? nil : t.qualityLabel
        if a.smallText != nil { a.smallImage = t.isDSD ? "dsd" : "hires" }
        return a
    }
}

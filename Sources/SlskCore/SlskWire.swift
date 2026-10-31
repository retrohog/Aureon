import Foundation
import CryptoKit
import Compression

// The Soulseek wire format as pure functions: little-endian integers, strings as a uint32 length and bytes, frames as `uint32 length | uint32 code | payload`
// (peer-init messages use a one-byte code). Nothing here opens a socket or touches the user interface.

public struct SlskWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }
    public mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    public mutating func string(_ s: String) { let b = Array(s.utf8); u32(UInt32(b.count)); data.append(contentsOf: b) }
    public mutating func raw(_ d: Data) { data.append(d) }
}

public struct SlskReader {
    private let data: Data
    private var pos: Int
    public init(_ d: Data) { data = d; pos = d.startIndex }
    public var remaining: Int { data.endIndex - pos }
    public var isAtEnd: Bool { remaining == 0 }
    public mutating func u8() -> UInt8? { guard remaining >= 1 else { return nil }; defer { pos += 1 }; return data[pos] }
    public mutating func bool() -> Bool? { u8().map { $0 != 0 } }
    public mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(data[pos + i]) << (8 * UInt32(i)) }
        pos += 4; return v
    }
    public mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(data[pos + i]) << (8 * UInt64(i)) }
        pos += 8; return v
    }
    public mutating func string() -> String? {
        guard let n = u32(), Int(n) <= remaining else { return nil }
        let s = String(decoding: data[pos..<pos + Int(n)], as: UTF8.self); pos += Int(n); return s
    }
    public mutating func rest() -> Data { defer { pos = data.endIndex }; return data[pos...] }
}

/// A message of the server or of a peer: a code and its payload.
public struct SlskFrame: Equatable {
    public var code: UInt32
    public var payload: Data
    public init(code: UInt32, payload: Data) { self.code = code; self.payload = payload }
    public func encoded() -> Data {
        var w = SlskWriter(); w.u32(UInt32(payload.count + 4)); w.u32(code); w.raw(payload); return w.data
    }
}

/// Cuts a byte stream into frames, whatever the chunking. A frame longer than `maxFrame` ends the link (a damaged or hostile stream).
public struct SlskFrameParser {
    public static let maxFrame = 64 * 1024 * 1024
    private var buffer = Data()
    public private(set) var failed = false
    public init() {}
    public mutating func feed(_ d: Data) -> [SlskFrame] {
        guard !failed else { return [] }
        buffer.append(d)
        var out: [SlskFrame] = []
        while buffer.count >= 8 {
            let len = Int(buffer.u32(at: 0))
            if len < 4 || len > Self.maxFrame { failed = true; buffer.removeAll(); return out }
            guard buffer.count >= 4 + len else { break }
            let code = buffer.u32(at: 4)
            out.append(SlskFrame(code: code, payload: Data(buffer[(buffer.startIndex + 8)..<(buffer.startIndex + 4 + len)])))
            buffer = Data(buffer.dropFirst(4 + len))
        }
        return out
    }
    /// Bytes held back for the next chunk.
    public var pending: Int { buffer.count }
}

extension Data {
    public func u32(at i: Int) -> UInt32 {
        var v: UInt32 = 0; for k in 0..<4 { v |= UInt32(self[startIndex + i + k]) << (8 * UInt32(k)) }; return v
    }
}

public enum SlskCode {
    // server
    public static let login: UInt32 = 1, setListenPort: UInt32 = 2, getPeerAddress: UInt32 = 3, connectToPeer: UInt32 = 18
    public static let fileSearch: UInt32 = 26, setStatus: UInt32 = 28, ping: UInt32 = 32, sharedFoldersFiles: UInt32 = 35
    public static let haveNoParent: UInt32 = 71, joinRoom: UInt32 = 14, leaveRoom: UInt32 = 15, sayInRoom: UInt32 = 13
    public static let privateMessage: UInt32 = 22, ackPrivateMessage: UInt32 = 23, addUser: UInt32 = 5, wishlistSearch: UInt32 = 103
    public static let roomList: UInt32 = 64
    // peer
    public static let sharedFileListRequest: UInt32 = 4, sharedFileListResponse: UInt32 = 5, fileSearchResponse: UInt32 = 9
    public static let transferRequest: UInt32 = 40, transferResponse: UInt32 = 41, queueUpload: UInt32 = 43, placeInQueue: UInt32 = 44
    public static let uploadFailed: UInt32 = 46, uploadDenied: UInt32 = 50, placeInQueueRequest: UInt32 = 51
    // peer init (one-byte codes)
    public static let pierceFirewall: UInt8 = 0, peerInit: UInt8 = 1
}

public enum SlskMessages {
    public static let clientVersion: UInt32 = 160, minorVersion: UInt32 = 1

    public static func md5Hex(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    public static func login(user: String, password: String) -> SlskFrame {
        var w = SlskWriter(); w.string(user); w.string(password); w.u32(clientVersion); w.string(md5Hex(user + password)); w.u32(minorVersion)
        return SlskFrame(code: SlskCode.login, payload: w.data)
    }
    public static func setListenPort(_ port: UInt16) -> SlskFrame { var w = SlskWriter(); w.u32(UInt32(port)); return SlskFrame(code: SlskCode.setListenPort, payload: w.data) }
    public static func setStatus(_ status: UInt32 = 2) -> SlskFrame { var w = SlskWriter(); w.u32(status); return SlskFrame(code: SlskCode.setStatus, payload: w.data) }
    public static func sharedFoldersFiles(folders: UInt32, files: UInt32) -> SlskFrame { var w = SlskWriter(); w.u32(folders); w.u32(files); return SlskFrame(code: SlskCode.sharedFoldersFiles, payload: w.data) }
    public static func haveNoParent(_ v: Bool = true) -> SlskFrame { var w = SlskWriter(); w.bool(v); return SlskFrame(code: SlskCode.haveNoParent, payload: w.data) }
    public static let ping = SlskFrame(code: SlskCode.ping, payload: Data())
    public static func fileSearch(token: UInt32, query: String) -> SlskFrame { var w = SlskWriter(); w.u32(token); w.string(query); return SlskFrame(code: SlskCode.fileSearch, payload: w.data) }
    public static func getPeerAddress(_ user: String) -> SlskFrame { var w = SlskWriter(); w.string(user); return SlskFrame(code: SlskCode.getPeerAddress, payload: w.data) }
    public static func connectToPeer(token: UInt32, user: String, type: String) -> SlskFrame { var w = SlskWriter(); w.u32(token); w.string(user); w.string(type); return SlskFrame(code: SlskCode.connectToPeer, payload: w.data) }
    public static func joinRoom(_ room: String) -> SlskFrame { var w = SlskWriter(); w.string(room); return SlskFrame(code: SlskCode.joinRoom, payload: w.data) }
    public static func leaveRoom(_ room: String) -> SlskFrame { var w = SlskWriter(); w.string(room); return SlskFrame(code: SlskCode.leaveRoom, payload: w.data) }
    public static func sayInRoom(_ room: String, _ text: String) -> SlskFrame { var w = SlskWriter(); w.string(room); w.string(text); return SlskFrame(code: SlskCode.sayInRoom, payload: w.data) }
    public static func privateMessage(user: String, text: String) -> SlskFrame { var w = SlskWriter(); w.string(user); w.string(text); return SlskFrame(code: SlskCode.privateMessage, payload: w.data) }
    public static func ackPrivateMessage(id: UInt32) -> SlskFrame { var w = SlskWriter(); w.u32(id); return SlskFrame(code: SlskCode.ackPrivateMessage, payload: w.data) }
    public static func addUser(_ user: String) -> SlskFrame { var w = SlskWriter(); w.string(user); return SlskFrame(code: SlskCode.addUser, payload: w.data) }
    public static func wishlistSearch(token: UInt32, query: String) -> SlskFrame { var w = SlskWriter(); w.u32(token); w.string(query); return SlskFrame(code: SlskCode.wishlistSearch, payload: w.data) }

    // peer init messages (a one-byte code, not a frame)
    public static func peerInit(user: String, type: String, token: UInt32) -> Data {
        var p = SlskWriter(); p.u8(SlskCode.peerInit); p.string(user); p.string(type); p.u32(token)
        var w = SlskWriter(); w.u32(UInt32(p.data.count)); w.raw(p.data); return w.data
    }
    public static func pierceFirewall(token: UInt32) -> Data {
        var p = SlskWriter(); p.u8(SlskCode.pierceFirewall); p.u32(token)
        var w = SlskWriter(); w.u32(UInt32(p.data.count)); w.raw(p.data); return w.data
    }

    // peer messages
    public static func queueUpload(_ path: String) -> SlskFrame { var w = SlskWriter(); w.string(path); return SlskFrame(code: SlskCode.queueUpload, payload: w.data) }
    public static func placeInQueueRequest(_ path: String) -> SlskFrame { var w = SlskWriter(); w.string(path); return SlskFrame(code: SlskCode.placeInQueueRequest, payload: w.data) }
    public static func placeInQueue(path: String, place: UInt32) -> SlskFrame { var w = SlskWriter(); w.string(path); w.u32(place); return SlskFrame(code: SlskCode.placeInQueue, payload: w.data) }
    public static func transferRequest(direction: UInt32, token: UInt32, path: String, size: UInt64?) -> SlskFrame {
        var w = SlskWriter(); w.u32(direction); w.u32(token); w.string(path); if let size { w.u64(size) }
        return SlskFrame(code: SlskCode.transferRequest, payload: w.data)
    }
    public static func transferResponse(token: UInt32, allowed: Bool, reason: String? = nil, size: UInt64? = nil) -> SlskFrame {
        var w = SlskWriter(); w.u32(token); w.bool(allowed)
        if allowed { if let size { w.u64(size) } } else { w.string(reason ?? "Cancelled") }
        return SlskFrame(code: SlskCode.transferResponse, payload: w.data)
    }
    public static func uploadDenied(path: String, reason: String) -> SlskFrame { var w = SlskWriter(); w.string(path); w.string(reason); return SlskFrame(code: SlskCode.uploadDenied, payload: w.data) }
    public static func uploadFailed(path: String) -> SlskFrame { var w = SlskWriter(); w.string(path); return SlskFrame(code: SlskCode.uploadFailed, payload: w.data) }
}

// MARK: - Decoded server and peer messages

public struct SlskLoginResult: Equatable {
    public var success: Bool
    public var greeting: String
    public var reason: String
    public static func parse(_ f: SlskFrame) -> SlskLoginResult? {
        var r = SlskReader(f.payload)
        guard f.code == SlskCode.login, let ok = r.bool() else { return nil }
        if ok { return SlskLoginResult(success: true, greeting: r.string() ?? "", reason: "") }
        return SlskLoginResult(success: false, greeting: "", reason: r.string() ?? "Login failed")
    }
}

/// Addresses cross the wire with their bytes reversed: the four bytes `0a 01 a8 c0` are 192.168.1.10, so as a little-endian number the first octet is the top byte.
func dotted(_ ip: UInt32) -> String { "\(ip >> 24).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)" }

public struct SlskPeerAddress: Equatable {
    public var user: String, host: String, port: UInt16
    public static func parse(_ f: SlskFrame) -> SlskPeerAddress? {
        var r = SlskReader(f.payload)
        guard f.code == SlskCode.getPeerAddress, let u = r.string(), let ip = r.u32(), let p = r.u32() else { return nil }
        let host = dotted(ip)
        return SlskPeerAddress(user: u, host: host, port: UInt16(truncatingIfNeeded: p))
    }
    public static func encode(user: String, host: String, port: UInt16) -> SlskFrame {
        let o = host.split(separator: ".").compactMap { UInt32($0) }
        var w = SlskWriter(); w.string(user)
        w.u32(o.count == 4 ? o[3] | o[2] << 8 | o[1] << 16 | o[0] << 24 : 0); w.u32(UInt32(port))
        return SlskFrame(code: SlskCode.getPeerAddress, payload: w.data)
    }
}

/// The server asks us to connect to a peer that cannot reach us (or tells us who is behind a token).
public struct SlskConnectToPeer: Equatable {
    public var user: String, type: String, host: String, port: UInt16, token: UInt32
    public static func parse(_ f: SlskFrame) -> SlskConnectToPeer? {
        var r = SlskReader(f.payload)
        guard f.code == SlskCode.connectToPeer, let u = r.string(), let t = r.string(), let ip = r.u32(), let p = r.u32(), let tok = r.u32() else { return nil }
        return SlskConnectToPeer(user: u, type: t, host: dotted(ip), port: UInt16(truncatingIfNeeded: p), token: tok)
    }
}

public struct SlskFileResult: Equatable, Identifiable {
    public var path: String
    public var size: UInt64
    public var ext: String
    public var bitrate: Int?, duration: Int?, sampleRate: Int?, bitDepth: Int?, vbr: Bool
    public var id: String { path }
    public var name: String { path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path }
    public var folder: String {
        let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        return parts.count > 1 ? parts.dropLast().joined(separator: "\\") : ""
    }
    public init(path: String, size: UInt64, ext: String, bitrate: Int?, duration: Int?, sampleRate: Int?, bitDepth: Int?, vbr: Bool) {
        self.path = path; self.size = size; self.ext = ext; self.bitrate = bitrate; self.duration = duration; self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.vbr = vbr
    }
    public var isLossless: Bool { ["flac", "wav", "aiff", "aif", "alac", "ape", "wv", "dsf", "dff"].contains(ext.lowercased()) }
}

public struct SlskSearchResponse: Equatable {
    public var user: String
    public var token: UInt32
    public var files: [SlskFileResult]
    public var freeSlot: Bool
    public var speed: UInt32
    public var queueLength: UInt32
    public init(user: String, token: UInt32, files: [SlskFileResult], freeSlot: Bool, speed: UInt32, queueLength: UInt32) {
        self.user = user; self.token = token; self.files = files; self.freeSlot = freeSlot; self.speed = speed; self.queueLength = queueLength
    }

    /// A code 9 message: its payload is zlib-compressed.
    public static func parse(_ f: SlskFrame) -> SlskSearchResponse? {
        guard f.code == SlskCode.fileSearchResponse, let raw = SlskZlib.inflate(f.payload) else { return nil }
        var r = SlskReader(raw)
        guard let user = r.string(), let token = r.u32(), let n = r.u32(), n < 100_000 else { return nil }
        var files: [SlskFileResult] = []
        for _ in 0..<n {
            guard r.u8() != nil, let path = r.string(), let size = r.u64(), let ext = r.string(), let na = r.u32(), na < 64 else { return nil }
            var res = SlskFileResult(path: path, size: size, ext: ext, bitrate: nil, duration: nil, sampleRate: nil, bitDepth: nil, vbr: false)
            for _ in 0..<na {
                guard let k = r.u32(), let v = r.u32() else { return nil }
                switch k { case 0: res.bitrate = Int(v); case 1: res.duration = Int(v); case 2: res.vbr = v != 0; case 4: res.sampleRate = Int(v); case 5: res.bitDepth = Int(v); default: break }
            }
            files.append(res)
        }
        let free = r.bool() ?? false, speed = r.u32() ?? 0, q = r.u32() ?? 0
        return SlskSearchResponse(user: user, token: token, files: files, freeSlot: free, speed: speed, queueLength: q)
    }

    public static func encode(_ s: SlskSearchResponse) -> SlskFrame {
        var w = SlskWriter(); w.string(s.user); w.u32(s.token); w.u32(UInt32(s.files.count))
        for f in s.files {
            w.u8(1); w.string(f.path); w.u64(f.size); w.string(f.ext)
            var attrs: [(UInt32, UInt32)] = []
            if let b = f.bitrate { attrs.append((0, UInt32(b))) }
            if let d = f.duration { attrs.append((1, UInt32(d))) }
            if f.vbr { attrs.append((2, 1)) }
            if let r = f.sampleRate { attrs.append((4, UInt32(r))) }
            if let b = f.bitDepth { attrs.append((5, UInt32(b))) }
            w.u32(UInt32(attrs.count)); for a in attrs { w.u32(a.0); w.u32(a.1) }
        }
        w.bool(s.freeSlot); w.u32(s.speed); w.u32(s.queueLength); w.u32(0)
        return SlskFrame(code: SlskCode.fileSearchResponse, payload: SlskZlib.deflate(w.data))
    }
}

public struct SlskTransferRequest: Equatable {
    public var direction: UInt32, token: UInt32, path: String, size: UInt64?
    public init(direction: UInt32, token: UInt32, path: String, size: UInt64?) { self.direction = direction; self.token = token; self.path = path; self.size = size }
    public static func parse(_ f: SlskFrame) -> SlskTransferRequest? {
        var r = SlskReader(f.payload)
        guard f.code == SlskCode.transferRequest, let d = r.u32(), let t = r.u32(), let p = r.string() else { return nil }
        return SlskTransferRequest(direction: d, token: t, path: p, size: d == 1 ? r.u64() : nil)
    }
}

public struct SlskTransferResponse: Equatable {
    public var token: UInt32, allowed: Bool, reason: String?, size: UInt64?
    public static func parse(_ f: SlskFrame) -> SlskTransferResponse? {
        var r = SlskReader(f.payload)
        guard f.code == SlskCode.transferResponse, let t = r.u32(), let ok = r.bool() else { return nil }
        return SlskTransferResponse(token: t, allowed: ok, reason: ok ? nil : r.string(), size: ok ? r.u64() : nil)
    }
}

// MARK: - zlib (RFC 1950) over the system's raw deflate

public enum SlskZlib {
    /// Wraps raw deflate in the two-byte zlib header and the Adler-32 trailer.
    public static func deflate(_ d: Data) -> Data {
        var out = Data([0x78, 0x9c])
        if d.isEmpty { out.append(contentsOf: [0x03, 0x00]) }
        else {
            let cap = d.count + d.count / 8 + 64
            var buf = [UInt8](repeating: 0, count: cap)
            let n = d.withUnsafeBytes { src in compression_encode_buffer(&buf, cap, src.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB) }
            out.append(contentsOf: buf[0..<n])
        }
        let a = adler32(d); out.append(contentsOf: [UInt8(a >> 24), UInt8((a >> 16) & 255), UInt8((a >> 8) & 255), UInt8(a & 255)])
        return out
    }

    /// The bytes inside a zlib stream, or nil for damaged input. Output is limited to `limit` bytes.
    public static func inflate(_ d: Data, limit: Int = 256 * 1024 * 1024) -> Data? {
        guard d.count >= 6, d[d.startIndex] & 0x0f == 8, (UInt16(d[d.startIndex]) << 8 | UInt16(d[d.startIndex + 1])) % 31 == 0 else { return nil }
        let body = d.dropFirst(2).dropLast(4)
        if body.isEmpty { return nil }
        var out = Data(), cap = max(4096, body.count * 6)
        while cap <= limit {
            var buf = [UInt8](repeating: 0, count: cap)
            let src = Array(body)
            let n = compression_decode_buffer(&buf, cap, src, src.count, nil, COMPRESSION_ZLIB)
            if n == 0 { return nil }
            if n < cap { out = Data(buf[0..<n]); break }
            cap *= 4
        }
        guard !out.isEmpty || body.count <= 2 else { return nil }
        let want = d.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return adler32(out) == want ? out : nil
    }

    static func adler32(_ d: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in d { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }
}

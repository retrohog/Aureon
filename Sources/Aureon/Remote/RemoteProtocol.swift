import Foundation
import CryptoKit

// Aureon remote protocol, version 1: JSON-RPC 2.0 over WebSocket text frames.
// This file and RemoteClient.swift depend only on Foundation/CryptoKit, so an iOS/iPadOS app can reuse them unchanged.
//
//   server → client   {"jsonrpc":"2.0","method":"hello","params":{"nonce":"…","protocol":1,"server":"Living room"}}
//   client → server   {"jsonrpc":"2.0","id":1,"method":"auth","params":{"hmac":"HMAC-SHA256(token, nonce) as hex"}}
//   …then any method below; the server also pushes notifications: status, queue.changed, settings.changed, library.changed.
//
// The pairing token never crosses the network: the client proves it knows it by answering a fresh nonce.
// (The channel itself is not encrypted — use it on a trusted network or tunnel it over a VPN.)

enum RemoteProtocol {
    static let version = 1
    static let bonjourType = "_aureon._tcp"

    static func hmac(token: String, nonce: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(token.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison.
    static func verify(token: String, nonce: String, response: String) -> Bool {
        let a = Array(hmac(token: token, nonce: nonce).utf8), b = Array(response.lowercased().utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func newNonce() -> String { newToken() }
}

enum RemoteErrorCode {
    static let parse = -32700, invalidRequest = -32600, methodNotFound = -32601, invalidParams = -32602, internalError = -32603
    static let unauthorized = 401, notFound = 404, forbidden = 403
}

struct RemoteError: Error, LocalizedError, Equatable {
    var code: Int
    var message: String
    var errorDescription: String? { "\(message) (\(code))" }
    static func invalidParams(_ m: String) -> RemoteError { RemoteError(code: RemoteErrorCode.invalidParams, message: m) }
    static func notFound(_ m: String) -> RemoteError { RemoteError(code: RemoteErrorCode.notFound, message: m) }
    static func forbidden(_ m: String) -> RemoteError { RemoteError(code: RemoteErrorCode.forbidden, message: m) }
}

// MARK: - DTOs shared by server and clients

struct QueueEntryDTO: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var path: String
    var title: String
    var artist: String
    var duration: Double
    var trackID: String?          // library track id, when the file is in the library
}

struct QueueSnapshot: Codable, Equatable {
    var revision: Int
    var currentID: String?
    var entries: [QueueEntryDTO]
}

struct RemoteStatus: Codable, Equatable {
    var state: String             // idle | loading | playing | paused
    var entryID: String?
    var title: String
    var artist: String
    var album: String
    var position: Double
    var duration: Double
    var codec: String
    var bitDepth: Int
    var sampleRate: Double
    var bitPerfect: Bool
    var pipeline: [String]
    var deviceName: String
    var volume: Double?
    var errors: [String]
    var serverTime: Double        // unix seconds when this was sampled: lets clients interpolate the position
}

struct LibraryChangeSet: Codable, Equatable {
    var revision: Int64           // the server's library revision right now
    var cursor: Int64             // position of the last change in this page: pass it back as "cursor" for the next page
    var changes: [LibraryChange]
    var more: Bool                // fetch again with cursor = this cursor
}

// MARK: - JSON-RPC envelopes

enum RPC {
    static func request(id: Int, method: String, params: Any? = nil) -> Data {
        var o: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { o["params"] = params }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    static func notification(method: String, resultJSON: Data) -> Data {
        var d = Data("{\"jsonrpc\":\"2.0\",\"method\":".utf8)
        d += (try? JSONSerialization.data(withJSONObject: method, options: .fragmentsAllowed)) ?? Data("\"\"".utf8)
        d += Data(",\"params\":".utf8) + (resultJSON.isEmpty ? Data("null".utf8) : resultJSON) + Data("}".utf8)
        return d
    }

    /// `id` is echoed back verbatim (number or string).
    static func response(id: Any, resultJSON: Data) -> Data {
        var d = Data("{\"jsonrpc\":\"2.0\",\"id\":".utf8)
        d += (try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed)) ?? Data("null".utf8)
        d += Data(",\"result\":".utf8) + (resultJSON.isEmpty ? Data("null".utf8) : resultJSON) + Data("}".utf8)
        return d
    }

    static func error(id: Any?, _ e: RemoteError) -> Data {
        let o: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": e.code, "message": e.message]]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }
}

extension JSONEncoder {
    static let remote: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
}

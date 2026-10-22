import Foundation

// The Chromecast sender protocol (CASTV2): length-prefixed protobuf CastMessages carrying JSON, over TLS to port 8009.
// This file is the protocol itself, independent of the network, so it can be tested against a simulated speaker.

enum CastNS {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let media = "urn:x-cast:com.google.cast.media"
    /// The "Default Media Receiver" every Chromecast has: it plays a URL and shows nothing fancy.
    static let defaultMediaReceiver = "CC1AD845"
}

struct CastMessage: Equatable {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] }
    var type: String? { json?["type"] as? String }
}

enum CastCodec {
    // protobuf wire format, just the fields CastMessage uses
    private static func varint(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = [], x = v
        repeat { var b = UInt8(x & 0x7F); x >>= 7; if x != 0 { b |= 0x80 }; out.append(b) } while x != 0
        return out
    }
    private static func string(_ field: Int, _ s: String) -> [UInt8] { let b = Array(s.utf8); return varint(UInt64(field << 3 | 2)) + varint(UInt64(b.count)) + b }

    static func encode(_ m: CastMessage) -> Data {
        var out: [UInt8] = []
        out += varint(UInt64(1 << 3 | 0)) + varint(0)                     // protocol_version = CASTV2_1_0
        out += string(2, m.source) + string(3, m.destination) + string(4, m.namespace)
        out += varint(UInt64(5 << 3 | 0)) + varint(0)                     // payload_type = STRING
        out += string(6, m.payload)
        return Data(out)
    }

    static func frame(_ m: CastMessage) -> Data {
        let body = encode(m), n = UInt32(body.count)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + body
    }

    static func decode(_ d: Data) -> CastMessage? {
        let b = [UInt8](d)
        var i = 0
        func readVarint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 { let x = b[i]; i += 1; v |= UInt64(x & 0x7F) << shift; if x & 0x80 == 0 { return v }; shift += 7 }
            return nil
        }
        var m = CastMessage(source: "", destination: "", namespace: "", payload: "")
        var payloadType: UInt64 = 0
        while i < b.count {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0: guard let v = readVarint() else { return nil }; if field == 5 { payloadType = v }
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { return nil }
                let bytes = Array(b[i..<(i + Int(len))]); i += Int(len)
                let s = String(decoding: bytes, as: UTF8.self)
                switch field { case 2: m.source = s; case 3: m.destination = s; case 4: m.namespace = s; case 6: m.payload = s; default: break }
            case 1: i += 8
            case 5: i += 4
            default: return nil
            }
        }
        return payloadType == 0 ? m : nil                                 // binary payloads are not used by the media receiver
    }

    /// Reassembles messages from a byte stream that delivers them in arbitrary pieces.
    struct Deframer {
        private var buffer = Data()
        private(set) var broken = false
        mutating func push(_ d: Data) -> [CastMessage] {
            guard !broken else { return [] }
            buffer.append(d)
            var out: [CastMessage] = []
            while buffer.count >= 4 {
                let b = buffer.startIndex
                let n = Int(buffer[b]) << 24 | Int(buffer[b + 1]) << 16 | Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
                if n > 1 << 20 { broken = true; buffer = Data(); return out }       // nothing legitimate is that large: the stream is garbage
                guard buffer.count >= 4 + n else { break }
                if let m = decode(buffer.subdata(in: (b + 4)..<(b + 4 + n))) { out.append(m) }
                buffer.removeFirst(4 + n)
            }
            return out
        }
    }
}

protocol CastTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    func send(_ data: Data)
    func close()
}

enum CastState: Equatable {
    case idle, connecting, launching, loading, buffering, playing, paused
    case closed(String)          // ended, with the reason a person would want to read
    case failed(String)

    var isLive: Bool { switch self { case .connecting, .launching, .loading, .buffering, .playing, .paused: true; default: false } }
}

/// Drives one Chromecast: connect, launch the media receiver, load the stream URL, then keep the session alive and report what the speaker does.
/// All methods and callbacks run on `queue`.
final class CastController {
    let queue: DispatchQueue
    private let transport: CastTransport
    private var deframer = CastCodec.Deframer()
    private var requestID = 0
    private(set) var state = CastState.idle { didSet { if state != oldValue { onState?(state) } } }
    var onState: ((CastState) -> Void)?
    var onVolume: ((Double, Bool) -> Void)?
    private(set) var volume = 1.0, muted = false

    private var appID = CastNS.defaultMediaReceiver
    private var media: (url: String, type: String, title: String, artist: String)?
    private var transportID: String?
    private var sessionID: String?
    private var mediaSessionID: Int?
    private var loaded = false
    private var lastHeard = Date()
    private var heartbeat: DispatchSourceTimer?
    var heartbeatInterval = 5.0, silenceLimit = 15.0
    let sender = "sender-aureon"

    init(transport: CastTransport, queue: DispatchQueue = DispatchQueue(label: "aureon.cast")) {
        self.transport = transport; self.queue = queue
        transport.onData = { [weak self] d in self?.queue.async { self?.receive(d) } }
        transport.onClose = { [weak self] e in self?.queue.async { self?.transportClosed(e) } }
    }

    // MARK: control

    func start(streamURL: String, contentType: String, title: String, artist: String, appID: String = CastNS.defaultMediaReceiver) {
        queue.async { [self] in
            guard state == .idle else { return }
            self.appID = appID; media = (streamURL, contentType, title, artist)
            state = .connecting
            send(CastNS.connection, to: "receiver-0", ["type": "CONNECT", "userAgent": "Aureon", "connType": 0])
            send(CastNS.receiver, to: "receiver-0", ["type": "GET_STATUS", "requestId": nextID()])
            send(CastNS.receiver, to: "receiver-0", ["type": "LAUNCH", "appId": appID, "requestId": nextID()])
            state = .launching
            startHeartbeat()
        }
    }

    func setVolume(_ level: Double) {
        queue.async { [self] in send(CastNS.receiver, to: "receiver-0", ["type": "SET_VOLUME", "requestId": nextID(), "volume": ["level": max(0, min(1, level))]]) }
    }
    func setMuted(_ m: Bool) {
        queue.async { [self] in send(CastNS.receiver, to: "receiver-0", ["type": "SET_VOLUME", "requestId": nextID(), "volume": ["muted": m]]) }
    }

    func stop() {
        queue.async { [self] in
            if let s = sessionID { send(CastNS.receiver, to: "receiver-0", ["type": "STOP", "sessionId": s, "requestId": nextID()]) }
            if let t = transportID { send(CastNS.connection, to: t, ["type": "CLOSE"]) }
            send(CastNS.connection, to: "receiver-0", ["type": "CLOSE"])
            heartbeat?.cancel(); heartbeat = nil
            transport.close()
            if state.isLive { state = .closed("Stopped") }
        }
    }

    // MARK: plumbing

    private func nextID() -> Int { requestID += 1; return requestID }

    private func send(_ ns: String, to dest: String, _ body: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: body), let s = String(data: d, encoding: .utf8) else { return }
        transport.send(CastCodec.frame(CastMessage(source: sender, destination: dest, namespace: ns, payload: s)))
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        t.setEventHandler { [weak self] in
            guard let self, self.state.isLive else { return }
            if Date().timeIntervalSince(self.lastHeard) > self.silenceLimit { self.fail("The speaker stopped answering. Check that it is on and on the same network.", closed: true); return }
            self.send(CastNS.heartbeat, to: "receiver-0", ["type": "PING"])
        }
        t.resume(); heartbeat = t
    }

    private func fail(_ why: String, closed: Bool = false) {
        guard state.isLive || state == .idle else { return }
        state = closed ? .closed(why) : .failed(why)
        heartbeat?.cancel(); heartbeat = nil
        transport.close()
    }

    private func transportClosed(_ e: Error?) {
        guard state.isLive else { return }
        fail(e.map { "The connection to the speaker was lost (\($0.localizedDescription))." } ?? "The speaker closed the connection.", closed: true)
    }

    private func receive(_ d: Data) {
        lastHeard = Date()
        let msgs = deframer.push(d)
        if deframer.broken { fail("The speaker sent data that is not part of the Cast protocol."); return }
        for m in msgs { handle(m) }
    }

    private func handle(_ m: CastMessage) {
        guard let type = m.type else { return }
        switch (m.namespace, type) {
        case (CastNS.heartbeat, "PING"): send(CastNS.heartbeat, to: m.source, ["type": "PONG"])
        case (CastNS.heartbeat, _): break
        case (CastNS.connection, "CLOSE"):
            if m.source == transportID || m.source == "receiver-0" { fail("The speaker ended the session.", closed: true) }
        case (CastNS.receiver, "RECEIVER_STATUS"): receiverStatus(m.json?["status"] as? [String: Any] ?? [:])
        case (CastNS.receiver, "LAUNCH_ERROR"): fail("The speaker could not start its media player (\(m.json?["reason"] as? String ?? "unknown reason")).")
        case (CastNS.receiver, "INVALID_REQUEST"): fail("The speaker refused a request (\(m.json?["reason"] as? String ?? "invalid request")).")
        case (CastNS.media, "MEDIA_STATUS"): mediaStatus(m.json?["status"] as? [[String: Any]] ?? [])
        case (CastNS.media, "LOAD_FAILED"): fail("The speaker could not play the stream. Its network may block this Mac, or the firewall asked for permission and was refused.")
        case (CastNS.media, "LOAD_CANCELLED"): fail("The speaker cancelled the stream.")
        case (CastNS.media, "INVALID_REQUEST"), (CastNS.media, "INVALID_PLAYER_STATE"): fail("The speaker refused the stream (\(m.json?["reason"] as? String ?? type)).")
        default: break
        }
    }

    private func receiverStatus(_ status: [String: Any]) {
        if let v = status["volume"] as? [String: Any] {
            volume = (v["level"] as? Double) ?? volume; muted = (v["muted"] as? Bool) ?? muted
            onVolume?(volume, muted)
        }
        let apps = status["applications"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { ($0["appId"] as? String) == appID }) else {
            // our app is gone: someone else started something on the speaker
            if loaded && state.isLive { fail("Another device took over the speaker.", closed: true) }
            return
        }
        guard !loaded, let t = app["transportId"] as? String, let s = app["sessionId"] as? String, let media else { return }
        transportID = t; sessionID = s; loaded = true
        send(CastNS.connection, to: t, ["type": "CONNECT", "userAgent": "Aureon", "connType": 0])
        state = .loading
        send(CastNS.media, to: t, [
            "type": "LOAD", "requestId": nextID(), "sessionId": s, "autoplay": true, "currentTime": 0,
            "media": ["contentId": media.url, "contentType": media.type, "streamType": "LIVE",
                      "metadata": ["metadataType": 3, "title": media.title, "artist": media.artist]],
        ])
    }

    private func mediaStatus(_ list: [[String: Any]]) {
        guard let s = list.first else { return }
        if let id = s["mediaSessionId"] as? Int { mediaSessionID = id }
        switch s["playerState"] as? String {
        case "PLAYING": state = .playing
        case "BUFFERING": state = .buffering
        case "PAUSED": state = .paused
        case "IDLE":
            switch s["idleReason"] as? String {
            case "ERROR": fail("The speaker could not decode the stream.")
            case "FINISHED", "CANCELLED", "INTERRUPTED": fail("The speaker stopped playing.", closed: true)
            default: break
            }
        default: break
        }
    }
}

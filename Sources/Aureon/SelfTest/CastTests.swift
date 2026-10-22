import Foundation
import AVFoundation
import Network
import Security

struct CastTests {
    let dir = tempDir("cast")

    private func signal(_ kind: String, frames: Int, channels: Int, bits: Int, rate: Double) -> [Int32] {
        var x: UInt64 = 99
        var out = [Int32](repeating: 0, count: frames * channels)
        let full = Double((Int64(1) << Int64(bits - 1)) - 1)
        for i in 0..<frames {
            for c in 0..<channels {
                var v: Double
                switch kind {
                case "sine": v = 0.6 * sin(2 * .pi * (440 + 110 * Double(c)) * Double(i) / rate) + 0.2 * sin(2 * .pi * 3001 * Double(i) / rate)
                case "silence": v = 0
                case "dc": v = 0.25
                case "square": v = (i / 50) % 2 == 0 ? 1 : -1
                default: x = x &* 6364136223846793005 &+ 1442695040888963407; v = Double(Int64(x >> 11) % 2_000_001 - 1_000_000) / 1_000_000   // noise
                }
                out[i * channels + c] = Int32(max(-full - 1, min(full, (v * full).rounded()))) << Int32(32 - bits)
            }
        }
        return out
    }

    private func decode(_ stream: Data, name: String) -> [Int32]? {
        let url = dir.appendingPathComponent(name + ".flac")
        try? stream.write(to: url)
        guard let f = try? LosslessFile(path: url.path) else { return nil }
        var out: [Int32] = [], b = [Int32](repeating: 0, count: 4096 * f.info.channels)
        while true { let n = f.read(into: &b, frames: 4096); if n == 0 { break }; out += b[0..<(n * f.info.channels)] }
        return out
    }

    func flacEncoderIsLossless() {
        let configs: [(String, Int, Int, Int, Double)] = [("sine", 44_100, 2, 16, 44_100), ("sine", 96_000, 2, 24, 96_000), ("noise", 48_000, 2, 24, 48_000), ("silence", 44_100, 2, 16, 44_100),
                                                         ("dc", 88_200, 2, 24, 88_200), ("square", 44_100, 1, 16, 44_100), ("sine", 192_000, 2, 24, 192_000), ("noise", 44_100, 2, 16, 44_100), ("sine", 48_000, 6, 24, 48_000)]
        for (kind, rate, ch, bits, r) in configs {
            let frames = 4096 * 3 + 1234                                 // not a whole number of blocks: the flush handles the tail
            let pcm = signal(kind, frames: frames, channels: ch, bits: bits, rate: r)
            let enc = LiveFLACEncoder(sampleRate: rate, channels: ch, bitsPerSample: bits)
            var stream = enc.streamHeader
            // arrive in awkward pieces, as the audio engine delivers them
            var pos = 0
            for piece in [1000, 4096, 777, 5000, 3000, 100000] where pos < frames {
                let n = min(piece, frames - pos)
                pcm.withUnsafeBufferPointer { for f in enc.encode($0.baseAddress! + pos * ch, frames: n) { stream.append(f) } }
                pos += n
            }
            if let tail = enc.flush() { stream.append(tail) }
            guard let got = decode(stream, name: "enc-\(kind)-\(rate)-\(ch)-\(bits)") else { expect(false, "\(kind) \(rate) Hz \(bits)-bit \(ch) ch: CoreAudio cannot read the stream"); continue }
            expect(got == pcm, "\(kind) \(rate) Hz \(bits)-bit \(ch) ch: \(got.count) of \(pcm.count) samples, first difference at \(zip(got, pcm).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)")
            let ratio = Double(stream.count) / Double(frames * ch * bits / 8)
            if kind == "silence" || kind == "dc" { expect(ratio < 0.02, "\(kind) compresses to nothing: \(ratio)") }
            if kind == "sine" && ch == 2 { expect(ratio < 0.75, "a tone shrinks: \(ratio)") }
            if kind == "noise" { expect(ratio < 1.01, "noise is never bigger than raw by more than the framing: \(ratio)") }
        }
    }

    func joiningMidStream() {
        let rate = 48_000, frames = 4096 * 8
        let pcm = signal("sine", frames: frames, channels: 2, bits: 24, rate: 48_000)
        let enc = LiveFLACEncoder(sampleRate: rate, channels: 2, bitsPerSample: 24)
        let all = pcm.withUnsafeBufferPointer { enc.encode($0.baseAddress!, frames: frames) }
        expect(all.count == 8)
        // a client that connects while the 4th frame is being produced gets the header and then frames 4…7
        var stream = enc.streamHeader
        for f in all[4...] { stream.append(f) }
        let got = decode(stream, name: "join")
        expect(got == Array(pcm[(4096 * 4 * 2)...]), "a late joiner decodes the frames it receives: \(got?.count ?? -1)")
    }

    func flacEncoderKeepsUpWithTheEngine() {
        // 24-bit / 96 kHz stereo music-like signal, 20 s: must encode far faster than real time even on a slow Intel Mac
        let rate = 96_000, frames = rate * 20
        let pcm = signal("sine", frames: frames, channels: 2, bits: 24, rate: 96_000)
        let enc = LiveFLACEncoder(sampleRate: rate, channels: 2, bitsPerSample: 24)
        let t0 = Date()
        var bytes = 0
        pcm.withUnsafeBufferPointer { for f in enc.encode($0.baseAddress!, frames: frames) { bytes += f.count } }
        let took = Date().timeIntervalSince(t0)
        expect(took < 20.0 / 15, "20 s of 24/96 stereo took \(took) s: \(20 / took)× real time")
        expect(bytes > 0)
    }
}

// MARK: - a speaker in software

/// The receiver side of CASTV2 as far as the media receiver goes. Feed it messages, get the answers.
final class FakeSpeaker {
    var apps: [[String: Any]] = []
    var volume = 0.4, muted = false
    var log: [CastMessage] = []
    var failLoad = false, idleError = false, launchError = false, ignorePings = false, ignoreEverything = false
    let sessionID = "sess-1", transportID = "web-5"
    private(set) var loaded: [String: Any]?
    var connected: Set<String> = []

    private func reply(_ ns: String, from: String, to: String, _ body: [String: Any]) -> CastMessage {
        CastMessage(source: from, destination: to, namespace: ns, payload: String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!)
    }
    private func status(_ id: Int) -> [String: Any] { ["type": "RECEIVER_STATUS", "requestId": id, "status": ["applications": apps, "volume": ["level": volume, "muted": muted]]] }

    func handle(_ m: CastMessage) -> [CastMessage] {
        log.append(m)
        guard !ignoreEverything, let j = m.json, let t = j["type"] as? String else { return [] }
        let rid = j["requestId"] as? Int ?? 0, me = m.destination, to = m.source
        switch (m.namespace, t) {
        case (CastNS.connection, "CONNECT"): connected.insert(m.destination); return []
        case (CastNS.heartbeat, "PING"): return ignorePings ? [] : [reply(CastNS.heartbeat, from: "receiver-0", to: to, ["type": "PONG"])]
        case (CastNS.receiver, "GET_STATUS"): return [reply(CastNS.receiver, from: "receiver-0", to: to, status(rid))]
        case (CastNS.receiver, "LAUNCH"):
            if launchError { return [reply(CastNS.receiver, from: "receiver-0", to: to, ["type": "LAUNCH_ERROR", "requestId": rid, "reason": "NOT_FOUND"])] }
            apps = [["appId": j["appId"] as? String ?? "", "sessionId": sessionID, "transportId": transportID, "displayName": "Default Media Receiver"]]
            return [reply(CastNS.receiver, from: "receiver-0", to: to, status(rid))]
        case (CastNS.receiver, "SET_VOLUME"):
            if let v = j["volume"] as? [String: Any] { volume = v["level"] as? Double ?? volume; muted = v["muted"] as? Bool ?? muted }
            return [reply(CastNS.receiver, from: "receiver-0", to: to, status(rid))]
        case (CastNS.receiver, "STOP"): apps = []; return [reply(CastNS.receiver, from: "receiver-0", to: to, status(rid))]
        case (CastNS.media, "LOAD"):
            guard connected.contains(me), me == transportID else { return [reply(CastNS.media, from: me, to: to, ["type": "INVALID_REQUEST", "requestId": rid, "reason": "INVALID_COMMAND"])] }
            loaded = j
            if failLoad { return [reply(CastNS.media, from: me, to: to, ["type": "LOAD_FAILED", "requestId": rid])] }
            func ms(_ s: String, _ extra: [String: Any] = [:]) -> CastMessage {
                reply(CastNS.media, from: me, to: to, ["type": "MEDIA_STATUS", "requestId": 0, "status": [["mediaSessionId": 1, "playerState": s].merging(extra) { $1 }]])
            }
            return idleError ? [ms("BUFFERING"), ms("IDLE", ["idleReason": "ERROR"])] : [ms("BUFFERING"), ms("PLAYING")]
        default: return []
        }
    }
    func takenOver() -> CastMessage { apps = []; return reply(CastNS.receiver, from: "receiver-0", to: "*", status(0)) }
    func close(from: String) -> CastMessage { reply(CastNS.connection, from: from, to: "*", ["type": "CLOSE"]) }
    func ping() -> CastMessage { reply(CastNS.heartbeat, from: "receiver-0", to: "*", ["type": "PING"]) }
}

/// A transport wired straight to a FakeSpeaker. `chunk` splits what the speaker says into small pieces, as a real network may.
final class LoopbackTransport: CastTransport {
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    let speaker: FakeSpeaker
    var chunk = Int.max
    private var deframer = CastCodec.Deframer()
    private(set) var closed = false
    private let q = DispatchQueue(label: "loopback")
    init(_ s: FakeSpeaker) { speaker = s }
    func send(_ data: Data) {
        q.async { [self] in
            for m in deframer.push(data) { for r in speaker.handle(m) { deliver(r) } }
        }
    }
    func deliver(_ m: CastMessage) {
        let d = CastCodec.frame(m)
        q.async { [self] in
            var i = 0
            while i < d.count { let n = min(chunk, d.count - i); onData?(d.subdata(in: i..<(i + n))); i += n }
        }
    }
    func deliverRaw(_ d: Data) { q.async { [self] in onData?(d) } }
    func close() { closed = true }
    func drop(_ e: Error? = nil) { q.async { [self] in onClose?(e) } }
}

extension CastTests {
    func castMessagesRoundTrip() {
        let m = CastMessage(source: "a", destination: "b", namespace: "c", payload: "{}")
        expect([UInt8](CastCodec.encode(m)) == [0x08, 0x00, 0x12, 0x01, 0x61, 0x1A, 0x01, 0x62, 0x22, 0x01, 0x63, 0x28, 0x00, 0x32, 0x02, 0x7B, 0x7D], "the bytes are those of the protobuf definition")
        expect([UInt8](CastCodec.frame(m)).prefix(4) == [0, 0, 0, 17])
        let big = CastMessage(source: "sender-aureon", destination: "receiver-0", namespace: CastNS.media, payload: "{\"title\":\"Café — 日本語 \(String(repeating: "x", count: 400))\"}")
        expect(CastCodec.decode(CastCodec.encode(big)) == big, "multi-byte lengths and UTF-8 survive")
        expect(CastCodec.decode(Data([0x12, 0x05, 0x61])) == nil && CastCodec.decode(Data([0xFF])) == nil, "truncated or garbage input is rejected, not trapped")
        var binary = CastCodec.encode(m); binary.replaceSubrange(11..<13, with: Data([0x28, 0x01]))
        expect(CastCodec.decode(binary) == nil, "binary payloads are ignored")

        var d = CastCodec.Deframer()
        let stream = CastCodec.frame(m) + CastCodec.frame(big) + CastCodec.frame(m)
        var got: [CastMessage] = []
        for b in stream { got += d.push(Data([b])) }
        expect(got == [m, big, m], "one byte at a time")
        var d2 = CastCodec.Deframer()
        expect(d2.push(stream) == [m, big, m] && d2.push(Data()) == [], "all at once")
        var d3 = CastCodec.Deframer()
        _ = d3.push(Data([0x7F, 0xFF, 0xFF, 0xFF, 1, 2, 3]))
        expect(d3.broken && d3.push(CastCodec.frame(m)).isEmpty, "an absurd length marks the stream as garbage")
    }

    private func controllerRun(_ speaker: FakeSpeaker, chunk: Int = Int.max, timeout: Double = 3, silence: Double = 15, until: (CastState) -> Bool) -> (states: [CastState], controller: CastController, transport: LoopbackTransport) {
        let t = LoopbackTransport(speaker); t.chunk = chunk
        let c = CastController(transport: t)
        c.silenceLimit = silence; c.heartbeatInterval = 0.05
        let lock = NSLock(); var states: [CastState] = []
        c.onState = { lock.lock(); states.append($0); lock.unlock() }
        c.start(streamURL: "http://192.168.1.20:8123/aureon.flac", contentType: "audio/flac", title: "Aureon", artist: "Test")
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            lock.lock(); let last = states.last; lock.unlock()
            if let last, until(last) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); defer { lock.unlock() }
        return (states, c, t)
    }

    func castSessionStartsAndPlays() {
        let sp = FakeSpeaker()
        for chunk in [Int.max, 1, 7] {
            sp.apps = []; sp.log = []
            let r = controllerRun(sp, chunk: chunk) { $0 == .playing }
            expect(r.states == [.connecting, .launching, .loading, .buffering, .playing], "chunk \(chunk): \(r.states)")
            let types = sp.log.map { "\($0.destination):\($0.json?["type"] as? String ?? "")" }
            expect(types.prefix(3) == ["receiver-0:CONNECT", "receiver-0:GET_STATUS", "receiver-0:LAUNCH"], "\(types)")
            let ci = types.firstIndex(of: "web-5:CONNECT"), li = types.firstIndex(of: "web-5:LOAD")
            expect(ci != nil && li != nil && ci! < li!, "a virtual connection to the app comes before the load: \(types)")
            let load = sp.loaded
            let media = load?["media"] as? [String: Any]
            expect(media?["contentId"] as? String == "http://192.168.1.20:8123/aureon.flac" && media?["contentType"] as? String == "audio/flac" && media?["streamType"] as? String == "LIVE" && load?["sessionId"] as? String == "sess-1" && load?["autoplay"] as? Bool == true, "\(String(describing: load))")
            expect((sp.log.first { $0.json?["type"] as? String == "LAUNCH" }?.json?["appId"] as? String) == CastNS.defaultMediaReceiver)
            r.controller.stop()
            Thread.sleep(forTimeInterval: 0.1)
            expect(sp.apps.isEmpty && r.transport.closed, "stopping ends the speaker's app and closes the connection")
        }
        // volume
        let r = controllerRun(sp) { $0 == .playing }
        var heard: [Double] = []
        r.controller.onVolume = { v, _ in heard.append(v) }
        r.controller.setVolume(0.8)
        Thread.sleep(forTimeInterval: 0.15)
        expect(sp.volume == 0.8 && heard.last == 0.8 && r.controller.volume == 0.8, "volume is set and reported back: \(heard)")
        r.controller.setVolume(7); Thread.sleep(forTimeInterval: 0.1)
        expect(sp.volume == 1, "out-of-range volume is clamped")
        r.controller.setMuted(true); Thread.sleep(forTimeInterval: 0.1)
        expect(sp.muted && r.controller.muted)
        // pings are answered
        r.transport.deliver(sp.ping()); Thread.sleep(forTimeInterval: 0.1)
        expect(sp.log.contains { $0.namespace == CastNS.heartbeat && $0.json?["type"] as? String == "PONG" }, "the speaker's ping gets a pong")
        expect(sp.log.filter { $0.json?["type"] as? String == "PING" }.count >= 2, "and we ping it regularly")
        r.controller.stop()
    }

    func castTroubleIsReportedPlainly() {
        func run(_ configure: (FakeSpeaker) -> Void, silence: Double = 15, timeout: Double = 3, then: ((LoopbackTransport, FakeSpeaker) -> Void)? = nil, until: @escaping (CastState) -> Bool) -> CastState? {
            let sp = FakeSpeaker(); configure(sp)
            let t = LoopbackTransport(sp), c = CastController(transport: t)
            c.silenceLimit = silence; c.heartbeatInterval = 0.05
            let lock = NSLock(); var last: CastState = .idle
            c.onState = { lock.lock(); last = $0; lock.unlock() }
            c.start(streamURL: "http://x/y", contentType: "audio/flac", title: "t", artist: "a")
            if let then { Thread.sleep(forTimeInterval: 0.3); then(t, sp) }
            let t0 = Date()
            while Date().timeIntervalSince(t0) < timeout { lock.lock(); let s = last; lock.unlock(); if until(s) { break }; Thread.sleep(forTimeInterval: 0.01) }
            lock.lock(); defer { lock.unlock() }
            return last
        }
        func isFailed(_ s: CastState) -> Bool { if case .failed = s { return true }; return false }
        func isClosed(_ s: CastState) -> Bool { if case .closed = s { return true }; return false }
        let a = run({ $0.failLoad = true }) { isFailed($0) }
        if case .failed(let m)? = a { expect(m.contains("could not play the stream"), m) } else { expect(false, "a refused load must fail: \(String(describing: a))") }
        let b = run({ $0.launchError = true }) { isFailed($0) }
        if case .failed(let m)? = b { expect(m.contains("media player") && m.contains("NOT_FOUND"), m) } else { expect(false, "launch error: \(String(describing: b))") }
        let c = run({ $0.idleError = true }) { isFailed($0) }
        if case .failed(let m)? = c { expect(m.contains("decode"), m) } else { expect(false, "decode error: \(String(describing: c))") }
        let d = run({ _ in }, then: { t, sp in t.deliver(sp.takenOver()) }) { isClosed($0) }
        if case .closed(let m)? = d { expect(m.contains("Another device"), m) } else { expect(false, "takeover: \(String(describing: d))") }
        let e = run({ _ in }, then: { t, _ in t.drop(URLError(.networkConnectionLost)) }) { isClosed($0) }
        if case .closed(let m)? = e { expect(m.contains("lost"), m) } else { expect(false, "dropped: \(String(describing: e))") }
        let f = run({ _ in }, then: { t, sp in t.deliver(sp.close(from: "web-5")) }) { isClosed($0) }
        if case .closed(let m)? = f { expect(m.contains("ended the session"), m) } else { expect(false, "speaker close: \(String(describing: f))") }
        let g = run({ $0.ignorePings = true }, silence: 0.4, timeout: 3, then: { _, sp in sp.ignoreEverything = true }) { isClosed($0) }
        if case .closed(let m)? = g { expect(m.contains("stopped answering"), m) } else { expect(false, "silence: \(String(describing: g))") }
        let h = run({ _ in }, then: { t, _ in t.deliverRaw(Data([0x7F, 0xFF, 0xFF, 0xFF, 1, 2, 3, 4])) }) { isFailed($0) }
        if case .failed(let m)? = h { expect(m.contains("not part of the Cast protocol"), m) } else { expect(false, "garbage: \(String(describing: h))") }
    }
}

// MARK: - the stream path

final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let lock = NSLock()
    private(set) var data = Data()
    private(set) var response: HTTPURLResponse?
    private(set) var done = false
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) { lock.lock(); response = r as? HTTPURLResponse; lock.unlock(); completionHandler(.allow) }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) { lock.lock(); done = true; lock.unlock() }
    var snapshot: Data { lock.lock(); defer { lock.unlock() }; return data }
    func wait(_ cond: () -> Bool, timeout: Double = 5) -> Bool { let t0 = Date(); while Date().timeIntervalSince(t0) < timeout { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }; return cond() }
}

extension CastTests {
    private func fetch(_ url: String, method: String = "GET") -> (Collector, URLSessionDataTask, URLSession) {
        let c = Collector()
        let s = URLSession(configuration: .ephemeral, delegate: c, delegateQueue: nil)
        var r = URLRequest(url: URL(string: url)!); r.httpMethod = method; r.timeoutInterval = 10
        let t = s.dataTask(with: r); t.resume()
        return (c, t, s)
    }

    func streamServerServesLiveFrames() {
        let enc = LiveFLACEncoder(sampleRate: 48_000, channels: 2, bitsPerSample: 24)
        let hub = LiveStreamHub(header: enc.streamHeader)
        let server = StreamServer(hub: hub)
        let port = try! server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        let pcm = signal("sine", frames: 4096 * 6, channels: 2, bits: 24, rate: 48_000)
        let frames = pcm.withUnsafeBufferPointer { enc.encode($0.baseAddress!, frames: 4096 * 6) }

        let (c1, t1, s1) = fetch(base + "/aureon.flac")
        expect(c1.wait { c1.snapshot.count >= enc.streamHeader.count }, "the header arrives at once")
        expect(c1.response?.statusCode == 200 && c1.response?.value(forHTTPHeaderField: "Content-Type") == "audio/flac" && c1.response?.value(forHTTPHeaderField: "Cache-Control")?.contains("no-cache") == true, "\(String(describing: c1.response))")
        expect(c1.snapshot == enc.streamHeader, "exactly the stream header, nothing before the first frame")
        expect(hub.subscriberCount == 1 && server.clientCount == 1)

        for f in frames[0..<3] { hub.publish(f) }
        // a second listener joins now: it gets the header and then what is published from here on
        let (c2, t2, s2) = fetch(base + "/aureon.flac")
        expect(c2.wait { c2.snapshot.count >= enc.streamHeader.count } && hub.subscriberCount == 2)
        for f in frames[3...] { hub.publish(f) }
        let want1 = enc.streamHeader + frames.reduce(Data()) { $0 + $1 }, want2 = enc.streamHeader + frames[3...].reduce(Data()) { $0 + $1 }
        expect(c1.wait { c1.snapshot.count >= want1.count } && c1.snapshot == want1, "the first listener hears everything: \(c1.snapshot.count) of \(want1.count)")
        expect(c2.wait { c2.snapshot.count >= want2.count } && c2.snapshot == want2, "the second only what came after it joined: \(c2.snapshot.count) of \(want2.count)")
        expect(decode(c1.snapshot, name: "served") == pcm, "and what was served decodes to exactly the PCM that went in")

        t1.cancel(); s1.invalidateAndCancel()
        expect(c1.wait({ hub.subscriberCount == 1 }, timeout: 3), "a listener that goes away is dropped: \(hub.subscriberCount)")
        t2.cancel(); s2.invalidateAndCancel()
        expect(c2.wait({ hub.subscriberCount == 0 && server.clientCount == 0 }, timeout: 3))

        let (c3, _, s3) = fetch(base + "/other.flac")
        expect(c3.wait { c3.done } && c3.response?.statusCode == 404, "unknown paths are refused")
        s3.invalidateAndCancel()
        let (c4, _, s4) = fetch(base + "/aureon.flac", method: "HEAD")
        expect(c4.wait { c4.done } && c4.response?.statusCode == 200 && c4.snapshot.isEmpty && hub.subscriberCount == 0, "HEAD answers without joining the stream")
        s4.invalidateAndCancel()

        // a listener that never reads must not make the server hold audio forever
        hub.maxBacklog = 100_000
        let stuck = hub.subscribe { _ in }
        for _ in 0..<40 { hub.publish(Data(count: 10_000)) }
        expect(hub.framesDropped > 20, "frames are dropped for a stalled listener, not queued without limit: \(hub.framesDropped)")
        hub.unsubscribe(stuck)
    }

    func playerFeedsTheCastStream() {
        // a 44.1 kHz tune cast at 48 kHz, then a 48 kHz file cast as it is: the second must arrive bit for bit
        let tone44 = sineWAV(dir.appendingPathComponent("t44.wav"), rate: 44_100, freq: 1000, amp: 0.3, seconds: 2)
        func ramp(_ i: Int, _ c: Int) -> Int { let v = ((i * 37) % 60_000 - 30_000) * 100; return c == 0 ? v : -v - 1 }
        let exact = dir.appendingPathComponent("exact48.wav")
        _ = writeWAV(exact, rate: 48_000, bits: 24, channels: 2, frames: 48_000 * 2) { f, c in ramp(f, c) }
        var rampSamples: [Int32] = []
        for i in 0..<(48_000 * 2) { rampSamples.append(Int32(ramp(i, 0)) << 8); rampSamples.append(Int32(ramp(i, 1)) << 8) }

        for (file, name) in [(tone44, "resampled"), (exact, "exact")] {
            let out = CastOutput(format: CastFormat(sampleRate: 48_000, bitsPerSample: 24, channels: 2))
            out.lead = 30
            _ = try! out.startStreaming()
            var got = Data()
            let lock = NSLock()
            let sub = out.hub.subscribe { d in lock.lock(); got.append(d); lock.unlock() }
            let sink = CastSink(output: out, name: "Test speaker")
            var o = PlayerOptions(); o.sinkFactory = { _ in sink }
            let p = Player()
            p.setQueue([file.path]); p.start(options: o)
            _ = p.waitUntilFinished(timeout: 15)
            Thread.sleep(forTimeInterval: 0.3)
            out.hub.unsubscribe(sub)
            out.stop()
            lock.lock(); let stream = got; lock.unlock()
            guard let pcm = decode(stream, name: "cast-\(name)") else { expect(false, "\(name): the cast stream cannot be decoded"); continue }
            let info = try! LosslessFile(path: dir.appendingPathComponent("cast-\(name).flac").path).info
            expect(info.sampleRate == 48_000 && info.channels == 2 && info.sourceBits == 24, "\(name): \(info)")
            expect(p.status.errors.isEmpty, "\(name): \(p.status.errors)")
            let lead = pcm.firstIndex { $0 != 0 } ?? 0
            if name == "exact" {
                let want = rampSamples.map { $0 }
                let start = lead - (lead % 2)
                expect(pcm.count >= start + want.count && Array(pcm[start..<(start + want.count)]) == want, "the 48 kHz file arrives untouched (starts at sample \(start / 2))")
            } else {
                let body = Array(pcm[lead...])
                expect(body.count / 2 > 48_000 * 2 - 2_000, "about two seconds of audio: \(body.count / 2) frames")
                let a = amplitude(body, channels: 2, rate: 48_000, freq: 1000, skip: 10_000, count: 40_000)
                expect(abs(a / 0.3 - 1) < 0.03, "the tone is still 1 kHz at the right level after resampling: \(a / 0.3)")
            }
        }
    }
}

// MARK: - real TLS against a software speaker

extension CastTests {
    private func localIdentity() -> sec_identity_t? {
        let d = tempDir("cast-tls")
        func openssl(_ args: [String]) -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            p.waitUntilExit(); return p.terminationStatus == 0
        }
        let key = d.appendingPathComponent("k.pem").path, cert = d.appendingPathComponent("c.pem").path, p12 = d.appendingPathComponent("i.p12").path
        guard openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=aureon-test-speaker", "-days", "2"]),
              openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "pass:pw"]),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p12)) else { return nil }
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: "pw"] as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first, let id = first[kSecImportItemIdentity as String] else { return nil }
        return sec_identity_create(id as! SecIdentity)
    }

    func castOverRealTLS() {
        guard let identity = localIdentity() else { expect(false, "could not create a test certificate with /usr/bin/openssl"); return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let listener = try! NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        let speaker = FakeSpeaker()
        let q = DispatchQueue(label: "fake.speaker")
        final class Conn: @unchecked Sendable { var deframer = CastCodec.Deframer() }
        listener.newConnectionHandler = { c in
            let st = Conn()
            c.start(queue: q)
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { d, _, done, err in
                    if let d { for m in st.deframer.push(d) { for r in speaker.handle(m) { c.send(content: CastCodec.frame(r), completion: .contentProcessed { _ in }) } } }
                    if err == nil && !done { read() }
                }
            }
            read()
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: q)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else { expect(false, "test speaker did not start"); return }
        defer { listener.cancel() }

        let t = TLSCastTransport(endpoint: .hostPort(host: "127.0.0.1", port: port))
        let c = CastController(transport: t)
        let lock = NSLock(); var states: [CastState] = [], host = ""
        c.onState = { lock.lock(); states.append($0); lock.unlock() }
        t.onReady = { h in
            lock.lock(); host = h; lock.unlock()
            c.start(streamURL: "http://\(h):9999/aureon.flac", contentType: "audio/flac", title: "TLS", artist: "Test")
        }
        t.connect()
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 8 { lock.lock(); let done = states.last == .playing; lock.unlock(); if done { break }; Thread.sleep(forTimeInterval: 0.02) }
        lock.lock(); let seen = states, h = host; lock.unlock()
        expect(seen.last == .playing, "a session over TLS to a speaker with an untrusted certificate reaches 'playing': \(seen)")
        expect(h == "127.0.0.1", "the sender knows its own address on that network: \(h)")
        expect(((speaker.loaded?["media"] as? [String: Any])?["contentId"] as? String) == "http://127.0.0.1:9999/aureon.flac")
        c.stop()
    }
}

import Foundation

// Multi-room zones. One processed stream (the engine's output, resampled once to the zone rate) is delivered to every room as its own
// live FLAC stream. Rooms start at different moments and buffer differently, so each room has a sample-exact delay line in front of
// its encoder: audio can be delayed (silence inserted) or advanced (samples dropped) in single-sample steps, and the delays are set so
// that "delay + the room's own latency" is equal everywhere.
//
// What can and cannot be synchronised:
//  • Sonos players in one group are synchronised by Sonos itself; the zone talks to the group's coordinator and joins the others to it.
//  • DLNA/UPnP renderers and Chromecasts just play what they receive. Their latency is measured where the renderer reports its play
//    position (most report whole seconds; the probe finds the second boundaries, which gives roughly ±20 ms) and trimmed by hand below that.
//  • AirPlay 2 receivers can only be driven by macOS itself (its output route); third-party senders cannot join its private sync, so an
//    AirPlay room is chosen with the system route button, not as a zone member.
//  • Clocks of different devices drift apart by tens of ppm; there is no shared clock here to correct that, so re-align on long sessions.

// MARK: - Sample-exact delay

/// A FIFO of interleaved frames whose length is the delay. Changing the delay inserts silence or drops the oldest frames.
struct SampleDelay {
    let channels: Int
    let maxDelayFrames: Int
    private var buf: [Int32]
    private let capacity: Int
    private var head = 0, count = 0
    private(set) var delayFrames = 0
    var target = 0 { didSet { target = min(max(0, target), maxDelayFrames) } }

    init(channels: Int, maxDelayFrames: Int, maxBlockFrames: Int) {
        self.channels = channels; self.maxDelayFrames = maxDelayFrames
        capacity = maxDelayFrames + maxBlockFrames + 1
        buf = [Int32](repeating: 0, count: capacity * channels)
    }

    /// Consumes `n` frames and produces `n` frames, `delayFrames` behind the input.
    mutating func process(_ input: UnsafePointer<Int32>, frames n: Int, output: UnsafeMutablePointer<Int32>) {
        let ch = channels
        if target > delayFrames {
            for _ in 0..<(target - delayFrames) { writeSilence() }
        } else if target < delayFrames {
            let drop = min(delayFrames - target, count)
            head = (head + drop) % capacity; count -= drop
        }
        delayFrames = target
        buf.withUnsafeMutableBufferPointer { b in
            for f in 0..<n where count < capacity {
                let t = (head + count) % capacity
                for c in 0..<ch { b[t * ch + c] = input[f * ch + c] }
                count += 1
            }
            for f in 0..<n {
                if count > 0 {
                    for c in 0..<ch { output[f * ch + c] = b[head * ch + c] }
                    head = (head + 1) % capacity; count -= 1
                } else { for c in 0..<ch { output[f * ch + c] = 0 } }
            }
        }
    }

    private mutating func writeSilence() {
        guard count < capacity else { return }
        let t = (head + count) % capacity
        for c in 0..<channels { buf[t * channels + c] = 0 }
        count += 1
    }
}

// MARK: - Latency measurement and balancing

enum LatencyProbe {
    /// Samples of (seconds fed to the room at that instant, seconds the room reports it has played, whether the report has sub-second resolution).
    /// Returns how far the room's audible position lags behind what was fed to it.
    static func estimate(_ samples: [(emitted: Double, played: Double, exact: Bool)]) -> Double? {
        var lags: [Double] = []
        for (i, s) in samples.enumerated() {
            if s.exact { lags.append(s.emitted - s.played); continue }
            // whole-second report: only the instant it ticks over is informative; it happened between the previous poll and this one
            if i > 0, s.played != samples[i - 1].played { lags.append((samples[i - 1].emitted + s.emitted) / 2 - s.played) }
        }
        guard !lags.isEmpty else { return nil }
        lags.sort()
        return lags[lags.count / 2]
    }
}

enum ZoneBalancer {
    /// Per-room delays (seconds) that make delay + latency equal for every room: the slowest room gets none.
    static func delays(latencies: [String: Double], maxDelay: Double = 2) -> [String: Double] {
        guard let slowest = latencies.values.max() else { return [:] }
        return latencies.mapValues { min(maxDelay, max(0, slowest - $0)) }
    }
}

// MARK: - One room's feed

/// Delay line → FLAC encoder → HTTP server for one room.
final class ZoneFeed: @unchecked Sendable {
    let format: CastFormat
    let hub: LiveStreamHub
    let server: StreamServer
    private let encoder: LiveFLACEncoder
    private var delay: SampleDelay
    private let lock = NSLock()
    private let pushLock = NSLock()           // the encoder is not reentrant: one push at a time
    private let scratch: UnsafeMutablePointer<Int32>
    private let scratchFrames = 8192
    private var _emitted = 0
    /// This room's level (a trim, 0 dB or below). Set from any thread; the push follows it smoothly. At exactly unity the samples are untouched.
    let level: SmoothGain

    static let maxDelaySeconds = 2.0

    init(format: CastFormat, path: String) {
        self.format = format
        level = SmoothGain(rate: Double(format.sampleRate))
        encoder = LiveFLACEncoder(sampleRate: format.sampleRate, channels: format.channels, bitsPerSample: format.bitsPerSample)
        hub = LiveStreamHub(header: encoder.streamHeader)
        server = StreamServer(hub: hub, path: path)
        delay = SampleDelay(channels: format.channels, maxDelayFrames: Int(Self.maxDelaySeconds * Double(format.sampleRate)), maxBlockFrames: scratchFrames)
        scratch = .allocate(capacity: scratchFrames * format.channels)
        scratch.initialize(repeating: 0, count: scratchFrames * format.channels)
    }
    deinit { scratch.deallocate() }

    var delaySeconds: Double {
        get { lock.lock(); defer { lock.unlock() }; return Double(delay.target) / Double(format.sampleRate) }
        set { lock.lock(); delay.target = Int((newValue * Double(format.sampleRate)).rounded()); lock.unlock() }
    }
    var delayFrames: Int { lock.lock(); defer { lock.unlock() }; return delay.target }
    /// Seconds of audio handed to this room so far.
    var emittedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(_emitted) / Double(format.sampleRate) }

    func push(_ pcm: UnsafePointer<Int32>, frames: Int) {
        pushLock.lock(); defer { pushLock.unlock() }
        var done = 0
        while done < frames {
            let n = min(scratchFrames, frames - done)
            lock.lock()
            delay.process(pcm + done * format.channels, frames: n, output: scratch)
            level.apply(scratch, frames: n, channels: format.channels)
            _emitted += n
            lock.unlock()
            for f in encoder.encode(scratch, frames: n) { hub.publish(f) }
            done += n
        }
    }

    func start() throws -> UInt16 { try server.start() }
    func stop() { server.stop() }
}

// MARK: - Endpoints

enum ZoneEndpointKind: String { case dlna = "DLNA", sonos = "Sonos", sonosMember = "Sonos (grouped)", chromecast = "Chromecast" }

protocol ZoneEndpoint: AnyObject, Sendable {
    var id: String { get }
    var name: String { get }
    var kind: ZoneEndpointKind { get }
    /// `streamURL` is given the address of this Mac as the room sees it.
    func start(streamURL: @escaping @Sendable (String?) -> String, title: String) async throws
    func stop() async
    /// How much the room says it has played of the stream, if it says.
    func playedSeconds() async -> (seconds: Double, exact: Bool)?
    func setVolume(_ v: Double) async
}

final class UPnPEndpoint: ZoneEndpoint, @unchecked Sendable {
    let device: UPnPDevice
    private let http: HTTPClient
    /// For a Sonos player joining another one: the coordinator's id. It then plays the coordinator's stream, in sync with it.
    let joins: String?
    var id: String { device.id }
    var name: String { device.name }
    var kind: ZoneEndpointKind { device.isSonos ? (joins == nil ? .sonos : .sonosMember) : .dlna }

    init(device: UPnPDevice, joins: String? = nil, http: HTTPClient = S3HTTP.shared) { self.device = device; self.joins = joins; self.http = http }

    private func av(_ action: String, _ args: [(String, String)] = []) async throws -> [String: String] {
        try await SOAP.call(http, url: device.avTransport, service: UPnPDevice.avTransportType, action: action, [("InstanceID", "0")] + args)
    }

    func start(streamURL: @escaping @Sendable (String?) -> String, title: String) async throws {
        if let c = joins {
            _ = try await av("SetAVTransportURI", [("CurrentURI", "x-rincon:\(c)"), ("CurrentURIMetaData", "")])
            return
        }
        guard let local = LocalNet.address(toward: device.host) else { throw AureonError.message("Could not find this Mac's address on the network of \(device.name).") }
        let url = streamURL(local)
        _ = try await av("SetAVTransportURI", [("CurrentURI", url), ("CurrentURIMetaData", SOAP.didl(title: title, url: url))])
        _ = try await av("Play", [("Speed", "1")])
    }

    func stop() async {
        if joins != nil { _ = try? await av("BecomeCoordinatorOfStandaloneGroup") }
        _ = try? await av("Stop")
    }

    func playedSeconds() async -> (seconds: Double, exact: Bool)? {
        guard joins == nil, let r = try? await av("GetPositionInfo"), let t = r["RelTime"], let p = SOAP.parseTime(t) else { return nil }
        return (p.seconds, p.exact)
    }

    func setVolume(_ v: Double) async {
        guard let rc = device.renderingControl else { return }
        _ = try? await SOAP.call(http, url: rc, service: UPnPDevice.renderingType, action: "SetVolume", [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", "\(Int((max(0, min(1, v)) * 100).rounded()))")])
    }
}

final class ChromecastEndpoint: ZoneEndpoint, @unchecked Sendable {
    let device: CastDevice
    var id: String { device.id }
    var name: String { device.name }
    let kind = ZoneEndpointKind.chromecast
    private var controller: CastController?
    private var transport: TLSCastTransport?

    init(device: CastDevice) { self.device = device }

    func start(streamURL: @escaping @Sendable (String?) -> String, title: String) async throws {
        let t = TLSCastTransport(endpoint: device.endpoint)
        let c = CastController(transport: t)
        transport = t; controller = c
        final class Once: @unchecked Sendable { let lock = NSLock(); var done = false
            func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true } }
        let once = Once()
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            c.onState = { s in
                switch s {
                case .playing, .buffering: if once.take() { k.resume() }
                case .failed(let m), .closed(let m): if once.take() { k.resume(throwing: AureonError.message(m)) }
                default: break
                }
            }
            t.onReady = { host in c.start(streamURL: streamURL(host), contentType: "audio/flac", title: title, artist: "Aureon zone") }
            t.connect()
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if once.take() { k.resume(throwing: AureonError.message("\(self.device.name) did not start playing.")) } }
        }
    }

    func stop() async { controller?.stop(); controller = nil; transport = nil }
    func playedSeconds() async -> (seconds: Double, exact: Bool)? { nil }
    func setVolume(_ v: Double) async { controller?.setVolume(v) }
}

// MARK: - The zone

final class ZoneCoordinator: @unchecked Sendable {
    struct Member { let endpoint: ZoneEndpoint; let feed: ZoneFeed }

    let output: CastOutput
    let format: CastFormat
    private let lock = NSLock()
    private var _members: [Member] = []
    private var counter = 0
    private(set) var running = false

    init(format: CastFormat = CastFormat()) {
        self.format = format
        output = CastOutput(format: format)
        output.title = "Aureon"; output.artist = "Zone"
    }

    var members: [Member] { lock.lock(); defer { lock.unlock() }; return _members }

    @discardableResult
    func add(_ e: ZoneEndpoint, delay: Double = 0) -> Member {
        lock.lock(); counter += 1; let n = counter; lock.unlock()
        let feed = ZoneFeed(format: format, path: "/zone/\(n).flac")
        feed.delaySeconds = delay
        let m = Member(endpoint: e, feed: feed)
        lock.lock(); _members.append(m); lock.unlock()
        return m
    }

    func member(_ id: String) -> Member? { members.first { $0.endpoint.id == id } }

    func remove(_ id: String) async {
        lock.lock(); let m = _members.first { $0.endpoint.id == id }; _members.removeAll { $0.endpoint.id == id }; lock.unlock()
        if let m { await m.endpoint.stop(); m.feed.stop() }
    }

    /// Starts every room. Returns the rooms that could not start (they are removed from the zone).
    func start(title: String = "Aureon") async throws -> [String: String] {
        _ = try output.startStreaming()
        output.onBlock = { [weak self] pcm, n in
            guard let self else { return }
            for m in self.members { m.feed.push(pcm, frames: n) }
        }
        running = true
        var failures: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for m in members {
                group.addTask {
                    do {
                        let port = try m.feed.start()
                        try await m.endpoint.start(streamURL: { host in "http://\(host ?? "127.0.0.1"):\(port)\(m.feed.server.path)" }, title: title)
                        return (m.endpoint.id, nil)
                    } catch { return (m.endpoint.id, error.localizedDescription) }
                }
            }
            for await (id, err) in group { if let err { failures[id] = err } }
        }
        for id in failures.keys { await remove(id) }
        return failures
    }

    func stop() async {
        running = false
        output.onBlock = nil
        for m in members { await m.endpoint.stop(); m.feed.stop() }
        lock.lock(); _members.removeAll(); lock.unlock()
        output.stop()
    }

    func setVolume(_ v: Double) async { for m in members { await m.endpoint.setVolume(v) } }

    /// One room's lag behind what was fed to it, from its reported play position.
    func measureLatency(of m: Member, duration: Double = 4, interval: Double = 0.04) async -> Double? {
        var samples: [(emitted: Double, played: Double, exact: Bool)] = []
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            let e0 = m.feed.emittedSeconds
            if let p = await m.endpoint.playedSeconds() { samples.append(((e0 + m.feed.emittedSeconds) / 2, p.seconds, p.exact)) }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
        }
        return LatencyProbe.estimate(samples)
    }

    /// Measures every room that reports its position and sets delays so they play together. Returns the delays applied (seconds) and what was measured.
    @discardableResult
    func align() async -> (delays: [String: Double], latencies: [String: Double]) {
        var lat: [String: Double] = [:]
        await withTaskGroup(of: (String, Double?).self) { g in
            for m in members { g.addTask { (m.endpoint.id, await self.measureLatency(of: m)) } }
            for await (id, l) in g { if let l { lat[id] = l } }
        }
        let d = ZoneBalancer.delays(latencies: lat, maxDelay: ZoneFeed.maxDelaySeconds)
        for (id, v) in d { member(id)?.feed.delaySeconds = v }
        return (d, lat)
    }
}

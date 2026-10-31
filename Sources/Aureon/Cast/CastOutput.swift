import Foundation
import Network

struct CastDevice: Identifiable, Equatable, @unchecked Sendable {
    var id: String
    var name: String
    var model: String
    var endpoint: NWEndpoint
    var isAudioOnly: Bool { model.lowercased().contains("audio") || model.lowercased().contains("home") || model.lowercased().contains("nest") }
}

/// Finds Chromecasts, Google Home / Nest speakers and Cast-enabled receivers through Bonjour.
final class CastBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    var onChange: (([CastDevice]) -> Void)?
    private let queue = DispatchQueue(label: "aureon.cast.browser")

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var devices: [CastDevice] = []
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                var txt: [String: String] = [:]
                if case .bonjour(let rec) = r.metadata { txt = rec.dictionary }
                devices.append(CastDevice(id: txt["id"] ?? name, name: txt["fn"] ?? name, model: txt["md"] ?? "Chromecast", endpoint: r.endpoint))
            }
            self?.onChange?(devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
        b.start(queue: queue)
        browser = b
    }
    func stop() { browser?.cancel(); browser = nil }
}

/// TLS to a Cast device. Chromecasts present a certificate signed by Google's device CA that no Mac trusts, so the certificate is not
/// validated: the connection is encrypted but the speaker is identified by where Bonjour found it, as every Cast sender does.
final class TLSCastTransport: CastTransport, @unchecked Sendable {
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "aureon.cast.tls")
    private var closed = false
    /// Called once with this Mac's address on the network the speaker is on (what the speaker needs to fetch the stream).
    var onReady: ((String) -> Void)?

    init(endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, queue)
        let tcp = NWProtocolTCP.Options(); tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        connection = NWConnection(to: endpoint, using: params)
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                var host = ""
                if case .hostPort(let h, _)? = self.connection.currentPath?.localEndpoint {
                    switch h { case .ipv4(let a): host = "\(a)"; case .ipv6(let a): host = "[\(a)]"; case .name(let n, _): host = n; @unknown default: break }
                    if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
                }
                self.onReady?(host)
                self.receive()
            case .failed(let e): self.finish(e)
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] d, _, done, err in
            guard let self else { return }
            if let d, !d.isEmpty { self.onData?(d) }
            if err != nil || done { self.finish(err); return }
            self.receive()
        }
    }

    private func finish(_ e: Error?) {
        guard !closed else { return }
        closed = true; onClose?(e)
    }

    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { [weak self] e in if e != nil { self?.finish(e) } }) }
    func close() { connection.cancel() }
}

struct CastFormat: Equatable {
    var sampleRate = 48_000
    var bitsPerSample = 24
    var channels = 2
    var description: String { "FLAC \(bitsPerSample)-bit / \(sampleRate % 1000 == 0 ? "\(sampleRate / 1000)" : String(format: "%.1f", Double(sampleRate) / 1000)) kHz" }
}

/// One casting session: the encoder, the stream server, the speaker connection, and the pacing thread that feeds them from the player.
///
/// The pacing thread never stops while the session is open. It takes audio from the player's renderer when a sink is attached and sends
/// silence otherwise (between tracks, while paused, before the first play), so the speaker always has a stream to read and never has to be
/// reloaded.
final class CastOutput: @unchecked Sendable {
    let format: CastFormat
    let hub: LiveStreamHub
    let server: StreamServer
    private let encoder: LiveFLACEncoder
    private let lock = NSLock()
    private var renderer: Renderer?
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let exited = DispatchSemaphore(value: 0)
    /// How far ahead of real time the stream is fed: the speaker's own buffer plus network jitter.
    var lead = 1.5
    private(set) var controller: CastController?
    private var transport: TLSCastTransport?
    var onState: ((CastState) -> Void)?
    var onVolume: ((Double, Bool) -> Void)?
    var title = "Aureon", artist = "Processed output"
    /// Every paced block of interleaved PCM (format.channels wide), on the pacing thread: how a multi-room zone gets its own copy per speaker.
    var onBlock: ((UnsafePointer<Int32>, Int) -> Void)?

    init(format: CastFormat = CastFormat()) {
        self.format = format
        encoder = LiveFLACEncoder(sampleRate: format.sampleRate, channels: format.channels, bitsPerSample: format.bitsPerSample)
        hub = LiveStreamHub(header: encoder.streamHeader)
        server = StreamServer(hub: hub)
    }

    deinit { stop() }

    // MARK: session

    /// Starts the server and the pacing thread (no speaker yet: tests and the "listen in a browser" case use this alone).
    @discardableResult
    func startStreaming() throws -> UInt16 {
        let port = try server.start()
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return port }
        let t = Thread { [weak self] in self?.pace() }
        t.name = "aureon.cast.pace"; t.qualityOfService = .userInitiated
        t.start(); thread = t
        return port
    }

    func connect(to device: CastDevice) {
        do { _ = try startStreaming() } catch { onState?(.failed("The stream server could not start: \(error.localizedDescription)")); return }
        let t = TLSCastTransport(endpoint: device.endpoint)
        let c = CastController(transport: t)
        c.onState = { [weak self] s in self?.onState?(s) }
        c.onVolume = { [weak self] v, m in self?.onVolume?(v, m) }
        transport = t; controller = c
        let port = server.port
        let title = self.title, artist = self.artist
        t.onReady = { [weak self, weak c] host in
            guard let self, let c else { return }
            self.onState?(.connecting)
            c.start(streamURL: "http://\(host):\(port)\(self.server.path)", contentType: self.server.contentType, title: title, artist: artist)
        }
        t.connect()
    }

    func attach(_ r: Renderer?) { lock.lock(); renderer = r; lock.unlock() }

    func stop() {
        controller?.stop(); controller = nil; transport = nil
        if running.exchange(false, ordering: .acquiringAndReleasing) { exited.wait() }
        server.stop()
        thread = nil
    }

    // MARK: pacing

    private func pace() {
        let block = 1024, ch = format.channels, rate = Double(format.sampleRate)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: block * 8), out = UnsafeMutablePointer<Int32>.allocate(capacity: block * ch)
        defer { buf.deallocate(); out.deallocate(); exited.signal() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var produced = 0.0
        while running.load(ordering: .acquiring) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            if produced < (elapsed - 2) * rate { produced = elapsed * rate }       // the Mac slept or stalled: resume in real time instead of bursting
            guard produced < (elapsed + lead) * rate else { usleep(2_000); continue }
            lock.lock()
            if let r = renderer, r.channels >= 1, r.channels <= 8 {
                let n = r.render(into: buf, frames: block)
                let rc = r.channels
                for i in 0..<block {
                    for c in 0..<ch {
                        out[i * ch + c] = i < n ? buf[i * rc + (rc == 1 ? 0 : min(c, rc - 1))] : 0
                    }
                }
            } else {
                out.update(repeating: 0, count: block * ch)
            }
            lock.unlock()
            onBlock?(out, block)
            for f in encoder.encode(out, frames: block) { hub.publish(f) }
            produced += Double(block)
        }
    }
}

/// The sink that sends the player's processed output (after DSP, resampling and volume) to a `CastOutput`.
final class CastSink: AudioSink, @unchecked Sendable {
    let output: CastOutput
    let deviceName: String
    var supportedRates: [Double] { [Double(output.format.sampleRate)] }
    var fixedRate: Double? { Double(output.format.sampleRate) }
    var outputChannels: Int { output.format.channels }
    var speakers: [Speaker?]? { [.fl, .fr] }

    init(output: CastOutput, name: String) { self.output = output; deviceName = name }

    func configure(for info: StreamInfo, options: PlayerOptions) -> SinkReport {
        var lines = ["Casting to \(deviceName) as \(output.format.description) (lossless, encoded on the fly)"]
        let exact = Int(info.sampleRate) == output.format.sampleRate
        if !exact { lines.append("Sample rate \(formatRate(info.sampleRate)) → \(formatRate(Double(output.format.sampleRate))): the speaker is sent one fixed rate") }
        return SinkReport(lines: lines, bitPerfect: false)
    }
    func start(renderer: Renderer) throws { output.attach(renderer) }
    func stop() { output.attach(nil) }
    func shutdown() { output.attach(nil) }
}

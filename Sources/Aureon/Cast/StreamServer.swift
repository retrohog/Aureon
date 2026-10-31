import Foundation
import Network

/// Fan-out of a live byte stream: every subscriber gets the stream header first and then each frame as it is published.
final class LiveStreamHub: @unchecked Sendable {
    final class Subscriber: @unchecked Sendable {
        fileprivate let deliver: @Sendable (Data) -> Void
        fileprivate let id = UUID()
        /// Bytes handed over but not yet confirmed sent; a client that falls too far behind loses frames instead of memory.
        let backlog = Atomic<Int>(0)
        init(deliver: @escaping @Sendable (Data) -> Void) { self.deliver = deliver }
    }
    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]
    private(set) var header: Data
    private(set) var framesPublished = 0, framesDropped = 0
    var maxBacklog = 8 << 20

    init(header: Data) { self.header = header }

    var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return subscribers.count }

    func setHeader(_ h: Data) { lock.lock(); header = h; lock.unlock() }

    func subscribe(_ deliver: @escaping @Sendable (Data) -> Void) -> Subscriber {
        let s = Subscriber(deliver: deliver)
        lock.lock(); subscribers[s.id] = s; let h = header; lock.unlock()
        _ = s.backlog.add(h.count, ordering: .relaxed); deliver(h)
        return s
    }
    func unsubscribe(_ s: Subscriber) { lock.lock(); subscribers[s.id] = nil; lock.unlock() }
    func sent(_ s: Subscriber, bytes: Int) { _ = s.backlog.add(-bytes, ordering: .relaxed) }

    func publish(_ frame: Data) {
        lock.lock(); let subs = Array(subscribers.values); framesPublished += 1; lock.unlock()
        for s in subs {
            if s.backlog.load(ordering: .relaxed) > maxBacklog { lock.lock(); framesDropped += 1; lock.unlock(); continue }
            _ = s.backlog.add(frame.count, ordering: .relaxed)
            s.deliver(frame)
        }
    }
}

/// A small HTTP server that hands the live stream to whatever asks for it (a Chromecast, a browser, VLC …).
final class StreamServer: @unchecked Sendable {
    let hub: LiveStreamHub
    let path: String
    let contentType: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "aureon.streamserver")
    private let lock = NSLock()
    private var clients = 0
    private(set) var port: UInt16 = 0
    private(set) var requests = 0

    init(hub: LiveStreamHub, path: String = "/aureon.flac", contentType: String = "audio/flac") { self.hub = hub; self.path = path; self.contentType = contentType }

    var clientCount: Int { lock.lock(); defer { lock.unlock() }; return clients }

    /// Starts listening on a free port and returns it.
    func start() throws -> UInt16 {
        let l = try NWListener(using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { st in
            switch st { case .ready: ready.signal(); case .failed(let e): failure = e; ready.signal(); default: break }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, failure == nil, let p = l.port?.rawValue else { l.cancel(); throw failure ?? AureonError.message("the stream server did not start") }
        listener = l; port = p
        return p
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        var buf = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
                guard let self else { c.cancel(); return }
                if let data { buf.append(data) }
                if let end = buf.range(of: Data("\r\n\r\n".utf8)) { self.respond(c, request: String(decoding: buf[..<end.lowerBound], as: UTF8.self)); return }
                if err != nil || done || buf.count > 16_384 { c.cancel(); return }
                read()
            }
        }
        read()
    }

    private func respond(_ c: NWConnection, request: String) {
        lock.lock(); requests += 1; lock.unlock()
        let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2, ["GET", "HEAD"].contains(parts[0]), parts[1].split(separator: "?").first.map(String.init) == path else {
            c.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache, no-store\r\nAccept-Ranges: none\r\nConnection: close\r\nicy-name: Aureon\r\naccess-control-allow-origin: *\r\n\r\n"
        if parts[0] == "HEAD" {
            c.send(content: Data(head.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return
        }
        lock.lock(); clients += 1; lock.unlock()
        let hub = self.hub
        var sub: LiveStreamHub.Subscriber?
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let s = hub.subscribe { [weak hub] data in
            c.send(content: data, completion: .contentProcessed { err in
                if let sub { hub?.sent(sub, bytes: data.count) }
                if err != nil { c.cancel() }
            })
        }
        sub = s
        c.stateUpdateHandler = { [weak self, weak hub] st in
            switch st {
            case .cancelled, .failed:
                hub?.unsubscribe(s)
                if let self { self.lock.lock(); self.clients = max(0, self.clients - 1); self.lock.unlock() }
                c.stateUpdateHandler = nil
            default: break
            }
        }
        // a client that closes its side ends the stream for it
        c.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, done, err in if done || err != nil { c.cancel() } }
    }
}

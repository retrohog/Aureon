import Foundation
#if canImport(Darwin)
import Darwin
#endif

// One poll() loop owns every socket (the server link, peers, file links, the listener). Handlers run on that thread and must not block: anything slow
// (disk, decoding a large result) is handed to another queue by the caller. Nothing here is called from, or calls into, the audio engine.

public final class SlskLink: @unchecked Sendable {
    public let id: Int
    public var label: String
    fileprivate var fd: Int32
    fileprivate var out = Data()
    fileprivate var connecting: Bool
    fileprivate var deadline: Date?
    fileprivate var lastActivity = Date()
    fileprivate var closeAfterFlush = false
    fileprivate unowned let loop: SlskLoop
    /// Set by the owner of a link that must stay open while idle (the server link).
    public var keepOpen = false
    /// While true, nothing is read from the socket (the receiver is behind).
    public var readPaused = false
    public var onConnect: (() -> Void)?
    public var onData: ((Data) -> Void)?
    public var onClose: ((String?) -> Void)?
    public fileprivate(set) var bytesIn: UInt64 = 0
    public fileprivate(set) var bytesOut: UInt64 = 0
    public fileprivate(set) var isOpen = true

    fileprivate init(id: Int, fd: Int32, label: String, connecting: Bool, loop: SlskLoop) {
        self.id = id; self.fd = fd; self.label = label; self.connecting = connecting; self.loop = loop
    }

    public func send(_ d: Data) { loop.queue(self, d) }
    public func send(_ f: SlskFrame) { loop.queue(self, f.encoded()) }
    /// Sends what is queued, then closes.
    public func closeWhenFlushed() { loop.flushThenClose(self) }
    public func close() { loop.requestClose(self, reason: nil) }
    public var queuedBytes: Int { loop.queued(self) }
}

public final class SlskLoop: @unchecked Sendable {
    public let maxLinks: Int
    public var idleTimeout: TimeInterval = 60
    private let lock = NSLock()
    private var links: [Int: SlskLink] = [:]
    private var listeners: [Int32: (SlskLink) -> Void] = [:]
    private var nextID = 1
    private var wake: (Int32, Int32) = (-1, -1)
    private var thread: Thread?
    private var running = false
    private var closing: [(SlskLink, String?)] = []

    public init(maxLinks: Int = 120) { self.maxLinks = maxLinks }

    public var liveLinks: Int { lock.lock(); defer { lock.unlock() }; return links.count }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        wake = (fds[0], fds[1])
        for f in fds { _ = fcntl(f, F_SETFL, fcntl(f, F_GETFL) | O_NONBLOCK) }
        running = true
        let t = Thread { [weak self] in self?.run() }
        t.name = "Soulseek network"; t.qualityOfService = .utility; thread = t; t.start()
    }

    public func stop() {
        lock.lock(); running = false; let all = Array(links.values); lock.unlock()
        poke()
        for l in all { requestClose(l, reason: nil) }
    }

    private func poke() { var b: UInt8 = 1; _ = write(wake.1, &b, 1) }

    // MARK: opening

    /// Starts a connection; `onConnect` or `onClose` follows on the loop thread. Returns nil when the link limit is reached.
    public func connect(host: String, port: UInt16, label: String, timeout: TimeInterval = 10) -> SlskLink? {
        lock.lock()
        if links.count >= maxLinks { lock.unlock(); return nil }
        lock.unlock()
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        // numeric hosts resolve instantly; names block briefly, so callers open links off the main thread
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let r = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if r != 0 && errno != EINPROGRESS { Darwin.close(fd); return nil }
        lock.lock()
        let l = SlskLink(id: nextID, fd: fd, label: label, connecting: true, loop: self); nextID += 1
        l.deadline = Date().addingTimeInterval(timeout)
        links[l.id] = l; lock.unlock()
        poke(); return l
    }

    /// Listens on `port` (0 picks a free one) on all interfaces; accepted links are handed to `onAccept` on the loop thread. Returns the port.
    public func listen(port: UInt16 = 0, loopbackOnly: Bool = false, onAccept: @escaping (SlskLink) -> Void) -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
        a.sin_addr.s_addr = (loopbackOnly ? INADDR_LOOPBACK : INADDR_ANY).bigEndian
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0, Darwin.listen(fd, 32) == 0 else { Darwin.close(fd); return nil }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        lock.lock(); listeners[fd] = onAccept; lock.unlock(); poke()
        return UInt16(bigEndian: bound.sin_port)
    }

    public func stopListening() {
        lock.lock(); let fds = Array(listeners.keys); listeners.removeAll(); lock.unlock()
        for f in fds { Darwin.close(f) }
        poke()
    }

    // MARK: sending and closing

    fileprivate func queue(_ l: SlskLink, _ d: Data) { lock.lock(); if l.isOpen { l.out.append(d) }; lock.unlock(); poke() }
    fileprivate func queued(_ l: SlskLink) -> Int { lock.lock(); defer { lock.unlock() }; return l.out.count }
    fileprivate func flushThenClose(_ l: SlskLink) { lock.lock(); l.closeAfterFlush = true; lock.unlock(); poke() }
    fileprivate func requestClose(_ l: SlskLink, reason: String?) { lock.lock(); closing.append((l, reason)); lock.unlock(); poke() }

    // MARK: the loop

    private func run() {
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            lock.lock()
            if !running { lock.unlock(); break }
            var fds: [pollfd] = [pollfd(fd: wake.0, events: Int16(POLLIN), revents: 0)]
            var owners: [SlskLink?] = [nil]
            var lfds: [Int32] = []
            for (fd, _) in listeners { fds.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0)); owners.append(nil); lfds.append(fd) }
            for l in links.values where l.isOpen {
                var ev: Int16 = 0
                if l.connecting { ev = Int16(POLLOUT) } else {
                    if !l.readPaused { ev |= Int16(POLLIN) }
                    if !l.out.isEmpty { ev |= Int16(POLLOUT) }
                }
                fds.append(pollfd(fd: l.fd, events: ev, revents: 0)); owners.append(l)
            }
            let pending = closing; closing.removeAll()
            lock.unlock()
            for (l, why) in pending { finish(l, why) }

            _ = poll(&fds, nfds_t(fds.count), 500)

            // wake pipe
            if fds[0].revents & Int16(POLLIN) != 0 { var b = [UInt8](repeating: 0, count: 64); while read(wake.0, &b, 64) > 0 {} }
            for (i, p) in fds.enumerated() where i > 0 {
                guard p.revents != 0 else { continue }
                if let l = owners[i] { service(l, p.revents, &scratch) }
                else { accept(p.fd) }
            }
            sweep()
        }
        lock.lock(); let rest = Array(links.values); let lf = Array(listeners.keys); listeners.removeAll(); lock.unlock()
        for l in rest { finish(l, nil) }
        for f in lf { Darwin.close(f) }
        Darwin.close(wake.0); Darwin.close(wake.1)
        lock.lock(); thread = nil; lock.unlock()
    }

    private func accept(_ lfd: Int32) {
        while true {
            var addr = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(lfd, $0, &len) } }
            if fd < 0 { break }
            lock.lock()
            let full = links.count >= maxLinks, cb = listeners[lfd]
            lock.unlock()
            if full || cb == nil { Darwin.close(fd); continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock(); let l = SlskLink(id: nextID, fd: fd, label: "incoming", connecting: false, loop: self); nextID += 1; links[l.id] = l; lock.unlock()
            cb?(l)
        }
    }

    private func service(_ l: SlskLink, _ rev: Int16, _ scratch: inout [UInt8]) {
        if l.connecting {
            if rev & Int16(POLLOUT | POLLERR | POLLHUP) != 0 {
                var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(l.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                if err != 0 { finish(l, String(cString: strerror(err))); return }
                lock.lock(); l.connecting = false; l.deadline = nil; l.lastActivity = Date(); lock.unlock()
                l.onConnect?()
            }
            return
        }
        if rev & Int16(POLLIN | POLLHUP) != 0 && !l.readPaused {
            let n = scratch.withUnsafeMutableBytes { read(l.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                l.lastActivity = Date(); l.bytesIn += UInt64(n)
                l.onData?(Data(scratch[0..<n]))
            } else if n == 0 { finish(l, nil); return }
            else if errno != EAGAIN && errno != EINTR { finish(l, String(cString: strerror(errno))); return }
        }
        if rev & Int16(POLLERR) != 0 { finish(l, "connection error"); return }
        if rev & Int16(POLLOUT) != 0 { flush(l) }
    }

    private func flush(_ l: SlskLink) {
        lock.lock()
        while !l.out.isEmpty {
            let n = l.out.withUnsafeBytes { write(l.fd, $0.baseAddress, min($0.count, 256 * 1024)) }
            if n > 0 { l.out.removeFirst(n); l.bytesOut += UInt64(n); l.lastActivity = Date() }
            else if n < 0 && (errno == EAGAIN || errno == EINTR) { break }
            else { lock.unlock(); finish(l, String(cString: strerror(errno))); return }
        }
        let done = l.out.isEmpty && l.closeAfterFlush
        lock.unlock()
        if done { finish(l, nil) }
    }

    private func sweep() {
        let now = Date()
        lock.lock(); let all = Array(links.values); lock.unlock()
        for l in all where l.isOpen {
            if l.connecting, let d = l.deadline, now > d { finish(l, "timed out") }
            else if !l.connecting, !l.keepOpen, now.timeIntervalSince(l.lastActivity) > idleTimeout { finish(l, "idle") }
            else if !l.connecting, l.closeAfterFlush, queued(l) == 0 { finish(l, nil) }
        }
    }

    private func finish(_ l: SlskLink, _ reason: String?) {
        lock.lock()
        guard l.isOpen else { lock.unlock(); return }
        l.isOpen = false; links[l.id] = nil; let fd = l.fd; l.fd = -1; lock.unlock()
        Darwin.close(fd)
        l.onClose?(reason)
        l.onData = nil; l.onConnect = nil; l.onClose = nil
    }
}

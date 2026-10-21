import Foundation
import Network

/// A small HTTP/1.x client on Network.framework.
///
/// Why not URLSession: App Transport Security refuses plain `http://` there, and most internet radio streams, podcast media and station
/// logos are `http://`. A music player has to open them. This client speaks HTTP and HTTPS directly (TLS is validated as usual), follows
/// redirects, decodes chunked bodies and understands the SHOUTcast "ICY 200 OK" status line.
final class HTTPStreamer: @unchecked Sendable {
    struct Response { var status: Int; var headers: [String: String]; var url: URL }

    enum Failure: Error, LocalizedError {
        case badURL, tooManyRedirects, connection(String), malformed, timeout
        var errorDescription: String? {
            switch self {
            case .badURL: "unsupported URL"; case .tooManyRedirects: "too many redirects"; case .connection(let m): m
            case .malformed: "malformed HTTP response"; case .timeout: "the server did not answer"
            }
        }
    }

    private let queue = DispatchQueue(label: "aureon.http")
    private var url: URL
    private let extraHeaders: [String: String]
    private var connection: NWConnection?
    private var redirects = 0
    private var buffer = Data()
    private var headerDone = false
    private var chunked = false
    private var chunkRemaining = -1          // -1: expecting a size line
    private var finished = false
    private var gen = 0                       // identifies the current connection; callbacks of older ones are ignored
    private var onResponse: ((Response) -> Void)?
    private var onBody: ((Data) -> Void)?
    private var onClose: ((Error?) -> Void)?
    private var timer: DispatchSourceTimer?
    var userAgent = "Aureon/0.3 (+https://github.com/aureon-player/aureon)"
    var connectTimeout: TimeInterval = 12

    init(url: URL, headers: [String: String] = [:]) { self.url = url; self.extraHeaders = headers }

    /// Starts the request. `onBody` gets raw body bytes as they arrive (chunk framing removed); `onClose` fires exactly once.
    func start(onResponse: @escaping (Response) -> Void, onBody: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) {
        self.onResponse = onResponse; self.onBody = onBody; self.onClose = onClose
        queue.async { self.connect() }
    }

    func cancel() { queue.async { self.finish(nil) } }

    // MARK: connection

    private func connect() {
        guard !finished else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host else { finish(Failure.badURL); return }
        let tls = scheme == "https"
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (tls ? 443 : 80))) ?? (tls ? 443 : 80)
        buffer = Data(); headerDone = false; chunked = false; chunkRemaining = -1
        gen += 1
        let mine = gen
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: tls ? .tls : .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self, self.gen == mine, !self.finished else { return }
            switch st {
            case .ready: self.sendRequest(c, host: host, port: url.port); self.receive(c, mine)
            case .failed(let e): self.finish(Failure.connection(e.localizedDescription))
            case .waiting(let e): if case .posix(let code) = e, code == .ECONNREFUSED || code == .ENETUNREACH || code == .EHOSTUNREACH { self.finish(Failure.connection(e.localizedDescription)) }
            default: break
            }
        }
        c.start(queue: queue)
        armTimer(connectTimeout)
    }

    private func armTimer(_ s: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + s)
        t.setEventHandler { [weak self] in if let self, !self.headerDone { self.finish(Failure.timeout) } }
        t.resume(); timer = t
    }

    private func sendRequest(_ c: NWConnection, host: String, port: Int?) {
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        var head = "GET \(path) HTTP/1.1\r\nHost: \(host)\(port.map { ":\($0)" } ?? "")\r\nUser-Agent: \(userAgent)\r\nAccept: */*\r\nConnection: close\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] e in if let e { self?.queue.async { self?.finish(Failure.connection(e.localizedDescription)) } } })
    }

    private func receive(_ c: NWConnection, _ mine: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.gen == mine, !self.finished else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if self.finished || self.gen != mine { return }
            if let error { self.finish(self.headerDone ? nil : Failure.connection(error.localizedDescription)); return }
            if complete { self.finish(self.headerDone ? nil : Failure.malformed); return }
            self.receive(c, mine)
        }
    }

    // MARK: parsing

    private func consume(_ data: Data) {
        if headerDone { body(data); return }
        buffer.append(data)
        guard let r = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 * 1024 { finish(Failure.malformed) }
            return
        }
        let head = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
        let rest = buffer[r.upperBound...]
        buffer = Data()
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst()
        let parts = status.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") || parts[0] == "ICY", let code = Int(parts[1]) else { finish(Failure.malformed); return }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }

        if [301, 302, 303, 307, 308].contains(code), let loc = headers["location"], let next = URL(string: loc, relativeTo: url)?.absoluteURL {
            redirects += 1
            if redirects > 6 { finish(Failure.tooManyRedirects); return }
            connection?.cancel(); gen += 1
            url = next
            connect()
            return
        }
        headerDone = true; timer?.cancel()
        chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        onResponse?(Response(status: code, headers: headers, url: url))
        if !rest.isEmpty { body(Data(rest)) }
    }

    private func body(_ data: Data) {
        guard chunked else { onBody?(data); return }
        buffer.append(data)
        while !buffer.isEmpty {
            if chunkRemaining < 0 {
                guard let r = buffer.range(of: Data("\r\n".utf8)) else { return }
                let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                guard let n = Int(line.trimmingCharacters(in: .whitespaces), radix: 16) else { finish(Failure.malformed); return }
                if n == 0 { finish(nil); return }
                chunkRemaining = n
            }
            let take = min(chunkRemaining, buffer.count)
            if take > 0 { onBody?(Data(buffer.prefix(take))); buffer.removeFirst(take); chunkRemaining -= take }
            if chunkRemaining == 0 {
                guard buffer.count >= 2 else { return }
                buffer.removeFirst(2); chunkRemaining = -1
            } else { return }
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); connection?.cancel()
        let cb = onClose
        onResponse = nil; onBody = nil; onClose = nil
        cb?(error)
    }
}

/// `HTTPClient` over `HTTPStreamer`: GET only, bodies up to 32 MB, with an overall timeout.
struct NetHTTPClient: HTTPClient {
    var timeout: TimeInterval = 25
    var maxBytes = 32 << 20

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url else { throw HTTPStreamer.Failure.badURL }
        var headers = request.allHTTPHeaderFields ?? [:]
        let ua = headers.removeValue(forKey: "User-Agent")
        return try await withCheckedThrowingContinuation { cont in
            let s = HTTPStreamer(url: url, headers: headers)
            if let ua { s.userAgent = ua }
            let box = FetchState()
            box.lock.lock(); box.streamer = s; box.lock.unlock()
            let done: (Result<(Data, Int), Error>) -> Void = { r in
                box.lock.lock(); let first = !box.resumed; box.resumed = true; box.lock.unlock()
                if first { s.cancel(); cont.resume(with: r) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { done(.failure(HTTPStreamer.Failure.timeout)) }
            s.start(onResponse: { box.lock.lock(); box.status = $0.status; box.lock.unlock() },
                    onBody: { d in
                        box.lock.lock(); box.data.append(d); let big = box.data.count > maxBytes; box.lock.unlock()
                        if big { done(.failure(HTTPStreamer.Failure.malformed)) }
                    },
                    onClose: { e in
                        box.lock.lock(); let (d, st) = (box.data, box.status); box.lock.unlock()
                        if let e, st == 0 { done(.failure(e)) } else { done(.success((d, st))) }
                    })
        }
    }

    private final class FetchState: @unchecked Sendable {
        let lock = NSLock(); var data = Data(); var status = 0; var resumed = false; var streamer: HTTPStreamer?
    }
}

import Foundation

// Client for the Aureon remote protocol. Foundation-only (URLSessionWebSocketTask), so it compiles unchanged for iOS / iPadOS.

struct RemoteEvent { var name: String; var params: Data }

/// A local mirror of the server's library, kept current by applying change sets (upserts and deletions by uid).
final class LibraryMirror {
    private(set) var tracks: [String: TrackDTO] = [:]
    private(set) var parties: [String: PartyDTO] = [:]
    private(set) var works: [String: WorkDTO] = [:]
    private(set) var releases: [String: ReleaseDTO] = [:]
    private(set) var revision: Int64 = 0       // server revision at the last completed sync
    private(set) var cursor: Int64 = 0         // position in the server's change log

    func apply(_ set: LibraryChangeSet) {
        for c in set.changes {
            switch (c.kind, c.op) {
            case ("track", "upsert"): if let t = c.track { tracks[c.uid] = t }
            case ("track", "delete"): tracks[c.uid] = nil
            case ("party", "upsert"): if let p = c.party { parties[c.uid] = p }
            case ("party", "delete"): parties[c.uid] = nil
            case ("work", "upsert"): if let w = c.work { works[c.uid] = w }
            case ("work", "delete"): works[c.uid] = nil
            case ("release", "upsert"): if let r = c.release { releases[c.uid] = r }
            case ("release", "delete"): releases[c.uid] = nil
            default: break
            }
        }
        cursor = max(cursor, set.cursor)
        if !set.more { revision = set.revision }
    }
}

final class RemoteClient: @unchecked Sendable {
    private let url: URL, token: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var helloWaiter: CheckedContinuation<String, Error>?
    private var helloNonce: String?
    private var continuation: AsyncStream<RemoteEvent>.Continuation?
    let events: AsyncStream<RemoteEvent>
    private(set) var serverName = ""
    var isConnected: Bool { task?.state == .running }

    init(url: URL, token: String) {
        self.url = url; self.token = token; session = URLSession(configuration: .ephemeral)
        var c: AsyncStream<RemoteEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    /// Opens the socket, answers the server's challenge and returns once authenticated.
    func connect(timeout: TimeInterval = 5) async throws {
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        Task { await readLoop(t) }
        let nonce: String = try await withThrowingTaskGroup(of: String.self) { g in
            g.addTask { try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                self.lock.lock()
                if let n = self.helloNonce { self.lock.unlock(); c.resume(returning: n) } else { self.helloWaiter = c; self.lock.unlock() }
            } }
            g.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); throw RemoteError(code: -1, message: "the server did not answer") }
            let first = try await g.next()!; g.cancelAll(); return first
        }
        let r: [String: Any] = try await callJSON("auth", ["hmac": RemoteProtocol.hmac(token: token, nonce: nonce)])
        serverName = r["server"] as? String ?? ""
    }

    func close() { task?.cancel(with: .goingAway, reason: nil); continuation?.finish(); failAll(RemoteError(code: -1, message: "closed")) }

    private func failAll(_ e: Error) {
        lock.lock(); let p = pending; pending = [:]; let h = helloWaiter; helloWaiter = nil; lock.unlock()
        p.values.forEach { $0.resume(throwing: e) }; h?.resume(throwing: e)
    }

    private func readLoop(_ t: URLSessionWebSocketTask) async {
        while true {
            do {
                let m = try await t.receive()
                var data: Data?
                switch m { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: break }
                if let data { dispatch(data) }
            } catch { failAll(error); continuation?.finish(); return }
        }
    }

    private func dispatch(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let id = obj["id"] as? Int {
            lock.lock(); let c = pending[id]; pending[id] = nil; lock.unlock()
            if let err = obj["error"] as? [String: Any] { c?.resume(throwing: RemoteError(code: err["code"] as? Int ?? 0, message: err["message"] as? String ?? "error")) }
            else { c?.resume(returning: (try? JSONSerialization.data(withJSONObject: obj["result"] ?? NSNull(), options: .fragmentsAllowed)) ?? Data("null".utf8)) }
            return
        }
        if let err = obj["error"] as? [String: Any], obj["id"] == nil || obj["id"] is NSNull {                        // a connection-level error
            failAll(RemoteError(code: err["code"] as? Int ?? 0, message: err["message"] as? String ?? "error")); return
        }
        guard let method = obj["method"] as? String else { return }
        let params = (try? JSONSerialization.data(withJSONObject: obj["params"] ?? NSNull(), options: .fragmentsAllowed)) ?? Data("null".utf8)
        if method == "hello", let p = obj["params"] as? [String: Any], let n = p["nonce"] as? String {
            lock.lock(); helloNonce = n; let w = helloWaiter; helloWaiter = nil; lock.unlock()
            w?.resume(returning: n); return
        }
        continuation?.yield(RemoteEvent(name: method, params: params))
    }

    // MARK: calls

    func callData(_ method: String, _ params: [String: Any] = [:]) async throws -> Data {
        guard let t = task else { throw RemoteError(code: -1, message: "not connected") }
        lock.lock(); let id = nextID; nextID += 1; lock.unlock()
        let msg = String(decoding: RPC.request(id: id, method: method, params: params), as: UTF8.self)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            lock.lock(); pending[id] = c; lock.unlock()
            t.send(.string(msg)) { [weak self] err in
                if let err { self?.lock.lock(); let p = self?.pending.removeValue(forKey: id); self?.lock.unlock(); p?.resume(throwing: err) }
            }
        }
    }

    func callJSON(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: try await callData(method, params), options: .fragmentsAllowed) as? [String: Any]) ?? [:]
    }

    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await callData(method, params))
    }

    /// Pulls every outstanding library change into `mirror`.
    func syncLibrary(into mirror: LibraryMirror) async throws {
        while true {
            let set: LibraryChangeSet = try await call("library.changes", ["cursor": mirror.cursor, "limit": 500])
            mirror.apply(set)
            if !set.more { break }
        }
    }
}

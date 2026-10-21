import Foundation
import Network

/// WebSocket server for the remote API (Network.framework, no third-party packages).
final class RemoteServer: @unchecked Sendable {
    let controller: RemoteController
    private let token: String
    private let advertise: Bool
    private let queue = DispatchQueue(label: "aureon.remote.server")
    private var listener: NWListener?
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: Client] = [:]
    private var timer: DispatchSourceTimer?
    private(set) var port: UInt16 = 0
    var onClientsChanged: ((Int) -> Void)?
    var authTimeout: TimeInterval = 5

    private final class Client {
        let conn: NWConnection
        let nonce = RemoteProtocol.newNonce()
        var authed = false
        init(_ c: NWConnection) { conn = c }
    }

    // last broadcast state
    private var lastQueueRev = -1, lastSettingsRev = -1, lastLibraryRev: Int64 = -1
    private var lastStatusKey = "", lastStatusAt = Date.distantPast

    init(controller: RemoteController, token: String, advertise: Bool = false) {
        self.controller = controller; self.token = token; self.advertise = advertise
    }

    var authenticatedClients: Int { lock.lock(); defer { lock.unlock() }; return clients.values.filter(\.authed).count }
    var connectedClients: Int { lock.lock(); defer { lock.unlock() }; return clients.count }

    /// Starts listening. `port == 0` picks a free port. Returns the port actually used.
    @discardableResult
    func start(port: UInt16 = 0) throws -> UInt16 {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options(); ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let l = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        if advertise { l.service = NWListener.Service(name: controller.serverName, type: RemoteProtocol.bonjourType) }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let ready = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var error: Error? }
        let box = Box()
        l.stateUpdateHandler = { s in
            switch s { case .ready: ready.signal(); case .failed(let e): box.error = e; ready.signal(); default: break }
        }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { l.cancel(); throw AureonError.message("the remote server did not start in time") }
        if let e = box.error { l.cancel(); throw e }
        listener = l
        self.port = l.port?.rawValue ?? 0
        startBroadcasting()
        return self.port
    }

    func stop() {
        timer?.cancel(); timer = nil
        listener?.cancel(); listener = nil
        lock.lock(); let all = Array(clients.values); clients = [:]; lock.unlock()
        all.forEach { $0.conn.cancel() }
    }

    // MARK: connections

    private func accept(_ conn: NWConnection) {
        let c = Client(conn), key = ObjectIdentifier(c)
        lock.lock(); clients[key] = c; lock.unlock()
        conn.stateUpdateHandler = { [weak self] st in
            switch st { case .failed, .cancelled: self?.remove(key); default: break }
        }
        conn.start(queue: queue)
        send(c, RPC.notification(method: "hello", resultJSON: (try? JSONSerialization.data(withJSONObject:
            ["nonce": c.nonce, "protocol": RemoteProtocol.version, "server": controller.serverName] as [String: Any])) ?? Data()))
        queue.asyncAfter(deadline: .now() + authTimeout) { [weak self, weak c] in
            guard let self, let c, !c.authed else { return }
            self.send(c, RPC.error(id: nil, RemoteError(code: RemoteErrorCode.unauthorized, message: "authentication timed out")), thenClose: true)
        }
        notifyCount()
        receive(c)
    }

    private func remove(_ key: ObjectIdentifier) { lock.lock(); clients[key] = nil; lock.unlock(); notifyCount() }
    private func notifyCount() { let n = authenticatedClients; onClientsChanged?(n) }

    private func receive(_ c: Client) {
        c.conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { c.conn.cancel(); return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close { c.conn.cancel(); return }
            if let data, meta?.opcode == .text { self.handle(c, data) }
            self.receive(c)
        }
    }

    private func send(_ c: Client, _ data: Data, thenClose: Bool = false) {
        let md = NWProtocolWebSocket.Metadata(opcode: .text)
        c.conn.send(content: data, contentContext: NWConnection.ContentContext(identifier: "msg", metadata: [md]), isComplete: true,
                    completion: .contentProcessed { _ in
            // close only after the message has actually left, or the client may see a reset instead of the reason
            if thenClose { self.queue.asyncAfter(deadline: .now() + 0.1) { c.conn.cancel() } }
        })
    }

    private func handle(_ c: Client, _ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            send(c, RPC.error(id: nil, RemoteError(code: RemoteErrorCode.parse, message: "invalid JSON"))); return
        }
        let id = obj["id"], method = obj.str("method") ?? "", params = obj.obj("params") ?? [:]
        guard !method.isEmpty else { send(c, RPC.error(id: id, RemoteError(code: RemoteErrorCode.invalidRequest, message: "missing method"))); return }

        if !c.authed {
            guard method == "auth", RemoteProtocol.verify(token: token, nonce: c.nonce, response: params.str("hmac") ?? "") else {
                send(c, RPC.error(id: id, RemoteError(code: RemoteErrorCode.unauthorized, message: method == "auth" ? "wrong pairing token" : "authenticate first")), thenClose: true)
                return
            }
            c.authed = true
            let result = (try? JSONSerialization.data(withJSONObject: ["ok": true, "server": controller.serverName, "protocol": RemoteProtocol.version,
                                                                      "queueRevision": controller.player.queueRevision, "libraryRevision": controller.library.revision] as [String: Any])) ?? Data()
            if let id { send(c, RPC.response(id: id, resultJSON: result)) }
            notifyCount()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await controller.handle(method: method, params: params)
                if let id { send(c, RPC.response(id: id, resultJSON: result)) }
            } catch let e as RemoteError { if let id { send(c, RPC.error(id: id, e)) } }
            catch { if let id { send(c, RPC.error(id: id, RemoteError(code: RemoteErrorCode.internalError, message: error.localizedDescription))) } }
        }
    }

    // MARK: pushing changes

    private func broadcast(_ method: String, _ json: Data) {
        let msg = RPC.notification(method: method, resultJSON: json)
        lock.lock(); let targets = clients.values.filter(\.authed); lock.unlock()
        for c in targets { send(c, msg) }
    }

    private func startBroadcasting() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: .milliseconds(100), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }

    /// Public so tests can drive it deterministically.
    func tick() {
        guard authenticatedClients > 0 else { return }
        let p = controller.player
        let q = p.queueRevision
        if q != lastQueueRev { lastQueueRev = q; if let d = try? JSONEncoder.remote.encode(controller.queueSnapshot()) { broadcast("queue.changed", d) } }
        let s = p.settingsRevision
        if s != lastSettingsRev { lastSettingsRev = s; if let d = try? JSONEncoder.remote.encode(p.settings) { broadcast("settings.changed", d) } }
        let lr = controller.library.revision
        if lr != lastLibraryRev { lastLibraryRev = lr; broadcast("library.changed", Data("{\"revision\":\(lr)}".utf8)) }
        let st = controller.statusDTO()
        let key = "\(st.state)|\(st.entryID ?? "")|\(st.pipeline.count)|\(st.errors.count)|\(st.bitPerfect)"
        let interval: TimeInterval = st.state == "playing" ? 0.5 : 2
        if key != lastStatusKey || Date().timeIntervalSince(lastStatusAt) >= interval {
            lastStatusKey = key; lastStatusAt = Date()
            if let d = try? JSONEncoder.remote.encode(st) { broadcast("status", d) }
        }
    }
}

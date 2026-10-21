import Foundation
import ServiceManagement
import AureonHelperKit

/// Something that wants to be told when playback starts and ends (quiet mode, tests).
protocol PlaybackTuning: AnyObject, Sendable {
    func playbackWillStart()
    func playbackDidEnd()
}

/// The connection to the privileged helper, abstracted so the controller can be tested without launchd.
protocol HelperClient: AnyObject, Sendable {
    func hello() async throws -> String
    func suspend(names: [String]) async throws -> [String]
    func resume() async throws -> Int
    func heartbeat() async throws
    func setPriority(nice: Int32) async throws -> Bool
    func invalidate()
}

/// Lets exactly one of an XPC reply and its error handler resume a continuation.
final class OnceGuard: @unchecked Sendable {
    private var done = false; private let l = NSLock()
    func run(_ f: () -> Void) { l.lock(); defer { l.unlock() }; if !done { done = true; f() } }
}

/// Talks to the real helper over XPC (a Mach service registered by launchd).
final class XPCHelperClient: HelperClient, @unchecked Sendable {
    private let connection: NSXPCConnection

    /// With no argument, connects to the registered helper (Mach service). An injected connection is used as given (already configured and resumed).
    init(connection: NSXPCConnection? = nil) {
        if let connection { self.connection = connection; return }
        let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: AureonHelperProtocol.self)
        c.resume()
        self.connection = c
    }

    private func call<T>(_ body: @escaping (AureonHelperProtocol, @escaping (T) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = OnceGuard()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ e in once.run { cont.resume(throwing: e) } }) as? AureonHelperProtocol else {
                cont.resume(throwing: AureonError.message("the helper is not reachable")); return
            }
            body(proxy) { v in once.run { cont.resume(returning: v) } }
        }
    }

    func hello() async throws -> String { try await call { $0.hello(reply: $1) } }
    func suspend(names: [String]) async throws -> [String] { try await call { $0.suspend(names: names, reply: $1) } }
    func resume() async throws -> Int { try await call { $0.resume(reply: $1) } }
    func heartbeat() async throws { let _: Bool = try await call { $0.heartbeat(reply: $1) } }
    func setPriority(nice: Int32) async throws -> Bool { try await call { $0.setCallerPriority(nice: nice, reply: $1) } }
    func invalidate() { connection.invalidate() }
}

/// "Quiet mode": while Aureon plays, pause Spotlight indexing / Time Machine / media analysis and raise Aureon's own priority;
/// put everything back afterwards. Needs the signed helper (see Docs/SYSTEM-OPTIMIZATION.md).
final class QuietModeController: PlaybackTuning, @unchecked Sendable {
    enum Status: Equatable {
        case notInstalled           // the app bundle contains no helper, or it is not registered
        case requiresApproval       // registered, waiting for the user in System Settings → Login Items
        case ready
        case active([String])       // what is currently paused
        case failed(String)
    }

    private let lock = NSLock()
    private let makeClient: () -> HelperClient
    private var client: HelperClient?
    private var heartbeatTask: Task<Void, Never>?
    private var _status: Status = .notInstalled
    var heartbeatInterval: TimeInterval = 5
    var processNames: [String] = []         // empty = everything on the helper's allowlist
    var nice: Int32 = -10                   // −20 is the maximum
    var onStatusChange: ((Status) -> Void)?

    init(makeClient: @escaping () -> HelperClient = { XPCHelperClient() }) { self.makeClient = makeClient }

    var status: Status { lock.lock(); defer { lock.unlock() }; return _status }
    private func set(_ s: Status) { lock.lock(); _status = s; lock.unlock(); onStatusChange?(s) }

    // MARK: registration (ServiceManagement)

    static func serviceStatus() -> SMAppService.Status { SMAppService.daemon(plistName: HelperConstants.plistName).status }

    func refreshStatus() -> Status {
        switch Self.serviceStatus() {
        case .enabled: if case .active = status { return status }; set(.ready)
        case .requiresApproval: set(.requiresApproval)
        default: set(.notInstalled)
        }
        return status
    }

    /// Registers the helper with launchd. Throws if the app is not a signed bundle that contains it.
    func register() throws {
        try SMAppService.daemon(plistName: HelperConstants.plistName).register()
        _ = refreshStatus()
    }

    func unregister() throws { try SMAppService.daemon(plistName: HelperConstants.plistName).unregister(); _ = refreshStatus() }

    // MARK: use

    func begin() async {
        guard status != .notInstalled || true else { return }
        let c = makeClient()
        lock.lock(); client = c; lock.unlock()
        do {
            _ = try await c.hello()
            let names = try await c.suspend(names: processNames)
            _ = try? await c.setPriority(nice: nice)
            set(.active(names))
            startHeartbeat(c)
        } catch {
            c.invalidate()
            lock.lock(); client = nil; lock.unlock()
            set(.failed(error.localizedDescription))
        }
    }

    private func startHeartbeat(_ c: HelperClient) {
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                do { try await c.heartbeat() } catch { self?.set(.failed("lost the helper: \(error.localizedDescription)")); return }
            }
        }
    }

    /// Always safe to call, any number of times.
    func end() async {
        heartbeatTask?.cancel(); heartbeatTask = nil
        lock.lock(); let c = client; client = nil; lock.unlock()
        guard let c else { return }
        _ = try? await c.setPriority(nice: 0)
        _ = try? await c.resume()
        c.invalidate()                                  // invalidating also makes the helper resume, should the call above have failed
        if case .active = status { set(.ready) }
    }

    // MARK: PlaybackTuning (called from the engine thread)

    func playbackWillStart() {
        let sem = DispatchSemaphore(value: 0)
        Task { await self.begin(); sem.signal() }
        _ = sem.wait(timeout: .now() + 3)               // never hold up playback for more than a moment
    }

    func playbackDidEnd() {
        let sem = DispatchSemaphore(value: 0)
        Task { await self.end(); sem.signal() }
        _ = sem.wait(timeout: .now() + 3)
    }
}

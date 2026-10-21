import Foundation
import Darwin

/// The helper's brain: one client at a time, a watchdog, and "resume on any exit path".
public final class HelperService: NSObject, NSXPCListenerDelegate, AureonHelperProtocol {
    public let suspender: ProcessSuspender
    private let lock = NSLock()
    private var lastBeat = Date()
    private var owner: NSXPCConnection?
    private var originalNice: [pid_t: Int32] = [:]
    private var watchdog: DispatchSourceTimer?
    public var heartbeatTimeout: TimeInterval
    public var maxSuspension: TimeInterval
    /// Production sets this to the app's code-signing requirement; tests leave it nil.
    public var codeSigningRequirement: String?

    public init(suspender: ProcessSuspender = ProcessSuspender(stateFile: URL(fileURLWithPath: "/var/db/org.aureon.helper.state.json")),
                heartbeatTimeout: TimeInterval = HelperConstants.heartbeatTimeout, maxSuspension: TimeInterval = HelperConstants.maxSuspension) {
        self.suspender = suspender; self.heartbeatTimeout = heartbeatTimeout; self.maxSuspension = maxSuspension
        super.init()
        _ = suspender.recoverFromCrash()                          // a previous run may have died while processes were paused
        startWatchdog()
    }

    deinit { watchdog?.cancel(); restoreEverything() }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.aureon.helper.watchdog"))
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.checkWatchdog() }
        t.resume(); watchdog = t
    }

    /// Public so tests can step it.
    public func checkWatchdog(now: Date = Date()) {
        guard suspender.isSuspending else { return }
        lock.lock(); let silent = now.timeIntervalSince(lastBeat); lock.unlock()
        let held = suspender.suspendedAt.map { now.timeIntervalSince($0) } ?? 0
        if silent > heartbeatTimeout || held > maxSuspension { restoreEverything() }
    }

    /// Resumes processes and restores priorities. Called on every way out.
    public func restoreEverything() {
        _ = suspender.resumeAll()
        lock.lock(); let nices = originalNice; originalNice = [:]; lock.unlock()
        for (pid, nice) in nices { setpriority(PRIO_PROCESS, id_t(pid), nice) }
    }

    // MARK: NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        lock.lock(); let busy = owner != nil; lock.unlock()
        if busy { return false }                                   // one client at a time
        if let req = codeSigningRequirement { c.setCodeSigningRequirement(req) }
        c.exportedInterface = NSXPCInterface(with: AureonHelperProtocol.self)
        c.exportedObject = self
        let gone: () -> Void = { [weak self, weak c] in
            guard let self else { return }
            self.restoreEverything()                                // the client died or hung up: put everything back
            self.lock.lock(); if self.owner === c { self.owner = nil }; self.lock.unlock()
        }
        c.invalidationHandler = gone
        c.interruptionHandler = gone
        lock.lock(); owner = c; lastBeat = Date(); lock.unlock()
        c.resume()
        return true
    }

    // MARK: AureonHelperProtocol

    public func hello(reply: @escaping (String) -> Void) { reply(HelperConstants.version) }

    public func suspend(names: [String], reply: @escaping ([String]) -> Void) {
        lock.lock(); lastBeat = Date(); lock.unlock()
        reply(suspender.suspend(only: names.isEmpty ? nil : names).map(\.description))
    }

    public func resume(reply: @escaping (Int) -> Void) { lock.lock(); lastBeat = Date(); lock.unlock(); reply(suspender.resumeAll()) }

    public func heartbeat(reply: @escaping (Bool) -> Void) { lock.lock(); lastBeat = Date(); lock.unlock(); reply(true) }

    public func status(reply: @escaping ([String]) -> Void) { reply(suspender.suspended.map(\.description)) }

    public func setCallerPriority(nice: Int32, reply: @escaping (Bool) -> Void) {
        // Only ever the calling process, and only within −20…0.
        guard let pid = NSXPCConnection.current()?.processIdentifier, pid > 1, (-20...0).contains(nice) else { reply(false); return }
        lock.lock(); if originalNice[pid] == nil { originalNice[pid] = Int32(getpriority(PRIO_PROCESS, id_t(pid))) }; lock.unlock()
        reply(setpriority(PRIO_PROCESS, id_t(pid), nice) == 0)
    }
}

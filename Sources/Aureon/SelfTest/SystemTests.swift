import Foundation
import Darwin
import AureonHelperKit

/// Harmless stand-ins for Spotlight and friends: real processes named "sleep" that the tests may stop and continue.
final class Decoys {
    let procs: [Process]
    init(_ n: Int, executable: String = "/bin/sleep") {
        procs = (0..<n).map { _ in let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = ["600"]; try! p.run(); return p }
    }
    var pids: [pid_t] { procs.map(\.processIdentifier) }
    var targets: () -> [ProcessSuspender.Target] { { [pids] in pids.compactMap { ProcessSuspender.target(pid: $0) } } }
    func stopped(_ i: Int) -> Bool { ProcessSuspender.isStopped(procs[i].processIdentifier) }
    func cleanup() { for p in procs { kill(p.processIdentifier, SIGCONT); p.terminate(); p.waitUntilExit() } }
}

final class FakeHelper: HelperClient, @unchecked Sendable {
    private let l = NSLock()
    private(set) var calls: [String] = []
    var failHello = false, failSuspend = false, failHeartbeat = false
    var suspended = ["mds (pid 100)", "backupd (pid 200)"]
    private func log(_ s: String) { l.lock(); calls.append(s); l.unlock() }
    var snapshot: [String] { l.lock(); defer { l.unlock() }; return calls }
    func hello() async throws -> String { log("hello"); if failHello { throw AureonError.message("not installed") }; return "1" }
    func suspend(names: [String]) async throws -> [String] { log("suspend \(names)"); if failSuspend { throw AureonError.message("refused") }; return suspended }
    func resume() async throws -> Int { log("resume"); return suspended.count }
    func heartbeat() async throws { log("beat"); if failHeartbeat { throw AureonError.message("gone") } }
    func setPriority(nice: Int32) async throws -> Bool { log("nice \(nice)"); return true }
    func invalidate() { log("invalidate") }
}

struct SystemTests {
    func wait(_ cond: () -> Bool, _ timeout: TimeInterval = 3) -> Bool { let end = Date().addingTimeInterval(timeout); while Date() < end { if cond() { return true }; usleep(10_000) }; return cond() }

    // MARK: unprivileged scheduling

    func machTimeConstraintPolicy() {
        final class Box: @unchecked Sendable { var ok = false; var policy: RealtimeThread.TimeConstraint?; var qos: qos_class_t = QOS_CLASS_DEFAULT; var before: RealtimeThread.TimeConstraint? }
        let b = Box(), done = DispatchSemaphore(value: 0)
        Thread {                                                              // a throw-away thread: never touch the test runner's own
            b.before = RealtimeThread.currentPolicy()
            b.ok = RealtimeThread.promoteCurrentThread(periodMs: 5, computationMs: 1, constraintMs: 4)
            b.policy = RealtimeThread.currentPolicy(); b.qos = RealtimeThread.currentQoS
            done.signal()
        }.start()
        done.wait()
        expect(b.before == nil, "an ordinary thread has no time-constraint policy")
        expect(b.ok, "a normal user may request a time-constraint policy for its own thread")
        if let p = b.policy {
            // the kernel may raise the computation time to its own minimum, but period and constraint are ours
            expect(abs(p.periodMs - 5) < 0.01 && abs(p.constraintMs - 4) < 0.01 && p.computationMs >= 1 && p.computationMs <= p.constraintMs && p.preemptible, "policy read back: \(p)")
        } else { expect(false, "the policy must be readable after it was set") }
        expect(b.qos != QOS_CLASS_BACKGROUND && b.qos != QOS_CLASS_UTILITY, "a real-time thread is not scheduled as background work (QoS \(b.qos.rawValue))")
        expect(RealtimeThread.currentPolicy() == nil, "the calling (main) thread was not affected")
    }

    func ioCycleUsageOnTheDefaultDevice() {
        guard let dev = OutputDevice(), let original = dev.ioCycleUsage else { return }          // some devices do not expose it
        expect(original > 0 && original <= 1, "usage \(original)")
        if dev.setIOCycleUsage(0.8) {
            expect(abs((dev.ioCycleUsage ?? 0) - 0.8) < 0.01, "read back \(String(describing: dev.ioCycleUsage))")
            dev.setIOCycleUsage(original)
            expect(abs((dev.ioCycleUsage ?? 0) - original) < 0.01, "restored")
        }
    }

    // MARK: suspending

    func suspendsOnlyAllowlistedProcesses() {
        let sleepers = Decoys(2), other = Decoys(1, executable: "/bin/cat")           // "cat" waits on stdin: a process whose name is not allowed
        defer { sleepers.cleanup(); other.cleanup() }
        let all = { sleepers.targets() + other.targets() }
        let s = ProcessSuspender(allowlist: ["sleep"], candidates: all)
        let done = s.suspend()
        expect(done.count == 2 && done.allSatisfy { $0.name == "sleep" }, "suspended \(done.map(\.description))")
        expect(wait { sleepers.stopped(0) && sleepers.stopped(1) }, "the kernel reports both as stopped")
        expect(!other.stopped(0), "a process outside the allowlist is never touched")
        expect(s.suspend().isEmpty && s.suspended.count == 2, "suspending twice does not duplicate")
        expect(s.suspend(only: ["launchd", "cat"]).isEmpty, "a request can narrow the list but never widen it beyond the allowlist")
        expect(s.resumeAll() == 2 && wait { !sleepers.stopped(0) && !sleepers.stopped(1) }, "both continue")
        expect(!s.isSuspending && s.resumeAll() == 0, "resume is idempotent")
    }

    func neverTouchesLaunchdOrItself() {
        let me = ProcessSuspender.target(pid: getpid())!, init1 = ProcessSuspender.target(pid: 1)
        let s = ProcessSuspender(allowlist: [me.name, init1?.name ?? "launchd"], candidates: { [me] + (init1.map { [$0] } ?? []) })
        expect(s.suspend().isEmpty, "pid 1 and the helper itself are off limits even if their names were allow-listed")
        expect(!ProcessSuspender.isStopped(getpid()))
        expect(ProcessSuspender.defaultAllowlist == ["mds", "mds_stores", "mdworker", "mdworker_shared", "backupd", "photoanalysisd", "mediaanalysisd"], "the shipped allowlist is exactly Spotlight, Time Machine and media analysis")
    }

    func doesNotResumeWhatSomeoneElseStopped() {
        let d = Decoys(1); defer { d.cleanup() }
        kill(d.pids[0], SIGSTOP); expect(wait { d.stopped(0) })
        let s = ProcessSuspender(allowlist: ["sleep"], candidates: d.targets)
        expect(s.suspend().isEmpty, "already stopped by the user: not ours")
        expect(s.resumeAll() == 0 && d.stopped(0), "and so not resumed either")
    }

    func recoversAfterACrash() {
        let d = Decoys(2); defer { d.cleanup() }
        let state = tempDir("susp").appendingPathComponent("state-\(UUID().uuidString.prefix(5)).json")
        var s: ProcessSuspender? = ProcessSuspender(allowlist: ["sleep"], stateFile: state, candidates: d.targets)
        s!.suspend()
        expect(FileManager.default.fileExists(atPath: state.path) && wait { d.stopped(0) }, "what is paused is written down")
        s = nil                                                                         // the helper "crashes": no resume ever ran
        expect(d.stopped(0) && d.stopped(1), "still stopped")
        let next = ProcessSuspender(allowlist: ["sleep"], stateFile: state, candidates: d.targets)
        expect(next.recoverFromCrash() == 2 && wait { !d.stopped(0) && !d.stopped(1) }, "the next start continues them")
        expect(!FileManager.default.fileExists(atPath: state.path), "the state file is cleared")

        // a recycled pid must be left alone: tamper with the recorded start time
        let s2 = ProcessSuspender(allowlist: ["sleep"], stateFile: state, candidates: d.targets)
        s2.suspend()
        var recorded = try! JSONDecoder().decode([ProcessSuspender.Target].self, from: Data(contentsOf: state))
        for i in recorded.indices { recorded[i].startSec -= 1000 }
        try! JSONEncoder().encode(recorded).write(to: state)
        expect(ProcessSuspender(allowlist: ["sleep"], stateFile: state, candidates: d.targets).recoverFromCrash() == 0 && d.stopped(0), "a different start time means a different process: not touched")
        s2.resumeAll()
        try? FileManager.default.removeItem(at: state)
    }

    // MARK: the service

    func watchdogResumesWhenTheAppGoesSilent() {
        let d = Decoys(1); defer { d.cleanup() }
        let svc = HelperService(suspender: ProcessSuspender(allowlist: ["sleep"], candidates: d.targets), heartbeatTimeout: 0.5, maxSuspension: 100)
        svc.suspend(names: []) { _ in }
        expect(wait { d.stopped(0) })
        for _ in 0..<4 { usleep(250_000); svc.heartbeat { _ in } }                      // a live app keeps it paused
        expect(d.stopped(0), "heartbeats keep the suspension alive")
        expect(wait({ !d.stopped(0) }, 3), "without heartbeats the helper resumes the processes by itself")
        expect(!svc.suspender.isSuspending)

        let capped = HelperService(suspender: ProcessSuspender(allowlist: ["sleep"], candidates: d.targets), heartbeatTimeout: 100, maxSuspension: 0.6)
        capped.suspend(names: []) { _ in }
        expect(wait { d.stopped(0) })
        let end = Date().addingTimeInterval(1.5); while Date() < end { capped.heartbeat { _ in }; usleep(100_000) }
        expect(!d.stopped(0), "even a healthy client cannot hold the system paused beyond the hard cap")
    }

    func deallocatingTheServiceResumes() {
        let d = Decoys(1); defer { d.cleanup() }
        var svc: HelperService? = HelperService(suspender: ProcessSuspender(allowlist: ["sleep"], candidates: d.targets))
        svc!.suspend(names: []) { _ in }
        expect(wait { d.stopped(0) })
        svc = nil
        expect(wait { !d.stopped(0) }, "tearing the service down puts everything back")
    }

    /// The real XPC protocol, over an in-process anonymous listener (no launchd, no privileges).
    func xpcRoundTrip() {
        let d = Decoys(2); defer { d.cleanup() }
        let svc = HelperService(suspender: ProcessSuspender(allowlist: ["sleep"], candidates: d.targets), heartbeatTimeout: 30)
        let listener = NSXPCListener.anonymous(); listener.delegate = svc; listener.resume()
        func connect() -> NSXPCConnection { let c = NSXPCConnection(listenerEndpoint: listener.endpoint); c.remoteObjectInterface = NSXPCInterface(with: AureonHelperProtocol.self); c.resume(); return c }
        let conn = connect()
        let client = XPCHelperClient(connection: conn)
        expect(runAsync { try await client.hello() }.isSuccessWith { $0 == HelperConstants.version }, "hello")
        let got = try! runAsync { try await client.suspend(names: ["sleep", "launchd"]) }.get()
        expect(got.count == 2 && got.allSatisfy { $0.hasPrefix("sleep (pid ") }, "only the allow-listed names are paused: \(got)")
        expect(wait { d.stopped(0) && d.stopped(1) })
        expect(runAsync { try await client.heartbeat() }.isSuccessWith { _ in true })
        expect(runAsync { try await client.resume() }.isSuccessWith { $0 == 2 } && wait { !d.stopped(0) && !d.stopped(1) }, "resume over XPC")

        // priorities: out-of-range values are refused; raising priority needs root, so it fails here instead of misbehaving
        expect(runAsync { try await client.setPriority(nice: 5) }.isSuccessWith { $0 == false }, "positive values are not accepted")
        expect(runAsync { try await client.setPriority(nice: -40) }.isSuccessWith { $0 == false })
        let nice0 = getpriority(PRIO_PROCESS, 0)
        expect(runAsync { try await client.setPriority(nice: -5) }.isSuccessWith { geteuid() == 0 || $0 == false } && getpriority(PRIO_PROCESS, 0) == nice0 || geteuid() == 0, "an unprivileged helper cannot raise priority, and nothing changed")

        // a second client is turned away while the first is connected
        let intruder = XPCHelperClient(connection: connect())
        expect(runAsync { try await intruder.hello() }.isFailure, "only one client at a time")
        intruder.invalidate()

        // the app dies while processes are paused: the helper notices the dead connection and resumes them
        _ = try! runAsync { try await client.suspend(names: []) }.get()
        expect(wait { d.stopped(0) })
        client.invalidate()
        expect(wait({ !d.stopped(0) && !d.stopped(1) }, 3), "a vanished client means everything is resumed")
        let again = XPCHelperClient(connection: connect())
        expect(runAsync { try await again.hello() }.isSuccessWith { _ in true }, "and a new client can connect afterwards")
        again.invalidate()
        listener.invalidate()
    }

    // MARK: the app-side controller

    func quietModeLifecycle() {
        let fake = FakeHelper()
        let q = QuietModeController(makeClient: { fake })
        q.heartbeatInterval = 0.1; q.nice = -10
        var states: [QuietModeController.Status] = []
        q.onStatusChange = { states.append($0) }
        _ = runAsync { await q.begin() }
        expect(q.status == .active(["mds (pid 100)", "backupd (pid 200)"]), "\(q.status)")
        expect(Array(fake.snapshot.prefix(3)) == ["hello", "suspend []", "nice -10"], "order of calls: \(fake.snapshot)")
        usleep(450_000)
        expect(fake.snapshot.filter { $0 == "beat" }.count >= 3, "heartbeats while active: \(fake.snapshot)")
        _ = runAsync { await q.end() }
        let calls = fake.snapshot
        expect(calls.contains("nice 0") && calls.contains("resume") && calls.last == "invalidate", "end restores priority, resumes and hangs up: \(calls)")
        let beats = calls.filter { $0 == "beat" }.count
        usleep(300_000)
        expect(fake.snapshot.filter { $0 == "beat" }.count == beats, "heartbeats stop after end()")
        expect(q.status == .ready && states.last == .ready)
        _ = runAsync { await q.end() }
        expect(fake.snapshot.filter { $0 == "resume" }.count == 1, "end() is idempotent")
    }

    func quietModeFailuresAreHarmless() {
        let bad = FakeHelper(); bad.failHello = true
        let q = QuietModeController(makeClient: { bad })
        _ = runAsync { await q.begin() }
        if case .failed(let m) = q.status { expect(m.contains("not installed"), m) } else { expect(false, "\(q.status)") }
        expect(bad.snapshot.contains("invalidate"), "a failed start hangs up")
        _ = runAsync { await q.end() }                                                  // must not crash

        let refuses = FakeHelper(); refuses.failSuspend = true
        let q2 = QuietModeController(makeClient: { refuses })
        _ = runAsync { await q2.begin() }
        if case .failed = q2.status { } else { expect(false, "\(q2.status)") }

        let flaky = FakeHelper(); flaky.failHeartbeat = true
        let q3 = QuietModeController(makeClient: { flaky }); q3.heartbeatInterval = 0.05
        _ = runAsync { await q3.begin() }
        expect(wait({ if case .failed = q3.status { return true }; return false }, 2), "a lost helper is reported, not ignored")
        _ = runAsync { await q3.end() }

        // in this test process there is no signed bundle: the helper is simply not installed
        let real = QuietModeController()
        expect(real.refreshStatus() == .notInstalled, "\(real.refreshStatus())")
        expect((try? real.register()) == nil, "registering without a signed bundle fails cleanly")
    }

    func playerCallsTheTuningHooks() {
        final class Hooks: PlaybackTuning, @unchecked Sendable {
            let l = NSLock(); var events: [String] = []
            func add(_ e: String) { l.lock(); events.append(e); l.unlock() }
            func playbackWillStart() { add("start") }
            func playbackDidEnd() { add("end") }
            var list: [String] { l.lock(); defer { l.unlock() }; return events }
        }
        let dir = tempDir("hooks")
        let t = writeWAV(dir.appendingPathComponent("h.wav"), rate: 8000, bits: 24, frames: 8000) { i, _ in i }
        let hooks = Hooks(), sink = RecordingSink()
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.tuning = hooks; o.promoteEngineThread = true
        let p = Player(); p.setQueue([t.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 10))
        expect(hooks.list == ["start", "end"], "started once, ended once: \(hooks.list)")
        expect(p.status.engineThreadPromoted, "the engine thread asked for a time-constraint policy")

        let h2 = Hooks(); var o2 = o; o2.tuning = h2
        let q = Player(); q.setQueue(["/nonexistent.flac"]); q.start(options: o2)
        expect(q.waitUntilFinished(timeout: 10) && h2.list == ["start", "end"], "even when nothing could be played the helper is told to stand down: \(h2.list)")

        let h3 = Hooks(); var o3 = o; o3.tuning = h3; o3.sinkFactory = { _ in RecordingSink(speed: 1) }
        let r = Player(); r.setQueue([writeWAV(dir.appendingPathComponent("long.wav"), rate: 8000, bits: 24, frames: 80_000) { i, _ in i }.path]); r.start(options: o3)
        usleep(500_000); r.stop()
        expect(h3.list == ["start", "end"], "and when playback is stopped midway: \(h3.list)")
    }
}

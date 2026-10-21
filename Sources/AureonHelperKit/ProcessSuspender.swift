import Foundation
import Darwin

/// Finds and pauses (SIGSTOP) well-known background daemons, and — crucially — makes sure they are always resumed.
public final class ProcessSuspender {
    public struct Target: Codable, Equatable, Hashable {
        public var pid: Int32
        public var name: String
        public var startSec: Int64
        public var startUsec: Int64
        public init(pid: Int32, name: String, startSec: Int64, startUsec: Int64) { self.pid = pid; self.name = name; self.startSec = startSec; self.startUsec = startUsec }
        public var description: String { "\(name) (pid \(pid))" }
    }

    /// Spotlight indexing, Time Machine and the Photos / media analysis daemons. Nothing else may ever be suspended.
    public static let defaultAllowlist: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "backupd", "photoanalysisd", "mediaanalysisd"]

    public let allowlist: Set<String>
    private let stateFile: URL?
    private let candidates: () -> [Target]
    private let lock = NSLock()
    public private(set) var suspended: [Target] = []
    public private(set) var suspendedAt: Date?

    /// - Parameters:
    ///   - candidates: where processes come from (every running process by default; tests pass a fixed list).
    ///   - stateFile: remembers what is paused, so a crashed helper's next run can resume it.
    public init(allowlist: Set<String> = ProcessSuspender.defaultAllowlist, stateFile: URL? = nil, candidates: @escaping () -> [Target] = ProcessSuspender.runningProcesses) {
        self.allowlist = allowlist; self.stateFile = stateFile; self.candidates = candidates
    }

    // MARK: process table

    public static func runningProcesses() -> [Target] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(got, 0))).compactMap { target(pid: $0) }
    }

    public static func target(pid: pid_t) -> Target? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return Target(pid: pid, name: String(cString: buf), startSec: Int64(info.pbi_start_tvsec), startUsec: Int64(info.pbi_start_tvusec))
    }

    /// True while the process exists and is in the stopped state.
    public static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return false }
        return info.pbi_status == 4          // SSTOP
    }

    /// The same process that was recorded (a recycled pid has a different start time).
    private func sameProcess(_ t: Target) -> Bool { Self.target(pid: t.pid).map { $0.startSec == t.startSec && $0.startUsec == t.startUsec && $0.name == t.name } ?? false }

    // MARK: suspend / resume

    /// Pauses every allow-listed process (optionally narrowed to `names`). Safe to call repeatedly.
    @discardableResult
    public func suspend(only names: [String]? = nil) -> [Target] {
        lock.lock(); defer { lock.unlock() }
        let wanted = names.map { allowlist.intersection($0) } ?? allowlist                 // never more than the allowlist, whatever was asked
        let me = getpid()
        var done: [Target] = []
        for t in candidates() where wanted.contains(t.name) && t.pid > 1 && t.pid != me && !suspended.contains(t) {
            if Self.isStopped(t.pid) { continue }                                            // somebody else paused it: not ours to resume
            if kill(t.pid, SIGSTOP) == 0 { suspended.append(t); done.append(t) }
        }
        if !done.isEmpty && suspendedAt == nil { suspendedAt = Date() }
        persist()
        return done
    }

    /// Resumes everything this instance paused. Returns how many processes were continued.
    @discardableResult
    public func resumeAll() -> Int {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        for t in suspended where sameProcess(t) { if kill(t.pid, SIGCONT) == 0 { n += 1 } }
        suspended = []; suspendedAt = nil
        persist()
        return n
    }

    /// After a crash: continue whatever a previous instance left stopped (verified by start time, so a recycled pid is never touched).
    @discardableResult
    public func recoverFromCrash() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let f = stateFile, let d = try? Data(contentsOf: f), let old = try? JSONDecoder().decode([Target].self, from: d) else { return 0 }
        var n = 0
        for t in old where sameProcess(t) && Self.isStopped(t.pid) && allowlist.contains(t.name) { if kill(t.pid, SIGCONT) == 0 { n += 1 } }
        try? FileManager.default.removeItem(at: f)
        return n
    }

    public var isSuspending: Bool { lock.lock(); defer { lock.unlock() }; return !suspended.isEmpty }

    private func persist() {
        guard let f = stateFile else { return }
        if suspended.isEmpty { try? FileManager.default.removeItem(at: f); return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(suspended).write(to: f, options: .atomic)
    }
}

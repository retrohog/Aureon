import Foundation
import AppKit

/// Notices when the interface stops responding and records what the app was doing: a stack sample of this process, written to
/// ~/Library/Logs/Aureon/Stalls. A freeze that comes and goes cannot be reproduced on demand; this keeps the evidence.
final class StallMonitor: @unchecked Sendable {
    static let shared = StallMonitor()
    static let threshold = 0.45                   // seconds without the main thread answering
    private let lock = NSLock()
    private var lastPong = CFAbsoluteTimeGetCurrent()
    private var sampling = false
    private var lastSample = 0.0
    private var started = false
    private(set) var recorded = 0

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Aureon/Stalls", isDirectory: true)
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let t = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.1)
                DispatchQueue.main.async { [self] in lock.lock(); lastPong = CFAbsoluteTimeGetCurrent(); lock.unlock() }
                lock.lock(); let silent = CFAbsoluteTimeGetCurrent() - lastPong, busy = sampling, since = CFAbsoluteTimeGetCurrent() - lastSample; lock.unlock()
                if silent > Self.threshold, !busy, since > 8 { record(stalledFor: silent) }
            }
        }
        t.name = "aureon.stallmonitor"; t.qualityOfService = .utility
        t.start()
    }

    private func record(stalledFor: Double) {
        lock.lock(); sampling = true; lastSample = CFAbsoluteTimeGetCurrent(); lock.unlock()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = Self.folder.appendingPathComponent("stall-\(stamp).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(getpid()), "2", "-file", file.path]
        p.terminationHandler = { [self] _ in
            lock.lock(); sampling = false; recorded += 1; lock.unlock()
            prune()
        }
        do { try p.run() } catch { lock.lock(); sampling = false; lock.unlock() }
    }

    /// Keeps the folder small: the newest twenty samples.
    private func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.lastPathComponent.hasPrefix("stall-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for f in files.dropFirst(20) { try? FileManager.default.removeItem(at: f) }
    }

    var files: [URL] { ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("stall-") } }
}

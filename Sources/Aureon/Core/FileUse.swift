import Foundation

/// Which audio files are in use right now, so the tag editor never replaces a file that the engine is reading.
///
/// * Every decoder that opens a local file (`LosslessFile`, `DsdContainer`) registers it for as long as it is open: the playback engine,
///   the RAM prefetch thread, loudness and transition analysis, the DJ decks and the ABX comparator all go through them.
/// * The interface adds the tracks the engine holds although their file is closed (the audible track and the next one, which may sit
///   decoded in RAM), via `setEngineHeld`.
///
/// Never used on the audio thread: opening and closing files happens on producer and utility threads only.
final class FileUse: @unchecked Sendable {
    static let shared = FileUse()

    private let lock = NSLock()
    private var open: [String: Int] = [:]
    private var held: Set<String> = []

    /// One spelling per file: symbolic links resolved, `/var` → `/private/var`.
    static func key(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(p) }
        return String(cString: p)
    }

    func opened(_ path: String) {
        let k = Self.key(path)
        lock.lock(); open[k, default: 0] += 1; lock.unlock()
    }

    func closed(_ path: String) {
        let k = Self.key(path)
        lock.lock()
        if let n = open[k] { if n <= 1 { open[k] = nil } else { open[k] = n - 1 } }
        lock.unlock()
    }

    func setEngineHeld(_ paths: Set<String>) {
        let keys = Set(paths.filter { !$0.contains("://") }.map(Self.key))
        lock.lock(); held = keys; lock.unlock()
    }

    /// Why the file cannot be written now, or nil when it is free.
    func busyReason(_ path: String) -> String? {
        let k = Self.key(path)
        lock.lock(); defer { lock.unlock() }
        if held.contains(k) { return "playing or buffered" }
        if let n = open[k], n > 0 { return "open for reading" }
        return nil
    }

    func isInUse(_ path: String) -> Bool { busyReason(path) != nil }

    /// Files currently open (tests and diagnostics).
    var openCount: Int { lock.lock(); defer { lock.unlock() }; return open.values.reduce(0, +) }
}

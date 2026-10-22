import Foundation

/// Keeps finished loudness analyses on disk, keyed by path, modification time and size, so a file is only analysed once.
final class LoudnessCache: @unchecked Sendable {
    static let shared = LoudnessCache(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Loudness", isDirectory: true))

    private struct Entry: Codable { var path: String; var mtime: Double; var size: Int; var result: R128Result }
    private let dir: URL
    private let lock = NSLock()
    private var memory: [String: R128Result] = [:]

    init(directory: URL) { dir = directory; try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    private func stamp(_ path: String) -> (mtime: Double, size: Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return ((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, (a[.size] as? Int) ?? 0)
    }

    private func file(for path: String) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return dir.appendingPathComponent(String(h, radix: 16) + ".json")
    }

    func cached(path: String) -> R128Result? {
        guard let st = stamp(path) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let key = "\(path)|\(st.mtime)|\(st.size)"
        if let m = memory[key] { return m }
        guard let d = try? Data(contentsOf: file(for: path)), let e = try? JSONDecoder().decode(Entry.self, from: d),
              e.path == path, e.mtime == st.mtime, e.size == st.size, e.result.version == R128Result.currentVersion else { return nil }
        memory[key] = e.result
        return e.result
    }

    func store(_ r: R128Result, path: String) {
        guard let st = stamp(path) else { return }
        lock.lock(); defer { lock.unlock() }
        memory["\(path)|\(st.mtime)|\(st.size)"] = r
        if let d = try? JSONEncoder().encode(Entry(path: path, mtime: st.mtime, size: st.size, result: r)) { try? d.write(to: file(for: path), options: .atomic) }
    }

    /// The analysis of a file, from the cache when it is current, else computed now.
    func analysis(path: String, cancelled: () -> Bool = { false }) -> R128Result? {
        if let c = cached(path: path) { return c }
        guard let r = R128.analyze(path: path, cancelled: cancelled) else { return nil }
        store(r, path: path)
        return r
    }
}

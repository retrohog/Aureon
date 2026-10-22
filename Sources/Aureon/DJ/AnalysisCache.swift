import Foundation

/// Keeps finished track analyses on disk so a track is only decoded for analysis once. Keyed by path, modification time and size.
final class AnalysisCache: @unchecked Sendable {
    static let shared = AnalysisCache(directory: AnalysisCache.defaultDirectory)
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Analysis", isDirectory: true)
    }

    private struct Entry: Codable { var path: String; var mtime: Double; var size: Int; var version: Int; var analysis: DJTrackAnalysis }
    static let version = 2
    private let dir: URL
    private let lock = NSLock()
    private var memory: [String: DJTrackAnalysis] = [:]

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

    func cached(path: String) -> DJTrackAnalysis? {
        guard let st = stamp(path) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let key = "\(path)|\(st.mtime)|\(st.size)"
        if let m = memory[key] { return m }
        guard let d = try? Data(contentsOf: file(for: path)), let e = try? JSONDecoder().decode(Entry.self, from: d),
              e.path == path, e.mtime == st.mtime, e.size == st.size, e.version == Self.version else { return nil }
        memory[key] = e.analysis
        return e.analysis
    }

    func store(_ a: DJTrackAnalysis, path: String) {
        guard let st = stamp(path) else { return }
        lock.lock(); defer { lock.unlock() }
        memory["\(path)|\(st.mtime)|\(st.size)"] = a
        if let d = try? JSONEncoder().encode(Entry(path: path, mtime: st.mtime, size: st.size, version: Self.version, analysis: a)) { try? d.write(to: file(for: path), options: .atomic) }
    }

    /// Analyses a file, using the cache when it is current.
    func analysis(path: String, cancelled: () -> Bool = { false }) -> DJTrackAnalysis? {
        if let c = cached(path: path) { return c }
        guard let a = DJAnalysis.analyze(path: path, cancelled: cancelled) else { return nil }
        store(a, path: path)
        return a
    }
}

/// The few figures of a track analysis that features ranking a whole library need (no waveform).
struct AnalysisSummary: Equatable, Sendable {
    var bpm: Double?
    var energy: Double
    var key: String?                 // Camelot code
    var loudness: Double             // mean level in dBFS
}

extension AnalysisCache {
    /// Reads one analysis from disk without keeping its waveform in memory: ranking 50 000 songs must not hold 50 000 overviews.
    /// Nil when the track was never analysed or the file changed since.
    func summary(path: String) -> AnalysisSummary? {
        guard let st = stamp(path), let d = try? Data(contentsOf: file(for: path)) else { return nil }
        struct Slim: Decodable {
            struct Inner: Decodable { var bpm: Double?; var energy: Double?; var key: MusicalKey?; var loudness: Double? }
            var path: String; var mtime: Double; var size: Int; var version: Int; var analysis: Inner
        }
        guard let e = try? JSONDecoder().decode(Slim.self, from: d), e.path == path, e.mtime == st.mtime, e.size == st.size, e.version == Self.version else { return nil }
        return AnalysisSummary(bpm: e.analysis.bpm, energy: e.analysis.energy ?? 0, key: e.analysis.key?.camelot, loudness: e.analysis.loudness ?? -30)
    }
}

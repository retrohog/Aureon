import Foundation

/// Lyrics kept on this Mac: what was found online or generated, what was looked for and not found (for a week, so a song is not asked about on every
/// play), and the songs whose owner said "do not offer to generate lyrics for this one".
final class LyricsStore: @unchecked Sendable {
    enum Kind: String, Codable { case found, miss, instrumental, declined }

    struct Entry: Codable, Equatable {
        var version = LyricsStore.version
        var key: String
        var kind: Kind
        var lyrics: Lyrics?
        var at: Double
    }

    static let version = 1
    static let missLifetime: TimeInterval = 7 * 86_400
    static let shared = LyricsStore(directory: LyricsStore.defaultDirectory)
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Lyrics", isDirectory: true)
    }

    private let dir: URL
    private let lock = NSLock()
    private var memory: [String: Entry] = [:]

    init(directory: URL) {
        dir = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ key: String) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return dir.appendingPathComponent(String(h, radix: 16) + ".json")
    }

    /// The entry for `key`, or nil when there is none or a "not found" has expired.
    func entry(_ key: String, now: Date = Date()) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        var e = memory[key]
        if e == nil, let d = try? Data(contentsOf: file(key)), let read = try? JSONDecoder().decode(Entry.self, from: d), read.key == key, read.version == Self.version { e = read; memory[key] = read }
        guard let e else { return nil }
        if e.kind == .miss, now.timeIntervalSince1970 - e.at > Self.missLifetime { return nil }
        return e
    }

    func put(_ e: Entry) {
        lock.lock(); defer { lock.unlock() }
        memory[e.key] = e
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: file(e.key), options: .atomic) }
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        memory[key] = nil
        try? FileManager.default.removeItem(at: file(key))
    }

    // MARK: by meaning

    func found(_ key: String) -> Lyrics? { entry(key).flatMap { $0.kind == .found ? $0.lyrics : nil } }
    func store(_ lyrics: Lyrics, key: String) { put(Entry(key: key, kind: .found, lyrics: lyrics, at: Date().timeIntervalSince1970)) }
    func storeMiss(key: String) { put(Entry(key: key, kind: .miss, lyrics: nil, at: Date().timeIntervalSince1970)) }
    func storeInstrumental(key: String) { put(Entry(key: key, kind: .instrumental, lyrics: nil, at: Date().timeIntervalSince1970)) }

    static func declinedKey(_ key: String) -> String { "declined:" + key }
    func isDeclined(_ key: String) -> Bool { entry(Self.declinedKey(key))?.kind == .declined }
    func decline(_ key: String) { put(Entry(key: Self.declinedKey(key), kind: .declined, lyrics: nil, at: Date().timeIntervalSince1970)) }
    func undecline(_ key: String) { remove(Self.declinedKey(key)) }
}

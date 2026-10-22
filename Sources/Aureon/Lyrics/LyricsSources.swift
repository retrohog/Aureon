import Foundation

// Where lyrics are found on this Mac: an .lrc (or .txt) file next to the song, and the file's own tags. Everything here reads files and runs on
// a background thread.

/// What is known about the song when lyrics are asked for.
struct LyricsRequest: Equatable, Sendable {
    var path: String
    var title: String
    var artist: String
    var album: String = ""
    /// Seconds; 0 when not known yet. Online matching needs it.
    var duration: Double = 0

    var isLocalFile: Bool { !RemoteMedia.isRemote(path) && path.hasPrefix("/") }

    /// The key lyrics are cached under: the same song in two places shares them. Letters and digits only, so tag spelling differences do not matter.
    var cacheKey: String {
        func norm(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber } }
        return "\(norm(artist))|\(norm(title))|\(norm(album))|\(Int(duration.rounded()))"
    }
}

/// What a local search found. A synced result beats a plain one; the best of each kind is kept so a plain result can still be shown while
/// a synced version is looked for online.
struct LocalLyricsResult: Equatable, Sendable {
    var synced: Lyrics?
    var plain: Lyrics?
    var best: Lyrics? { synced ?? plain }
}

enum LocalLyrics {
    static let sidecarExtensions = ["lrc", "txt"]
    static let maxFileBytes = 2 << 20

    /// Sidecar files, then the file's tags.
    static func find(_ r: LyricsRequest, fileManager fm: FileManager = .default) -> LocalLyricsResult {
        var found = LocalLyricsResult()
        func consider(_ l: Lyrics?) {
            guard let l else { return }
            if l.synced { if found.synced == nil { found.synced = l } } else if found.plain == nil { found.plain = l }
        }
        guard r.isLocalFile else { return found }
        consider(sidecar(for: r, fileManager: fm))
        if found.synced == nil { for l in fromTags(TagReader.read(path: r.path)) { consider(l) } }
        return found
    }

    // MARK: sidecar files

    /// The .lrc next to the song: same name; else a name that matches once track numbers, case and punctuation are ignored ("01 Title.flac" and
    /// "Artist - Title.lrc"); else the same inside a "Lyrics" folder.
    static func sidecarURL(for r: LyricsRequest, fileManager fm: FileManager = .default) -> URL? {
        let file = URL(fileURLWithPath: r.path)
        let dir = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        for folder in [dir, dir.appendingPathComponent("Lyrics", isDirectory: true), dir.appendingPathComponent("lyrics", isDirectory: true)] {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path), !names.isEmpty else { continue }
            let lowered = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            for ext in sidecarExtensions { if let n = lowered[(base + "." + ext).lowercased()] { return folder.appendingPathComponent(n) } }
            if folder == dir {
                let wanted = Set([key(base), key(r.title), key(r.artist + " " + r.title)].filter { !$0.isEmpty })
                for ext in sidecarExtensions {
                    for n in names.prefix(5000) where (n as NSString).pathExtension.lowercased() == ext {
                        let stem = (n as NSString).deletingPathExtension
                        if wanted.contains(key(stem)) { return folder.appendingPathComponent(n) }
                    }
                }
            }
        }
        return nil
    }

    /// "01 - Some Title" → "sometitle"; "Artist - Title" is left whole (the request tries both).
    static func key(_ name: String) -> String {
        var s = name
        if let r = s.range(of: #"^\s*\d{1,3}\s*[-._)\s]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    static func sidecar(for r: LyricsRequest, fileManager fm: FileManager = .default) -> Lyrics? {
        guard let url = sidecarURL(for: r, fileManager: fm),
              let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 0, size <= maxFileBytes,
              let data = try? Data(contentsOf: url), let text = decode(data) else { return nil }
        // a .txt of a song is only lyrics if it is not a note about something else; accept it when it is short enough to be a song
        if url.pathExtension.lowercased() == "txt", text.count > 40_000 { return nil }
        return LRCParser.parse(text, origin: .sidecar, source: url.lastPathComponent)
    }

    /// File bytes → text: UTF-8 (with or without a byte-order mark), UTF-16 with one, else Windows-1252.
    static func decode(_ d: Data) -> String? {
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: d.dropFirst(3), encoding: .utf8) }
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16) }
        if let s = String(data: d, encoding: .utf8) { return s }
        return String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .isoLatin1)
    }

    // MARK: tags

    /// Lyrics held by the tags: Vorbis LYRICS / UNSYNCEDLYRICS / SYNCEDLYRICS (also with a language suffix), ID3 USLT and SYLT, MP4 ©lyr. Text
    /// that carries timestamps counts as synced whatever the field is called, because LRC in a LYRICS field is what most taggers write.
    static func fromTags(_ tags: RawTags) -> [Lyrics] {
        var out: [Lyrics] = []
        for key in tags.keys where isLyricsKey(key) {
            for value in tags.values[key] ?? [] {
                if let l = LRCParser.parse(value, origin: .embedded, source: "file tags") { out.append(l) }
            }
        }
        // synced first; among equals the longer one
        return out.sorted { a, b in a.synced != b.synced ? a.synced : a.lines.count > b.lines.count }
    }

    static func isLyricsKey(_ normalized: String) -> Bool {
        if normalized == "LYRIC" || normalized == "LRC" { return true }
        // "LYRICS" alone, or with a language code: LYRICS-ENG, UNSYNCED LYRICS=…  ("LYRICIST" is a different field)
        return ["SYNCEDLYRICS", "UNSYNCEDLYRICS", "LYRICS"].contains { normalized == $0 || (normalized.hasPrefix($0) && normalized.count - $0.count <= 4) }
    }
}

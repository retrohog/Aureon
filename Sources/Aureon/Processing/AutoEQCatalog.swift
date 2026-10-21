import Foundation

/// Fetches and caches headphone correction profiles from the open AutoEQ database
/// (github.com/jaakkopasanen/AutoEq, MIT licensed). Nothing is downloaded until the user searches for a headphone.
struct AutoEQEntry: Codable, Hashable, Identifiable {
    var name: String
    var source: String
    var rig: String
    var path: String                 // relative to results/, decoded, e.g. "oratory1990/over-ear/Sennheiser HD 650"
    var id: String { path }
}

protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionFetcher: HTTPFetching {
    func data(from url: URL) async throws -> Data {
        var req = URLRequest(url: url); req.setValue("Aureon/0.1 (open-source macOS player)", forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        if let h = r as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw AureonError.message("HTTP \(h.statusCode) for \(url.lastPathComponent)") }
        return d
    }
}

final class AutoEQCatalog: @unchecked Sendable {
    static let base = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!
    private let fetcher: HTTPFetching
    private let dir: URL
    private let lock = NSLock()
    private var entries: [AutoEQEntry] = []

    init(fetcher: HTTPFetching = URLSessionFetcher(), directory: URL? = nil) {
        self.fetcher = fetcher
        dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/AutoEQ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// `- [Name](./source/rig/Name) by source on rig` (the "on rig" part is optional).
    static func parseIndex(_ text: String) -> [AutoEQEntry] {
        var out: [AutoEQEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("- ["), let close = line.range(of: "]("), let end = line.range(of: ")", range: close.upperBound..<line.endIndex) else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            var path = String(line[close.upperBound..<end.lowerBound])
            if path.hasPrefix("./") { path.removeFirst(2) }
            path = path.removingPercentEncoding ?? path
            let rest = String(line[end.upperBound...])
            var source = "", rig = ""
            if let by = rest.range(of: " by ") {
                let tail = String(rest[by.upperBound...])
                if let on = tail.range(of: " on ") { source = String(tail[..<on.lowerBound]); rig = String(tail[on.upperBound...]) } else { source = tail }
            }
            out.append(AutoEQEntry(name: name, source: source.trimmingCharacters(in: .whitespaces), rig: rig.trimmingCharacters(in: .whitespaces), path: path))
        }
        return out
    }

    /// Loads the index from the on-disk cache, or downloads it (≈850 KB) the first time.
    func loadIndex(refresh: Bool = false) async throws -> [AutoEQEntry] {
        let cache = dir.appendingPathComponent("INDEX.md")
        if !refresh, let d = try? Data(contentsOf: cache), let s = String(data: d, encoding: .utf8) {
            let e = Self.parseIndex(s); if !e.isEmpty { lock.lock(); entries = e; lock.unlock(); return e }
        }
        let d = try await fetcher.data(from: Self.base.appendingPathComponent("INDEX.md"))
        try? d.write(to: cache)
        let e = Self.parseIndex(String(decoding: d, as: UTF8.self))
        guard !e.isEmpty else { throw AureonError.message("the AutoEQ index could not be read") }
        lock.lock(); entries = e; lock.unlock()
        return e
    }

    /// Case- and punctuation-insensitive word search ("hd650" matches "Sennheiser HD 650").
    static func search(_ query: String, in entries: [AutoEQEntry], limit: Int = 40) -> [AutoEQEntry] {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let words = query.lowercased().split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let scored: [(AutoEQEntry, Int)] = entries.compactMap { e in
            let hay = norm(e.name)
            guard words.allSatisfy({ hay.contains($0) }) else { return nil }
            let exact = hay == words.joined() ? 0 : (hay.hasPrefix(words[0]) ? 1 : 2)
            return (e, exact * 1000 + e.name.count)
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    func search(_ query: String) -> [AutoEQEntry] { lock.lock(); let e = entries; lock.unlock(); return Self.search(query, in: e) }

    func profile(for entry: AutoEQEntry) async throws -> HeadphoneProfile {
        let file = dir.appendingPathComponent(entry.path.replacingOccurrences(of: "/", with: "__") + ".txt")
        var text: String?
        if let d = try? Data(contentsOf: file) { text = String(data: d, encoding: .utf8) }
        if text == nil {
            var url = Self.base
            for comp in entry.path.split(separator: "/") { url.appendPathComponent(String(comp)) }
            url = url.appendingPathComponent("\(entry.path.split(separator: "/").last ?? "") ParametricEQ.txt")
            let d = try await fetcher.data(from: url)
            try? d.write(to: file)
            text = String(decoding: d, as: UTF8.self)
        }
        guard let p = AutoEQParser.parse(text ?? "", name: entry.name, source: entry.source) else { throw AureonError.message("no EQ filters found for \(entry.name)") }
        return p
    }
}

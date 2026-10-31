import Foundation

// Lyrics as Aureon holds them: lines with the time each one starts, optionally with the time of every word. They come from an .lrc file next to
// the song, from the file's own tags, or from LRCLIB (see LyricsService). This file is the data and the
// LRC reader/writer; it touches no files and no network, so everything here is plain, testable code.

/// One word (or syllable) of a line and the time it starts.
struct LyricWord: Equatable, Sendable, Codable {
    var start: Double
    var text: String
}

struct LyricLine: Equatable, Sendable, Identifiable, Codable {
    var id: Int
    /// Seconds from the start of the song.
    var time: Double
    var text: String
    /// Empty unless the source timed single words (enhanced LRC).
    var words: [LyricWord] = []

    /// An empty line marks a pause in the singing: an instrumental passage.
    var isBreak: Bool { text.isEmpty }
}

struct Lyrics: Equatable, Sendable, Codable {
    enum Origin: String, Codable, Sendable { case sidecar, embedded, online, generated }

    var lines: [LyricLine]
    /// True when the lines carry times; false for lyrics that are only text.
    var synced: Bool
    var origin: Origin
    /// Where they came from, for the panel ("Song.lrc", "file tags", "LRCLIB").
    var source: String
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var language: String? = nil

    var wordSynced: Bool { synced && lines.contains { !$0.words.isEmpty } }
    var plainText: String { lines.map(\.text).joined(separator: "\n") }
    /// No words at all (a file of timestamps and nothing else).
    var isEmpty: Bool { !lines.contains { !$0.text.isEmpty } }

    /// The line being sung at `t`: the last one that has started. Nil before the first line, and for lyrics without times.
    func activeIndex(at t: Double) -> Int? {
        guard synced, let first = lines.first, t >= first.time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// When line `i` ends: the start of the next line, or a few seconds after the last one.
    func end(ofLine i: Int) -> Double {
        guard lines.indices.contains(i) else { return 0 }
        for j in (i + 1)..<max(i + 1, lines.count) where lines[j].time > lines[i].time { return lines[j].time }
        return lines[i].time + 6
    }

    /// The end of each word of line `i`: the start of the next word, and for the last word the end of the line (at most 4 s on).
    func wordEnds(ofLine i: Int) -> [Double] {
        guard lines.indices.contains(i) else { return [] }
        let w = lines[i].words
        let lineEnd = min(end(ofLine: i), (w.last?.start ?? lines[i].time) + 4)
        return w.indices.map { k in k + 1 < w.count ? max(w[k].start, w[k + 1].start) : max(w[k].start, lineEnd) }
    }
}

// MARK: - Reading LRC

enum LRCParser {
    /// "mm:ss.xx", "m:ss", "mm:ss.xxx", the older "mm:ss:xx", and "h:mm:ss.xx". Nil for anything else (a header such as "ar:Name").
    static func timestamp(_ s: String) -> Double? { timestamp(Substring(s)) }

    static func timestamp(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        func whole(_ p: Substring, max digits: Int) -> Double? {
            guard !p.isEmpty, p.count <= digits, p.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Double(p)
        }
        func fraction(_ p: Substring) -> Double? {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Double("0." + p)
        }
        // seconds, with an optional ".fraction"
        func seconds(_ p: Substring) -> Double? {
            let bits = p.split(separator: ".", omittingEmptySubsequences: false)
            guard bits.count <= 2, let sec = whole(bits[0], max: 2) else { return nil }
            if bits.count == 2 { guard let f = fraction(bits[1]) else { return nil }; return sec + f }
            return sec
        }
        if parts.count == 2 {
            guard let m = whole(parts[0], max: 4), let s = seconds(parts[1]) else { return nil }
            return m * 60 + s
        }
        // three parts: "mm:ss:xx" (hundredths) unless the last carries a ".", then it is h:mm:ss.xx
        if parts[2].contains(".") {
            guard let h = whole(parts[0], max: 3), let m = whole(parts[1], max: 2), let s = seconds(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        }
        guard let m = whole(parts[0], max: 4), let s = whole(parts[1], max: 2), let f = fraction(parts[2]) else { return nil }
        return m * 60 + s + f
    }

    /// True when the text has timestamps on at least two lines, at least two different times.
    static func looksSynced(_ text: String) -> Bool {
        var times = Set<Double>(), lines = 0
        for raw in normalizedLines(text) {
            let stamps = leadingStamps(raw[...]).stamps
            guard !stamps.isEmpty else { continue }
            lines += 1; times.formUnion(stamps)
            if lines >= 2 && times.count >= 2 { return true }
        }
        return false
    }

    static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The `[mm:ss.xx]` tags at the start of a line (a line can carry several, for a repeated chorus) and what follows them.
    private static func leadingStamps(_ line: Substring) -> (stamps: [Double], rest: Substring) {
        var rest = line.drop(while: { $0 == " " || $0 == "\t" })
        var stamps: [Double] = []
        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            guard let t = timestamp(rest[rest.index(after: rest.startIndex)..<close]) else { break }
            stamps.append(t)
            rest = rest[rest.index(after: close)...]
        }
        return (stamps, rest)
    }

    /// "[ar:Name]" → ("ar", "Name").
    private static func header(_ line: Substring) -> (key: String, value: String)? {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix("["), l.hasSuffix("]"), let colon = l.firstIndex(of: ":") else { return nil }
        let key = l[l.index(after: l.startIndex)..<colon]
        guard !key.isEmpty, key.count <= 8, key.allSatisfy({ $0.isLetter }) else { return nil }
        return (key.lowercased(), String(l[l.index(after: colon)..<l.index(before: l.endIndex)]).trimmingCharacters(in: .whitespaces))
    }

    /// Splits a line's text at `<mm:ss.xx>` word tags (enhanced LRC). Without tags the words are empty.
    static func words(in text: Substring) -> (text: String, words: [LyricWord]) {
        var segments: [(start: Double?, text: String)] = [(nil, "")]
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "<", let close = text[i...].firstIndex(of: ">"), let t = timestamp(text[text.index(after: i)..<close]) {
                segments.append((t, "")); i = text.index(after: close); continue
            }
            segments[segments.count - 1].text.append(text[i])
            i = text.index(after: i)
        }
        let plain = segments.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard segments.count > 1 else { return (plain, []) }
        var words: [LyricWord] = []
        for s in segments where s.start != nil && !s.text.trimmingCharacters(in: .whitespaces).isEmpty { words.append(LyricWord(start: s.start!, text: s.text)) }
        // trailing space of the last word is not part of the line
        if let last = words.last { words[words.count - 1].text = last.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        return (plain, words)
    }

    /// Reads LRC text (or plain lyrics: a text without timestamps comes back unsynced).
    static func parse(_ text: String, origin: Lyrics.Origin = .sidecar, source: String = "") -> Lyrics? {
        let raw = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let all = normalizedLines(raw)
        var entries: [(time: Double, text: String, words: [LyricWord], order: Int)] = []
        var meta: [String: String] = [:]
        var ordered: [String] = []                       // every line of text in file order, for lyrics without times
        var stampedLines = 0
        for (n, line) in all.enumerated() {
            let (stamps, rest) = leadingStamps(line[...])
            if stamps.isEmpty {
                if let h = header(line[...]), ["ti", "ar", "al", "au", "by", "offset", "length", "re", "ve", "la", "lang"].contains(h.key) { meta[h.key] = h.value; continue }
                ordered.append(line.trimmingCharacters(in: .whitespaces))
                continue
            }
            stampedLines += 1
            let (t, w) = words(in: rest)
            ordered.append(t)
            for (k, s) in stamps.enumerated() { entries.append((s, t, w, n * 16 + k)) }
        }
        let distinct = Set(entries.map(\.time)).count
        var lyrics: Lyrics
        if stampedLines >= 2 && distinct >= 2 {
            // [offset:+500] shows the lines half a second sooner
            let offset = (meta["offset"].flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "+ "))) } ?? 0) / 1000
            let sorted = entries.sorted { $0.time != $1.time ? $0.time < $1.time : $0.order < $1.order }
            let lines = sorted.prefix(20_000).enumerated().map { i, e in
                LyricLine(id: i, time: max(0, e.time - offset), text: e.text,
                          words: e.words.map { LyricWord(start: max(0, $0.start - offset), text: $0.text) })
            }
            lyrics = Lyrics(lines: lines, synced: true, origin: origin, source: source)
        } else {
            // no times: the text as it is, without the header tags, one blank line between paragraphs at most
            var lines: [String] = []
            for l in ordered {
                if l.isEmpty { if let last = lines.last, !last.isEmpty { lines.append("") } } else { lines.append(l) }
            }
            while lines.last == "" { lines.removeLast() }
            guard !lines.isEmpty else { return nil }
            lyrics = Lyrics(lines: lines.prefix(20_000).enumerated().map { LyricLine(id: $0.offset, time: 0, text: $0.element) }, synced: false, origin: origin, source: source)
        }
        guard !lyrics.isEmpty else { return nil }
        lyrics.title = meta["ti"]; lyrics.artist = meta["ar"]; lyrics.album = meta["al"]
        lyrics.language = meta["la"] ?? meta["lang"]
        return lyrics
    }
}

// MARK: - Writing LRC

extension Lyrics {
    /// "mm:ss.xx", rounded to the hundredth.
    static func stamp(_ t: Double) -> String {
        let cs = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }

    /// The lyrics as LRC text (with word times as `<mm:ss.xx>` tags when `words` is true), or as plain text when they have no times.
    func lrc(words includeWords: Bool = true) -> String {
        guard synced else { return plainText }
        var out: [String] = []
        if let title { out.append("[ti:\(title)]") }
        if let artist { out.append("[ar:\(artist)]") }
        if let album { out.append("[al:\(album)]") }
        if origin == .generated, !source.isEmpty { out.append("[by:Aureon · \(source)]") }
        for l in lines {
            if includeWords, !l.words.isEmpty {
                out.append("[\(Self.stamp(l.time))]" + l.words.map { "<\(Self.stamp($0.start))>" + $0.text }.joined())
            } else {
                out.append("[\(Self.stamp(l.time))]" + l.text)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

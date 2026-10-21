import Foundation

// Reading tags from FLAC (Vorbis comments) and ALAC/AAC (MP4 "ilst" atoms), including multi-valued tags and the
// classical-music fields (composer, conductor, ensemble, performers, work, movement, opus…).
// Both parsers are synchronous, dependency-free and never decode audio.

/// Tag values keyed by a normalised name (upper-case, without spaces or underscores), each key holding every value in file order.
struct RawTags: Equatable {
    private(set) var values: [String: [String]] = [:]
    private(set) var order: [String] = []

    static func normalize(_ key: String) -> String { key.uppercased().filter { $0 != " " && $0 != "_" && $0 != "-" } }

    mutating func add(_ key: String, _ value: String) {
        let k = Self.normalize(key), v = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !v.isEmpty else { return }
        if values[k] == nil { order.append(k) }
        values[k, default: []].append(v)
    }

    func first(_ keys: String...) -> String? { for k in keys { if let v = values[Self.normalize(k)]?.first { return v } }; return nil }
    /// Every value of the first key that has any, de-duplicated, in order.
    func all(_ keys: String...) -> [String] {
        for k in keys { if let v = values[Self.normalize(k)], !v.isEmpty { var seen = Set<String>(); return v.filter { seen.insert($0).inserted } } }
        return []
    }
    /// Adds every key of `other` that this set does not have (this set wins on conflicts).
    mutating func fillMissing(from other: RawTags) {
        for k in other.order where values[k] == nil { values[k] = other.values[k]; order.append(k) }
    }

    var isEmpty: Bool { values.isEmpty }
    var keys: [String] { order }
}

enum TagReader {
    static func read(path: String) -> RawTags { readAll(path: path).tags }

    /// Tags and embedded pictures, whatever the container: FLAC (Vorbis or a leading ID3v2), MP4/ALAC, AIFF/WAV with an ID3 chunk, or a bare ID3v2 file.
    static func readAll(path: String) -> FileTags {
        switch (path as NSString).pathExtension.lowercased() {
        case "flac": return FLACMetadata.read(path: path) ?? FileTags()
        case "m4a", "mp4", "alac", "m4b": return MP4Tags.readAll(path: path) ?? FileTags()
        case "aif", "aiff", "wav", "wave", "aifc": return ID3v2.readContainer(path: path) ?? FileTags()
        default:
            // unknown extension: sniff for a leading ID3v2 tag
            if let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), let t = ID3v2.parse(d) { return t }
            return FileTags()
        }
    }
}

// MARK: - FLAC / Vorbis comments

enum VorbisTags {
    /// Parses a Vorbis-comment block body (vendor string, count, then "KEY=value" entries).
    static func parseComments(_ block: Data) -> RawTags { parseCommentsWithPictures(block).tags }

    /// Like `parseComments`, and also decodes base64 METADATA_BLOCK_PICTURE entries (the way Ogg/Opus and some FLAC taggers embed art).
    static func parseCommentsWithPictures(_ block: Data) -> FileTags {
        var t = FileTags()
        var p = block.startIndex
        func u32() -> Int? {
            guard p + 4 <= block.endIndex else { return nil }
            defer { p += 4 }
            return Int(block[p]) | Int(block[p + 1]) << 8 | Int(block[p + 2]) << 16 | Int(block[p + 3]) << 24
        }
        guard let vlen = u32(), p + vlen <= block.endIndex else { return t }
        p += vlen
        guard let count = u32() else { return t }
        for _ in 0..<min(count, 100_000) {
            guard let l = u32(), l >= 0, p + l <= block.endIndex else { break }
            if let s = String(data: block[p..<(p + l)], encoding: .utf8), let eq = s.firstIndex(of: "=") {
                let key = String(s[..<eq])
                let value = String(s[s.index(after: eq)...])
                if key.uppercased() == "METADATA_BLOCK_PICTURE" {
                    if let raw = Data(base64Encoded: value, options: .ignoreUnknownCharacters), let pic = FLACMetadata.parsePicture(raw) { t.pictures.append(pic) }
                } else { t.tags.add(key, value) }
            }
            p += l
        }
        return t
    }

    static func readFLAC(path: String) -> RawTags? { FLACMetadata.read(path: path)?.tags }
}

// MARK: - MP4 / ALAC

enum MP4Tags {
    /// Atom → canonical tag name. iTunes' classical atoms: ©wrk work, ©mvn movement name, ©mvi movement number, ©mvc movement count.
    static let atomNames: [String: String] = [
        "\u{A9}nam": "TITLE", "\u{A9}ART": "ARTIST", "aART": "ALBUMARTIST", "\u{A9}alb": "ALBUM", "\u{A9}day": "DATE",
        "\u{A9}wrt": "COMPOSER", "\u{A9}gen": "GENRE", "\u{A9}grp": "GROUPING", "\u{A9}cmt": "COMMENT", "\u{A9}lyr": "LYRICS",
        "cprt": "COPYRIGHT", "\u{A9}too": "ENCODER", "\u{A9}con": "CONDUCTOR", "\u{A9}wrk": "WORK", "\u{A9}mvn": "MOVEMENTNAME",
        "\u{A9}mvi": "MOVEMENT", "\u{A9}mvc": "MOVEMENTTOTAL", "shwm": "SHOWMOVEMENT", "soar": "ARTISTSORT", "soaa": "ALBUMARTISTSORT",
        "soco": "COMPOSERSORT", "sonm": "TITLESORT", "soal": "ALBUMSORT", "\u{A9}lyr ": "LYRICS", "tvsh": "SHOW"
    ]

    struct Box { var type: String; var body: Range<Int> }

    static func boxes(_ d: Data, in r: Range<Int>) -> [Box] {
        var out: [Box] = [], p = r.lowerBound
        func u32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        while p + 8 <= r.upperBound {
            var size = u32(p), header = 8
            let type = String(bytes: d[(p + 4)..<(p + 8)].map { $0 }, encoding: .isoLatin1) ?? ""
            if size == 1, p + 16 <= r.upperBound { size = Int(u32(p + 12)) | Int(u32(p + 8)) << 32; header = 16 }
            else if size == 0 { size = r.upperBound - p }
            guard size >= header, p + size <= r.upperBound else { break }
            out.append(Box(type: type, body: (p + header)..<(p + size)))
            p += size
        }
        return out
    }

    /// Reads the payload of a `data` atom: (data-type code, bytes).
    static func dataAtom(_ d: Data, _ b: Box) -> (type: Int, bytes: Data)? {
        guard b.body.count >= 8 else { return nil }
        let t = Int(d[b.body.lowerBound + 1]) << 16 | Int(d[b.body.lowerBound + 2]) << 8 | Int(d[b.body.lowerBound + 3])
        return (t, d.subdata(in: (b.body.lowerBound + 8)..<b.body.upperBound))
    }

    static func integer(_ bytes: Data) -> Int? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        var v = 0; for b in bytes { v = v << 8 | Int(b) }
        return v
    }

    static func parse(_ d: Data) -> RawTags { parseAll(d).tags }

    static func parseAll(_ d: Data) -> FileTags {
        var file = FileTags()
        var t: RawTags { get { file.tags } set { file.tags = newValue } }
        func descend(_ r: Range<Int>, path: [String]) {
            for b in boxes(d, in: r) {
                switch b.type {
                case "moov", "udta": descend(b.body, path: path + [b.type])
                case "meta": descend((b.body.lowerBound + 4)..<b.body.upperBound, path: path + ["meta"])      // full box: skip version/flags
                case "ilst": readItems(b.body)
                default: break
                }
            }
        }
        func readItems(_ r: Range<Int>) {
            for item in boxes(d, in: r) {
                let children = boxes(d, in: item.body)
                if item.type == "----" {
                    let mean = children.first { $0.type == "mean" }.flatMap { String(data: d.subdata(in: ($0.body.lowerBound + 4)..<$0.body.upperBound), encoding: .utf8) } ?? ""
                    guard let name = children.first(where: { $0.type == "name" }).flatMap({ String(data: d.subdata(in: ($0.body.lowerBound + 4)..<$0.body.upperBound), encoding: .utf8) }) else { continue }
                    _ = mean
                    for c in children where c.type == "data" { if let (_, bytes) = dataAtom(d, c), let s = String(data: bytes, encoding: .utf8) { t.add(name, s) } }
                    continue
                }
                for c in children where c.type == "data" {
                    guard let (type, bytes) = dataAtom(d, c) else { continue }
                    if item.type == "covr" {           // data type 13 = JPEG, 14 = PNG
                        let sniffed = EmbeddedPicture.sniffMime(bytes)
                        if !bytes.isEmpty { file.pictures.append(EmbeddedPicture(data: bytes, mime: sniffed == "application/octet-stream" ? (type == 14 ? "image/png" : "image/jpeg") : sniffed, type: 3)) }
                        continue
                    }
                    switch item.type {
                    case "trkn", "disk":
                        guard bytes.count >= 6 else { continue }
                        let n = Int(bytes[2]) << 8 | Int(bytes[3]), total = Int(bytes[4]) << 8 | Int(bytes[5])
                        let base = item.type == "trkn" ? "TRACK" : "DISC"
                        if n > 0 { t.add(base + "NUMBER", String(n)) }
                        if total > 0 { t.add(base + "TOTAL", String(total)) }
                    case "\u{A9}mvi", "\u{A9}mvc", "shwm", "tmpo", "rtng", "cpil", "pgap":
                        if let v = integer(bytes), let name = atomNames[item.type] { t.add(name, String(v)) }
                    default:
                        guard let name = atomNames[item.type] else { continue }
                        if type == 1 || type == 0, let s = String(data: bytes, encoding: .utf8) { t.add(name, s) }
                    }
                }
            }
        }
        descend(0..<d.count, path: [])
        return file
    }

    static func read(path: String) -> RawTags? { readAll(path: path)?.tags }

    static func readAll(path: String) -> FileTags? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), d.count > 16 else { return nil }
        return parseAll(d)
    }
}

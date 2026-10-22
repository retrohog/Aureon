import Foundation

// Embedded pictures and ID3v2 tags. Together with `VorbisTags` and `MP4Tags` these cover every container Aureon plays:
//   FLAC  : PICTURE blocks, base64 METADATA_BLOCK_PICTURE comments, and a *leading ID3v2 tag* (common in the wild, and it hides the "fLaC" marker)
//   ALAC  : the `covr` atom
//   AIFF/WAV : an "ID3 " chunk
// All parsers are synchronous and dependency-free; none of them decodes audio.

struct EmbeddedPicture: Equatable {
    var data: Data
    var mime: String
    /// ID3 picture type: 3 = front cover, 4 = back cover, 0 = other …
    var type: Int
    var width = 0, height = 0

    static func sniffMime(_ d: Data) -> String {
        if d.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if d.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return "application/octet-stream"
    }
}

/// Tags plus pictures read from one file.
struct FileTags {
    var tags = RawTags()
    var pictures: [EmbeddedPicture] = []

    /// The picture to show: the front cover if there is one, otherwise the biggest image.
    var bestPicture: EmbeddedPicture? {
        let usable = pictures.filter { !$0.data.isEmpty }
        func biggest(_ p: [EmbeddedPicture]) -> EmbeddedPicture? { p.max { $0.data.count < $1.data.count } }
        return biggest(usable.filter { $0.type == 3 }) ?? biggest(usable.filter { $0.type == 0 }) ?? biggest(usable)
    }
}

// MARK: - ID3v2

enum ID3v2 {
    /// Total length of an ID3v2 tag at the start of `d` (header, frames, padding and optional footer), or nil when there is none.
    static func tagLength(_ d: Data) -> Int? {
        guard d.count >= 10, d.starts(with: Data("ID3".utf8)), d[3] != 0xFF else { return nil }
        let size = syncsafe(d, 6)
        return 10 + size + (d[5] & 0x10 != 0 ? 10 : 0)
    }

    static func syncsafe(_ d: Data, _ o: Int) -> Int {
        Int(d[d.startIndex + o] & 0x7f) << 21 | Int(d[d.startIndex + o + 1] & 0x7f) << 14 | Int(d[d.startIndex + o + 2] & 0x7f) << 7 | Int(d[d.startIndex + o + 3] & 0x7f)
    }

    private static func be(_ d: Data, _ o: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 << 8 | Int(d[d.startIndex + o + $1]) } }

    /// Undoes the unsynchronisation scheme (0xFF 0x00 → 0xFF).
    static func unsynchronise(_ d: Data) -> Data {
        var out = Data(capacity: d.count), i = d.startIndex
        while i < d.endIndex {
            out.append(d[i])
            if d[i] == 0xFF, i + 1 < d.endIndex, d[i + 1] == 0 { i += 1 }
            i += 1
        }
        return out
    }

    static let v22to23 = ["TT2": "TIT2", "TP1": "TPE1", "TP2": "TPE2", "TAL": "TALB", "TRK": "TRCK", "TPA": "TPOS", "TYE": "TYER", "TCO": "TCON",
                          "TCM": "TCOM", "TP3": "TPE3", "PIC": "APIC", "TXX": "TXXX", "TT3": "TIT3", "TDA": "TDAT", "TPB": "TPUB", "TCP": "TCMP",
                          "ULT": "USLT", "SLT": "SYLT"]

    static let textFrames: [String: String] = [
        "TIT2": "TITLE", "TPE1": "ARTIST", "TPE2": "ALBUMARTIST", "TALB": "ALBUM", "TCOM": "COMPOSER", "TPE3": "CONDUCTOR", "TPE4": "REMIXER",
        "TYER": "DATE", "TDRC": "DATE", "TDRL": "RELEASEDATE", "TDOR": "ORIGINALDATE", "TORY": "ORIGINALDATE", "TPUB": "LABEL", "TIT1": "GROUPING",
        "TIT3": "SUBTITLE", "TSOP": "ARTISTSORT", "TSO2": "ALBUMARTISTSORT", "TSOA": "ALBUMSORT", "TSOT": "TITLESORT", "TSOC": "COMPOSERSORT",
        "TKEY": "KEY", "TCMP": "COMPILATION", "TSRC": "ISRC", "TENC": "ENCODEDBY", "TLAN": "LANGUAGE", "TEXT": "LYRICIST", "TMOO": "MOOD"
    ]

    static let genres80 = ["Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B",
        "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal",
        "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk",
        "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance",
        "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic",
        "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"]

    static func decodeText(_ d: Data, encoding: UInt8) -> String {
        switch encoding {
        case 1: return String(data: d, encoding: .utf16) ?? String(decoding: d, as: UTF8.self)
        case 2: return String(data: d, encoding: .utf16BigEndian) ?? ""
        case 3: return String(decoding: d, as: UTF8.self)
        default: return String(data: d, encoding: .isoLatin1) ?? ""
        }
    }

    /// Offset just past the first terminator (one byte for Latin-1/UTF-8, an aligned pair for UTF-16), or nil.
    private static func terminator(_ d: Data, from: Int, encoding: UInt8) -> (start: Int, end: Int)? {
        var i = d.startIndex + from
        if encoding == 1 || encoding == 2 {
            while i + 1 < d.endIndex { if d[i] == 0 && d[i + 1] == 0 { return (i - d.startIndex, i + 2 - d.startIndex) }; i += 2 }
        } else {
            while i < d.endIndex { if d[i] == 0 { return (i - d.startIndex, i + 1 - d.startIndex) }; i += 1 }
        }
        return nil
    }

    private static func values(_ body: Data) -> [String] {
        guard let enc = body.first else { return [] }
        return decodeText(body.dropFirst(), encoding: enc).split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
    }

    private static func genreNames(_ raw: [String]) -> [String] {
        raw.flatMap { g -> [String] in
            var s = g.trimmingCharacters(in: .whitespaces), out: [String] = []
            // "(17)" / "(17)Rock" references to the ID3v1 list
            while s.hasPrefix("("), let close = s.firstIndex(of: ")") {
                if let n = Int(s[s.index(after: s.startIndex)..<close]), n >= 0, n < genres80.count { out.append(genres80[n]) }
                s = String(s[s.index(after: close)...])
            }
            if let n = Int(s), out.isEmpty, n >= 0, n < genres80.count { return [genres80[n]] }
            if !s.isEmpty { out.append(s) }
            return out
        }
    }

    static func parse(_ file: Data) -> FileTags? {
        guard let total = tagLength(file), file.count >= 10 else { return nil }
        let version = Int(file[file.startIndex + 3]), flags = file[file.startIndex + 5]
        guard (2...4).contains(version) else { return nil }
        var body = file.subdata(in: (file.startIndex + 10)..<min(file.endIndex, file.startIndex + total))
        if flags & 0x80 != 0 && version < 4 { body = unsynchronise(body) }
        var p = 0
        if flags & 0x40 != 0, version >= 3, body.count >= 4 {        // extended header
            p = version == 4 ? syncsafe(body, 0) : be(body, 0, 4) + 4
        }
        let idLen = version == 2 ? 3 : 4, hdr = version == 2 ? 6 : 10
        var out = FileTags()
        while p + hdr <= body.count {
            if body[body.startIndex + p] == 0 { break }                    // padding
            var id = String(decoding: body[(body.startIndex + p)..<(body.startIndex + p + idLen)], as: UTF8.self)
            let size = version == 2 ? be(body, p + 3, 3) : (version == 4 ? syncsafe(body, p + 4) : be(body, p + 4, 4))
            let fflags = version == 2 ? 0 : be(body, p + 8, 2)
            let start = p + hdr
            guard size >= 0, start + size <= body.count else { break }
            var frame = body.subdata(in: (body.startIndex + start)..<(body.startIndex + start + size))
            p = start + size
            if version == 2 { id = v22to23[id] ?? id }
            if version == 3, fflags & 0x00C0 != 0 { continue }            // compressed or encrypted
            if version == 4 {
                if fflags & 0x000C != 0 { continue }
                if fflags & 0x0001 != 0, frame.count >= 4 { frame = frame.dropFirst(4) }    // data-length indicator
                if fflags & 0x0002 != 0 { frame = unsynchronise(frame) }
            }
            frame = Data(frame)
            switch id {
            case "TRCK", "TPOS":
                let base = id == "TRCK" ? "TRACK" : "DISC"
                for v in values(frame).prefix(1) {
                    let parts = v.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if let n = parts.first, !n.isEmpty { out.tags.add(base + "NUMBER", n) }
                    if parts.count > 1 { out.tags.add(base + "TOTAL", parts[1]) }
                }
            case "TCON":
                for g in genreNames(values(frame)) { out.tags.add("GENRE", g) }
            case "TXXX":
                guard let enc = frame.first, let t = terminator(frame, from: 1, encoding: enc) else { continue }
                let key = decodeText(frame.subdata(in: (frame.startIndex + 1)..<(frame.startIndex + t.start)), encoding: enc)
                for v in decodeText(frame.subdata(in: (frame.startIndex + t.end)..<frame.endIndex), encoding: enc).split(separator: "\u{0}") { out.tags.add(key, String(v)) }
            case "UFID":
                guard let z = frame.firstIndex(of: 0) else { continue }
                if String(decoding: frame[frame.startIndex..<z], as: UTF8.self).contains("musicbrainz.org") {
                    out.tags.add("MUSICBRAINZ_TRACKID", String(decoding: frame[(z + 1)...], as: UTF8.self))
                }
            case "APIC":
                if let pic = picture(frame, v22: version == 2) { out.pictures.append(pic) }
            case "USLT":
                if let text = ID3Lyrics.unsynchronised(frame) { out.tags.add("LYRICS", text) }
            case "SYLT":
                if let lrc = ID3Lyrics.synchronised(frame) { out.tags.add("SYNCEDLYRICS", lrc) }
            default:
                if let name = textFrames[id] { for v in values(frame) { out.tags.add(name, v) } }
            }
        }
        return out
    }

    private static func picture(_ f: Data, v22: Bool) -> EmbeddedPicture? {
        guard f.count > 4, let enc = f.first else { return nil }
        var p = 1, mime: String
        if v22 {
            guard f.count > 5 else { return nil }
            let fmt = String(decoding: f[(f.startIndex + 1)..<(f.startIndex + 4)], as: UTF8.self).uppercased()
            mime = fmt == "PNG" ? "image/png" : "image/jpeg"; p = 4
        } else {
            guard let t = terminator(f, from: 1, encoding: 0) else { return nil }
            mime = String(decoding: f[(f.startIndex + 1)..<(f.startIndex + t.start)], as: UTF8.self); p = t.end
        }
        guard p < f.count else { return nil }
        let type = Int(f[f.startIndex + p]); p += 1
        guard let d = terminator(f, from: p, encoding: enc), d.end <= f.count else { return nil }
        let img = f.subdata(in: (f.startIndex + d.end)..<f.endIndex)
        guard !img.isEmpty else { return nil }
        let sniffed = EmbeddedPicture.sniffMime(img)
        return EmbeddedPicture(data: img, mime: sniffed == "application/octet-stream" ? mime : sniffed, type: type)
    }

    /// Looks for an ID3 chunk inside AIFF ("ID3 ") or RIFF/WAVE ("id3 " / "ID3 ") containers.
    static func readContainer(path: String) -> FileTags? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 12), head.count == 12 else { return nil }
        let tag = String(decoding: head.prefix(4), as: UTF8.self)
        let bigEndian = tag == "FORM"
        guard bigEndian || tag == "RIFF" else { return nil }
        guard let size = (try? fh.seekToEnd()) else { return nil }
        var pos: UInt64 = 12
        while pos + 8 <= size {
            try? fh.seek(toOffset: pos)
            guard let h = try? fh.read(upToCount: 8), h.count == 8 else { return nil }
            let id = String(decoding: h.prefix(4), as: UTF8.self)
            let len = bigEndian ? be(h, 4, 4) : (0..<4).reduce(0) { $0 | Int(h[4 + $1]) << ($1 * 8) }
            if id.lowercased() == "id3 " {
                guard len > 0, len < 64 << 20, let body = try? fh.read(upToCount: len) else { return nil }
                return parse(body)
            }
            pos += 8 + UInt64(len) + UInt64(len & 1)
        }
        return nil
    }
}

// MARK: - FLAC

enum FLACMetadata {
    /// Parses a METADATA_BLOCK_PICTURE structure (FLAC PICTURE block body, also base64-embedded in Vorbis comments).
    static func parsePicture(_ b: Data) -> EmbeddedPicture? {
        var p = b.startIndex
        func u32() -> Int? {
            guard p + 4 <= b.endIndex else { return nil }
            defer { p += 4 }
            return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        }
        guard let type = u32(), let mlen = u32(), mlen >= 0, p + mlen <= b.endIndex else { return nil }
        let mime = String(decoding: b[p..<(p + mlen)], as: UTF8.self); p += mlen
        guard let dlen = u32(), dlen >= 0, p + dlen <= b.endIndex else { return nil }
        p += dlen
        guard let w = u32(), let h = u32(), u32() != nil, u32() != nil, let n = u32(), n > 0, p + n <= b.endIndex else { return nil }
        let img = Data(b[p..<(p + n)])
        let sniffed = EmbeddedPicture.sniffMime(img)
        return EmbeddedPicture(data: img, mime: sniffed == "application/octet-stream" ? mime : sniffed, type: type, width: w, height: h)
    }

    /// Reads every metadata block of a FLAC file (tags and pictures), tolerating a leading ID3v2 tag. Never touches the audio frames.
    static func read(path: String) -> FileTags? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var start: UInt64 = 0
        var id3: FileTags?
        if let head = try? fh.read(upToCount: 10), let n = ID3v2.tagLength(head) {
            start = UInt64(n)
            try? fh.seek(toOffset: 0)
            if n < 32 << 20, let all = try? fh.read(upToCount: n) { id3 = ID3v2.parse(all) }
        }
        try? fh.seek(toOffset: start)
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        var out = FileTags()
        while let h = try? fh.read(upToCount: 4), h.count == 4 {
            let last = h[0] & 0x80 != 0, type = h[0] & 0x7f
            let len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            if type == 4 || type == 6, len < 64 << 20 {
                guard let block = try? fh.read(upToCount: len), block.count == len else { break }
                if type == 4 {
                    let parsed = VorbisTags.parseCommentsWithPictures(block)
                    out.tags = parsed.tags; out.pictures += parsed.pictures
                } else if let pic = parsePicture(block) { out.pictures.append(pic) }
            } else if let off = try? fh.offset() { try? fh.seek(toOffset: off + UInt64(len)) }
            if last { break }
        }
        // an ID3 tag in front fills whatever the Vorbis block lacks
        if let id3 { out.tags.fillMissing(from: id3.tags) }
        if let id3, out.pictures.isEmpty { out.pictures = id3.pictures }
        return out
    }
}

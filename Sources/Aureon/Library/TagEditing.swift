import Foundation

// Editing the tags of the files themselves: FLAC (Vorbis comments), ALAC/AAC in MP4 (iTunes atoms) and MP3 (ID3v2.4).
//
//   • Only the fields that were edited change. Every other comment, atom or frame is copied as it was, pictures included, and the
//     audio is streamed across byte for byte, never decoded.
//   • Writes are atomic: the new file is built next to the old one, flushed to disk, and swapped in with one rename
//     (`FileManager.replaceItemAt`, which also keeps the file's permissions). A failure at any point leaves the original untouched.
//   • A file that the engine has open, or that is playing or buffered, is never replaced (`FileUse`): the write is refused with
//     `.busy` and the caller retries once the file is free. The check is repeated right before the swap.

enum TagField: String, CaseIterable, Identifiable, Codable, Sendable {
    case title, artist, album, albumArtist, composer, year, genre, trackNumber, trackTotal, discNumber
    case rgTrackGain, rgTrackPeak, rgAlbumGain, rgAlbumPeak
    /// The song's lyrics (LRC text when they are timed). Written by the lyrics page, not shown in the tag editor.
    case lyrics
    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Title"; case .artist: "Artist"; case .album: "Album"; case .albumArtist: "Album artist"; case .composer: "Composer"
        case .year: "Year"; case .genre: "Genre"; case .trackNumber: "Track"; case .trackTotal: "of"; case .discNumber: "Disc"
        case .rgTrackGain: "Track gain"; case .rgTrackPeak: "Track peak"; case .rgAlbumGain: "Album gain"; case .rgAlbumPeak: "Album peak"
        case .lyrics: "Lyrics"
        }
    }

    var isReplayGain: Bool { [.rgTrackGain, .rgTrackPeak, .rgAlbumGain, .rgAlbumPeak].contains(self) }
    /// Several values, separated by ";" in the editor.
    var isMultiValued: Bool { [.artist, .albumArtist, .composer, .genre].contains(self) }

    /// The canonical (Vorbis) key the field is written as.
    var vorbisKey: String {
        switch self {
        case .title: "TITLE"; case .artist: "ARTIST"; case .album: "ALBUM"; case .albumArtist: "ALBUMARTIST"; case .composer: "COMPOSER"
        case .year: "DATE"; case .genre: "GENRE"; case .trackNumber: "TRACKNUMBER"; case .trackTotal: "TRACKTOTAL"; case .discNumber: "DISCNUMBER"
        case .rgTrackGain: "REPLAYGAIN_TRACK_GAIN"; case .rgTrackPeak: "REPLAYGAIN_TRACK_PEAK"; case .rgAlbumGain: "REPLAYGAIN_ALBUM_GAIN"; case .rgAlbumPeak: "REPLAYGAIN_ALBUM_PEAK"
        case .lyrics: "LYRICS"
        }
    }

    /// Every key (normalised, see `RawTags.normalize`) that holds this field and must go when it is rewritten.
    var replacedKeys: Set<String> {
        let extra: [String]
        switch self {
        case .artist: extra = ["ARTISTS"]
        case .albumArtist: extra = ["ALBUMARTISTS", "ALBUM ARTIST"]
        case .year: extra = ["YEAR"]
        case .trackTotal: extra = ["TOTALTRACKS"]
        case .lyrics: extra = ["UNSYNCEDLYRICS", "SYNCEDLYRICS"]
        default: extra = []
        }
        return Set(([vorbisKey] + extra).map(RawTags.normalize))
    }
}

/// One file's values for the editable fields.
struct TagValues: Equatable, Sendable {
    var values: [TagField: String] = [:]
    subscript(_ f: TagField) -> String? { get { values[f] } set { values[f] = newValue } }

    static func from(_ t: RawTags) -> TagValues {
        var v = TagValues()
        v[.title] = t.first("TITLE")
        let artists = t.all("ARTISTS").isEmpty ? t.all("ARTIST") : t.all("ARTISTS")
        if !artists.isEmpty { v[.artist] = artists.joined(separator: "; ") }
        v[.album] = t.first("ALBUM")
        let aa = t.all("ALBUMARTISTS").isEmpty ? t.all("ALBUMARTIST") : t.all("ALBUMARTISTS")
        if !aa.isEmpty { v[.albumArtist] = aa.joined(separator: "; ") }
        let comp = t.all("COMPOSER")
        if !comp.isEmpty { v[.composer] = comp.joined(separator: "; ") }
        v[.year] = t.first("DATE", "YEAR")
        let g = t.all("GENRE")
        if !g.isEmpty { v[.genre] = g.joined(separator: "; ") }
        if let tn = t.first("TRACKNUMBER", "TRACK") {
            let parts = tn.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            v[.trackNumber] = parts.first
            if parts.count > 1, !parts[1].isEmpty { v[.trackTotal] = parts[1] }
        }
        if let tt = t.first("TRACKTOTAL", "TOTALTRACKS") { v[.trackTotal] = tt }
        if let d = t.first("DISCNUMBER", "DISC") { v[.discNumber] = d.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } }
        v[.rgTrackGain] = t.first("REPLAYGAIN_TRACK_GAIN"); v[.rgTrackPeak] = t.first("REPLAYGAIN_TRACK_PEAK")
        v[.rgAlbumGain] = t.first("REPLAYGAIN_ALBUM_GAIN"); v[.rgAlbumPeak] = t.first("REPLAYGAIN_ALBUM_PEAK")
        return v
    }
}

enum TagEditError: LocalizedError, Equatable {
    case unsupported(String), malformed(String), busy(String), io(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let s): "Cannot edit \(s)"
        case .malformed(let s): "The file's structure is damaged: \(s)"
        case .busy(let s): "In use (\(s))"
        case .io(let s): s
        }
    }
    var isBusy: Bool { if case .busy = self { return true }; return false }
}

enum TagEditing {
    static let supportedExtensions: Set<String> = ["flac", "m4a", "alac", "mp4", "m4b", "mp3"]

    static func isEditable(_ path: String) -> Bool { !RemoteMedia.isRemote(path) && supportedExtensions.contains((path as NSString).pathExtension.lowercased()) }

    static func read(path: String) -> TagValues { TagValues.from(TagReader.read(path: path)) }

    /// Splits a multi-valued field ("A; B") into its values; a single field keeps its text.
    static func values(_ f: TagField, _ s: String) -> [String] {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        return f.isMultiValued ? t.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : [t]
    }

    /// The tags as they will read after `edits` (empty text removes a field). The library uses this when only it is updated.
    static func applying(_ edits: [TagField: String], to raw: RawTags) -> RawTags {
        var gone = Set<String>()
        for f in edits.keys { gone.formUnion(f.replacedKeys) }
        var out = RawTags()
        for k in raw.keys where !gone.contains(k) { for v in raw.values[k] ?? [] { out.add(k, v) } }
        for f in TagField.allCases { if let e = edits[f] { for v in values(f, e) { out.add(f.vorbisKey, v) } } }
        return out
    }

    /// Writes `edits` into the file (empty text removes a field). Throws `.busy` while the engine holds the file.
    static func write(path: String, edits: [TagField: String]) throws {
        guard !edits.isEmpty else { return }
        guard !RemoteMedia.isRemote(path) else { throw TagEditError.unsupported("a track stored in the cloud") }
        if let r = FileUse.shared.busyReason(path) { throw TagEditError.busy(r) }
        guard FileManager.default.isWritableFile(atPath: path) else { throw TagEditError.io("No permission to change \((path as NSString).lastPathComponent)") }
        switch (path as NSString).pathExtension.lowercased() {
        case "flac": try FLACTagEditor.write(path: path, edits: edits)
        case "m4a", "alac", "mp4", "m4b": try MP4TagEditor.write(path: path, edits: edits)
        case "mp3": try ID3TagEditor.write(path: path, edits: edits)
        default: throw TagEditError.unsupported("\((path as NSString).pathExtension.uppercased()) files")
        }
    }

    // MARK: atomic replacement

    /// Builds the new file next to the original with `build`, flushes it, and swaps it in. The original survives any failure.
    static func replaceAtomically(_ path: String, build: (FileHandle) throws -> Void) throws {
        let url = URL(fileURLWithPath: path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).aureon-\(UUID().uuidString.prefix(8)).tmp")
        let fm = FileManager.default
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw TagEditError.io("Cannot create a file in \(url.deletingLastPathComponent().path)") }
        do {
            let out = try FileHandle(forWritingTo: tmp)
            do { try build(out); try out.synchronize(); try out.close() } catch { try? out.close(); throw error }
            // last look: if the engine opened the file meanwhile, keep the original and let the caller retry
            if let r = FileUse.shared.busyReason(path) { throw TagEditError.busy(r) }
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            if let e = error as? TagEditError { throw e }
            throw TagEditError.io("\((error as NSError).localizedDescription)")
        }
    }

    /// Copies `length` bytes (nil = to the end) from `offset` in `src` to `dst`, a megabyte at a time.
    static func copy(_ src: FileHandle, from offset: UInt64, length: UInt64? = nil, to dst: FileHandle) throws {
        try src.seek(toOffset: offset)
        var left = length ?? .max
        while left > 0 {
            let want = Int(min(left, 1 << 20))
            guard let chunk = try src.read(upToCount: want), !chunk.isEmpty else { break }
            try dst.write(contentsOf: chunk)
            left -= UInt64(chunk.count)
        }
        if length != nil, left > 0 { throw TagEditError.malformed("the file ended early") }
    }

    static func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
    static func le32(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
}

// MARK: - FLAC

enum FLACTagEditor {
    /// The Vorbis comment list after the edits: untouched entries keep their order and spelling, edited fields go to the end.
    static func edited(_ entries: [(String, String)], _ edits: [TagField: String]) -> [(String, String)] {
        var gone = Set<String>()
        for f in edits.keys { gone.formUnion(f.replacedKeys) }
        // "TRACKNUMBER=3/12" carries the total; keep it when only the number changes
        var keptTotal: String?
        if edits[.trackNumber] != nil, edits[.trackTotal] == nil, !entries.contains(where: { RawTags.normalize($0.0) == "TRACKTOTAL" || RawTags.normalize($0.0) == "TOTALTRACKS" }),
           let old = entries.first(where: { RawTags.normalize($0.0) == "TRACKNUMBER" })?.1, let slash = old.firstIndex(of: "/") {
            let t = old[old.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { keptTotal = t }
        }
        var out = entries.filter { !gone.contains(RawTags.normalize($0.0)) }
        for f in TagField.allCases { if let e = edits[f] { for v in TagEditing.values(f, e) { out.append((f.vorbisKey, v)) } } }
        if let keptTotal { out.append(("TRACKTOTAL", keptTotal)) }
        return out
    }

    static func parseComments(_ b: Data) -> (vendor: String, entries: [(String, String)])? {
        var p = b.startIndex
        func u32() -> Int? { guard p + 4 <= b.endIndex else { return nil }; defer { p += 4 }; return Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
        guard let vl = u32(), vl >= 0, p + vl <= b.endIndex else { return nil }
        let vendor = String(decoding: b[p..<(p + vl)], as: UTF8.self); p += vl
        guard let n = u32() else { return nil }
        var out: [(String, String)] = []
        for _ in 0..<min(n, 200_000) {
            guard let l = u32(), l >= 0, p + l <= b.endIndex else { return nil }
            let s = String(decoding: b[p..<(p + l)], as: UTF8.self); p += l
            if let eq = s.firstIndex(of: "=") { out.append((String(s[..<eq]), String(s[s.index(after: eq)...]))) }
        }
        return (vendor, out)
    }

    static func commentBlock(vendor: String, entries: [(String, String)]) -> Data {
        var d = TagEditing.le32(vendor.utf8.count) + Data(vendor.utf8) + TagEditing.le32(entries.count)
        for (k, v) in entries { let e = Data("\(k)=\(v)".utf8); d += TagEditing.le32(e.count) + e }
        return d
    }

    static func write(path: String, edits: [TagField: String]) throws {
        let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? src.close() }
        // an ID3v2 tag in front of "fLaC" (some taggers add one) is kept as it is
        let head = try src.read(upToCount: 10) ?? Data()
        let prefix = UInt64(ID3v2.tagLength(head) ?? 0)
        try src.seek(toOffset: prefix)
        guard try src.read(upToCount: 4) == Data("fLaC".utf8) else { throw TagEditError.unsupported("this file: it is not FLAC") }
        var blocks: [(type: UInt8, body: Data)] = []
        var oldMetaBytes = 0
        while true {
            guard let h = try src.read(upToCount: 4), h.count == 4 else { throw TagEditError.malformed("metadata ends early") }
            let last = h[0] & 0x80 != 0, type = h[0] & 0x7F
            let len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            guard type != 127 else { throw TagEditError.malformed("invalid metadata block") }
            guard let body = try src.read(upToCount: len), body.count == len else { throw TagEditError.malformed("a metadata block is cut short") }
            blocks.append((type, body)); oldMetaBytes += 4 + len
            if last { break }
            guard blocks.count < 4096 else { throw TagEditError.malformed("too many metadata blocks") }
        }
        guard blocks.first?.type == 0 else { throw TagEditError.malformed("STREAMINFO is not first") }
        let audioStart = try src.offset()

        let existing = blocks.first { $0.type == 4 }.flatMap { parseComments($0.body) }
        let comments = commentBlock(vendor: existing?.vendor ?? "Aureon", entries: edited(existing?.entries ?? [], edits))
        var out: [(UInt8, Data)] = []
        var placed = false
        for b in blocks where b.type != 1 {                                    // padding is rebuilt at the end
            if b.type == 4 { if !placed { out.append((4, comments)); placed = true } } else { out.append((b.type, b.body)) }
        }
        if !placed { out.insert((4, comments), at: 1) }
        // pad to the old size when the new metadata fits, so the next edit can be quick; otherwise leave room for one
        let newMeta = out.reduce(0) { $0 + 4 + $1.1.count }
        let padding = newMeta + 4 <= oldMetaBytes ? oldMetaBytes - newMeta - 4 : 4096
        out.append((1, Data(count: min(padding, (1 << 24) - 1))))

        try TagEditing.replaceAtomically(path) { dst in
            if prefix > 0 { try TagEditing.copy(src, from: 0, length: prefix, to: dst) }
            var meta = Data("fLaC".utf8)
            for (i, b) in out.enumerated() {
                guard b.1.count < 1 << 24 else { throw TagEditError.unsupported("a metadata block larger than 16 MB") }
                meta.append((i == out.count - 1 ? 0x80 : 0) | b.0)
                meta += Data([UInt8((b.1.count >> 16) & 255), UInt8((b.1.count >> 8) & 255), UInt8(b.1.count & 255)]) + b.1
            }
            try dst.write(contentsOf: meta)
            try TagEditing.copy(src, from: audioStart, to: dst)
        }
    }
}

// MARK: - MP4 (ALAC / AAC)

enum MP4TagEditor {
    struct Box { var type: String; var start: Int; var size: Int; var header: Int; var end: Int { start + size }; var body: Range<Int> { (start + header)..<end } }

    static func boxes(_ d: Data, _ r: Range<Int>) -> [Box] {
        var out: [Box] = [], p = r.lowerBound
        func u32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        while p + 8 <= r.upperBound {
            var size = u32(p), header = 8
            let type = String(bytes: d[(p + 4)..<(p + 8)], encoding: .isoLatin1) ?? "????"
            if size == 1 { guard p + 16 <= r.upperBound else { break }; size = u32(p + 8) << 32 | u32(p + 12); header = 16 }
            else if size == 0 { size = r.upperBound - p }
            guard size >= header, p + size <= r.upperBound else { break }
            out.append(Box(type: type, start: p, size: size, header: header))
            p += size
        }
        return out
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        TagEditing.be32(8 + payload.count) + Data(type.unicodeScalars.map { UInt8($0.value & 0xFF) }) + payload
    }
    static func dataAtom(_ kind: Int, _ bytes: Data) -> Data { box("data", Data([0, 0, 0, UInt8(kind)]) + TagEditing.be32(0) + bytes) }
    static func text(_ atom: String, _ values: [String]) -> Data { box(atom, values.reduce(Data()) { $0 + dataAtom(1, Data($1.utf8)) }) }
    static func freeform(_ name: String, _ value: String) -> Data {
        box("----", box("mean", TagEditing.be32(0) + Data("com.apple.iTunes".utf8)) + box("name", TagEditing.be32(0) + Data(name.utf8)) + dataAtom(1, Data(value.utf8)))
    }
    static func pair(_ atom: String, _ n: Int, _ total: Int, trailing: Bool) -> Data {
        var b = Data([0, 0, UInt8((n >> 8) & 255), UInt8(n & 255), UInt8((total >> 8) & 255), UInt8(total & 255)])
        if trailing { b += Data([0, 0]) }
        return box(atom, dataAtom(0, b))
    }

    static func atom(for f: TagField) -> String? {
        switch f {
        case .title: "\u{A9}nam"; case .artist: "\u{A9}ART"; case .album: "\u{A9}alb"; case .albumArtist: "aART"; case .composer: "\u{A9}wrt"
        case .year: "\u{A9}day"; case .genre: "\u{A9}gen"; case .trackNumber, .trackTotal: "trkn"; case .discNumber: "disk"; case .lyrics: "\u{A9}lyr"
        default: nil
        }
    }

    /// Reads a number pair (trkn / disk) from an item.
    static func readPair(_ d: Data, _ item: Box) -> (Int, Int)? {
        guard let data = boxes(d, item.body).first(where: { $0.type == "data" }), data.body.count >= 8 + 6 else { return nil }
        let b = data.body.lowerBound + 8
        return (Int(d[b + 2]) << 8 | Int(d[b + 3]), Int(d[b + 4]) << 8 | Int(d[b + 5]))
    }

    static func freeformName(_ d: Data, _ item: Box) -> String? {
        guard let n = boxes(d, item.body).first(where: { $0.type == "name" }), n.body.count >= 4 else { return nil }
        return String(decoding: d[(n.body.lowerBound + 4)..<n.body.upperBound], as: UTF8.self)
    }

    /// The new `ilst` contents: items that were not edited are copied byte for byte.
    static func editedItems(_ d: Data, _ items: [Box], _ edits: [TagField: String]) -> Data {
        var dropAtoms = Set(edits.keys.compactMap(atom(for:)))
        if edits[.genre] != nil { dropAtoms.insert("gnre") }                    // the old numeric genre would otherwise come back
        let dropNames = Set(edits.keys.filter(\.isReplayGain).map { $0.vorbisKey.lowercased() })
        var oldTrack = (0, 0), oldDisc = (0, 0)
        var out = Data()
        for it in items {
            if it.type == "trkn" { oldTrack = readPair(d, it) ?? oldTrack }
            if it.type == "disk" { oldDisc = readPair(d, it) ?? oldDisc }
            if dropAtoms.contains(it.type) { continue }
            if it.type == "----", let n = freeformName(d, it)?.lowercased(), dropNames.contains(n) { continue }
            out += d.subdata(in: it.start..<it.end)
        }
        for f in [TagField.title, .artist, .album, .albumArtist, .composer, .year, .genre, .lyrics] {
            if let e = edits[f], let a = atom(for: f) { let v = TagEditing.values(f, e); if !v.isEmpty { out += text(a, v) } }
        }
        if edits[.trackNumber] != nil || edits[.trackTotal] != nil {
            let n = edits[.trackNumber].map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 } ?? oldTrack.0
            let t = edits[.trackTotal].map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 } ?? oldTrack.1
            if n > 0 || t > 0 { out += pair("trkn", n, t, trailing: true) }
        }
        if let e = edits[.discNumber] {
            let n = Int(e.trimmingCharacters(in: .whitespaces)) ?? 0
            if n > 0 { out += pair("disk", n, oldDisc.1, trailing: false) }
        }
        for f in TagField.allCases where f.isReplayGain {
            if let e = edits[f], let v = TagEditing.values(f, e).first { out += freeform(f.vorbisKey.lowercased(), v) }
        }
        return out
    }

    /// Adds `delta` to every chunk offset (stco / co64) that points at or beyond `from`.
    static func patchOffsets(_ d: inout Data, _ r: Range<Int>, from: Int, delta: Int) throws {
        func u32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        func put32(_ o: Int, _ v: Int) { d[o] = UInt8((v >> 24) & 255); d[o + 1] = UInt8((v >> 16) & 255); d[o + 2] = UInt8((v >> 8) & 255); d[o + 3] = UInt8(v & 255) }
        for b in boxes(d, r) {
            switch b.type {
            case "trak", "mdia", "minf", "stbl", "edts", "moof", "traf": try patchOffsets(&d, b.body, from: from, delta: delta)
            case "stco":
                let n = u32(b.body.lowerBound + 4)
                guard b.body.lowerBound + 8 + n * 4 <= b.end else { throw TagEditError.malformed("chunk offset table") }
                for i in 0..<n {
                    let o = b.body.lowerBound + 8 + i * 4, v = u32(o)
                    if v >= from {
                        let nv = v + delta
                        guard nv >= 0, nv <= 0xFFFF_FFFF else { throw TagEditError.unsupported("a file this large without 64-bit chunk offsets") }
                        put32(o, nv)
                    }
                }
            case "co64":
                let n = u32(b.body.lowerBound + 4)
                guard b.body.lowerBound + 8 + n * 8 <= b.end else { throw TagEditError.malformed("chunk offset table") }
                for i in 0..<n {
                    let o = b.body.lowerBound + 8 + i * 8, v = u32(o) << 32 | u32(o + 4)
                    if v >= from { let nv = v + delta; put32(o, nv >> 32); put32(o + 4, nv & 0xFFFF_FFFF) }
                }
            default: break
            }
        }
    }

    /// The moov with one edited `udta/meta/ilst`. Some taggers add a second `udta` instead of editing the first: the items of every
    /// list are merged into the first (the first spelling of an item wins) and the later lists are dropped, so old values cannot
    /// come back from a list the reader happens to see first.
    static func rebuiltMoov(_ moov: Data, edits: [TagField: String]) throws -> Data {
        guard let top = boxes(moov, 0..<moov.count).first, top.type == "moov" else { throw TagEditError.malformed("movie box") }
        let kids = boxes(moov, top.body)
        let hdlr = box("hdlr", TagEditing.be32(0) + TagEditing.be32(0) + Data("mdir".utf8) + Data("appl".utf8) + Data(count: 9))

        func metaChildren(_ meta: Box) -> [Box] { meta.body.count >= 4 ? boxes(moov, (meta.body.lowerBound + 4)..<meta.end) : [] }
        var items: [Box] = [], seen = Set<String>()
        for u in kids where u.type == "udta" {
            for m in boxes(moov, u.body) where m.type == "meta" {
                for l in metaChildren(m) where l.type == "ilst" {
                    for it in boxes(moov, l.body) {
                        let key = it.type == "----" ? "----" + (freeformName(moov, it)?.uppercased() ?? "#\(it.start)") : it.type
                        if seen.insert(key).inserted { items.append(it) }
                    }
                }
            }
        }
        let ilst = box("ilst", editedItems(moov, items, edits))

        var placed = false
        /// A meta box with the edited list in place of its first `ilst` (or none, once the list is placed elsewhere).
        func newMeta(_ meta: Box?) -> Data {
            guard let meta, meta.body.count >= 4 else { placed = true; return box("meta", TagEditing.be32(0) + hdlr + ilst) }
            let inner = metaChildren(meta)
            var body = moov.subdata(in: meta.body.lowerBound..<(meta.body.lowerBound + 4))
            if !inner.contains(where: { $0.type == "hdlr" }) { body += hdlr }
            for b in inner {
                if b.type == "ilst" { if !placed { body += ilst; placed = true } }
                else { body += moov.subdata(in: b.start..<b.end) }
            }
            if !placed { body += ilst; placed = true }
            return box("meta", body)
        }
        func newUdta(_ udta: Box?) -> Data {
            guard let udta else { return box("udta", newMeta(nil)) }
            var body = Data()
            for b in boxes(moov, udta.body) {
                if b.type != "meta" { body += moov.subdata(in: b.start..<b.end); continue }
                if !placed { body += newMeta(b); continue }
                // a later meta: keep what else it holds, without its list
                let rest = metaChildren(b).filter { $0.type != "ilst" && $0.type != "hdlr" }
                if !rest.isEmpty { body += newMeta(b) }
            }
            if !placed { body += newMeta(nil) }
            return box("udta", body)
        }
        var body = Data()
        for b in kids {
            if b.type == "udta" {
                let u = newUdta(b)
                if u.count > 8 { body += u }                  // a udta left empty by the merge goes
            } else {
                body += moov.subdata(in: b.start..<b.end)
            }
        }
        if !placed { body += newUdta(nil) }
        return box("moov", body)
    }

    static func write(path: String, edits: [TagField: String]) throws {
        let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? src.close() }
        let fileSize = Int(try src.seekToEnd())
        // walk the top-level boxes by their headers only
        var p = 0
        var moovAt: (start: Int, size: Int)?
        while p + 8 <= fileSize {
            try src.seek(toOffset: UInt64(p))
            guard let h = try src.read(upToCount: 16), h.count >= 8 else { break }
            var size = Int(h[0]) << 24 | Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            let type = String(bytes: h[4..<8], encoding: .isoLatin1) ?? ""
            if size == 1 { guard h.count == 16 else { break }; size = (0..<8).reduce(0) { $0 << 8 | Int(h[8 + $1]) } }
            else if size == 0 { size = fileSize - p }
            guard size >= 8, p + size <= fileSize else { throw TagEditError.malformed("box \(type) runs past the end") }
            if type == "moov" { moovAt = (p, size); break }
            p += size
        }
        guard let mv = moovAt else { throw TagEditError.malformed("no movie box") }
        guard mv.size < 256 << 20 else { throw TagEditError.unsupported("a movie box this large") }
        try src.seek(toOffset: UInt64(mv.start))
        guard var moov = try src.read(upToCount: mv.size), moov.count == mv.size else { throw TagEditError.malformed("movie box cut short") }
        if moov.count >= 16, moov[0] == 0, moov[1] == 0, moov[2] == 0, moov[3] == 1 {
            // a 64-bit size header: re-express with an ordinary one so the parser sees one layout
            moov = TagEditing.be32(moov.count - 8) + moov.subdata(in: 4..<8) + moov.subdata(in: 16..<moov.count)
        }
        var newMoov = try rebuiltMoov(moov, edits: edits)
        let delta = newMoov.count - mv.size
        if delta != 0 {
            // media data after the movie box moves by delta; anything before it stays where it is
            try patchOffsets(&newMoov, 8..<newMoov.count, from: mv.start + mv.size, delta: delta)
        }
        try TagEditing.replaceAtomically(path) { dst in
            try TagEditing.copy(src, from: 0, length: UInt64(mv.start), to: dst)
            try dst.write(contentsOf: newMoov)
            try TagEditing.copy(src, from: UInt64(mv.start + mv.size), to: dst)
        }
    }
}

// MARK: - MP3 (ID3v2.4)

enum ID3TagEditor {
    static func frameID(for f: TagField) -> String? {
        switch f {
        case .title: "TIT2"; case .artist: "TPE1"; case .album: "TALB"; case .albumArtist: "TPE2"; case .composer: "TCOM"
        case .year: "TDRC"; case .genre: "TCON"; case .trackNumber, .trackTotal: "TRCK"; case .discNumber: "TPOS"; case .lyrics: "USLT"
        default: nil
        }
    }

    static func syncsafe(_ v: Int) -> Data { Data([UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]) }

    static func frame(_ id: String, _ body: Data, flags: UInt16 = 0) -> Data {
        Data(id.utf8) + syncsafe(body.count) + Data([UInt8(flags >> 8), UInt8(flags & 0xFF)]) + body
    }
    static func textFrame(_ id: String, _ values: [String]) -> Data { frame(id, Data([3]) + Data(values.joined(separator: "\u{0}").utf8)) }
    static func txxx(_ desc: String, _ value: String) -> Data { frame("TXXX", Data([3]) + Data(desc.utf8) + Data([0]) + Data(value.utf8)) }

    /// A TXXX frame's description (any text encoding).
    static func txxxDescription(_ body: Data) -> String? {
        guard let enc = body.first else { return nil }
        let rest = body.dropFirst()
        if enc == 1 || enc == 2 {
            var i = rest.startIndex
            while i + 1 < rest.endIndex { if rest[i] == 0 && rest[i + 1] == 0 { break }; i += 2 }
            return ID3v2.decodeText(Data(rest[rest.startIndex..<min(i, rest.endIndex)]), encoding: enc)
        }
        let end = rest.firstIndex(of: 0) ?? rest.endIndex
        return ID3v2.decodeText(Data(rest[rest.startIndex..<end]), encoding: enc)
    }

    /// The text of a text frame (first value).
    static func firstText(_ body: Data) -> String? {
        guard let enc = body.first else { return nil }
        return ID3v2.decodeText(Data(body.dropFirst()), encoding: enc).split(separator: "\u{0}").first.map(String.init)
    }

    /// Existing frames as ID3v2.4 frames (id, flags, body). v2.3 flags are translated; frames that cannot be carried over safely are dropped.
    static func frames(of tag: Data) -> [(id: String, flags: UInt16, body: Data)] {
        guard tag.count >= 10 else { return [] }
        let version = Int(tag[3]), flags = tag[5]
        let size = ID3v2.syncsafe(tag, 6)
        var body = tag.subdata(in: 10..<min(tag.count, 10 + size))
        if flags & 0x80 != 0 && version < 4 { body = ID3v2.unsynchronise(body) }
        var p = 0
        func be(_ o: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 << 8 | Int(body[o + $1]) } }
        if flags & 0x40 != 0, version >= 3, body.count >= 4 { p = version == 4 ? ID3v2.syncsafe(body, 0) : be(0, 4) + 4 }
        let idLen = version == 2 ? 3 : 4, hdr = version == 2 ? 6 : 10
        var out: [(String, UInt16, Data)] = []
        while p + hdr <= body.count {
            if body[p] == 0 { break }
            var id = String(decoding: body[p..<(p + idLen)], as: UTF8.self)
            let size = version == 2 ? be(p + 3, 3) : (version == 4 ? ID3v2.syncsafe(body, p + 4) : be(p + 4, 4))
            let ff = version == 2 ? 0 : UInt16(be(p + 8, 2))
            let start = p + hdr
            guard size >= 0, start + size <= body.count else { break }
            var fb = body.subdata(in: start..<(start + size))
            p = start + size
            switch version {
            case 2:
                if id == "PIC" {
                    // v2.2 picture: 3-letter image format → MIME type
                    guard fb.count > 5 else { continue }
                    let fmt = String(decoding: fb[1..<4], as: UTF8.self).uppercased()
                    fb = Data([fb[0]]) + Data((fmt == "PNG" ? "image/png" : "image/jpeg").utf8) + Data([0]) + fb.subdata(in: 4..<fb.count)
                    id = "APIC"
                } else if let mapped = ID3v2.v22to23[id] { id = mapped } else { continue }
                if id == "TYER" { id = "TDRC" }
                out.append((id, 0, fb))
            case 3:
                if ff & 0x8000 != 0 { continue }                    // "discard when the tag is altered"
                if ff & 0x00E0 != 0 { continue }                    // compressed, encrypted or grouped: cannot be re-expressed safely
                if id == "TYER" { id = "TDRC" }
                if ["TDAT", "TIME", "TRDA", "TSIZ", "EQUA", "RVAD"].contains(id) { continue }    // v2.3-only frames
                out.append((id, 0, fb))
            default:
                out.append((id, ff & 0x704F, fb))                   // kept exactly, flags included
            }
        }
        return out
    }

    /// The new tag (ID3v2.4, with padding) for the given existing tag bytes (empty when the file had none).
    static func rebuiltTag(_ old: Data, edits: [TagField: String]) -> Data {
        let existing = frames(of: old)
        var dropIDs = Set(edits.keys.compactMap(frameID(for:)))
        if edits[.year] != nil { dropIDs.formUnion(["TYER", "TDAT", "TIME"]) }
        if edits[.lyrics] != nil { dropIDs.insert("SYLT") }                          // a timed copy of the old words would contradict the new ones
        let dropDesc = Set(edits.keys.filter(\.isReplayGain).map(\.vorbisKey))
        var oldTrack: (String, String) = ("", "")
        for f in existing where f.id == "TRCK" {
            let parts = (firstText(f.body) ?? "").split(separator: "/", maxSplits: 1).map(String.init)
            oldTrack = (parts.first ?? "", parts.count > 1 ? parts[1] : "")
        }
        var oldDiscTotal = ""
        for f in existing where f.id == "TPOS" { let parts = (firstText(f.body) ?? "").split(separator: "/", maxSplits: 1).map(String.init); if parts.count > 1 { oldDiscTotal = parts[1] } }
        var body = Data()
        for f in existing {
            if dropIDs.contains(f.id) { continue }
            if f.id == "TXXX", let d = txxxDescription(f.body), dropDesc.contains(d.uppercased()) { continue }
            body += frame(f.id, f.body, flags: f.flags)
        }
        for f in [TagField.title, .artist, .album, .albumArtist, .composer, .year, .genre] {
            if let e = edits[f], let id = frameID(for: f) { let v = TagEditing.values(f, e); if !v.isEmpty { body += textFrame(id, v) } }
        }
        if edits[.trackNumber] != nil || edits[.trackTotal] != nil {
            let n = (edits[.trackNumber] ?? oldTrack.0).trimmingCharacters(in: .whitespaces), t = (edits[.trackTotal] ?? oldTrack.1).trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { body += textFrame("TRCK", [t.isEmpty ? n : "\(n)/\(t)"]) }
        }
        if let e = edits[.discNumber] {
            let n = e.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { body += textFrame("TPOS", [oldDiscTotal.isEmpty ? n : "\(n)/\(oldDiscTotal)"]) }
        }
        if let e = edits[.lyrics] {
            let text = e.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { body += frame("USLT", Data([3]) + Data("und".utf8) + Data([0]) + Data(text.utf8)) }     // UTF-8, no description
        }
        for f in TagField.allCases where f.isReplayGain {
            if let e = edits[f], let v = TagEditing.values(f, e).first { body += txxx(f.vorbisKey, v) }
        }
        body += Data(count: 2048)                                                    // padding
        return Data("ID3".utf8) + Data([4, 0, 0]) + syncsafe(body.count) + body
    }

    static func write(path: String, edits: [TagField: String]) throws {
        let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? src.close() }
        let head = try src.read(upToCount: 10) ?? Data()
        var old = Data()
        var audioStart: UInt64 = 0
        if let n = ID3v2.tagLength(head) {
            guard n < 64 << 20 else { throw TagEditError.unsupported("an ID3 tag this large") }
            try src.seek(toOffset: 0)
            old = try src.read(upToCount: n) ?? Data()
            guard old.count == n else { throw TagEditError.malformed("the ID3 tag is cut short") }
            guard (2...4).contains(Int(old[3])) else { throw TagEditError.unsupported("ID3 version 2.\(old[3])") }
            audioStart = UInt64(n)
        }
        let tag = rebuiltTag(old, edits: edits)
        try TagEditing.replaceAtomically(path) { dst in
            try dst.write(contentsOf: tag)
            try TagEditing.copy(src, from: audioStart, to: dst)
        }
    }
}

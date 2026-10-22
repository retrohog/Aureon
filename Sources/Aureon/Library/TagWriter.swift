import Foundation

// Writing tags and cover art into FLAC and MP4 (M4A, ALAC, AAC) files. The audio is never touched: only the metadata blocks / atoms are rewritten.
// Both writers work on a temporary copy and swap it in, so a failure can never leave a half-written file behind.

enum TagWriteError: Error { case notFLAC, malformed, noMoov, io(String) }

enum FLACTagWriter {
    private static func u24(_ v: Int) -> Data { Data([UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
    private static func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
    private static func le32(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }

    struct Picture { var data: Data; var mime: String; var width = 0, height = 0 }

    /// Replaces the file's Vorbis comments (and its front-cover picture, when `picture` is given) with the ones supplied. Other blocks are kept.
    static func write(path: String, comments: [(String, String)], picture: Picture? = nil, vendor: String = "Aureon") throws {
        let url = URL(fileURLWithPath: path)
        let d = try Data(contentsOf: url)
        guard d.count > 8, d.prefix(4) == Data("fLaC".utf8) else { throw TagWriteError.notFLAC }
        var pos = 4
        var blocks: [(type: UInt8, body: Data)] = []
        while true {
            guard pos + 4 <= d.count else { throw TagWriteError.malformed }
            let h = d[pos], last = h & 0x80 != 0, type = h & 0x7f
            let len = Int(d[pos + 1]) << 16 | Int(d[pos + 2]) << 8 | Int(d[pos + 3])
            guard pos + 4 + len <= d.count else { throw TagWriteError.malformed }
            blocks.append((type, d.subdata(in: (pos + 4)..<(pos + 4 + len)))); pos += 4 + len
            if last { break }
        }
        blocks.removeAll { $0.type == 4 || $0.type == 1 || ($0.type == 6 && picture != nil && $0.body.count >= 4 && Int($0.body[3]) == 3) }       // old comments, padding, the old front cover
        var vc = le32(vendor.utf8.count) + Data(vendor.utf8) + le32(comments.count)
        for (k, v) in comments { let e = Data("\(k)=\(v)".utf8); vc += le32(e.count) + e }
        blocks.insert((4, vc), at: 1)
        if let p = picture {
            let body = be32(3) + be32(p.mime.utf8.count) + Data(p.mime.utf8) + be32(0) + be32(p.width) + be32(p.height) + be32(24) + be32(0) + be32(p.data.count) + p.data
            blocks.append((6, body))
        }
        blocks.append((1, Data(count: 2048)))                                  // padding: the next edit can happen in place
        var out = Data("fLaC".utf8)
        for (i, b) in blocks.enumerated() { out.append((i == blocks.count - 1 ? 0x80 : 0) | b.type); out += u24(b.body.count) + b.body }
        out += d.subdata(in: pos..<d.count)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        do { try out.write(to: tmp); _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) } catch { try? FileManager.default.removeItem(at: tmp); throw TagWriteError.io("\(error)") }
    }
}

enum MP4TagWriter {
    private static func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
    static func box(_ type: String, _ payload: Data) -> Data { be32(8 + payload.count) + Data(type.unicodeScalars.map { UInt8($0.value & 0xFF) }) + payload }
    static func dataAtom(_ type: Int, _ bytes: Data) -> Data { box("data", Data([0, 0, 0, UInt8(type)]) + be32(0) + bytes) }
    static func text(_ atom: String, _ values: [String]) -> Data { box(atom, values.reduce(Data()) { $0 + dataAtom(1, Data($1.utf8)) }) }
    static func pair(_ atom: String, _ n: Int, _ total: Int) -> Data { box(atom, dataAtom(0, Data([0, 0, UInt8(n >> 8), UInt8(n & 255), UInt8(total >> 8), UInt8(total & 255), 0, 0]))) }
    static func freeform(_ name: String, _ values: [String]) -> Data {
        box("----", box("mean", be32(0) + Data("com.apple.iTunes".utf8)) + box("name", be32(0) + Data(name.utf8)) + values.reduce(Data()) { $0 + dataAtom(1, Data($1.utf8)) })
    }
    static func cover(_ image: Data, png: Bool) -> Data { box("covr", dataAtom(png ? 14 : 13, image)) }

    /// Tags as iTunes-style atoms. Keys: title, artist, albumArtist, album, year, genre, composer, track/trackTotal, disc/discTotal; `freeform` for the rest.
    struct Tags {
        var title: String?, artist: String?, albumArtist: String?, album: String?, year: String?, genre: String?, composer: String?, comment: String?
        var track = 0, trackTotal = 0, disc = 0, discTotal = 0
        var freeform: [(String, String)] = []
        var cover: Data?
        var coverIsPNG = false

        var atoms: [Data] {
            var a: [Data] = []
            let t = MP4TagWriter.text
            if let v = title { a.append(t("\u{A9}nam", [v])) }
            if let v = artist { a.append(t("\u{A9}ART", [v])) }
            if let v = albumArtist { a.append(t("aART", [v])) }
            if let v = album { a.append(t("\u{A9}alb", [v])) }
            if let v = year { a.append(t("\u{A9}day", [v])) }
            if let v = genre { a.append(t("\u{A9}gen", [v])) }
            if let v = composer { a.append(t("\u{A9}wrt", [v])) }
            if let v = comment { a.append(t("\u{A9}cmt", [v])) }
            if track > 0 { a.append(MP4TagWriter.pair("trkn", track, trackTotal)) }
            if disc > 0 { a.append(MP4TagWriter.pair("disk", disc, discTotal)) }
            for (k, v) in freeform { a.append(MP4TagWriter.freeform(k, [v])) }
            if let c = cover { a.append(MP4TagWriter.cover(c, png: coverIsPNG)) }
            return a
        }
    }

    /// Puts a `udta/meta/ilst` box with these atoms into the file's `moov`, replacing an existing one, and fixes the chunk offsets when media data follows.
    static func write(path: String, tags: Tags) throws {
        let url = URL(fileURLWithPath: path)
        var d = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        func put32(_ o: Int, _ v: Int) { d.replaceSubrange(o..<(o + 4), with: be32(v)) }
        func children(_ start: Int, _ end: Int) -> [(type: String, at: Int, size: Int)] {
            var out: [(String, Int, Int)] = [], p = start
            while p + 8 <= end { let size = u32(p); guard size >= 8, p + size <= end else { break }; out.append((String(decoding: d[(p + 4)..<(p + 8)], as: UTF8.self), p, size)); p += size }
            return out
        }
        let top = children(0, d.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw TagWriteError.noMoov }
        let mdatAfter = top.first(where: { $0.type == "mdat" }).map { $0.at > moov.at } ?? false
        // remove an existing udta
        var oldSize = 0
        if let u = children(moov.at + 8, moov.at + moov.size).first(where: { $0.type == "udta" }) { oldSize = u.size; d.removeSubrange(u.at..<(u.at + u.size)) }
        let hdlr = box("hdlr", be32(0) + be32(0) + Data("mdir".utf8) + Data("appl".utf8) + Data(count: 9))
        let udta = box("udta", box("meta", be32(0) + hdlr + box("ilst", tags.atoms.reduce(Data(), +))))
        let delta = udta.count - oldSize
        if mdatAfter && delta != 0 {
            func patch(_ start: Int, _ end: Int) {
                for c in children(start, end) {
                    if ["trak", "mdia", "minf", "stbl"].contains(c.type) { patch(c.at + 8, c.at + c.size) }
                    if c.type == "stco" { let n = u32(c.at + 12); for i in 0..<n { put32(c.at + 16 + i * 4, u32(c.at + 16 + i * 4) + delta) } }
                    if c.type == "co64" { let n = u32(c.at + 12); for i in 0..<n { let o = c.at + 16 + i * 8; let v = (u32(o) << 32) | u32(o + 4); let nv = v + delta; put32(o, nv >> 32); put32(o + 4, nv & 0xFFFFFFFF) } }
                }
            }
            patch(moov.at + 8, moov.at + moov.size - oldSize)
        }
        put32(moov.at, moov.size - oldSize + udta.count)
        d.insert(contentsOf: udta, at: moov.at + moov.size - oldSize)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        do { try d.write(to: tmp); _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) } catch { try? FileManager.default.removeItem(at: tmp); throw TagWriteError.io("\(error)") }
    }
}

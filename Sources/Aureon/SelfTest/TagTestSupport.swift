import Foundation

// Writers used by the tests to put genuine tags into real FLAC and ALAC files.

func le32(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }

func vorbisBlock(_ comments: [(String, String)]) -> Data {
    var b = le32(4) + Data("test".utf8) + le32(comments.count)
    for (k, v) in comments { let e = Data("\(k)=\(v)".utf8); b += le32(e.count) + e }
    return b
}

/// Replaces (or adds) the Vorbis-comment block of a FLAC file.
func injectVorbisComments(_ path: String, _ comments: [(String, String)]) {
    let d = try! Data(contentsOf: URL(fileURLWithPath: path))
    precondition(d.prefix(4) == Data("fLaC".utf8))
    var pos = 4, blocks: [(UInt8, Data)] = []
    while true {
        let h = d[pos]; let last = h & 0x80 != 0, type = h & 0x7f
        let len = Int(d[pos + 1]) << 16 | Int(d[pos + 2]) << 8 | Int(d[pos + 3])
        blocks.append((type, d.subdata(in: (pos + 4)..<(pos + 4 + len)))); pos += 4 + len
        if last { break }
    }
    blocks.removeAll { $0.0 == 4 }
    blocks.append((4, vorbisBlock(comments)))
    var out = Data("fLaC".utf8)
    for (i, b) in blocks.enumerated() {
        out.append((i == blocks.count - 1 ? 0x80 : 0) | b.0)
        out += Data([UInt8((b.1.count >> 16) & 255), UInt8((b.1.count >> 8) & 255), UInt8(b.1.count & 255)]) + b.1
    }
    try! (out + d.subdata(in: pos..<d.count)).write(to: URL(fileURLWithPath: path))
}

// MARK: MP4

func mp4Box(_ type: String, _ payload: Data) -> Data { be32(8 + payload.count) + Data(type.unicodeScalars.map { UInt8($0.value & 0xFF) }) + payload }

/// One `data` atom: type 1 = UTF-8 text, 21 = big-endian integer, 0 = binary.
func mp4Data(_ type: Int, _ bytes: Data) -> Data { mp4Box("data", Data([0, 0, 0, UInt8(type)]) + be32(0) + bytes) }
func mp4Text(_ atom: String, _ values: [String]) -> Data { mp4Box(atom, values.reduce(Data()) { $0 + mp4Data(1, Data($1.utf8)) }) }
func mp4Int16(_ atom: String, _ v: Int) -> Data { mp4Box(atom, mp4Data(21, Data([UInt8(v >> 8), UInt8(v & 255)]))) }
func mp4Pair(_ atom: String, _ n: Int, _ total: Int) -> Data { mp4Box(atom, mp4Data(0, Data([0, 0, UInt8(n >> 8), UInt8(n & 255), UInt8(total >> 8), UInt8(total & 255), 0, 0]))) }
func mp4Freeform(_ name: String, _ values: [String]) -> Data {
    mp4Box("----", mp4Box("mean", be32(0) + Data("com.apple.iTunes".utf8)) + mp4Box("name", be32(0) + Data(name.utf8)) + values.reduce(Data()) { $0 + mp4Data(1, Data($1.utf8)) })
}
/// moov/udta/meta/ilst wrapper around the given item atoms.
func mp4Tags(_ items: [Data]) -> Data { mp4Box("udta", mp4Box("meta", be32(0) + mp4Box("hdlr", Data(count: 24)) + mp4Box("ilst", items.reduce(Data(), +)))) }

/// Appends a udta box inside the moov of a real .m4a file, fixing sizes and (if moov precedes mdat) chunk offsets.
func injectMP4Tags(_ path: String, items: [Data]) {
    var d = try! Data(contentsOf: URL(fileURLWithPath: path))
    func u32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
    func put32(_ o: Int, _ v: Int) { d.replaceSubrange(o..<(o + 4), with: be32(v)) }
    var p = 0, moov = -1, mdat = -1
    while p + 8 <= d.count {
        let size = u32(p), type = String(decoding: d[(p + 4)..<(p + 8)], as: UTF8.self)
        if type == "moov" { moov = p }; if type == "mdat" { mdat = p }
        p += max(size, 8)
    }
    precondition(moov >= 0, "no moov")
    let udta = mp4Tags(items), moovSize = u32(moov)
    // patch chunk offsets when media data sits after the moov box (it moves by udta.count)
    if mdat > moov {
        func patch(_ start: Int, _ end: Int) {
            var q = start
            while q + 8 <= end {
                let size = u32(q), type = String(decoding: d[(q + 4)..<(q + 8)], as: UTF8.self)
                if ["trak", "mdia", "minf", "stbl"].contains(type) { patch(q + 8, q + size) }
                if type == "stco" { let n = u32(q + 12); for i in 0..<n { put32(q + 16 + i * 4, u32(q + 16 + i * 4) + udta.count) } }
                if type == "co64" { let n = u32(q + 12); for i in 0..<n { let o = q + 16 + i * 8; let v = (u32(o) << 32) | u32(o + 4); let nv = v + udta.count
                    put32(o, nv >> 32); put32(o + 4, nv & 0xFFFFFFFF) } }
                q += max(size, 8)
            }
        }
        patch(moov + 8, moov + moovSize)
    }
    put32(moov, moovSize + udta.count)
    d.insert(contentsOf: udta, at: moov + moovSize)
    try! d.write(to: URL(fileURLWithPath: path))
}

func runTool(_ exe: String, _ args: [String]) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = Pipe(); p.standardError = Pipe()
    do { try p.run() } catch { return false }
    p.waitUntilExit(); return p.terminationStatus == 0
}

/// Encodes a WAV to FLAC or ALAC (.m4a) with macOS's afconvert.
func encode(_ wav: URL, to out: URL, alac: Bool) -> Bool {
    runTool("/usr/bin/afconvert", alac ? ["-f", "m4af", "-d", "alac", wav.path, out.path] : ["-f", "flac", "-d", "flac", wav.path, out.path])
}

/// Adds a PICTURE block (type 6) with the given image bytes to a FLAC file.
func injectFLACPicture(_ path: String, image: Data, mime: String = "image/png") {
    let d = try! Data(contentsOf: URL(fileURLWithPath: path))
    var pos = 4, blocks: [(UInt8, Data)] = []
    while true {
        let h = d[pos]; let last = h & 0x80 != 0, type = h & 0x7f
        let len = Int(d[pos + 1]) << 16 | Int(d[pos + 2]) << 8 | Int(d[pos + 3])
        blocks.append((type, d.subdata(in: (pos + 4)..<(pos + 4 + len)))); pos += 4 + len
        if last { break }
    }
    blocks.removeAll { $0.0 == 6 }
    blocks.append((6, be32(3) + be32(mime.utf8.count) + Data(mime.utf8) + be32(0) + be32(64) + be32(64) + be32(24) + be32(0) + be32(image.count) + image))
    var out = Data("fLaC".utf8)
    for (i, b) in blocks.enumerated() {
        out.append((i == blocks.count - 1 ? 0x80 : 0) | b.0)
        out += Data([UInt8((b.1.count >> 16) & 255), UInt8((b.1.count >> 8) & 255), UInt8(b.1.count & 255)]) + b.1
    }
    try! (out + d.subdata(in: pos..<d.count)).write(to: URL(fileURLWithPath: path))
}

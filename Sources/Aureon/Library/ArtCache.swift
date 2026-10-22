import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Cover art, extracted once. Reading a cover out of an audio file means parsing its tags (and, for some containers, falling back to AVFoundation) and
/// decoding a picture that can be several megapixels. This cache does that a single time per cover and keeps small derived files in the user's Caches
/// folder: a thumbnail for grids and lists, a larger picture for Now Playing and the colour palette worked out from it. Every later launch loads
/// those few-kilobyte files instead of touching the audio files.
///
/// Layout (all of it can be deleted at any time; it is rebuilt on demand):
///   ptr/xx/<sha256 of the source>   names the picture a source (an album, a file) resolves to, or "-" when it has no cover
///   img/<sha256 of the picture bytes>.t.jpg | .l.jpg | .pal      thumbnail, large picture, palette — shared by every source with the same picture
///
/// A source's identity includes what makes its cover change (an album carries the newest modification time of its files, a file its own time and size),
/// so editing a cover simply makes a new source and the old entry ages out.
final class ArtCache: @unchecked Sendable {
    static let thumbPixels = 384
    static let largePixels = 1200
    /// How long "this has no cover" is believed before the sources are tried again (a cover may have been fetched online meanwhile).
    static let negativeLifetime: TimeInterval = 12 * 3600

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Artwork", isDirectory: true)
    }
    static let shared = ArtCache(root: ArtCache.defaultRoot)

    /// What a cover is looked up by.
    struct Source: Hashable, Sendable {
        let token: String
        static func album(id: String, stamp: Double) -> Source { Source(token: "album|\(id)|\(Int64(stamp * 1000))") }
        static func file(path: String, mtime: Double, size: Int64) -> Source { Source(token: "file|\(path)|\(Int64(mtime * 1000))|\(size)") }
        static func url(_ u: String) -> Source { Source(token: "url|\(u)") }
        static func fetched(artist: String, album: String) -> Source { Source(token: "fetched|\(artist.lowercased())|\(album.lowercased())") }
        /// A local file as it is now (nil when it cannot be read).
        static func localFile(_ path: String) -> Source? {
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            return .file(path: path, mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9, size: Int64(st.st_size))
        }
    }

    enum Lookup: Equatable {
        case hit(String)          // the picture's hash
        case empty                // known to have no cover (recently)
        case miss                 // not in the cache
    }

    /// A cover ready for the interface.
    struct Loaded {
        var hash: String
        var picture: CGImage
        var palette: ArtPalette
    }

    let root: URL
    private let lock = NSLock()
    private var stored = 0

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
    }

    /// How many covers have been extracted into the cache by this instance (tests and timings).
    var extractions: Int { lock.lock(); defer { lock.unlock() }; return stored }

    private var imgDir: URL { root.appendingPathComponent("v1/img", isDirectory: true) }
    private func pointerURL(_ s: Source) -> URL {
        let h = Self.sha(Data(s.token.utf8))
        return root.appendingPathComponent("v1/ptr/\(h.prefix(2))/\(h)")
    }
    private func file(_ hash: String, _ ext: String) -> URL { imgDir.appendingPathComponent("\(hash).\(ext)") }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).prefix(16).map { String(format: "%02x", $0) }.joined() }

    // MARK: lookup

    func lookup(_ s: Source, now: Date = Date()) -> Lookup {
        let url = pointerURL(s)
        guard let d = try? Data(contentsOf: url), let text = String(data: d, encoding: .utf8) else { return .miss }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let written = (attrs?[.modificationDate] as? Date) ?? .distantPast
        if text == "-" { return now.timeIntervalSince(written) < Self.negativeLifetime ? .empty : .miss }
        guard FileManager.default.fileExists(atPath: file(text, "t.jpg").path) else { return .miss }
        if now.timeIntervalSince(written) > 24 * 3600 {                // what is in use stays: trimming removes the least recently used
            for u in [url, file(text, "t.jpg"), file(text, "l.jpg"), file(text, "pal")] { try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: u.path) }
        }
        return .hit(text)
    }

    // MARK: reading

    func thumbnail(_ hash: String) -> CGImage? { decode(file(hash, "t.jpg"), maxPixel: Self.thumbPixels) }
    func large(_ hash: String) -> CGImage? { decode(file(hash, "l.jpg"), maxPixel: Self.largePixels) }

    private func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return ImageTools.cgImage(d, maxPixel: maxPixel)
    }

    func palette(_ hash: String) -> ArtPalette? {
        guard let d = try? Data(contentsOf: file(hash, "pal")), let v = try? JSONDecoder().decode([Double].self, from: d), v.count == 30 else { return nil }
        func rgb(_ i: Int) -> RGB { RGB(v[i * 3], v[i * 3 + 1], v[i * 3 + 2]) }
        return ArtPalette(grid: (0..<9).map(rgb), accent: rgb(9))
    }

    /// The Now Playing picture and its palette for a source already in the cache.
    func loaded(_ s: Source) -> Loaded? {
        guard case .hit(let h) = lookup(s) else { return nil }
        return loaded(hash: h)
    }

    func loaded(hash h: String) -> Loaded? {
        guard let pic = large(h) else { return nil }
        if let p = palette(h) { return Loaded(hash: h, picture: pic, palette: p) }
        let p = ArtPalette.extract(from: pic)                      // an entry written without its palette: derive it once more
        writePalette(p, hash: h)
        return Loaded(hash: h, picture: pic, palette: p)
    }

    // MARK: writing

    /// Writes both sizes and the palette for a picture (once per distinct picture) and points `s` at them. Returns the picture's hash, nil if the bytes are no image.
    @discardableResult
    func store(_ s: Source, data: Data) -> String? {
        let hash = Self.sha(data)
        if !FileManager.default.fileExists(atPath: file(hash, "t.jpg").path) || !FileManager.default.fileExists(atPath: file(hash, "pal").path) {
            guard let cg = ImageTools.cgImage(data, maxPixel: Self.largePixels), let big = Self.jpeg(cg, quality: 0.88),
                  let small = Artwork.thumbnail(big, maxPixel: Self.thumbPixels, quality: 0.82) else { return nil }
            do {
                try big.write(to: file(hash, "l.jpg"), options: .atomic)
                writePalette(ArtPalette.extract(from: cg), hash: hash)
                try small.write(to: file(hash, "t.jpg"), options: .atomic)          // written last: its presence means the entry is complete
            } catch { return nil }
            lock.lock(); stored += 1; lock.unlock()
        }
        writePointer(s, hash)
        return hash
    }

    /// Remembers that a source has no cover, so it is not opened again for a while.
    func storeNone(_ s: Source) { writePointer(s, "-") }

    /// Stores the bytes and loads what the Now Playing view needs.
    func ingest(_ s: Source, data: Data) -> Loaded? {
        guard let h = store(s, data: data) else { return nil }
        return loaded(hash: h)
    }

    private func writePointer(_ s: Source, _ text: String) {
        let url = pointerURL(s)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private func writePalette(_ p: ArtPalette, hash: String) {
        let v = (p.grid + [p.accent]).flatMap { [$0.r, $0.g, $0.b] }
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: file(hash, "pal"), options: .atomic) }
    }

    static func jpeg(_ cg: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    // MARK: housekeeping

    /// Total size of the cache in bytes.
    func size() -> Int {
        var n = 0
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) { for case let u as URL in e { n += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 } }
        return n
    }

    /// Deletes the least recently used entries until the cache is below `maxBytes` (and under 80 % of it, so it is not trimmed again at once).
    @discardableResult
    func trim(maxBytes: Int = 512 << 20) -> Int {
        guard size() > maxBytes else { return 0 }
        var items: [(url: URL, date: Date, bytes: Int)] = []
        var total = 0
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) {
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                items.append((u, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)); total += v.fileSize ?? 0
            }
        }
        var removed = 0
        for it in items.sorted(by: { $0.date < $1.date }) {
            if total <= maxBytes * 8 / 10 { break }
            if (try? FileManager.default.removeItem(at: it.url)) != nil { total -= it.bytes; removed += 1 }
        }
        return removed
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("v1"))
        try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
    }
}

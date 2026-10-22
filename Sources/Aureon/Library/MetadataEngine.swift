import Foundation
import AVFoundation
import ImageIO
import AppKit

/// What the interface needs to know about a file, whatever its container.
struct TrackTags: Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?, trackTotal: Int?
    var discNumber: Int?
    var picture: EmbeddedPicture?
    /// Where the values came from: our own parsers, or AVFoundation filling gaps.
    var usedFallback = false

    var isEmpty: Bool { title == nil && artist == nil && album == nil && picture == nil }
    /// "Artist" the way a player shows it: track artist, else album artist.
    var displayArtist: String? { artist ?? albumArtist }
}

/// Reads tags and the embedded cover of a file.
///
/// Order of attack: Aureon's own parsers (Vorbis comments, ID3v2, MP4 atoms — they see everything, including classical fields and
/// pictures hidden behind a leading ID3 tag), then AVFoundation for whatever is still missing. TagLib is deliberately not used:
/// a C++ dependency would complicate the build for no gain over parsers that are tested against real files.
enum MetadataEngine {
    /// A small local file holding the tags of a cloud track (its first bytes, or the MP4 tag boxes), for the parsers that read paths.
    static func tagStub(for path: String) -> URL? {
        guard CloudPath.isCloud(path), let r = try? CloudRegistry.shared.reader(for: path, config: stubConfig) else { return nil }
        return try? RemoteTags.materialize(r, fileExtension: (path as NSString).pathExtension, into: FileManager.default.temporaryDirectory.appendingPathComponent("aureon-cloud-tags", isDirectory: true))
    }
    private static var stubConfig: ChunkedReader.Config { var c = ChunkedReader.Config(); c.chunkSize = 256 << 10; c.defaultAhead = 1; c.minAhead = 1; return c }

    static func load(path: String) async -> TrackTags {
        if SubsonicPath.isSubsonic(path) || LMSPath.isLMS(path) { return TrackTags() }                 // a server's tags come with its listing
        if CloudPath.isCloud(path) {
            guard let stub = await Task.detached(operation: { tagStub(for: path) }).value else { return TrackTags() }
            defer { try? FileManager.default.removeItem(at: stub) }
            return native(path: stub.path)
        }
        var t = native(path: path)
        let ext = (path as NSString).pathExtension.lowercased()
        guard !["dsf", "dff"].contains(ext) else { return t }
        // only ask AVFoundation when something is still missing: it is the slow path
        if t.title == nil || t.artist == nil || t.album == nil || t.picture == nil || t.year == nil || t.genre == nil || t.trackNumber == nil {
            if await fillFromAVFoundation(&t, path: path) { t.usedFallback = true }
        }
        return t
    }

    static func native(path: String) -> TrackTags {
        let file = TagReader.readAll(path: path)
        let m = TagInterpreter.interpret(file.tags)
        func names(_ role: CreditRole) -> String? { let n = m.credits(role).map(\.name); return n.isEmpty ? nil : n.joined(separator: ", ") }
        return TrackTags(title: m.title, artist: names(.artist), albumArtist: names(.albumArtist), album: m.album, composer: names(.composer),
                         genre: m.genres.isEmpty ? nil : m.genres.joined(separator: ", "), year: m.year,
                         trackNumber: m.trackNumber, trackTotal: m.trackTotal, discNumber: m.discNumber, picture: file.bestPicture)
    }

    /// Fills the gaps in `t` from AVFoundation. Returns whether it added anything.
    @discardableResult
    static func fillFromAVFoundation(_ t: inout TrackTags, path: String) async -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let items = ((try? await asset.load(.commonMetadata)) ?? []) + ((try? await asset.load(.metadata)) ?? [])
        var changed = false
        for it in items {
            let id = (it.identifier?.rawValue ?? "").uppercased(), common = it.commonKey?.rawValue
            func str() async -> String? {
                guard let s = try? await it.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
                return s
            }
            if t.title == nil, common == "title" || id.hasSuffix("/TITLE") || id.hasSuffix("/TIT2") || id.hasSuffix("/NAM") { if let s = await str() { t.title = s; changed = true } }
            else if t.artist == nil, common == "artist" || id.hasSuffix("/ARTIST") || id.hasSuffix("/TPE1") || id.hasSuffix("/ART") { if let s = await str() { t.artist = s; changed = true } }
            else if t.album == nil, common == "albumName" || id.hasSuffix("/ALBUM") || id.hasSuffix("/TALB") || id.hasSuffix("/ALB") { if let s = await str() { t.album = s; changed = true } }
            else if t.genre == nil, id.hasSuffix("/GENRE") || id.hasSuffix("/TCON") || id.hasSuffix("/GEN") { if let s = await str() { t.genre = s; changed = true } }
            else if t.composer == nil, id.hasSuffix("/COMPOSER") || id.hasSuffix("/TCOM") || id.hasSuffix("/WRT") { if let s = await str() { t.composer = s; changed = true } }
            else if t.year == nil, common == "creationDate" || id.hasSuffix("/DATE") || id.hasSuffix("/TYER") || id.hasSuffix("/TDRC") || id.hasSuffix("/DAY") {
                if let s = await str(), s.count >= 4, let y = Int(s.prefix(4)) { t.year = y; changed = true }
            }
            else if t.trackNumber == nil, id.hasSuffix("/TRACKNUMBER") || id.hasSuffix("/TRCK") {
                if let s = await str() {
                    let parts = s.split(separator: "/"); t.trackNumber = Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? "")
                    if parts.count > 1 { t.trackTotal = Int(parts[1].trimmingCharacters(in: .whitespaces)) }
                    changed = changed || t.trackNumber != nil
                }
            }
            else if t.picture == nil, common == "artwork" || id.hasSuffix("PICTURE") || id.hasSuffix("/APIC") || id.hasSuffix("/COVR") {
                if let d = try? await it.load(.dataValue), !d.isEmpty, ImageTools.isImage(d) { t.picture = EmbeddedPicture(data: d, mime: EmbeddedPicture.sniffMime(d), type: 3); changed = true }
            }
        }
        return changed
    }

    /// Just the picture bytes (native first, AVFoundation second).
    static func artwork(path: String) async -> Data? {
        if SubsonicPath.isSubsonic(path) { return await Task.detached { SubsonicRegistry.shared.coverArt(for: path) }.value }
        if LMSPath.isLMS(path) { return await Task.detached { LMSRegistry.shared.coverArt(for: path) }.value }
        if CloudPath.isCloud(path) {
            guard let stub = await Task.detached(operation: { tagStub(for: path) }).value else { return nil }
            defer { try? FileManager.default.removeItem(at: stub) }
            return TagReader.readAll(path: stub.path).bestPicture?.data
        }
        if let p = TagReader.readAll(path: path).bestPicture { return p.data }
        var t = TrackTags()
        await fillFromAVFoundation(&t, path: path)
        return t.picture?.data
    }
}

enum ImageTools {
    static func isImage(_ d: Data) -> Bool { CGImageSourceCreateWithData(d as CFData, nil).map { CGImageSourceGetCount($0) > 0 } ?? false }

    static func size(_ d: Data) -> (Int, Int)? {
        guard let s = CGImageSourceCreateWithData(d as CFData, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Decodes at most `maxPixel` on the longest side without ever materialising the full-size bitmap.
    static func cgImage(_ d: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                                           kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func nsImage(_ d: Data, maxPixel: Int) -> NSImage? {
        guard let cg = cgImage(d, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

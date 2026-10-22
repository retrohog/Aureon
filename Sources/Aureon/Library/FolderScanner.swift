import Foundation
import CoreServices

// Reading folders straight from the disk, for the Folders page: no tags, no database, no import.
//
//   • A listing is one `contentsOfDirectory` call with the attributes prefetched in bulk, so a folder of 50 000 files is listed in a fraction
//     of a second, always on a background queue.
//   • Symbolic links are listed as what they point at, flagged, and checked for loops (a link to one of its own ancestors).
//   • A recursive walk (to play a whole folder tree) follows linked folders once each, by device and inode, so a loop can never run away.

/// One entry of a directory listing.
struct FolderEntry: Identifiable, Hashable, Sendable {
    enum Kind: Int, Sendable { case folder, audio, booklet, image, other }
    /// The address as listed (for a symbolic link: the link itself).
    let url: URL
    let name: String
    let kind: Kind
    let isSymlink: Bool
    /// Where a symbolic link leads, fully resolved; nil for a broken link. For other entries, the entry itself.
    let target: URL?
    let size: Int64
    let modified: Date?
    var id: String { url.path }
    var isBroken: Bool { isSymlink && target == nil }
    var isPlayable: Bool { kind == .audio && FolderScanner.playableExtensions.contains(url.pathExtension.lowercased()) }
    var isTaggable: Bool { kind == .audio && TagEditing.supportedExtensions.contains(url.pathExtension.lowercased()) }
}

enum FolderScanner {
    /// Everything the player decodes.
    static var playableExtensions: Set<String> { audioExtensions }
    /// Audio shown in the browser: what plays, plus MP3, whose tags can be edited.
    static var listedAudioExtensions: Set<String> { audioExtensions.union(["mp3"]) }
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "tif", "tiff", "heic", "webp"]

    static func kind(of url: URL, isDirectory: Bool) -> FolderEntry.Kind {
        if isDirectory { return .folder }
        let ext = url.pathExtension.lowercased()
        if listedAudioExtensions.contains(ext) { return .audio }
        if ext == "pdf" { return .booklet }
        if imageExtensions.contains(ext) { return .image }
        return .other
    }

    /// Folders first, then files, each in Finder order ("Track 2" before "Track 10").
    static func ordered(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        let af = a.kind == .folder, bf = b.kind == .folder
        if af != bf { return af }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Lists one folder. Hidden files are skipped. Never call on the main thread: it touches the disk.
    static func list(_ dir: URL, includeHidden: Bool = false, cancelled: () -> Bool = { false }) throws -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: includeHidden ? [] : [.skipsHiddenFiles])
        var out: [FolderEntry] = []
        out.reserveCapacity(urls.count)
        for (i, u) in urls.enumerated() {
            if i & 1023 == 0, cancelled() { throw CancellationError() }
            let v = try? u.resourceValues(forKeys: Set(keys))
            let link = v?.isSymbolicLink ?? false
            var isDir = v?.isDirectory ?? false
            var target: URL? = u
            var size = Int64(v?.fileSize ?? 0)
            var modified = v?.contentModificationDate
            if link {
                // the attributes above describe the link; the entry shows what it points at
                var d: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &d) {
                    isDir = d.boolValue
                    target = realPath(u)
                    let tv = try? target?.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    size = Int64(tv?.fileSize ?? 0); modified = tv?.contentModificationDate
                } else { target = nil; isDir = false }
            }
            out.append(FolderEntry(url: u, name: v?.name ?? u.lastPathComponent, kind: kind(of: u, isDirectory: isDir), isSymlink: link, target: target, size: size, modified: modified))
        }
        out.sort(by: ordered)
        return out
    }

    /// True when `entry` is a link to a folder that already contains it (following it would go round in circles).
    static func isLoop(_ entry: FolderEntry, ancestors: [String]) -> Bool {
        guard entry.isSymlink, entry.kind == .folder, let target = entry.target else { return false }
        // compare one spelling: standardizing drops /private from /private/var and /private/tmp on either side
        let t = target.standardizedFileURL.path
        let prefix = t.hasSuffix("/") ? t : t + "/"
        return ancestors.contains { raw in
            let a = URL(fileURLWithPath: raw).standardizedFileURL.path
            return a == t || a.hasPrefix(prefix)
        }
    }

    /// Every playable file under `dir` in playing order (each folder's files, then its subfolders, all in Finder order).
    /// Linked folders are followed once each; `limit` bounds the result. Never call on the main thread.
    static func audioFiles(under dir: URL, recursive: Bool = true, limit: Int = 100_000, cancelled: () -> Bool = { false }) -> [URL] {
        var out: [URL] = []
        var seen = Set<FileIdentity>()
        func walk(_ d: URL, depth: Int) {
            guard out.count < limit, depth < 64, !cancelled(), let id = FileIdentity(path: d.path), seen.insert(id).inserted else { return }
            guard let entries = try? list(d, cancelled: cancelled) else { return }
            for e in entries where e.isPlayable && !e.isBroken {
                out.append(e.url)
                if out.count >= limit { return }
            }
            guard recursive else { return }
            for e in entries where e.kind == .folder && !e.isBroken { walk(e.url, depth: depth + 1) }
        }
        walk(dir, depth: 0)
        return out
    }

    /// The PDF booklets that sit in `dir` (and in a "Scans"/"Artwork"/"Booklet" subfolder), largest first.
    static func booklets(in dir: URL) -> [URL] {
        var found: [URL] = []
        func scan(_ d: URL) { for e in (try? list(d)) ?? [] where e.kind == .booklet && !e.isBroken { found.append(e.url) } }
        scan(dir)
        for e in (try? list(dir)) ?? [] where e.kind == .folder && BookletIndex.extrasFolders.contains(e.name.lowercased()) { scan(e.url) }
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        // "Digital Booklet - Album.pdf" (iTunes) and anything called booklet first, then by size
        func rank(_ u: URL) -> Int { u.lastPathComponent.lowercased().contains("booklet") ? 0 : 1 }
        return found.sorted { (rank($0), -size($0)) < (rank($1), -size($1)) }
    }
}

/// A file's device and inode: the same folder reached through two paths is recognised as one.
struct FileIdentity: Hashable, Sendable {
    let device: UInt64, inode: UInt64
    init?(path: String) {
        var s = stat()
        guard stat(path, &s) == 0 else { return nil }
        device = UInt64(s.st_dev); inode = UInt64(s.st_ino)
    }
}

/// Watches folders for changes with FSEvents and reports the folders whose contents changed, on the main queue.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "aureon.folderwatch", qos: .utility)
    private let onChange: ([String]) -> Void

    init(onChange: @escaping ([String]) -> Void) { self.onChange = onChange }
    deinit { stop() }

    func watch(_ paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, pathsPtr, _, _ in
            guard let info else { return }
            let report = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange
            let cfArray = Unmanaged<CFArray>.fromOpaque(pathsPtr).takeUnretainedValue()
            var changed: [String] = []
            for i in 0..<count {
                if let s = CFArrayGetValueAtIndex(cfArray, i) { changed.append(Unmanaged<CFString>.fromOpaque(s).takeUnretainedValue() as String) }
            }
            let trimmed = changed.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
            DispatchQueue.main.async { report(trimmed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }
}

import Foundation
import CryptoKit

// Cloud libraries: a profile says where the bucket is, the Keychain holds the secret key, and tracks that live in the bucket carry a
// `cloud://<profile>/<key>` path in the library, so everything else (queue, Auto-playlists, likes, loudness …) treats them like files.

enum CloudProvider: String, Codable, CaseIterable, Identifiable {
    case backblaze, aws, r2, wasabi, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .backblaze: "Backblaze B2"; case .aws: "Amazon S3"; case .r2: "Cloudflare R2"; case .wasabi: "Wasabi"; case .custom: "Other S3-compatible (MinIO …)" }
    }
    func endpoint(region: String, account: String = "") -> String {
        switch self {
        case .backblaze: "https://s3.\(region).backblazeb2.com"
        case .aws: "https://s3.\(region).amazonaws.com"
        case .r2: "https://\(account).r2.cloudflarestorage.com"
        case .wasabi: "https://s3.\(region).wasabisys.com"
        case .custom: ""
        }
    }
    var regionHint: String {
        switch self { case .backblaze: "us-west-004 (shown in the bucket's endpoint)"; case .aws: "us-east-1"; case .r2: "auto"; case .wasabi: "us-east-1"; case .custom: "us-east-1" }
    }
}

struct CloudProfile: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString.prefix(8).lowercased().description
    var name = ""
    var provider = CloudProvider.backblaze
    var endpoint = ""
    var region = ""
    var bucket = ""
    var prefix = ""
    var accessKey = ""
    var pathStyle = true

    var config: S3Config? {
        guard let u = URL(string: endpoint), u.scheme?.hasPrefix("http") == true, u.host != nil, !bucket.isEmpty else { return nil }
        return S3Config(endpoint: u, region: region.isEmpty ? "us-east-1" : region, bucket: bucket, pathStyle: pathStyle, prefix: prefix)
    }
    var secretAccount: String { "cloud.\(id)" }
}

enum CloudPath {
    static let scheme = "cloud://"
    static func make(profile: String, key: String) -> String { scheme + profile + "/" + key }
    static func isCloud(_ path: String) -> Bool { path.hasPrefix(scheme) }
    static func parse(_ path: String) -> (profile: String, key: String)? {
        guard isCloud(path) else { return nil }
        let rest = path.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let key = String(rest[rest.index(after: slash)...])
        return key.isEmpty ? nil : (String(rest[..<slash]), key)
    }
}

enum Blocking {
    /// Runs an async operation to completion on the calling (non-main, non-realtime) thread.
    static func run<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
        let box = AsyncBox<T>(), sem = DispatchSemaphore(value: 0)
        Task.detached { do { box.result = .success(try await op()) } catch { box.result = .failure(error) }; sem.signal() }
        sem.wait()
        return try box.result!.get()
    }
}

final class CloudRegistry: @unchecked Sendable {
    static let shared = CloudRegistry()

    var secrets: SecretStore = KeychainSecretStore()
    var http: HTTPClient = S3HTTP.shared
    /// Where the profile list is kept (defaults); tests point it elsewhere.
    var defaults = UserDefaults.standard
    var playbackConfig = ChunkedReader.Config()

    private let lock = NSLock()
    private var readers: [(path: String, reader: ChunkedReader, size: Int64)] = []
    private var sizes: [String: Int64] = [:]
    private let keep = 4

    // MARK: profiles

    var profiles: [CloudProfile] {
        get { (defaults.data(forKey: "aureon.cloud.profiles").flatMap { try? JSONDecoder().decode([CloudProfile].self, from: $0) }) ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "aureon.cloud.profiles") }
    }

    func profile(_ id: String) -> CloudProfile? { profiles.first { $0.id == id } }

    func save(_ p: CloudProfile, secret: String?) {
        var all = profiles
        if let i = all.firstIndex(where: { $0.id == p.id }) { all[i] = p } else { all.append(p) }
        profiles = all
        if let secret, !secret.isEmpty { secrets.set(secret, for: p.secretAccount) }
    }

    func remove(_ id: String) {
        profiles = profiles.filter { $0.id != id }
        secrets.set(nil, for: "cloud.\(id)")
        lock.lock(); readers.removeAll { CloudPath.parse($0.path)?.profile == id }; lock.unlock()
    }

    func client(for p: CloudProfile) throws -> S3Client {
        guard let cfg = p.config else { throw AureonError.message("The storage address of “\(p.name)” is incomplete.") }
        guard let secret = secrets.get(p.secretAccount), !p.accessKey.isEmpty else { throw AureonError.message("The secret key of “\(p.name)” is missing: enter it again in the Cloud page.") }
        return S3Client(config: cfg, credentials: S3Credentials(accessKey: p.accessKey, secretKey: secret), http: http)
    }

    // MARK: opening

    func remember(size: Int64, for path: String) { lock.lock(); sizes[path] = size; lock.unlock() }

    /// A reader for the object, shared between the player, the next-track warm-up and the importer.
    func reader(for path: String, config: ChunkedReader.Config? = nil) throws -> ChunkedReader {
        lock.lock()
        if let i = readers.firstIndex(where: { $0.path == path }) { let r = readers.remove(at: i); readers.append(r); lock.unlock(); return r.reader }
        let known = sizes[path]
        lock.unlock()
        guard let (pid, key) = CloudPath.parse(path), let p = profile(pid) else { throw AureonError.message("This track belongs to a cloud library that is no longer set up.") }
        let client = try client(for: p)
        let size: Int64
        if let known { size = known } else {
            guard let o = try Blocking.run({ try await client.stat(key: key) }) else { throw AureonError.message("The file is no longer in the bucket: \(key)") }
            size = o.size; remember(size: size, for: path)
        }
        let r = ChunkedReader(fetcher: S3ObjectFetcher(client: client, key: key, size: size), config: config ?? playbackConfig)
        lock.lock()
        readers.append((path, r, size))
        if readers.count > keep { readers.removeFirst(readers.count - keep) }
        lock.unlock()
        return r
    }

    /// Opens a cloud track for decoding (called by the player and the analysers on their own threads).
    func openFile(_ path: String) throws -> LosslessFile {
        let r = try reader(for: path)
        let ext = (path as NSString).pathExtension
        guard !["dsf", "dff"].contains(ext.lowercased()) else { throw AureonError.message("DSD files cannot be streamed from a bucket yet: download them or keep them on disk.") }
        let f = try RemoteAudioHandle.open(reader: r, fileExtension: ext)
        if f.info.duration > 0 { r.setBitrate(bytesPerSecond: Double(r.size) / f.info.duration) }
        return f
    }

    /// Starts loading the beginning and end of a track that is about to play, so the switch to it needs no network round trip.
    func warm(_ path: String) {
        guard CloudPath.isCloud(path) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let r = try? reader(for: path) else { return }
            r.warm(head: 3, tail: 1)
        }
    }
}

/// Reading tags and cover art out of a remote file without downloading it.
enum RemoteTags {
    private static func be32(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) << 24 | Int(d[d.startIndex + o + 1]) << 16 | Int(d[d.startIndex + o + 2]) << 8 | Int(d[d.startIndex + o + 3]) }
    private static func read(_ r: ChunkedReader, _ off: Int64, _ n: Int) throws -> Data {
        var d = Data(count: n)
        let got = try d.withUnsafeMutableBytes { try r.read(offset: off, length: n, into: $0.baseAddress!) }
        return d.prefix(got)
    }

    /// The bytes a tag parser needs, as a small file on disk: the start of the file, or for MP4 the `ftyp` and `moov` boxes wherever they are.
    static func materialize(_ r: ChunkedReader, fileExtension ext: String, into dir: URL, headBytes: Int = 3 << 20) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString.prefix(10) + "." + ext)
        var out = Data()
        if ["m4a", "mp4", "alac", "m4b"].contains(ext.lowercased()) {
            var off: Int64 = 0, hops = 0
            while off + 8 <= r.size, hops < 64 {
                hops += 1
                let h = try read(r, off, 16)
                guard h.count >= 8 else { break }
                var size = Int64(be32(h, 0))
                let type = String(decoding: h[(h.startIndex + 4)..<(h.startIndex + 8)], as: UTF8.self)
                if size == 1, h.count >= 16 { size = Int64(be32(h, 8)) << 32 | Int64(be32(h, 12)) }
                if size == 0 { size = r.size - off }
                guard size >= 8 else { break }
                if type == "ftyp" || type == "moov" {
                    guard size <= 48 << 20 else { throw AureonError.message("the tag box is unreasonably large") }
                    out += try read(r, off, Int(size))
                    if type == "moov" { break }
                }
                off += size
            }
        } else {
            out = try read(r, 0, Int(min(r.size, Int64(headBytes))))
        }
        try out.write(to: url)
        return url
    }
}

/// Indexes a bucket into the library.
enum CloudImporter {
    static let extensions = LibraryStore.audioExtensions

    struct Report: Equatable { var scanned = 0, added = 0, updated = 0, skipped = 0, removed = 0, failed = 0; var errors: [String] = [] }

    @discardableResult
    static func run(profile: CloudProfile, registry: CloudRegistry = .shared, store: LibraryStore, concurrency: Int = 4,
                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Report {
        let client = try registry.client(for: profile)
        let objects = try Blocking.run { try await client.listAll(prefix: profile.prefix) }
            .filter { extensions.contains(($0.key as NSString).pathExtension.lowercased()) }
            .sorted { $0.key < $1.key }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aureon-cloud-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        final class Shared: @unchecked Sendable {
            let lock = NSLock(); var report = Report(); var batch: [(facts: FileFacts, tags: TrackMetadata)] = []; var done = 0
        }
        let sh = Shared()
        let pid = profile.id
        var existing = Set<String>()
        for o in objects { existing.insert(CloudPath.make(profile: pid, key: o.key)) }

        let queue = DispatchQueue(label: "aureon.cloud.import", attributes: .concurrent), slots = DispatchSemaphore(value: max(1, concurrency)), group = DispatchGroup()
        sh.report.scanned = objects.count
        for o in objects {
            if cancelled() { break }
            slots.wait()
            group.enter()
            queue.async {
                defer { slots.signal(); group.leave() }
                let path = CloudPath.make(profile: pid, key: o.key)
                let mtime = o.modified?.timeIntervalSince1970 ?? 0
                if let k = store.knownFile(path), k.mtime == mtime, k.size == o.size {
                    sh.lock.lock(); sh.report.skipped += 1; sh.done += 1; let d = sh.done; sh.lock.unlock(); progress(d, objects.count); return
                }
                do {
                    registry.remember(size: o.size, for: path)
                    var cfg = ChunkedReader.Config(); cfg.chunkSize = 256 << 10; cfg.defaultAhead = 1; cfg.minAhead = 1; cfg.maxCacheBytes = 16 << 20
                    let reader = ChunkedReader(fetcher: S3ObjectFetcher(client: client, key: o.key, size: o.size), config: cfg)
                    let ext = (o.key as NSString).pathExtension
                    let file = try RemoteAudioHandle.open(reader: reader, fileExtension: ext)
                    var facts = FileFacts(path: path, mtime: mtime, size: o.size)
                    facts.duration = file.info.duration; facts.sampleRate = file.info.sampleRate; facts.bitDepth = file.info.sourceBits; facts.channels = file.info.channels; facts.codec = file.info.codec
                    let local = try RemoteTags.materialize(reader, fileExtension: ext, into: tmp)
                    defer { try? FileManager.default.removeItem(at: local) }
                    let tags = TagInterpreter.interpret(TagReader.read(path: local.path), fileName: (o.key as NSString).lastPathComponent)
                    sh.lock.lock()
                    sh.batch.append((facts, tags)); sh.done += 1
                    var flush: [(facts: FileFacts, tags: TrackMetadata)] = []
                    if sh.batch.count >= 100 { flush = sh.batch; sh.batch = [] }
                    let d = sh.done
                    sh.lock.unlock()
                    if !flush.isEmpty { let r = store.upsert(flush); sh.lock.lock(); sh.report.added += r.added; sh.report.updated += r.updated; sh.lock.unlock() }
                    progress(d, objects.count)
                } catch {
                    sh.lock.lock(); sh.report.failed += 1; sh.report.errors.append("\((o.key as NSString).lastPathComponent): \(error.localizedDescription)"); sh.done += 1; let d = sh.done; sh.lock.unlock()
                    progress(d, objects.count)
                }
            }
        }
        group.wait()
        if !sh.batch.isEmpty { let r = store.upsert(sh.batch); sh.report.added += r.added; sh.report.updated += r.updated }
        // a bucket that lists as empty is more likely a wrong prefix or a failed listing than a deleted library: keep what we know about it
        if !cancelled(), !objects.isEmpty { sh.report.removed = store.removeTracks(under: CloudPath.scheme + pid, keeping: existing) }
        return sh.report
    }
}

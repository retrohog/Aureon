import Foundation

enum SubsonicPath {
    static let scheme = "subsonic://"
    static func isSubsonic(_ p: String) -> Bool { p.hasPrefix(scheme) }
    static func make(profile: String, song: String, suffix: String) -> String { scheme + profile + "/" + song + (suffix.isEmpty ? "" : "." + suffix) }
    static func parse(_ p: String) -> (profile: String, song: String)? {
        guard isSubsonic(p) else { return nil }
        let rest = p.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        var song = String(rest[rest.index(after: slash)...])
        if let dot = song.lastIndex(of: "."), song.distance(from: dot, to: song.endIndex) <= 6 { song = String(song[..<dot]) }
        return song.isEmpty ? nil : (String(rest[..<slash]), song)
    }
}

/// Everything that plays from somewhere other than a local file goes through here.
enum RemoteMedia {
    static func isRemote(_ path: String) -> Bool { CloudPath.isCloud(path) || SubsonicPath.isSubsonic(path) || LMSPath.isLMS(path) }

    static func openFile(_ path: String) throws -> LosslessFile {
        if CloudPath.isCloud(path) { return try CloudRegistry.shared.openFile(path) }
        if SubsonicPath.isSubsonic(path) { return try SubsonicRegistry.shared.openFile(path) }
        if LMSPath.isLMS(path) { return try LMSRegistry.shared.openFile(path) }
        return try LosslessFile(path: path)
    }

    static func warm(_ path: String) {
        if CloudPath.isCloud(path) { CloudRegistry.shared.warm(path) } else if SubsonicPath.isSubsonic(path) { SubsonicRegistry.shared.warm(path) } else if LMSPath.isLMS(path) { LMSRegistry.shared.warm(path) }
    }

    /// A small local file holding a remote track's tags, for the parsers that read paths (buckets only: servers send tags with the listing).
    static func tagStub(_ path: String) -> URL? { MetadataEngine.tagStub(for: path) }
}

final class SubsonicRegistry: @unchecked Sendable {
    static let shared = SubsonicRegistry()
    var secrets: SecretStore = KeychainSecretStore()
    var http: HTTPClient = S3HTTP.shared
    var defaults = UserDefaults.standard
    var playbackConfig = ChunkedReader.Config()

    private let lock = NSLock()
    private var readers: [(path: String, reader: ChunkedReader)] = []
    private var sizes: [String: Int64] = [:]
    private var covers: [String: String] = [:]

    var profiles: [SubsonicProfile] {
        get { (defaults.data(forKey: "aureon.subsonic.profiles").flatMap { try? JSONDecoder().decode([SubsonicProfile].self, from: $0) }) ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "aureon.subsonic.profiles") }
    }
    func profile(_ id: String) -> SubsonicProfile? { profiles.first { $0.id == id } }

    func save(_ p: SubsonicProfile, password: String?) {
        var all = profiles
        if let i = all.firstIndex(where: { $0.id == p.id }) { all[i] = p } else { all.append(p) }
        profiles = all
        if let password, !password.isEmpty { secrets.set(password, for: p.secretAccount) }
    }

    func remove(_ id: String) {
        profiles = profiles.filter { $0.id != id }
        secrets.set(nil, for: "subsonic.\(id)")
        lock.lock(); readers.removeAll { SubsonicPath.parse($0.path)?.profile == id }; lock.unlock()
    }

    func client(for p: SubsonicProfile) throws -> SubsonicClient {
        guard let pw = secrets.get(p.secretAccount), !pw.isEmpty else { throw AureonError.message("The password of “\(p.name)” is missing: enter it again on the Cloud page.") }
        guard let c = SubsonicClient(urlString: p.url, username: p.username, password: pw, http: http) else { throw AureonError.message("The address of “\(p.name)” is not valid.") }
        return c
    }

    func remember(size: Int64, for path: String) { lock.lock(); sizes[path] = size; lock.unlock() }

    func reader(for path: String, config: ChunkedReader.Config? = nil) throws -> ChunkedReader {
        lock.lock()
        if let i = readers.firstIndex(where: { $0.path == path }) { let r = readers.remove(at: i); readers.append(r); lock.unlock(); return r.reader }
        let known = sizes[path]
        lock.unlock()
        guard let (pid, sid) = SubsonicPath.parse(path), let p = profile(pid) else { throw AureonError.message("This track belongs to a music server that is no longer set up.") }
        let client = try client(for: p)
        var size = known ?? 0
        if known == nil {
            guard let s = try Blocking.run({ try await client.song(id: sid) }) else { throw AureonError.message("The server no longer has this track.") }
            size = s.size; remember(size: size, for: path)
            if let c = s.coverArt { lock.lock(); covers[path] = c; lock.unlock() }
        }
        guard size > 0 else { throw AureonError.message("The server did not say how big this file is, so it cannot be streamed.") }
        let r = ChunkedReader(fetcher: client.fetcher(songID: sid, size: size), config: config ?? playbackConfig)
        lock.lock(); readers.append((path, r)); if readers.count > 4 { readers.removeFirst(readers.count - 4) }; lock.unlock()
        return r
    }

    func openFile(_ path: String) throws -> LosslessFile {
        let ext = (path as NSString).pathExtension
        guard !["dsf", "dff"].contains(ext.lowercased()) else { throw AureonError.message("DSD files cannot be streamed from a server yet.") }
        let r = try reader(for: path)
        let f = try RemoteAudioHandle.open(reader: r, fileExtension: ext)
        if f.info.duration > 0 { r.setBitrate(bytesPerSecond: Double(r.size) / f.info.duration) }
        return f
    }

    func warm(_ path: String) {
        DispatchQueue.global(qos: .utility).async { [self] in (try? reader(for: path))?.warm(head: 3, tail: 1) }
    }

    func coverArt(for path: String) -> Data? {
        guard let (pid, sid) = SubsonicPath.parse(path), let p = profile(pid), let c = try? client(for: p) else { return nil }
        lock.lock(); let known = covers[path]; lock.unlock()
        return try? Blocking.run { try await c.coverArt(id: known ?? sid) }
    }
}

enum SubsonicImporter {
    struct Report: Equatable { var songs = 0, albums = 0, removed = 0, failed = 0; var errors: [String] = [] }

    static func facts(_ s: SubsonicSong, path: String) -> FileFacts {
        var f = FileFacts(path: path, mtime: 0, size: s.size)
        f.duration = s.duration; f.sampleRate = s.sampleRate ?? 0; f.bitDepth = s.bitDepth ?? 0; f.channels = s.channels ?? 2; f.codec = s.suffix.uppercased()
        return f
    }

    static func tags(_ s: SubsonicSong) -> TrackMetadata {
        var t = TrackMetadata()
        t.title = s.title; t.album = s.album; t.trackNumber = s.track; t.discNumber = s.disc; t.year = s.year
        t.date = s.year.map(String.init)
        if let g = s.genre, !g.isEmpty { t.genres = [g] }
        if let a = s.artist, !a.isEmpty { t.credits.append(Credit(role: .artist, name: a)) }
        if let a = s.albumArtist ?? s.artist, !a.isEmpty { t.credits.append(Credit(role: .albumArtist, name: a)) }
        t.mbRecordingID = s.musicBrainzID
        return t
    }

    @discardableResult
    static func run(profile: SubsonicProfile, registry: SubsonicRegistry = .shared, store: LibraryStore, concurrency: Int = 4,
                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Report {
        let client = try registry.client(for: profile)
        _ = try Blocking.run { try await client.ping() }
        var albums: [SubsonicAlbum] = []
        while !cancelled() {
            let page = try Blocking.run { [albums] in try await client.albums(offset: albums.count) }
            albums += page
            if page.count < 500 { break }
        }
        final class Shared: @unchecked Sendable { let lock = NSLock(); var report = Report(); var batch: [(facts: FileFacts, tags: TrackMetadata)] = []; var paths = Set<String>(); var done = 0 }
        let sh = Shared()
        let queue = DispatchQueue(label: "aureon.subsonic.import", attributes: .concurrent), slots = DispatchSemaphore(value: max(1, concurrency)), group = DispatchGroup()
        for a in albums {
            if cancelled() { break }
            slots.wait(); group.enter()
            queue.async {
                defer { slots.signal(); group.leave() }
                do {
                    let songs = try Blocking.run { try await client.songs(inAlbum: a.id) }
                    var items: [(facts: FileFacts, tags: TrackMetadata)] = [], paths: [String] = []
                    for s in songs {
                        let path = SubsonicPath.make(profile: profile.id, song: s.id, suffix: s.suffix)
                        registry.remember(size: s.size, for: path)
                        items.append((facts(s, path: path), tags(s))); paths.append(path)
                    }
                    sh.lock.lock()
                    sh.batch += items; sh.paths.formUnion(paths); sh.report.songs += songs.count; sh.report.albums += 1; sh.done += 1
                    var flush: [(facts: FileFacts, tags: TrackMetadata)] = []
                    if sh.batch.count >= 200 { flush = sh.batch; sh.batch = [] }
                    let d = sh.done
                    sh.lock.unlock()
                    if !flush.isEmpty { store.upsert(flush) }
                    progress(d, albums.count)
                } catch {
                    sh.lock.lock(); sh.report.failed += 1; sh.report.errors.append("\(a.name): \(error.localizedDescription)"); sh.done += 1; let d = sh.done; sh.lock.unlock()
                    progress(d, albums.count)
                }
            }
        }
        group.wait()
        if !sh.batch.isEmpty { store.upsert(sh.batch) }
        if !cancelled(), sh.report.failed == 0 { sh.report.removed = store.removeTracks(under: SubsonicPath.scheme + profile.id, keeping: sh.paths) }
        return sh.report
    }
}

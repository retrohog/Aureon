import Foundation
import Darwin

// Lyrion Music Server (formerly Logitech Media Server / Squeezebox Server). Two interfaces matter to a player:
//  • JSON-RPC at /jsonrpc.js  → the library (paged `songs` listing, `serverstatus` for change detection)
//  • /music/<id>/download     → the original file, byte for byte, with HTTP range support
// The files go through the same chunk reader as buckets and Subsonic servers, so FLAC lands in the RAM buffer and plays through the
// normal engine. (Acting as a SlimProto player would make LMS transcode the stream; downloading the original does not.)

struct LMSProfile: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString.prefix(8).lowercased().description
    var name = ""
    var url = ""                      // http://192.168.1.20:9000
    var username = ""                 // empty when the server has no password
    var secretAccount: String { "lms.\(id)" }
}

struct LMSTrack: Equatable, Sendable {
    var id: String
    var title: String
    var artist: String?
    var albumArtist: String?
    var album: String?
    var genre: String?
    var track: Int?
    var disc: Int?
    var year: Int?
    var duration: Double
    var size: Int64
    var suffix: String
    var sampleRate: Double?
    var bitDepth: Int?
    var channels: Int?
    var coverID: String?
}

enum LMSPath {
    static let scheme = "lms://"
    static func isLMS(_ p: String) -> Bool { p.hasPrefix(scheme) }
    static func make(profile: String, track: String, suffix: String) -> String { scheme + profile + "/" + track + (suffix.isEmpty ? "" : "." + suffix) }
    static func parse(_ p: String) -> (profile: String, track: String)? {
        guard isLMS(p) else { return nil }
        let rest = p.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        var t = String(rest[rest.index(after: slash)...])
        if let dot = t.lastIndex(of: "."), t.distance(from: dot, to: t.endIndex) <= 6 { t = String(t[..<dot]) }
        return t.isEmpty ? nil : (String(rest[..<slash]), t)
    }
    /// LMS names formats by its own short codes.
    static func suffix(forType t: String) -> String {
        switch t.lowercased() {
        case "flc", "flac": "flac"
        case "alc", "mp4", "aac", "m4a": "m4a"
        case "aif", "aiff": "aiff"
        case "wav", "pcm": "wav"
        case "wma", "wmal", "wmap": "wma"
        case "ogg", "ogf", "ops": "ogg"
        case "dsf": "dsf"
        case "dff": "dff"
        case "mp3": "mp3"
        default: t.lowercased()
        }
    }
}

enum LMSError: LocalizedError {
    case badAnswer(String)
    case unauthorised
    var errorDescription: String? {
        switch self {
        case .badAnswer(let m): m
        case .unauthorised: "The server rejected the user name or password."
        }
    }
}

final class LMSClient: @unchecked Sendable {
    let base: URL
    private let authHeader: String?
    private let http: HTTPClient

    /// The tags we ask for (see the LMS CLI documentation): artist, coverid, duration, album_id, filesize, genre, disc, artwork flag, album, type,
    /// disc count, bitrate, track number, year, samplerate, samplesize, channels, album artist.
    static let tags = "acdefgijlorqtyTIHA"

    init?(urlString: String, username: String = "", password: String = "", http: HTTPClient = S3HTTP.shared) {
        var s = urlString.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.host != nil else { return nil }
        base = u; self.http = http
        authHeader = username.isEmpty ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    var headers: [String: String] { authHeader.map { ["Authorization": $0] } ?? [:] }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url); r.timeoutInterval = 30
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// One JSON-RPC `slim.request` for a command that does not need a player.
    func rpc(_ command: [Any]) async throws -> JSONObject {
        var req = request(base.appendingPathComponent("jsonrpc.js"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": 1, "method": "slim.request", "params": ["-", command]] as [String: Any])
        let (d, status) = try await http.send(req)
        if status == 401 || status == 403 { throw LMSError.unauthorised }
        guard status == 200 else { throw LMSError.badAnswer("The server answered HTTP \(status). Check the address and port (9000 by default).") }
        guard let root = try? parseJSON(d), let result = root.obj("result") else { throw LMSError.badAnswer("That address does not answer like a Lyrion Music Server.") }
        return result
    }

    struct Status: Equatable { var version: String; var songs: Int; var lastScan: Double; var scanning: Bool }

    func status() async throws -> Status {
        let r = try await rpc(["serverstatus", 0, 1])
        return Status(version: Self.string(r["version"]) ?? "?", songs: Int(Self.double(r["info total songs"]) ?? 0),
                      lastScan: Self.double(r["lastscan"]) ?? 0, scanning: Self.double(r["rescan"]) == 1)
    }

    /// One page of the whole library, in album order. `total` is how many tracks the server has.
    func songs(offset: Int, count: Int = 500) async throws -> (tracks: [LMSTrack], total: Int) {
        let r = try await rpc(["songs", offset, count, "tags:" + Self.tags, "sort:albumtrack"])
        let total = Int(Self.double(r["count"]) ?? 0)
        return (r.arr("titles_loop").compactMap(Self.track), total)
    }

    func song(id: String) async throws -> LMSTrack? {
        let r = try await rpc(["songs", 0, 1, "track_id:\(id)", "tags:" + Self.tags])
        return r.arr("titles_loop").compactMap(Self.track).first
    }

    // LMS returns many numbers as strings ("3") and some as numbers; accept both.
    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func track(_ o: JSONObject) -> LMSTrack? {
        guard let id = string(o["id"]), let title = string(o["title"]) else { return nil }
        let suffix = LMSPath.suffix(forType: string(o["type"]) ?? "")
        return LMSTrack(id: id, title: title, artist: string(o["artist"]), albumArtist: string(o["albumartist"]) ?? string(o["album_artist"]), album: string(o["album"]), genre: string(o["genre"]),
                        track: double(o["tracknum"]).map(Int.init), disc: double(o["disc"]).map(Int.init), year: double(o["year"]).flatMap { $0 > 0 ? Int($0) : nil },
                        duration: double(o["duration"]) ?? 0, size: Int64(double(o["filesize"]) ?? 0), suffix: suffix,
                        sampleRate: double(o["samplerate"]), bitDepth: double(o["samplesize"]).map(Int.init), channels: double(o["channels"]).map(Int.init),
                        coverID: string(o["coverid"]) ?? string(o["artwork_track_id"]))
    }

    func downloadURL(id: String) -> URL { base.appendingPathComponent("music").appendingPathComponent(id).appendingPathComponent("download") }
    func coverURL(id: String) -> URL { base.appendingPathComponent("music").appendingPathComponent(id).appendingPathComponent("cover_1000x1000.jpg") }

    func coverArt(id: String) async throws -> Data? {
        let (d, status) = try await http.send(request(coverURL(id: id)))
        return status == 200 && !d.isEmpty ? d : nil
    }

    func fetcher(trackID: String, size: Int64) -> HTTPRangeFetcher { HTTPRangeFetcher(url: downloadURL(id: trackID), size: size, http: http, headers: headers) }
}

// MARK: - Registry (profiles, readers)

final class LMSRegistry: @unchecked Sendable {
    static let shared = LMSRegistry()
    var secrets: SecretStore = KeychainSecretStore()
    var http: HTTPClient = S3HTTP.shared
    var defaults = UserDefaults.standard
    var playbackConfig = ChunkedReader.Config()

    private let lock = NSLock()
    private var readers: [(path: String, reader: ChunkedReader)] = []
    private var sizes: [String: Int64] = [:]
    private var covers: [String: String] = [:]

    var profiles: [LMSProfile] {
        get { (defaults.data(forKey: "aureon.lms.profiles").flatMap { try? JSONDecoder().decode([LMSProfile].self, from: $0) }) ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "aureon.lms.profiles") }
    }
    func profile(_ id: String) -> LMSProfile? { profiles.first { $0.id == id } }

    func save(_ p: LMSProfile, password: String?) {
        var all = profiles
        if let i = all.firstIndex(where: { $0.id == p.id }) { all[i] = p } else { all.append(p) }
        profiles = all
        if let password, !password.isEmpty { secrets.set(password, for: p.secretAccount) }
    }

    func remove(_ id: String) {
        profiles = profiles.filter { $0.id != id }
        secrets.set(nil, for: "lms.\(id)")
        lock.lock(); readers.removeAll { LMSPath.parse($0.path)?.profile == id }; lock.unlock()
    }

    func client(for p: LMSProfile) throws -> LMSClient {
        let pw = p.username.isEmpty ? "" : (secrets.get(p.secretAccount) ?? "")
        guard let c = LMSClient(urlString: p.url, username: p.username, password: pw, http: http) else { throw AureonError.message("The address of “\(p.name)” is not valid.") }
        return c
    }

    func remember(size: Int64, for path: String) { lock.lock(); sizes[path] = size; lock.unlock() }

    func reader(for path: String, config: ChunkedReader.Config? = nil) throws -> ChunkedReader {
        lock.lock()
        if let i = readers.firstIndex(where: { $0.path == path }) { let r = readers.remove(at: i); readers.append(r); lock.unlock(); return r.reader }
        let known = sizes[path]
        lock.unlock()
        guard let (pid, tid) = LMSPath.parse(path), let p = profile(pid) else { throw AureonError.message("This track belongs to a Lyrion server that is no longer set up.") }
        let client = try client(for: p)
        var size = known ?? 0
        if known == nil {
            guard let t = try Blocking.run({ try await client.song(id: tid) }) else { throw AureonError.message("The server no longer has this track.") }
            size = t.size; remember(size: size, for: path)
            if let c = t.coverID { lock.lock(); covers[path] = c; lock.unlock() }
        }
        guard size > 0 else { throw AureonError.message("The server did not say how big this file is, so it cannot be streamed.") }
        let r = ChunkedReader(fetcher: client.fetcher(trackID: tid, size: size), config: config ?? playbackConfig)
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

    func warm(_ path: String) { DispatchQueue.global(qos: .utility).async { [self] in (try? reader(for: path))?.warm(head: 3, tail: 1) } }

    func coverArt(for path: String) -> Data? {
        guard let (pid, tid) = LMSPath.parse(path), let p = profile(pid), let c = try? client(for: p) else { return nil }
        lock.lock(); let known = covers[path]; lock.unlock()
        return try? Blocking.run { try await c.coverArt(id: known ?? tid) }
    }
}

// MARK: - Importer

enum LMSImporter {
    struct Report: Equatable { var songs = 0, removed = 0, failed = 0; var errors: [String] = [] }

    static func facts(_ t: LMSTrack, path: String) -> FileFacts {
        var f = FileFacts(path: path, mtime: 0, size: t.size)
        f.duration = t.duration; f.sampleRate = t.sampleRate ?? 0; f.bitDepth = t.bitDepth ?? 0; f.channels = t.channels ?? 2; f.codec = t.suffix.uppercased()
        return f
    }

    static func tags(_ t: LMSTrack) -> TrackMetadata {
        var m = TrackMetadata()
        m.title = t.title; m.album = t.album; m.trackNumber = t.track; m.discNumber = t.disc; m.year = t.year
        m.date = t.year.map(String.init)
        if let g = t.genre, !g.isEmpty { m.genres = [g] }
        if let a = t.artist, !a.isEmpty { m.credits.append(Credit(role: .artist, name: a)) }
        if let a = t.albumArtist ?? t.artist, !a.isEmpty { m.credits.append(Credit(role: .albumArtist, name: a)) }
        return m
    }

    @discardableResult
    static func run(profile: LMSProfile, registry: LMSRegistry = .shared, store: LibraryStore, pageSize: Int = 500,
                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Report {
        let client = try registry.client(for: profile)
        _ = try Blocking.run { try await client.status() }
        var report = Report(), kept = Set<String>(), offset = 0, total = 0
        while !cancelled() {
            let page = try Blocking.run { [offset] in try await client.songs(offset: offset, count: pageSize) }
            total = max(total, page.total)
            var batch: [(facts: FileFacts, tags: TrackMetadata)] = []
            for t in page.tracks {
                guard t.size > 0 else { report.failed += 1; if report.errors.count < 5 { report.errors.append("\(t.title): the server gave no file size") }; continue }
                let path = LMSPath.make(profile: profile.id, track: t.id, suffix: t.suffix)
                registry.remember(size: t.size, for: path)
                batch.append((facts(t, path: path), tags(t))); kept.insert(path)
            }
            if !batch.isEmpty { store.upsert(batch) }
            report.songs += batch.count
            offset += pageSize
            progress(min(offset, total), total)
            if page.tracks.isEmpty || offset >= total { break }
        }
        if !cancelled(), report.failed == 0 { report.removed = store.removeTracks(under: LMSPath.scheme + profile.id, keeping: kept) }
        return report
    }
}

// MARK: - Discovery

/// Finds servers on the local network the way Squeezebox hardware does: a UDP broadcast to port 3483; each server answers with its name and
/// the port of its web interface.
enum LMSDiscovery {
    struct Found: Equatable, Sendable { var name: String; var host: String; var httpPort: Int; var url: String { "http://\(host):\(httpPort)" } }

    static let request: [UInt8] = Array("e".utf8) + Array("NAME".utf8) + [0] + Array("JSON".utf8) + [0] + Array("VERS".utf8) + [0]

    /// 'E' followed by (4-character tag, 1-byte length, value) triples.
    static func parse(_ data: [UInt8], from host: String) -> Found? {
        guard data.first == UInt8(ascii: "E") else { return nil }
        var i = 1, name = "Lyrion Music Server", port: Int?
        while i + 5 <= data.count {
            let tag = String(decoding: data[i..<(i + 4)], as: UTF8.self), len = Int(data[i + 4])
            guard i + 5 + len <= data.count else { break }
            let value = String(decoding: data[(i + 5)..<(i + 5 + len)], as: UTF8.self)
            if tag == "NAME" { name = value } else if tag == "JSON" { port = Int(value) }
            i += 5 + len
        }
        return port.map { Found(name: name, host: host, httpPort: $0) }
    }

    static func discover(timeout: TimeInterval = 1.5, target: String = "255.255.255.255", port: UInt16 = 3483) -> [Found] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var dest = sockaddr_in(); dest.sin_family = sa_family_t(AF_INET); dest.sin_port = port.bigEndian
        guard inet_pton(AF_INET, target, &dest.sin_addr) == 1 else { return [] }
        let sent = withUnsafePointer(to: &dest) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard sent > 0 else { return [] }
        var found: [Found] = []
        let end = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 1024)
        while Date() < end {
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) } }
            guard n > 0 else { continue }
            var addr = from.sin_addr, name = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &name, socklen_t(INET_ADDRSTRLEN))
            if let f = parse(Array(buf[0..<n]), from: String(cString: name)), !found.contains(f) { found.append(f) }
        }
        return found
    }
}

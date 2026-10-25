import Foundation
import CryptoKit
import Security

// Scrobbling to Last.fm and ListenBrainz.
//   • ScrobbleTracker  — decides *when* a play counts (≥ 30 s long; played for half of it or 4 minutes, whichever comes first)
//   • ScrobbleQueue    — persists plays and retries with back-off while offline
//   • LastFMClient / ListenBrainzClient — the two protocols
// Credentials belong to the user: API key/secret and tokens are typed in the app and kept in the Keychain.

struct ScrobbleTrack: Codable, Equatable, Hashable {
    var artist: String, title: String
    var album: String? = nil, albumArtist: String? = nil
    var duration: Int? = nil                 // seconds
    var trackNumber: Int? = nil
    var mbRecordingID: String? = nil, mbReleaseID: String? = nil

    init(artist: String, title: String, album: String? = nil, albumArtist: String? = nil, duration: Int? = nil, trackNumber: Int? = nil, mbRecordingID: String? = nil, mbReleaseID: String? = nil) {
        self.artist = artist; self.title = title; self.album = album; self.albumArtist = albumArtist; self.duration = duration
        self.trackNumber = trackNumber; self.mbRecordingID = mbRecordingID; self.mbReleaseID = mbReleaseID
    }

    init?(_ n: NowPlayingInfo) {
        guard !n.title.isEmpty, !n.artist.isEmpty else { return nil }          // both services require an artist and a title
        self.init(artist: n.artist, title: n.title, album: n.album.isEmpty ? nil : n.album, albumArtist: n.albumArtist.isEmpty ? nil : n.albumArtist,
                  duration: n.duration > 0 ? Int(n.duration.rounded()) : nil, trackNumber: n.trackNumber, mbRecordingID: n.mbRecordingID, mbReleaseID: n.mbReleaseID)
    }
}

enum ScrobbleError: Error, Equatable, LocalizedError {
    case auth(String)             // credentials are wrong or expired: needs the user
    case temporary(String)        // try again later
    case rejected(String)         // this play can never be accepted: drop it
    var errorDescription: String? { switch self { case .auth(let m), .temporary(let m), .rejected(let m): m } }
}

protocol ScrobbleService: AnyObject, Sendable {
    var name: String { get }
    var isConfigured: Bool { get }
    func nowPlaying(_ t: ScrobbleTrack) async throws
    func scrobble(_ plays: [(track: ScrobbleTrack, playedAt: Date)]) async throws
}

private func formEncode(_ params: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
    return Data(params.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
}

// MARK: - Last.fm

final class LastFMClient: ScrobbleService, @unchecked Sendable {
    let name = "Last.fm"
    private let http: HTTPClient
    private let apiKey: String, secret: String
    var sessionKey: String?
    var endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    static let version = "0.1"

    init(apiKey: String, secret: String, sessionKey: String? = nil, http: HTTPClient = URLSessionClient()) {
        self.apiKey = apiKey; self.secret = secret; self.sessionKey = sessionKey; self.http = http
    }
    var isConfigured: Bool { !apiKey.isEmpty && !secret.isEmpty && (sessionKey?.isEmpty == false) }

    /// api_sig = md5( name1 value1 name2 value2 … secret ), parameters sorted by name; `format` and `callback` are not signed.
    static func signatureBase(_ params: [String: String], secret: String) -> String {
        params.filter { $0.key != "format" && $0.key != "callback" }.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + secret
    }

    static func signature(_ params: [String: String], secret: String) -> String {
        Insecure.MD5.hash(data: Data(signatureBase(params, secret: secret).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func call(_ method: String, _ params: [String: String], post: Bool = true) async throws -> JSONObject {
        var p = params; p["method"] = method; p["api_key"] = apiKey
        p["api_sig"] = Self.signature(p, secret: secret); p["format"] = "json"
        var req: URLRequest
        let pairs = p.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        if post {
            req = URLRequest(url: endpoint); req.httpMethod = "POST"; req.httpBody = formEncode(pairs)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else {
            var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!; c.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
            req = URLRequest(url: c.url!)
        }
        req.setValue("Aureon/\(Self.version)", forHTTPHeaderField: "User-Agent")
        let data: Data, status: Int
        do { (data, status) = try await http.send(req) } catch { throw ScrobbleError.temporary(error.localizedDescription) }
        if status >= 500 || status == 429 { throw ScrobbleError.temporary("Last.fm answered HTTP \(status)") }
        let j = (try? parseJSON(data)) ?? [:]
        if let code = j.num("error") {
            let msg = j.str("message") ?? "error \(Int(code))"
            switch Int(code) {
            case 4, 9, 10, 14, 15, 26: throw ScrobbleError.auth(msg)
            case 8, 11, 16, 29: throw ScrobbleError.temporary(msg)
            default: throw ScrobbleError.rejected(msg)
            }
        }
        guard status == 200 else { throw ScrobbleError.temporary("Last.fm answered HTTP \(status)") }
        return j
    }

    private func fields(_ t: ScrobbleTrack, into p: inout [String: String], index: Int? = nil) {
        func k(_ n: String) -> String { index.map { "\(n)[\($0)]" } ?? n }
        p[k("artist")] = t.artist; p[k("track")] = t.title
        if let a = t.album { p[k("album")] = a }
        if let a = t.albumArtist { p[k("albumArtist")] = a }
        if let d = t.duration { p[k("duration")] = String(d) }
        if let n = t.trackNumber { p[k("trackNumber")] = String(n) }
        if let m = t.mbRecordingID { p[k("mbid")] = m }
    }

    func nowPlaying(_ t: ScrobbleTrack) async throws {
        guard let sk = sessionKey else { throw ScrobbleError.auth("not signed in to Last.fm") }
        var p = ["sk": sk]; fields(t, into: &p)
        _ = try await call("track.updateNowPlaying", p)
    }

    func scrobble(_ plays: [(track: ScrobbleTrack, playedAt: Date)]) async throws {
        guard let sk = sessionKey else { throw ScrobbleError.auth("not signed in to Last.fm") }
        for chunk in stride(from: 0, to: plays.count, by: 50).map({ Array(plays[$0..<min($0 + 50, plays.count)]) }) {
            var p = ["sk": sk]
            for (i, play) in chunk.enumerated() { fields(play.track, into: &p, index: i); p["timestamp[\(i)]"] = String(Int(play.playedAt.timeIntervalSince1970)) }
            _ = try await call("track.scrobble", p)
        }
    }

    /// Step 1 of signing in: a request token and the page where the user approves Aureon.
    func authToken() async throws -> (token: String, url: URL) {
        let j = try await call("auth.getToken", [:], post: false)
        guard let t = j.str("token") else { throw ScrobbleError.rejected("no token in reply") }
        var c = URLComponents(string: "https://www.last.fm/api/auth/")!; c.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "token", value: t)]
        return (t, c.url!)
    }

    /// Step 2, after the user approved: the long-lived session key.
    func session(token: String) async throws -> (key: String, user: String) {
        let j = try await call("auth.getSession", ["token": token], post: false)
        guard let s = j.obj("session"), let k = s.str("key") else { throw ScrobbleError.rejected("no session in reply") }
        sessionKey = k
        return (k, s.str("name") ?? "")
    }
}

// MARK: - ListenBrainz

final class ListenBrainzClient: ScrobbleService, @unchecked Sendable {
    let name = "ListenBrainz"
    private let http: HTTPClient
    var token: String
    var base: URL

    init(token: String, base: URL = URL(string: "https://api.listenbrainz.org")!, http: HTTPClient = URLSessionClient()) { self.token = token; self.base = base; self.http = http }
    var isConfigured: Bool { !token.isEmpty }

    private func metadata(_ t: ScrobbleTrack) -> [String: Any] {
        var info: [String: Any] = ["media_player": "Aureon", "media_player_version": "0.1", "submission_client": "Aureon", "submission_client_version": "0.1"]
        if let d = t.duration { info["duration_ms"] = d * 1000 }
        if let n = t.trackNumber { info["tracknumber"] = n }
        if let m = t.mbRecordingID { info["recording_mbid"] = m }
        if let m = t.mbReleaseID { info["release_mbid"] = m }
        var md: [String: Any] = ["artist_name": t.artist, "track_name": t.title, "additional_info": info]
        if let a = t.album { md["release_name"] = a }
        return md
    }

    private func submit(_ type: String, _ payload: [[String: Any]]) async throws {
        guard isConfigured else { throw ScrobbleError.auth("no ListenBrainz token") }
        var req = URLRequest(url: base.appendingPathComponent("1/submit-listens")); req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["listen_type": type, "payload": payload])
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data, status: Int
        do { (data, status) = try await http.send(req) } catch { throw ScrobbleError.temporary(error.localizedDescription) }
        let msg = ((try? parseJSON(data))?.str("error")) ?? "HTTP \(status)"
        switch status {
        case 200: return
        case 401: throw ScrobbleError.auth(msg)
        case 400: throw ScrobbleError.rejected(msg)
        default: throw ScrobbleError.temporary(msg)          // 429, 5xx
        }
    }

    func nowPlaying(_ t: ScrobbleTrack) async throws { try await submit("playing_now", [["track_metadata": metadata(t)]]) }

    func scrobble(_ plays: [(track: ScrobbleTrack, playedAt: Date)]) async throws {
        for chunk in stride(from: 0, to: plays.count, by: 100).map({ Array(plays[$0..<min($0 + 100, plays.count)]) }) {
            try await submit(chunk.count == 1 ? "single" : "import", chunk.map { ["listened_at": Int($0.playedAt.timeIntervalSince1970), "track_metadata": metadata($0.track)] })
        }
    }

    /// Checks the token and returns the user name.
    func validate() async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("1/validate-token")); req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (d, s) = try await http.send(req)
        let j = (try? parseJSON(d)) ?? [:]
        guard s == 200, (j["valid"] as? Bool) == true else { throw ScrobbleError.auth(j.str("message") ?? "invalid token") }
        return j.str("user_name") ?? ""
    }
}

// MARK: - When does a play count?

final class ScrobbleTracker {
    var onNowPlaying: ((ScrobbleTrack) -> Void)?
    var onScrobble: ((ScrobbleTrack, Date) -> Void)?

    private var currentID: String?
    private var track: ScrobbleTrack?
    private var startedAt = Date()
    private var played = 0.0
    private var lastTick: Date?
    private var lastPosition = 0.0
    private var scrobbled = false

    static let minimumLength = 30.0, maximumThreshold = 240.0

    /// Seconds of actual listening needed before the play counts.
    static func threshold(duration: Double) -> Double? {
        if duration <= 0 { return maximumThreshold }               // unknown length: the 4-minute rule
        guard duration >= minimumLength else { return nil }
        return min(duration / 2, maximumThreshold)
    }

    private func begin(_ n: NowPlayingInfo, position: Double, now: Date) {
        currentID = n.id; track = ScrobbleTrack(n); startedAt = now.addingTimeInterval(-position); played = 0; scrobbled = false
        if let t = track { onNowPlaying?(t) }
    }

    /// Call regularly (several times a second) with the current playback state.
    func update(_ n: NowPlayingInfo?, position: Double, playing: Bool, now: Date = Date()) {
        guard let n else { currentID = nil; track = nil; lastTick = nil; return }
        if n.id != currentID { begin(n, position: position, now: now); lastTick = now; lastPosition = position; return }
        // the same track starting over (repeat / replay) is a new play
        if scrobbled && position < 5 && lastPosition > position + 10 { begin(n, position: position, now: now); lastTick = now; lastPosition = position; return }
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now; lastPosition = position
        if playing { played += min(max(dt, 0), 2) }               // a long gap (sleep, stall) must not count as listening
        if !scrobbled, let th = Self.threshold(duration: n.duration), played >= th, let t = track {
            scrobbled = true
            onScrobble?(t, startedAt)
        }
    }
}

// MARK: - Persistent queue

struct PendingScrobble: Codable, Equatable {
    var track: ScrobbleTrack
    var playedAt: Date
    var service: String
    var attempts = 0
    var nextTry = Date.distantPast
}

final class ScrobbleQueue: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var items: [PendingScrobble] = []
    static let maxAge: TimeInterval = 14 * 86_400                 // Last.fm refuses older timestamps

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/pending-scrobbles.json")
        try? FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: self.url) { let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970; items = (try? dec.decode([PendingScrobble].self, from: d)) ?? [] }
    }

    private func save() { let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; try? enc.encode(items).write(to: url, options: .atomic) }

    var pending: [PendingScrobble] { lock.lock(); defer { lock.unlock() }; return items }
    func count(for service: String) -> Int { pending.filter { $0.service == service }.count }

    func add(_ t: ScrobbleTrack, playedAt: Date, services: [String]) {
        lock.lock(); defer { lock.unlock() }
        for s in services { items.append(PendingScrobble(track: t, playedAt: playedAt, service: s)) }
        save()
    }

    struct Outcome: Equatable { var sent = 0, dropped = 0, retryLater = 0, needsAuth = false, lastError: String? = nil }

    /// Submits what is due for `service`, oldest first. Temporary failures back off exponentially (30 s … 1 h).
    func flush(_ service: ScrobbleService, now: Date = Date()) async -> Outcome {
        var out = Outcome()
        lock.lock(); items.removeAll { now.timeIntervalSince($0.playedAt) > Self.maxAge }; save(); lock.unlock()
        let due = pending.filter { $0.service == service.name && $0.nextTry <= now }.sorted { $0.playedAt < $1.playedAt }
        guard !due.isEmpty else { return out }

        func remove(_ plays: [PendingScrobble]) { lock.lock(); items.removeAll { p in plays.contains { $0 == p } }; save(); lock.unlock() }
        func backoff(_ plays: [PendingScrobble]) {
            lock.lock()
            for i in items.indices where plays.contains(where: { $0 == items[i] }) {
                items[i].attempts += 1; items[i].nextTry = now.addingTimeInterval(min(3600, 30 * pow(2, Double(items[i].attempts - 1))))
            }
            save(); lock.unlock()
        }
        var batch = Array(due.prefix(50))
        while !batch.isEmpty {
            do {
                try await service.scrobble(batch.map { ($0.track, $0.playedAt) })
                remove(batch); out.sent += batch.count
                batch = Array(pending.filter { $0.service == service.name && $0.nextTry <= now }.sorted { $0.playedAt < $1.playedAt }.prefix(50))
            } catch ScrobbleError.auth(let m) { out.needsAuth = true; out.lastError = m; out.retryLater = batch.count; return out }
            catch ScrobbleError.temporary(let m) { backoff(batch); out.retryLater += batch.count; out.lastError = m; return out }
            catch ScrobbleError.rejected(let m) {
                out.lastError = m
                if batch.count == 1 { remove(batch); out.dropped += 1 }
                else {                                                  // find the offender: send one by one
                    for p in batch {
                        do { try await service.scrobble([(p.track, p.playedAt)]); remove([p]); out.sent += 1 }
                        catch ScrobbleError.rejected { remove([p]); out.dropped += 1 }
                        catch ScrobbleError.auth(let m) { out.needsAuth = true; out.lastError = m; return out }
                        catch { backoff([p]); out.retryLater += 1 }
                    }
                }
                batch = Array(pending.filter { $0.service == service.name && $0.nextTry <= now }.sorted { $0.playedAt < $1.playedAt }.prefix(50))
            } catch { backoff(batch); out.retryLater += batch.count; out.lastError = error.localizedDescription; return out }
        }
        return out
    }
}

// MARK: - Secrets

protocol SecretStore: AnyObject, Sendable {
    func get(_ account: String) -> String?
    func set(_ value: String?, for account: String)
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var d: [String: String] = [:]; private let l = NSLock()
    func get(_ account: String) -> String? { l.lock(); defer { l.unlock() }; return d[account] }
    func set(_ value: String?, for account: String) { l.lock(); d[account] = value; l.unlock() }
}

/// Secrets kept as small files in a private folder of the app's own support folder: the folder is readable by this user only (0700), each file is too (0600) and is
/// written whole and moved into place (so a crash never leaves half a key), and nothing about their content is ever logged. Nothing here talks to the Keychain, so
/// macOS never asks for a password.
final class PrivateFileSecretStore: SecretStore, @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()

    init(folder: URL) { self.folder = folder }

    /// `~/Library/Application Support/Aureon/Private`.
    static let standard = PrivateFileSecretStore(folder: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("Aureon", isDirectory: true).appendingPathComponent("Private", isDirectory: true))

    private func url(_ account: String) -> URL {
        let safe = String(account.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
        return folder.appendingPathComponent(safe.isEmpty ? "_" : safe)
    }

    func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: url(account)), let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    func set(_ value: String?, for account: String) {
        lock.lock(); defer { lock.unlock() }
        let target = url(account)
        guard let value, !value.isEmpty else { try? FileManager.default.removeItem(at: target); return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        // written whole to a file only this user can read, then moved over the old one
        let temp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let bytes = Array(value.utf8)
        var written = 0
        while written < bytes.count { let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }; if n <= 0 { break }; written += n }
        fsync(fd); close(fd)
        guard written == bytes.count, rename(temp.path, target.path) == 0 else { try? fm.removeItem(at: temp); return }
    }
}

/// The macOS Keychain (generic passwords under a service named after the app's bundle identifier, or another service when given).
///
/// Keychain items are guarded by the identity of the app that made them: another build asking for them gets the system's "wants to use your
/// confidential information" prompt, which wants the login password. So each build keeps its own items: a preview or development build never
/// asks for the release app's. Snapshot renders and `AUREON_NO_KEYCHAIN=1` never touch the Keychain at all (secrets stay in memory).
/// Every time something asks the real Keychain (macOS may ask the person for a password when that happens), so a test can prove that start-up never does.
enum KeychainAudit {
    nonisolated(unsafe) private static var entries: [String] = []
    private static let lock = NSLock()
    static func note(_ what: String) { lock.lock(); entries.append(what); lock.unlock() }
    static var accesses: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    static func reset() { lock.lock(); entries = []; lock.unlock() }
}

final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    private let memory: MemorySecretStore?
    init(service: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        let skip = service == nil && (env["AUREON_NO_KEYCHAIN"] != nil || env["AUREON_SNAPSHOT"] != nil)
        self.memory = skip ? MemorySecretStore() : nil
        self.service = service ?? Bundle.main.bundleIdentifier ?? "org.aureon.player.dev"
    }
    func get(_ account: String) -> String? {
        if let memory { return memory.get(account) }
        KeychainAudit.note("get \(service)/\(account)")
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    func set(_ value: String?, for account: String) {
        if let memory { memory.set(value, for: account); return }
        KeychainAudit.note("set \(service)/\(account)")
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

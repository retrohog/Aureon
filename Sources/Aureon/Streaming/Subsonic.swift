import Foundation
import CryptoKit

// Self-hosted music servers (Navidrome, Gonic, Airsonic, Subsonic, Jellyfin's Subsonic plugin …) speak the Subsonic / OpenSubsonic API.
// Their files stream into the same chunk reader as a bucket does, so FLAC plays through the normal engine: RAM buffer, DSP, integer mode.
//
// This is the sanctioned way to stream lossless music in a third-party player. Tidal, Qobuz and Spotify give lossless streams only to
// their own apps and approved partners (encrypted manifests, per-app keys), so Aureon does not pretend to log in to them.

struct SubsonicProfile: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString.prefix(8).lowercased().description
    var name = ""
    var url = ""                      // https://music.example.com
    var username = ""
    var secretAccount: String { "subsonic.\(id)" }
}

struct SubsonicSong: Equatable, Sendable {
    var id: String
    var title: String
    var album: String?
    var albumID: String?
    var artist: String?
    var albumArtist: String?
    var track: Int?
    var disc: Int?
    var year: Int?
    var genre: String?
    var duration: Double
    var size: Int64
    var suffix: String
    var sampleRate: Double?
    var bitDepth: Int?
    var channels: Int?
    var musicBrainzID: String?
    var coverArt: String?
}

struct SubsonicAlbum: Equatable, Sendable { var id: String; var name: String; var artist: String?; var songCount: Int }

enum SubsonicError: LocalizedError {
    case server(Int, String)
    case badAnswer(String)
    var errorDescription: String? {
        switch self {
        case .server(let code, let m):
            switch code {
            case 40, 41: return "The server rejected the user name or password."
            case 50: return "This user is not allowed to do that."
            default: return "The server said: \(m) (\(code))."
            }
        case .badAnswer(let m): return m
        }
    }
}

final class SubsonicClient: @unchecked Sendable {
    let base: URL
    let username: String
    private let password: String
    private let http: HTTPClient
    /// Fixed salt in tests.
    var salt: () -> String = { (0..<8).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined() }

    init?(urlString: String, username: String, password: String, http: HTTPClient = S3HTTP.shared) {
        var s = urlString.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.host != nil else { return nil }
        base = u; self.username = username; self.password = password; self.http = http
    }

    private func authItems() -> [URLQueryItem] {
        let s = salt()
        let token = Insecure.MD5.hash(data: Data((password + s).utf8)).map { String(format: "%02x", $0) }.joined()
        return [URLQueryItem(name: "u", value: username), URLQueryItem(name: "t", value: token), URLQueryItem(name: "s", value: s),
                URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "Aureon"), URLQueryItem(name: "f", value: "json")]
    }

    func url(_ method: String, _ items: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: base.appendingPathComponent("rest").appendingPathComponent(method), resolvingAgainstBaseURL: false)!
        c.queryItems = authItems() + items
        // "+" in a query means a space to most servers: encode it explicitly
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    private func call(_ method: String, _ items: [URLQueryItem] = []) async throws -> JSONObject {
        var req = URLRequest(url: url(method, items))
        req.timeoutInterval = 30
        let (d, status) = try await http.send(req)
        guard status == 200 else { throw status == 401 || status == 403 ? SubsonicError.server(40, "unauthorised") : SubsonicError.badAnswer("The server answered HTTP \(status). Check the address.") }
        guard let root = (try? parseJSON(d))?.obj("subsonic-response") else { throw SubsonicError.badAnswer("That address does not answer like a Subsonic-compatible server.") }
        if root.str("status") != "ok" {
            let e = root.obj("error")
            throw SubsonicError.server(Int(e?.num("code") ?? 0), e?.str("message") ?? "unknown error")
        }
        return root
    }

    struct ServerInfo: Equatable { var apiVersion: String; var type: String?; var serverVersion: String?; var openSubsonic: Bool }

    func ping() async throws -> ServerInfo {
        let r = try await call("ping")
        return ServerInfo(apiVersion: r.str("version") ?? "?", type: r.str("type"), serverVersion: r.str("serverVersion"), openSubsonic: (r["openSubsonic"] as? Bool) ?? false)
    }

    func albums(offset: Int, size: Int = 500) async throws -> [SubsonicAlbum] {
        let r = try await call("getAlbumList2", [URLQueryItem(name: "type", value: "alphabeticalByName"), URLQueryItem(name: "size", value: "\(size)"), URLQueryItem(name: "offset", value: "\(offset)")])
        return (r.obj("albumList2")?.arr("album") ?? []).compactMap { a in
            guard let id = a.str("id") else { return nil }
            return SubsonicAlbum(id: id, name: a.str("name") ?? a.str("title") ?? "", artist: a.str("artist"), songCount: Int(a.num("songCount") ?? 0))
        }
    }

    func songs(inAlbum id: String) async throws -> [SubsonicSong] {
        let r = try await call("getAlbum", [URLQueryItem(name: "id", value: id)])
        return (r.obj("album")?.arr("song") ?? []).compactMap(Self.song)
    }

    func song(id: String) async throws -> SubsonicSong? {
        Self.song(try await call("getSong", [URLQueryItem(name: "id", value: id)]).obj("song") ?? [:])
    }

    static func song(_ s: JSONObject) -> SubsonicSong? {
        guard let id = s.str("id"), let title = s.str("title") else { return nil }
        if (s["isDir"] as? Bool) == true { return nil }
        var suffix = s.str("suffix") ?? ""
        if suffix.isEmpty, let p = s.str("path") { suffix = (p as NSString).pathExtension }
        return SubsonicSong(id: id, title: title, album: s.str("album"), albumID: s.str("albumId"), artist: s.str("artist"), albumArtist: s.str("albumArtist") ?? (s.arr("albumArtists").first?.str("name")),
                            track: s.num("track").map(Int.init), disc: s.num("discNumber").map(Int.init), year: s.num("year").map(Int.init), genre: s.str("genre") ?? s.arr("genres").first?.str("name"),
                            duration: s.num("duration") ?? 0, size: Int64(s.num("size") ?? 0), suffix: suffix.lowercased(),
                            sampleRate: s.num("samplingRate"), bitDepth: s.num("bitDepth").map(Int.init), channels: s.num("channelCount").map(Int.init),
                            musicBrainzID: s.str("musicBrainzId"), coverArt: s.str("coverArt"))
    }

    /// The original file, byte for byte (the `download` call never transcodes) and with range support.
    func downloadURL(id: String) -> URL { url("download", [URLQueryItem(name: "id", value: id)]) }
    func coverArtURL(id: String, size: Int = 600) -> URL { url("getCoverArt", [URLQueryItem(name: "id", value: id), URLQueryItem(name: "size", value: "\(size)")]) }

    func coverArt(id: String) async throws -> Data? {
        let (d, status) = try await http.send(URLRequest(url: coverArtURL(id: id)))
        return status == 200 && !d.isEmpty && (try? parseJSON(d)) == nil ? d : nil
    }

    func fetcher(songID: String, size: Int64) -> HTTPRangeFetcher { HTTPRangeFetcher(url: downloadURL(id: songID), size: size, http: http) }
}

/// Byte ranges of a plain HTTP resource.
struct HTTPRangeFetcher: RangeFetcher {
    let url: URL
    let size: Int64
    let http: HTTPClient

    func fetch(offset: Int64, length: Int) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 30
        let (d, status) = try await http.send(req)
        switch status {
        case 206: return d
        case 200:
            // a server that ignores Range sends the whole file: usable only from the start
            guard offset == 0, d.count >= length else { throw NetworkError.badResponse("The server does not support partial downloads, so this file cannot be streamed.") }
            return d.prefix(length)
        case 416: return Data()
        default: throw NetworkError.status(status, url.host ?? "server")
        }
    }
}

import Foundation

// MusicBrainz: recordings, artists, works and their relationships (session musicians, producers, composers).
// API: https://musicbrainz.org/doc/MusicBrainz_API — JSON via fmt=json, one request per second, descriptive User-Agent.

struct MBArtistRef: Codable, Hashable { var id: String; var name: String; var sortName: String? = nil }

struct MBRelease: Codable, Hashable {
    var id: String, title: String
    var date: String?, country: String?, status: String?
    var releaseGroupID: String?, releaseGroupTitle: String?, primaryType: String?
}

/// A person credited on a recording, with everything they did.
struct MBCredit: Codable, Hashable {
    enum Group: String, Codable { case performance, production, composition }
    var group: Group
    var artistID: String
    var name: String
    var roles: [String]               // "vocals", "producer", "mix", …
    var instruments: [String]         // "piano", "tenor saxophone", …
}

struct MBWork: Codable, Hashable {
    var id: String, title: String
    var type: String?, language: String?
    var composers: [MBArtistRef], lyricists: [MBArtistRef]
}

struct MBRecording: Codable, Hashable {
    var id: String, title: String
    var lengthMs: Int?
    var disambiguation: String?
    var firstReleaseDate: String?
    var artists: [MBArtistRef]
    var releases: [MBRelease]
    var credits: [MBCredit]
    var works: [MBWork]
    var genres: [String]
    var isrcs: [String]
}

struct MBArtist: Codable, Hashable {
    var id: String, name: String
    var sortName: String?, type: String?, disambiguation: String?
    var country: String?, area: String?
    var begin: String?, end: String?
    var annotation: String?
    var genres: [String]
    var wikipediaTitle: String?, wikipediaLanguage: String?
    var wikidataID: String?
    var homepage: String?
}

enum MusicBrainzParser {
    static let performanceTypes: Set<String> = ["instrument", "vocal", "performer", "performing orchestra", "orchestra", "conductor", "chorus master", "concertmaster", "remixer", "dj-mix", "performance"]
    static let productionTypes: Set<String> = ["producer", "engineer", "mix", "recording", "mastering", "sound", "audio", "programming", "balance", "editor", "executive producer", "co-producer", "assistant producer", "assistant engineer", "recording engineer", "mixer", "mastering engineer", "live sound"]
    static let compositionTypes: Set<String> = ["composer", "lyricist", "writer", "arranger", "orchestrator", "librettist", "translator", "instrumentator"]

    static func artistRef(_ j: JSONObject?) -> MBArtistRef? {
        guard let j, let id = j.str("id"), let name = j.str("name") else { return nil }
        return MBArtistRef(id: id, name: name, sortName: j.str("sort-name"))
    }

    static func creditList(_ arr: [JSONObject]) -> [MBArtistRef] { arr.compactMap { artistRef($0.obj("artist")) } }

    /// Parses a recording lookup (inc=artists+releases+release-groups+artist-rels+work-rels+work-level-rels+genres+isrcs).
    static func recording(_ d: Data) throws -> MBRecording {
        let j = try parseJSON(d)
        guard let id = j.str("id"), let title = j.str("title") else { throw NetworkError.badResponse("not a recording") }
        var credits: [MBCredit] = [], works: [MBWork] = []
        var index: [String: Int] = [:]
        func add(_ group: MBCredit.Group, _ a: MBArtistRef, role: String?, instruments: [String]) {
            let k = group.rawValue + "|" + a.id
            if let i = index[k] {
                if let r = role, !credits[i].roles.contains(r) { credits[i].roles.append(r) }
                for ins in instruments where !credits[i].instruments.contains(ins) { credits[i].instruments.append(ins) }
            } else {
                index[k] = credits.count
                credits.append(MBCredit(group: group, artistID: a.id, name: a.name, roles: role.map { [$0] } ?? [], instruments: instruments))
            }
        }
        for r in j.arr("relations") {
            let type = (r.str("type") ?? "").lowercased(), target = r.str("target-type") ?? ""
            if target == "artist", let a = artistRef(r.obj("artist")) {
                let attrs = r.strs("attributes")
                if type == "instrument" { add(.performance, a, role: nil, instruments: attrs) }
                else if type == "vocal" { add(.performance, a, role: attrs.isEmpty ? "vocals" : attrs.joined(separator: ", "), instruments: []) }
                else if performanceTypes.contains(type) { add(.performance, a, role: type, instruments: attrs) }
                else if productionTypes.contains(type) { add(.production, a, role: ([type] + attrs).joined(separator: " "), instruments: []) }
                else if compositionTypes.contains(type) { add(.composition, a, role: type, instruments: []) }
            } else if target == "work", type == "performance", let w = r.obj("work"), let wid = w.str("id"), let wt = w.str("title") {
                let rels = w.arr("relations")
                func people(_ types: Set<String>) -> [MBArtistRef] { rels.filter { types.contains(($0.str("type") ?? "").lowercased()) }.compactMap { artistRef($0.obj("artist")) } }
                let composers = people(["composer", "writer"]), lyricists = people(["lyricist"])
                works.append(MBWork(id: wid, title: wt, type: w.str("type"), language: w.str("language"), composers: composers, lyricists: lyricists))
                for c in composers { add(.composition, c, role: "composer", instruments: []) }
                for l in lyricists { add(.composition, l, role: "lyricist", instruments: []) }
            }
        }
        let releases: [MBRelease] = j.arr("releases").compactMap { r in
            guard let rid = r.str("id"), let rt = r.str("title") else { return nil }
            let rg = r.obj("release-group")
            return MBRelease(id: rid, title: rt, date: r.str("date"), country: r.str("country"), status: r.str("status"),
                             releaseGroupID: rg?.str("id"), releaseGroupTitle: rg?.str("title"), primaryType: rg?.str("primary-type"))
        }
        return MBRecording(id: id, title: title, lengthMs: j.num("length").map { Int($0) }, disambiguation: j.str("disambiguation").flatMap { $0.isEmpty ? nil : $0 },
                           firstReleaseDate: j.str("first-release-date"), artists: creditList(j.arr("artist-credit")), releases: releases, credits: credits, works: works,
                           genres: j.arr("genres").sorted { ($0.num("count") ?? 0) > ($1.num("count") ?? 0) }.compactMap { $0.str("name") }, isrcs: j.strs("isrcs"))
    }

    /// Parses an artist lookup (inc=url-rels+genres+annotation).
    static func artist(_ d: Data) throws -> MBArtist {
        let j = try parseJSON(d)
        guard let id = j.str("id"), let name = j.str("name") else { throw NetworkError.badResponse("not an artist") }
        var a = MBArtist(id: id, name: name, sortName: j.str("sort-name"), type: j.str("type"), disambiguation: j.str("disambiguation").flatMap { $0.isEmpty ? nil : $0 },
                         country: j.str("country"), area: j.obj("area")?.str("name"), begin: j.obj("life-span")?.str("begin"), end: j.obj("life-span")?.str("end"),
                         annotation: j.str("annotation"), genres: j.arr("genres").sorted { ($0.num("count") ?? 0) > ($1.num("count") ?? 0) }.compactMap { $0.str("name") })
        for r in j.arr("relations") where r.str("target-type") == "url" {
            guard let url = r.obj("url")?.str("resource") else { continue }
            switch (r.str("type") ?? "").lowercased() {
            case "wikipedia":
                if let u = URL(string: url), let host = u.host, host.hasSuffix(".wikipedia.org"), u.pathComponents.count >= 3 {
                    a.wikipediaLanguage = String(host.prefix(while: { $0 != "." })); a.wikipediaTitle = u.pathComponents[2].removingPercentEncoding ?? u.pathComponents[2]
                }
            case "wikidata": a.wikidataID = URL(string: url)?.lastPathComponent
            case "official homepage": a.homepage = a.homepage ?? url
            default: break
            }
        }
        return a
    }
}

final class MusicBrainzClient: @unchecked Sendable {
    private let http: HTTPClient, identity: ClientIdentity, limiter: RateLimiter, cache: MetadataCache
    /// Pause before retrying after a 503/429 (MusicBrainz sheds load by rejecting requests).
    var retryDelay: TimeInterval = 1.5
    static let base = "https://musicbrainz.org/ws/2/"

    init(http: HTTPClient = URLSessionClient(), identity: ClientIdentity = ClientIdentity(), cache: MetadataCache = MetadataCache(), minInterval: TimeInterval = 1.05) {
        self.http = http; self.identity = identity; self.cache = cache; limiter = RateLimiter(interval: minInterval)
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> Data {
        var c = URLComponents(string: Self.base + path)!
        c.queryItems = (query.merging(["fmt": "json"]) { a, _ in a }).sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!); req.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent"); req.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<3 {
            await limiter.wait()
            let (d, status) = try await http.send(req)
            if status == 200 { return d }
            if (status == 503 || status == 429) && attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000)); continue }   // rate limited: back off, retry
            throw NetworkError.status(status, path)
        }
        throw NetworkError.status(503, path)
    }

    func recording(id: String) async throws -> MBRecording {
        if let c: MBRecording = cache.get("mb-recording-\(id)", ttl: 30 * 86_400) { return c }
        let d = try await get("recording/\(id)", ["inc": "artists+releases+release-groups+artist-rels+work-rels+work-level-rels+genres+isrcs"])
        let r = try MusicBrainzParser.recording(d)
        cache.put("mb-recording-\(id)", r)
        return r
    }

    func artist(id: String) async throws -> MBArtist {
        if let c: MBArtist = cache.get("mb-artist-\(id)", ttl: 30 * 86_400) { return c }
        let d = try await get("artist/\(id)", ["inc": "url-rels+genres+annotation"])
        let a = try MusicBrainzParser.artist(d)
        cache.put("mb-artist-\(id)", a)
        return a
    }
}

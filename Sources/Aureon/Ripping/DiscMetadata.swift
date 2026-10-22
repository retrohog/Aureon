import Foundation

/// A MusicBrainz release that contains this disc, with the medium (disc) that matched and its tracks.
struct MBDiscRelease: Equatable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var date: String?
    var country: String?
    var label: String?
    var genre: String?
    var hasFrontCover: Bool
    var mediumPosition: Int
    var mediumCount: Int
    var tracks: [Track]

    struct Track: Equatable { var number: Int; var title: String; var artist: String; var recordingID: String?; var lengthMs: Int? }

    var year: String { String((date ?? "").prefix(4)) }
    var summary: String { [artist, year, country, label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }

    func metadata(discID: String) -> RipMetadata {
        var m = RipMetadata()
        m.album = mediumCount > 1 ? "\(title) (disc \(mediumPosition))" : title
        m.albumArtist = artist; m.year = year; m.genre = genre ?? ""; m.releaseID = id; m.discID = discID
        for t in tracks { m.tracks[t.number] = .init(title: t.title, artist: t.artist, recordingID: t.recordingID) }
        return m
    }
}

extension MusicBrainzParser {
    private static func credit(_ arr: [JSONObject]) -> String {
        arr.map { ($0.str("name") ?? $0.obj("artist")?.str("name") ?? "") + ($0.str("joinphrase") ?? "") }.joined()
    }

    /// Parses the answer of `discid/<id>?inc=recordings+artist-credits+release-groups+labels`: every release that has the disc, with the medium that carries it.
    static func discReleases(_ d: Data, discID: String) throws -> [MBDiscRelease] {
        let j = try parseJSON(d)
        return j.arr("releases").compactMap { r -> MBDiscRelease? in
            guard let id = r.str("id"), let title = r.str("title") else { return nil }
            let media = r.arr("media")
            // the medium that holds this disc; a fuzzy match by table of contents has none and falls back to the first
            let medium = media.first { $0.arr("discs").contains { $0.str("id") == discID } } ?? media.first
            guard let medium else { return nil }
            let tracks: [MBDiscRelease.Track] = medium.arr("tracks").enumerated().map { i, t in
                let recording = t.obj("recording")
                let artist = credit(t.arr("artist-credit")).isEmpty ? credit(recording?.arr("artist-credit") ?? []) : credit(t.arr("artist-credit"))
                return MBDiscRelease.Track(number: Int(t.str("number") ?? "") ?? t.num("position").map(Int.init) ?? i + 1, title: t.str("title") ?? recording?.str("title") ?? "Track \(i + 1)",
                                           artist: artist, recordingID: recording?.str("id"), lengthMs: t.num("length").map(Int.init) ?? recording?.num("length").map(Int.init))
            }
            let label = r.arr("label-info").compactMap { $0.obj("label")?.str("name") }.first
            let genre = r.obj("release-group")?.arr("genres").first?.str("name")
            return MBDiscRelease(id: id, title: title, artist: credit(r.arr("artist-credit")), date: r.str("date"), country: r.str("country"), label: label, genre: genre,
                                 hasFrontCover: (r.obj("cover-art-archive")?["front"] as? Bool) ?? false, mediumPosition: medium.num("position").map(Int.init) ?? 1, mediumCount: media.count, tracks: tracks)
        }
    }
}

extension MusicBrainzClient {
    /// Looks a disc up by its ID (and, failing that, by its table of contents). Results are cached for a month.
    func discReleases(for toc: CDTOC) async throws -> [MBDiscRelease] {
        let id = toc.musicBrainzDiscID
        let key = "mb-disc-\(id)"
        if let cached: [CachedDiscRelease] = metadataCache.get(key, ttl: 30 * 86_400) { return cached.map(\.release) }
        let d = try await request("discid/\(id)", ["inc": "recordings+artist-credits+release-groups+labels", "toc": toc.musicBrainzTOCString, "cdstubs": "no"])
        let r = try MusicBrainzParser.discReleases(d, discID: id)
        metadataCache.put(key, r.map(CachedDiscRelease.init))
        return r
    }
}

/// Codable wrapper so lookups can be cached on disk.
struct CachedDiscRelease: Codable {
    var id, title, artist: String; var date, country, label, genre: String?; var hasFrontCover: Bool; var mediumPosition, mediumCount: Int
    var tracks: [[String]]                       // number, title, artist, recordingID, lengthMs
    init(_ r: MBDiscRelease) {
        id = r.id; title = r.title; artist = r.artist; date = r.date; country = r.country; label = r.label; genre = r.genre; hasFrontCover = r.hasFrontCover
        mediumPosition = r.mediumPosition; mediumCount = r.mediumCount
        tracks = r.tracks.map { ["\($0.number)", $0.title, $0.artist, $0.recordingID ?? "", $0.lengthMs.map(String.init) ?? ""] }
    }
    var release: MBDiscRelease {
        MBDiscRelease(id: id, title: title, artist: artist, date: date, country: country, label: label, genre: genre, hasFrontCover: hasFrontCover, mediumPosition: mediumPosition, mediumCount: mediumCount,
                      tracks: tracks.map { MBDiscRelease.Track(number: Int($0[0]) ?? 0, title: $0[1], artist: $0[2], recordingID: $0[3].isEmpty ? nil : $0[3], lengthMs: Int($0[4])) })
    }
}

enum CoverArt {
    /// The front cover of a release from the Cover Art Archive, or nil when there is none.
    static func front(releaseID: String, http: HTTPClient = URLSessionClient()) async -> Data? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/front-500") else { return nil }
        var req = URLRequest(url: url); req.setValue(ClientIdentity().userAgent, forHTTPHeaderField: "User-Agent")
        guard let (d, status) = try? await http.send(req), status == 200, d.count > 100 else { return nil }
        return d
    }
}

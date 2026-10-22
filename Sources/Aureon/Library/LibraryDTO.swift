import Foundation

// Plain value types returned by the library. No Core Data object ever leaves the store, so the UI, the remote
// protocol and the tests all work with the same Codable structs.

struct CreditDTO: Codable, Hashable {
    var role: String
    var name: String
    var instrument: String?
    var partyID: String
}

struct TrackDTO: Codable, Identifiable, Hashable {
    var id: String
    var path: String
    var title: String
    var trackNumber: Int?
    var discNumber: Int?
    var duration: Double
    var codec: String
    var sampleRate: Double
    var bitDepth: Int
    var channels: Int
    var year: Int?
    var releaseID: String?
    var releaseTitle: String?
    var workID: String?
    var workTitle: String?
    var catalog: String?
    var movementID: String?
    var movementNumber: Int?
    var movementTitle: String?
    var credits: [CreditDTO]
    var genres: [String]
    var mbRecordingID: String?
    var addedAt: Double? = nil
    // optional so remote peers and libraries from older versions still decode
    var fileSize: Int64? = nil
    var liked: Bool? = nil
    var playCount: Int? = nil
    var lastPlayedAt: Double? = nil
    // EBU R128 figures, filled in by the loudness analysis
    var lufs: Double? = nil
    var truePeakDB: Double? = nil
    var lra: Double? = nil
    var dr: Double? = nil

    func names(_ role: CreditRole) -> [String] { credits.filter { $0.role == role.rawValue }.map(\.name) }
    /// "Artist" or "Artist feat. Guest".
    var artistLine: String {
        let a = names(.artist), f = names(.featured)
        let main = a.isEmpty ? names(.albumArtist).joined(separator: ", ") : a.joined(separator: ", ")
        return f.isEmpty ? main : main + " feat. " + f.joined(separator: ", ")
    }
    /// The artists the track belongs to, without the featured guests.
    var primaryArtistLine: String { let a = names(.artist); return a.isEmpty ? names(.albumArtist).joined(separator: ", ") : a.joined(separator: ", ") }
    var isLiked: Bool { liked == true }
}

struct PlaylistDTO: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var trackCount: Int
    var duration: Double
    var createdAt: Double
    var updatedAt: Double
}

struct PartyDTO: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var sortName: String
    var kind: String                 // "person" | "group"
    var count: Int                   // tracks credited (in the queried role, if any)
    var mbArtistID: String?
}

struct WorkDTO: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var catalog: String?
    var key: String?
    var composerID: String?
    var composerName: String?
    var movementCount: Int
    var trackCount: Int
    var recordingCount: Int
}

struct ReleaseDTO: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var year: Int?
    var trackCount: Int
    var artistNames: [String]
    var mbReleaseID: String?
    // aggregated from the album's tracks; optional so libraries and remote peers from older versions still decode
    var maxSampleRate: Double?
    var maxBitDepth: Int?
    var genre: String?
    var addedAt: Double?

    var isHiRes: Bool { (maxSampleRate ?? 0) > 48_000 || (maxBitDepth ?? 0) > 16 }
    var isDSD: Bool { maxBitDepth == 1 }
}

/// One recording of a work: the tracks of that work on one release, with who performed them.
struct RecordingGroupDTO: Codable, Identifiable, Hashable {
    var id: String                   // release id
    var releaseTitle: String
    var year: Int?
    var performers: [CreditDTO]      // conductor, ensembles, soloists, in that order
    var tracks: [TrackDTO]           // ordered by movement number
}

struct LibraryChange: Codable, Hashable {
    var seq: Int64                   // unique position in the change log
    var revision: Int64
    var kind: String                 // track | release | party | work
    var uid: String
    var op: String                   // upsert | delete
    var track: TrackDTO?
    var party: PartyDTO?
    var release: ReleaseDTO?
    var work: WorkDTO?
}

struct LibraryStats: Codable, Equatable {
    var tracks = 0, releases = 0, works = 0, composers = 0, artists = 0, revision: Int64 = 0
}

struct SearchResults: Codable, Equatable {
    var tracks: [TrackDTO] = []
    var works: [WorkDTO] = []
    var parties: [PartyDTO] = []
    var releases: [ReleaseDTO] = []
}

/// What the importer knows about a file besides its tags.
struct FileFacts: Equatable {
    var path: String
    var duration: Double = 0
    var sampleRate: Double = 0
    var bitDepth: Int = 0
    var channels: Int = 0
    var codec: String = ""
    var mtime: Double = 0
    var size: Int64 = 0
}

struct ImportReport: Equatable {
    var scanned = 0, added = 0, updated = 0, skipped = 0, removed = 0, failed = 0
    var errors: [String] = []
}

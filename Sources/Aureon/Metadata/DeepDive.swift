import Foundation

struct ArtistProfile: Codable, Hashable {
    var artist: MBArtist
    var bio: WikiSummary?
}

/// Everything the "Deep Dive" view shows about the playing track.
struct DeepDive: Codable, Hashable {
    var recording: MBRecording
    var identifiedBy: String               // "file tags" or "AcoustID fingerprint (97%)"
    var artists: [ArtistProfile]
    var coverReleaseGroupID: String?
    var fetchedAt: Date

    func credits(_ g: MBCredit.Group) -> [MBCredit] { recording.credits.filter { $0.group == g } }
}

enum DeepDiveStage: String { case fingerprinting = "Fingerprinting", identifying = "Identifying with AcoustID", loadingRecording = "Loading from MusicBrainz", loadingArtists = "Loading artist biographies" }

final class DeepDiveService: @unchecked Sendable {
    private let fingerprinter: Fingerprinter
    private let acoustid: AcoustIDClient
    private let musicbrainz: MusicBrainzClient
    private let wikipedia: WikipediaClient
    private let cache: MetadataCache
    var apiKey: @Sendable () -> String
    var minimumScore = 0.75

    init(fingerprinter: Fingerprinter = FpcalcFingerprinter(), acoustid: AcoustIDClient, musicbrainz: MusicBrainzClient, wikipedia: WikipediaClient,
         cache: MetadataCache = MetadataCache(), apiKey: @escaping @Sendable () -> String) {
        self.fingerprinter = fingerprinter; self.acoustid = acoustid; self.musicbrainz = musicbrainz; self.wikipedia = wikipedia; self.cache = cache; self.apiKey = apiKey
    }

    static func chooseCover(_ r: MBRecording) -> String? {
        let withGroup = r.releases.filter { $0.releaseGroupID != nil }
        let albums = withGroup.filter { $0.primaryType == "Album" }
        return ((albums.isEmpty ? withGroup : albums).min { ($0.date ?? "9999") < ($1.date ?? "9999") })?.releaseGroupID
    }

    /// Identifies the file (tags first, fingerprint otherwise), then gathers recording, credits and artist biographies.
    func load(path: String, knownRecordingID: String?, progress: @Sendable (DeepDiveStage) -> Void = { _ in }) async throws -> DeepDive {
        var id = knownRecordingID, how = "file tags"
        if id == nil {
            progress(.fingerprinting)
            let fp = try await fingerprinter.fingerprint(path: path)
            progress(.identifying)
            let matches = try await acoustid.lookup(fp, apiKey: apiKey())
            guard let best = matches.first, best.score >= minimumScore else {
                throw AureonError.message(matches.isEmpty ? "AcoustID does not know this recording." : String(format: "The best AcoustID match is only %.0f%% certain; not using it.", (matches.first?.score ?? 0) * 100))
            }
            id = best.recordingID; how = String(format: "AcoustID fingerprint (%.0f%%)", best.score * 100)
        }
        if let c: DeepDive = cache.get("deepdive-\(id!)", ttl: 14 * 86_400) { return DeepDive(recording: c.recording, identifiedBy: how, artists: c.artists, coverReleaseGroupID: c.coverReleaseGroupID, fetchedAt: c.fetchedAt) }

        progress(.loadingRecording)
        let rec = try await musicbrainz.recording(id: id!)
        progress(.loadingArtists)
        var profiles: [ArtistProfile] = []
        for ref in rec.artists.prefix(3) {
            guard let a = try? await musicbrainz.artist(id: ref.id) else { continue }
            var bio: WikiSummary?
            if let t = a.wikipediaTitle { bio = try? await wikipedia.summary(title: t, language: a.wikipediaLanguage ?? "en") }
            if bio == nil, let q = a.wikidataID { bio = try? await wikipedia.summary(wikidataID: q) }
            profiles.append(ArtistProfile(artist: a, bio: bio))
        }
        let dive = DeepDive(recording: rec, identifiedBy: how, artists: profiles, coverReleaseGroupID: Self.chooseCover(rec), fetchedAt: Date())
        cache.put("deepdive-\(id!)", dive)
        return dive
    }
}

/// A fully populated example for previews, screenshots and tests.
extension DeepDive {
    static let sample: DeepDive = {
        let miles = MBArtistRef(id: "a1", name: "Miles Davis", sortName: "Davis, Miles")
        let rec = MBRecording(id: "b9c6bcfa-89eb-4b01-83b2-49327ee2e896", title: "So What", lengthMs: 562_000, disambiguation: nil, firstReleaseDate: "1959-08-17", artists: [miles],
            releases: [MBRelease(id: "r1", title: "Kind of Blue", date: "1959-08-17", country: "US", status: "Official", releaseGroupID: "rg1", releaseGroupTitle: "Kind of Blue", primaryType: "Album")],
            credits: [
                MBCredit(group: .performance, artistID: "a1", name: "Miles Davis", roles: [], instruments: ["trumpet"]),
                MBCredit(group: .performance, artistID: "a2", name: "John Coltrane", roles: [], instruments: ["tenor saxophone"]),
                MBCredit(group: .performance, artistID: "a3", name: "Julian “Cannonball” Adderley", roles: [], instruments: ["alto saxophone"]),
                MBCredit(group: .performance, artistID: "a4", name: "Bill Evans", roles: [], instruments: ["piano"]),
                MBCredit(group: .performance, artistID: "a5", name: "Paul Chambers", roles: [], instruments: ["double bass"]),
                MBCredit(group: .performance, artistID: "a6", name: "Jimmy Cobb", roles: [], instruments: ["drums"]),
                MBCredit(group: .production, artistID: "a7", name: "Teo Macero", roles: ["producer"], instruments: []),
                MBCredit(group: .production, artistID: "a8", name: "Irving Townsend", roles: ["producer"], instruments: []),
                MBCredit(group: .composition, artistID: "a1", name: "Miles Davis", roles: ["composer"], instruments: []),
            ],
            works: [MBWork(id: "w1", title: "So What", type: "Song", language: nil, composers: [miles], lyricists: [])],
            genres: ["jazz", "modal jazz", "cool jazz"], isrcs: ["USSM15900001"])
        let bio = WikiSummary(title: "Miles Davis", description: "American jazz trumpeter and bandleader (1926–1991)",
                              extract: "Miles Dewey Davis III was an American trumpeter, bandleader, and composer. He is among the most influential and acclaimed figures in the history of jazz and 20th-century music.",
                              pageURL: "https://en.wikipedia.org/wiki/Miles_Davis", thumbnailURL: nil, language: "en")
        let art = MBArtist(id: "a1", name: "Miles Davis", sortName: "Davis, Miles", type: "Person", disambiguation: nil, country: "US", area: "United States", begin: "1926-05-26", end: "1991-09-28",
                           annotation: nil, genres: ["jazz", "cool jazz", "bebop"], wikipediaTitle: "Miles_Davis", wikipediaLanguage: "en", wikidataID: "Q93341", homepage: "https://www.milesdavis.com/")
        return DeepDive(recording: rec, identifiedBy: "AcoustID fingerprint (98%)", artists: [ArtistProfile(artist: art, bio: bio)], coverReleaseGroupID: "rg1", fetchedAt: Date())
    }()
}

import Foundation

/// Canned HTTP for the online services. Routes match on a URL substring; a route can return a sequence of statuses.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    struct Route { var match: String; var bodies: [(Data, Int)]; var hits = 0 }
    private let lock = NSLock()
    private(set) var routes: [Route] = []
    private(set) var requests: [URLRequest] = []

    func on(_ match: String, _ json: String, status: Int = 200) { on(match, [(Data(json.utf8), status)]) }
    func on(_ match: String, _ bodies: [(Data, Int)]) { lock.lock(); routes.append(Route(match: match, bodies: bodies)); lock.unlock() }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let url = request.url?.absoluteString ?? ""
        guard let i = routes.firstIndex(where: { url.contains($0.match) }) else { return (Data(), 404) }
        let r = routes[i].bodies[min(routes[i].hits, routes[i].bodies.count - 1)]
        routes[i].hits += 1
        return r
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    func urls() -> [String] { lock.lock(); defer { lock.unlock() }; return requests.compactMap { $0.url?.absoluteString } }
}

final class AsyncBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

/// Runs an async operation to completion from a synchronous test.
func runAsync<T: Sendable>(timeout: TimeInterval = 30, _ op: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = AsyncBox<T>(), sem = DispatchSemaphore(value: 0)
    Task.detached { do { box.result = .success(try await op()) } catch { box.result = .failure(error) }; sem.signal() }
    if sem.wait(timeout: .now() + timeout) == .timedOut { return .failure(AureonError.message("timed out")) }
    return box.result!
}

enum Fixtures {
    static let recording = """
    {"id":"rec-1","title":"So What","length":562000,"disambiguation":"","first-release-date":"1959-08-17","video":false,
     "artist-credit":[{"name":"Miles Davis","joinphrase":"","artist":{"id":"art-miles","name":"Miles Davis","sort-name":"Davis, Miles"}}],
     "releases":[{"id":"rel-2","title":"Kind of Blue (reissue)","date":"1997-08-26","country":"XW","status":"Official","release-group":{"id":"rg-1","title":"Kind of Blue","primary-type":"Album"}},
                 {"id":"rel-1","title":"Kind of Blue","date":"1959-08-17","country":"US","status":"Official","release-group":{"id":"rg-1","title":"Kind of Blue","primary-type":"Album"}},
                 {"id":"rel-3","title":"Best of","date":"1960","release-group":{"id":"rg-9","title":"Best of","primary-type":"Compilation"}}],
     "genres":[{"name":"jazz","count":9},{"name":"modal jazz","count":14}],"isrcs":["USSM15900001"],
     "relations":[
      {"type":"instrument","target-type":"artist","attributes":["trumpet"],"artist":{"id":"art-miles","name":"Miles Davis"}},
      {"type":"instrument","target-type":"artist","attributes":["tenor saxophone","soprano saxophone"],"artist":{"id":"art-trane","name":"John Coltrane"}},
      {"type":"instrument","target-type":"artist","attributes":["piano"],"artist":{"id":"art-evans","name":"Bill Evans"}},
      {"type":"vocal","target-type":"artist","attributes":["lead vocals"],"artist":{"id":"art-singer","name":"A Singer"}},
      {"type":"producer","target-type":"artist","attributes":[],"artist":{"id":"art-teo","name":"Teo Macero"}},
      {"type":"mix","target-type":"artist","attributes":[],"artist":{"id":"art-teo","name":"Teo Macero"}},
      {"type":"conductor","target-type":"artist","attributes":[],"artist":{"id":"art-gil","name":"Gil Evans"}},
      {"type":"performance","target-type":"work","work":{"id":"work-1","title":"So What","type":"Song","language":"zxx","relations":[
         {"type":"composer","target-type":"artist","artist":{"id":"art-miles","name":"Miles Davis"}},{"type":"lyricist","target-type":"artist","artist":{"id":"art-lyr","name":"A Lyricist"}}]}},
      {"type":"instrument","target-type":"artist","attributes":["piano"],"artist":{"id":"art-evans","name":"Bill Evans"}},
      {"type":"recording of","target-type":"url","url":{"resource":"https://example.com"}}
     ]}
    """
    static let recording2 = """
    {"id":"rec-2","title":"Duet","length":1000,"artist-credit":[{"name":"Miles Davis","joinphrase":" & ","artist":{"id":"art-miles","name":"Miles Davis"}},{"name":"Gil Evans","joinphrase":"","artist":{"id":"art-gil","name":"Gil Evans"}}],
     "releases":[],"genres":[],"isrcs":[],"relations":[]}
    """
    static let artistMiles = """
    {"id":"art-miles","name":"Miles Davis","sort-name":"Davis, Miles","type":"Person","disambiguation":"","country":"US","area":{"name":"United States"},
     "life-span":{"begin":"1926-05-26","end":"1991-09-28"},"annotation":"Trumpeter and bandleader.","genres":[{"name":"jazz","count":5},{"name":"bebop","count":9}],
     "relations":[{"type":"wikipedia","target-type":"url","url":{"resource":"https://en.wikipedia.org/wiki/Miles_Davis"}},
                  {"type":"wikidata","target-type":"url","url":{"resource":"https://www.wikidata.org/wiki/Q93341"}},
                  {"type":"official homepage","target-type":"url","url":{"resource":"https://www.milesdavis.com/"}},{"type":"member of band","target-type":"artist","artist":{"id":"x","name":"X"}}]}
    """
    static let artistGil = """
    {"id":"art-gil","name":"Gil Evans","sort-name":"Evans, Gil","type":"Person","life-span":{"begin":"1912-05-13"},"genres":[],
     "relations":[{"type":"wikidata","target-type":"url","url":{"resource":"https://www.wikidata.org/wiki/Q313437"}}]}
    """
    static let wikiMiles = """
    {"title":"Miles Davis","description":"American jazz trumpeter","extract":"Miles Dewey Davis III was an American trumpeter, bandleader, and composer.",
     "content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Miles_Davis"}},"thumbnail":{"source":"https://upload.wikimedia.org/miles.jpg"}}
    """
    static let wikiGil = #"{"title":"Gil Evans","extract":"Ian Ernest Gilmore Green, known as Gil Evans, was a Canadian jazz pianist, arranger, composer, and bandleader."}"#
    static let wikidata = #"{"entities":{"Q313437":{"sitelinks":{"enwiki":{"title":"Gil Evans"},"dewiki":{"title":"Gil Evans (Musiker)"}}}}}"#
    static let acoustid = """
    {"status":"ok","results":[{"id":"aa","score":0.60,"recordings":[{"id":"rec-weak","title":"Other","artists":[{"id":"art-x","name":"X"}]}]},
      {"id":"bb","score":0.98,"recordings":[{"id":"rec-1","title":"So What","artists":[{"id":"art-miles","name":"Miles Davis"}],
        "releasegroups":[{"id":"rg-1","title":"Kind of Blue","type":"Album"}]}]}]}
    """
}

struct MetadataTests {
    let dir = tempDir("meta")

    func cache() -> MetadataCache { MetadataCache(directory: dir.appendingPathComponent("c-\(UUID().uuidString.prefix(6))")) }
    func mb(_ http: StubHTTP, interval: TimeInterval = 0) -> MusicBrainzClient { let c = MusicBrainzClient(http: http, cache: cache(), minInterval: interval); c.retryDelay = 0.05; return c }

    func recordingParsing() {
        let r = try! MusicBrainzParser.recording(Data(Fixtures.recording.utf8))
        expect(r.id == "rec-1" && r.title == "So What" && r.lengthMs == 562_000 && r.firstReleaseDate == "1959-08-17" && r.disambiguation == nil)
        expect(r.artists == [MBArtistRef(id: "art-miles", name: "Miles Davis", sortName: "Davis, Miles")])
        expect(r.genres == ["modal jazz", "jazz"] && r.isrcs == ["USSM15900001"], "genres by vote count: \(r.genres)")
        let perf = r.credits.filter { $0.group == .performance }
        expect(perf.map(\.name) == ["Miles Davis", "John Coltrane", "Bill Evans", "A Singer", "Gil Evans"], "\(perf.map(\.name))")
        expect(perf[1].instruments == ["tenor saxophone", "soprano saxophone"] && perf[2].instruments == ["piano"], "a duplicate relation must not repeat the instrument")
        expect(perf[3].roles == ["lead vocals"] && perf[4].roles == ["conductor"])
        let prod = r.credits.filter { $0.group == .production }
        expect(prod.count == 1 && prod[0].name == "Teo Macero" && prod[0].roles == ["producer", "mix"], "one person, two production roles merged: \(prod)")
        let comp = r.credits.filter { $0.group == .composition }
        expect(comp.map { "\($0.name):\($0.roles.joined())" } == ["Miles Davis:composer", "A Lyricist:lyricist"], "composers come from the work relationship: \(comp.map(\.name))")
        expect(r.works.count == 1 && r.works[0].composers.map(\.name) == ["Miles Davis"] && r.works[0].lyricists.map(\.name) == ["A Lyricist"] && r.works[0].title == "So What")
        expect(r.releases.count == 3 && r.releases[1].releaseGroupID == "rg-1" && r.releases[1].primaryType == "Album" && r.releases[1].country == "US")
        expect(DeepDiveService.chooseCover(r) == "rg-1", "earliest album release group, not a compilation")
        expect((try? MusicBrainzParser.recording(Data("{}".utf8))) == nil && (try? MusicBrainzParser.recording(Data("[1]".utf8))) == nil, "malformed documents are rejected")
    }

    func artistParsing() {
        let a = try! MusicBrainzParser.artist(Data(Fixtures.artistMiles.utf8))
        expect(a.name == "Miles Davis" && a.type == "Person" && a.country == "US" && a.area == "United States" && a.begin == "1926-05-26" && a.end == "1991-09-28" && a.disambiguation == nil)
        expect(a.genres == ["bebop", "jazz"] && a.annotation == "Trumpeter and bandleader." && a.homepage == "https://www.milesdavis.com/")
        expect(a.wikipediaTitle == "Miles_Davis" && a.wikipediaLanguage == "en" && a.wikidataID == "Q93341")
        let g = try! MusicBrainzParser.artist(Data(Fixtures.artistGil.utf8))
        expect(g.wikipediaTitle == nil && g.wikidataID == "Q313437" && g.end == nil)
        let de = #"{"id":"i","name":"N","relations":[{"type":"wikipedia","target-type":"url","url":{"resource":"https://de.wikipedia.org/wiki/Mot%C3%B6rhead"}}]}"#
        let d = try! MusicBrainzParser.artist(Data(de.utf8))
        expect(d.wikipediaLanguage == "de" && d.wikipediaTitle == "Motörhead", "percent-encoded titles are decoded: \(String(describing: d.wikipediaTitle))")
    }

    func acoustidParsing() {
        let m = try! AcoustIDClient.parse(Data(Fixtures.acoustid.utf8))
        expect(m.count == 2 && m[0].recordingID == "rec-1" && m[0].score == 0.98 && m[0].title == "So What" && m[0].artists.first?.name == "Miles Davis", "best match first")
        expect(m[0].releaseGroups.first?.releaseGroupTitle == "Kind of Blue" && m[1].recordingID == "rec-weak")
        expect((try? AcoustIDClient.parse(Data(#"{"status":"error","error":{"code":4,"message":"invalid API key"}}"#.utf8))) == nil)
        expect((try! AcoustIDClient.parse(Data(#"{"status":"ok","results":[]}"#.utf8))).isEmpty)
    }

    func musicBrainzClientBehaviour() {
        let http = StubHTTP(); http.on("/recording/rec-1", Fixtures.recording)
        let c = mb(http)
        let r = try! runAsync { try await c.recording(id: "rec-1") }.get()
        expect(r.title == "So What")
        let req = http.requests[0]
        expect(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Aureon/") == true && req.value(forHTTPHeaderField: "User-Agent")?.contains("(") == true, "a descriptive User-Agent is required by MusicBrainz")
        let url = req.url!.absoluteString
        expect(url.contains("fmt=json") && url.contains("inc=artists") && url.contains("work-level-rels") && url.hasPrefix("https://musicbrainz.org/ws/2/recording/rec-1"), url)
        _ = try! runAsync { try await c.recording(id: "rec-1") }.get()
        expect(http.count == 1, "the second lookup is served from the cache")

        // 503 is retried, other errors are reported
        let flaky = StubHTTP(); flaky.on("/recording/rec-1", [(Data(), 503), (Data(Fixtures.recording.utf8), 200)])
        expect((try? runAsync { try await self.mb(flaky).recording(id: "rec-1") }.get())?.id == "rec-1" && flaky.count == 2, "retried once after a 503")
        let gone = StubHTTP()
        if case .failure(let e) = runAsync({ try await self.mb(gone).recording(id: "nope") }) { expect("\(e)".contains("404") || e.localizedDescription.contains("404"), "\(e)") } else { expect(false, "a 404 must throw") }
    }

    func rateLimiterSpacesRequests() {
        let http = StubHTTP(); http.on("/artist/", Fixtures.artistMiles)
        let c = mb(http, interval: 0.25)
        let t0 = Date()
        for i in 0..<4 { _ = try! runAsync { try await c.artist(id: "a\(i)") }.get() }
        let took = Date().timeIntervalSince(t0)
        expect(took >= 0.70 && took < 3, "four requests at one per 250 ms took \(took) s")
        expect(http.count == 4)
    }

    func acoustidClientRequest() {
        let http = StubHTTP(); http.on("acoustid.org", Fixtures.acoustid)
        let c = AcoustIDClient(http: http)
        let m = try! runAsync { try await c.lookup(Fingerprint(duration: 562, value: "AQAA+/="), apiKey: "KEY123") }.get()
        expect(m.first?.recordingID == "rec-1")
        let r = http.requests[0], body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        expect(r.httpMethod == "POST" && r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded", "long fingerprints go in a POST body")
        expect(body.contains("client=KEY123") && body.contains("duration=562") && body.contains("fingerprint=AQAA") && body.contains("meta=recordings"), body)
        if case .failure(let e) = runAsync({ try await c.lookup(Fingerprint(duration: 1, value: "x"), apiKey: "") }) { expect("\(e)".contains("AcoustID application key"), "\(e)") } else { expect(false, "no key must throw") }
        let bad = StubHTTP(); bad.on("acoustid.org", "", status: 500)
        expect(runAsync({ try await AcoustIDClient(http: bad).lookup(Fingerprint(duration: 1, value: "x"), apiKey: "k") }).isFailure)
    }

    func wikipediaAndCoverArt() {
        let http = StubHTTP(); http.on("rest_v1/page/summary/Miles_Davis", Fixtures.wikiMiles); http.on("Special:EntityData/Q313437", Fixtures.wikidata); http.on("rest_v1/page/summary/Gil_Evans", Fixtures.wikiGil)
        let w = WikipediaClient(http: http, cache: cache())
        let s = try! runAsync { try await w.summary(title: "Miles_Davis") }.get()
        expect(s.extract.hasPrefix("Miles Dewey Davis") && s.pageURL == "https://en.wikipedia.org/wiki/Miles_Davis" && s.thumbnailURL?.hasSuffix("miles.jpg") == true && s.language == "en")
        _ = try! runAsync { try await w.summary(title: "Miles_Davis") }.get()
        expect(http.count == 1, "cached")
        let g = try! runAsync { try await w.summary(wikidataID: "Q313437") }.get()
        expect(g.title == "Gil Evans" && g.pageURL.contains("Gil_Evans"), "Wikidata → sitelink → summary: \(g)")
        expect(WikiSummary.license.contains("CC BY-SA"))
        expect(runAsync({ try await w.summary(title: "Unknown_Person") }).isFailure)

        let art = StubHTTP(); art.on("front-500", [(Data(count: 2048), 200)])
        let ca = CoverArtClient(http: art, cache: cache())
        expect(runAsync({ await ca.frontCover(releaseGroupID: "rg-1") }).isSuccessWith { $0?.count == 2048 })
        _ = runAsync { await ca.frontCover(releaseGroupID: "rg-1") }
        expect(art.count == 1, "cover cached on disk")
        expect(runAsync({ await CoverArtClient(http: StubHTTP(), cache: self.cache()).frontCover(releaseGroupID: "none") }).isSuccessWith { $0 == nil }, "404 → no cover, no error")
    }

    // MARK: the whole flow

    func service(_ http: StubHTTP, fingerprinter: Fingerprinter = FpcalcFingerprinter(), key: String = "KEY") -> DeepDiveService {
        let c = cache()
        return DeepDiveService(fingerprinter: fingerprinter, acoustid: AcoustIDClient(http: http), musicbrainz: MusicBrainzClient(http: http, cache: c, minInterval: 0),
                               wikipedia: WikipediaClient(http: http, cache: c), cache: c, apiKey: { key })
    }

    func fullStubs() -> StubHTTP {
        let h = StubHTTP()
        h.on("acoustid.org", Fixtures.acoustid)
        h.on("/recording/rec-1", Fixtures.recording); h.on("/recording/rec-2", Fixtures.recording2)
        h.on("/artist/art-miles", Fixtures.artistMiles); h.on("/artist/art-gil", Fixtures.artistGil)
        h.on("summary/Miles_Davis", Fixtures.wikiMiles); h.on("summary/Gil_Evans", Fixtures.wikiGil); h.on("Q313437", Fixtures.wikidata)
        return h
    }

    final class Stages: @unchecked Sendable { var list: [String] = []; let l = NSLock(); func add(_ s: String) { l.lock(); list.append(s); l.unlock() } }

    func deepDiveFromFileTags() {
        let http = fullStubs()
        let svc = service(http)
        let st = Stages()
        let d = try! runAsync { try await svc.load(path: "/x.flac", knownRecordingID: "rec-2") { st.add($0.rawValue) } }.get()
        expect(d.identifiedBy == "file tags" && d.recording.title == "Duet")
        expect(st.list == ["Loading from MusicBrainz", "Loading artist biographies"], "tagged files skip fingerprinting: \(st.list)")
        expect(d.artists.map(\.artist.name) == ["Miles Davis", "Gil Evans"], "\(d.artists.map(\.artist.name))")
        expect(d.artists[0].bio?.extract.hasPrefix("Miles Dewey") == true, "bio via the Wikipedia link")
        expect(d.artists[1].bio?.title == "Gil Evans", "bio via Wikidata when there is no Wikipedia link")
        let calls = http.count
        let again = try! runAsync { try await svc.load(path: "/x.flac", knownRecordingID: "rec-2") }.get()
        expect(http.count == calls && again.recording.id == "rec-2", "a repeat is answered from the cache with no network")
    }

    func deepDiveByFingerprint() {
        let script = dir.appendingPathComponent("fake-fpcalc-\(UUID().uuidString.prefix(5)).sh")
        try! Data("#!/bin/sh\necho '{\"duration\": 562.3, \"fingerprint\": \"AQADtEoUZVoUp0XIDXmN\"}'\n".utf8).write(to: script)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let http = fullStubs()
        let svc = service(http, fingerprinter: FpcalcFingerprinter(explicitPath: script.path))
        let st = Stages()
        let d = try! runAsync { try await svc.load(path: "/untagged.flac", knownRecordingID: nil) { st.add($0.rawValue) } }.get()
        expect(d.identifiedBy == "AcoustID fingerprint (98%)" && d.recording.id == "rec-1", d.identifiedBy)
        expect(st.list == ["Fingerprinting", "Identifying with AcoustID", "Loading from MusicBrainz", "Loading artist biographies"], "\(st.list)")
        expect(d.coverReleaseGroupID == "rg-1" && d.credits(.performance).count == 5 && d.credits(.production).count == 1)
        let body = String(data: http.requests.first { $0.httpMethod == "POST" }?.httpBody ?? Data(), encoding: .utf8) ?? ""
        expect(body.contains("duration=562") && body.contains("fingerprint=AQADtEoUZVoUp0XIDXmN"), "fpcalc's output is what gets sent: \(body)")

        // only weak matches → refuse rather than guess
        let weak = StubHTTP(); weak.on("acoustid.org", #"{"status":"ok","results":[{"id":"a","score":0.5,"recordings":[{"id":"rec-weak","title":"?"}]}]}"#)
        if case .failure(let e) = runAsync({ try await self.service(weak, fingerprinter: FpcalcFingerprinter(explicitPath: script.path)).load(path: "/u.flac", knownRecordingID: nil) }) {
            expect("\(e)".contains("50%"), "low-confidence matches are reported, not used: \(e)")
        } else { expect(false, "a weak match must not be accepted") }
        let none = StubHTTP(); none.on("acoustid.org", #"{"status":"ok","results":[]}"#)
        expect(runAsync({ try await self.service(none, fingerprinter: FpcalcFingerprinter(explicitPath: script.path)).load(path: "/u.flac", knownRecordingID: nil) }).isFailure)
    }

    func missingToolsAreExplained() {
        if case .failure(let e) = runAsync({ try await self.service(StubHTTP(), fingerprinter: FpcalcFingerprinter(explicitPath: "/nonexistent/fpcalc")).load(path: "/u.flac", knownRecordingID: nil) }) {
            let hasFpcalc = FpcalcFingerprinter.locate() != nil
            expect(hasFpcalc || "\(e)".contains("Chromaprint"), "message should explain how to install fpcalc: \(e)")
        } else if FpcalcFingerprinter.locate() == nil { expect(false, "should fail without fpcalc") }
        expect((try? FpcalcFingerprinter.parse(Data(#"{"duration": 1.2}"#.utf8))) == nil && (try? FpcalcFingerprinter.parse(Data(#"{"duration":10,"fingerprint":"AB"}"#.utf8)))?.duration == 10)
    }

    func artistBioFailureIsNotFatal() {
        let http = StubHTTP()
        http.on("/recording/rec-2", Fixtures.recording2); http.on("/artist/art-miles", Fixtures.artistMiles); http.on("/artist/art-gil", "", status: 500)   // no Wikipedia route: 404
        let d = try! runAsync { try await self.service(http).load(path: "/x", knownRecordingID: "rec-2") }.get()
        expect(d.artists.count == 1 && d.artists[0].artist.name == "Miles Davis" && d.artists[0].bio == nil, "one artist failing, and no bio found, must not fail the page")
    }

    func chooseCoverRules() {
        func rec(_ rels: [MBRelease]) -> MBRecording { MBRecording(id: "r", title: "t", artists: [], releases: rels, credits: [], works: [], genres: [], isrcs: []) }
        func rel(_ g: String?, _ d: String?, _ t: String?) -> MBRelease { MBRelease(id: UUID().uuidString, title: "x", date: d, releaseGroupID: g, primaryType: t) }
        expect(DeepDiveService.chooseCover(rec([rel("c", "1990", "Compilation"), rel("a", "2000", "Album")])) == "a", "albums win over compilations")
        expect(DeepDiveService.chooseCover(rec([rel("a2", "2005", "Album"), rel("a1", "1999", "Album")])) == "a1", "earliest wins")
        expect(DeepDiveService.chooseCover(rec([rel("s", "1990", "Single")])) == "s" && DeepDiveService.chooseCover(rec([])) == nil && DeepDiveService.chooseCover(rec([rel(nil, "1", "Album")])) == nil)
        let s = DeepDive.sample
        let back = try! JSONDecoder().decode(DeepDive.self, from: JSONEncoder().encode(s))
        expect(back == s, "Codable round trip")
    }
}

extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
    func isSuccessWith(_ f: (Success) -> Bool) -> Bool { if case .success(let v) = self { return f(v) }; return false }
}

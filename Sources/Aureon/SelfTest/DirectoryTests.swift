import Foundation
import Network

struct DirectoryTests {
    let dir = tempDir("directories")

    static let stationsJSON = """
    [{"stationuuid":"u1","name":"France Info","url":"http://direct.franceinfo.fr/live/franceinfo-midfi.mp3","url_resolved":"http://direct.franceinfo.fr/live/franceinfo-midfi.mp3","favicon":"https://x/f.png","tags":"news,talk, info ,a,b,c","country":"France","countrycode":"FR","language":"french","codec":"MP3","bitrate":128,"votes":94307,"hls":0,"lastcheckok":1,"homepage":"https://www.francetvinfo.fr/"},
     {"stationuuid":"u2","name":"RTL","url":"https://live/x/index.m3u8","url_resolved":"https://live/x/index.m3u8","codec":"AAC","bitrate":64,"hls":1,"lastcheckok":1,"countrycode":"FR"},
     {"stationuuid":"u3","name":"Jazz Lossless","url":"https://jazz.example/flac","url_resolved":"https://jazz.example/flac","codec":"FLAC","bitrate":1000,"hls":0,"lastcheckok":1,"country":"Germany","countrycode":"DE","votes":5},
     {"stationuuid":"u4","name":"Ogg Only","url_resolved":"https://o.example/stream.ogg","codec":"OGG","bitrate":128,"hls":0,"lastcheckok":1},
     {"stationuuid":"u5","name":"france info!","url_resolved":"http://dup.example/a.mp3","codec":"MP3","bitrate":96,"hls":0,"lastcheckok":1,"countrycode":"FR"},
     {"stationuuid":"u6","name":"Dead Station","url_resolved":"http://dead.example/a.mp3","codec":"MP3","hls":0,"lastcheckok":0},
     {"stationuuid":"u7","name":"","url_resolved":"http://noname.example/a.mp3","codec":"MP3","hls":0,"lastcheckok":1},
     {"stationuuid":"u8","name":"Bad URL","url_resolved":"rtmp://bad.example/live","codec":"MP3","hls":0,"lastcheckok":1},
     {"stationuuid":"u9","name":"AAC+ Pop","url":"http://pop.example/aac","url_resolved":"","codec":"AAC+","bitrate":48,"hls":0,"lastcheckok":1,"countrycode":"US","country":"United States"}]
    """

    func stationParsingKeepsOnlyPlayableStreams() {
        let s = RadioDirectory.parseStations(Data(Self.stationsJSON.utf8))
        expect(s.map(\.name) == ["France Info", "Jazz Lossless", "AAC+ Pop"], "HLS, Ogg, dead, nameless, non-HTTP and duplicate entries are dropped: \(s.map(\.name))")
        let fi = s[0]
        expect(fi.codec == "MP3" && fi.bitrate == 128 && fi.countryCode == "FR" && fi.tags == ["news", "talk", "info", "a"], "\(fi)")
        expect(fi.subtitle == "France · 128 kbps · MP3" && s[1].isLossless && s[1].subtitle.contains("FLAC"))
        expect(s[2].url == "http://pop.example/aac", "falls back to the plain url when url_resolved is empty")
        expect(RadioDirectory.parseStations(Data(Self.stationsJSON.utf8), limit: 1).count == 1)
        expect(RadioDirectory.parseStations(Data("not json".utf8)).isEmpty && RadioDirectory.parseStations(Data("{}".utf8)).isEmpty)
    }

    func facetParsing() {
        let langs = RadioDirectory.parseFacets(Data("[{\"name\":\"english\",\"iso_639\":\"en\",\"stationcount\":14222},{\"name\":\"\",\"stationcount\":5},{\"name\":\"klingon\",\"iso_639\":\"\",\"stationcount\":0}]".utf8), kind: "languages")
        expect(langs == [RadioFacet(name: "English", code: "en", count: 14222)], "\(langs)")
        let tags = RadioDirectory.parseFacets(Data("[{\"name\":\"jazz\",\"stationcount\":900},{\"name\":\"rare\",\"stationcount\":3}]".utf8), kind: "tags")
        expect(tags.map(\.name) == ["Jazz"], "tags with fewer than 30 stations are noise")
        let c = RadioDirectory.parseFacets(Data("[{\"name\":\"Germany\",\"iso_3166_1\":\"DE\",\"stationcount\":2500}]".utf8), kind: "countries")
        expect(c.first?.code == "DE")
    }

    func radioQueriesAndFallbackServers() {
        let http = StubHTTP()
        http.on("de1.api.radio-browser.info", "{}", status: 503)
        http.on("nl1.api.radio-browser.info/json/stations/search", Self.stationsJSON)
        let cache = MetadataCache(directory: dir.appendingPathComponent("rc"))
        let d = RadioDirectory(http: http, cache: cache)
        var q = RadioDirectory.Query(); q.countryCode = "fr"; q.tag = "News"; q.minBitrate = 128; q.limit = 10; q.language = "French"
        let r = try? runAsync { try await d.search(q) }.get()
        expect(r?.count == 3, "second server answered after the first returned 503: \(String(describing: r?.count))")
        let u = http.urls().last ?? ""
        expect(u.contains("nl1.api") && u.contains("countrycode=FR") && u.contains("tag=news") && u.contains("tagExact=true") && u.contains("bitrateMin=128") && u.contains("language=french") && u.contains("hidebroken=true") && u.contains("order=votes"), u)
        expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Aureon/") == true })
        let n = http.count
        _ = try? runAsync { try await d.search(q) }.get()
        expect(http.count == n, "an identical query is served from the cache")
        var lossless = RadioDirectory.Query(); lossless.lossless = true
        _ = try? runAsync { try await d.search(lossless) }.get()
        expect(http.urls().last?.contains("codec=FLAC") == true)
        // every server down → an error, not a crash
        let down = RadioDirectory(http: StubHTTP(), cache: MetadataCache(directory: dir.appendingPathComponent("rc2")))
        expect((try? runAsync { try await down.search(RadioDirectory.Query()) }.get()) == nil)
        // the click ping
        let h2 = StubHTTP(); h2.on("/json/url/u1", "{}")
        let d2 = RadioDirectory(http: h2, cache: MetadataCache(directory: dir.appendingPathComponent("rc3")))
        _ = try? runAsync { await d2.registerClick(RadioDirectory.parseStations(Data(Self.stationsJSON.utf8))[0]) }.get()
        expect(h2.urls().contains { $0.hasSuffix("/json/url/u1") })
        let custom = RadioStation(id: "user-1", name: "x", url: "http://x", favicon: nil, country: nil, countryCode: nil, language: nil, tags: [], codec: "?", bitrate: 0, votes: 0, homepage: nil)
        let before = h2.count
        _ = try? runAsync { await d2.registerClick(custom) }.get()
        expect(h2.count == before, "stations added by hand are never reported")
    }

    func favoritesAndCustomStations() {
        let f = dir.appendingPathComponent("radio.json"); try? FileManager.default.removeItem(at: f)
        let lib = RadioLibrary(url: f)
        let st = RadioDirectory.parseStations(Data(Self.stationsJSON.utf8))
        lib.toggleFavorite(st[0]); lib.toggleFavorite(st[1])
        expect(lib.favorites.map(\.name) == ["Jazz Lossless", "France Info"] && lib.isFavorite(st[0]))
        lib.toggleFavorite(st[0])
        expect(!lib.isFavorite(st[0]) && lib.favorites.count == 1)
        expect(lib.addCustom(name: "My Station", address: "ftp://nope") == nil && lib.addCustom(name: "", address: "not a url") == nil && lib.addCustom(name: "", address: "http://") == nil)
        let c = lib.addCustom(name: "", address: " https://radio.example.org:8000/live ")
        expect(c?.name == "radio.example.org" && c?.isUserAdded == true && c?.url == "https://radio.example.org:8000/live")
        let again = RadioLibrary(url: f)
        expect(again.favorites.count == 1 && again.custom.count == 1, "persists across launches")
        again.removeCustom(c!)
        expect(RadioLibrary(url: f).custom.isEmpty)
    }

    // MARK: podcasts

    static let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
    <channel>
      <title>The Science Show</title>
      <description><![CDATA[<p>Weekly <b>science</b> &amp; wonder.</p>]]></description>
      <itunes:author>Dr. Example</itunes:author>
      <itunes:image href="https://img.example/show.jpg"/>
      <item>
        <title>Episode 2: Black Holes</title>
        <description><![CDATA[<p>What happens inside?<br/>Find out &amp; learn.</p>]]></description>
        <pubDate>Mon, 05 Oct 2026 06:00:00 +0000</pubDate>
        <itunes:duration>01:02:03</itunes:duration>
        <guid isPermaLink="false">ep-2</guid>
        <enclosure url="http://media.example/ep2.mp3" length="52428800" type="audio/mpeg"/>
        <itunes:image href="https://img.example/ep2.jpg"/>
      </item>
      <item>
        <title>Episode 1</title>
        <itunes:summary>Plain summary</itunes:summary>
        <pubDate>Mon, 28 Sep 2026 06:00:00 GMT</pubDate>
        <itunes:duration>1800</itunes:duration>
        <enclosure url="https://media.example/ep1.m4a?token=abc" length="0" type="audio/x-m4a"/>
      </item>
      <item><title>Video episode</title><enclosure url="http://media.example/v.mp4" type="video/mp4"/></item>
      <item><title>No media</title><description>text only</description></item>
    </channel></rss>
    """

    func feedParsing() {
        let f = PodcastFeedParser.parse(Data(Self.rss.utf8))
        expect(f.title == "The Science Show" && f.author == "Dr. Example" && f.image == "https://img.example/show.jpg", "\(f.title) \(f.author) \(String(describing: f.image))")
        expect(f.summary == "Weekly science & wonder.", f.summary)
        expect(f.episodes.map(\.title) == ["Episode 2: Black Holes", "Episode 1"], "video and media-less items are skipped: \(f.episodes.map(\.title))")
        let e = f.episodes[0]
        expect(e.id == "ep-2" && e.audioURL == "http://media.example/ep2.mp3" && e.bytes == 52_428_800 && e.duration == 3723 && e.image == "https://img.example/ep2.jpg", "\(e)")
        expect(e.summary == "What happens inside?\nFind out & learn.", e.summary)
        expect(e.date.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: $0).day } == 5)
        let e1 = f.episodes[1]
        expect(e1.id == e1.audioURL && e1.duration == 1800 && e1.bytes == nil && e1.summary == "Plain summary", "\(e1)")
        expect(e1.date != nil, "GMT dates parse too")
        expect(PodcastFeedParser.parse(Data("garbage".utf8)).episodes.isEmpty)
        expect(PodcastFeedParser.parseDuration("12:34") == 754 && PodcastFeedParser.parseDuration("abc") == nil && PodcastFeedParser.parseDuration("90") == 90)
    }

    func podcastDirectoryParsing() {
        let search = "{\"resultCount\":1,\"results\":[{\"collectionId\":385427377,\"collectionName\":\"The Science of Everything Podcast\",\"artistName\":\"James Fodor\",\"feedUrl\":\"https://www.thescienceofeverything.net/feed.xml\",\"artworkUrl100\":\"https://x/100.jpg\",\"artworkUrl600\":\"https://x/600.jpg\",\"primaryGenreName\":\"Natural Sciences\"},{\"collectionName\":\"No id\"}]}"
        let s = PodcastDirectory.parseSearch(Data(search.utf8))
        expect(s.count == 1 && s[0].id == "385427377" && s[0].feedURL?.hasSuffix("feed.xml") == true && s[0].artwork == "https://x/600.jpg" && s[0].genre == "Natural Sciences", "\(s)")
        let chart = "{\"feed\":{\"entry\":[{\"im:name\":{\"label\":\"The Joe Show\"},\"im:image\":[{\"label\":\"https://i/55x55bb.png\"},{\"label\":\"https://i/170x170bb.png\"}],\"im:artist\":{\"label\":\"Joe\"},\"id\":{\"label\":\"https://podcasts.apple.com/x\",\"attributes\":{\"im:id\":\"360084272\"}},\"category\":{\"attributes\":{\"label\":\"Comedy\"}}},{\"im:name\":{\"label\":\"broken\"}}]}}"
        let c = PodcastDirectory.parseChart(Data(chart.utf8))
        expect(c.count == 1 && c[0].id == "360084272" && c[0].artwork == "https://i/400x400bb.jpg" && c[0].genre == "Comedy" && c[0].feedURL == nil, "\(c)")
        expect(PodcastDirectory.parseSearch(Data("x".utf8)).isEmpty && PodcastDirectory.parseChart(Data("{}".utf8)).isEmpty)
        expect(PodcastGenre.allCases.count == 18 && Set(PodcastGenre.allCases.map(\.rawValue)).count == 18)
        expect(PodcastLanguage.all.first?.name == "English" && PodcastLanguage.all.allSatisfy { $0.country.count == 2 })
    }

    func podcastRequestsAndLookups() {
        let http = StubHTTP()
        http.on("itunes.apple.com/search", "{\"results\":[{\"collectionId\":1,\"collectionName\":\"Show\",\"feedUrl\":\"http://feed.example/rss\"}]}")
        http.on("itunes.apple.com/lookup?id=77", "{\"results\":[{\"collectionId\":77,\"collectionName\":\"Chart Show\",\"feedUrl\":\"https://feed.example/chart.xml\"}]}")
        http.on("itunes.apple.com/de/rss/toppodcasts/limit=20/genre=1533/json", "{\"feed\":{\"entry\":[]}}")
        http.on("feed.example/rss", Self.rss)
        let d = PodcastDirectory(http: http, cache: MetadataCache(directory: dir.appendingPathComponent("pc")))
        let found = try? runAsync { try await d.search("science fiction", country: "gb", limit: 5) }.get()
        expect(found?.first?.feedURL == "http://feed.example/rss")
        let u = http.urls().last ?? ""
        expect(u.contains("media=podcast") && u.contains("term=science%20fiction") && u.contains("country=gb") && u.contains("limit=5"), u)
        _ = try? runAsync { try await d.top(country: "DE", genre: .science, limit: 20) }.get()
        expect(http.urls().last?.contains("/de/rss/toppodcasts/limit=20/genre=1533/json") == true, "\(http.urls().last ?? "")")
        let feed = try? runAsync { try await d.feedURL(for: PodcastShow(id: "77", name: "x", artist: "", artwork: nil, feedURL: nil, genre: nil)) }.get()
        expect(feed == "https://feed.example/chart.xml", "a chart entry needs one lookup for its feed")
        let direct = try? runAsync { try await d.feedURL(for: PodcastShow(id: "1", name: "x", artist: "", artwork: nil, feedURL: "http://known/feed", genre: nil)) }.get()
        expect(direct == "http://known/feed")
        let eps = try? runAsync { try await d.episodes(feed: "http://feed.example/rss") }.get()
        expect(eps?.episodes.count == 2)
        expect((try? runAsync { try await d.feedURL(for: PodcastShow(id: "404", name: "x", artist: "", artwork: nil, feedURL: nil, genre: nil)) }.get()) == nil)
    }

    func episodeDownloadsAreCachedAndVerified() {
        guard let aac = RadioTests().aacData(seconds: 2) else { return }
        let srv = try! FakeRadio(audio: aac, mode: .plain); defer { srv.stop() }
        // FakeRadio loops forever; serve a finite body through a second, tiny server instead
        let body = aac
        let fin = try! FiniteServer(body: body, type: "audio/aac"); defer { fin.stop() }
        let dl = PodcastDownloader(directory: dir.appendingPathComponent("episodes")); dl.clear()
        let prog = ProgressLog()
        let url = "http://127.0.0.1:\(fin.port)/ep.aac"
        let f = try? runAsync(timeout: 20) { try await dl.download(url) { b, t in prog.add(b, t) } }.get()
        expect(f != nil && (try? Data(contentsOf: f!)) == body, "the downloaded file is byte-identical")
        expect(f?.pathExtension == "aac" && dl.cachedFile(for: url)?.lastPathComponent == f?.lastPathComponent, "cached under a stable name")
        expect(prog.last.0 == body.count && prog.last.1 == body.count, "progress reaches 100%: \(prog.last)")
        let hits = fin.hits
        let again = try? runAsync { try await dl.download(url) }.get()
        expect(again?.lastPathComponent == f?.lastPathComponent && fin.hits == hits, "the second request does not touch the network")
        expect(dl.usedBytes == body.count)
        // truncated transfer must not leave a half file that looks complete
        let bad = try! FiniteServer(body: body, type: "audio/mpeg", truncateTo: 5000); defer { bad.stop() }
        let badURL = "http://127.0.0.1:\(bad.port)/cut.mp3"
        expect((try? runAsync(timeout: 20) { try await dl.download(badURL) }.get()) == nil && dl.cachedFile(for: badURL) == nil, "an interrupted download is discarded")
        let missing = try! FiniteServer(body: body, type: "audio/mpeg", status: 404); defer { missing.stop() }
        expect((try? runAsync(timeout: 20) { try await dl.download("http://127.0.0.1:\(missing.port)/x.mp3") }.get()) == nil)
        // and the file plays through the normal pipeline
        if let f, let src = try? LosslessFile(path: f.path) {
            let pcm = readAll(src)
            let a = amplitude(pcm, channels: 2, rate: src.info.sampleRate, freq: 440, skip: 8000, count: 30_000)
            expect(src.info.codec.contains("lossy") == false || a > 0.3, "decodes like any file: \(a)")
        } else { expect(false, "ExtAudioFile could not open the downloaded episode") }
        expect(PodcastDownloader.fileExtension(url: URL(string: "http://x/a")!, contentType: "audio/mp4") == "m4a" && PodcastDownloader.fileExtension(url: URL(string: "http://x/a.MP3?x=1")!, contentType: "") == "mp3")
    }

    final class ProgressLog: @unchecked Sendable { let l = NSLock(); var last = (0, 0); func add(_ b: Int, _ t: Int) { l.lock(); last = (b, t); l.unlock() } }
}

/// Serves one finite body (with Content-Length), optionally cutting it short or answering with an error status.
final class FiniteServer: @unchecked Sendable {
    let listener: NWListener
    private let q = DispatchQueue(label: "finite")
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var _hits = 0
    var hits: Int { lock.lock(); defer { lock.unlock() }; return _hits }

    init(body: Data, type: String, truncateTo: Int? = nil, status: Int = 200) throws {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: .any)
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [self] s in if case .ready = s { port = listener.port?.rawValue ?? 0; sem.signal() } }
        listener.newConnectionHandler = { [self] c in
            lock.lock(); _hits += 1; lock.unlock()
            c.start(queue: q)
            c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                if status != 200 { c.send(content: Data("HTTP/1.1 \(status) Nope\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() }); return }
                let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8) + (truncateTo.map { body.prefix($0) } ?? body), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: q)
        _ = sem.wait(timeout: .now() + 5)
    }
    func stop() { listener.cancel() }
}

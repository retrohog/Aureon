import Foundation
import CryptoKit

struct PodcastShow: Codable, Identifiable, Hashable {
    var id: String               // iTunes collection id
    var name: String
    var artist: String
    var artwork: String?
    var feedURL: String?         // known for search results; charts need one lookup
    var genre: String?
}

struct PodcastEpisode: Codable, Identifiable, Hashable {
    var id: String               // the feed's guid, else the media address
    var title: String
    var summary: String
    var date: Date?
    var duration: TimeInterval?
    var audioURL: String
    var bytes: Int?
    var image: String?
}

struct PodcastFeed: Equatable {
    var title: String
    var author: String
    var summary: String
    var image: String?
    var episodes: [PodcastEpisode]
}

enum PodcastGenre: Int, CaseIterable, Identifiable {
    case arts = 1301, business = 1321, comedy = 1303, education = 1304, fiction = 1483, health = 1512, history = 1487, kids = 1305, leisure = 1502
    case music = 1310, news = 1489, religion = 1314, science = 1533, society = 1324, sports = 1545, tech = 1318, tv = 1309, trueCrime = 1488
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .arts: "Arts"; case .business: "Business"; case .comedy: "Comedy"; case .education: "Education"; case .fiction: "Fiction"; case .health: "Health & Fitness"
        case .history: "History"; case .kids: "Kids & Family"; case .leisure: "Leisure"; case .music: "Music"; case .news: "News"; case .religion: "Religion"
        case .science: "Science"; case .society: "Society & Culture"; case .sports: "Sports"; case .tech: "Technology"; case .tv: "TV & Film"; case .trueCrime: "True Crime"
        }
    }
}

/// Languages offered on the podcast page, each with the store whose charts best represent it.
enum PodcastLanguage {
    static let all: [(name: String, country: String)] = [
        ("English", "us"), ("Arabic", "sa"), ("Chinese", "tw"), ("Czech", "cz"), ("Danish", "dk"), ("Dutch", "nl"), ("Finnish", "fi"), ("French", "fr"), ("German", "de"),
        ("Greek", "gr"), ("Hebrew", "il"), ("Hindi", "in"), ("Hungarian", "hu"), ("Icelandic", "is"), ("Indonesian", "id"), ("Italian", "it"), ("Japanese", "jp"),
        ("Korean", "kr"), ("Norwegian", "no"), ("Polish", "pl"), ("Portuguese", "br"), ("Russian", "ru"), ("Slovenian", "si"), ("Spanish", "es"), ("Swedish", "se"),
        ("Turkish", "tr"), ("Ukrainian", "ua")]
}

/// Podcast discovery through Apple's public iTunes Search API and charts (no account or key), and episodes from the show's own RSS feed.
final class PodcastDirectory: @unchecked Sendable {
    private let http: HTTPClient
    private let cache: MetadataCache
    private let identity: ClientIdentity

    init(http: HTTPClient = NetHTTPClient(), cache: MetadataCache = MetadataCache(), identity: ClientIdentity = ClientIdentity()) { self.http = http; self.cache = cache; self.identity = identity }

    private func get(_ url: URL, ttl: TimeInterval) async throws -> Data {
        let key = "podcast-" + url.absoluteString
        if let d = cache.data(key, ttl: ttl) { return d }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        let (d, status) = try await http.send(r)
        guard status == 200 else { throw NetworkError.status(status, url.host ?? "") }
        cache.putData(key, d)
        return d
    }

    func search(_ term: String, country: String = "us", limit: Int = 50) async throws -> [PodcastShow] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "media", value: "podcast"), .init(name: "entity", value: "podcast"), .init(name: "term", value: term), .init(name: "limit", value: String(limit)), .init(name: "country", value: country)]
        return Self.parseSearch(try await get(c.url!, ttl: 3600))
    }

    func top(country: String = "us", genre: PodcastGenre? = nil, limit: Int = 50) async throws -> [PodcastShow] {
        let g = genre.map { "/genre=\($0.rawValue)" } ?? ""
        let url = URL(string: "https://itunes.apple.com/\(country.lowercased())/rss/toppodcasts/limit=\(limit)\(g)/json")!
        return Self.parseChart(try await get(url, ttl: 3600))
    }

    /// The feed address of a show that came from a chart.
    func feedURL(for show: PodcastShow) async throws -> String {
        if let f = show.feedURL { return f }
        let url = URL(string: "https://itunes.apple.com/lookup?id=\(show.id)&entity=podcast")!
        guard let f = Self.parseSearch(try await get(url, ttl: 24 * 3600)).first?.feedURL else { throw NetworkError.badResponse("this show has no feed") }
        return f
    }

    func episodes(feed: String) async throws -> PodcastFeed {
        guard let url = URL(string: feed) else { throw NetworkError.badResponse("bad feed address") }
        return PodcastFeedParser.parse(try await get(url, ttl: 900))
    }

    // MARK: parsing

    static func parseSearch(_ d: Data) -> [PodcastShow] {
        guard let o = try? parseJSON(d) else { return [] }
        return o.arr("results").compactMap { r in
            guard let id = (r.num("collectionId")).map({ String(Int($0)) }), let name = r.str("collectionName") else { return nil }
            return PodcastShow(id: id, name: name, artist: r.str("artistName") ?? "", artwork: r.str("artworkUrl600") ?? r.str("artworkUrl100"), feedURL: r.str("feedUrl"), genre: r.str("primaryGenreName"))
        }
    }

    static func parseChart(_ d: Data) -> [PodcastShow] {
        guard let o = try? parseJSON(d), let feed = o.obj("feed") else { return [] }
        return feed.arr("entry").compactMap { e in
            guard let name = e.obj("im:name")?.str("label"), let id = e.obj("id")?.obj("attributes")?.str("im:id") else { return nil }
            let art = e.arr("im:image").last?.str("label")?.replacingOccurrences(of: #"/\d+x\d+bb\.(png|jpg)$"#, with: "/400x400bb.jpg", options: .regularExpression)
            return PodcastShow(id: id, name: name, artist: e.obj("im:artist")?.str("label") ?? "", artwork: art, feedURL: nil, genre: e.obj("category")?.obj("attributes")?.str("label"))
        }
    }
}

/// Reads a podcast RSS feed: show details and the episodes with their audio enclosures.
final class PodcastFeedParser: NSObject, XMLParserDelegate {
    private var feed = PodcastFeed(title: "", author: "", summary: "", image: nil, episodes: [])
    private var stack: [String] = []
    private var text = ""
    private var item: PodcastEpisode?
    private var guid: String?

    static func parse(_ data: Data) -> PodcastFeed {
        let p = PodcastFeedParser()
        let x = XMLParser(data: data); x.delegate = p; x.shouldProcessNamespaces = false
        x.parse()
        return p.feed
    }

    static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n").replacingOccurrences(of: "</p>", with: "\n")
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] { t = t.replacingOccurrences(of: a, with: b) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseDuration(_ s: String) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private static let dateFormats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss'Z'"]
    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in dateFormats { f.dateFormat = fmt; if let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) { return d } }
        return nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        stack.append(name); text = ""
        switch name {
        case "item": item = PodcastEpisode(id: "", title: "", summary: "", date: nil, duration: nil, audioURL: "", bytes: nil, image: nil); guid = nil
        case "enclosure":
            if item != nil, let u = a["url"], (a["type"] ?? "").hasPrefix("audio") || a["type"] == nil || ["mp3", "m4a", "aac", "wav", "flac"].contains((u as NSString).pathExtension.lowercased().components(separatedBy: "?")[0]) {
                item?.audioURL = u; item?.bytes = a["length"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            }
        case "itunes:image":
            if let h = a["href"] { if item != nil { item?.image = h } else if feed.image == nil { feed.image = h } }
        case "url" where stack.suffix(2).first == "image" && item == nil: break
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, foundCDATA d: Data) { text += String(decoding: d, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { stack.removeLast(); text = "" }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.dropLast().last ?? ""
        if item != nil {
            switch name {
            case "title" where parent == "item": item?.title = t
            case "description" where (item?.summary.isEmpty ?? true): item?.summary = Self.stripHTML(t)
            case "itunes:summary" where (item?.summary.isEmpty ?? true): item?.summary = Self.stripHTML(t)
            case "pubDate": item?.date = Self.parseDate(t)
            case "itunes:duration": item?.duration = Self.parseDuration(t)
            case "guid": guid = t
            case "item":
                if var e = item, !e.audioURL.isEmpty {
                    e.id = guid ?? e.audioURL
                    if e.title.isEmpty { e.title = "Episode" }
                    feed.episodes.append(e)
                }
                item = nil
            default: break
            }
        } else {
            switch name {
            case "title" where parent == "channel" && feed.title.isEmpty: feed.title = t
            case "itunes:author": feed.author = t
            case "description" where parent == "channel" && feed.summary.isEmpty: feed.summary = Self.stripHTML(t)
            case "url" where parent == "image" && feed.image == nil: feed.image = t
            default: break
            }
        }
    }
}

/// Downloads an episode into the cache before it plays, so seeking, resuming and the whole signal path work as for any file.
final class PodcastDownloader: @unchecked Sendable {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Podcasts", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func cachedFile(for address: String) -> URL? {
        let prefix = Self.key(address)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.first { $0.lastPathComponent.hasPrefix(prefix + ".") && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
    }

    static func key(_ address: String) -> String { SHA256.hash(data: Data(address.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() }

    /// Downloads (or finds) the episode file. `progress` gets (bytes so far, total or 0).
    func download(_ address: String, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> URL {
        if let f = cachedFile(for: address) { return f }
        guard let url = URL(string: address) else { throw NetworkError.badResponse("bad episode address") }
        let tmp = directory.appendingPathComponent(Self.key(address) + ".part")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        let state = State()
        let finalURL: URL = try await withCheckedThrowingContinuation { cont in
            let s = HTTPStreamer(url: url)
            state.streamer = s
            s.start(onResponse: { r in
                state.status = r.status; state.total = Int(r.headers["content-length"] ?? "") ?? 0; state.type = r.headers["content-type"] ?? ""
            }, onBody: { d in
                try? fh.write(contentsOf: d); state.bytes += d.count; progress(state.bytes, state.total)
            }, onClose: { [directory] e in
                try? fh.close()
                if let e, state.bytes == 0 || state.status == 0 { try? FileManager.default.removeItem(at: tmp); cont.resume(throwing: e); return }
                guard state.status == 200, state.bytes > 0 else { try? FileManager.default.removeItem(at: tmp); cont.resume(throwing: NetworkError.status(state.status, url.host ?? "")); return }
                if state.total > 0 && state.bytes < state.total { try? FileManager.default.removeItem(at: tmp); cont.resume(throwing: NetworkError.badResponse("download interrupted")); return }
                let ext = Self.fileExtension(url: url, contentType: state.type)
                let dest = directory.appendingPathComponent(Self.key(address) + "." + ext)
                try? FileManager.default.removeItem(at: dest)
                do { try FileManager.default.moveItem(at: tmp, to: dest); cont.resume(returning: dest) } catch { cont.resume(throwing: error) }
            })
        }
        return finalURL
    }

    private final class State: @unchecked Sendable { var status = 0, total = 0, bytes = 0; var type = ""; var streamer: HTTPStreamer? }

    static func fileExtension(url: URL, contentType: String) -> String {
        let ext = url.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "mp4"].contains(ext) { return ext == "mp4" ? "m4a" : ext }
        let ct = contentType.lowercased()
        if ct.contains("mp4") || ct.contains("m4a") || ct.contains("aac") { return "m4a" }
        if ct.contains("flac") { return "flac" }
        if ct.contains("wav") { return "wav" }
        return "mp3"
    }

    func clear() { try? FileManager.default.removeItem(at: directory); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    var usedBytes: Int { ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
}

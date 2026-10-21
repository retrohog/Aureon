import Foundation

/// Artist biographies come from Wikipedia (CC BY-SA 4.0): the extract is shown with attribution and a link to the article.
struct WikiSummary: Codable, Hashable {
    var title: String
    var description: String?
    var extract: String
    var pageURL: String
    var thumbnailURL: String?
    var language: String
    static let license = "Text from Wikipedia, available under CC BY-SA 4.0"
}

final class WikipediaClient: @unchecked Sendable {
    private let http: HTTPClient, identity: ClientIdentity, cache: MetadataCache

    init(http: HTTPClient = URLSessionClient(), identity: ClientIdentity = ClientIdentity(), cache: MetadataCache = MetadataCache()) {
        self.http = http; self.identity = identity; self.cache = cache
    }

    static func parseSummary(_ d: Data, language: String) throws -> WikiSummary {
        let j = try parseJSON(d)
        guard let title = j.str("title"), let extract = j.str("extract"), !extract.isEmpty else { throw NetworkError.badResponse("no article text") }
        return WikiSummary(title: title, description: j.str("description"), extract: extract,
                           pageURL: j.obj("content_urls")?.obj("desktop")?.str("page") ?? "https://\(language).wikipedia.org/wiki/\(title.replacingOccurrences(of: " ", with: "_"))",
                           thumbnailURL: j.obj("thumbnail")?.str("source"), language: language)
    }

    /// Page title of the English article linked from a Wikidata item.
    static func parseWikidata(_ d: Data, id: String) -> (title: String, language: String)? {
        guard let j = try? parseJSON(d), let ent = j.obj("entities")?.obj(id), let links = ent.obj("sitelinks") else { return nil }
        for lang in ["enwiki", "dewiki", "frwiki"] { if let t = links.obj(lang)?.str("title") { return (t, String(lang.dropLast(4))) } }
        return nil
    }

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url); req.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        let (d, status) = try await http.send(req)
        guard status == 200 else { throw NetworkError.status(status, url.host ?? "") }
        return d
    }

    func summary(title: String, language: String = "en") async throws -> WikiSummary {
        let key = "wiki-\(language)-\(title)"
        if let c: WikiSummary = cache.get(key, ttl: 90 * 86_400) { return c }
        let encoded = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        let s = try Self.parseSummary(try await get(URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(encoded)")!), language: language)
        cache.put(key, s)
        return s
    }

    func summary(wikidataID id: String) async throws -> WikiSummary {
        guard let (title, lang) = Self.parseWikidata(try await get(URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(id).json")!), id: id) else { throw NetworkError.badResponse("no Wikipedia article for \(id)") }
        return try await summary(title: title, language: lang)
    }
}

/// Cover Art Archive: front cover of a release group.
final class CoverArtClient: @unchecked Sendable {
    private let http: HTTPClient, cache: MetadataCache
    init(http: HTTPClient = URLSessionClient(), cache: MetadataCache = MetadataCache()) { self.http = http; self.cache = cache }

    func frontCover(releaseGroupID id: String) async -> Data? {
        if let c = cache.data("caa-rg-\(id)", ttl: 365 * 86_400) { return c }
        var req = URLRequest(url: URL(string: "https://coverartarchive.org/release-group/\(id)/front-500")!)
        req.setValue(ClientIdentity().userAgent, forHTTPHeaderField: "User-Agent")
        guard let (d, status) = try? await http.send(req), status == 200, d.count > 100 else { return nil }
        cache.putData("caa-rg-\(id)", d)
        return d
    }
}

import Foundation
import AppKit

/// Finds a portrait for an artist: Deezer's public artist search first (high-resolution, no key), then the artist's Wikipedia article.
/// Only the artist's name is sent. Results — including "no portrait exists" — are cached on disk.
actor ArtistImageFetcher {
    enum Source: String { case deezer, wikipedia }

    private let http: HTTPClient
    private let directory: URL
    private let identity: ClientIdentity
    private let wikipedia: WikipediaClient
    private let negativeTTL: TimeInterval
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private(set) var lastSource: Source?

    init(http: HTTPClient = NetHTTPClient(), directory: URL? = nil, identity: ClientIdentity = ClientIdentity(), wikipedia: WikipediaClient? = nil, negativeTTL: TimeInterval = 14 * 86_400) {
        self.http = http; self.identity = identity; self.negativeTTL = negativeTTL
        self.wikipedia = wikipedia ?? WikipediaClient(http: http, identity: identity)
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Artists", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    nonisolated static func key(_ name: String) -> String { ArtworkFetcher.key(artist: nil, album: ArtworkMatch.normalize(name)) }
    private func file(_ key: String, _ ext: String) -> URL { directory.appendingPathComponent(key + "." + ext) }

    func cached(name: String) -> Data? { try? Data(contentsOf: file(Self.key(name), "img")) }

    func image(for name: String) async -> Data? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !ArtworkMatch.isVariousArtists(name) else { return nil }
        let key = Self.key(name)
        if let d = try? Data(contentsOf: file(key, "img")) { return d }
        if let m = (try? FileManager.default.attributesOfItem(atPath: file(key, "none").path))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < negativeTTL { return nil }
        if let t = inFlight[key] { return await t.value }
        let task = Task<Data?, Never> { await self.lookup(name, key: key) }
        inFlight[key] = task
        let r = await task.value
        inFlight[key] = nil
        return r
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    private func usable(_ d: Data) -> Bool { ImageTools.size(d).map { min($0.0, $0.1) >= 150 } ?? false }

    private func lookup(_ name: String, key: String) async -> Data? {
        var transportFailed = false
        for source in [Source.deezer, .wikipedia] {
            do {
                if let d = try await (source == .deezer ? deezer(name) : wiki(name)) {
                    try? d.write(to: file(key, "img")); lastSource = source
                    return d
                }
            } catch { transportFailed = true }
        }
        if !transportFailed { try? Data().write(to: file(key, "none")) }
        return nil
    }

    // MARK: Deezer

    static func parseDeezer(_ d: Data, wanted: String) -> String? {
        guard let o = try? parseJSON(d) else { return nil }
        let hits = o.arr("data").compactMap { a -> (Int, String)? in
            guard let n = a.str("name"), ArtworkMatch.similarity(n, wanted) >= 0.92,
                  let pic = a.str("picture_xl") ?? a.str("picture_big") ?? a.str("picture_medium"), !pic.contains("/artist//") else { return nil }
            return (Int(a.num("nb_fan") ?? 0), pic)
        }
        return hits.max { $0.0 < $1.0 }?.1       // the most followed artist of that name
    }

    private func deezer(_ name: String) async throws -> Data? {
        var c = URLComponents(string: "https://api.deezer.com/search/artist")!
        c.queryItems = [.init(name: "q", value: name), .init(name: "limit", value: "8")]
        let (body, status) = try await http.send(request(c.url!))
        guard status == 200 else { if status >= 500 || status == 429 { throw NetworkError.status(status, "deezer") }; return nil }
        guard let pic = Self.parseDeezer(body, wanted: name), let url = URL(string: pic) else { return nil }
        let (img, st) = try await http.send(request(url))
        return st == 200 && usable(img) ? img : nil
    }

    // MARK: Wikipedia

    private func wiki(_ name: String) async throws -> Data? {
        guard let s = try? await wikipedia.summary(title: name), let t = s.thumbnailURL, let url = URL(string: t) else { return nil }
        // an ambiguous name leads to a disambiguation page or an unrelated article: require it to read like a musician
        let d = ((s.description ?? "") + " " + s.extract.prefix(300)).lowercased()
        guard ["singer", "musician", "band", "rapper", "composer", "conductor", "orchestra", "duo", "songwriter", "pianist", "violinist", "guitarist", "dj", "ensemble", "quartet", "vocalist"].contains(where: d.contains),
              ArtworkMatch.similarity(s.title, name) >= 0.7 else { return nil }
        let (img, st) = try await http.send(request(url))
        return st == 200 && usable(img) ? img : nil
    }
}

/// Builds an artist picture from album covers when no portrait is available: 1 cover fills the frame, 2–4 form a grid.
enum ArtistMosaic {
    static func render(_ images: [CGImage], size: Int = 400) -> NSImage? {
        let covers = Array(images.prefix(4))
        guard !covers.isEmpty, let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let n = covers.count
        let cells: [CGRect]
        let s = CGFloat(size), h = s / 2
        switch n {
        case 1: cells = [CGRect(x: 0, y: 0, width: s, height: s)]
        case 2: cells = [CGRect(x: 0, y: 0, width: h, height: s), CGRect(x: h, y: 0, width: h, height: s)]
        case 3: cells = [CGRect(x: 0, y: 0, width: h, height: s), CGRect(x: h, y: h, width: h, height: h), CGRect(x: h, y: 0, width: h, height: h)]
        default: cells = [CGRect(x: 0, y: h, width: h, height: h), CGRect(x: h, y: h, width: h, height: h), CGRect(x: 0, y: 0, width: h, height: h), CGRect(x: h, y: 0, width: h, height: h)]
        }
        for (img, cell) in zip(covers, cells) {
            // aspect-fill each cell
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let scale = max(cell.width / iw, cell.height / ih)
            let w = iw * scale, hh = ih * scale
            ctx.saveGState(); ctx.clip(to: cell)
            ctx.draw(img, in: CGRect(x: cell.midX - w / 2, y: cell.midY - hh / 2, width: w, height: hh))
            ctx.restoreGState()
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: size, height: size))
    }
}

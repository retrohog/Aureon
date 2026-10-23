import SwiftUI
import Combine
import AppKit

// MARK: - Playback progress (published separately so the whole interface does not redraw ten times a second)

@MainActor
final class ProgressModel: ObservableObject {
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    func update(position p: Double, duration d: Double) {
        if abs(p - position) > 0.0005 { position = p }
        if d != duration { duration = d }
    }
}

extension PlayerStatus {
    /// Equal in everything the interface shows except the playhead: those changes need no global redraw.
    func sameStructure(as o: PlayerStatus) -> Bool {
        state == o.state && trackID == o.trackID && trackIndex == o.trackIndex && info == o.info && sourceInfo == o.sourceInfo && pipeline == o.pipeline
            && pathLines == o.pathLines && bitPerfect == o.bitPerfect && transparentStream == o.transparentStream && replayGainDB == o.replayGainDB
            && underruns == o.underruns && loadProgress == o.loadProgress && ramBytes == o.ramBytes && dspActive == o.dspActive && dspSummary == o.dspSummary
            && engineThreadPromoted == o.engineThreadPromoted && rtStages == o.rtStages && rtLatencyFrames == o.rtLatencyFrames && live == o.live
            && deviceName == o.deviceName && finished == o.finished && errors == o.errors && duration == o.duration && Int(bufferedSeconds * 2) == Int(o.bufferedSeconds * 2)
    }
}

// MARK: - Navigation history (back / forward)

struct Place: Equatable {
    var tab: Tab
    var library: String? = nil
    var radio: String? = nil
    var podcast: String? = nil
}

@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    private var back: [Place] = [], forward: [Place] = []
    private(set) var current: Place
    init(start: Place = Place(tab: .player)) { current = start }
    private(set) var restoring = false
    var restore: ((Place) -> Void)?

    /// Records a new place (ignored while a back/forward step is being applied, or when nothing changed).
    func visit(_ p: Place) {
        guard !restoring, p != current else { return }
        back.append(current); if back.count > 100 { back.removeFirst() }
        forward.removeAll(); current = p
        publish()
    }

    func goBack() {
        guard let p = back.popLast() else { return }
        forward.append(current); apply(p)
    }

    func goForward() {
        guard let p = forward.popLast() else { return }
        back.append(current); apply(p)
    }

    private func apply(_ p: Place) {
        current = p
        restoring = true; restore?(p); restoring = false
        publish()
    }

    private func publish() { canGoBack = !back.isEmpty; canGoForward = !forward.isEmpty }
}

// MARK: - Remote images (station logos, podcast covers, artist portraits)

actor RemoteImageStore {
    static let shared = RemoteImageStore()
    private let http: HTTPClient = NetHTTPClient(maxBytes: 12 << 20)
    private let directory: URL
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var failed = Set<String>()

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ url: String) -> URL { directory.appendingPathComponent(PodcastDownloader.key(url) + ".img") }

    func preload(_ url: String, data: Data) { try? data.write(to: file(url)) }

    func data(_ url: String) async -> Data? {
        if let d = try? Data(contentsOf: file(url)) { return d }
        if failed.contains(url) { return nil }
        if let t = inFlight[url] { return await t.value }
        let t = Task<Data?, Never> {
            guard let u = URL(string: url), u.scheme?.hasPrefix("http") == true else { return nil }
            var r = URLRequest(url: u, timeoutInterval: 15); r.setValue(ClientIdentity().userAgent, forHTTPHeaderField: "User-Agent")
            guard let (d, st) = try? await http.send(r), st == 200, ImageTools.isImage(d) else { return nil }
            try? d.write(to: file(url))
            return d
        }
        inFlight[url] = t
        let d = await t.value
        inFlight[url] = nil
        if d == nil { failed.insert(url) }
        return d
    }
}

@MainActor
final class RemoteImages {
    static let shared = RemoteImages()
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ url: String, maxPixel: Int) -> NSImage? { cache.object(forKey: "\(url)|\(maxPixel)" as NSString) }

    func image(_ url: String, maxPixel: Int) async -> NSImage? {
        if let c = cached(url, maxPixel: maxPixel) { return c }
        guard let d = await RemoteImageStore.shared.data(url) else { return nil }
        let img = await Task.detached(priority: .utility) { ImageTools.nsImage(d, maxPixel: maxPixel) }.value
        if let img { cache.setObject(img, forKey: "\(url)|\(maxPixel)" as NSString) }
        return img
    }
}

/// An image from the web with a generated placeholder underneath while it loads (or when it never will).
struct RemoteImage: View {
    let url: String?
    let seed: String
    var corner: CGFloat = 12
    var maxPixel = 420
    var symbol = "music.note"
    var fit = false           // logos: show the whole image on a light tile instead of cropping it
    var label: String? = nil  // shown on the placeholder tile (station names)
    @StateObject private var img = Box<NSImage?>(nil)

    var body: some View {
        ZStack {
            if let i = img.v ?? url.flatMap({ RemoteImages.shared.cached($0, maxPixel: maxPixel) }) {
                if fit { Color.white.opacity(0.94); Image(nsImage: i).resizable().aspectRatio(contentMode: .fit).padding(12) }
                else { GeometryReader { g in Image(nsImage: i).resizable().aspectRatio(contentMode: .fill).frame(width: g.size.width, height: g.size.height).clipped() } }
            } else {
                let p = ArtPalette.fallback(seed: seed)
                LinearGradient(colors: [p.grid[0].color, p.grid[4].color, p.grid[8].color], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let label {
                    VStack(spacing: 8) {
                        Image(systemName: symbol).font(Typo.sans(18, .light)).foregroundStyle(Brand.inkSecondary)
                        Text(label).font(Typo.sans(13, .bold)).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7).foregroundStyle(Brand.inkSecondary).padding(.horizontal, 12)
                    }
                } else { Image(systemName: symbol).font(Typo.sans(26, .ultraLight)).foregroundStyle(Brand.inkTertiary) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Brand.ink.opacity(0.1), lineWidth: 0.8))
        .task(id: url) {
            guard let url else { img.v = nil; return }
            if let i = await RemoteImages.shared.image(url, maxPixel: maxPixel) { withAnimation(.smooth(duration: 0.25)) { img.v = i } }
        }
    }
}

// MARK: - Library view options (sorting, filtering, size)

enum SortKey: String, Codable, CaseIterable, Identifiable {
    case title, artist, album, year, duration, quality, added, count, genre, plays, recent, size
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: "Title"; case .artist: "Artist"; case .album: "Album"; case .year: "Year"; case .duration: "Length"; case .quality: "Quality (resolution)"
        case .added: "Date added"; case .count: "Number of songs"; case .genre: "Genre"; case .plays: "Most played"; case .recent: "Recently played"; case .size: "File size"
        }
    }
}

enum QualityFilter: String, Codable, CaseIterable, Identifiable {
    case all, hiRes, cd, dsd
    var id: String { rawValue }
    var label: String { switch self { case .all: "All qualities"; case .hiRes: "Hi-Res (above 48 kHz or 16-bit)"; case .cd: "CD quality and below"; case .dsd: "DSD" } }
    var short: String { switch self { case .all: "All"; case .hiRes: "Hi-Res"; case .cd: "CD"; case .dsd: "DSD" } }
}

struct ViewOptions: Codable, Equatable {
    var sort: SortKey = .title
    var ascending = true
    var quality: QualityFilter = .all
    var list = false              // grid or list
    var size = 0.3                // 0…1: cover size in grids
    var letters = true           // group lists under A–Z headers

    static func defaults(for tab: Tab) -> ViewOptions {
        var o = ViewOptions()
        switch tab {
        case .albums: o.sort = .title
        case .songs: o.sort = .title; o.list = true
        case .artists: o.sort = .title
        default: o.sort = .title; o.list = true
        }
        return o
    }

    static func available(for tab: Tab) -> [SortKey] {
        switch tab {
        case .albums: [.title, .artist, .year, .added, .count, .genre, .quality]
        case .songs, .liked: [.title, .artist, .album, .year, .duration, .quality, .added, .genre, .plays, .recent, .size]
        default: [.title, .count]
        }
    }
}

enum LibraryOrdering {
    static func key(_ s: String) -> String { LibraryStore.fold(s) }

    static func albums(_ a: [ReleaseDTO], _ o: ViewOptions) -> [ReleaseDTO] {
        let f = a.filter { r in
            switch o.quality { case .all: true; case .hiRes: r.isHiRes && !r.isDSD; case .cd: !r.isHiRes; case .dsd: r.isDSD }
        }
        // every sort key is computed once per item, not once per comparison
        struct K { var a: String; var n: Double; var t: String }
        let keyed: [(ReleaseDTO, K)] = f.map { r in
            let t = key(r.title)
            switch o.sort {
            case .artist: return (r, K(a: key(r.artistNames.first ?? ""), n: 0, t: t))
            case .year: return (r, K(a: "", n: Double(r.year ?? 0), t: t))
            case .added: return (r, K(a: "", n: r.addedAt ?? 0, t: t))
            case .count: return (r, K(a: "", n: Double(r.trackCount), t: t))
            case .genre: return (r, K(a: key(r.genre ?? "~"), n: 0, t: t))
            case .quality: return (r, K(a: "", n: (r.maxSampleRate ?? 0) * Double(r.maxBitDepth ?? 0), t: t))
            default: return (r, K(a: "", n: 0, t: t))
            }
        }
        let s = keyed.sorted { ($0.1.a, $0.1.n, $0.1.t) < ($1.1.a, $1.1.n, $1.1.t) }.map(\.0)
        return o.ascending ? s : s.reversed()
    }

    static func songs(_ t: [TrackDTO], _ o: ViewOptions) -> [TrackDTO] {
        let f = t.filter { r in
            switch o.quality { case .all: true; case .hiRes: isHiRes(r) && r.bitDepth != 1; case .cd: !isHiRes(r); case .dsd: r.bitDepth == 1 }
        }
        struct K { var a: String; var b: String; var n: Double; var m: Double; var t: String }
        let keyed: [(TrackDTO, K)] = f.map { r in
            let t = key(r.title)
            switch o.sort {
            case .artist: return (r, K(a: key(r.artistLine), b: key(r.releaseTitle ?? ""), n: 0, m: Double(r.trackNumber ?? 0), t: t))
            case .album: return (r, K(a: key(r.releaseTitle ?? ""), b: "", n: Double(r.discNumber ?? 1), m: Double(r.trackNumber ?? 0), t: t))
            case .year: return (r, K(a: "", b: "", n: Double(r.year ?? 0), m: 0, t: t))
            case .duration: return (r, K(a: "", b: "", n: r.duration, m: 0, t: ""))
            case .quality: return (r, K(a: "", b: "", n: r.sampleRate * Double(r.bitDepth), m: 0, t: t))
            case .added: return (r, K(a: "", b: "", n: r.addedAt ?? 0, m: 0, t: t))
            case .genre: return (r, K(a: key(r.genres.first ?? "~"), b: "", n: 0, m: 0, t: t))
            case .plays: return (r, K(a: "", b: "", n: Double(r.playCount ?? 0), m: 0, t: t))
            case .recent: return (r, K(a: "", b: "", n: r.lastPlayedAt ?? 0, m: 0, t: t))
            case .size: return (r, K(a: "", b: "", n: Double(r.fileSize ?? 0), m: 0, t: t))
            default: return (r, K(a: "", b: "", n: 0, m: 0, t: t))
            }
        }
        let s = keyed.sorted { ($0.1.a, $0.1.b, $0.1.n, $0.1.m, $0.1.t) < ($1.1.a, $1.1.b, $1.1.n, $1.1.m, $1.1.t) }.map(\.0)
        return o.ascending ? s : s.reversed()
    }

    static func rows(_ r: [LibraryModel.Row], _ o: ViewOptions) -> [LibraryModel.Row] {
        let keyed = r.map { ($0, key($0.title)) }
        let s = keyed.sorted { o.sort == .count ? ($0.0.count, $0.1) < ($1.0.count, $1.1) : $0.1 < $1.1 }.map(\.0)
        return o.ascending ? s : s.reversed()
    }

    /// "A"…"Z" for letters (diacritics folded), "#" for everything else.
    static func letter(_ s: String) -> String {
        guard let c = key(s).uppercased().first, c.isLetter, c.isASCII else { return "#" }
        return String(c)
    }

    static func grouped<T>(_ items: [T], title: (T) -> String) -> [(letter: String, items: [T])] {
        var out: [(letter: String, items: [T])] = []
        for it in items {
            let l = letter(title(it))
            if let last = out.last, last.letter == l { out[out.count - 1].items.append(it) } else { out.append((l, [it])) }
        }
        return out
    }
}

// MARK: - Artist pictures

@MainActor
final class ArtistArt: ObservableObject {
    struct Info { var image: NSImage?; var portrait: Bool }
    @Published private(set) var info: [String: Info] = [:]
    private var loading = Set<String>()
    private let gate = ArtLoadGate(), batch = ArtBatch<Info>()
    var store: LibraryStore?
    var fetchOnline: () -> Bool = { false }
    let fetcher = ArtistImageFetcher()

    /// Test and snapshot seam: sets a picture directly.
    func preload(id: String, image: NSImage, portrait: Bool) { info[id] = Info(image: image, portrait: portrait) }

    /// First a mosaic of the artist's own album covers (instant, offline), then a portrait from the web when one exists.
    func load(id: String, name: String) {
        let p = (id: id, name: name)
        guard info[p.id] == nil, !loading.contains(p.id), let store else { return }
        loading.insert(p.id)
        let online = fetchOnline(), fetcher = fetcher
        gate.submit { [weak self] done in
            Task {
                let mosaic = await Task.detached(priority: .utility) { () -> NSImage? in
                    var covers: [CGImage] = []
                    for r in store.releases(partyID: p.id, limit: 12) {
                        guard covers.count < 4 else { break }
                        for t in store.tracks(releaseID: r.id, limit: 3) {
                            if let d = await MetadataEngine.artwork(path: t.path), let cg = ImageTools.cgImage(d, maxPixel: 300) { covers.append(cg); break }
                        }
                    }
                    return ArtistMosaic.render(covers, size: 360)
                }.value
                await MainActor.run {
                    guard let self else { done(); return }
                    self.batch.add(p.id, Info(image: mosaic, portrait: false)) { items in withAnimation(.smooth(duration: 0.3)) { self.info.merge(items) { _, new in new } } }
                    done()                               // the portrait (a web request) does not hold the gate
                }
                guard let self else { return }
                var portrait = await fetcher.cached(name: p.name)
                if portrait == nil, online { portrait = await fetcher.image(for: p.name) }
                if let d = portrait, let img = await Task.detached(priority: .utility, operation: { ImageTools.nsImage(d, maxPixel: 480) }).value {
                    await MainActor.run { withAnimation(.smooth(duration: 0.4)) { self.info[p.id] = Info(image: img, portrait: true) } }
                }
                await MainActor.run { self.loading.remove(p.id) }
            }
        }
    }
}

// MARK: - Radio

@MainActor
final class RadioModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case local = "Local radios", highQuality = "High Quality", genre = "By genre", location = "By location", language = "By language", favorites = "Favorites", mine = "My stations"
        var id: String { rawValue }
        var icon: String { switch self { case .local: "location"; case .highQuality: "sparkles"; case .genre: "guitars"; case .location: "globe.europe.africa"; case .language: "character.bubble"; case .favorites: "heart"; case .mine: "plus.circle" } }
    }

    @Published var section: Section = .local { didSet { if section != oldValue { facet = nil; facets = []; Task { await load() } ; publishKey() } } }
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published private(set) var stations: [RadioStation] = []
    @Published private(set) var facets: [RadioFacet] = []
    @Published var facet: RadioFacet? { didSet { if facet != oldValue { Task { await load() }; publishKey() } } }
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var favorites: [RadioStation] = []
    @Published private(set) var custom: [RadioStation] = []
    @Published private(set) var navKey = ""

    let directory: RadioDirectory
    let library: RadioLibrary
    private var searchTask: Task<Void, Never>?
    private var loadToken = 0
    var onPlay: ((RadioStation) -> Void)?

    var countryCode: String { Locale.current.region?.identifier ?? "US" }

    init(directory: RadioDirectory = RadioDirectory(), library: RadioLibrary = RadioLibrary()) {
        self.directory = directory; self.library = library
        favorites = library.favorites; custom = library.custom
    }

    private func publishKey() { navKey = "\(section.rawValue)|\(facet?.id ?? "")" }

    func restore(_ key: String) {
        let p = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 2, let s = Section(rawValue: p[0]) else { return }
        let f = facets.first { $0.id == p[1] }
        section = s; facet = f
    }

    func isFavorite(_ s: RadioStation) -> Bool { favorites.contains { $0.id == s.id } }
    func toggleFavorite(_ s: RadioStation) { library.toggleFavorite(s); favorites = library.favorites }
    func addStation(name: String, address: String) -> Bool { let ok = library.addCustom(name: name, address: address) != nil; custom = library.custom; return ok }
    func remove(_ s: RadioStation) { library.removeCustom(s); custom = library.custom }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func load() async {
        loadToken += 1; let token = loadToken
        error = nil
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty, section == .favorites { stations = favorites; return }
        if q.isEmpty, section == .mine { stations = custom; return }
        loading = true; defer { if token == loadToken { loading = false } }
        do {
            var result: [RadioStation] = []
            if !q.isEmpty {
                var query = RadioDirectory.Query(); query.name = q; query.limit = 80
                if section == .location, let f = facet { query.countryCode = f.code }
                result = try await directory.search(query)
            } else {
                switch section {
                case .local:
                    var qq = RadioDirectory.Query(); qq.countryCode = countryCode; qq.limit = 80
                    result = try await directory.search(qq)
                case .highQuality:
                    var lossless = RadioDirectory.Query(); lossless.lossless = true; lossless.limit = 20
                    var hq = RadioDirectory.Query(); hq.minBitrate = 192; hq.limit = 80
                    let a = (try? await directory.search(lossless)) ?? []
                    let b = try await directory.search(hq)
                    var seen = Set<String>(); result = (a + b).filter { seen.insert($0.id).inserted }
                case .genre, .location, .language:
                    let kind = section == .genre ? "tags" : section == .location ? "countries" : "languages"
                    if facets.isEmpty { let f = try await directory.facets(kind); if token == loadToken { facets = Array(f.prefix(section == .genre ? 120 : 250)) } }
                    if facet == nil, q.isEmpty, let first = facets.first { facet = first; return }       // didSet starts the load for it
                    if let f = facet {
                        var qq = RadioDirectory.Query(); qq.limit = 80
                        switch section { case .genre: qq.tag = f.name; case .location: qq.countryCode = f.code; default: qq.language = f.name }
                        result = try await directory.search(qq)
                    }
                case .favorites, .mine: break
                }
            }
            if token == loadToken { stations = result }
        } catch {
            if token == loadToken { stations = []; self.error = "Could not reach the radio directory. Check your connection and try again." }
        }
    }
}

// MARK: - Podcasts

@MainActor
final class PodcastModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable { case top = "Top shows", categories = "Categories", languages = "Languages"; var id: String { rawValue }
        var icon: String { switch self { case .top: "chart.line.uptrend.xyaxis"; case .categories: "square.grid.2x2"; case .languages: "character.bubble" } } }

    @Published var section: Section = .top { didSet { if section != oldValue { Task { await loadShows() }; publishKey() } } }
    @Published var language = PodcastLanguage.all[0].name { didSet { if language != oldValue { Task { await loadShows() }; publishKey() } } }
    @Published var genre: PodcastGenre? { didSet { if genre != oldValue { Task { await loadShows() }; publishKey() } } }
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published private(set) var shows: [PodcastShow] = []
    @Published var selected: PodcastShow? { didSet { if selected?.id != oldValue?.id { feed = nil; episodeError = nil; if let s = selected { Task { await openShow(s) } }; publishKey() } } }
    @Published private(set) var feed: PodcastFeed?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var episodeError: String?
    @Published private(set) var downloads: [String: Double] = [:]      // episode id → 0…1 while downloading
    @Published private(set) var navKey = ""

    let directory: PodcastDirectory
    let downloader: PodcastDownloader
    private var searchTask: Task<Void, Never>?
    private var token = 0
    var onPlay: ((PodcastEpisode, PodcastShow, URL) -> Void)?

    init(directory: PodcastDirectory = PodcastDirectory(), downloader: PodcastDownloader = PodcastDownloader()) { self.directory = directory; self.downloader = downloader }

    var country: String { PodcastLanguage.all.first { $0.name == language }?.country ?? "us" }
    private func publishKey() { navKey = "\(section.rawValue)|\(language)|\(genre?.rawValue ?? 0)|\(selected?.id ?? "")" }

    func restore(_ key: String) {
        let p = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4, let s = Section(rawValue: p[0]) else { return }
        section = s; language = p[1]; genre = PodcastGenre(rawValue: Int(p[2]) ?? 0)
        selected = p[3].isEmpty ? nil : (shows.first { $0.id == p[3] } ?? selected)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadShows()
        }
    }

    func loadShows() async {
        token += 1; let t = token
        error = nil; loading = true; defer { if t == token { loading = false } }
        let q = query.trimmingCharacters(in: .whitespaces)
        do {
            let r: [PodcastShow]
            if !q.isEmpty { r = try await directory.search(q, country: country) }
            else if section == .categories, let g = genre { r = try await directory.top(country: country, genre: g) }
            else if section == .categories { r = [] }
            else { r = try await directory.top(country: country) }
            if t == token { shows = r }
        } catch { if t == token { shows = []; self.error = "Could not reach the podcast directory. Check your connection and try again." } }
    }

    func openShow(_ show: PodcastShow) async {
        do {
            let url = try await directory.feedURL(for: show)
            let f = try await directory.episodes(feed: url)
            if selected?.id == show.id { feed = f }
        } catch { if selected?.id == show.id { episodeError = "This show's feed could not be loaded." } }
    }

    /// Downloads the episode (with progress) and hands the file to the player.
    func play(_ ep: PodcastEpisode, of show: PodcastShow) {
        guard downloads[ep.id] == nil else { return }
        downloads[ep.id] = 0
        Task {
            do {
                let url = try await downloader.download(ep.audioURL) { [weak self] b, total in
                    let f = total > 0 ? Double(b) / Double(total) : min(0.95, Double(b) / Double(max(ep.bytes ?? 30_000_000, 1)))
                    Task { @MainActor in self?.downloads[ep.id] = f }
                }
                downloads[ep.id] = nil
                onPlay?(ep, show, url)
            } catch {
                downloads[ep.id] = nil
                episodeError = "Could not download “\(ep.title)”."
            }
        }
    }
}

import SwiftUI
import AppKit

/// Runs a few image jobs at a time, newest request first: while a long list is scrolled, only what is on screen now is worth loading, and
/// the library database (one serial context) must never be kept busy by dozens of background lookups the interface then has to wait behind.
@MainActor
final class ArtLoadGate {
    private var running = 0
    private var queue: [(_ done: @escaping @MainActor () -> Void) -> Void] = []
    let limit: Int
    init(limit: Int = 3) { self.limit = limit }

    func submit(_ job: @escaping (_ done: @escaping @MainActor () -> Void) -> Void) { queue.append(job); pump() }

    private func pump() {
        while running < limit, let job = queue.popLast() {
            running += 1
            job { [weak self] in self?.running -= 1; self?.pump() }
        }
    }
}

/// Collects results and publishes them together, so a burst of finished covers redraws the grid once instead of once per cover.
@MainActor
final class ArtBatch<T> {
    private var pending: [String: T] = [:]
    private var scheduled = false
    func add(_ id: String, _ v: T, flush: @escaping @MainActor ([String: T]) -> Void) {
        pending[id] = v
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            scheduled = false
            let p = pending; pending = [:]
            MainActor.assumeIsolated { flush(p) }
        }
    }
}


/// Cover thumbnails and quality flags for the album grid, loaded lazily (only for albums that scroll into view).
///
/// A cover is read out of the audio files once (see `ArtCache`); after that a thumbnail is a few-kilobyte file. Only the covers of albums near the
/// screen are held decoded: the others are dropped from memory and come back from the cache file in about a millisecond when they scroll into view again.
@MainActor
final class AlbumArt: ObservableObject {
    struct Info { var image: NSImage?; var hd: Bool }

    /// Covers kept decoded at once. A grid shows a few dozen; this leaves room to scroll back without reloading.
    static let resident = 120

    @Published private(set) var info: [String: Info] = [:]
    private var loading = Set<String>()
    private var recency: [String] = []                      // ids, least recently asked for first
    private let gate = ArtLoadGate(), batch = ArtBatch<Info>()
    var store: LibraryStore?
    var fetcher: ArtworkFetcher?
    var fetchOnline: () -> Bool = { false }
    var cache: ArtCache = .shared
    var limit = AlbumArt.resident

    func load(_ r: ReleaseDTO) {
        touch(r.id)
        guard info[r.id] == nil, !loading.contains(r.id), let store else { return }
        loading.insert(r.id)
        let fetcher = fetcher, online = fetchOnline(), cache = cache
        gate.submit { [weak self] done in
            Task {
                let result = await Task.detached(priority: .utility) { await AlbumArt.cover(for: r, store: store, fetcher: fetcher, online: online, cache: cache) }.value
                await MainActor.run {
                    guard let self else { done(); return }
                    self.loading.remove(r.id)
                    self.batch.add(r.id, result) { items in
                        withAnimation(.smooth(duration: 0.3)) { self.info.merge(items) { _, new in new } }
                        self.trim()
                    }
                    done()
                }
            }
        }
    }

    private func touch(_ id: String) {
        if recency.last != id { recency.removeAll { $0 == id }; recency.append(id) }
    }

    /// Drops the decoded covers of albums that have not been asked for lately.
    private func trim() {
        guard recency.count > limit else { return }
        for id in recency.prefix(recency.count - limit) { info[id] = nil }
        recency.removeFirst(recency.count - limit)
    }

    /// The thumbnail of an album: from the cache when it is there, otherwise extracted from the files (or fetched online) and stored for next time.
    nonisolated static func cover(for r: ReleaseDTO, store: LibraryStore, fetcher: ArtworkFetcher?, online: Bool, cache: ArtCache) async -> Info {
        let source = ArtCache.Source.album(id: r.id, stamp: r.artStamp ?? 0)
        switch cache.lookup(source) {
        case .hit(let h): if let cg = cache.thumbnail(h) { return Info(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), hd: r.isHiRes) }
        case .empty: return Info(image: nil, hd: r.isHiRes)
        case .miss: break
        }
        let tracks = store.tracks(releaseID: r.id, limit: 60)
        var data: Data?
        for t in tracks.prefix(3) { if let d = await MetadataEngine.artwork(path: t.path) { data = d; break } }
        if data == nil, let f = fetcher {
            let artist = r.artistNames.first
            data = await f.cached(artist: artist, album: r.title)
            if data == nil, online { data = await f.cover(artist: artist, album: r.title) }
        }
        let hd = r.isHiRes || tracks.contains { $0.sampleRate > 48_000 || $0.bitDepth > 16 }
        guard let d = data, let h = cache.store(source, data: d), let cg = cache.thumbnail(h) else {
            if data == nil, fetcher == nil || online { cache.storeNone(source) }            // everything was tried: do not try again at every launch
            return Info(image: nil, hd: hd)
        }
        return Info(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), hd: hd)
    }
}

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


/// Cover thumbnails and quality flags for the album grid, loaded lazily (only for albums that scroll into view) and cached.
@MainActor
final class AlbumArt: ObservableObject {
    struct Info { var image: NSImage?; var hd: Bool }

    @Published private(set) var info: [String: Info] = [:]
    private var loading = Set<String>()
    private let gate = ArtLoadGate(), batch = ArtBatch<Info>()
    var store: LibraryStore?
    var fetcher: ArtworkFetcher?
    var fetchOnline: () -> Bool = { false }

    func load(_ r: ReleaseDTO) {
        guard info[r.id] == nil, !loading.contains(r.id), let store else { return }
        loading.insert(r.id)
        let fetcher = fetcher, online = fetchOnline()
        gate.submit { [weak self] done in
            Task {
                let result = await Task.detached(priority: .utility) { () -> Info in
                    let tracks = store.tracks(releaseID: r.id, limit: 60)
                    let hd = tracks.contains { $0.sampleRate > 48_000 || $0.bitDepth > 16 }
                    var data: Data?
                    for t in tracks.prefix(3) { if let d = await MetadataEngine.artwork(path: t.path) { data = d; break } }
                    if data == nil, let f = fetcher {
                        let artist = r.artistNames.first
                        data = await f.cached(artist: artist, album: r.title)
                        if data == nil, online { data = await f.cover(artist: artist, album: r.title) }
                    }
                    return Info(image: data.flatMap { ImageTools.nsImage($0, maxPixel: 480) }, hd: hd)
                }.value
                await MainActor.run {
                    guard let self else { done(); return }
                    self.loading.remove(r.id)
                    self.batch.add(r.id, result) { items in withAnimation(.smooth(duration: 0.3)) { self.info.merge(items) { _, new in new } } }
                    done()
                }
            }
        }
    }
}

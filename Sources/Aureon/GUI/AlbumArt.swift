import SwiftUI
import AppKit

/// Cover thumbnails and quality flags for the album grid, loaded lazily (only for albums that scroll into view) and cached.
@MainActor
final class AlbumArt: ObservableObject {
    struct Info { var image: NSImage?; var hd: Bool }

    @Published private(set) var info: [String: Info] = [:]
    private var loading = Set<String>()
    var store: LibraryStore?
    var fetcher: ArtworkFetcher?
    var fetchOnline: () -> Bool = { false }

    func load(_ r: ReleaseDTO) {
        guard info[r.id] == nil, !loading.contains(r.id), let store else { return }
        loading.insert(r.id)
        let fetcher = fetcher, online = fetchOnline()
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
            withAnimation(.smooth(duration: 0.3)) { info[r.id] = result }
            loading.remove(r.id)
        }
    }
}

import Foundation

// What starts a lyrics lookup. It lives outside any view: a task attached to the lyrics panel itself never ran, because that panel is empty until
// lyrics exist, and SwiftUI does not start work for a view that is not on screen. The Now Playing page attaches `ask` to its scroll view, which is
// always there, and the Lyrics buttons call `start` directly, so the lookup does not depend on the panel being visible.

/// What the driver needs from the app model: the song in focus and how long it is.
@MainActor
protocol LyricsFocus: AnyObject {
    var focusItem: QueueItem? { get }
    /// Seconds; 0 until the engine knows it.
    var lyricsDuration: Double { get }
}

extension PlayerModel: LyricsFocus {
    var lyricsDuration: Double { progress.duration }
}

@MainActor
enum LyricsDriver {
    /// Changes when a new lookup may be needed: another song, its tags read, lyrics switched on or off.
    struct Trigger: Equatable { var path: String?; var tagsRead: Bool; var show: Bool }

    static func trigger(for f: LyricsFocus, show: Bool) -> Trigger {
        let item = f.focusItem
        let song = item.map { !$0.isStream } ?? false
        return Trigger(path: song ? item?.path : nil, tagsRead: item.map { $0.artSource != .unknown } ?? false, show: show)
    }

    /// The request for a song: nil for nothing playing and for radio. The tags may not have been read yet, and the length may be 0: it is
    /// asked again when they arrive.
    static func request(for item: QueueItem?, duration: Double) -> LyricsRequest? {
        guard let item, !item.isStream else { return nil }
        return LyricsRequest(path: item.path, title: item.title, artist: item.artist.isEmpty ? item.albumArtist : item.artist, album: item.album, duration: max(0, duration))
    }

    /// Looks for the lyrics of the song in focus now, with what is known so far. The service ignores a repeat of the same song.
    static func start(_ f: LyricsFocus, service: LyricsService = .shared) {
        let r = request(for: f.focusItem, duration: f.lyricsDuration)
        LyricsDebug.log("start: \(r.map { "\($0.title) | \($0.artist) | \($0.duration)s | \($0.path)" } ?? "nothing to look up")")
        service.show(r)
    }

    /// From the Now Playing page: starts at once, then asks again when the tags have been read and the length is known (both help the online
    /// match), without waiting more than a few seconds. Lyrics switched off, or no song: clears the page's lyrics.
    static func ask(_ f: LyricsFocus, show: Bool, service: LyricsService = .shared, maxWait: TimeInterval = 3) async {
        LyricsDebug.log("ask: show=\(show) song=\(f.focusItem.map { !$0.isStream } ?? false)")
        guard show, let item = f.focusItem, !item.isStream else { service.show(nil); return }
        start(f, service: service)
        var waited = 0.0
        while ((f.focusItem ?? item).artSource == .unknown || f.lyricsDuration <= 0) && waited < maxWait && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000); waited += 0.1
        }
        guard !Task.isCancelled else { return }
        start(f, service: service)
    }
}

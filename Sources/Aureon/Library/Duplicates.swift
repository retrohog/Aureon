import Foundation

/// Finds songs and albums that exist more than once in the library and recommends which copy to keep.
struct DuplicateItem: Identifiable, Hashable {
    var id: String { track.id }
    var track: TrackDTO
    var quality: Double
    var summary: String             // "FLAC 24/96 · 38.2 MB"
}

struct DuplicateGroup: Identifiable, Hashable {
    enum Kind { case song, album }
    var id: String                  // stable: the same copies always make the same id (so "ignore" survives a rescan)
    var kind: Kind
    var title: String
    var artist: String
    var items: [DuplicateItem]      // best first
    var reason: String              // why they are considered the same
    var keepReason: String          // why the first one is recommended
    /// For albums: every track of every copy, grouped by copy (`items` holds one representative per copy).
    var albumCopies: [[TrackDTO]] = []
    var keep: DuplicateItem { items[0] }
    var removable: [DuplicateItem] { Array(items.dropFirst()) }
}

enum DuplicateFinder {
    private static let lossy: Set<String> = ["mp3", "aac", "ogg", "opus", "wma", "mpeg"]

    static func isLossy(_ t: TrackDTO) -> Bool { t.codec.lowercased().contains("lossy") || lossy.contains(where: { t.codec.lowercased().contains($0) }) }

    /// Comparable figure: lossless beats lossy, then bit depth × sample rate, then file size.
    static func quality(_ t: TrackDTO) -> Double {
        (isLossy(t) ? 0 : 1_000_000) + Double(t.bitDepth) * t.sampleRate / 1000 + Double(t.fileSize ?? 0) / 1e9
    }

    static func describe(_ t: TrackDTO) -> String {
        let q = t.bitDepth == 1 ? "DSD" : "\(t.codec.replacingOccurrences(of: " (lossy)", with: "")) \(t.bitDepth)/\(formatRate(t.sampleRate).replacingOccurrences(of: " kHz", with: ""))"
        let size = t.fileSize.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        return q + size
    }

    /// Title with the parts that do not make a different recording removed: "(feat. X)", "(Remastered 2011)", "- Remastered", punctuation, case, accents.
    static func normalizedTitle(_ s: String) -> String {
        var t = s
        for pattern in [#"[\(\[]\s*(?:feat\.?|ft\.?|featuring)[^\)\]]*[\)\]]"#, #"[\(\[][^\)\]]*remaster(?:ed)?[^\)\]]*[\)\]]"#, #"\s[-–—]\s*(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\s*$"#,
                        #"[\(\[]\s*(?:album|single|radio)\s+version\s*[\)\]]"#, #"\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        let folded = LibraryStore.fold(t)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(Character.init)).split(separator: " ").joined(separator: " ")
    }

    static func normalizedEdition(_ s: String) -> String {
        var t = s
        for pattern in [#"[\(\[][^\)\]]*(?:deluxe|remaster|expanded|anniversary|edition|bonus|special)[^\)\]]*[\)\]]"#, #"\s[-–—]\s*(?:deluxe|remaster|expanded|anniversary).*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return normalizedTitle(t)
    }

    private static func keepReason(_ best: DuplicateItem, _ others: [DuplicateItem]) -> String {
        let b = best.track, o = others[0].track
        if isLossy(o) && !isLossy(b) { return "Lossless (\(b.codec)) beats lossy (\(o.codec))" }
        if b.bitDepth * Int(b.sampleRate) > o.bitDepth * Int(o.sampleRate) { return "Higher resolution: \(describe(b).components(separatedBy: " · ")[0]) vs \(describe(o).components(separatedBy: " · ")[0])" }
        if (b.fileSize ?? 0) > (o.fileSize ?? 0) { return "Same format, larger file (more complete)" }
        return "Same quality: keeping the first copy"
    }

    /// Groups of the same recording: same title and artist and (nearly) the same length.
    static func songGroups(_ tracks: [TrackDTO], ignoring ignored: Set<String> = []) -> [DuplicateGroup] {
        var buckets: [String: [TrackDTO]] = [:]
        for t in tracks {
            let artist = LibraryStore.fold(t.primaryArtistLine.split(separator: ",").first.map(String.init) ?? t.primaryArtistLine)
            let title = normalizedTitle(t.title)
            guard !title.isEmpty else { continue }
            buckets[title + "|" + artist, default: []].append(t)
        }
        var out: [DuplicateGroup] = []
        for (key, list) in buckets where list.count > 1 {
            // within a bucket, copies must be about the same length (a live take or an edit is a different recording)
            var clusters: [[TrackDTO]] = []
            for t in list.sorted(by: { $0.duration < $1.duration }) {
                if let i = clusters.firstIndex(where: { abs(($0.last?.duration ?? 0) - t.duration) <= max(2.5, t.duration * 0.015) }) { clusters[i].append(t) } else { clusters.append([t]) }
            }
            for c in clusters where c.count > 1 {
                let items = c.map { DuplicateItem(track: $0, quality: quality($0), summary: describe($0)) }.sorted { ($0.quality, $1.track.path) > ($1.quality, $0.track.path) }
                let id = "song|" + key + "|" + items.map(\.track.path).sorted().joined(separator: "|")
                guard !ignored.contains(id) else { continue }
                let spread = (c.map(\.duration).max() ?? 0) - (c.map(\.duration).min() ?? 0)
                out.append(DuplicateGroup(id: id, kind: .song, title: items[0].track.title, artist: items[0].track.primaryArtistLine,
                                          items: items, reason: "Same title and artist, lengths within \(Int(spread.rounded(.up))) s",
                                          keepReason: keepReason(items[0], Array(items.dropFirst()))))
            }
        }
        return out.sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }

    /// Whole albums that exist twice (for instance a CD rip and a hi-res purchase): the same artist and album title once edition tags are ignored,
    /// with most of the songs in common.
    static func albumGroups(_ tracks: [TrackDTO], ignoring ignored: Set<String> = []) -> [DuplicateGroup] {
        var byRelease: [String: [TrackDTO]] = [:]
        for t in tracks { if let r = t.releaseID { byRelease[r, default: []].append(t) } }
        var buckets: [String: [(id: String, tracks: [TrackDTO])]] = [:]
        for (rid, ts) in byRelease {
            guard let title = ts.first?.releaseTitle else { continue }
            let artist = LibraryStore.fold(ts.first?.primaryArtistLine.split(separator: ",").first.map(String.init) ?? "")
            buckets[normalizedEdition(title) + "|" + artist, default: []].append((rid, ts))
        }
        var out: [DuplicateGroup] = []
        for (key, copies) in buckets where copies.count > 1 {
            let sets = copies.map { Set($0.tracks.map { normalizedTitle($0.title) }) }
            let common = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }
            guard Double(common.count) >= 0.6 * Double(sets.map(\.count).min() ?? 1), !common.isEmpty else { continue }
            func score(_ ts: [TrackDTO]) -> Double { ts.map(quality).reduce(0, +) / Double(max(1, ts.count)) + Double(ts.count) * 0.001 }
            let ordered = copies.sorted { (score($0.tracks), $1.id) > (score($1.tracks), $0.id) }
            let items = ordered.map { c -> DuplicateItem in
                let best = c.tracks.max { quality($0) < quality($1) }!
                let bytes = c.tracks.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
                return DuplicateItem(track: best, quality: score(c.tracks), summary: "\(describe(best).components(separatedBy: " · ")[0]) · \(c.tracks.count) songs · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            let id = "album|" + key + "|" + ordered.map(\.id).sorted().joined(separator: "|")
            guard !ignored.contains(id) else { continue }
            let first = ordered[0].tracks[0]
            var g = DuplicateGroup(id: id, kind: .album, title: first.releaseTitle ?? "Album", artist: first.primaryArtistLine, items: items,
                                   reason: "Same album and artist; \(common.count) songs in common", keepReason: keepReason(items[0], Array(items.dropFirst())))
            g.albumCopies = ordered.map(\.tracks)
            out.append(g)
        }
        return out.sorted { $0.artist.lowercased() < $1.artist.lowercased() }
    }

    /// Everything to propose: albums first (they cover their songs), then songs that are not already part of a duplicate album.
    static func all(_ tracks: [TrackDTO], ignoring ignored: Set<String> = []) -> [DuplicateGroup] {
        let albums = albumGroups(tracks, ignoring: ignored)
        let covered = Set(albums.flatMap { $0.albumCopies.flatMap { $0.map(\.path) } })
        let songs = songGroups(tracks.filter { !covered.contains($0.path) }, ignoring: ignored)
        return albums + songs
    }

    /// The files that would be removed if every group were resolved as recommended.
    static func removalPaths(_ groups: [DuplicateGroup]) -> [String] {
        groups.flatMap { g -> [String] in
            switch g.kind {
            case .song: return g.removable.map(\.track.path)
            case .album: return g.albumCopies.dropFirst().flatMap { $0.map(\.path) }
            }
        }
    }
}


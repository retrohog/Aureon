import Foundation
import PDFKit

/// A track of the album a booklet belongs to, as far as the booklet index needs it.
struct BookletTrack: Hashable, Sendable {
    var number: Int?
    var title: String
    var path: String?
}

/// A place in the booklet to jump to: the page a track's notes or lyrics start on, or a chapter from the PDF's own outline.
struct BookletAnchor: Identifiable, Hashable, Sendable {
    enum Source: Int, Sendable { case outline, text }
    var id: String { "\(trackIndex.map(String.init) ?? "c")-\(page)-\(title)" }
    let title: String
    /// Zero-based page index.
    let page: Int
    /// Index into the track list the anchors were made for, nil for a chapter that is not a track.
    let trackIndex: Int?
    let source: Source
}

/// Finds booklets for an album and the pages its tracks start on.
///
/// The PDF outline wins where it names a track. The remaining tracks are looked up in the page text: a page that names most of the album
/// is the track list and is used only as a last resort, so a track lands on its own lyrics or notes page, in album order where possible.
enum BookletIndex {
    /// Folders that hold scans and booklets rather than the album itself.
    static let extrasFolders: Set<String> = ["scans", "artwork", "booklet", "booklets", "digital booklet", "extras", "pdf"]

    /// At most this many pages are read for text: a booklet is short, a 900-page score is not worth indexing in full.
    static let maxIndexedPages = 400

    /// The album folder of a booklet: its own folder, or the parent of a "Scans"-style subfolder.
    static func albumFolder(for booklet: URL) -> URL {
        let dir = booklet.deletingLastPathComponent()
        return extrasFolders.contains(dir.lastPathComponent.lowercased()) ? dir.deletingLastPathComponent() : dir
    }

    /// The booklets of the folder a track sits in (and of the album folder when the track is in a disc subfolder such as "CD1").
    static func booklets(forTrack path: String) -> [URL] {
        guard !path.contains("://") else { return [] }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let own = FolderScanner.booklets(in: dir)
        if !own.isEmpty { return own }
        let name = dir.lastPathComponent.lowercased()
        let isDisc = name.range(of: #"^(cd|disc|disk|side)\s*[0-9a-z]{1,2}\b"#, options: .regularExpression) != nil
        return isDisc ? FolderScanner.booklets(in: dir.deletingLastPathComponent()) : []
    }

    /// The tracks of the album a booklet belongs to: the audio files of its album folder (and disc subfolders), titled from the library
    /// where it knows them and from the file name otherwise.
    static func tracks(forBooklet booklet: URL, store: LibraryStore?) -> [BookletTrack] {
        let album = albumFolder(for: booklet)
        var files = FolderScanner.audioFiles(under: album, recursive: false, limit: 500)
        if files.isEmpty { files = FolderScanner.audioFiles(under: album, recursive: true, limit: 500) }
        let known = store?.tracks(paths: files.map(\.path)) ?? [:]
        let tracks = files.map { u -> BookletTrack in
            if let t = known[u.path] { return BookletTrack(number: t.trackNumber, title: t.title, path: u.path) }
            let (n, title) = titleFromFileName(u.deletingPathExtension().lastPathComponent)
            return BookletTrack(number: n, title: title, path: u.path)
        }
        return tracks.sorted { ($0.number ?? Int.max, $0.path ?? "") < ($1.number ?? Int.max, $1.path ?? "") }
    }

    /// "03 - Title", "03. Title", "1-03 Title" → (3, "Title").
    static func titleFromFileName(_ stem: String) -> (Int?, String) {
        let pattern = #"^\s*(?:\d{1,2}[-.])?(\d{1,3})\s*[-._)]?\s+(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let nr = Range(m.range(at: 1), in: stem), let tr = Range(m.range(at: 2), in: stem) else { return (nil, stem) }
        return (Int(stem[nr]), String(stem[tr]).trimmingCharacters(in: .whitespaces))
    }

    // MARK: Matching

    /// Lower case, no diacritics, punctuation turned into spaces, one space between words, padded with a space on both sides so that
    /// `contains(" \(word) ")` matches whole words only.
    static func normalize(_ s: String) -> String {
        let folded = LibraryStore.fold(s)
        var out = ""
        out.reserveCapacity(folded.count + 2)
        var space = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch); space = false
            } else if !space {
                out.append(" "); space = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return " " + out + " "
    }

    /// The spellings of a track title worth looking for: the full title and the title without a trailing "(Live)", "[Remastered 2009]"
    /// or " - Single Version". Titles of fewer than three letters are too likely to occur by chance and give nothing.
    static func spellings(_ title: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let n = normalize(s)
            if n.count >= 5, !out.contains(n) { out.append(n) }       // " ab " is 4 characters
        }
        add(title)
        var t = title
        while let r = t.range(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, options: .regularExpression) { t.removeSubrange(r) }
        if let r = t.range(of: #"\s+[-–—]\s+[^-–—]*(version|mix|edit|remaster(ed)?|live|mono|stereo)[^-–—]*$"#, options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        add(t)
        return out
    }

    static func contains(_ normalizedText: String, _ spellings: [String]) -> Bool { spellings.contains { normalizedText.contains($0) } }

    /// The anchors for `tracks`, from the outline (title, zero-based page) and the text of each page. Pure: the tests drive it directly.
    static func anchors(pageTexts: [String], outline: [(title: String, page: Int)], tracks: [BookletTrack]) -> [BookletAnchor] {
        let pageCount = pageTexts.count
        var trackPage = [Int?](repeating: nil, count: tracks.count)
        var source = [BookletAnchor.Source](repeating: .text, count: tracks.count)
        let names = tracks.map { spellings($0.title) }
        var chapters: [BookletAnchor] = []

        // 1. The outline: an entry that names a track, or starts with its number ("3. …", "Track 3").
        for item in outline where item.page >= 0 {
            let n = normalize(item.title)
            var hit: Int?
            for (i, s) in names.enumerated() where trackPage[i] == nil && !s.isEmpty && contains(n, s) { hit = i; break }
            if hit == nil, let num = leadingNumber(item.title) {
                hit = tracks.indices.first { trackPage[$0] == nil && tracks[$0].number == num }
            }
            if let i = hit {
                trackPage[i] = item.page; source[i] = .outline
            } else {
                chapters.append(BookletAnchor(title: item.title.trimmingCharacters(in: .whitespacesAndNewlines), page: item.page, trackIndex: nil, source: .outline))
            }
        }

        // 2. The page text.
        if pageCount > 0 {
            let texts = pageTexts.map(normalize)
            let searchable = names.filter { !$0.isEmpty }.count
            let found = names.map { s in s.isEmpty ? [] : texts.indices.filter { contains(texts[$0], s) } }
            var perPage = [Int](repeating: 0, count: pageCount)
            for pages in found { for p in pages { perPage[p] += 1 } }
            let listThreshold = max(3, (searchable + 1) / 2)
            let isList = perPage.map { $0 >= listThreshold }
            var last = 0
            for i in tracks.indices where trackPage[i] == nil {
                let own = found[i].filter { !isList[$0] }
                if let p = own.first(where: { $0 >= last }) ?? own.first {
                    trackPage[i] = p; last = p
                } else if let p = found[i].first {
                    trackPage[i] = p
                }
            }
        }

        var out: [BookletAnchor] = []
        for (i, t) in tracks.enumerated() {
            if let p = trackPage[i] { out.append(BookletAnchor(title: t.title, page: p, trackIndex: i, source: source[i])) }
        }
        let named = Set(out.map { "\($0.page)\(normalize($0.title))" })
        for c in chapters where !c.title.isEmpty && !named.contains("\(c.page)\(normalize(c.title))") { out.append(c) }
        return out.sorted { ($0.page, $0.trackIndex ?? Int.max) < ($1.page, $1.trackIndex ?? Int.max) }
    }

    /// "3. Title", "03 Title", "Track 3", "Track 03 - Title" → 3.
    static func leadingNumber(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^(?:track\s*)?(\d{1,3})(?=$|[\s.):\-–—])"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(t[r].filter(\.isNumber))
    }

    // MARK: PDF

    /// The text of each page (up to `maxIndexedPages`) and the flattened outline. Slow on long documents: call it off the main thread,
    /// on a `PDFDocument` that nothing else is using.
    static func extract(_ doc: PDFDocument, cancelled: () -> Bool = { false }) -> (texts: [String], outline: [(title: String, page: Int)]) {
        var outline: [(String, Int)] = []
        func walk(_ o: PDFOutline, depth: Int) {
            guard depth < 8 else { return }
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                if let label = c.label, let page = c.destination?.page ?? (c.action as? PDFActionGoTo)?.destination.page {
                    let idx = doc.index(for: page)
                    if idx != NSNotFound { outline.append((label, idx)) }
                }
                walk(c, depth: depth + 1)
            }
        }
        if let root = doc.outlineRoot { walk(root, depth: 0) }
        var texts: [String] = []
        let n = min(doc.pageCount, maxIndexedPages)
        texts.reserveCapacity(n)
        for i in 0..<n {
            if cancelled() { break }
            texts.append(autoreleasepool { doc.page(at: i)?.string ?? "" })
        }
        return (texts, outline)
    }
}

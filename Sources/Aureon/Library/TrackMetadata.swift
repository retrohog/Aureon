import Foundation

enum CreditRole: String, Codable, CaseIterable, Hashable {
    case artist, albumArtist, composer, conductor, ensemble, soloist, performer, lyricist, arranger, producer, engineer, remixer, featured

    var title: String {
        switch self {
        case .artist: "Artist"; case .albumArtist: "Album artist"; case .composer: "Composer"; case .conductor: "Conductor"
        case .ensemble: "Ensemble"; case .soloist: "Soloist"; case .performer: "Performer"; case .lyricist: "Lyricist"
        case .arranger: "Arranger"; case .producer: "Producer"; case .engineer: "Engineer"; case .remixer: "Remixer"; case .featured: "Featured artist"
        }
    }
    /// Roles that name a group (orchestra, choir, quartet…) rather than a person.
    var usuallyGroup: Bool { self == .ensemble }
}

struct Credit: Codable, Hashable {
    var role: CreditRole
    var name: String
    var instrument: String? = nil
    var sortName: String? = nil
    var mbid: String? = nil
}

/// Everything Aureon understands about a track's tags, independent of the file format.
struct TrackMetadata: Equatable {
    var title: String?
    var album: String?
    var trackNumber: Int?, trackTotal: Int?, discNumber: Int?, discTotal: Int?
    var date: String?, year: Int?
    var genres: [String] = []
    var credits: [Credit] = []

    // classical
    var workTitle: String?
    var catalog: String?                       // Op. 67, BWV 1068, K. 550 …
    var key: String?
    var movementNumber: Int?, movementTotal: Int?
    var movementTitle: String?
    var workInferred = false                   // work/movement were guessed from the title, not tagged

    // release
    var label: String?, releaseCatalogNumber: String?

    // MusicBrainz
    var mbRecordingID: String?, mbTrackID: String?, mbReleaseID: String?, mbReleaseGroupID: String?, mbWorkID: String?

    func credits(_ role: CreditRole) -> [Credit] { credits.filter { $0.role == role } }
    var composers: [Credit] { credits(.composer) }
    var isClassical: Bool { workTitle != nil || !credits(.composer).isEmpty && !credits(.conductor).isEmpty }
}

enum CatalogParser {
    private static let regex = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z])((?:Op\.?|opus)\s*(?:posth\.?\s*)?\d+[a-z]?(?:\s*,?\s*No\.?\s*\d+)?|BWV\.?\s*\d+[a-z]?|KV\.?\s*\d+[a-z]?|K\.\s*\d+[a-z]?|K\s\d{2,4}[a-z]?|D\.\s*\d+[a-z]?|D\s\d{3}[a-z]?|Hob\.?\s*[IVX]+[:/]\s*\d+|RV\.?\s*\d+|HWV\.?\s*\d+|WoO\.?\s*\d+|TrV\.?\s*\d+|Sz\.?\s*\d+|Wq\.?\s*\d+)"#,
        options: [.caseInsensitive])

    /// The first catalogue number found in `text`, normalised to e.g. "Op. 67".
    static func extract(from text: String) -> String? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var s = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^(?i)opus\s*"#, with: "Op. ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?i)op\.?\s*"#, with: "Op. ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?i)bwv\.?\s*"#, with: "BWV ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?i)kv\.?\s*"#, with: "K. ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^K\.?\s*(?=\d)"#, with: "K. ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^D\.?\s*(?=\d)"#, with: "D. ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?i)hwv\.?\s*"#, with: "HWV ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?i)rv\.?\s*"#, with: "RV ", options: .regularExpression)
        return s
    }
}

enum TagInterpreter {
    // MARK: helpers

    /// Splits "A; B" and "A / B" (with spaces), but never "AC/DC" or "Earth, Wind & Fire".
    static func splitMultiple(_ s: String) -> [String] {
        s.replacingOccurrences(of: " / ", with: ";").replacingOccurrences(of: "\u{0}", with: ";").replacingOccurrences(of: "\\\\", with: ";")
            .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "A feat. B & C" → ("A", ["B", "C"]). Also understands "ft.", "featuring" and "(feat. B)". Names that merely contain such a word ("Left Behind") are left alone.
    static func splitFeaturing(_ s: String) -> (primary: String, featured: [String]) {
        var text = s.trimmingCharacters(in: .whitespaces)
        var featured: [String] = []
        func people(_ t: String) -> [String] {
            t.replacingOccurrences(of: " & ", with: ",").replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: ";", with: ",")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let r = text.range(of: #"[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+([^\)\]]+)[\)\]]"#, options: [.regularExpression, .caseInsensitive]) {
            let inner = String(text[r]).replacingOccurrences(of: #"^[\(\[]\s*(?i:feat\.?|ft\.?|featuring)\s+"#, with: "", options: .regularExpression).dropLast()
            featured += people(String(inner))
            text.removeSubrange(r)
        }
        if let r = text.range(of: #"\s+(?:feat\.?|ft\.?|featuring)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            featured += people(String(text[r.upperBound...]))
            text = String(text[..<r.lowerBound])
        }
        let primary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (primary.isEmpty ? s : primary, featured)
    }

    /// Composer, lyricist and similar fields often hold "Lennon, McCartney" or "A & B". "Beethoven, Ludwig van" (surname first) stays one name.
    static func splitPeople(_ s: String) -> [String] {
        var out: [String] = []
        for piece in splitMultiple(s) {
            if piece.contains(", ") {
                let parts = piece.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                // "John Lennon, Paul McCartney" are two people; "Beethoven, Ludwig van" and "Earth, Wind & Fire" are one name
                if parts.count >= 2, parts.allSatisfy({ $0.contains(" ") && $0.first?.isUppercase == true && !$0.contains(" & ") }) { out += parts } else { out.append(piece) }
            } else {
                out += piece.components(separatedBy: " & ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        return out
    }

    /// Case- and accent-insensitive comparison key.
    static func fold(_ s: String) -> String { LibraryStore.fold(s) }

    static func number(_ s: String?) -> (Int?, Int?) {
        guard let s else { return (nil, nil) }
        let parts = s.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        return (parts.first ?? nil, parts.count > 1 ? parts[1] : nil)
    }

    static func roman(_ s: String) -> Int? {
        let map: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
        let u = Array(s.uppercased())
        guard !u.isEmpty, u.allSatisfy({ map[$0] != nil }) else { return nil }
        var total = 0
        for (i, c) in u.enumerated() { let v = map[c]!; if i + 1 < u.count, map[u[i + 1]]! > v { total -= v } else { total += v } }
        return total
    }

    /// "II. Andante" / "2 - Andante" / "IV Finale" → (2, "Andante")
    static func leadingMovement(_ s: String) -> (Int?, String)? {
        let pattern = #"^\s*([IVXLC]+|\d{1,2})\s*[\.\):\-–—]\s*(.+)$"#
        guard let m = s.range(of: pattern, options: .regularExpression) else { return nil }
        let t = String(s[m])
        let ns = t as NSString
        guard let re = try? NSRegularExpression(pattern: pattern), let r = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let numText = ns.substring(with: r.range(at: 1)), rest = ns.substring(with: r.range(at: 2)).trimmingCharacters(in: .whitespaces)
        return (Int(numText) ?? roman(numText), rest)
    }

    static func roleAndInstrument(from annotation: String) -> (CreditRole, String?) {
        let a = annotation.lowercased()
        if a.contains("conductor") { return (.conductor, nil) }
        for w in ["orchestra", "ensemble", "quartet", "quintet", "trio", "choir", "chorus", "philharmonic", "symphony", "consort", "band", "sinfonia"] where a.contains(w) { return (.ensemble, nil) }
        if a.contains("composer") { return (.composer, nil) }
        if a.contains("lyric") { return (.lyricist, nil) }
        if a.contains("arrang") { return (.arranger, nil) }
        if a.contains("produc") { return (.producer, nil) }
        if a.contains("engineer") || a.contains("mix") { return (.engineer, nil) }
        return (.performer, annotation.trimmingCharacters(in: .whitespaces))
    }

    /// "Anne-Sophie Mutter (violin)" → name + instrument; "Berliner Philharmoniker (orchestra)" → ensemble.
    static func parsePerformer(_ s: String) -> Credit? {
        var name = s.trimmingCharacters(in: .whitespaces), note: String?
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            note = String(name[name.index(after: open)..<name.index(before: name.endIndex)]).trimmingCharacters(in: .whitespaces)
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty else { return nil }
        var role = CreditRole.performer, instrument: String? = nil
        if let note {
            // "role: instrument" is how some taggers write it
            let afterColon = note.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? note
            (role, instrument) = roleAndInstrument(from: afterColon)
        }
        return Credit(role: role, name: name, instrument: instrument)
    }

    private static func list(_ t: RawTags, _ keys: String...) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for k in keys { for v in t.all(k) { for p in splitMultiple(v) where seen.insert(p).inserted { out.append(p) } } }
        return out
    }

    private static func credits(_ role: CreditRole, names: [String], sorts: [String] = [], mbids: [String] = []) -> [Credit] {
        names.enumerated().map { i, n in
            Credit(role: role, name: n, sortName: sorts.count == names.count ? sorts[i] : nil, mbid: mbids.count == names.count ? mbids[i] : nil)
        }
    }

    // MARK: main entry

    static func interpret(_ t: RawTags, fileName: String = "") -> TrackMetadata {
        var m = TrackMetadata()
        m.title = t.first("TITLE")
        m.album = t.first("ALBUM")
        (m.trackNumber, m.trackTotal) = number(t.first("TRACKNUMBER", "TRACK"))
        if m.trackTotal == nil { m.trackTotal = Int(t.first("TRACKTOTAL", "TOTALTRACKS") ?? "") }
        (m.discNumber, m.discTotal) = number(t.first("DISCNUMBER", "DISC"))
        if m.discTotal == nil { m.discTotal = Int(t.first("DISCTOTAL", "TOTALDISCS") ?? "") }
        m.date = t.first("DATE", "YEAR", "ORIGINALDATE")
        if let d = m.date, d.count >= 4, let y = Int(d.prefix(4)) { m.year = y }
        m.genres = list(t, "GENRE")
        m.label = t.first("LABEL", "ORGANIZATION"); m.releaseCatalogNumber = t.first("CATALOGNUMBER")

        // people: multiple values and parallel MusicBrainz / sort lists
        // "A feat. B" is one primary artist plus a featured one: the primary owns the album, the featured artist is credited on the track
        var featuredNames: [String] = []
        func primaries(_ names: [String]) -> [String] {
            var out: [String] = []
            for n in names { let (p, f) = splitFeaturing(n); out.append(p); featuredNames += f }
            return out
        }
        let rawArtists = list(t, "ARTISTS").isEmpty ? list(t, "ARTIST") : list(t, "ARTISTS")
        let artists = primaries(rawArtists)
        let rawAlbumArtists = list(t, "ALBUMARTISTS").isEmpty ? list(t, "ALBUMARTIST") : list(t, "ALBUMARTISTS")
        let albumArtists = primaries(rawAlbumArtists)
        m.credits += credits(.artist, names: artists, sorts: rawArtists.count == artists.count ? t.all("ARTISTSORT") : [], mbids: rawArtists.count == artists.count ? t.all("MUSICBRAINZARTISTID") : [])
        m.credits += credits(.albumArtist, names: albumArtists, sorts: t.all("ALBUMARTISTSORT"), mbids: rawAlbumArtists.count == albumArtists.count ? t.all("MUSICBRAINZALBUMARTISTID") : [])
        if let title = t.first("TITLE") { featuredNames += splitFeaturing(title + " ").featured }
        var seenFeatured = Set(artists.map { fold($0) } + albumArtists.map { fold($0) })
        for f in featuredNames where seenFeatured.insert(fold(f)).inserted { m.credits.append(Credit(role: .featured, name: f)) }
        m.credits += credits(.composer, names: (t.all("COMPOSER") + t.all("COMPOSERS")).flatMap(splitPeople).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, sorts: t.all("COMPOSERSORT"))
        m.credits += credits(.conductor, names: list(t, "CONDUCTOR", "CONDUCTORS"))
        m.credits += credits(.ensemble, names: list(t, "ENSEMBLE", "ORCHESTRA", "CHOIR"))
        m.credits += credits(.lyricist, names: list(t, "LYRICIST", "LYRICIST"))
        m.credits += credits(.arranger, names: list(t, "ARRANGER"))
        m.credits += credits(.producer, names: list(t, "PRODUCER"))
        m.credits += credits(.engineer, names: list(t, "ENGINEER", "MIXER"))
        m.credits += credits(.remixer, names: list(t, "REMIXER"))
        for p in t.all("PERFORMER") + t.all("SOLOIST", "SOLOISTS") {
            for piece in p.contains("(") ? [p] : splitMultiple(p) {
                if var c = parsePerformer(piece) {
                    if t.all("SOLOIST", "SOLOISTS").contains(p) { c.role = .soloist }
                    if !m.credits.contains(where: { $0.role == c.role && $0.name == c.name && $0.instrument == c.instrument }) { m.credits.append(c) }
                }
            }
        }

        // classical structure
        m.workTitle = t.first("WORK", "WORKNAME", "CLASSICALWORK")
        m.movementTitle = t.first("MOVEMENTNAME", "MOVEMENTTITLE")
        let mv = number(t.first("MOVEMENT", "MOVEMENTNUMBER"))
        m.movementNumber = mv.0 ?? roman(t.first("MOVEMENT", "MOVEMENTNUMBER") ?? "")
        m.movementTotal = mv.1 ?? Int(t.first("MOVEMENTTOTAL", "MOVEMENTS") ?? "")
        if m.workTitle == nil, let g = t.first("GROUPING"), (m.movementTitle != nil || m.movementNumber != nil) { m.workTitle = g }
        m.catalog = t.first("OPUS", "WORKCATALOG") ?? (m.workTitle.flatMap(CatalogParser.extract(from:)))
        m.key = t.first("KEY", "INITIALKEY")

        // conservative inference: "Symphony No. 5 in C minor, Op. 67: I. Allegro con brio" with a composer present
        if m.workTitle == nil, !m.composers.isEmpty, let title = m.title, let r = title.range(of: ": ") {
            let w = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), rest = String(title[r.upperBound...])
            if w.count >= 3 && !rest.isEmpty {
                m.workTitle = w; m.workInferred = true
                if let (n, name) = leadingMovement(rest) { m.movementNumber = m.movementNumber ?? n; m.movementTitle = m.movementTitle ?? name }
                else { m.movementTitle = m.movementTitle ?? rest }
                m.catalog = m.catalog ?? CatalogParser.extract(from: w)
            }
        }
        if m.movementTitle == nil, m.workTitle != nil, let title = m.title, let (n, name) = leadingMovement(title) { m.movementNumber = m.movementNumber ?? n; m.movementTitle = name }

        m.mbRecordingID = t.first("MUSICBRAINZTRACKID", "MUSICBRAINZRECORDINGID")
        m.mbTrackID = t.first("MUSICBRAINZRELEASETRACKID")
        m.mbReleaseID = t.first("MUSICBRAINZALBUMID", "MUSICBRAINZRELEASEID")
        m.mbReleaseGroupID = t.first("MUSICBRAINZRELEASEGROUPID")
        m.mbWorkID = t.first("MUSICBRAINZWORKID")
        if m.title == nil, !fileName.isEmpty { m.title = (fileName as NSString).deletingPathExtension }
        return m
    }
}

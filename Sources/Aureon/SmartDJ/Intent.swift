import Foundation

// Smart DJ, part 1: what the listener asked for. A small language model is good at ordering and at breaking ties; it is poor at
// arithmetic on a catalogue. So the request is first read by plain code into hard facts (how many, which genres, which tempo, which
// decade), the library is narrowed with them, and the model only chooses from what is left.

struct DJIntent: Equatable {
    enum Energy: String { case low, medium, high }
    var count = 10
    var genres: [String] = []          // lower-case words that match library genres
    var avoidGenres: [String] = []
    var artists: [String] = []         // lower-case names of library artists the request mentions
    var bpm: ClosedRange<Double>?
    var energy: Energy?
    var decades: [Int] = []            // 1980, 1990 …
    var years: ClosedRange<Int>?
    var keywords: [String] = []        // other meaningful words, matched against titles and albums
    var moods: [String] = []           // for display: what was understood
    var onlyLiked = false

    var hasConstraints: Bool { !genres.isEmpty || !artists.isEmpty || bpm != nil || energy != nil || !decades.isEmpty || years != nil || onlyLiked }

    /// One line a person can read: "10 tracks · electronic · 120–180 BPM · high energy".
    var summary: String {
        var p = ["\(count) track\(count == 1 ? "" : "s")"]
        if !genres.isEmpty { p.append(genres.joined(separator: ", ")) }
        if !artists.isEmpty { p.append(artists.map { $0.capitalized }.joined(separator: ", ")) }
        if let b = bpm { p.append("\(Int(b.lowerBound))–\(b.upperBound >= 400 ? "∞" : "\(Int(b.upperBound))") BPM") }
        if let e = energy { p.append("\(e.rawValue) energy") }
        if !decades.isEmpty { p.append(decades.map { "\($0 % 100 == 0 ? "\($0)s" : "\($0)s")" }.joined(separator: ", ")) }
        if let y = years { p.append("\(y.lowerBound)–\(y.upperBound)") }
        if onlyLiked { p.append("liked songs") }
        return p.joined(separator: " · ")
    }
}

/// What the library knows by name, so mentions can be recognised.
struct LibraryVocabulary: Equatable {
    var genres: Set<String> = []         // lower-case
    var artists: [String] = []           // lower-case, longest first

    init(genres: Set<String> = [], artists: [String] = []) {
        self.genres = genres
        self.artists = Array(Set(artists.filter { $0.count >= 3 })).sorted { $0.count > $1.count }
    }
    init(tracks: [TrackDTO]) {
        var g = Set<String>(), a = Set<String>()
        for t in tracks {
            for x in t.genres { g.insert(x.lowercased()) }
            for n in t.names(.artist) + t.names(.albumArtist) { a.insert(n.lowercased()) }
        }
        self.init(genres: g, artists: Array(a))
    }
}

enum IntentParser {
    static let numberWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
                                              "fourteen": 14, "fifteen": 15, "sixteen": 16, "eighteen": 18, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "dozen": 12, "couple": 2, "few": 5]
    static let decadeWords: [String: Int] = ["fifties": 1950, "sixties": 1960, "seventies": 1970, "eighties": 1980, "nineties": 1990, "noughties": 2000, "aughts": 2000]

    private static let highWords: Set<String> = ["upbeat", "energetic", "energizing", "energising", "pumping", "hype", "party", "dance", "dancing", "danceable", "workout", "gym", "run", "running", "cardio", "fast", "driving", "intense", "banger", "bangers", "uptempo", "lively", "motivating", "motivational", "festival", "club"]
    private static let workoutWords: Set<String> = ["workout", "gym", "run", "running", "cardio", "training", "exercise"]
    private static let lowWords: Set<String> = ["chill", "chilled", "relax", "relaxing", "relaxed", "calm", "calming", "mellow", "lounge", "study", "studying", "focus", "sleep", "sleepy", "ambient", "soft", "quiet", "slow", "laid-back", "background", "dinner", "rainy", "gentle", "peaceful", "soothing", "unwind", "bedtime", "cozy", "cosy"]
    private static let sleepWords: Set<String> = ["sleep", "sleepy", "bedtime", "lullaby"]
    private static let stop: Set<String> = ["give", "play", "some", "songs", "song", "tracks", "track", "music", "me", "for", "the", "and", "with", "that", "this", "from", "like", "something", "make", "playlist", "set", "mix", "want", "need", "please", "good", "great", "best", "nice", "really", "very", "just", "about", "into", "over", "under", "only", "also", "more", "most", "less", "than", "then", "them", "they", "your", "have", "show", "find", "put", "get", "which", "when", "what", "where", "would", "could", "should", "tonight", "today", "now", "all", "any", "can", "you", "are", "was", "were", "will", "its", "not", "but", "out", "off", "too", "own"]
    private static let genreSynonyms: [String: [String]] = ["edm": ["electronic", "dance", "house", "techno", "trance"], "electronica": ["electronic"], "rap": ["hip hop", "hip-hop", "rap"], "hiphop": ["hip hop", "hip-hop"],
                                                            "rnb": ["r&b", "rnb", "soul"], "r&b": ["r&b", "rnb", "soul"], "classical": ["classical"], "orchestral": ["classical", "orchestral"], "metal": ["metal"], "country": ["country"],
                                                            "reggae": ["reggae"], "folk": ["folk"], "blues": ["blues"], "indie": ["indie"], "punk": ["punk"], "disco": ["disco"], "funk": ["funk"], "soul": ["soul"], "latin": ["latin"], "lofi": ["lo-fi", "lofi", "lo fi"]]

    private static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "’", with: "'").split { !($0.isLetter || $0.isNumber || $0 == "&" || $0 == "-" || $0 == "'") }.map(String.init)
    }

    static func parse(_ prompt: String, vocabulary v: LibraryVocabulary) -> DJIntent {
        var intent = DJIntent()
        var text = " " + prompt.lowercased().replacingOccurrences(of: "’", with: "'") + " "

        // explicit BPM: "128 bpm", "around 120 bpm"
        if let r = text.range(of: #"(\d{2,3})\s*bpm"#, options: .regularExpression) {
            let n = Double(text[r].filter(\.isNumber)) ?? 0
            if n >= 40 && n <= 260 { intent.bpm = (n - 8)...(n + 8); intent.moods.append("\(Int(n)) BPM") }
            text.replaceSubrange(r, with: " ")
        }
        // decades: "80s", "1990s", "nineties"
        while let r = text.range(of: #"\b(19|20)?\d0'?s\b"#, options: .regularExpression) {
            let digits = text[r].filter(\.isNumber)
            var y = Int(digits) ?? 0
            if digits.count == 2 { y += y < 30 ? 2000 : 1900 }
            if y >= 1900 && y <= 2090 { intent.decades.append(y) }
            text.replaceSubrange(r, with: " ")
        }
        for (w, y) in decadeWords where text.contains(" \(w) ") { intent.decades.append(y); text = text.replacingOccurrences(of: " \(w) ", with: " ") }
        intent.decades = Array(Set(intent.decades)).sorted()
        // a single year or a range: "from 1999", "2005-2010"
        if let r = text.range(of: #"\b(19|20)\d{2}\s*(-|to|–)\s*(19|20)\d{2}\b"#, options: .regularExpression) {
            let ys = text[r].split { !$0.isNumber }.compactMap { Int($0) }
            if ys.count == 2, ys[0] <= ys[1] { intent.years = ys[0]...ys[1] }
            text.replaceSubrange(r, with: " ")
        } else if let r = text.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            if let y = Int(text[r]) { intent.years = y...y }
            text.replaceSubrange(r, with: " ")
        }

        // count
        let ws = words(text)
        if let r = text.range(of: #"\b\d{1,3}\b"#, options: .regularExpression), let n = Int(text[r]), n >= 1 { intent.count = min(50, n) }
        else {
            for (i, w) in ws.enumerated() {
                if w == "a" || w == "the", i + 1 < ws.count, ws[i + 1] == "dozen" { intent.count = 12; break }
                if let n = numberWords[w], w != "few" || ws.contains("tracks") || ws.contains("songs") { intent.count = n; break }
            }
        }

        // moods
        let wordSet = Set(ws)
        let high = !wordSet.isDisjoint(with: highWords), low = !wordSet.isDisjoint(with: lowWords)
        if high && !low {
            intent.energy = .high
            if intent.bpm == nil { intent.bpm = (wordSet.isDisjoint(with: workoutWords) ? 110 : 120)...(wordSet.isDisjoint(with: workoutWords) ? 400 : 185) }
            intent.moods += wordSet.intersection(highWords).sorted()
        } else if low && !high {
            intent.energy = .low
            if intent.bpm == nil { intent.bpm = 0...(wordSet.isDisjoint(with: sleepWords) ? 105 : 85) }
            intent.moods += wordSet.intersection(lowWords).sorted()
        } else if wordSet.contains("happy") || wordSet.contains("feel-good") { intent.energy = .medium; if intent.bpm == nil { intent.bpm = 95...400 }; intent.moods.append("happy") }
        if wordSet.contains("sad") || wordSet.contains("melancholy") || wordSet.contains("melancholic") { intent.energy = .low; intent.moods.append("sad") }
        if wordSet.contains("liked") || wordSet.contains("favourites") || wordSet.contains("favorites") || wordSet.contains("favourite") || wordSet.contains("favorite") { intent.onlyLiked = true }

        // negations: "no rock", "without metal"
        var negated = Set<String>()
        for (i, w) in ws.enumerated() where ["no", "without", "except", "not", "avoid", "excluding"].contains(w) && i + 1 < ws.count { negated.insert(ws[i + 1]); if i + 2 < ws.count { negated.insert(ws[i + 1] + " " + ws[i + 2]) } }

        // genres
        let flat = " " + ws.joined(separator: " ").replacingOccurrences(of: "-", with: " ") + " "
        for g in v.genres.sorted() {
            let key = g.replacingOccurrences(of: "-", with: " ")
            guard !key.isEmpty, flat.contains(" \(key) ") || flat.contains(" \(key)s ") else { continue }
            if negated.contains(g) || negated.contains(key) { intent.avoidGenres.append(g) } else { intent.genres.append(g) }
        }
        for w in ws {
            guard let syn = genreSynonyms[w], !negated.contains(w) else { continue }
            for s in syn {
                let hits = v.genres.filter { $0.contains(s.replacingOccurrences(of: "-", with: " ")) || $0.replacingOccurrences(of: "-", with: " ").contains(s.replacingOccurrences(of: "-", with: " ")) }
                for h in hits.sorted() where !intent.genres.contains(h) { intent.genres.append(h) }
            }
        }
        // genre words used loosely: "electronic" when the library says "Electronic/Dance"
        for w in ws where w.count >= 4 && !stop.contains(w) {
            for g in v.genres where g.contains(w) && !intent.genres.contains(g) && !negated.contains(w) && g != w { intent.genres.append(g) }
        }

        // artists
        for a in v.artists where flat.contains(" \(a.replacingOccurrences(of: "-", with: " ")) ") {
            if !intent.artists.contains(where: { $0.contains(a) }) { intent.artists.append(a) }
        }

        // leftovers worth matching against titles
        let known = Set(intent.genres.flatMap { $0.split(separator: " ").map(String.init) } + intent.artists.flatMap { $0.split(separator: " ").map(String.init) } + intent.moods + Array(highWords) + Array(lowWords) + Array(stop) + Array(numberWords.keys))
        intent.keywords = ws.filter { $0.count >= 4 && !known.contains($0) && !$0.allSatisfy(\.isNumber) && !negated.contains($0) }
        return intent
    }
}

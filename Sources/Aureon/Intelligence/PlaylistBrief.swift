import Foundation

// Natural-language playlists, part 1: what the listener asked for, as hard facts.
//
// "Create a 2-hour mix of late-night, low-energy acoustic tracks with high dynamic range" becomes a length (7 200 s), a mood (quiet, low
// energy, winding down), a feel (acoustic) and a recording quality (dynamic range DR11 or better). Plain code does this reading, so the
// numbers are always right. The language model (when allowed) only fills in what the words leave open, and the library does the choosing.

struct PlaylistBrief: Equatable {
    /// The shape of the energy over the playlist.
    enum Arc: String, Codable, CaseIterable, Equatable {
        case steady, windDown, buildUp, journey
        var title: String {
            switch self {
            case .steady: "steady"
            case .windDown: "winding down"
            case .buildUp: "building up"
            case .journey: "rising and falling"
            }
        }
    }

    var request: String
    /// How long the playlist should run, when the request names a length.
    var targetSeconds: Double?
    /// How many songs, when the request names a number.
    var trackCount: Int?
    /// Genres, artists, tempo, energy, decades, years, keywords, "liked only". (Its `count` is not used.)
    var intent = DJIntent()
    /// Recordings must have at least this DR score ("high dynamic range" → 11).
    var minDynamicRange: Double?
    /// Recordings must have at most this DR score ("loud", "compressed").
    var maxDynamicRange: Double?
    /// Late night, bedtime: gentle loudness is preferred.
    var quiet = false
    var acoustic = false
    var instrumental = false
    var arc = Arc.steady
    /// Genres the language model suggested for a vague request: they nudge the ranking, they never exclude a song.
    var hintGenres: [String] = []
    /// Points the reader should know about (what was understood loosely).
    var notes: [String] = []

    static let defaultTrackCount = 20

    var hasConstraints: Bool {
        intent.hasConstraints || minDynamicRange != nil || maxDynamicRange != nil || quiet || acoustic || instrumental
    }

    /// One line a person can read: "2 h · low energy · acoustic · DR ≥ 11 · winding down".
    var summary: String {
        var p: [String] = []
        if let s = targetSeconds { p.append(Self.formatDuration(s)) }
        else { p.append("\(trackCount ?? Self.defaultTrackCount) songs") }
        if !intent.genres.isEmpty { p.append(intent.genres.joined(separator: ", ")) }
        if !intent.artists.isEmpty { p.append(intent.artists.map { $0.capitalized }.joined(separator: ", ")) }
        if let e = intent.energy { p.append("\(e.rawValue) energy") }
        if let b = intent.bpm { p.append("\(Int(b.lowerBound))–\(b.upperBound >= 400 ? "∞" : "\(Int(b.upperBound))") BPM") }
        if acoustic { p.append("acoustic") }
        if instrumental { p.append("instrumental") }
        if quiet { p.append("quiet") }
        if let d = minDynamicRange { p.append("DR ≥ \(Int(d))") }
        if let d = maxDynamicRange { p.append("DR ≤ \(Int(d))") }
        if !intent.decades.isEmpty { p.append(intent.decades.map { "\($0)s" }.joined(separator: ", ")) }
        if let y = intent.years { p.append(y.lowerBound == y.upperBound ? "\(y.lowerBound)" : "\(y.lowerBound)–\(y.upperBound)") }
        if intent.onlyLiked { p.append("liked songs") }
        if arc != .steady { p.append(arc.title) }
        return p.joined(separator: " · ")
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int((seconds / 60).rounded())
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

enum PlaylistBriefParser {
    private static let numberWords: [String: Double] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]

    // MARK: length

    /// A length in the request ("2-hour", "90 minutes", "an hour and a half", "half an hour"), and the text without it.
    static func extractDuration(from text: String) -> (seconds: Double, rest: String)? {
        var t = text
        func number(_ s: String) -> Double? { Double(s) ?? numberWords[s] }
        func replace(_ pattern: String, _ body: ([String]) -> Double?) -> Double? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let ns = t as NSString
            guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let groups = (0..<m.numberOfRanges).map { i -> String in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)).lowercased() }
            guard let v = body(groups) else { return nil }
            t = ns.replacingCharacters(in: m.range, with: " ")
            return v
        }
        let num = #"(\d+(?:\.\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"#
        // "an hour and a half", "1 hour and a half", "two and a half hours"
        if let v = replace(#"\b(?:an?|"# + num + #")[\s-]*hours?\s+and\s+a\s+half\b"#, { g in (number(g[1]) ?? 1) * 3600 + 1800 }) { return (v, t) }
        if let v = replace(#"\b"# + num + #"\s+and\s+a\s+half[\s-]*hours?\b"#, { g in (number(g[1]) ?? 0) * 3600 + 1800 }) { return (v, t) }
        if let v = replace(#"\bhalf\s+an?\s+hour\b|\bhalf[\s-]*hour\b"#, { _ in 1800 }) { return (v, t) }
        // "2 hours 30 minutes", "1h30" (the minutes need their unit, so "1 hour, 30 songs" stays an hour and thirty songs)
        if let v = replace(#"\b"# + num + #"[\s-]*(?:hours?|hrs?)\b[\s,]*(?:and\s+)?(\d{1,2})[\s-]*(?:minutes?|mins?)\b"#, { g in
            guard let h = number(g[1]), let m = Double(g[2]), m < 60 else { return nil }
            return h * 3600 + m * 60 }) { return (v, t) }
        if let v = replace(#"\b(\d{1,2})h(\d{1,2})\b"#, { g in
            guard let h = Double(g[1]), let m = Double(g[2]), m < 60 else { return nil }
            return h * 3600 + m * 60 }) { return (v, t) }
        if let v = replace(#"\b"# + num + #"[\s-]*(?:hours?|hrs?|h)\b"#, { g in number(g[1]).map { $0 * 3600 } }) { return (v, t) }
        if let v = replace(#"\b(?:an|one)\s+hour\b"#, { _ in 3600 }) { return (v, t) }
        if let v = replace(#"\b(\d{1,3})[\s-]*(?:minutes?|mins?|min)\b"#, { g in Double(g[1]).map { $0 * 60 } }) { return (v, t) }
        return nil
    }

    // MARK: phrases

    private struct Rule {
        let pattern: String
        let apply: (inout PlaylistBrief, inout Flags, [String]) -> Void
    }
    private struct Flags { var energy: DJIntent.Energy?; var gentle = false }

    private static let rules: [Rule] = [
        // dynamic range: "DR14", "high dynamic range", "wide dynamics", "uncompressed" / "low dynamic range", "compressed", "loud"
        Rule(pattern: #"\bdr[\s-]?(\d{1,2})\b"#) { b, _, g in if let n = Double(g[1]) { b.minDynamicRange = min(20, max(4, n)) } },
        Rule(pattern: #"\b(?:low|narrow|small|little)[\s-]+dynamic(?:s|[\s-]+range)\b|\bbrickwalled\b|\bheavily\s+compressed\b"#) { b, _, _ in b.maxDynamicRange = 7 },
        Rule(pattern: #"\b(?:(?:high|wide|large|big|good|great|natural|full|rich|huge|maximum|best)[\s-]+)?dynamic[\s-]+range\b|\b(?:high|wide|large|big|good|great|natural|full|rich|huge)[\s-]+dynamics\b|\buncompressed\b|\baudiophile[\s-]+(?:grade|quality)\b|\bwell[\s-]+recorded\b"#) { b, _, _ in
            b.minDynamicRange = max(b.minDynamicRange ?? 0, 11)
        },
        // time of day
        Rule(pattern: #"\blate[\s-]*night\b|\bmidnight\b|\bafter[\s-]+dark\b|\bnight[\s-]*time\b|\binsomnia\b|\bbed[\s-]*time\b|\bbefore[\s-]+bed\b|\bgoing\s+to\s+sleep\b|\blullab(?:y|ies)\b|\b[1-4]\s?am\b"#) { b, f, _ in
            b.quiet = true; if f.energy == nil { f.energy = .low }; b.arc = .windDown; b.intent.moods.append("late night")
        },
        Rule(pattern: #"\bwind(?:ing)?[\s-]+down\b|\bcool(?:ing)?[\s-]+down\b|\bunwind(?:ing)?\b"#) { b, f, _ in b.arc = .windDown; if f.energy == nil { f.energy = .low }; b.quiet = true },
        Rule(pattern: #"\bbuild(?:ing)?[\s-]+up\b|\bwarm(?:ing)?[\s-]+up\b|\bramp(?:ing)?[\s-]+up\b|\bcrescendo\b"#) { b, _, _ in b.arc = .buildUp },
        Rule(pattern: #"\bjourney\b|\brise\s+and\s+fall\b|\bebb\s+and\s+flow\b|\broller[\s-]*coaster\b"#) { b, _, _ in b.arc = .journey },
        // energy
        Rule(pattern: #"\b(?:low|soft|gentle|quiet|laid[\s-]*back)[\s-]+energy\b|\blow[\s-]+key\b"#) { _, f, _ in f.energy = .low; f.gentle = true },
        Rule(pattern: #"\b(?:high|big|max(?:imum)?)[\s-]+energy\b"#) { _, f, _ in f.energy = .high },
        Rule(pattern: #"\b(?:medium|moderate|mid)[\s-]+energy\b"#) { _, f, _ in f.energy = .medium },
        // feel
        Rule(pattern: #"\bacoustic\b|\bunplugged\b|\bstripped(?:[\s-]+back)?\b|\bunamplified\b"#) { b, _, _ in b.acoustic = true },
        Rule(pattern: #"\binstrumentals?\b|\bno\s+vocals\b|\bwithout\s+(?:vocals|singing|lyrics)\b|\bwordless\b"#) { b, _, _ in b.instrumental = true },
        // verbs and filler that would otherwise become title keywords
        Rule(pattern: #"\b(?:create|build|generate|compile|curate|assemble|queue(?:\s+up)?|put\s+together|make\s+me|mix|playlist)\b"#) { _, _, _ in },
    ]

    private static func apply(_ rule: Rule, to text: inout String, brief: inout PlaylistBrief, flags: inout Flags) {
        guard let re = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { return }
        while true {
            let ns = text as NSString
            guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return }
            let groups = (0..<m.numberOfRanges).map { i -> String in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)).lowercased() }
            rule.apply(&brief, &flags, groups)
            text = ns.replacingCharacters(in: m.range, with: " ")
        }
    }

    // MARK: entry

    static func parse(_ request: String, vocabulary: LibraryVocabulary) -> PlaylistBrief {
        var brief = PlaylistBrief(request: request)
        var text = " " + request.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        var flags = Flags()

        if let d = extractDuration(from: text) {
            brief.targetSeconds = min(max(d.seconds, 120), 24 * 3600)
            text = d.rest
        }
        // an explicit number of songs: "20 songs", "ten upbeat electronic tracks"
        if let re = try? NSRegularExpression(pattern: #"\b(\d{1,3}|"# + IntentParser.numberWords.keys.joined(separator: "|") + #")\s+(?:[\w'&-]+\s+){0,3}?(?:tracks?|songs?|tunes)\b"#, options: [.caseInsensitive]) {
            let ns = text as NSString
            if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let w = ns.substring(with: m.range(at: 1)).lowercased()
                if let n = Int(w) ?? IntentParser.numberWords[w], n >= 1 { brief.trackCount = min(n, 200) }
            }
        }
        for r in rules { apply(r, to: &text, brief: &brief, flags: &flags) }

        // genres, artists, tempo, decades, years, "liked" and the other keywords
        var intent = IntentParser.parse(text, vocabulary: vocabulary)
        if let e = flags.energy {
            intent.energy = e
            if !intent.moods.contains(where: { $0.hasSuffix("BPM") }) {
                switch e {
                case .low: intent.bpm = 0...(brief.quiet ? 100 : 105)
                case .high: intent.bpm = 110...400
                case .medium: intent.bpm = 90...130
                }
            }
        }
        if brief.quiet, intent.energy == nil { intent.energy = .low }
        intent.moods += brief.intent.moods
        intent.keywords.removeAll { ["acoustic", "dynamic", "range", "energy", "night", "midnight", "tracks", "songs"].contains($0) }
        brief.intent = intent

        if brief.targetSeconds == nil && brief.trackCount == nil { brief.trackCount = PlaylistBrief.defaultTrackCount }
        if let lo = brief.minDynamicRange, let hi = brief.maxDynamicRange, lo > hi { brief.maxDynamicRange = nil }
        return brief
    }
}

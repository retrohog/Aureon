import Foundation

// Natural-language playlists, part 2: choosing the songs.
//
//   request ─► brief (plain code) ─► [model: fills what the words leave open] ─► score the whole library ─► [model: picks from the best 60]
//           ─► fit the length ─► order along the energy arc ─► playlist
//
// The library is scored with the facts Aureon measured (tempo, key, energy from the DJ analysis; loudness, loudness range and DR from the
// R128 analysis) plus tags and, when Semantic Search is on, similarity of meaning. The model never decides alone: its picks are checked
// against the same scores, and without a model the ranking answers the request by itself.

/// A song with its score for one request.
struct PlaylistRanked: Equatable {
    var song: SmartDJTrack
    var score: Double
}

/// The answer to one request.
struct PlaylistPlan: Equatable, Identifiable {
    let id = UUID()
    var request: String
    var brief: PlaylistBrief
    var tracks: [TrackDTO]
    var seconds: Double
    var usedModel = false
    var modelPicked = 0
    var engine = "ranking"
    var notes: [String] = []
    var elapsed = 0.0
    var name: String { PlaylistEngine.suggestedName(for: request) }
}

enum PlaylistRelevance {
    static let acousticGenres = ["acoustic", "folk", "singer", "songwriter", "classical", "chamber", "piano", "jazz", "blues", "bluegrass", "country", "unplugged",
                                 "baroque", "new age", "lute", "guitar", "americana", "bossa", "lieder", "early music", "string quartet"]
    static let instrumentalGenres = ["instrumental", "classical", "ambient", "post-rock", "post rock", "soundtrack", "score", "piano", "chamber", "baroque", "new age",
                                     "orchestral", "symphon", "concerto", "sonata", "minimal", "drone", "lo-fi", "lofi", "jazz"]

    /// How well a song fits the brief. Higher is better; only meaningful relative to other songs for the same brief.
    static func score(_ s: SmartDJTrack, brief b: PlaylistBrief, semantic: Float?) -> Double {
        var r = Relevance.score(s, b.intent)
        let t = s.track
        let genres = t.genres.map { $0.lowercased() }
        if let lo = b.minDynamicRange {
            if let dr = t.dr { r += dr >= lo ? 2 + min(1, (dr - lo) / 6) : -min(4, (lo - dr) * 0.8) } else { r -= 0.4 }
        }
        if let hi = b.maxDynamicRange {
            if let dr = t.dr { r += dr <= hi ? 1.5 : -min(4, (dr - hi) * 0.8) } else { r -= 0.4 }
        }
        if b.quiet, let l = t.lufs { r += l <= -17 ? 1 : (l >= -11 ? -1.5 : 0) }
        if b.acoustic {
            var a = 0.0
            if genres.contains(where: { g in acousticGenres.contains { g.contains($0) } }) { a += 2.5 }
            let hay = (t.title + " " + (t.releaseTitle ?? "")).lowercased()
            if ["acoustic", "unplugged", "piano", "stripped"].contains(where: { hay.contains($0) }) { a += 1.5 }
            if let e = s.energy, e > 0.65 { a -= 1.5 }
            if let dr = t.dr, dr >= 10 { a += 0.5 }
            r += a
        }
        if b.instrumental {
            var a = 0.0
            if genres.contains(where: { g in instrumentalGenres.contains { g.contains($0) } }) { a += 1.5 }
            if t.title.lowercased().contains("instrumental") { a += 3 }
            r += a
        }
        if !b.hintGenres.isEmpty, genres.contains(where: { g in b.hintGenres.contains { g.contains($0) || $0.contains(g) } }) { r += 1.5 }
        if let sem = semantic { r += Double(sem) * 4 }
        return r
    }
}

enum PlaylistEngine {
    /// Songs shorter than this are interludes and skits, not playlist material.
    static let minimumSongSeconds = 45.0

    // MARK: ranking

    /// True when the song breaks something the request states outright: an excluded or missing genre, another artist, an unliked song for "liked only",
    /// the wrong decade, or a measured dynamic range well outside the one asked for. Tempo, energy and loudness are tastes, not rules: they only rank.
    static func breaksTheRequest(_ s: SmartDJTrack, _ b: PlaylistBrief) -> Bool {
        let t = s.track, i = b.intent
        let genres = t.genres.map { $0.lowercased().replacingOccurrences(of: "-", with: " ") }
        func hits(_ want: String) -> Bool { let w = want.replacingOccurrences(of: "-", with: " "); return genres.contains { $0.contains(w) || w.contains($0) } }
        if i.avoidGenres.contains(where: hits) { return true }
        if !i.genres.isEmpty, !i.genres.contains(where: hits) { return true }
        if !i.artists.isEmpty {
            let names = (t.names(.artist) + t.names(.albumArtist)).map { $0.lowercased() }
            if !names.contains(where: { n in i.artists.contains { n.contains($0) || $0.contains(n) } }) { return true }
        }
        if i.onlyLiked, !t.isLiked { return true }
        if (!i.decades.isEmpty || i.years != nil), let y = t.year {
            let inDecade = i.decades.contains { y >= $0 && y < $0 + 10 }, inYears = i.years.map { $0.contains(y) } ?? false
            if !(inDecade || inYears) { return true }
        }
        if let lo = b.minDynamicRange, let dr = t.dr, dr < lo - 2 { return true }
        if let hi = b.maxDynamicRange, let dr = t.dr, dr > hi + 2 { return true }
        return false
    }

    static func rank(_ songs: [SmartDJTrack], brief: PlaylistBrief, semantic: [String: Float] = [:]) -> [PlaylistRanked] {
        var out = songs.filter { !breaksTheRequest($0, brief) }.map { PlaylistRanked(song: $0, score: PlaylistRelevance.score($0, brief: brief, semantic: semantic[$0.track.path])) }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.song.track.path < $1.song.track.path }
        return out
    }

    /// How many songs the playlist needs, given what the best of the library lasts.
    static func neededCount(brief: PlaylistBrief, ranked: [PlaylistRanked]) -> Int {
        if let n = brief.trackCount, brief.targetSeconds == nil { return max(1, n) }
        let top = ranked.prefix(60).map { $0.song.track.duration }.filter { $0 >= minimumSongSeconds }
        let avg = top.isEmpty ? 240 : top.reduce(0, +) / Double(top.count)
        let n = Int(((brief.targetSeconds ?? 0) / max(60, avg)).rounded(.up))
        return min(400, max(1, n))
    }

    /// The lowest score a song may have and still be a fit: 4.5 under the N-th best in the library, which tolerates a tempo or loudness that is a
    /// little off but not a song of the wrong genre, artist or decade.
    static func floorScore(ranked: [PlaylistRanked], needed: Int, brief: PlaylistBrief) -> Double {
        guard brief.hasConstraints || !brief.hintGenres.isEmpty, !ranked.isEmpty else { return -.infinity }
        return ranked[min(needed, ranked.count) - 1].score - 4.5
    }

    /// The best `limit` songs for the model to choose from: no artist takes over, and the order is shuffled so position says nothing.
    static func pool<R: RandomNumberGenerator>(_ ranked: [PlaylistRanked], limit: Int, floor: Double, using rng: inout R) -> [SmartDJCandidate] {
        let eligible = ranked.filter { $0.score >= floor && ($0.song.track.duration <= 0 || $0.song.track.duration >= minimumSongSeconds) }
        guard !eligible.isEmpty else { return [] }
        let tier = eligible.prefix(limit)
        let distinct = max(1, Set(tier.map { $0.song.artist.lowercased() }).count)
        let cap = max(3, Int((Double(limit) / Double(distinct)).rounded(.up)))
        var taken: [PlaylistRanked] = [], perArtist: [String: Int] = [:], used = Set<String>()
        for r in eligible {
            let a = r.song.artist.lowercased()
            if perArtist[a, default: 0] >= cap { continue }
            perArtist[a, default: 0] += 1; used.insert(r.song.track.path); taken.append(r)
            if taken.count >= limit { break }
        }
        if taken.count < min(limit, eligible.count) {
            for r in eligible where !used.contains(r.song.track.path) { taken.append(r); if taken.count >= limit { break } }
        }
        taken.shuffle(using: &rng)
        return taken.enumerated().map { SmartDJCandidate(id: $0.offset + 1, song: $0.element.song, score: $0.element.score) }
    }

    // MARK: selection and length

    private static func songKey(_ t: TrackDTO) -> String { LibraryStore.fold(t.title) + "|" + LibraryStore.fold(t.primaryArtistLine) }

    /// Walks `order` (best first) and takes songs until the playlist is long enough, with limits per artist and per album so no one fills it.
    static func select(order: [PlaylistRanked], brief: PlaylistBrief, floor: Double, needed: Int) -> [PlaylistRanked] {
        let artistCap = brief.intent.artists.isEmpty ? max(2, Int((Double(needed) / 6).rounded(.up))) : Int.max
        let albumCap = brief.intent.artists.isEmpty ? max(3, Int((Double(needed) / 4).rounded(.up))) : Int.max
        func pass(caps: Bool) -> [PlaylistRanked] {
            var out: [PlaylistRanked] = [], seconds = 0.0
            var perArtist: [String: Int] = [:], perAlbum: [String: Int] = [:], seen = Set<String>(), paths = Set<String>()
            for r in order where r.score >= floor {
                if let target = brief.targetSeconds { if seconds >= target { break } } else if out.count >= (brief.trackCount ?? needed) { break }
                let t = r.song.track
                if t.duration > 0 && t.duration < minimumSongSeconds { continue }
                guard paths.insert(t.path).inserted, seen.insert(songKey(t)).inserted else { continue }
                let a = r.song.artist.lowercased(), al = t.releaseID ?? t.releaseTitle ?? ""
                if caps {
                    if perArtist[a, default: 0] >= artistCap { continue }
                    if !al.isEmpty, perAlbum[al, default: 0] >= albumCap { continue }
                }
                perArtist[a, default: 0] += 1; if !al.isEmpty { perAlbum[al, default: 0] += 1 }
                out.append(r); seconds += max(0, t.duration)
            }
            return out
        }
        let first = pass(caps: true)
        let short: Bool = brief.targetSeconds.map { t in first.reduce(0) { $0 + max(0, $1.song.track.duration) } < t * 0.97 } ?? (first.count < (brief.trackCount ?? needed))
        return short ? pass(caps: false) : first
    }

    /// Brings a duration-targeted playlist as close to its length as the library allows by dropping or swapping the last song.
    static func fit(_ picks: [PlaylistRanked], target: Double, spare: [PlaylistRanked], floor: Double) -> [PlaylistRanked] {
        guard picks.count > 1 else { return picks }
        func total(_ p: [PlaylistRanked]) -> Double { p.reduce(0) { $0 + max(0, $1.song.track.duration) } }
        let tolerance = max(90, target * 0.02)
        let base = total(picks)
        if abs(base - target) <= tolerance { return picks }
        guard base > target else { return picks }                                  // the library ran out: nothing to trim
        let head = Array(picks.dropLast())
        var best = picks, bestGap = abs(base - target)
        func consider(_ c: [PlaylistRanked]) {
            let gap = abs(total(c) - target)
            if gap < bestGap - 1 { best = c; bestGap = gap }
        }
        consider(head)
        let used = Set(picks.map { $0.song.track.path }), keys = Set(picks.map { songKey($0.song.track) })
        for c in spare where c.score >= floor && !used.contains(c.song.track.path) && !keys.contains(songKey(c.song.track)) && c.song.track.duration >= minimumSongSeconds {
            consider(head + [c])
        }
        return best
    }

    // MARK: ordering

    private static func energyOf(_ s: SmartDJTrack) -> Double {
        if let e = s.energy { return e }
        if let b = s.bpm { return min(1, max(0, (b - 60) / 100)) }
        return 0.5
    }

    private static func keyCost(_ a: String?, _ b: String?) -> Double {
        func parse(_ s: String?) -> (Int, Bool)? {
            guard let s, let l = s.last, let n = Int(s.dropLast()) else { return nil }
            return (n, l == "A")
        }
        guard let x = parse(a), let y = parse(b) else { return 0.4 }
        let d = min((x.0 - y.0 + 12) % 12, (y.0 - x.0 + 12) % 12)
        let wheel = x.1 == y.1 ? d : (d == 0 ? 1 : d + 1)
        return Double(min(wheel, 4)) / 4
    }

    /// Lays the songs out along the energy arc, each step as smooth as possible in energy, tempo and key.
    static func order<R: RandomNumberGenerator>(_ songs: [SmartDJTrack], arc: PlaylistBrief.Arc, using rng: inout R) -> [SmartDJTrack] {
        guard songs.count > 2 else { return songs }
        let es = songs.map(energyOf)
        let lo = es.min() ?? 0, hi = es.max() ?? 1, span = max(hi - lo, 1e-6)
        let norm = es.map { ($0 - lo) / span }                                       // the playlist's own range, so a quiet one still has a shape
        func curve(_ p: Double) -> Double {
            switch arc {
            case .steady: 0.5
            case .windDown: 1 - p
            case .buildUp: p
            case .journey: 0.5 - 0.5 * cos(2 * Double.pi * p)
            }
        }
        let wShape = arc == .steady ? 0.25 : 1.0, wSmooth = arc == .steady ? 1.0 : 0.3
        var left = Array(songs.indices), out: [Int] = []
        out.reserveCapacity(songs.count)
        while !left.isEmpty {
            let p = songs.count > 1 ? Double(out.count) / Double(songs.count - 1) : 0
            let want = curve(p), prev = out.last
            var bestI = 0, bestCost = Double.infinity
            for (k, i) in left.enumerated() {
                var c = wShape * abs(norm[i] - want)
                if let q = prev {
                    c += wSmooth * abs(norm[i] - norm[q]) + 0.25 * keyCost(songs[q].key, songs[i].key)
                    if let b1 = songs[q].bpm, let b2 = songs[i].bpm { c += min(0.3, abs(b1 - b2) / 400) }
                }
                c += Double.random(in: 0..<0.02, using: &rng)
                if c < bestCost { bestCost = c; bestI = k }
            }
            out.append(left.remove(at: bestI))
        }
        return out.map { songs[$0] }
    }

    // MARK: names

    static func suggestedName(for request: String) -> String {
        var s = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = #"^(?:please\s+)?(?:can you\s+|could you\s+)?(?:create|make|build|give me|generate|compile|curate|play|i want|i need|queue)\s+(?:me\s+)?(?:an?\s+|the\s+|some\s+)?"#
        if let r = s.range(of: lead, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?"))
        if s.count > 48 {
            let cut = s.prefix(48)
            s = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
        }
        guard let f = s.first else { return "New mix" }
        return f.uppercased() + s.dropFirst()
    }

    // MARK: the whole pipeline

    /// Everything but the interface. `semantic` maps file paths to a similarity in 0…1 (empty when Semantic Search is not available).
    /// `backend` is nil for a ranking-only answer.
    static func compose<R: RandomNumberGenerator>(request: String, songs: [SmartDJTrack], backend: SmartDJBackend?, semantic: [String: Float],
                                                  maxTokens: Int = 260, rng: inout R) async -> PlaylistPlan {
        let started = Date()
        let vocab = LibraryVocabulary(tracks: songs.map(\.track))
        var brief = PlaylistBriefParser.parse(request, vocabulary: vocab)
        var notes: [String] = []
        var plan = PlaylistPlan(request: request, brief: brief, tracks: [], seconds: 0)
        guard !songs.isEmpty else { plan.notes = ["Your library is empty: add some music first."]; return plan }

        var usable: SmartDJBackend? = backend?.isLoaded == true ? backend : nil

        // 1. the model fills in what the words leave open
        if let b = usable {
            let genreList = Array(vocab.genres.sorted().prefix(80))
            let p = PlaylistModelPrompt.briefPrompt(request: request, genres: genreList)
            do {
                let text = try await b.generate(system: p.system, user: p.user, schema: p.schema, maxTokens: 120)
                if let r = PlaylistModelPrompt.parseRefinement(text) { PlaylistModelPrompt.merge(r, into: &brief, genres: vocab.genres) }
                else { notes.append("The language model's reading of the request could not be used; the words alone were used.") }
            } catch {
                notes.append("The language model failed (\(error.localizedDescription)) and the ranking answered alone.")
                usable = nil
            }
        }

        // 2. score everything that does not break the request
        let ranked = rank(songs, brief: brief, semantic: semantic)
        guard !ranked.isEmpty else {
            plan.brief = brief
            plan.notes = notes + ["Nothing in your library matches “\(brief.summary)”."]
            plan.elapsed = Date().timeIntervalSince(started)
            return plan
        }
        let needed = neededCount(brief: brief, ranked: ranked)
        let floor = floorScore(ranked: ranked, needed: needed, brief: brief)

        // 3. the model chooses among the best
        var modelRanked: [PlaylistRanked] = []
        if let b = usable {
            let candidates = pool(ranked, limit: 60, floor: floor, using: &rng)
            if !candidates.isEmpty {
                var intent = brief.intent
                intent.count = min(candidates.count, min(50, needed))
                let p = ContextBuilder.prompt(request: request, intent: intent, candidates: candidates)
                do {
                    let text = try await b.generate(system: PlaylistModelPrompt.pickSystem, user: p.user, schema: p.schema, maxTokens: maxTokens)
                    let ids = SmartDJSelection.parse(text, valid: Set(candidates.map(\.id)))
                    let o = SmartDJSelection.finalize(modelIDs: ids, candidates: candidates, count: intent.count, minScore: floor)
                    modelRanked = o.picks.prefix(o.fromModel).map { PlaylistRanked(song: $0.song, score: $0.score) }
                    plan.usedModel = !modelRanked.isEmpty
                    plan.modelPicked = modelRanked.count
                    if ids.isEmpty { notes.append("The language model's answer could not be used.") }
                    if o.rejected > 0 { notes.append("\(o.rejected) pick\(o.rejected == 1 ? "" : "s") from the model did not fit the request and \(o.rejected == 1 ? "was" : "were") replaced.") }
                } catch {
                    notes.append("The language model failed (\(error.localizedDescription)) and the ranking answered alone.")
                }
            }
        }

        // 4. select, fit the length, lay out along the arc
        let chosen = Set(modelRanked.map { $0.song.track.path })
        let order = modelRanked + ranked.filter { !chosen.contains($0.song.track.path) }
        var picks = select(order: order, brief: brief, floor: floor, needed: needed)
        if let target = brief.targetSeconds { picks = fit(picks, target: target, spare: order, floor: floor) }
        let arranged = Self.order(picks.map(\.song), arc: brief.arc, using: &rng)

        plan.brief = brief
        plan.tracks = arranged.map(\.track)
        plan.seconds = plan.tracks.reduce(0) { $0 + max(0, $1.duration) }
        plan.engine = plan.usedModel ? "model + ranking" : "ranking"

        // 5. say what is thin
        if let target = brief.targetSeconds, plan.seconds < target * 0.9 {
            notes.append("Only \(PlaylistBrief.formatDuration(plan.seconds)) of matching music was found for the \(PlaylistBrief.formatDuration(target)) asked for.")
        } else if brief.targetSeconds == nil, let n = brief.trackCount, plan.tracks.count < n, brief.hasConstraints {
            notes.append("Only \(plan.tracks.count) songs were found.")
        }
        let withEnergy = songs.filter { $0.energy != nil }.count
        if (brief.intent.energy != nil || brief.quiet || brief.arc != .steady), withEnergy * 4 < songs.count {
            notes.append("Only \(withEnergy) of \(songs.count) songs have a measured energy: analyse the library in the DJ browser for closer matches.")
        }
        if let lo = brief.minDynamicRange ?? brief.maxDynamicRange, lo > 0 {
            let withDR = songs.filter { $0.track.dr != nil }.count
            if withDR * 4 < songs.count { notes.append("Only \(withDR) of \(songs.count) songs have a measured dynamic range: run the loudness analysis to use it fully.") }
        }
        if !semantic.isEmpty { notes.append("Matched by meaning as well as by tags.") }
        plan.notes = notes + brief.notes
        plan.elapsed = Date().timeIntervalSince(started)
        return plan
    }
}

// MARK: - The questions put to the model

enum PlaylistModelPrompt {
    static let briefSystem = """
    You read a listener's request for a playlist and describe its mood as JSON. energy is low, medium, high or any. arc is how the energy moves: \
    steady, winding down, building up or rising and falling. acoustic is true only when the request asks for acoustic or unplugged music. \
    instrumental is true only when it asks for music without vocals. genres lists up to three genres from the allowed list that fit; use an empty list when none clearly fit. \
    Do not invent anything the request does not suggest.
    """

    static let pickSystem = """
    You are the DJ of a music player. You get a list of tracks as JSON (i = id, a = artist, t = title, g = genre, b = tempo in BPM, y = year, k = key, tags = descriptive words) \
    and a request for a playlist. Choose the tracks that best fit the whole request. Use only ids from the list and never repeat an id. Answer with JSON only: {"ids":[...]}
    """

    static func schema(genres: [String]) -> String {
        var props = #""energy":{"type":"string","enum":["low","medium","high","any"]},"arc":{"type":"string","enum":["steady","winding down","building up","rising and falling"]},"acoustic":{"type":"boolean"},"instrumental":{"type":"boolean"}"#
        var required = #""energy","arc","acoustic","instrumental""#
        if !genres.isEmpty, let d = try? JSONSerialization.data(withJSONObject: genres), let list = String(data: d, encoding: .utf8) {
            props += #","genres":{"type":"array","items":{"type":"string","enum":\#(list)},"maxItems":3}"#
            required += #","genres""#
        }
        return #"{"type":"object","properties":{\#(props)},"required":[\#(required)],"additionalProperties":false}"#
    }

    static func briefPrompt(request: String, genres: [String]) -> (system: String, user: String, schema: String) {
        let g = genres.isEmpty ? "" : "\nAllowed genres: " + genres.joined(separator: ", ")
        return (briefSystem, "Request: \(request.trimmingCharacters(in: .whitespacesAndNewlines))" + g, schema(genres: genres))
    }

    struct Refinement: Equatable {
        var energy: DJIntent.Energy?
        var arc: PlaylistBrief.Arc?
        var acoustic = false
        var instrumental = false
        var genres: [String] = []
    }

    /// Tolerates fences and prose around the JSON.
    static func parseRefinement(_ text: String) -> Refinement? {
        let bytes = Array(text.utf8)
        var spans: [Range<Int>] = [0..<bytes.count]
        if let a = bytes.firstIndex(of: UInt8(ascii: "{")), let b = bytes.lastIndex(of: UInt8(ascii: "}")), a < b { spans.append(a..<(b + 1)) }
        for s in spans {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(bytes[s]))) as? [String: Any] else { continue }
            var r = Refinement()
            switch (o["energy"] as? String)?.lowercased() {
            case "low": r.energy = .low
            case "medium": r.energy = .medium
            case "high": r.energy = .high
            default: break
            }
            switch (o["arc"] as? String)?.lowercased() {
            case "winding down": r.arc = .windDown
            case "building up": r.arc = .buildUp
            case "rising and falling": r.arc = .journey
            default: break
            }
            r.acoustic = o["acoustic"] as? Bool ?? false
            r.instrumental = o["instrumental"] as? Bool ?? false
            r.genres = ((o["genres"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }
            return r
        }
        return nil
    }

    /// The words win: the model only fills what the rules found nothing for, and its genres (used only for a request with no facts at all) must exist in the library and only nudge the ranking.
    static func merge(_ r: Refinement, into b: inout PlaylistBrief, genres: Set<String>) {
        let vague = !b.hasConstraints
        if b.intent.energy == nil, let e = r.energy {
            b.intent.energy = e
            if b.intent.bpm == nil {
                switch e {
                case .low: b.intent.bpm = 0...105
                case .high: b.intent.bpm = 110...400
                case .medium: b.intent.bpm = 90...130
                }
            }
            b.notes.append("The language model read this as \(e.rawValue) energy.")
        }
        if b.arc == .steady, let a = r.arc, a != .steady { b.arc = a }
        if vague {
            if r.acoustic { b.acoustic = true }
            if r.instrumental { b.instrumental = true }
        }
        if vague {
            b.hintGenres = r.genres.filter { genres.contains($0) }
        }
    }
}

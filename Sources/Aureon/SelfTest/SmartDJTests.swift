import Foundation
import Darwin

/// A language model stand-in that records how it is used.
final class FakeLLM: SmartDJBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _loaded = false
    private(set) var loads = 0, unloads = 0, generations = 0
    private(set) var lastUser = "", lastSchema = "", lastSystem = ""
    var loadDelay = 0.0
    var failLoad: String?
    var failGenerate: String?
    var generateDelay = 0.0
    /// Builds the answer from the schema's allowed ids; default: the first `count` ids in reverse order.
    var answer: (([Int], Int) -> String)?
    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return _loaded }

    func load(model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        lock.lock(); loads += 1; lock.unlock()
        progress(0.25, "Downloading the model")
        if loadDelay > 0 { try await Task.sleep(nanoseconds: UInt64(loadDelay * 1e9)) }
        if let f = failLoad { throw SmartDJError.failed(f) }
        lock.lock(); _loaded = true; lock.unlock()
        progress(1, "Loaded")
    }
    func generate(system: String, user: String, schema: String, maxTokens: Int) async throws -> String {
        lock.lock(); generations += 1; lastUser = user; lastSchema = schema; lastSystem = system; lock.unlock()
        if generateDelay > 0 { try await Task.sleep(nanoseconds: UInt64(generateDelay * 1e9)) }
        if let f = failGenerate { throw SmartDJError.failed(f) }
        let obj = (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) as? [String: Any]
        let ids = (((obj?["properties"] as? [String: Any])?["ids"] as? [String: Any])?["items"] as? [String: Any])?["enum"] as? [Int] ?? []
        let count = (((obj?["properties"] as? [String: Any])?["ids"] as? [String: Any])?["minItems"] as? Int) ?? 0
        if let a = answer { return a(ids, count) }
        return "{\"ids\":[\((ids.reversed().prefix(count)).map(String.init).joined(separator: ","))]}"
    }
    func unload() async { lock.lock(); unloads += 1; _loaded = false; lock.unlock() }
}

struct SmartDJTests {
    let dir = tempDir("smartdj")

    private func dto(_ n: Int, _ title: String, _ artist: String, _ genre: String, year: Int, liked: Bool = false) -> TrackDTO {
        var t = TrackDTO(id: "t\(n)", path: "/music/\(n).flac", title: title, trackNumber: nil, discNumber: nil, duration: 200, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2, year: year,
                         releaseID: nil, releaseTitle: "Album \(n % 10)", workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil,
                         credits: [CreditDTO(role: "artist", name: artist, instrument: nil, partyID: "p-\(artist)")], genres: [genre], mbRecordingID: nil)
        t.liked = liked ? true : nil
        return t
    }

    /// A made-up library: 600 songs over six genres, with tempos and energies that make sense for the genre.
    private func library(count: Int = 600) -> [SmartDJTrack] {
        var rng = SeededRNG(seed: 42)
        let spec: [(genre: String, artists: [String], bpm: ClosedRange<Double>, energy: ClosedRange<Double>)] = [
            ("Electronic", ["Daft Punk", "Prodigy", "Fatboy Slim", "Chemical Brothers", "Orbital"], 118...150, 0.6...0.95),
            ("Classical", ["Bach", "Mozart", "Beethoven", "Satie"], 50...90, 0.1...0.4),
            ("Jazz", ["Miles Davis", "Norah Jones", "Bill Evans"], 60...120, 0.2...0.55),
            ("Rock", ["Queen", "Nirvana", "Foo Fighters", "AC/DC"], 100...160, 0.5...0.9),
            ("Ambient", ["Brian Eno", "Stars of the Lid"], 40...80, 0.05...0.3),
            ("Hip-Hop", ["Kendrick Lamar", "Outkast", "Run the Jewels"], 80...110, 0.5...0.85),
        ]
        var out: [SmartDJTrack] = []
        for i in 0..<count {
            let s = spec[i % spec.count], artist = s.artists[(i / spec.count) % s.artists.count]
            let year = 1965 + Int.random(in: 0..<55, using: &rng)
            let t = dto(i, "\(s.genre) Song \(i)", artist, s.genre, year: year, liked: i % 17 == 0)
            out.append(SmartDJTrack(track: t, bpm: Double.random(in: s.bpm, using: &rng).rounded(), energy: Double.random(in: s.energy, using: &rng), key: "\(i % 12 + 1)\(i % 2 == 0 ? "A" : "B")"))
        }
        return out
    }

    private func vocab(_ lib: [SmartDJTrack]) -> LibraryVocabulary { LibraryVocabulary(tracks: lib.map(\.track)) }

    // MARK: reading the request

    func requestsAreUnderstood() {
        let v = LibraryVocabulary(genres: ["electronic", "jazz", "rock", "metal", "hip-hop", "classical", "indie", "ambient"], artists: ["daft punk", "miles davis", "queen"])
        func p(_ s: String) -> DJIntent { IntentParser.parse(s, vocabulary: v) }

        let a = p("Give me 10 upbeat electronic tracks for a workout")
        expect(a.count == 10 && a.genres == ["electronic"] && a.energy == .high && a.bpm == 120...185 && !a.moods.isEmpty && a.artists.isEmpty, "\(a)")
        let b = p("five calm jazz songs")
        expect(b.count == 5 && b.genres == ["jazz"] && b.energy == .low && b.bpm == 0...105, "\(b)")
        let c = p("a dozen songs from the 90s")
        expect(c.count == 12 && c.decades == [1990] && c.genres.isEmpty, "the decade is not mistaken for the count: \(c)")
        let d = p("80s rock without metal")
        expect(d.decades == [1980] && d.genres == ["rock"] && d.avoidGenres == ["metal"] && d.count == 10, "\(d)")
        let e = p("something by Daft Punk around 128 bpm")
        expect(e.artists == ["daft punk"] && e.bpm == 120...136 && e.count == 10, "\(e)")
        expect(p("my favourite songs").onlyLiked && p("play my liked tracks").onlyLiked)
        let f = p("indie from 2005-2010")
        expect(f.years == 2005...2010 && f.genres == ["indie"], "\(f)")
        let g = p("nineties hip hop")
        expect(g.decades == [1990] && g.genres == ["hip-hop"], "spaces and hyphens do not matter: \(g)")
        expect(p("play 100 songs").count == 50 && p("two tracks").count == 2 && p("the 1 song").count == 1)
        expect(p("sleep music").bpm == 0...85 && p("something slow").energy == .low)
        let h = p("asdf qwer")
        expect(!h.hasConstraints && h.count == 10, "an empty request asks for nothing in particular: \(h)")
        expect(p("a few songs by Queen").count == 5 && p("a few songs by Queen").artists == ["queen"])
        let i = p("lofi beats and bangers")
        expect(i.energy == .high, "\(i)")
        expect(!p("upbeat electronic tracks for a workout").summary.isEmpty && p("10 upbeat electronic tracks").summary.contains("10 tracks"))
        let l = p("jazz and electronic for a dinner party")
        expect(Set(l.genres) == ["jazz", "electronic"], "\(l)")
    }

    func rankingFavoursWhatWasAsked() {
        let lib = library()
        let v = vocab(lib)
        let intent = IntentParser.parse("10 upbeat electronic tracks for a workout", vocabulary: v)
        let scored = lib.map { (t: $0, s: Relevance.score($0, intent)) }.sorted { $0.s > $1.s }
        let top = scored.prefix(100)
        expect(top.allSatisfy { $0.t.track.genres == ["Electronic"] }, "the best hundred are all electronic")
        expect(scored.suffix(100).allSatisfy { $0.t.track.genres != ["Electronic"] }, "…and the worst hundred are not")
        var slowElectronic = lib.first { $0.track.genres == ["Electronic"] }!, fastElectronic = slowElectronic
        slowElectronic.bpm = 100; fastElectronic.bpm = 140
        expect(Relevance.score(fastElectronic, intent) > Relevance.score(slowElectronic, intent) + 2, "within the genre, faster wins for a workout")
        let byArtist = IntentParser.parse("Brian Eno", vocabulary: v)
        expect(lib.map { ($0, Relevance.score($0, byArtist)) }.max { $0.1 < $1.1 }!.0.track.names(.artist) == ["Brian Eno"])
        let ninetiesIntent = DJIntent(decades: [1990])
        let y90 = lib.first { ($0.year ?? 0) >= 1990 && ($0.year ?? 0) < 2000 }!, y70 = lib.first { ($0.year ?? 0) < 1980 }!
        expect(Relevance.score(y90, ninetiesIntent) > Relevance.score(y70, ninetiesIntent) + 3)
        let liked = DJIntent(onlyLiked: true)
        expect(Relevance.score(lib[0], liked) > Relevance.score(lib[1], liked) + 5, "only liked songs when asked")
        var avoid = DJIntent(); avoid.avoidGenres = ["rock"]
        expect(Relevance.score(lib.first { $0.track.genres == ["Rock"] }!, avoid) < -5)
    }

    // MARK: what the model sees

    func contextIsSmallAndRelevant() {
        let lib = library(count: 6000)
        let intent = IntentParser.parse("10 upbeat electronic tracks for a workout", vocabulary: vocab(lib))
        var r1 = SeededRNG(seed: 1), r2 = SeededRNG(seed: 1), r3 = SeededRNG(seed: 2)
        let c1 = ContextBuilder.candidates(from: lib, intent: intent, limit: 60, using: &r1), c2 = ContextBuilder.candidates(from: lib, intent: intent, limit: 60, using: &r2), c3 = ContextBuilder.candidates(from: lib, intent: intent, limit: 60, using: &r3)
        expect(c1.count == 60 && c1.map(\.id) == Array(1...60), "ids are 1…60")
        expect(c1 == c2 && c1.map(\.song.track.id) != c3.map(\.song.track.id), "the same seed gives the same list, another seed a different one")
        expect(c1.filter { $0.song.track.genres == ["Electronic"] }.count == 60, "only electronic songs are shown for an electronic request")
        var per: [String: Int] = [:]
        for c in c1 { per[c.song.artist, default: 0] += 1 }
        expect(per.count == 5 && (per.values.max() ?? 0) <= 12 && (per.values.min() ?? 0) >= 10, "the five electronic artists share the list evenly: \(per)")
        var rngOpen = SeededRNG(seed: 5)
        let open = ContextBuilder.candidates(from: lib, intent: DJIntent(), limit: 60, using: &rngOpen)
        var perOpen: [String: Int] = [:]
        for c in open { perOpen[c.song.artist, default: 0] += 1 }
        expect(open.count == 60 && (perOpen.values.max() ?? 0) <= 4 && perOpen.count >= 18, "an open request gets a varied list, no artist with more than four songs: \(perOpen.count) artists")
        expect(Set(c1.map(\.song.track.id)).count == 60, "no song twice")

        let json = ContextBuilder.json(c1)
        expect(json.count < 9_000, "60 songs fit in \(json.count) characters (about \(json.count / 4) tokens)")
        let rows = (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [[String: Any]]
        expect(rows.count == 60 && rows.allSatisfy { $0["i"] is Int && $0["a"] is String && $0["t"] is String && $0["g"] is String && $0["b"] is Int }, "every row has id, artist, title, genre and tempo")
        expect(rows.contains { ($0["tags"] as? [String])?.contains("fast") == true } && rows.contains { ($0["tags"] as? [String])?.contains("high-energy") == true }, "tags describe tempo and energy")
        expect(!json.contains("/music/") && !json.contains("t12"), "file paths and library ids never reach the model")

        let p = ContextBuilder.prompt(request: "10 upbeat electronic tracks for a workout", intent: intent, candidates: c1)
        let schema = (try! JSONSerialization.jsonObject(with: Data(p.schema.utf8))) as! [String: Any]
        let ids = (((schema["properties"] as! [String: Any])["ids"] as! [String: Any]))
        expect((ids["items"] as! [String: Any])["enum"] as! [Int] == Array(1...60) && ids["minItems"] as? Int == 10 && ids["maxItems"] as? Int == 10, "the answer must be exactly ten ids from the list")
        expect(p.user.contains("Request: 10 upbeat electronic tracks for a workout") && p.user.contains("Number of tracks to choose: 10") && p.user.contains(json), "the request and the tracks are in the prompt")
        expect(p.system.contains("{\"ids\":[...]}") && p.count == 10)
        // a request for more than there is
        let tiny = ContextBuilder.prompt(request: "x", intent: DJIntent(count: 50), candidates: Array(c1.prefix(7)))
        expect(tiny.count == 7 && tiny.schema.contains("\"minItems\":7"))
        // a library with no analysis at all still works
        let bare = lib.map { SmartDJTrack(track: $0.track) }
        let cb = ContextBuilder.candidates(from: bare, intent: DJIntent(), limit: 30, using: &r1)
        expect(cb.count == 30 && !ContextBuilder.json(cb).contains("\"b\":"), "without tempo data the field is simply absent")
        expect(ContextBuilder.candidates(from: [], intent: DJIntent(), limit: 30, using: &r1).isEmpty)
    }

    func answersAreCheckedAndRepaired() {
        let valid = Set(1...20)
        expect(SmartDJSelection.parse("{\"ids\":[3,1,2]}", valid: valid) == [3, 1, 2])
        expect(SmartDJSelection.parse("```json\n{\"ids\": [5, 6]}\n```", valid: valid) == [5, 6], "code fences")
        expect(SmartDJSelection.parse("Sure! Here you go: {\"ids\":[7,8,9]} Enjoy.", valid: valid) == [7, 8, 9], "prose around the JSON")
        expect(SmartDJSelection.parse("[4, 5, 6]", valid: valid) == [4, 5, 6], "a bare array")
        expect(SmartDJSelection.parse("{\"ids\":[\"2\", \"3\", 4.0]}", valid: valid) == [2, 3, 4], "numbers written as text")
        expect(SmartDJSelection.parse("{\"ids\":[1,1,2,99,-3,2,3]}", valid: valid) == [1, 2, 3], "duplicates and unknown ids are dropped")
        expect(SmartDJSelection.parse("{\"tracks\":[8,9]}", valid: valid) == [8, 9] && SmartDJSelection.parse("{\"playlist\":[10]}", valid: valid) == [10])
        expect(SmartDJSelection.parse("no json at all", valid: valid).isEmpty && SmartDJSelection.parse("", valid: valid).isEmpty && SmartDJSelection.parse("{\"ids\":", valid: valid).isEmpty)
        expect(SmartDJSelection.parse("{\"ids\":[99999999999999999999]}", valid: valid).isEmpty)

        func cand(_ id: Int, _ score: Double) -> SmartDJCandidate { SmartDJCandidate(id: id, song: SmartDJTrack(track: dto(id, "T\(id)", "A\(id)", "G", year: 2000)), score: score) }
        let cs = (1...12).map { cand($0, Double(20 - $0)) }                       // id 1 scores best
        var o = SmartDJSelection.finalize(modelIDs: [5, 3, 9], candidates: cs, count: 5, minScore: -10)
        expect(o.picks.map(\.id).prefix(3) == [5, 3, 9] && o.fromModel == 3 && o.filled == 2 && o.picks.count == 5, "the model's order is kept, the ranking completes the list: \(o)")
        expect(o.picks.map(\.id).suffix(2) == [1, 2], "the fillers are the best remaining")
        o = SmartDJSelection.finalize(modelIDs: [12, 11, 1], candidates: cs, count: 3, minScore: 10)
        expect(o.rejected == 2 && o.picks.map(\.id).first == 1 && o.picks.count == 3 && o.picks.allSatisfy { $0.score >= 10 }, "picks that do not fit are replaced: \(o)")
        o = SmartDJSelection.finalize(modelIDs: [], candidates: cs, count: 4, minScore: -.infinity)
        expect(o.picks.map(\.id) == [1, 2, 3, 4] && o.fromModel == 0, "no answer: the ranking alone")
        o = SmartDJSelection.finalize(modelIDs: [1, 2, 3, 4, 5, 6], candidates: cs, count: 3, minScore: -.infinity)
        expect(o.picks.count == 3, "never more than asked")
        o = SmartDJSelection.finalize(modelIDs: [1], candidates: Array(cs.prefix(2)), count: 5, minScore: -.infinity)
        expect(o.picks.count == 2, "never more than exist")
        let lib = library()
        let intent = IntentParser.parse("10 electronic tracks", vocabulary: vocab(lib))
        let ms = SmartDJSelection.minScore(library: lib, intent: intent)
        expect(ms > Relevance.score(lib.first { $0.track.genres == ["Classical"] }!, intent) && ms < Relevance.score(lib.first { $0.track.genres == ["Electronic"] }!, intent) + 1, "a classical piece is below the bar for an electronic request, an electronic one above: \(ms)")
        expect(SmartDJSelection.minScore(library: lib, intent: DJIntent()) == -.infinity, "no constraints, no bar")
    }

    func theWholePipeline() {
        let lib = library()
        let fake = FakeLLM()
        MainActor.assumeIsolated {}
        // the model is told to load by the service; here call the pipeline directly with a loaded backend
        _ = runAsync { try await fake.load(model: "m") { _, _ in } }
        var rng = SeededRNG(seed: 9)
        let r = try! runAsync { await SmartDJService.compose(request: "10 upbeat electronic tracks for a workout", songs: lib, backend: fake, candidateLimit: 60, maxTokens: 200, rng: &rng) }.get()
        expect(r.tracks.count == 10 && r.usedModel && r.modelPicked == 10 && r.rejected == 0, "\(r.tracks.count) tracks, \(r.modelPicked) from the model, \(r.rejected) rejected; minScore \(SmartDJSelection.minScore(library: lib, intent: r.intent)); top scores \(lib.map { Relevance.score($0, r.intent) }.sorted(by: >).prefix(12).map { String(format: "%.1f", $0) })")
        expect(r.tracks.allSatisfy { $0.genres == ["Electronic"] }, "all electronic")
        expect(Set(r.tracks.map(\.id)).count == 10 && r.intent.count == 10 && r.contextTracks == 60)
        expect(fake.lastUser.contains("Request: 10 upbeat electronic") && fake.generations == 1)

        // a model that chooses badly: classical pieces for a workout
        let classicalPicks = lib.enumerated().filter { $0.element.track.genres == ["Classical"] }.map(\.element)
        let bad = FakeLLM(); _ = runAsync { try await bad.load(model: "m") { _, _ in } }
        var rng2 = SeededRNG(seed: 10)
        // candidates only hold relevant songs, so a bad model cannot even see classical ones: its picks are ids of electronic songs in a poor order
        let r2 = try! runAsync { await SmartDJService.compose(request: "10 upbeat electronic tracks for a workout", songs: lib, backend: bad, candidateLimit: 60, maxTokens: 200, rng: &rng2) }.get()
        expect(r2.tracks.allSatisfy { $0.genres == ["Electronic"] } && !classicalPicks.isEmpty)

        // a library where few songs fit: the model is shown unrelated filler and picks it; those picks are replaced
        let few = lib.filter { $0.track.genres != ["Electronic"] } + lib.filter { $0.track.genres == ["Electronic"] }.prefix(12)
        let silly = FakeLLM(); _ = runAsync { try await silly.load(model: "m") { _, _ in } }
        silly.answer = { ids, count in
            // choose the LAST ids, which are the worst-ranked ones only by chance: force the check by picking every id twice over
            "{\"ids\":[\(ids.prefix(count).map(String.init).joined(separator: ","))]}"
        }
        var rng3 = SeededRNG(seed: 11)
        let r3 = try! runAsync { await SmartDJService.compose(request: "10 upbeat electronic tracks", songs: Array(few), backend: silly, candidateLimit: 60, maxTokens: 200, rng: &rng3) }.get()
        expect(r3.tracks.count == 10 && r3.tracks.filter { $0.genres == ["Electronic"] }.count == 10, "ten electronic songs although the model was shown others as well: \(r3.rejected) rejected, \(r3.filled) filled")

        // failures
        let broken = FakeLLM(); _ = runAsync { try await broken.load(model: "m") { _, _ in } }
        broken.failGenerate = "out of memory"
        var rng4 = SeededRNG(seed: 12)
        let r4 = try! runAsync { await SmartDJService.compose(request: "6 calm jazz songs", songs: lib, backend: broken, candidateLimit: 60, maxTokens: 200, rng: &rng4) }.get()
        expect(r4.tracks.count == 6 && !r4.usedModel && r4.note?.contains("out of memory") == true, "the ranking answers when the model fails: \(r4.note ?? "")")
        expect(r4.tracks.allSatisfy { $0.genres == ["Jazz"] })
        let junk = FakeLLM(); _ = runAsync { try await junk.load(model: "m") { _, _ in } }
        junk.answer = { _, _ in "I think you would like some music." }
        var rng5 = SeededRNG(seed: 13)
        let r5 = try! runAsync { await SmartDJService.compose(request: "6 calm jazz songs", songs: lib, backend: junk, candidateLimit: 60, maxTokens: 200, rng: &rng5) }.get()
        expect(r5.tracks.count == 6 && !r5.usedModel && r5.note?.contains("could not be used") == true)
        var rng6 = SeededRNG(seed: 14)
        let r6 = try! runAsync { await SmartDJService.compose(request: "anything", songs: [], backend: nil, candidateLimit: 60, maxTokens: 200, rng: &rng6) }.get()
        expect(r6.tracks.isEmpty && r6.note?.contains("empty") == true)
        let r7 = try! runAsync { await SmartDJService.compose(request: "20 songs", songs: Array(lib.prefix(5)), backend: nil, candidateLimit: 60, maxTokens: 200, rng: &rng6) }.get()
        expect(r7.tracks.count == 5 && r7.intent.count == 5, "asking for more than the library has gives what there is")
        let noTempo = lib.map { SmartDJTrack(track: $0.track) }
        let r8 = try! runAsync { await SmartDJService.compose(request: "10 upbeat tracks", songs: noTempo, backend: nil, candidateLimit: 60, maxTokens: 200, rng: &rng6) }.get()
        expect(r8.tracks.count == 10 && r8.note?.contains("tempo") == true, "a library without tempo data is told how to improve: \(r8.note ?? "")")
    }
}

// MARK: - the service and the helper process

extension SmartDJTests {
    @MainActor private func spin(_ timeout: Double = 8, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    func modelLivesOnlyWhileSwitchedOn() {
        MainActor.assumeIsolated {
            let lib = library()
            var made: [FakeLLM] = []
            let s = SmartDJService()
            s.library = { lib }
            s.rng = { 77 }
            s.makeBackend = { let f = FakeLLM(); f.loadDelay = 0.15; made.append(f); return f }
            expect(s.state == .off && made.isEmpty, "nothing is created, let alone loaded, until Smart DJ is switched on")
            s.enable()
            expect({ if case .loading = s.state { return true }; return false }(), "loading right away: \(s.state)")
            s.enable()
            spin { s.state == .ready }
            expect(s.state == .ready && s.modelActive && s.modelProblem == nil && made.count == 1 && made[0].loads == 1 && made[0].isLoaded, "loaded once: \(s.state)")
            // asking
            Task { await s.suggest("10 upbeat electronic tracks for a workout") }
            spin { s.suggestion != nil }
            expect(s.suggestion?.tracks.count == 10 && s.suggestion?.usedModel == true && s.state == .ready && made[0].generations == 1, "an answer from the model: \(String(describing: s.suggestion?.note))")
            expect(s.history.count == 1)
            Task { await s.suggest("   ") }
            spin(0.2) { false }
            expect(made[0].generations == 1, "an empty request asks nothing")

            // switching off unloads, really
            Task { await s.disableAndWait() }
            spin { made[0].unloads >= 1 && s.state == .off }
            expect(s.state == .off && !made[0].isLoaded && made[0].unloads == 1 && !s.modelActive, "unloaded: \(made[0].unloads) times, loaded \(made[0].isLoaded)")
            Task { await s.suggest("anything") }
            spin(0.2) { false }
            expect(made[0].generations == 1, "while it is off nothing is asked")

            // and on again: a fresh model
            s.enable()
            spin { s.state == .ready }
            expect(made.count == 2 && made[1].loads == 1 && made[1].isLoaded, "switching on again starts a new model")
            s.disable(); s.disable()
            spin { made[1].unloads >= 1 }
            spin(0.3) { false }
            expect(made[1].unloads == 1 && s.state == .off, "switching off twice unloads once")

            // off while it is still loading
            s.enable()
            spin(0.05) { false }
            s.disable()
            spin { made.count == 3 && made[2].unloads >= 1 }
            spin(0.3) { false }
            expect(s.state == .off && !made[2].isLoaded && made[2].unloads >= 1, "switching off during the load leaves nothing running (loads \(made[2].loads), unloads \(made[2].unloads))")

            // off while thinking: the answer is dropped
            s.enable(); spin { s.state == .ready }
            let before = s.history.count
            made.last!.generateDelay = 0.4
            Task { await s.suggest("10 electronic tracks") }
            spin(0.1) { s.state == .thinking }
            expect(s.state == .thinking)
            s.disable()
            spin(0.8) { false }
            expect(s.state == .off && s.history.count == before, "an answer that arrives after switching off is discarded")
            Task { await s.disableAndWait() }
            spin { true }
        }
    }

    func withoutAModelTheRankingStillAnswers() {
        MainActor.assumeIsolated {
            let lib = library()
            let s = SmartDJService()
            s.library = { lib }; s.rng = { 5 }
            s.makeBackend = { nil }
            s.enable()
            spin { s.state == .ready }
            expect(s.state == .ready && !s.modelActive && s.modelProblem?.contains("not installed") == true, "\(s.state) \(s.modelProblem ?? "")")
            Task { await s.suggest("6 calm jazz songs") }
            spin { s.suggestion != nil }
            expect(s.suggestion?.tracks.count == 6 && s.suggestion?.usedModel == false && s.suggestion?.tracks.allSatisfy { $0.genres == ["Jazz"] } == true)
            Task { await s.disableAndWait() }
            spin { s.state == .off }

            let failing = SmartDJService()
            failing.library = { lib }
            let f = FakeLLM(); f.failLoad = "no network"
            failing.makeBackend = { f }
            failing.enable()
            spin { failing.state == .ready }
            expect(failing.state == .ready && !failing.modelActive && failing.modelProblem?.contains("no network") == true && f.unloads >= 1 && !f.isLoaded, "a model that cannot start is cleaned up and the ranking takes over: \(failing.modelProblem ?? "")")
            Task { await failing.suggest("5 rock songs") }
            spin { failing.suggestion != nil }
            expect(failing.suggestion?.tracks.count == 5 && failing.suggestion?.usedModel == false)
            Task { await failing.disableAndWait() }
            spin { failing.state == .off }
        }
    }

    // MARK: the helper program

    private func script(_ name: String, _ body: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try! ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static let loop = """
    while IFS= read -r line; do
      case "$line" in
        *'"op":"ping"'*) echo '{"event":"pong"}';;
        *'"op":"load"'*) echo '{"event":"progress","fraction":0.5,"message":"Downloading the model"}'; sleep 0.1; echo '{"event":"loaded","seconds":0.1}';;
        *'"op":"generate"'*) id=$(printf '%s' "$line" | sed 's/.*"id":\\([0-9]*\\).*/\\1/'); @@GEN@@;;
        *'"op":"unload"'*) echo '{"event":"unloaded"}'; exit 0;;
      esac
    done
    """

    private func loop(_ gen: String) -> String { Self.loop.replacingOccurrences(of: "@@GEN@@", with: gen) }

    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func theHelperProcessFollowsTheProtocol() {
        let ok = script("helper-ok.sh", loop("echo \"{\\\"event\\\":\\\"result\\\",\\\"id\\\":$id,\\\"text\\\":\\\"{\\\\\\\"ids\\\\\\\":[3,1,2]}\\\",\\\"tokens\\\":9}\""))
        let b = HelperProcessBackend(executable: ok)
        expect(!b.isLoaded && b.processID == nil)
        var seen: [Double] = []
        let lock = NSLock()
        try! runAsync { try await b.load(model: "m") { f, _ in lock.lock(); seen.append(f); lock.unlock() } }.get()
        expect(b.isLoaded && b.launches == 1 && (b.processID.map(alive) ?? false), "the helper is running once the model is loaded")
        lock.lock(); let progress = seen; lock.unlock()
        expect(progress.contains(0.5), "download progress is passed on: \(progress)")
        let text = try! runAsync { try await b.generate(system: "s", user: "u", schema: "{\"type\":\"object\"}", maxTokens: 50) }.get()
        expect(SmartDJSelection.parse(text, valid: Set(1...5)) == [3, 1, 2], text)
        let again = try! runAsync { try await b.generate(system: "s", user: "u2", schema: "{}", maxTokens: 50) }.get()
        expect(!again.isEmpty, "requests are matched to their answers")
        let pid = b.processID!
        _ = runAsync { await b.unload() }
        Thread.sleep(forTimeInterval: 0.2)
        expect(!alive(pid) && !b.isLoaded && b.processID == nil, "after unloading the process is gone")
        _ = runAsync { await b.unload() }   // twice is fine
        if case .failure = runAsync({ try await b.generate(system: "", user: "", schema: "{}", maxTokens: 5) }) {} else { expect(false, "nothing can be asked of an unloaded model") }
        // it can be started again
        try! runAsync { try await b.load(model: "m") { _, _ in } }.get()
        expect(b.launches == 2 && b.isLoaded)
        let pid2 = b.processID!
        _ = runAsync { await b.unload() }
        Thread.sleep(forTimeInterval: 0.2)
        expect(!alive(pid2))
    }

    func theHelperProcessMisbehaves() {
        // crashes while answering
        let crash = script("helper-crash.sh", loop("exit 3"))
        let c = HelperProcessBackend(executable: crash)
        try! runAsync { try await c.load(model: "m") { _, _ in } }.get()
        if case .failure(let e) = runAsync({ try await c.generate(system: "", user: "", schema: "{}", maxTokens: 5) }) { expect(e.localizedDescription.contains("stopped"), e.localizedDescription) } else { expect(false, "a crash must surface as an error") }
        Thread.sleep(forTimeInterval: 0.2)
        expect(!c.isLoaded && c.processID == nil, "and the backend knows the model is gone")

        // hangs while answering: the timeout ends it
        let hang = script("helper-hang.sh", loop("sleep 30"))
        let h = HelperProcessBackend(executable: hang); h.generateTimeout = 0.6
        try! runAsync { try await h.load(model: "m") { _, _ in } }.get()
        let pid = h.processID!
        let t0 = Date()
        if case .failure(let e) = runAsync({ try await h.generate(system: "", user: "", schema: "{}", maxTokens: 5) }) { expect(e.localizedDescription.contains("too long"), e.localizedDescription) } else { expect(false, "should time out") }
        expect(Date().timeIntervalSince(t0) < 3, "gave up after the timeout")
        Thread.sleep(forTimeInterval: 0.4)
        expect(!alive(pid), "a stuck model is killed, not left running")

        // refuses to load
        let refuse = script("helper-refuse.sh", "while IFS= read -r line; do echo '{\"event\":\"error\",\"message\":\"Could not load the model: offline\"}'; done\n")
        let r = HelperProcessBackend(executable: refuse)
        if case .failure(let e) = runAsync({ try await r.load(model: "m") { _, _ in } }) { expect(e.localizedDescription.contains("offline"), e.localizedDescription) } else { expect(false, "load error") }
        expect(!r.isLoaded && r.processID == nil, "a failed load leaves no process behind")

        // a helper that ignores "unload" is terminated
        let deaf = script("helper-deaf.sh", "while IFS= read -r line; do case \"$line\" in *'\"op\":\"load\"'*) echo '{\"event\":\"loaded\"}';; esac; done\n")
        let d = HelperProcessBackend(executable: deaf); d.quitGrace = 0.3
        try! runAsync { try await d.load(model: "m") { _, _ in } }.get()
        let dpid = d.processID!
        _ = runAsync { await d.unload() }
        Thread.sleep(forTimeInterval: 0.2)
        expect(!alive(dpid), "unloading always ends the process")

        // missing or not runnable
        let missing = HelperProcessBackend(executable: dir.appendingPathComponent("nope"))
        if case .failure = runAsync({ try await missing.load(model: "m") { _, _ in } }) {} else { expect(false, "a missing helper must fail") }
        expect(SmartDJHelperLocator.find(environment: ["AUREON_SMARTDJ_HELPER": ok(dir)], bundle: Bundle(for: FakeAnchor.self), cwd: "/nonexistent") != nil, "the locator honours the override")
        expect(SmartDJHelperLocator.find(environment: [:], bundle: Bundle(for: FakeAnchor.self), cwd: "/nonexistent") == nil, "and finds nothing otherwise")
    }

    private func ok(_ d: URL) -> String { d.appendingPathComponent("helper-ok.sh").path }

    func theServiceDrivesTheHelperProcess() {
        MainActor.assumeIsolated {
            let lib = library()
            let ok = script("helper-svc.sh", loop("echo \"{\\\"event\\\":\\\"result\\\",\\\"id\\\":$id,\\\"text\\\":\\\"{\\\\\\\"ids\\\\\\\":[1,2,3,4,5,6]}\\\",\\\"tokens\\\":9}\""))
            var backend: HelperProcessBackend?
            let s = SmartDJService()
            s.library = { lib }; s.rng = { 3 }
            s.makeBackend = { let b = HelperProcessBackend(executable: ok); backend = b; return b }
            s.enable()
            spin { s.state == .ready }
            expect(s.modelActive && backend?.isLoaded == true, "\(s.state) \(s.modelProblem ?? "")")
            let pid = backend?.processID
            expect(pid.map(alive) == true)
            Task { await s.suggest("6 calm jazz songs") }
            spin { s.suggestion != nil }
            expect(s.suggestion?.tracks.count == 6 && s.suggestion?.usedModel == true && s.suggestion?.tracks.allSatisfy { $0.genres == ["Jazz"] } == true, "\(String(describing: s.suggestion?.note))")
            Task { await s.disableAndWait() }
            spin { s.state == .off }
            spin(1) { pid.map { !alive($0) } ?? true }
            expect(s.state == .off && pid.map({ !alive($0) }) == true, "switching Smart DJ off ends the helper process")
        }
    }
}

private final class FakeAnchor {}

extension SmartDJTests {
    /// The real thing: the actual language model, started and stopped through the service. Runs only where the helper has been built and
    /// the model is already on disk (it never downloads in a test); otherwise it says so and passes nothing it did not check.
    func theRealModelPicksTracks() {
        guard let helper = SmartDJHelperLocator.find() else { print("      (skipped: the Smart DJ helper is not built; see Packages/SmartDJHelper)"); return }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub/models--mlx-community--Qwen2.5-0.5B-Instruct-4bit")
        guard FileManager.default.fileExists(atPath: cache.path) else { print("      (skipped: the model is not downloaded yet)"); return }
        MainActor.assumeIsolated {
            let lib = library()
            var backend: HelperProcessBackend?
            let s = SmartDJService()
            s.library = { lib }; s.rng = { 21 }
            s.makeBackend = { let b = HelperProcessBackend(executable: helper); backend = b; return b }
            let t0 = Date()
            s.enable()
            spin(120) { s.state == .ready }
            expect(s.state == .ready && s.modelActive, "the model started in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(s.modelProblem ?? "")")
            guard let pid = backend?.processID else { return }
            func rssMB() -> Double {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "rss=", "-p", "\(pid)"]
                let out = Pipe(); p.standardOutput = out; try? p.run(); p.waitUntilExit()
                return (Double(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
            }
            let loadedMB = rssMB()
            expect(loadedMB > 150, "the model is really in memory while on: \(Int(loadedMB)) MB")
            for (request, genre) in [("10 upbeat electronic tracks for a workout", "Electronic"), ("six calm classical pieces to study", "Classical"), ("8 hip hop songs", "Hip-Hop")] {
                Task { await s.suggest(request) }
                spin(60) { s.suggestion?.request == request }
                let r = s.suggestion
                let want = request.hasPrefix("six") ? 6 : (request.hasPrefix("8") ? 8 : 10)
                expect(r?.request == request && r?.tracks.count == want, "\(request): \(r?.tracks.count ?? -1) tracks")
                expect(r?.usedModel == true && (r?.modelPicked ?? 0) > 0, "\(request): the model made picks (\(r?.modelPicked ?? 0) kept, \(r?.rejected ?? 0) rejected, \(r?.filled ?? 0) filled) in \(String(format: "%.1f", r?.seconds ?? 0)) s")
                expect(r?.tracks.allSatisfy { $0.genres == [genre] } == true, "\(request): every track is \(genre)")
                expect(Set(r?.tracks.map(\.id) ?? []).count == want, "\(request): no repeats")
            }
            Task { await s.disableAndWait() }
            spin(10) { s.state == .off }
            spin(5) { kill(pid, 0) != 0 }
            expect(kill(pid, 0) != 0, "switching off ended the process and returned its \(Int(loadedMB)) MB")
        }
    }
}

extension SmartDJTests {
    func aSetLandsOnTheDecks() {
        MainActor.assumeIsolated {
            let m = DJModel()
            m.outputFactory = { core in let p = PullOutput(core: core, speed: 1); p.keep = false; return p }
            var o = PlayerOptions(); o.bufferSeconds = 0.25
            m.enter(options: o, rate: 48_000)
            defer { m.exit() }
            let tracks = (0..<3).map { i in DJTrack(path: sineWAV(dir.appendingPathComponent("set\(i).wav"), rate: 48_000, freq: 300 + Double(i) * 100, amp: 0.3, seconds: 2).path, title: "S\(i)", artist: "") }
            m.loadSet(tracks)
            expect(m.a.track?.title == "S0" && m.b.track?.title == "S1" && m.crossfader == -1 && m.setNext == 2, "track 1 on deck A, track 2 on deck B")
            expect(!m.a.playing && !m.b.playing, "nothing plays until the DJ says so")
            spin(8) { m.a.duration > 0 }
            m.startSet()
            spin(6) { m.tick(); return m.a.playing }
            expect(m.a.playing, "Start set plays deck A")
            // when A has finished, the third track takes its place
            spin(12) { m.tick(); return m.a.track?.title == "S2" }
            expect(m.a.track?.title == "S2" && m.setNext == 3, "the next song of the set is loaded on the deck that finished: \(String(describing: m.a.track?.title))")
        }
    }
}

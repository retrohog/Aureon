import Foundation
import Synchronization

/// A language model stand-in: answers the two kinds of question (the mood of the request, the choice of songs) from closures, and counts what happens to it.
final class ScriptedPlaylistModel: SmartDJBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private(set) var loads = 0, unloads = 0, briefCalls = 0, pickCalls = 0
    var brief = #"{"energy":"any","arc":"steady","acoustic":false,"instrumental":false,"genres":[]}"#
    /// Which of the offered ids to answer with.
    var choose: ([Int]) -> [Int] = { Array($0) }
    var failOn: Set<String> = []                      // "brief", "pick"
    var rawPick: String?                              // replaces the pick answer (to test unusable answers)

    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded }
    func load(model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        progress(0.5, "Loading the model"); progress(1, "Loaded")
        lock.lock(); loaded = true; loads += 1; lock.unlock()
    }
    func generate(system: String, user: String, schema: String, maxTokens: Int) async throws -> String {
        let isBrief = schema.contains("\"acoustic\"")
        lock.lock(); if isBrief { briefCalls += 1 } else { pickCalls += 1 }; lock.unlock()
        if failOn.contains(isBrief ? "brief" : "pick") { throw SmartDJError.failed("boom") }
        if isBrief { return brief }
        if let rawPick { return rawPick }
        let o = (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) as? [String: Any]
        let ids = ((((o?["properties"] as? [String: Any])?["ids"] as? [String: Any])?["items"] as? [String: Any])?["enum"] as? [Int]) ?? []
        let n = (((o?["properties"] as? [String: Any])?["ids"] as? [String: Any])?["minItems"] as? Int) ?? ids.count
        return "{\"ids\":[\(choose(ids).prefix(n).map(String.init).joined(separator: ","))]}"
    }
    func unload() async { lock.lock(); loaded = false; unloads += 1; lock.unlock() }
}

struct NaturalPlaylistTests {
    let dir = tempDir("naturalplaylist")

    // MARK: fixtures

    private func dto(_ n: Int, _ title: String, _ artist: String, _ genre: String, duration: Double = 210, year: Int = 2001, dr: Double? = nil, lufs: Double? = nil) -> TrackDTO {
        var t = TrackDTO(id: "t\(n)", path: "/music/\(n).flac", title: title, trackNumber: nil, discNumber: nil, duration: duration, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2, year: year,
                         releaseID: "r\(n / 9)", releaseTitle: "Album \(n / 9)", workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil,
                         credits: [CreditDTO(role: "artist", name: artist, instrument: nil, partyID: "p-\(artist)")], genres: [genre], mbRecordingID: nil)
        t.dr = dr; t.lufs = lufs
        return t
    }

    /// 300 songs in five families: quiet folk (0), loud rock (1), energetic electronic (2), mid jazz (3), quiet classical (4).
    private func library(_ n: Int = 300) -> [SmartDJTrack] {
        (0..<n).map { i in
            let fam = i % 5, artist = "Artist \(i % 23)"
            switch fam {
            case 0: return SmartDJTrack(track: dto(i, "Folk \(i)", artist, "Folk", duration: 190 + Double(i % 50), dr: 13, lufs: -20), bpm: 70 + Double(i % 20), energy: 0.12 + Double(i % 7) * 0.03, key: "\(1 + i % 12)A")
            case 1: return SmartDJTrack(track: dto(i, "Rock \(i)", artist, "Rock", dr: 6, lufs: -8), bpm: 140, energy: 0.85, key: "\(1 + i % 12)B")
            case 2: return SmartDJTrack(track: dto(i, "Beat \(i)", artist, "Electronic", dr: 7, lufs: -9), bpm: 128, energy: 0.9, key: "\(1 + i % 12)A")
            case 3: return SmartDJTrack(track: dto(i, "Jazz \(i)", artist, "Jazz", dr: 12, lufs: -17), bpm: 95, energy: 0.35, key: "\(1 + i % 12)B")
            default: return SmartDJTrack(track: dto(i, "Sonata \(i)", artist, "Classical", duration: 300, dr: 15, lufs: -24), bpm: 60, energy: 0.06 + Double(i % 9) * 0.02, key: "\(1 + i % 12)A")
            }
        }
    }

    private func vocab(_ songs: [SmartDJTrack]) -> LibraryVocabulary { LibraryVocabulary(tracks: songs.map(\.track)) }

    private func compose(_ request: String, _ songs: [SmartDJTrack], model: SmartDJBackend? = nil, semantic: [String: Float] = [:], seed: UInt64 = 7) -> PlaylistPlan {
        let r = runAsync(timeout: 60) { () -> PlaylistPlan in
            var g = SeededRNG(seed: seed)
            return await PlaylistEngine.compose(request: request, songs: songs, backend: model, semantic: semantic, rng: &g)
        }
        if case .success(let p) = r { return p }
        expect(false, "compose failed: \(r)")
        return PlaylistPlan(request: request, brief: PlaylistBrief(request: request), tracks: [], seconds: 0)
    }

    @MainActor private func wait(_ timeout: Double = 8, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: reading the request

    func lengthsAreRead() {
        func secs(_ s: String) -> Double? { PlaylistBriefParser.extractDuration(from: " " + s.lowercased() + " ")?.seconds }
        expect(secs("a 2-hour mix") == 7200, "2-hour")
        expect(secs("an hour and a half of jazz") == 5400, "an hour and a half")
        expect(secs("two and a half hours of rock") == 9000, "two and a half hours")
        expect(secs("half an hour of calm") == 1800, "half an hour")
        expect(secs("2 hours 30 minutes") == 9000, "2 hours 30 minutes")
        expect(secs("1h30 of focus") == 5400, "1h30")
        expect(secs("45 minutes of funk") == 2700, "45 minutes")
        expect(secs("one hour of piano") == 3600, "one hour")
        expect(secs("1 hour, 30 songs") == 3600, "the 30 is a number of songs, not minutes: \(String(describing: secs("1 hour, 30 songs")))")
        expect(secs("20 songs of jazz") == nil && secs("the 80s") == nil, "no length where none is named")
        let rest = PlaylistBriefParser.extractDuration(from: " a 2-hour mix of jazz ")?.rest ?? ""
        expect(!rest.contains("2") && !rest.contains("hour") && rest.contains("jazz"), "the length is taken out of the text: \(rest)")
    }

    func theHeadlineRequestBecomesHardFacts() {
        let songs = library()
        let b = PlaylistBriefParser.parse("Create a 2-hour mix of late-night, low-energy acoustic tracks with high dynamic range", vocabulary: vocab(songs))
        expect(b.targetSeconds == 7200 && b.trackCount == nil, "length: \(String(describing: b.targetSeconds)), \(String(describing: b.trackCount))")
        expect(b.intent.energy == .low && b.quiet && b.acoustic && b.arc == .windDown, "mood: \(b)")
        expect(b.minDynamicRange == 11 && b.maxDynamicRange == nil, "dynamic range: \(String(describing: b.minDynamicRange))")
        expect((b.intent.bpm?.upperBound ?? 999) <= 105, "a slow ceiling: \(String(describing: b.intent.bpm))")
        expect(!b.intent.keywords.contains("create") && !b.intent.keywords.contains("acoustic") && !b.intent.keywords.contains("dynamic"), "no filler words left as title keywords: \(b.intent.keywords)")
        expect(b.summary.contains("2 h") && b.summary.contains("acoustic") && b.summary.contains("DR ≥ 11"), b.summary)
    }

    func otherRequestsAreRead() {
        let songs = library()
        let v = vocab(songs)
        let run = PlaylistBriefParser.parse("45 minutes of upbeat 80s tracks for a run", vocabulary: v)
        expect(run.targetSeconds == 2700 && run.intent.energy == .high && run.intent.decades == [1980], "run: \(run)")
        let jazz = PlaylistBriefParser.parse("20 jazz songs", vocabulary: v)
        expect(jazz.trackCount == 20 && jazz.targetSeconds == nil && jazz.intent.genres == ["jazz"], "jazz: \(jazz)")
        let hourAndSongs = PlaylistBriefParser.parse("1 hour, 30 songs of folk", vocabulary: v)
        expect(hourAndSongs.targetSeconds == 3600 && hourAndSongs.trackCount == 30, "both: \(hourAndSongs)")
        let dr = PlaylistBriefParser.parse("DR14 folk", vocabulary: v)
        expect(dr.minDynamicRange == 14 && dr.intent.genres == ["folk"], "DR14: \(dr)")
        let loud = PlaylistBriefParser.parse("low dynamic range rock", vocabulary: v)
        expect(loud.maxDynamicRange == 7 && loud.minDynamicRange == nil, "low dynamic range: \(loud)")
        let plain = PlaylistBriefParser.parse("some jazz", vocabulary: v)
        expect(plain.trackCount == PlaylistBrief.defaultTrackCount && plain.targetSeconds == nil && !plain.quiet && plain.arc == .steady, "defaults: \(plain)")
        let instr = PlaylistBriefParser.parse("instrumental music, building up", vocabulary: v)
        expect(instr.instrumental && instr.arc == .buildUp, "instrumental: \(instr)")
        let noRock = PlaylistBriefParser.parse("a mix without rock", vocabulary: v)
        expect(noRock.intent.avoidGenres == ["rock"] && noRock.intent.genres.isEmpty, "avoid: \(noRock.intent)")
    }

    // MARK: choosing

    func rankingPrefersTheRightRecordings() {
        let songs = library()
        let b = PlaylistBriefParser.parse("late-night low-energy acoustic tracks with high dynamic range", vocabulary: vocab(songs))
        let ranked = PlaylistEngine.rank(songs, brief: b)
        let top = ranked.prefix(40)
        expect(top.allSatisfy { ($0.song.energy ?? 1) <= 0.4 && ($0.song.track.dr ?? 0) >= 11 && ["Folk", "Classical", "Jazz"].contains($0.song.track.genres[0]) }, "the top is quiet, dynamic and acoustic: \(top.prefix(5).map { $0.song.track.title })")
        expect(ranked.prefix(120).first(where: { $0.song.track.genres[0] == "Folk" }) != nil, "folk is among the best 120")
        expect(ranked.count == 180 && !ranked.contains { ["Rock", "Electronic"].contains($0.song.track.genres[0]) }, "squashed recordings (DR 6 and 7) are out of the running: \(ranked.count)")
        // a measured DR counts: a song a little under the asked-for DR falls behind its dynamic twin, and one far under is out
        var close = songs[0]; close.track.dr = 10
        var twin = songs[0]; twin.track.path = "/music/twin.flac"; twin.track.dr = 14
        var squashed = songs[0]; squashed.track.path = "/music/squashed.flac"; squashed.track.dr = 5
        let r = PlaylistEngine.rank([close, twin, squashed], brief: b)
        expect(r.count == 2 && r[0].song.track.path == "/music/twin.flac", "high dynamic range wins: \(r.map { $0.song.track.path })")
    }

    func theLengthIsFitAndTheArcFollowed() {
        let songs = library()
        let plan = compose("Create a 2-hour mix of late-night, low-energy acoustic tracks with high dynamic range", songs)
        let target = 7200.0
        expect(abs(plan.seconds - target) <= max(150, target * 0.02), "two hours, give or take: \(PlaylistBrief.formatDuration(plan.seconds)) in \(plan.tracks.count) songs")
        expect(!plan.usedModel && plan.engine == "ranking", "no model: ranking alone")
        expect(plan.tracks.allSatisfy { !["Rock", "Electronic"].contains($0.genres[0]) && ($0.dr ?? 0) >= 11 }, "every song fits")
        expect(Set(plan.tracks.map(\.path)).count == plan.tracks.count && Set(plan.tracks.map(\.title)).count == plan.tracks.count, "no song twice")
        let perArtist = Dictionary(grouping: plan.tracks, by: { $0.primaryArtistLine }).mapValues(\.count)
        expect((perArtist.values.max() ?? 0) <= Int((Double(plan.tracks.count) / 6).rounded(.up)) + 1, "no artist takes over: \(perArtist.values.max() ?? 0) of \(plan.tracks.count)")
        // winding down: the first third is louder than the last
        let e: [String: Double] = Dictionary(uniqueKeysWithValues: songs.map { ($0.track.path, $0.energy ?? 0.5) })
        let third = max(1, plan.tracks.count / 3)
        let head = plan.tracks.prefix(third).map { e[$0.path] ?? 0 }.reduce(0, +) / Double(third)
        let tail = plan.tracks.suffix(third).map { e[$0.path] ?? 0 }.reduce(0, +) / Double(third)
        expect(head > tail, "winding down: \(head) → \(tail)")
        expect(!plan.name.isEmpty && plan.name.count <= 49 && !plan.name.lowercased().hasPrefix("create"), "a name for the playlist: \(plan.name)")
    }

    func countRequestsAndThinLibraries() {
        let songs = library()
        let ten = compose("10 jazz songs", songs)
        expect(ten.tracks.count == 10 && ten.tracks.allSatisfy { $0.genres[0] == "Jazz" }, "ten jazz songs: \(ten.tracks.map(\.title))")
        // a library with little that fits says so
        let few = Array(songs.filter { $0.track.genres[0] != "Folk" }.prefix(60)) + Array(songs.filter { $0.track.genres[0] == "Folk" }.prefix(4))
        let thin = compose("an hour of folk", few)
        expect(thin.tracks.count == 4 && thin.tracks.allSatisfy { $0.genres[0] == "Folk" } && thin.notes.contains { $0.contains("Only") }, "only folk, and the shortfall is explained: \(thin.tracks.count), \(thin.notes)")
        let none = compose("an hour of folk from the 1960s", songs)
        expect(none.tracks.isEmpty && none.notes.contains { $0.contains("Nothing in your library matches") }, "the library has no 1960s folk, and says so: \(none.notes)")
        let empty = compose("anything", [])
        expect(empty.tracks.isEmpty && empty.notes.first?.contains("empty") == true, "empty library")
        // interludes are left out
        var withSkit = library(20); withSkit[0].track.duration = 20; withSkit[0].track.genres = ["Jazz"]
        let p = compose("20 songs", withSkit)
        expect(!p.tracks.contains { $0.duration < PlaylistEngine.minimumSongSeconds }, "no skits")
    }

    func fitAndOrderBehave() {
        let songs = library(40)
        let ranked = PlaylistEngine.rank(songs, brief: PlaylistBrief(request: ""))
        let picks = Array(ranked.prefix(12))
        let total = picks.reduce(0.0) { $0 + $1.song.track.duration }
        let target = total - 100
        let fitted = PlaylistEngine.fit(picks, target: target, spare: ranked, floor: -.infinity)
        let after = fitted.reduce(0.0) { $0 + $1.song.track.duration }
        expect(abs(after - target) <= abs(total - target), "fitting never makes it worse: \(total) → \(after) for \(target)")
        var g = SeededRNG(seed: 3)
        let pool = Array(songs.prefix(30))
        let down = PlaylistEngine.order(pool, arc: .windDown, using: &g)
        let up = PlaylistEngine.order(pool, arc: .buildUp, using: &g)
        func mean(_ s: ArraySlice<SmartDJTrack>) -> Double { s.map { $0.energy ?? 0.5 }.reduce(0, +) / Double(max(1, s.count)) }
        expect(Set(down.map(\.track.path)) == Set(pool.map(\.track.path)) && down.count == pool.count, "nothing lost")
        expect(mean(down.prefix(10)) > mean(down.suffix(10)) && mean(up.prefix(10)) < mean(up.suffix(10)), "winding down falls, building up rises")
        expect(PlaylistEngine.suggestedName(for: "Create a 2-hour mix of late-night tracks") == "2-hour mix of late-night tracks", PlaylistEngine.suggestedName(for: "Create a 2-hour mix of late-night tracks"))
        expect(PlaylistEngine.suggestedName(for: "   ") == "New mix")
    }

    func meaningNudgesTheRanking() {
        let songs = library(60)
        let plain = compose("10 songs", songs)
        // the request is neutral, so a similarity score alone decides: songs the index calls close come first
        let close = stride(from: 0, to: 60, by: 6).map { songs[$0] }
        var sem: [String: Float] = [:]
        for s in close { sem[s.track.path] = 0.9 }
        let nudged = compose("10 songs", songs, semantic: sem)
        expect(Set(nudged.tracks.map(\.path)) == Set(close.map(\.track.path)), "similar songs are chosen: \(nudged.tracks.map(\.title))")
        expect(nudged.notes.contains { $0.contains("meaning") } && !plain.notes.contains { $0.contains("meaning") }, "the page says so")
    }

    // MARK: the model

    func theModelRefinesAndChoosesButCannotOverrideTheWords() {
        let songs = library()
        let m = ScriptedPlaylistModel()
        _ = runAsync { try await m.load(model: "x") { _, _ in } }
        // a vague request: the model's reading fills the gaps, its genre only nudges and must exist in the library
        m.brief = #"{"energy":"low","arc":"winding down","acoustic":true,"instrumental":false,"genres":["folk","polka"]}"#
        let vague = compose("something for a long drive", songs, model: m)
        expect(vague.brief.intent.energy == .low && vague.brief.arc == .windDown && vague.brief.acoustic, "model filled the gaps: \(vague.brief)")
        expect(vague.brief.hintGenres == ["folk"], "a made-up genre is dropped: \(vague.brief.hintGenres)")
        expect(vague.usedModel && vague.modelPicked > 0 && m.briefCalls == 1 && m.pickCalls == 1, "two questions asked: \(m.briefCalls), \(m.pickCalls)")
        // a clear request: the words win over the model
        m.brief = #"{"energy":"high","arc":"building up","acoustic":true,"instrumental":true,"genres":["rock"]}"#
        let clear = compose("late-night low-energy tracks", songs, model: m)
        expect(clear.brief.intent.energy == .low && clear.brief.arc == .windDown && !clear.brief.acoustic && !clear.brief.instrumental && clear.brief.hintGenres.isEmpty,
               "the request's own words are not overridden: \(clear.brief)")
        expect(clear.tracks.allSatisfy { ($0.lufs ?? -30) < -10 }, "and the songs still fit them")
    }

    func theModelsPicksAreCheckedAgainstTheRequest() {
        let songs = library()
        let m = ScriptedPlaylistModel()
        _ = runAsync { try await m.load(model: "x") { _, _ in } }
        m.choose = { ids in ids.reversed() }
        let plan = compose("10 acoustic folk songs", songs, model: m)
        expect(plan.tracks.count == 10 && plan.tracks.allSatisfy { $0.genres[0] == "Folk" }, "ten folk songs: \(plan.tracks.map(\.title))")
        expect(plan.usedModel && plan.modelPicked >= 6, "most are the model's: \(plan.modelPicked)")
        // unusable answers fall back to the ranking and say so
        m.rawPick = "I think you will like these!"
        let junk = compose("10 acoustic folk songs", songs, model: m)
        expect(!junk.usedModel && junk.tracks.count == 10 && junk.notes.contains { $0.contains("could not be used") }, "junk answer: \(junk.notes)")
        m.rawPick = #"{"ids":[9999,9998,9997]}"#
        let invented = compose("10 acoustic folk songs", songs, model: m)
        expect(!invented.usedModel && invented.tracks.count == 10, "invented ids are ignored")
        // a failing model never takes the playlist down
        m.rawPick = nil; m.failOn = ["brief", "pick"]
        let failed = compose("10 acoustic folk songs", songs, model: m)
        expect(!failed.usedModel && failed.tracks.count == 10 && failed.notes.contains { $0.contains("failed") }, "failure: \(failed.notes)")
        // an unloaded model is not used at all
        let cold = ScriptedPlaylistModel()
        let none = compose("10 acoustic folk songs", songs, model: cold)
        expect(!none.usedModel && cold.briefCalls == 0 && cold.pickCalls == 0 && none.tracks.count == 10, "not loaded, not asked")
    }

    func theSameRequestGivesTheSameAnswerForOneSeed() {
        let songs = library()
        let a = compose("an hour of calm jazz", songs, seed: 11), b = compose("an hour of calm jazz", songs, seed: 11)
        expect(a.tracks.map(\.path) == b.tracks.map(\.path), "reproducible for one seed")
    }

    // MARK: analysis figures

    func analysisSummariesSkipTheWaveform() {
        let cacheDir = dir.appendingPathComponent("an-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let cache = AnalysisCache(directory: cacheDir)
        let file = dir.appendingPathComponent("song-\(UUID().uuidString.prefix(6)).flac")
        try? Data(repeating: 1, count: 64).write(to: file)
        var a = DJTrackAnalysis(peaks: [Float](repeating: 0.5, count: 1200), bpm: 101, confidence: 0.9, duration: 200)
        a.energy = 0.42; a.key = MusicalKey(pitchClass: 0, minor: false); a.loudness = -17
        expect(cache.summary(path: file.path) == nil, "nothing before it is analysed")
        cache.store(a, path: file.path)
        let fresh = AnalysisCache(directory: cacheDir)                              // a new cache object: the figures come from the disk
        let s = fresh.summary(path: file.path)
        expect(s == AnalysisSummary(bpm: 101, energy: 0.42, key: "8B", loudness: -17), "figures: \(String(describing: s))")
        try? Data(repeating: 2, count: 200).write(to: file)                        // the file changed: the analysis is stale
        expect(fresh.summary(path: file.path) == nil, "stale after the file changed")
        // without a DJ analysis the loudness figures stand in for energy
        let songs = NaturalPlaylistService.prepare(tracks: [dto(1, "Quiet", "A", "Folk", lufs: -24), dto(2, "Loud", "B", "Rock", lufs: -10), dto(3, "Unknown", "C", "Rock")],
                                                   analysis: { $0 == "/music/1.flac" ? AnalysisSummary(bpm: 80, energy: 0.2, key: "8A", loudness: -22) : nil })
        expect(songs[0].energy == 0.2 && songs[0].bpm == 80 && songs[0].key == "8A", "an analysis wins")
        expect(songs[1].energy == 1 && songs[2].energy == nil, "loudness is the stand-in, and unknown stays unknown: \(String(describing: songs[1].energy))")
    }

    // MARK: the switch

    @MainActor private func service(_ model: ScriptedPlaylistModel, allowed: @escaping () -> Bool = { true }) -> NaturalPlaylistService {
        let s = NaturalPlaylistService()
        let tracks = library().map(\.track)
        s.library = { { tracks } }
        s.analysis = { _ in nil }
        s.isAllowed = allowed
        s.makeBackend = { (model, "test-model", "scripted model") }
        s.rng = { 5 }
        return s
    }

    func theServiceObeysTheSwitchAndFreesTheModel() {
        MainActor.assumeIsolated {
            let model = ScriptedPlaylistModel()
            let on = Box(true)
            let s = service(model, allowed: { on.v })
            s.idleUnload = 0.3
            Task { await s.build("10 acoustic folk songs") }
            wait { s.state == .done }
            expect(s.state == .done && s.plan?.tracks.count == 10 && model.loads == 1 && s.modelLoaded && s.engineDescription == "scripted model", "built: \(s.state), loads \(model.loads)")
            expect(s.plan?.usedModel == true, "the model took part")
            // a second request reuses the loaded model
            Task { await s.build("10 jazz songs") }
            wait { s.history.count == 2 && s.state == .done }
            expect(model.loads == 1 && s.history.count == 2, "the model stays loaded between requests: \(model.loads)")
            // idle: it is unloaded
            wait { model.unloads == 1 && !s.modelLoaded }
            expect(model.unloads == 1 && !s.modelLoaded && !model.isLoaded, "unloaded after the idle time: \(model.unloads)")
            // the next request loads it again
            Task { await s.build("10 jazz songs") }
            wait { model.loads == 2 && s.state == .done }
            expect(model.loads == 2, "loaded again on demand")
            // switching the feature off frees it at once and refuses new requests
            on.v = false
            s.shutDown()
            wait { !model.isLoaded }
            expect(!model.isLoaded && !s.modelLoaded && s.plan == nil, "shut down frees the model")
            let before = model.loads
            Task { await s.build("10 jazz songs") }
            wait { if case .failed = s.state { return true } else { return false } }
            expect(s.state == .failed(NaturalPlaylistService.offMessage) && model.loads == before, "refused while off, nothing loaded: \(s.state)")
        }
    }

    func theIntelligenceSwitchesReachPlaylists() {
        MainActor.assumeIsolated {
            @MainActor func center(_ hw: HostHardware, _ s: IntelligenceSettings? = nil) -> IntelligenceCenter {
                let settings = s ?? .defaults(for: hw)
                return IntelligenceCenter(gate: IntelligenceGate(hardware: hw, settings: settings), keys: AIKeyStore(store: MemorySecretStore()),
                                          defaults: UserDefaults(suiteName: "aureon.pltest.\(UUID().uuidString.prefix(8))")!, persist: false, settings: settings)
            }
            // Apple Silicon: on by default, with the master switch and its own switch
            let a = center(IntelligenceTests.appleM)
            expect(a.playlists.isAllowed() && a.isActive(.naturalPlaylists), "on by default on Apple Silicon")
            a.setFeature(.naturalPlaylists, false)
            expect(!a.playlists.isAllowed(), "its own switch")
            a.setFeature(.naturalPlaylists, true); a.setMaster(false)
            expect(!a.playlists.isAllowed(), "the master switch")
            a.setMaster(true)
            expect(a.playlists.isAllowed(), "back on")
            // Intel: off until the warning is accepted
            let i = center(IntelligenceTests.intel)
            expect(!i.playlists.isAllowed(), "off by default on Intel")
            i.setMaster(true)
            expect(!i.playlists.isAllowed() && i.showIntelWarning, "still off behind the warning")
            i.acceptIntelWarning()
            expect(i.playlists.isAllowed(), "on once accepted")
            var reason = ""
            do { _ = try i.playlistBackend() } catch { reason = error.localizedDescription }
            expect(reason.contains("Apple Silicon"), "on-device models need Apple Silicon: \(reason)")
            // the engine choice is its own and shares the provider
            i.setEngine(.naturalPlaylists, .api)
            expect(i.settings.playlistEngine == .api && i.settings.smartDJEngine == .onDevice && i.settings.engine(for: .naturalPlaylists) == .api, "engine choice is separate from Smart DJ")
            // switching it off while the model is loaded frees the model
            let model = ScriptedPlaylistModel()
            a.playlists.makeBackend = { (model, "m", "scripted") }
            a.playlists.library = { { self.library().map(\.track) } }
            a.playlists.analysis = { _ in nil }
            a.playlists.similarities = { _ in nil }
            Task { await a.playlists.build("10 jazz songs") }
            wait { a.playlists.state == .done }
            expect(model.isLoaded && a.playlists.modelLoaded, "loaded for the request")
            a.setFeature(.naturalPlaylists, false)
            wait { !model.isLoaded }
            expect(!model.isLoaded && a.playlists.plan == nil, "turning the feature off frees the model and forgets the result")
            // the same through the master switch
            a.setFeature(.naturalPlaylists, true)
            Task { await a.playlists.build("10 jazz songs") }
            wait { a.playlists.state == .done && model.isLoaded }
            a.setMaster(false)
            wait { !model.isLoaded }
            expect(!model.isLoaded, "the master switch frees it too")
            // defaults written before this feature existed still decode, with it on
            let old = #"{"masterEnabled":true,"smartDJ":true}"#
            let decoded = try? JSONDecoder().decode(IntelligenceSettings.self, from: Data(old.utf8))
            expect(decoded?.naturalPlaylists == true && decoded?.playlistEngine == .onDevice, "old settings decode")
        }
    }
}

func naturalPlaylistTests() -> [(String, TestFn)] {
    let t = NaturalPlaylistTests()
    return [("playlist.lengths", t.lengthsAreRead), ("playlist.headline", t.theHeadlineRequestBecomesHardFacts), ("playlist.requests", t.otherRequestsAreRead),
            ("playlist.ranking", t.rankingPrefersTheRightRecordings), ("playlist.fit", t.theLengthIsFitAndTheArcFollowed), ("playlist.counts", t.countRequestsAndThinLibraries),
            ("playlist.fitOrder", t.fitAndOrderBehave), ("playlist.meaning", t.meaningNudgesTheRanking), ("playlist.model", t.theModelRefinesAndChoosesButCannotOverrideTheWords),
            ("playlist.modelChecks", t.theModelsPicksAreCheckedAgainstTheRequest), ("playlist.seed", t.theSameRequestGivesTheSameAnswerForOneSeed),
            ("playlist.analysis", t.analysisSummariesSkipTheWaveform), ("playlist.service", t.theServiceObeysTheSwitchAndFreesTheModel), ("playlist.switches", t.theIntelligenceSwitchesReachPlaylists)]
}

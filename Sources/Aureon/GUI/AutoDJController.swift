import SwiftUI
import Combine

/// Plays the library on its own: picks what follows the current track, loads it on the idle deck, matches its tempo, and blends the two with a
/// bass swap. The choosing is done by `TransitionNet`; the timing by `AutoMixer`.
@MainActor
final class AutoDJController: ObservableObject {
    enum Phase: Equatable { case off, starting, playing, armed, blending }

    unowned let model: DJModel
    let net: TransitionNet

    @Published var enabled = false { didSet { if enabled != oldValue { enabled ? begin() : end() } } }
    @Published private(set) var phase = Phase.off
    @Published private(set) var status = "Off"
    @Published private(set) var next: DJTrack?
    @Published private(set) var nextScore: Float?
    @Published private(set) var progress = 0.0
    @Published private(set) var analysed = 0
    @Published private(set) var poolSize = 0
    @Published private(set) var feedbackCount = 0
    @Published private(set) var mixes = 0
    @Published private(set) var canRate = false
    @Published var mixBeats = 32
    @Published var vibe = AutoVibe.steady
    @Published var strictKey = false

    /// The tracks Auto DJ may choose from. Set by the interface.
    var library: () -> [DJTrack] = { [] }
    var persistence = true

    /// The deck that is on air (the one that is not just being mixed in).
    var onAirDeck: DJDeck? { current }
    private var current: DJDeck?
    private var incoming: DJDeck?
    private var plan: MixPlan?
    private var outgoingRatio = 1.0
    private var pool: [String: DJTrackAnalysis] = [:]
    private var tracks: [String: DJTrack] = [:]
    private var recent: [String] = []
    private var lastFeatures: TransitionFeatures?
    private var analysisTask: Task<Void, Never>?
    private var chooseAfter = Date.distantPast
    private var rng = SystemRandomNumberGenerator()

    init(model: DJModel, net: TransitionNet? = nil) {
        self.model = model
        self.net = net ?? TransitionNet.loadOrCreate()
        feedbackCount = self.net.feedbackCount
    }

    // MARK: on / off

    private func begin() {
        phase = .starting; status = "Starting…"; plan = nil; incoming = nil; next = nil
        refreshPool()
        // start from whatever is already playing, else whatever is loaded, else a pick of our own
        current = model.decks.first { $0.playing } ?? model.decks.first { $0.isLoaded }
        if let c = current { settle(c) }
    }

    private func end() {
        analysisTask?.cancel()
        model.autoBlend = nil
        if let i = incoming, phase != .blending { i.unload() }
        for d in model.decks { d.filter = 0 }
        incoming = nil; plan = nil; next = nil; progress = 0; phase = .off; status = "Off"; canRate = false
    }

    /// Makes `c` the deck on air: the crossfader goes to its side so nothing jumps when the first blend starts.
    private func settle(_ c: DJDeck) {
        current = c
        model.crossfader = c === model.a ? -1 : 1
        if !c.playing { c.play() }
        phase = .playing; status = "Playing"
    }

    // MARK: the pool

    /// Looks up (and, in the background, computes) the analyses of the library's tracks.
    func refreshPool() {
        let lib = library()
        tracks = Dictionary(lib.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        poolSize = lib.count
        var missing: [String] = []
        for t in lib {
            if pool[t.path] != nil { continue }
            if let c = AnalysisCache.shared.cached(path: t.path) { pool[t.path] = c } else { missing.append(t.path) }
        }
        analysed = pool.count
        guard !missing.isEmpty, analysisTask == nil else { return }
        let order = Array(missing.shuffled().prefix(150))
        analysisTask = Task { [weak self] in
            // three at a time, so a first handful of tracks is ready within seconds
            await withTaskGroup(of: (String, DJTrackAnalysis?).self) { group in
                var next = 0
                func feed(_ g: inout TaskGroup<(String, DJTrackAnalysis?)>) {
                    guard next < order.count else { return }
                    let path = order[next]; next += 1
                    g.addTask(priority: .utility) { (path, AnalysisCache.shared.analysis(path: path)) }
                }
                for _ in 0..<3 { feed(&group) }
                while let (path, a) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let a, let self { self.pool[path] = a; self.analysed = self.pool.count }
                    feed(&group)
                }
            }
            self?.analysisTask = nil
        }
    }

    /// For tests and for the interface: analyses known to Auto DJ.
    func addToPool(_ t: DJTrack, _ a: DJTrackAnalysis) { pool[t.path] = a; tracks[t.path] = t; analysed = pool.count; poolSize = max(poolSize, tracks.count) }

    // MARK: choosing

    private func candidates(excluding path: String?) -> [AutoCandidate] {
        pool.compactMap { (p, a) in guard p != path, let t = tracks[p], a.bpm != nil else { return nil }; return AutoCandidate(track: t, analysis: a) }
    }

    private func pickFirst() -> DJTrack? {
        var c = candidates(excluding: nil).filter { !recent.contains($0.track.path) }
        if c.isEmpty { c = pool.compactMap { (p, a) in tracks[p].map { AutoCandidate(track: $0, analysis: a) } }.filter { !recent.contains($0.track.path) } }
        // open with something calm-to-medium so there is room to build
        return c.sorted { abs($0.analysis.energy - 0.5) < abs($1.analysis.energy - 0.5) }.prefix(5).randomElement(using: &rng)?.track
    }

    private func chooseNext(after c: DJDeck) {
        guard let cur = c.analysis else { return }
        var ranked = AutoPlanner.rank(current: cur, candidates: candidates(excluding: c.track?.path), recent: recent, vibe: vibe, strictKey: strictKey, net: net)
        if ranked.isEmpty && strictKey { ranked = AutoPlanner.rank(current: cur, candidates: candidates(excluding: c.track?.path), recent: recent, vibe: vibe, strictKey: false, net: net) }
        if ranked.isEmpty {
            // nothing with a usable tempo: any analysed track will do, with a plain fade
            let rest = pool.compactMap { (p, a) -> AutoCandidate? in guard p != c.track?.path, !recent.contains(p), let t = tracks[p] else { return nil }; return AutoCandidate(track: t, analysis: a) }
            ranked = rest.shuffled().prefix(3).map { (candidate: $0, score: Float(0.3)) }
        }
        guard !ranked.isEmpty else {
            status = analysed < 2 ? "Analysing your library… (\(analysed) ready)" : "No other track to play next"
            if pool.isEmpty || analysed < 2 { refreshPool() }
            chooseAfter = Date().addingTimeInterval(2); return
        }
        // among the top few, prefer the best but not always: variety without picking something poor
        let top = ranked.prefix(3).filter { $0.score >= ranked[0].score - 0.06 }
        let pick = top.randomElement(using: &rng) ?? ranked[0]
        let other = model.other(c)
        other.unload()
        other.load(pick.candidate.track)
        guard other.isLoaded else { status = "Could not load \(pick.candidate.track.title)"; chooseAfter = Date().addingTimeInterval(1); return }
        other.setAnalysisForTests(pick.candidate.analysis)         // already known: no need to wait for the deck's own analysis
        lastFeatures = TransitionFeatures(from: cur, to: pick.candidate.analysis)
        outgoingRatio = 1 + c.pitch
        var p = AutoMixer.plan(a: cur, aRatio: outgoingRatio, b: pick.candidate.analysis, beats: mixBeats)
        if p == nil {                                                  // no usable tempo: a plain fade at the end of the track
            let d = 8.0
            p = MixPlan(aStart: max(0, cur.duration - d - 2), bStart: pick.candidate.analysis.firstBeat ?? 0, duration: d, bRatio: 1, beats: 0)
        }
        plan = p
        guard let p else { return }
        other.pitchRange = max(other.pitchRange, abs(p.bRatio - 1) > 0.08 ? 0.16 : other.pitchRange)
        other.pitch = p.bRatio - 1
        other.low = DJMath.eqRange.lowerBound; other.filter = 0
        other.cue = p.bStart
        other.seek(to: p.bStart)
        incoming = other; next = pick.candidate.track; nextScore = pick.score
        phase = .armed; status = "Next: \(pick.candidate.track.title)"
    }

    // MARK: the loop

    func tick() {
        guard enabled else { return }
        if analysed < poolSize || pool.isEmpty { if analysisTask == nil && Int.random(in: 0..<50) == 0 { refreshPool() } }
        switch phase {
        case .off: return
        case .starting:
            if let c = current, c.isLoaded { settle(c); return }
            guard Date() >= chooseAfter else { return }
            refreshPool()
            if let t = pickFirst() {
                let d = model.freeDeck()
                d.load(t)
                if d.isLoaded { if let a = pool[t.path] { d.setAnalysisForTests(a) }; recent.append(t.path); settle(d) }
            } else { status = "Analysing your library… (\(analysed) ready)"; refreshPool(); chooseAfter = Date().addingTimeInterval(2) }
        case .playing:
            guard let c = current else { phase = .starting; return }
            if !c.isLoaded { phase = .starting; current = nil; return }
            // track ended by itself with nothing queued: carry on with a fresh pick
            if !c.playing && c.position >= c.duration - 0.2 { c.unload(); current = nil; phase = .starting; return }
            if c.analysis != nil, Date() >= chooseAfter { chooseNext(after: c) }
        case .armed:
            guard let c = current, let i = incoming, let p = plan else { phase = .playing; return }
            if !c.isLoaded { phase = .starting; return }
            if c.position >= p.aStart || (!c.playing && c.position >= c.duration - 0.2) {
                canRate = false
                i.play(); phase = .blending; status = "Mixing into \(i.track?.title ?? "next track")"
                blend(c, i, p)
            }
        case .blending:
            guard let c = current, let i = incoming, let p = plan else { phase = .playing; return }
            blend(c, i, p)
        }
    }

    private func blend(_ c: DJDeck, _ i: DJDeck, _ p: MixPlan) {
        let span = max(0.5, p.duration * outgoingRatio)
        let prog = (c.position - p.aStart) / span
        progress = max(0, min(1, prog))
        let ended = !c.playing && c.position >= c.duration - 0.2
        if prog >= 1 || ended || !c.isLoaded {
            finish(c, i)
        } else {
            let f = AutoMixer.frame(prog)
            model.autoBlend = (c, f)
            c.low = f.lowA; i.low = f.lowB; c.filter = f.filterA
        }
    }

    private func finish(_ c: DJDeck, _ i: DJDeck) {
        model.autoBlend = nil
        model.crossfader = i === model.a ? -1 : 1
        i.low = 0; i.filter = 0
        c.unload(); c.low = 0; c.filter = 0; c.pitch = 0
        if let p = i.track?.path { recent.append(p); if recent.count > 25 { recent.removeFirst() } }
        current = i; incoming = nil; plan = nil; next = nil; progress = 0
        mixes += 1; canRate = lastFeatures != nil
        phase = .playing; status = "Playing"
        chooseAfter = Date().addingTimeInterval(2)
    }

    // MARK: feedback

    /// Teaches the network about the transition that just finished.
    func rate(liked: Bool) {
        guard let f = lastFeatures else { return }
        net.feedback(f, liked: liked)
        if persistence { net.save() }
        feedbackCount = net.feedbackCount
        lastFeatures = nil; canRate = false
    }

    /// Starts the next mix now instead of waiting for the end of the track.
    func skip() {
        guard enabled else { return }
        switch phase {
        case .playing:
            guard let c = current else { return }
            chooseAfter = .distantPast
            if c.analysis != nil { chooseNext(after: c) }
            if phase == .armed, var p = plan { p.aStart = c.position; plan = p }
        case .armed:
            if let c = current, var p = plan { p.aStart = c.position; plan = p }
        default: break
        }
    }
}

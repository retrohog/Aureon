import SwiftUI
import Combine
import CoreAudio

struct DJTrack: Equatable {
    var path: String
    var title: String
    var artist: String
    var album: String = ""
}

/// Hot cues are remembered per track.
enum HotCueStore {
    private static let key = "aureon.dj.hotcues"
    private static var enabled: Bool { ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil && ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil }
    static var overrideDefaults: UserDefaults?
    private static var defaults: UserDefaults { overrideDefaults ?? .standard }

    static func load(path: String) -> [Double?] {
        guard enabled || overrideDefaults != nil, let d = defaults.dictionary(forKey: key) as? [String: [Double]], let v = d[path], v.count == 4 else { return Array(repeating: nil, count: 4) }
        return v.map { $0 < 0 ? nil : $0 }
    }
    static func save(path: String, cues: [Double?]) {
        guard enabled || overrideDefaults != nil else { return }
        var d = (defaults.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
        if cues.allSatisfy({ $0 == nil }) { d[path] = nil } else { d[path] = cues.map { $0 ?? -1 } }
        defaults.set(d, forKey: key)
    }
}

/// One deck: its own player, feeding a channel of the mixer. Everything on the channel strip is a published value that is pushed to the mixer's atomics.
@MainActor
final class DJDeck: ObservableObject, Identifiable {
    let name: String
    let player = Player()
    let control = VarispeedControl()
    private(set) var mix: DJMixerCore.Deck
    private var usesMixer = false

    @Published private(set) var track: DJTrack?
    @Published private(set) var analysis: DJTrackAnalysis?
    @Published private(set) var analyzing = false
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var error: String?
    @Published private(set) var peakL: Float = 0
    @Published private(set) var peakR: Float = 0
    @Published var cue = 0.0
    /// The pitch fader as a fraction: +0.04 plays 4 % faster (and higher).
    @Published var pitch = 0.0 { didSet { control.ratio = 1 + pitch; mix.params.bpm.value = Float(effectiveBPM ?? 0); onMix?() } }
    @Published var pitchRange = 0.08
    @Published var channel = 0.8 { didSet { onMix?() } }
    @Published var low = 0.0 { didSet { mix.params.low.value = Float(DJMath.eqGainDB(low)) } }
    @Published var mid = 0.0 { didSet { mix.params.mid.value = Float(DJMath.eqGainDB(mid)) } }
    @Published var high = 0.0 { didSet { mix.params.high.value = Float(DJMath.eqGainDB(high)) } }
    /// Input gain in dB.
    @Published var trim = 0.0 { didSet { mix.params.trim.value = Float(pow(10, trim / 20)) } }
    /// -1 sweeps a low-pass down, +1 a high-pass up, 0 is off.
    @Published var filter = 0.0 { didSet { mix.params.filter.value = Float(filter) } }
    @Published var fxKind = DeckFXKind.echo { didSet { mix.params.fxKind.value = fxKind.rawValue } }
    @Published var fxOn = false { didSet { mix.params.fxOn.value = fxOn ? 1 : 0 } }
    @Published var fxWet = 0.35 { didSet { mix.params.fxWet.value = Float(fxWet) } }
    @Published var fxParam = 0.5 { didSet { mix.params.fxParam.value = Float(fxParam) } }
    /// Pre-fader listen (headphone cue).
    @Published var pfl = false { didSet { mix.cue.value = pfl ? 1 : 0 } }
    @Published private(set) var hotCues: [Double?] = Array(repeating: nil, count: 4)
    @Published private(set) var loopIn: Double?
    @Published private(set) var loopOut: Double?
    @Published private(set) var loopActive = false
    @Published private(set) var bending = 0.0

    var onMix: (() -> Void)?
    var options = PlayerOptions()
    var deckRate = 48_000.0
    var quantize = true
    private var analysisTask: Task<Void, Never>?
    private var lastTick: Date?
    private var lastWraps = 0
    private var trustEngineAfter = Date.distantPast       // just after a seek the engine's figure is still the old one

    init(_ name: String) {
        self.name = name
        mix = DJMixerCore.Deck(sampleRate: 48_000)
        player.varispeed = control
        mix.params.fxKind.value = fxKind.rawValue; mix.params.fxWet.value = Float(fxWet); mix.params.fxParam.value = Float(fxParam)
    }

    /// Connects this deck to a channel of a mixer: its player renders into that channel, and all its controls are applied to it.
    func attach(_ channel: DJMixerCore.Deck, rate: Double) {
        mix = channel; usesMixer = true; deckRate = rate
        channel.params.fxKind.value = fxKind.rawValue; channel.params.fxWet.value = Float(fxWet); channel.params.fxParam.value = Float(fxParam)
        channel.params.fxOn.value = fxOn ? 1 : 0
        channel.params.low.value = Float(DJMath.eqGainDB(low)); channel.params.mid.value = Float(DJMath.eqGainDB(mid)); channel.params.high.value = Float(DJMath.eqGainDB(high))
        channel.params.trim.value = Float(pow(10, trim / 20)); channel.params.filter.value = Float(filter)
        channel.params.bpm.value = Float(effectiveBPM ?? 0); channel.cue.value = pfl ? 1 : 0
        onMix?()
    }

    var bpm: Double? { analysis?.bpm }
    var effectiveBPM: Double? { DJMath.effectiveBPM(bpm, pitch: pitch) }
    var isLoaded: Bool { track != nil }
    var key: MusicalKey? { analysis?.key }
    /// Length of one beat in seconds of the track (not affected by the pitch fader).
    var beatLength: Double? { bpm.map { 60 / $0 } }

    private func settings() -> PlaybackSettings { var s = PlaybackSettings(); s.deckRate = deckRate; return s }

    private func playerOptions(paused: Bool) -> PlayerOptions {
        var o = options; o.startPaused = paused
        if usesMixer { let m = mix, r = deckRate; o.sinkFactory = { _ in DeckSink(deck: m, rate: r) } }
        return o
    }

    func load(_ t: DJTrack) {
        analysisTask?.cancel()
        player.stop()
        clearLoop()
        track = t; analysis = nil; error = nil; position = 0; cue = 0; playing = false; pitch = 0; bend(0); lastTick = nil
        hotCues = HotCueStore.load(path: t.path)
        guard let f = try? openLossless(path: t.path) else { error = "Could not open this file"; track = nil; return }
        if f.info.sourceBits == 1 { error = "DSD files cannot be loaded on a deck"; track = nil; return }
        duration = f.info.duration
        player.settings = settings()
        player.setQueue([t.path])
        player.start(options: playerOptions(paused: true))
        if let cached = AnalysisCache.shared.cached(path: t.path) { analysis = cached; analyzing = false; mix.params.bpm.value = Float(effectiveBPM ?? 0); return }
        analyzing = true
        let path = t.path
        analysisTask = Task { [weak self] in
            let a = await Task.detached(priority: .utility) { AnalysisCache.shared.analysis(path: path) }.value
            guard !Task.isCancelled, let self, self.track?.path == path else { return }
            self.analysis = a; self.analyzing = false; self.mix.params.bpm.value = Float(self.effectiveBPM ?? 0)
        }
    }

    func setAnalysisForTests(_ a: DJTrackAnalysis) { analysis = a }

    func unload() {
        analysisTask?.cancel(); player.stop(); clearLoop(); track = nil; analysis = nil; playing = false; position = 0; duration = 0; hotCues = Array(repeating: nil, count: 4)
        mix.params.fxOn.value = 0; fxOn = false
    }

    func play() {
        guard track != nil else { return }
        if player.isRunning { player.send(.setPaused(false)) }
        else { player.start(startSeconds: min(cue, max(0, duration - 0.5)), options: playerOptions(paused: false)) }
    }

    func pause() { if player.isRunning { player.send(.setPaused(true)) } }
    func togglePlay() { playing ? pause() : play() }

    /// CDJ-style: while playing, jump back to the cue point and wait there; while stopped, set the cue point here.
    func cuePressed() {
        guard track != nil else { return }
        if playing { pause(); seek(to: cue) } else { cue = snapped(position) }
    }

    func seek(to t: Double) {
        guard track != nil else { return }
        let s = max(0, min(t, max(0, duration - 0.1)))
        if player.isRunning { player.send(.seekTo(s)) }
        else { player.start(startSeconds: s, options: playerOptions(paused: true)) }
        position = s; lastTick = nil; trustEngineAfter = Date().addingTimeInterval(0.3)
    }

    /// Snaps a position to the nearest beat when quantize is on and the track has a beat grid.
    func snapped(_ t: Double) -> Double { quantize ? (analysis?.nearestBeat(to: t).map { max(0, $0) } ?? t) : t }

    // MARK: hot cues

    func hotCue(_ i: Int) {
        guard track != nil, hotCues.indices.contains(i) else { return }
        if let t = hotCues[i] { seek(to: t); if !playing { play() } }
        else { hotCues[i] = snapped(position); persistCues() }
    }
    func clearHotCue(_ i: Int) { guard hotCues.indices.contains(i) else { return }; hotCues[i] = nil; persistCues() }
    private func persistCues() { if let p = track?.path { HotCueStore.save(path: p, cues: hotCues) } }

    // MARK: loops

    private func applyLoop() {
        guard let a = loopIn, let b = loopOut, b > a else { control.clearLoop(); loopActive = false; return }
        control.setLoop(from: Int64(a * deckRate), to: Int64(b * deckRate), on: loopActive)
    }
    func setLoopIn() { guard track != nil else { return }; loopIn = snapped(position); if let o = loopOut, o <= loopIn! { loopOut = nil; loopActive = false; control.clearLoop() } }
    func setLoopOut() {
        guard track != nil, let a = loopIn else { return }
        let b = snapped(position)
        guard b > a + 0.02 else { return }
        loopOut = b; loopActive = true; applyLoop()
    }
    /// A loop of `beats` beats starting at the current position (on the beat grid when there is one).
    func autoLoop(beats: Double, snap: Bool = false) {
        guard track != nil else { return }
        let len = beats * (beatLength ?? 0.5)
        let a = snap ? (analysis?.nearestBeat(to: position).map { max(0, $0) } ?? position) : snapped(position)
        loopIn = a; loopOut = min(duration, a + len); loopActive = true; applyLoop()
    }
    func toggleLoop() {
        guard track != nil else { return }
        if loopActive { loopActive = false; applyLoop(); return }
        if loopIn != nil, loopOut != nil { loopActive = true; applyLoop() } else { autoLoop(beats: 4) }
    }
    func scaleLoop(_ f: Double) {
        guard let a = loopIn, let b = loopOut else { return }
        let len = max(0.03, min(duration - a, (b - a) * f))
        loopOut = a + len; applyLoop()
    }
    func clearLoop() { loopIn = nil; loopOut = nil; loopActive = false; control.clearLoop() }
    var loopBeats: Double? { guard let a = loopIn, let b = loopOut, let bl = beatLength else { return nil }; return (b - a) / bl }

    // MARK: pitch bend

    /// A momentary nudge (like pushing the jog wheel): +1 = 4 % faster, -1 = 4 % slower, 0 releases.
    func bend(_ x: Double) { bending = x; control.bend = x * 0.04 }

    /// Reads the engine's state (called ten times a second by the model).
    func refresh() {
        guard track != nil else { return }
        let st = player.status, now = Date()
        playing = st.state == .playing
        if st.finished && player.isRunning == false && st.state == .idle { playing = false }
        else if player.isRunning {
            // The engine reads ahead in chunks, so its figure steps; between looks the position is dead-reckoned at the current speed and gently
            // pulled toward the engine's figure, which keeps it smooth and prevents drift.
            let engine = max(0, min(duration, control.sourceFrame / deckRate - st.bufferedSeconds * control.ratio))
            let speed = control.ratio * (1 + control.bend)
            if playing, let last = lastTick, now >= trustEngineAfter || lastTick != nil {
                let dead = position + now.timeIntervalSince(last) * speed
                position = now >= trustEngineAfter && !loopActive ? dead + (engine - dead) * 0.12 : dead
            } else if now >= trustEngineAfter { position = engine }
            if loopActive, let a = loopIn, let b = loopOut, b > a, position >= b { position = a + (position - b).truncatingRemainder(dividingBy: b - a) }
            position = max(0, min(duration, position))
        }
        lastTick = playing ? now : nil
        if st.finished { playing = false; position = min(duration, position) }
        peakL = mix.peakL.value; peakR = mix.peakR.value
    }

    func shutdown() { analysisTask?.cancel(); player.stop() }
}

enum CueRoute: Equatable {
    case none, channels34, device(AudioDeviceID)
}

@MainActor
final class DJModel: ObservableObject {
    let a = DJDeck("A")
    let b = DJDeck("B")
    @Published var crossfader = 0.0 { didSet { applyMix() } }
    @Published var curve = CrossfaderCurve.smooth { didSet { applyMix() } }
    @Published private(set) var active = false
    @Published var quantize = true { didSet { decks.forEach { $0.quantize = quantize } } }

    // master section
    @Published var masterLow = 0.0 { didSet { core.masterLow.value = Float(DJMath.eqGainDB(masterLow)) } }
    @Published var masterMid = 0.0 { didSet { core.masterMid.value = Float(DJMath.eqGainDB(masterMid)) } }
    @Published var masterHigh = 0.0 { didSet { core.masterHigh.value = Float(DJMath.eqGainDB(masterHigh)) } }
    /// Master level, 0…1.25 (1 = unity).
    @Published var masterLevel = 1.0 { didSet { core.trim.value = Float(max(0, min(1.25, masterLevel))) } }
    @Published var limiter = true { didSet { core.limiterOn.value = limiter ? 1 : 0 } }
    @Published private(set) var meterL: Float = 0
    @Published private(set) var meterR: Float = 0
    @Published private(set) var limiterReduction: Float = 0

    // headphones
    @Published var cueMix = 0.0 { didSet { core.cueMix.value = Float(cueMix) } }
    @Published var cueLevel = 0.8 { didSet { core.cueLevel.value = Float(cueLevel) } }
    @Published var cueRoute = CueRoute.none { didSet { if active && oldValue != cueRoute { restartOutputs() } } }
    @Published private(set) var outputError: String?

    // recording
    @Published private(set) var recording = false
    @Published private(set) var recordingURL: URL?
    @Published private(set) var recordedSeconds = 0.0
    private var tap: RecorderTap?

    private(set) var core = DJMixerCore(sampleRate: 48_000)
    private var outputs: [DJOutput] = []
    private var cueRing: FloatRing?
    private var timer: Timer?
    private var options = PlayerOptions()
    private var rate = 48_000.0
    /// Tests and snapshots replace the real device output.
    var outputFactory: ((DJMixerCore) -> DJOutput?)?
    lazy var remix = RemixController(model: self)
    /// The language model that picks songs from a spoken request. Only in memory while it is switched on.
    let smart = SmartDJService()

    init() {
        a.onMix = { [weak self] in self?.applyMix() }
        b.onMix = { [weak self] in self?.applyMix() }
        applyMix()
    }

    var decks: [DJDeck] { [a, b] }

    /// Mixes the two decks' output levels: channel fader × crossfader.
    func applyMix() {
        let g = curve.gains(crossfader), ga = g.a, gb = g.b
        a.mix.gain.value = Float(DJMath.channelGain(a.channel) * ga)
        b.mix.gain.value = Float(DJMath.channelGain(b.channel) * gb)
    }

    func enter(options: PlayerOptions, rate: Double) {
        guard !active else { return }
        active = true
        self.options = options; self.rate = rate
        buildCore()
        for d in decks { d.options = options; d.options.sinkFactory = nil; d.quantize = quantize; d.player.analysis.setActive(true) }
        startOutputs()
        applyMix()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func buildCore() {
        let c = DJMixerCore(sampleRate: rate)
        c.masterLow.value = Float(DJMath.eqGainDB(masterLow)); c.masterMid.value = Float(DJMath.eqGainDB(masterMid)); c.masterHigh.value = Float(DJMath.eqGainDB(masterHigh))
        c.trim.value = Float(masterLevel); c.limiterOn.value = limiter ? 1 : 0; c.cueMix.value = Float(cueMix); c.cueLevel.value = Float(cueLevel)
        core = c
        a.attach(c.a, rate: rate); b.attach(c.b, rate: rate)
    }

    private func startOutputs() {
        outputError = nil
        stopOutputs()
        if let f = outputFactory { if let o = f(core) { do { try o.start(); outputs = [o] } catch { outputError = "\(error)" } }; return }
        var ring: FloatRing?
        var cueOut: DJOutput?
        if case .device(let id) = cueRoute {
            let r = FloatRing(frames: Int(rate))
            if let o = CoreAudioCueOutput(deviceID: id, ring: r, srcRate: rate) { ring = r; cueOut = o } else { outputError = "The headphone device is not available" }
        }
        guard let main = CoreAudioDJOutput(deviceID: options.deviceID, core: core, cueRing: ring, cueOnChannels34: cueRoute == .channels34) else { outputError = "No output device"; return }
        do {
            try main.start(); outputs = [main]
            if let c = cueOut { do { try c.start(); outputs.append(c) } catch { outputError = "Headphones: \(error)" } }
        } catch { outputError = "\(error)" }
        cueRing = ring
    }

    private func stopOutputs() { outputs.forEach { $0.stop() }; outputs = []; cueRing = nil }
    private func restartOutputs() { startOutputs() }

    func exit() {
        guard active else { return }
        active = false
        smart.disable()
        remix.enabled = false
        stopRecording()
        timer?.invalidate(); timer = nil
        for d in decks { d.unload(); d.player.analysis.setActive(false) }
        stopOutputs()
    }

    /// Ten times a second: the decks, the meters, the recording clock.
    func tick() {
        decks.forEach { $0.refresh() }
        advanceSet()
        meterL = core.meterL.value; meterR = core.meterR.value; limiterReduction = core.limiterReduction.value
        if recording, let t = tap { recordedSeconds = Double(t.frames) / rate }
    }

    // MARK: recording

    func startRecording(to url: URL? = nil) {
        guard active, !recording else { return }
        let dir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon Mixes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let u = url ?? dir.appendingPathComponent("Mix \(f.string(from: Date())).wav")
        guard let t = RecorderTap(url: u, sampleRate: rate) else { outputError = "Could not create the recording file"; return }
        t.start(); tap = t; core.recorder.publish(t)
        recording = true; recordingURL = u; recordedSeconds = 0
    }

    @discardableResult
    func stopRecording() -> URL? {
        guard recording, let t = tap else { return nil }
        core.recorder.publish(nil)
        let u = t.stop(); tap = nil; recording = false
        return u
    }

    func other(_ d: DJDeck) -> DJDeck { d === a ? b : a }

    /// Matches this deck's tempo to the other deck's current tempo (half or double time if that is closer).
    func sync(_ d: DJDeck) {
        guard let mine = d.bpm, let target = other(d).effectiveBPM, let p = DJMath.syncPitch(bpm: mine, target: target) else { return }
        d.pitch = max(-d.pitchRange, min(d.pitchRange, p))
        if abs(p) > d.pitchRange { d.pitchRange = 0.16; d.pitch = p }
    }

    /// Tempo sync, then nudges this deck so its beats fall on the other deck's beats (within the accuracy of the position readout).
    func beatSync(_ d: DJDeck) {
        sync(d)
        let o = other(d)
        guard let mine = d.analysis, let theirs = o.analysis, let bl = d.beatLength, let pm = mine.beatPhase(at: d.position), let pt = theirs.beatPhase(at: o.position) else { return }
        var delta = pt - pm
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        d.seek(to: d.position + delta * bl)
    }

    // MARK: library information (tempo, key, energy for the browser)

    @Published private(set) var info: [String: DJTrackAnalysis] = [:]
    @Published private(set) var analysisProgress: (done: Int, total: Int)?
    private var infoRequested: Set<String> = []
    private var libraryTask: Task<Void, Never>?

    /// Shows what is already known about a file (from the analysis cache) without analysing it.
    func requestInfo(_ path: String) {
        guard info[path] == nil, !infoRequested.contains(path) else { return }
        infoRequested.insert(path)
        Task { [weak self] in
            let a = await Task.detached(priority: .utility) { AnalysisCache.shared.cached(path: path) }.value
            if let a { self?.info[path] = a }
        }
    }

    /// Analyses every file that has not been analysed yet, in the background; call again to stop.
    func analyzeLibrary(_ paths: [String]) {
        if let t = libraryTask { t.cancel(); libraryTask = nil; analysisProgress = nil; return }
        let todo = paths.filter { info[$0] == nil }
        guard !todo.isEmpty else { return }
        analysisProgress = (0, todo.count)
        libraryTask = Task { [weak self] in
            var done = 0
            for p in todo {
                if Task.isCancelled { break }
                let a = await Task.detached(priority: .utility) { AnalysisCache.shared.analysis(path: p) }.value
                done += 1
                guard let self else { return }
                if let a { self.info[p] = a }
                self.analysisProgress = (done, todo.count)
            }
            self?.libraryTask = nil; self?.analysisProgress = nil
        }
    }

    /// A file dropped on a deck (or on the console): its tags come from the library when it is in there, else its file name.
    func loadFile(_ url: URL, into d: DJDeck) {
        guard audioExtensions.contains(url.pathExtension.lowercased()) else { return }
        let known = LibraryModelBridge.shared.model?.store?.track(path: url.path)
        d.load(DJTrack(path: url.path, title: known?.title ?? url.deletingPathExtension().lastPathComponent, artist: known?.artistLine ?? "", album: known?.releaseTitle ?? ""))
    }

    /// Several dropped files go to the free deck and then the other one.
    func loadDropped(_ urls: [URL]) {
        let files = urls.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard let first = files.first else { return }
        let target = freeDeck()
        loadFile(first, into: target)
        if files.count > 1 { loadFile(files[1], into: other(target)) }
    }

    /// Loads into the deck that is not playing (deck A if neither is).
    func loadIntoFreeDeck(_ t: DJTrack) { load(t, into: freeDeck()) }

    func freeDeck() -> DJDeck {
        if !a.isLoaded { return a }
        if !b.isLoaded { return b }
        if a.playing && !b.playing { return b }
        if b.playing && !a.playing { return a }
        return a
    }
    func load(_ t: DJTrack, into d: DJDeck) { d.load(t) }

    // MARK: set list (Smart DJ)

    /// The songs Smart DJ chose, in order. The first two sit on the decks; the next one is loaded on whichever deck frees up.
    @Published private(set) var setList: [DJTrack] = []
    @Published private(set) var setNext = 0

    /// Puts a set on the table: track 1 on deck A, track 2 on deck B, crossfader on A. Nothing plays until the DJ presses play.
    func loadSet(_ tracks: [DJTrack]) {
        setList = tracks; setNext = 0
        a.unload(); b.unload()
        crossfader = -1
        if tracks.indices.contains(0) { a.load(tracks[0]); setNext = 1 }
        if tracks.indices.contains(1) { b.load(tracks[1]); setNext = 2 }
    }

    func startSet() { if a.isLoaded { crossfader = -1; a.play() } else if b.isLoaded { crossfader = 1; b.play() } }

    private func advanceSet() {
        guard setNext < setList.count else { return }
        for d in [a, b] where d.isLoaded && !d.playing && d.duration > 0 && d.position >= d.duration - 0.6 {
            d.load(setList[setNext]); setNext += 1
            return
        }
    }
}

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
    static let count = 8
    private static var enabled: Bool { ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil && ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil }
    static var overrideDefaults: UserDefaults?
    private static var defaults: UserDefaults { overrideDefaults ?? .standard }

    static func load(path: String) -> [Double?] {
        guard enabled || overrideDefaults != nil, let d = defaults.dictionary(forKey: key) as? [String: [Double]], let v = d[path], !v.isEmpty else { return Array(repeating: nil, count: count) }
        let padded = v + Array(repeating: -1, count: max(0, count - v.count))          // cues saved when there were four pads
        return padded.prefix(count).map { $0 < 0 ? nil : $0 }
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
    @Published private(set) var hotCues: [Double?] = Array(repeating: nil, count: HotCueStore.count)
    @Published private(set) var loopIn: Double?
    @Published private(set) var loopOut: Double?
    @Published private(set) var loopActive = false
    @Published private(set) var bending = 0.0

    // MARK: performance modes (the Pro console)
    /// Plays the track backwards.
    @Published var reverse = false { didSet { control.reverse = reverse; if reverse { slipBegin() } else { slipEnd() } } }
    /// Keeps the key when the pitch fader moves the tempo.
    @Published var keyLock = false { didSet { control.keyLock = keyLock } }
    /// Whole semitones the key is shifted by, without changing the tempo.
    @Published var keyShift = 0 { didSet { control.keyShift = Double(keyShift) } }
    /// While on, loops, reverse and scratching run on in the background: when they end the track is where it would have been.
    @Published var slip = false { didSet { if !slip { slipAnchor = nil } } }
    /// Whether dragging the disc scratches (otherwise it only nudges the tempo while playing).
    @Published var scratchEnabled = true
    /// Editing the beat grid: the disc and buttons move the grid instead of the track.
    @Published var gridEdit = false
    /// How far the grid has been moved by hand, in seconds.
    @Published private(set) var gridOffset = 0.0
    /// Keeps this deck's tempo locked to the master deck.
    @Published var syncOn = false
    @Published var isMaster = false
    @Published var padMode = PadMode.cues { didSet { padBank = 0 } }
    @Published var padBank = 0
    @Published private(set) var scratching = false
    /// 0 = no effect unit, 1…3 = the unit this channel listens to.
    @Published var fxUnit = 0 { didSet { onFX?() } }
    @Published private(set) var detail: DJWaveDetail?
    /// The loop size selected in the loop block, in beats.
    @Published var loopSize = 4.0
    var onFX: (() -> Void)?
    var onLoaded: ((DJTrack) -> Void)?
    private var fxSaved: (kind: DeckFXKind, on: Bool, wet: Double, param: Double)?
    private var detailTask: Task<Void, Never>?
    private var slipAnchor: (position: Double, at: Date)?

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

    /// Tempo as the track is used: the analysed one, halved or doubled when the analysis picked the wrong octave, or tapped in by hand.
    var bpm: Double? { manualBPM ?? analysis?.bpm.map { $0 * bpmScale } }
    @Published var manualBPM: Double? { didSet { refreshBPM() } }
    @Published var bpmScale = 1.0 { didSet { refreshBPM() } }
    private var taps: [Date] = []
    private func refreshBPM() { mix.params.bpm.value = Float(effectiveBPM ?? 0) }

    /// Tap the tempo: the average of the last few taps (a pause longer than two seconds starts over).
    func tap(now: Date = Date()) {
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps = [] }
        taps.append(now); taps = Array(taps.suffix(8))
        guard taps.count >= 3 else { return }
        let gaps = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        if mean > 0 { manualBPM = max(40, min(220, 60 / mean)) }
    }
    func resetBPM() { manualBPM = nil; bpmScale = 1; taps = [] }

    /// How the crossfader treats this deck.
    @Published var assign = CrossAssign.left { didSet { onMix?() } }
    private var killed: [String: Double] = [:]

    /// A kill switch: drops a band to nothing, and the next press puts it back where it was.
    func toggleKill(_ band: String) {
        func flip(_ v: Double, _ set: (Double) -> Void) {
            if v <= DJMath.eqRange.lowerBound + 0.5 { set(killed[band] ?? 0); killed[band] = nil }       // already cut: put it back (flat if it was never moved)
            else { killed[band] = v; set(DJMath.eqRange.lowerBound) }
        }
        switch band { case "low": flip(low) { low = $0 }; case "mid": flip(mid) { mid = $0 }; default: flip(high) { high = $0 } }
    }
    func isKilled(_ band: String) -> Bool { (band == "low" ? low : band == "mid" ? mid : high) <= DJMath.eqRange.lowerBound + 0.5 }
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
        detailTask?.cancel(); detail = nil
        track = t; analysis = nil; error = nil; position = 0; cue = 0; playing = false; pitch = 0; bend(0); lastTick = nil
        reverse = false; slipAnchor = nil; scratching = false; control.scratchOn = false; gridEdit = false
        gridOffset = GridStore.load(path: t.path)
        hotCues = HotCueStore.load(path: t.path)
        guard let f = try? openLossless(path: t.path) else { error = "Could not open this file"; track = nil; return }
        if f.info.sourceBits == 1 { error = "DSD files cannot be loaded on a deck"; track = nil; return }
        duration = f.info.duration
        player.settings = settings()
        player.setQueue([t.path])
        player.start(options: playerOptions(paused: true))
        onLoaded?(t)
        let wavePath = t.path
        detailTask = Task { [weak self] in
            let d = await Task.detached(priority: .utility) { DJWaveDetail.build(path: wavePath) }.value
            guard !Task.isCancelled, let self, self.track?.path == wavePath else { return }
            self.detail = d
        }
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
        analysisTask?.cancel(); detailTask?.cancel(); detail = nil; player.stop(); clearLoop(); track = nil; analysis = nil; playing = false; position = 0; duration = 0; hotCues = Array(repeating: nil, count: HotCueStore.count)
        reverse = false; slipAnchor = nil; scratching = false; control.scratchOn = false; gridOffset = 0; gridEdit = false; syncOn = false
        mix.params.fxOn.value = 0; fxOn = false; manualBPM = nil; bpmScale = 1; taps = []
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
    func snapped(_ t: Double) -> Double { quantize ? (gridBeat(near: t).map { max(0, $0) } ?? t) : t }

    /// The beat nearest to `t`, on the analysed grid (its first beat) at the tempo in use.
    func gridBeat(near t: Double) -> Double? {
        guard let bpm, bpm > 0, let fb = firstBeat else { return analysis?.nearestBeat(to: t) }
        let p = 60 / bpm
        return fb + ((t - fb) / p).rounded() * p
    }

    /// The first beat of the grid: the analysed one, moved by whatever the DJ has nudged it by.
    var firstBeat: Double? { analysis?.firstBeat.map { max(0, $0 + gridOffset) } }

    /// Moves the beat grid by `seconds` (negative = earlier) and remembers it for this track.
    func nudgeGrid(by seconds: Double) {
        guard track != nil, analysis?.firstBeat != nil else { return }
        gridOffset = max(-5, min(5, gridOffset + seconds))
        persistGrid()
    }
    /// Puts a beat of the grid at the playhead.
    func setGridHere() {
        guard let t = track, let fb = analysis?.firstBeat, let bpm, bpm > 0 else { return }
        let p = 60 / bpm
        let n = ((position - fb) / p).rounded()
        gridOffset = max(-5, min(5, position - (fb + n * p)))
        _ = t; persistGrid()
    }
    func resetGrid() { gridOffset = 0; persistGrid() }
    private func persistGrid() { if let p = track?.path { GridStore.save(path: p, offset: gridOffset) } }

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
        loopOut = b; slipBegin(); loopActive = true; applyLoop()
    }
    /// A loop of `beats` beats starting at the current position (on the beat grid when there is one).
    func autoLoop(beats: Double, snap: Bool = false) {
        guard track != nil else { return }
        let len = beats * (beatLength ?? 0.5)
        let a = snap ? (gridBeat(near: position).map { max(0, $0) } ?? position) : snapped(position)
        slipBegin()
        loopIn = a; loopOut = min(duration, a + len); loopActive = true; applyLoop()
    }
    func toggleLoop() {
        guard track != nil else { return }
        if loopActive { loopActive = false; applyLoop(); slipEnd(); return }
        if loopIn != nil, loopOut != nil { slipBegin(); loopActive = true; applyLoop() } else { autoLoop(beats: 4) }
    }
    func scaleLoop(_ f: Double) {
        guard let a = loopIn, let b = loopOut else { return }
        let len = max(0.03, min(duration - a, (b - a) * f))
        loopOut = a + len; applyLoop()
    }
    func clearLoop() { let was = loopActive; loopIn = nil; loopOut = nil; loopActive = false; control.clearLoop(); if was { slipEnd() } }
    /// Starts the loop again from its start, or from where it was last set.
    func reloop() { guard track != nil, loopIn != nil, loopOut != nil else { return }; if !loopActive { slipBegin(); loopActive = true; applyLoop() }; if let a = loopIn { seek(to: a) } }
    /// Moves the whole loop by its own length (negative = earlier).
    func moveLoop(by times: Double) {
        guard let a = loopIn, let b = loopOut, b > a else { return }
        let len = b - a, shift = max(-a, min(duration - b, times * len))
        loopIn = a + shift; loopOut = b + shift; applyLoop()
    }
    var loopBeats: Double? { guard let a = loopIn, let b = loopOut, let bl = beatLength else { return nil }; return (b - a) / bl }

    // MARK: pitch bend

    /// A momentary nudge (like pushing the jog wheel): +1 = 4 % faster, -1 = 4 % slower, 0 releases.
    func bend(_ x: Double) { bending = x; control.bend = x * 0.04 }

    // MARK: beat jump, loop roll, brake

    /// Moves the playhead by whole beats (negative = back).
    func beatJump(_ beats: Double) {
        guard track != nil, let bl = beatLength else { return }
        seek(to: position + beats * bl)
    }

    private var roll: (origin: Double, since: Date)?

    /// A loop that lasts only while the pad is held: on release the track carries on from where it would have been had it not been looped.
    func rollBegin(beats: Double) {
        guard track != nil, roll == nil else { return }
        roll = (position, Date())
        let len = beats * (beatLength ?? 0.5)
        loopIn = position; loopOut = min(duration, position + len); loopActive = true; applyLoop()
    }
    func rollEnd() {
        guard let r = roll else { return }
        roll = nil
        clearLoop()
        let speed = control.ratio * (1 + control.bend)
        seek(to: r.origin + Date().timeIntervalSince(r.since) * speed)
    }

    private var braking: Task<Void, Never>?

    /// Slows the deck to a stop, like pressing a turntable's brake, then pauses it and restores the speed.
    func brake(seconds: Double = 0.9) {
        guard playing, braking == nil else { return }
        let start = control.ratio
        braking = Task { [weak self] in
            let steps = 30
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(seconds / Double(steps) * 1e9))
                guard let self, !Task.isCancelled else { return }
                self.control.ratio = max(0.5, start * (1 - Double(i) / Double(steps)))
            }
            guard let self else { return }
            self.pause()
            self.control.ratio = 1 + self.pitch
            self.braking = nil
        }
    }
    func cancelBrake() { braking?.cancel(); braking = nil; control.ratio = 1 + pitch }

    /// Reads the engine's state (called ten times a second by the model).
    func refresh() {
        guard track != nil else { return }
        let st = player.status, now = Date()
        playing = st.state == .playing
        if st.finished && player.isRunning == false && st.state == .idle { playing = false }
        else if player.isRunning {
            // The engine reads ahead in chunks, so its figure steps; between looks the position is dead-reckoned at the current speed and gently
            // pulled toward the engine's figure, which keeps it smooth and prevents drift.
            let speed = control.effectiveSpeed
            let engine = max(0, min(duration, control.sourceFrame / deckRate - st.bufferedSeconds * speed))
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

    func shutdown() { analysisTask?.cancel(); detailTask?.cancel(); player.stop() }

    // MARK: slip, scratch, live readings

    /// With slip on, remembers where the track would be if nothing interrupted it.
    func slipBegin() { if slip, playing, slipAnchor == nil { slipAnchor = (position, Date()) } }
    /// Returns to where the track would have been.
    func slipEnd() {
        guard let a = slipAnchor else { return }
        slipAnchor = nil
        seek(to: a.position + Date().timeIntervalSince(a.at) * max(0.5, 1 + pitch))
    }
    var slipping: Bool { slipAnchor != nil }

    /// A loop-size button: engages a loop of that many beats, or leaves the loop when it is already that size.
    func loopSizePressed(_ beats: Double) {
        guard track != nil else { return }
        if loopActive, let b = loopBeats, abs(b - beats) < 0.05 { toggleLoop(); return }
        loopSize = beats; autoLoop(beats: beats)
    }

    /// An effect pad held down: the preset replaces the deck's effect until it is let go.
    func fxPadDown(_ p: DJPadSets.FXPreset) {
        if fxSaved == nil { fxSaved = (fxKind, fxOn, fxWet, fxParam) }
        fxKind = p.kind; fxWet = p.wet; fxParam = p.param; fxOn = true
    }
    func fxPadUp() {
        guard let s = fxSaved else { return }
        fxSaved = nil
        fxKind = s.kind; fxWet = s.wet; fxParam = s.param; fxOn = s.on
    }

    /// The start of slice `index` of bank `bank`: eight one-beat slices of an eight-beat stretch, four banks to a 32-beat phrase of the grid.
    func sliceTime(bank: Int, index: Int) -> Double? {
        guard let bl = beatLength, let fb = firstBeat else { return nil }
        let beat = Int(((position - fb) / bl).rounded(.down))
        let phrase = max(0, beat) / 32
        return fb + Double(phrase * 32 + bank * 8 + index) * bl
    }
    func sliceDown(bank: Int, index: Int) {
        guard track != nil, let t = sliceTime(bank: bank, index: index) else { return }
        slipBegin(); seek(to: min(t, max(0, duration - 0.2))); if !playing { play() }
    }
    func sliceUp() { slipEnd() }

    /// A hand on the disc. While playing, the track follows the hand's speed; while stopped, the playhead follows the hand (a scrub).
    func scratchBegin() {
        guard track != nil, !scratching else { return }
        scratching = true
        slipBegin()
        if playing { control.scratchSpeed = 0; control.scratchOn = true }
    }
    func scratchMove(speed: Double, deltaSeconds: Double) {
        guard scratching else { return }
        if playing || control.scratchOn { control.scratchSpeed = speed }
        else { seek(to: position + deltaSeconds) }
    }
    func scratchEnd() {
        guard scratching else { return }
        scratching = false
        let wasScratching = control.scratchOn
        control.scratchOn = false
        if wasScratching { trustEngineAfter = Date().addingTimeInterval(0.2) }
        slipEnd()
    }

    /// The position at a moment, carried forward at the current speed from the last reading: smooth enough to draw at the display's rate.
    func livePosition(at now: Date = Date()) -> Double {
        guard playing, let last = lastTick else { return position }
        return max(0, min(duration, position + now.timeIntervalSince(last) * control.effectiveSpeed))
    }
    var livePeak: (l: Float, r: Float) { (mix.peakL.value, mix.peakR.value) }
    var remaining: Double { max(0, (duration - position) / max(0.5, abs(1 + pitch))) }
}

/// Which side of the crossfader a channel is on: left, right, or straight through (not affected by it).
enum CrossAssign: String, CaseIterable, Identifiable { case left, thru, right
    var id: String { rawValue }
    var title: String { switch self { case .left: "A"; case .thru: "THRU"; case .right: "B" } } }

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
    /// Which parts of the console are shown (see `DJLayout`).
    @Published var layout = DJLayout.load() { didSet { if layout != oldValue { layout.save() } } }

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
    @Published var outputError: String?

    // recording
    @Published private(set) var recording = false
    @Published private(set) var recordingURL: URL?
    @Published private(set) var recordedSeconds = 0.0
    private var tap: RecorderTap?

    private(set) var core = DJMixerCore(sampleRate: 48_000)
    var outputs: [DJOutput] = []
    private var cueRing: FloatRing?
    private var timer: Timer?
    private var options = PlayerOptions()
    private(set) var rate = 48_000.0
    /// Tests and snapshots replace the real device output.
    var outputFactory: ((DJMixerCore) -> DJOutput?)?
    lazy var remix = RemixController(model: self)
    /// The language model that picks songs from a spoken request. Only in memory while it is switched on.

    // MARK: Pro console state
    @Published var preset = DJLayoutPreset.load() { didSet { if preset != oldValue { preset.save() } } }
    /// The three shared effect units; a channel is assigned to one of them.
    let fxUnits = [DJFXUnit(index: 1, kind: .echo), DJFXUnit(index: 2, kind: .reverb), DJFXUnit(index: 3, kind: .flanger)]
    /// The microphone and auxiliary channels.
    private(set) lazy var mic = DJLineChannel(name: "MIC", mix: core.mic, defaultFader: 0)
    private(set) lazy var aux = DJLineChannel(name: "AUX", mix: core.aux, defaultFader: 0.8)
    @Published var inputDevices: [InputDeviceInfo] = []
    /// The deck whose tempo the others follow.
    @Published var masterName: String?
    @Published var boothLevel = 0.7 { didSet { core.boothLevel.value = Float(boothLevel) } }
    @Published var boothRoute = CueRoute.none { didSet { if active && oldValue != boothRoute { restartOutputs() } } }
    /// What each sampler slot holds (name and length in seconds), nil when empty.
    @Published var sampleSlots: [(name: String, seconds: Double)?] = Array(repeating: nil, count: DJSampler.slots)
    @Published var samplerLevel = 0.9 { didSet { core.sampler.level.value = Float(samplerLevel) } }
    var sampleData: [SampleData?] = Array(repeating: nil, count: DJSampler.slots)
    var sampleNames: [Int: String] = [:]
    /// When each track was last put on a deck (seconds since 1970).
    @Published var history: [String: Double] = DJModel.loadHistory()
    var boothRing: FloatRing?

    init() {
        b.assign = .right
        a.onMix = { [weak self] in self?.applyMix() }
        b.onMix = { [weak self] in self?.applyMix() }
        a.onFX = { [weak self] in self?.applyFX() }
        b.onFX = { [weak self] in self?.applyFX() }
        for u in fxUnits { u.changed = { [weak self] in self?.applyFX() } }
        mic.onMix = { [weak self] in
            guard let self else { return }
            self.applyMix()
            if self.active, self.mic.channel > 0, !self.mic.running, self.mic.error == nil { self.startLineInputs() }
        }
        aux.onMix = { [weak self] in self?.applyMix() }
        a.onLoaded = { [weak self] t in self?.noteLoaded(t) }; b.onLoaded = { [weak self] t in self?.noteLoaded(t) }
        mic.onFX = { [weak self] in self?.applyFX() }; aux.onFX = { [weak self] in self?.applyFX() }
        mic.restart = { [weak self] in self?.startLineInputs() }; aux.restart = { [weak self] in self?.startLineInputs() }
        applyMix()
    }

    var decks: [DJDeck] { [a, b] }

    /// Mixes the two decks' output levels: channel fader × crossfader.
    func applyMix() {
        let g = curve.gains(crossfaderReverse ? -crossfader : crossfader)
        func gain(_ d: DJDeck) -> Double { d.assign == .left ? g.a : d.assign == .right ? g.b : 1 }
        a.mix.gain.value = Float(DJMath.channelGain(a.channel) * gain(a))
        b.mix.gain.value = Float(DJMath.channelGain(b.channel) * gain(b))
        mic.mix.gain.value = Float(DJMath.channelGain(mic.channel)); aux.mix.gain.value = Float(DJMath.channelGain(aux.channel))
    }

    /// Flips the crossfader's direction (a "hamster" switch).
    @Published var crossfaderReverse = false { didSet { applyMix() } }
    @Published private(set) var autoMixProgress: Double?
    private var autoMixTask: Task<Void, Never>?

    /// Brings in the idle deck at the playing deck's tempo and slides the crossfader across over `seconds`; the old deck is stopped at the end.
    func autoMix(seconds: Double) {
        guard autoMixTask == nil else { return }
        let toB = crossfader <= 0
        let incoming = toB ? b : a, outgoing = toB ? a : b
        guard incoming.isLoaded else { outputError = "Load a track on deck \(incoming.name) first"; return }
        if incoming.bpm != nil, outgoing.bpm != nil { sync(incoming) }
        if !incoming.playing { incoming.play() }
        let from = crossfader, to = toB ? 1.0 : -1.0
        autoMixTask = Task { [weak self] in
            let steps = max(1, Int(seconds * 30))
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(1e9 / 30))
                guard let self, !Task.isCancelled else { return }
                let t = Double(i) / Double(steps)
                self.crossfader = from + (to - from) * (t * t * (3 - 2 * t))         // eases in and out
                self.autoMixProgress = t
            }
            guard let self else { return }
            outgoing.pause()
            self.autoMixProgress = nil; self.autoMixTask = nil
        }
    }
    func cancelAutoMix() { autoMixTask?.cancel(); autoMixTask = nil; autoMixProgress = nil }

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
        c.boothLevel.value = Float(boothLevel); c.sampler.level.value = Float(samplerLevel)
        for (i, d) in sampleData.enumerated() { c.sampler.load(d, slot: i) }
        core = c
        a.attach(c.a, rate: rate); b.attach(c.b, rate: rate)
        mic.attach(c.mic); aux.attach(c.aux)
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
        startBooth()
        startLineInputs()
    }

    private func stopOutputs() { core.booth.publish(nil); boothRing = nil; mic.stop(); aux.stop(); outputs.forEach { $0.stop() }; outputs = []; cueRing = nil }
    func restartOutputs() { startOutputs() }

    func exit() {
        guard active else { return }
        active = false
        remix.enabled = false
        stopRecording()
        timer?.invalidate(); timer = nil
        for d in decks { d.unload(); d.player.analysis.setActive(false) }
        masterName = nil
        stopOutputs()
    }

    /// Ten times a second: the decks, the meters, the recording clock.
    func tick() {
        decks.forEach { $0.refresh() }
        followMaster()
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
}

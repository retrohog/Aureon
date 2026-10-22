// Player: controllable, queue-aware playback engine.
//
//   file ─► decode (FLAC/ALAC/PCM via CoreAudio · DSF/DFF → DoP or PCM)
//        ─► [RAM cache] ─► [resample] ─► [ReplayGain] ─► [polarity] ─► [DoP marker]      (producer thread)
//        ─► lock-free ring ─► Renderer (direct, or DSP via AVAudioEngine manual rendering) ─► sink / DAC
//
// One engine thread decodes ahead into the ring; the sink's real-time callback drains it. The queue is a list of
// stable IDs that can be edited at any time: the engine reconciles against the queue version and, when the next
// track is already buffered, truncates the ring tail so the audible track is never disturbed.

import Foundation
import CoreAudio
import AudioToolbox
import Synchronization
import AVFoundation

struct QueueEntry: Identifiable, Equatable {
    let id: UUID
    var path: String
    init(id: UUID = UUID(), path: String) { self.id = id; self.path = path }
}

enum RepeatMode: Int, Codable, CaseIterable {
    case off, all, one
}

enum PlayerCommand {
    case togglePause
    case setPaused(Bool)
    case seekBy(Double)              // seconds, relative
    case seekTo(Double)              // seconds, absolute within the current track
    case next, previous
    case jump(UUID)
    case stop
}

struct PlayerStatus {
    enum State { case idle, loading, playing, paused }
    var state: State = .idle
    var trackID: UUID?
    var trackIndex = 0
    var position = 0.0
    var duration = 0.0
    var info: StreamInfo?            // what is being delivered to the device
    var sourceInfo: StreamInfo?      // what the file contains
    var pipeline: [String] = []      // processing stages in use for the audible track
    var pathLines: [String] = []     // device negotiation report
    var bitPerfect = false           // device accepts the stream natively AND no stage altered the samples
    var transparentStream = true
    var replayGainDB: Double?
    var underruns = 0
    var bufferedSeconds = 0.0
    var loadProgress: Double?        // RAM preload progress while loading
    var ramBytes = 0
    var dspActive = false
    var dspSummary: String?
    var engineThreadPromoted = false
    var rtStages: [String] = []      // real-time processors in use (convolution, crossfeed, headphone EQ)
    var live: LiveMetadata.Snapshot? // station, bit rate and current title while a radio stream plays
    var rtLatencyFrames = 0
    var mixProgress: Double?         // 0…1 while two tracks overlap in a transition, else nil
    var mixingInto: UUID?            // the track being faded in during that overlap
    var deviceName = ""
    var finished = false
    var errors: [String] = []
}

final class Player: @unchecked Sendable {
    private let lock = NSLock()
    private var _status = PlayerStatus()
    private var commands: [PlayerCommand] = []
    private var entries: [QueueEntry] = []
    private var queueVersion = 0
    private var _settings = PlaybackSettings()
    private var settingsVersion = 0
    private var _plugins: [AVAudioUnit] = []
    private var pluginsVersion = 0
    private var thread: Thread?
    private let stopFlag = Atomic<Bool>(false)
    private let underruns = Counter()
    private let done = DispatchSemaphore(value: 0)
    private var userPaused = false           // engine thread only
    /// DJ decks: pitch control and output level, set before `start`.
    var varispeed: VarispeedControl?
    var deckGain: DeckGain?
    private var heardIndexHint = 0           // engine thread only
    private var sinkFixedRate: Double?       // engine thread only: the one rate the current sink accepts, if it has just one
    private var sinkChannels = 0             // engine thread only: output channels of the current sink (0 = unconstrained)
    private var _repeat = RepeatMode.off
    /// The oversampling filter wanted by the resamplers in the open chains; changed while playing without rebuilding them.
    private let filterSwitch = FilterSwitch(.standard)

    let dsp = DSPChain()
    let replayGain = ReplayGainStore()
    let cache = TrackCache(budgetBytes: 1 << 30)
    let analysisTap = AnalysisTap()
    /// The AI enhancer for lossy streams (switched in the Intelligence settings). Tests substitute their own before `start`.
    lazy var upscaler: NeuralUpscaler = { NeuralUpscaler.shared.observeSettings(); return .shared }()
    /// How much audio is queued for the device: tells the enhancer how long it may wait for a block.
    let playoutGauge = PlayoutGauge()
    private let rtQueue = DispatchQueue(label: "aureon.rtbuild", qos: .userInitiated)
    private let rtGeneration = Atomic<Int>(0)
    private var irCache: [String: PreparedIR] = [:]
    private let irLock = NSLock()
    private(set) lazy var analysis = AnalysisEngine(tap: analysisTap)
    /// How tracks start and end (silence, edge loudness, fade-outs), for transitions.
    var edges = EdgeCache.shared
    /// Which album a file belongs to, for "keep albums gapless". Default: its folder.
    var albumKey: (String) -> String? = AlbumKey.folder

    // MARK: public state

    var status: PlayerStatus { lock.lock(); defer { lock.unlock() }; return _status }
    var isRunning: Bool { thread != nil && !status.finished }
    var queue: [QueueEntry] { lock.lock(); defer { lock.unlock() }; return entries }
    /// Bumped on every queue / settings change (including local ones), so a remote server can tell when to broadcast.
    var queueRevision: Int { lock.lock(); defer { lock.unlock() }; return queueVersion }
    var settingsRevision: Int { lock.lock(); defer { lock.unlock() }; return settingsVersion }

    var settings: PlaybackSettings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); if newValue != _settings { _settings = newValue; settingsVersion += 1 }; lock.unlock() }
    }

    /// Hosted Audio Unit effects, in signal order. Applied on the engine thread (never while the audio thread is rendering them).
    var plugins: [AVAudioUnit] { lock.lock(); defer { lock.unlock() }; return _plugins }
    func setPlugins(_ units: [AVAudioUnit]) { lock.lock(); _plugins = units; pluginsVersion += 1; lock.unlock() }

    /// What happens at the end of the queue (all) or of a track (one). Takes effect at the next track boundary.
    var repeatMode: RepeatMode {
        get { lock.lock(); defer { lock.unlock() }; return _repeat }
        set { lock.lock(); _repeat = newValue; lock.unlock() }
    }

    func send(_ c: PlayerCommand) { lock.lock(); commands.append(c); lock.unlock() }

    // MARK: queue editing (safe at any time, including during playback)

    @discardableResult func setQueue(_ paths: [String]) -> [QueueEntry] {
        let new = paths.map { QueueEntry(path: $0) }
        lock.lock(); entries = new; queueVersion += 1; lock.unlock()
        return new
    }
    @discardableResult func append(_ paths: [String]) -> [QueueEntry] { insert(paths, at: nil) }
    @discardableResult func insert(_ paths: [String], at index: Int?) -> [QueueEntry] {
        let new = paths.map { QueueEntry(path: $0) }
        lock.lock(); entries.insert(contentsOf: new, at: min(max(0, index ?? entries.count), entries.count)); queueVersion += 1; lock.unlock()
        return new
    }
    func remove(ids: Set<UUID>) {
        lock.lock(); entries.removeAll { ids.contains($0.id) }; queueVersion += 1; lock.unlock()
    }
    /// Moves the entries at `source` to before position `destination` (SwiftUI `onMove` semantics).
    func move(from source: IndexSet, to destination: Int) {
        lock.lock()
        let moving = source.map { entries[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) { entries.remove(at: i) }
        entries.insert(contentsOf: moving, at: max(0, min(destination - before, entries.count)))
        queueVersion += 1; lock.unlock()
    }
    /// Replaces the whole queue and starts playing entry `index`, in one step: the running engine just jumps (no teardown of the output device).
    @discardableResult
    func replace(with paths: [String], startAt index: Int) -> [QueueEntry] {
        let new = paths.map { QueueEntry(path: $0) }
        lock.lock()
        entries = new; queueVersion += 1
        if new.indices.contains(index) { commands.append(.jump(new[index].id)) }
        lock.unlock()
        return new
    }

    func clearQueue() { lock.lock(); entries = []; queueVersion += 1; lock.unlock() }

    /// Puts the queue in this order (ids that are not in `ids` keep their relative order at the end). Safe during playback: the engine reconciles it like any edit.
    func setOrder(_ ids: [UUID]) {
        lock.lock()
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [QueueEntry] = [], seen = Set<UUID>()
        for id in ids { if let e = byID[id], seen.insert(id).inserted { out.append(e) } }
        for e in entries where !seen.contains(e.id) { out.append(e) }
        if out.map(\.id) != entries.map(\.id) { entries = out; queueVersion += 1 }
        lock.unlock()
    }

    // MARK: lifecycle

    func start(startID: UUID? = nil, startSeconds: Double = 0, options: PlayerOptions) {
        stop()
        stopFlag.store(false, ordering: .relaxed)
        lock.lock(); _status = PlayerStatus(); commands = []; lock.unlock()
        underruns.n.store(0, ordering: .relaxed)
        userPaused = options.startPaused
        let t = Thread { [self] in
            run(startID: startID, startSeconds: startSeconds, options: options)
            done.signal()
        }
        t.name = "aureon.engine"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops playback, restores the device and waits for the engine thread.
    func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .relaxed)
        done.wait()
        thread = nil
    }

    /// Blocks until playback ends (tests).
    func waitUntilFinished(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if status.finished { return true }; usleep(5_000) }
        return status.finished
    }

    private func update(_ f: (inout PlayerStatus) -> Void) { lock.lock(); f(&_status); lock.unlock() }
    private func drainCommands() -> [PlayerCommand] { lock.lock(); defer { lock.unlock() }; let c = commands; commands = []; return c }
    private func snapshot() -> (version: Int, entries: [QueueEntry], settings: PlaybackSettings, settingsVersion: Int, plugins: [AVAudioUnit], pluginsVersion: Int) {
        lock.lock(); defer { lock.unlock() }; return (queueVersion, entries, _settings, settingsVersion, _plugins, pluginsVersion)
    }
    private func note(_ e: String) { update { if !$0.errors.contains(e) { $0.errors.append(e) } } }

    // MARK: engine thread

    private enum GroupExit { case finished; case continueAt(UUID, seconds: Double) }

    private func run(startID: UUID?, startSeconds: Double, options: PlayerOptions) {
        guard let sink: AudioSink = options.sinkFactory?(options) ?? CoreAudioSink(deviceID: options.deviceID) else {
            update { $0.errors.append("no output device"); $0.finished = true }
            return
        }
        update { $0.deviceName = sink.deviceName }
        sinkChannels = sink.outputChannels
        sinkFixedRate = sink.fixedRate
        if options.promoteEngineThread { let ok = RealtimeThread.promoteCurrentThread(); update { $0.engineThreadPromoted = ok } }
        if let u = options.ioCycleUsage, let cs = sink as? CoreAudioSink { cs.device.setIOCycleUsage(u) }
        options.tuning?.playbackWillStart()
        defer { dsp.teardown(); sink.shutdown(); options.tuning?.playbackDidEnd(); update { $0.state = .idle; $0.finished = true; $0.dspActive = false } }

        var next: UUID? = startID ?? snapshot().entries.first?.id
        var seconds = startSeconds
        while let id = next, !stopFlag.load(ordering: .relaxed) {
            do {
                switch try playGroup(startID: id, startSeconds: seconds, sink: sink, options: options) {
                case .finished: next = nil
                case .continueAt(let n, let s): next = n; seconds = s
                }
            } catch {
                let q = snapshot().entries
                note("\(((q.first { $0.id == id }?.path ?? "") as NSString).lastPathComponent): \(error.localizedDescription)")
                guard let i = q.firstIndex(where: { $0.id == id }), i + 1 < q.count else { break }
                next = q[i + 1].id; seconds = 0
            }
        }
    }

    // MARK: opening a track (builds the whole ingestion chain)

    private struct Opened {
        var source: FrameSource; var raw: StreamInfo; var stages: [String]; var gainDB: Double?; var live: LiveMetadata? = nil; var neural = false
        /// Index in `stages` of the resampler's line, and the rates it converts between, so the line can be rewritten when the filter is changed.
        var filterLine: Int? = nil; var filterRates: (from: Double, to: Double) = (0, 0)
    }

    private static func resampleLine(from: Double, to: Double, _ c: ResamplerConfig) -> String {
        let f = OversamplingFilter(c)
        return "Resample \(Int(from)) → \(Int(to)) Hz, \(f.title.lowercased()) filter" + (f.adjustable ? ", \(Int(c.effectiveStopbandDB)) dB stop-band" : ", \(Int(c.effectiveStopbandDB)) dB")
    }

    private struct DecodePlan { var base: FrameSource; var raw: StreamInfo; var key: String; var isDoP: Bool; var stages: [String]; var live: LiveMetadata? = nil }

    static func layoutName(_ n: Int) -> String {
        switch n { case 1: "mono"; case 2: "stereo"; case 3: "3.0"; case 4: "quad"; case 5: "5.0"; case 6: "5.1"; case 7: "6.1"; case 8: "7.1"; default: "\(n) ch" }
    }

    static func isStreamURL(_ path: String) -> Bool { path.hasPrefix("http://") || path.hasPrefix("https://") }

    /// Starts loading the start of the next queued cloud track while this one plays, so the switch needs no network round trip.
    private func warmNeighbour(of path: String) {
        let q = snapshot().entries
        if let i = q.firstIndex(where: { $0.path == path }), q.indices.contains(i + 1), RemoteMedia.isRemote(q[i + 1].path) { RemoteMedia.warm(q[i + 1].path) }
    }

    private func nearest(_ rate: Double, in rates: [Double]) -> Bool { rates.contains { abs($0 - rate) < 0.5 } }

    private func decodePlan(path: String, settings s: PlaybackSettings, rates: [Double]) throws -> DecodePlan {
        if Self.isStreamURL(path) {
            guard let url = URL(string: path) else { throw AureonError.message("bad stream address") }
            let r = try RadioSource(url: url)
            let br = r.live.snapshot.bitrate.map { ", \($0) kbps" } ?? ""
            return DecodePlan(base: r, raw: r.info, key: path, isDoP: false, stages: ["Internet radio: \(r.live.snapshot.codec ?? "stream")\(br), lossy"], live: r.live)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "dsf" || ext == "dff" else {
            let f = try openLossless(path: path)
            var stages: [String] = []
            if RemoteMedia.isRemote(path) {
                stages.append("Streamed from \(SubsonicPath.isSubsonic(path) || LMSPath.isLMS(path) ? "your music server" : "cloud storage"), in \(CloudRegistry.shared.playbackConfig.chunkSize >> 20) MB pieces, read ahead of the playhead")
                warmNeighbour(of: path)
            }
            if !f.info.transparent { stages.append("Lossy source: not bit-perfect by definition") }
            return DecodePlan(base: f, raw: f.info, key: path + "|pcm", isDoP: false, stages: stages)
        }
        let file = try DsdContainer(path: path)
        let codec = dsdRateName(file.dsdRate)
        let raw = StreamInfo(sampleRate: file.dsdRate, channels: file.channels, sourceBits: 1, totalFrames: Int64(file.totalBits), codec: codec)
        var stages: [String] = []
        var mode = s.dsd.mode
        let dopRate = file.dsdRate / 16
        if mode == .dop && sinkChannels > 0 && file.channels > sinkChannels {
            mode = .pcm; stages.append("Device has \(sinkChannels) outputs for \(file.channels) DSD channels: converting to PCM so it can be mixed down")
        }
        if mode == .dop && !rates.isEmpty && !nearest(dopRate, in: rates) {
            mode = .pcm; stages.append("Device cannot run DoP at \(Int(dopRate)) Hz: converting to PCM instead")
        }
        if mode == .dop {
            stages.append("\(codec) → DoP at \(Int(dopRate)) Hz (DSD bits untouched)")
            return DecodePlan(base: DoPSource(file, codec: codec), raw: raw, key: path + "|dop", isDoP: true, stages: stages)
        }
        let candidates = [s.dsd.pcmRate, 176_400, 88_200, 352_800, 44_100].filter { r in
            let k = file.dsdRate / r; return k >= 8 && abs(k - k.rounded()) < 1e-9 && Int(k) % 8 == 0
        }
        let prof = PerformanceProfile.ready
        let playable = candidates.filter { r in rates.isEmpty || nearest(r, in: rates) }
        var pick = playable.first ?? candidates.first
        if let p = pick, !prof.canDecodeDSD(rate: file.dsdRate, channels: file.channels) || !prof.canResample(to: p, channels: file.channels) {
            // too heavy for this Mac at that rate: take the lowest sustainable one, never below the smallest available
            let lighter = playable.filter { prof.canResample(to: $0, channels: file.channels) }.sorted()
            if let l = lighter.last, l < p, prof.canDecodeDSD(rate: file.dsdRate, channels: file.channels) { pick = l; stages.append("\(codec) → PCM limited to \(formatRate(l)): this Mac cannot sustain \(formatRate(p)) in real time") }
            else if !prof.canDecodeDSD(rate: file.dsdRate, channels: file.channels) { stages.append("\(codec) is heavy for this Mac (\(String(format: "%.1f", prof.dsdFactor(dsdRate: file.dsdRate, channels: file.channels)))× real time): expect dropouts; a larger buffer is used") }
        }
        guard let target = pick,
              let src = DsdToPcm.make(file, codec: codec, pcmRate: target, gainDB: s.dsd.gainDB) else {
            throw AureonError.message("cannot convert \(codec) to PCM")
        }
        stages.append("\(codec) → PCM \(Int(target)) Hz (" + (src is FastDsdToPcmSource ? "multi-stage FIR decimation" : "FIR decimation") + ")")
        return DecodePlan(base: src, raw: raw, key: path + "|pcm|\(Int(target))|\(s.dsd.gainDB)", isDoP: false, stages: stages)
    }

    private func openTrack(_ entry: QueueEntry, settings s: PlaybackSettings, rates: [Double], clock: DoPClock,
                           loadRAMNow: Bool, progress: ((Double) -> Void)? = nil) throws -> Opened {
        var plan = try decodePlan(path: entry.path, settings: s, rates: rates)
        var base = plan.base
        var stages = plan.stages

        let isLive = plan.raw.isLive
        if s.ram.enabled && !isLive {
            cache.budgetBytes = s.ram.budgetMB << 20
            if let m = cache.get(plan.key) {
                base = MemorySource(m); stages.append("RAM: preloaded, no disk reads")
            } else if loadRAMNow {
                if let m = MemoryTrack.load(from: base, budgetBytes: cache.budgetBytes, progress: progress, cancelled: { self.stopFlag.load(ordering: .relaxed) }) {
                    cache.put(plan.key, m); base = MemorySource(m); stages.append("RAM: loaded before playback")
                } else { stages.append("RAM: track exceeds the \(s.ram.budgetMB) MB budget, streaming from disk") }
            } else { stages.append("RAM: not preloaded yet, streaming from disk") }
            plan.base = base
        }

        var chain: FrameSource = base
        var gainDB: Double?
        // multichannel: play every channel the device has an output for; mix down only when it has not (or when the user asks for stereo)
        if !plan.isDoP, chain.info.channels > 2 || s.multichannel.mode == .stereo, let target = Downmix.target(sourceChannels: chain.info.channels, deviceChannels: sinkChannels, mode: s.multichannel.mode) {
            let from = chain.info.channels
            chain = DownmixSource(chain, target: target, includeLFE: s.multichannel.includeLFE)
            stages.append("Downmix \(Self.layoutName(from)) → \(target.count == 1 ? "mono" : target.count == 2 ? "stereo" : Self.layoutName(target.count)) (ITU-R BS.775\(s.multichannel.includeLFE ? ", LFE included" : ", LFE left out"))")
        } else if chain.info.channels > 2 {
            stages.append("\(Self.layoutName(chain.info.channels)) (\(chain.info.channels) channels) played directly, no processing")
        }
        var neural = false
        var filterLine: Int?, filterRates = (from: 0.0, to: 0.0)
        if plan.isDoP {
            if s.upsampling.mode != .off || s.replayGain.mode != .off || s.polarityInverted {
                stages.append("Upsampling, ReplayGain and polarity are bypassed for DoP")
            }
            chain = DoPStampSource(chain, clock: clock)
        } else {
            // AI enhancer (lossy sources only): sinc to the model's rate, the model, then on to the device rate below
            if let n = upscaler.makeNode(upstream: chain, raw: plan.raw, deckRate: s.deckRate, gauge: playoutGauge) {
                chain = n.source; stages += n.stages; neural = true
            }
            filterSwitch.request(s.upsampling.filter)
            let filterCost = s.upsampling.filter.costFactor
            // PCM → DSD for a DAC that takes DoP: the music goes to 16 × the base rate (32 × for DSD512) with the chosen filter, and is then
            // interpolated and modulated to DSD below. Radio, DJ decks and fixed-rate outputs are left alone.
            var dsdPlan: DSDOutputPlan?
            if s.dsdOutput.enabled, s.dsd.mode == .dop, !isLive, s.deckRate == nil, sinkFixedRate == nil {
                let r = DSDOutputPlanner.plan(settings: s.dsdOutput, sourceRate: chain.info.sampleRate, channels: chain.info.channels, deviceRates: rates,
                                              profile: PerformanceProfile.ready, filterCost: filterCost)
                dsdPlan = r.plan
                if let n = r.note { stages.append(n) }
            }
            // sample rate
            let rate = chain.info.sampleRate
            var target = upsamplingTarget(source: rate, mode: s.upsampling.mode, deviceRates: rates, maxRate: s.upsampling.maxRate)
            if let dr = s.deckRate { target = abs(rate - dr) < 0.5 ? nil : dr }
            if isLive, s.radio.upscale, !rates.isEmpty, s.deckRate == nil {
                target = upsamplingTarget(source: rate, mode: .deviceMax, deviceRates: rates, maxRate: s.radio.maxRate)
                if target == nil, !nearest(rate, in: rates) { target = fitRate(source: rate, deviceRates: rates) }
            }
            if target == nil, s.upsampling.downsampleToFit, !rates.isEmpty, !nearest(rate, in: rates) { target = fitRate(source: rate, deviceRates: rates) }
            // keep the request inside what this Mac can resample in real time, with headroom
            if let t = target, t > rate, dsdPlan == nil {
                let prof = PerformanceProfile.ready, ch = chain.info.channels
                if !prof.canResample(to: t, channels: ch, cost: filterCost) {
                    var c = prof.capped(t, channels: ch, floor: rate, cost: filterCost)
                    // the cap must still be a rate the device offers
                    if !rates.isEmpty { c = rates.filter { $0 <= c + 0.5 && $0 > rate + 0.5 }.max() ?? rate }
                    stages.append("Upsampling to \(formatRate(t)) is too heavy for this Mac in real time (\(String(format: "%.1f", prof.resampleFactor(rate: t, channels: ch, cost: filterCost)))×): using \(c > rate ? formatRate(c) : "the native rate") instead")
                    target = c > rate ? c : nil
                }
            }
            if let fr = sinkFixedRate, s.deckRate == nil {
                target = abs(rate - fr) < 0.5 ? nil : fr
                if target != nil { stages.append("This output takes only \(formatRate(fr)): resampling") }
            }
            if s.upsampling.mode != .off && target == nil && sinkFixedRate == nil && dsdPlan == nil {
                stages.append("Upsampling: no suitable device rate above \(Int(rate)) Hz, keeping native rate")
            }
            if let p = dsdPlan { target = abs(rate - p.intermediateRate) < 0.5 ? nil : p.intermediateRate }
            if let t = target {
                if let r = ResamplingSource(chain, outRate: t, config: s.upsampling.filter, control: filterSwitch) {
                    chain = r
                    stages.append(Self.resampleLine(from: rate, to: t, s.upsampling.filter))
                    filterLine = stages.count - 1; filterRates = (rate, t)
                } else if dsdPlan != nil {
                    dsdPlan = nil
                    stages.append("Conversion to DSD: \(Int(rate)) Hz cannot be brought to \(Int(t)) Hz here, so the music is sent as PCM")
                }
            }
            // ReplayGain
            if s.replayGain.mode != .off && !isLive {
                let r = replayGain.resolve(path: entry.path, settings: s.replayGain, allowMeasuring: loadRAMNow)
                if r.linear != 1 {
                    chain = GainSource(chain, gain: r.linear); gainDB = r.appliedDB
                    stages.append(String(format: "ReplayGain %+.2f dB (%@%@)", r.appliedDB, r.origin, r.limitedByPeak ? ", limited by peak" : ""))
                } else { stages.append("ReplayGain: none applied (\(r.origin == "none" ? "no tag, no measurement" : "0 dB"))") }
            }
            if s.polarityInverted { chain = InvertSource(chain); stages.append("Polarity inverted") }
            if let v = varispeed { chain = VarispeedSource(chain, control: v); stages.append("Pitch control") }
            if let p = dsdPlan {
                if let d = PCMToDSDSource(chain, plan: p) {
                    chain = DoPStampSource(d, clock: clock)
                    stages.append("PCM → \(p.rate.name): \(p.order.title) one-bit modulator at \(formatRate(p.dsdRate)), sent as \(formatRate(p.carrier)) DoP")
                } else {
                    stages.append("Conversion to DSD: the stream could not be set up, so the music is sent as PCM")
                }
            }
        }
        return Opened(source: chain, raw: plan.raw, stages: stages, gainDB: gainDB, live: plan.live, neural: neural, filterLine: filterLine, filterRates: filterRates)
    }

    /// Decodes upcoming tracks into RAM (and warms ReplayGain data) on a background queue.
    private func prefetch(after id: UUID, heard: UUID, settings s: PlaybackSettings, rates: [Double]) {
        let q = snapshot().entries
        guard let i = q.firstIndex(where: { $0.id == id }) else { return }
        let upcoming = Array(q[(i + 1)..<min(i + 3, q.count)]).filter { !Self.isStreamURL($0.path) }
        replayGain.prefetch(paths: upcoming.map(\.path), settings: s.replayGain)
        if s.transition.mode != .off { edges.prefetch(paths: ([q[i]] + upcoming).map(\.path)) }
        guard s.ram.enabled else { cache.clear(); return }
        let keepPaths = Set(([q[i]] + upcoming).map(\.path))
        cache.retain(onlyPaths: keepPaths)
        for e in upcoming {
            DispatchQueue.global(qos: .utility).async { [self] in
                guard let plan = try? decodePlan(path: e.path, settings: s, rates: rates), cache.beginPrefetch(plan.key) else { return }
                defer { cache.endPrefetch(plan.key) }
                cache.budgetBytes = s.ram.budgetMB << 20
                if let m = MemoryTrack.load(from: plan.base, budgetBytes: cache.budgetBytes) { cache.put(plan.key, m) }
            }
        }
    }

    // MARK: real-time processing chain

    /// Builds convolution → crossfeed → headphone EQ for one stream format. Runs off the audio thread; may load an impulse response.
    func makeRTChain(_ s: RTSettings, rate: Double, channels: Int) -> (state: RTChainState?, notes: [String]) {
        guard s.anyEnabled else { return (nil, []) }
        var procs: [RTProcessor] = [], notes: [String] = []
        if s.convolution.enabled {
            if channels > 2 { notes.append("Room correction supports mono and stereo streams only") }
            else if let path = s.convolution.irPath {
                let mtime = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
                let block = rate >= 88_000 ? 1024 : 512
                let key = "\(path)|\(Int(rate))|\(block)|\(s.convolution.gainDB)|\(s.convolution.normalize)|\(mtime)"
                irLock.lock(); var prepared = irCache[key]; irLock.unlock()
                if prepared == nil {
                    do {
                        var ir = IRLoader.trimmed(try IRLoader.readWAV(path: path))
                        if let r = IRLoader.resampled(ir, to: rate) { ir = r } else { throw AureonError.message("could not resample the impulse response") }
                        prepared = PreparedIR(ir, block: block, gainDB: s.convolution.gainDB, normalize: s.convolution.normalize)
                        irLock.lock(); if irCache.count >= 3 { irCache.removeAll() }; irCache[key] = prepared; irLock.unlock()
                    } catch { notes.append("Room correction: \((path as NSString).lastPathComponent): \(error.localizedDescription)") }
                }
                if let p = prepared { procs.append(ConvolutionProcessor(ir: p, channels: channels)) }
            } else { notes.append("Room correction is on but no impulse response is selected") }
        }
        if s.crossfeed.enabled {
            if channels == 2 { procs.append(BS2BCrossfeed(sampleRate: rate, cutoffHz: s.crossfeed.cutoffHz, feedDB: s.crossfeed.feedDB)) }
            else { notes.append("Crossfeed needs a stereo stream") }
        }
        if s.headphoneEQ.enabled, let prof = s.headphoneEQ.profile {
            procs.append(BiquadChainProcessor(profile: prof, sampleRate: rate, channels: channels))
        }
        return (procs.isEmpty ? nil : RTChainState(processors: procs, channels: channels, rate: rate), notes)
    }

    private func publishRT(_ s: RTSettings, renderer: Renderer, rate: Double, channels: Int, async: Bool) {
        let gen = rtGeneration.add(1, ordering: .sequentiallyConsistent).newValue
        let work = { [self] in
            let (state, notes) = makeRTChain(s, rate: rate, channels: channels)
            guard rtGeneration.load(ordering: .sequentiallyConsistent) == gen else { return }     // superseded by a newer request
            renderer.chain.publish(state)
            let dither: DitherStage? = s.dither.enabled ? DitherStage(settings: s.dither, channels: channels) : nil
            renderer.dither.publish(dither)
            update { $0.rtStages = (state?.description ?? []) + (dither.map { [$0.name] } ?? []); $0.rtLatencyFrames = state?.latencyFrames ?? 0 }
            notes.forEach(note)
        }
        if async { rtQueue.async(execute: work) } else { work() }
    }

    // MARK: one format group

    /// One overlap between two tracks, as written to the ring.
    private struct MixInfo { var startRing: Int; var frames: Int; var intoID: UUID; var note: String }

    /// Maps ring frames back to (track, position). A transition writes three: the outgoing track's overlap half (`mixOut`, a continuation
    /// of that track), the incoming track from the overlap's midpoint, and the incoming track from the overlap's end (a continuation).
    private struct Boundary {
        var ringFrame: Int; var entryID: UUID; var offset: Int; var opened: Opened; var info: StreamInfo
        /// Same entry as the boundary before it (not a new queue position).
        var continuation = false
        var mix: MixInfo? = nil
        var mixOut = false
    }

    /// A transition that has been decided: the incoming chain is open and positioned, waiting for the outgoing one to reach `plan.mixStart`.
    private struct PendingMix { var plan: TransitionPlan; var entry: QueueEntry; var opened: Opened }

    private func playGroup(startID: UUID, startSeconds: Double, sink: AudioSink, options: PlayerOptions) throws -> GroupExit {
        var snap = snapshot()
        guard let startEntry = snap.entries.first(where: { $0.id == startID }) else {
            if let f = snap.entries.first { return .continueAt(f.id, seconds: 0) }
            return .finished
        }
        var cfg = snap.settings
        var seenSettings = snap.settingsVersion, seenQueue = snap.version, seenPlugins = snap.pluginsVersion
        var seenUpscaler = upscaler.generation
        dsp.setPlugins(snap.plugins)
        let rates = sink.supportedRates
        let clock = DoPClock()

        update { $0.state = .loading; $0.loadProgress = nil }
        var lastProgress = Date.distantPast
        let opened0 = try openTrack(startEntry, settings: cfg, rates: rates, clock: clock, loadRAMNow: true) { p in
            if Date().timeIntervalSince(lastProgress) > 0.05 { lastProgress = Date(); self.update { $0.loadProgress = p } }
        }
        update { $0.loadProgress = nil }
        let fmt = opened0.source.info
        let report = sink.configure(for: fmt, options: options)
        update { $0.pathLines = report.lines }

        let perf = PerformanceProfile.ready
        let ringSeconds = perf.bufferSeconds(base: options.bufferSeconds, rate: fmt.sampleRate, channels: fmt.channels)
        let ring = RingBuffer(frames: perf.ringFrames(rate: fmt.sampleRate, channels: fmt.channels, seconds: ringSeconds), channels: fmt.channels)
        playoutGauge.attach(ring, rate: fmt.sampleRate)
        let prefillFrames = max(4096, Int(fmt.sampleRate * perf.prefillSeconds(rate: fmt.sampleRate)))
        if fmt.sampleRate > 192_000 { update { $0.errors.removeAll { $0.hasPrefix("Heavy stream") } } }
        ring.paused.store(true, ordering: .relaxed)                       // held until prefilled: no false underruns
        let renderer = Renderer(ring: ring, channels: fmt.channels, dsp: dsp, underruns: underruns, tap: analysisTap)
        renderer.deckGain = deckGain
        analysisTap.sampleRate.store(Int(fmt.sampleRate), ordering: .relaxed)
        func applyDSP(_ requested: DSPSettings) {
            let d = fmt.isDoP ? DSPSettings() : requested          // floating-point processing would destroy the bits inside a DoP stream
            dsp.apply(d.eq)
            if d.enabled && !renderer.useDSP.load(ordering: .relaxed) {
                do { try dsp.prepare(sampleRate: fmt.sampleRate, channels: fmt.channels, ring: ring); renderer.useDSP.store(true, ordering: .relaxed) }
                catch { note("DSP unavailable: \(error.localizedDescription)") }
            } else if !d.enabled && renderer.useDSP.load(ordering: .relaxed) {
                renderer.useDSP.store(false, ordering: .relaxed); usleep(30_000); dsp.teardown()
            }
        }
        applyDSP(cfg.dsp)
        publishRT(fmt.isDoP ? RTSettings() : cfg.rt, renderer: renderer, rate: fmt.sampleRate, channels: fmt.channels, async: false)
        try sink.start(renderer: renderer)
        defer { renderer.useDSP.store(false, ordering: .relaxed); sink.stop(); dsp.teardown() }

        // producer state
        var src: FrameSource? = opened0.source
        var pendingFilterFlush = false                 // a new oversampling filter is being built; the buffered audio is replaced once it is ready
        var srcID = startID, tailID = startID
        var exhausted = false, endOfGroup = false, groupNext: UUID? = nil, prefilled = false
        let startFrame = max(0, min(Int(startSeconds * fmt.sampleRate), max(0, Int(fmt.totalFrames) - 1)))
        if startFrame > 0 { src?.seek(to: Int64(startFrame)) }
        var bounds = [Boundary(ringFrame: 0, entryID: startID, offset: startFrame, opened: opened0, info: fmt)]
        let chunk = 8192
        let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * fmt.channels)
        defer { scratch.deallocate() }
        var offered = 0, offeredFrames = 0
        var lastUpdate = Date.distantPast, lastHeard: UUID? = nil
        // transitions
        var srcPos = startFrame                      // frames of `src` read so far, in its own timeline
        var decidedFor: UUID? = nil                  // the source a transition was already decided for (or ruled out)
        var pendingMix: PendingMix? = nil            // decided, waiting for `src` to reach the mix start
        var mixing: PendingMix? = nil                // `src` is the TransitionMixer
        func resetTransition() { decidedFor = nil; pendingMix = nil; mixing = nil }

        func heard() -> (Boundary, Int) {
            let c = ring.totalConsumed
            while bounds.count > 1 && bounds[1].ringFrame <= c { bounds.removeFirst() }
            let b = bounds[0]
            return (b, max(0, min(b.offset + c - b.ringFrame, Int(b.info.totalFrames))))
        }

        func entry(_ id: UUID) -> QueueEntry? { snapshot().entries.first { $0.id == id } }

        /// Reposition the audible track: drop buffered audio, seek, refill.
        func seekHeard(to target: Int) throws {
            let (b, _) = heard()
            if src == nil || srcID != b.entryID || mixing != nil {        // never seek inside a mixer: rebuild the heard track's chain
                guard let e = entry(b.entryID) else { return }
                src = try openTrack(e, settings: cfg, rates: rates, clock: clock, loadRAMNow: false).source
                srcID = b.entryID
            }
            ring.flush()
            let t = max(0, min(target, max(0, Int(b.info.totalFrames) - 1)))
            src?.seek(to: Int64(t))
            srcPos = t; resetTransition()
            bounds.removeAll { $0.ringFrame >= ring.totalWritten }       // boundaries of audio that was never written (an unfinished overlap)
            offered = 0; offeredFrames = 0; exhausted = false; endOfGroup = false; groupNext = nil; tailID = b.entryID
            bounds.append(Boundary(ringFrame: ring.totalWritten, entryID: b.entryID, offset: t, opened: b.opened, info: b.info))
            clock.phase = ring.totalWritten      // DoP markers keep alternating: the dropped, already stamped frames never reached the DAC
        }

        func neighbour(of id: UUID, _ delta: Int) -> QueueEntry? {
            let q = snapshot().entries
            guard let i = q.firstIndex(where: { $0.id == id }) else { return nil }
            if q.indices.contains(i + delta) { return q[i + delta] }
            // repeat-all wraps around the ends of the queue
            if repeatMode == .all, q.count > 1 { return delta > 0 ? q.first : q.last }
            return nil
        }

        /// Chain the next queue entry gaplessly, or end the group.
        func advance() {
            let q = snapshot().entries
            let mode = repeatMode
            guard let ti = q.firstIndex(where: { $0.id == tailID }) else { endOfGroup = true; groupNext = nil; return }
            var ni = mode == .one ? ti : ti + 1
            var tried = 0
            while true {
                if ni >= q.count { if mode != .off, !q.isEmpty { ni = 0 } else { break } }
                tried += 1
                if tried > q.count + 1 { break }                                       // every track failed: do not spin
                let e = q[ni]
                do {
                    let o = try openTrack(e, settings: cfg, rates: rates, clock: clock, loadRAMNow: false)
                    let i = o.source.info
                    if i.sampleRate == fmt.sampleRate && i.channels == fmt.channels && i.isDoP == fmt.isDoP {
                        src = o.source; srcID = e.id; tailID = e.id; exhausted = false
                        srcPos = 0; resetTransition()
                        bounds.append(Boundary(ringFrame: ring.totalWritten, entryID: e.id, offset: 0, opened: o, info: i))
                    } else { endOfGroup = true; groupNext = e.id }
                    return
                } catch {
                    note("skipped \((e.path as NSString).lastPathComponent): \(error.localizedDescription)")
                    ni = (mode == .one ? ti : ni) + 1
                }
            }
            endOfGroup = true; groupNext = nil
        }

        /// The entry a transition from `id` would lead into, or nil (end of the queue, repeat-one).
        func transitionTarget(after id: UUID) -> QueueEntry? {
            let q = snapshot().entries
            let mode = repeatMode
            guard mode != .one, let i = q.firstIndex(where: { $0.id == id }) else { return nil }
            if i + 1 < q.count { return q[i + 1] }
            return mode == .all && q.count > 1 ? q[0] : nil
        }

        /// Near the end of the current source, decides once whether and how to blend into the next entry. The incoming chain is opened
        /// here, on the engine thread, and positioned at its first audible frame.
        func prepareTransition() {
            let ts = cfg.transition
            guard ts.mode != .off, mixing == nil, decidedFor != srcID, let s = src, !fmt.isDoP, !s.info.isLive else { return }
            let total = Int(s.info.totalFrames)
            guard total > 0 else { decidedFor = srcID; return }
            let lookahead = Int((ts.seconds + EdgeAnalyzer.windowSeconds) * fmt.sampleRate) + chunk
            guard total - srcPos <= lookahead else { return }
            decidedFor = srcID
            guard let a = entry(srcID), let next = transitionTarget(after: srcID), next.id != srcID, !Self.isStreamURL(next.path) else { return }
            if ts.skipSameAlbum, let ka = albumKey(a.path), ka == albumKey(next.path) { return }
            let ea = edges.cached(path: a.path), eb = edges.cached(path: next.path)
            if ea == nil || eb == nil { edges.prefetch(paths: [a.path, next.path]) }      // ready for the next decision
            guard let o = try? openTrack(next, settings: cfg, rates: rates, clock: clock, loadRAMNow: false) else { return }
            let i = o.source.info
            guard i.sampleRate == fmt.sampleRate, i.channels == fmt.channels, !i.isDoP, !i.isLive, i.totalFrames > 0 else { return }
            let input = TransitionInput(rate: fmt.sampleRate, outgoingFrames: total, incomingFrames: Int(i.totalFrames), outgoing: ea, incoming: eb,
                                        outgoingGainDB: bounds.last { $0.entryID == srcID }?.opened.gainDB ?? 0, incomingGainDB: o.gainDB ?? 0)
            guard var plan = TransitionPlanner.plan(ts, input) else { return }
            if plan.mixStart < srcPos { plan.overlapFrames = plan.outgoingEnd - srcPos }      // decided late (after a seek near the end)
            guard plan.overlapFrames >= Int(TransitionPlanner.minimumSeconds * fmt.sampleRate) else { return }
            if plan.incomingStart > 0 { o.source.seek(to: Int64(plan.incomingStart)) }
            pendingMix = PendingMix(plan: plan, entry: next, opened: o)
        }

        /// The outgoing source has reached the mix start: from here the mixer is the source, and the boundaries for the overlap are recorded.
        func startMix(_ p: PendingMix) {
            guard let a = src, let outgoing = bounds.last(where: { $0.entryID == srcID }) else { pendingMix = nil; return }
            let w = ring.totalWritten                       // everything before the overlap has been written (offered == offeredFrames)
            let n = p.plan.overlapFrames, half = n / 2
            let mi = MixInfo(startRing: w, frames: n, intoID: p.entry.id, note: p.plan.description)
            let inInfo = p.opened.source.info
            bounds.append(Boundary(ringFrame: w, entryID: srcID, offset: srcPos, opened: outgoing.opened, info: outgoing.info, continuation: true, mix: mi, mixOut: true))
            bounds.append(Boundary(ringFrame: w + half, entryID: p.entry.id, offset: p.plan.incomingStart + half, opened: p.opened, info: inInfo, mix: mi))
            bounds.append(Boundary(ringFrame: w + n, entryID: p.entry.id, offset: p.plan.incomingStart + n, opened: p.opened, info: inInfo, continuation: true))
            src = TransitionMixer(outgoing: a, incoming: p.opened.source, plan: p.plan, info: fmt)
            tailID = p.entry.id
            mixing = p; pendingMix = nil
        }

        /// The overlap is written: the incoming chain carries on from where the mixer left it.
        func finishMix() {
            guard let m = mixing else { return }
            src = m.opened.source; srcID = m.entry.id; tailID = m.entry.id
            srcPos = m.plan.incomingStart + m.plan.overlapFrames
            resetTransition()
        }

        /// Commands, settings and queue edits. Returns an exit when the group must be restarted elsewhere.
        func service() throws -> GroupExit? {
            for c in drainCommands() {
                let (b, pos) = heard()
                switch c {
                case .togglePause: userPaused.toggle(); if prefilled { ring.paused.store(userPaused, ordering: .relaxed) }
                case .setPaused(let p): userPaused = p; if prefilled { ring.paused.store(p, ordering: .relaxed) }
                case .seekBy(let s): if !b.info.isLive { try seekHeard(to: pos + Int(s * b.info.sampleRate)) }
                case .seekTo(let s): if !b.info.isLive { try seekHeard(to: Int(s * b.info.sampleRate)) }
                case .next: if let n = neighbour(of: b.entryID, 1) { return .continueAt(n.id, seconds: 0) }
                case .previous:
                    if Double(pos) / b.info.sampleRate > 3 && !b.info.isLive { try seekHeard(to: 0) }
                    else if let p = neighbour(of: b.entryID, -1) { return .continueAt(p.id, seconds: 0) }
                    else if !b.info.isLive { try seekHeard(to: 0) }
                case .jump(let id): if entry(id) != nil { return .continueAt(id, seconds: 0) }
                case .stop: stopFlag.store(true, ordering: .relaxed)
                }
            }

            snap = snapshot()

            // settings
            if snap.settingsVersion != seenSettings {
                seenSettings = snap.settingsVersion
                let old = cfg
                cfg = snap.settings
                if cfg.upsampling.filter != old.upsampling.filter, filterSwitch.request(cfg.upsampling.filter), heard().0.opened.filterLine != nil { pendingFilterFlush = true }
                if cfg.streamKey != old.streamKey {
                    let (b, pos) = heard()
                    if let e = entry(b.entryID) {
                        let probe = try openTrack(e, settings: cfg, rates: rates, clock: clock, loadRAMNow: false)
                        let pi = probe.source.info
                        if pi.sampleRate != fmt.sampleRate || pi.channels != fmt.channels || pi.isDoP != fmt.isDoP {
                            return .continueAt(b.entryID, seconds: Double(pos) / fmt.sampleRate)
                        }
                        src = probe.source; srcID = b.entryID           // reuse the freshly built chain
                        try seekHeard(to: pos)
                        bounds[bounds.count - 1].opened = probe
                        pendingFilterFlush = false          // the rebuilt chain was made with the new filter
                    }
                }
                if cfg.transition != old.transition, mixing == nil { pendingMix = nil; decidedFor = nil }   // decide again with the new settings
                applyDSP(cfg.dsp)
                if cfg.rt != old.rt { publishRT(fmt.isDoP ? RTSettings() : cfg.rt, renderer: renderer, rate: fmt.sampleRate, channels: fmt.channels, async: true) }
            }

            // A new oversampling filter: once the resampler has built it, replace the audio already buffered so the change is heard at once
            // (the resampler swaps the design in when it is repositioned). A filter this Mac cannot afford is declined with a note.
            if pendingFilterFlush {
                if let why = filterSwitch.takeRefusal() { pendingFilterFlush = false; note(why) }
                else if filterSwitch.isReady, mixing == nil {
                    pendingFilterFlush = false
                    let (_, pos) = heard()
                    try seekHeard(to: pos)
                    if var o = bounds.last?.opened, let li = o.filterLine, o.stages.indices.contains(li) {
                        o.stages[li] = Self.resampleLine(from: o.filterRates.from, to: o.filterRates.to, cfg.upsampling.filter)
                        bounds[bounds.count - 1].opened = o
                    }
                }
            }

            // AI enhancer switched on, or its model finished loading, while a lossy stream plays without it: rebuild that stream.
            // (Switching it off needs no rebuild: the stage crossfades to its input and passes it through unchanged.)
            let upGen = upscaler.generation
            if upGen != seenUpscaler {
                seenUpscaler = upGen
                let (b, pos) = heard()
                if !b.opened.neural, upscaler.wouldInsert(for: b.opened.raw, deckRate: cfg.deckRate) {
                    return .continueAt(b.entryID, seconds: b.info.isLive ? 0 : Double(pos) / fmt.sampleRate)
                }
            }

            // hosted plugins
            if snap.pluginsVersion != seenPlugins {
                seenPlugins = snap.pluginsVersion
                let wasOn = renderer.useDSP.load(ordering: .relaxed)
                if wasOn { renderer.useDSP.store(false, ordering: .relaxed); usleep(30_000) }   // let an in-flight render finish
                dsp.setPlugins(snap.plugins)                                                  // rebuilds the graph if prepared
                if wasOn { renderer.useDSP.store(dsp.prepared, ordering: .relaxed) }
            }

            // queue
            if snap.version != seenQueue {
                seenQueue = snap.version
                let ids = snap.entries.map(\.id)
                let (b, pos) = heard()
                guard let hi = ids.firstIndex(of: b.entryID) else {
                    guard !ids.isEmpty else { return .finished }
                    return .continueAt(ids[min(heardIndexHint, ids.count - 1)], seconds: 0)   // the playing track was removed
                }
                heardIndexHint = hi
                if mixing == nil { pendingMix = nil; decidedFor = nil }          // the next entry may have changed: decide again
                var mismatch: Int? = nil
                var expect = hi
                for k in 1..<max(1, bounds.count) where !bounds[k].continuation {
                    expect += 1
                    if expect >= ids.count || ids[expect] != bounds[k].entryID { mismatch = k; break }
                }
                if let k = mismatch {
                    // A transition into the mismatched entry is undone whole: cut where the outgoing track starts to fade.
                    let cut = bounds[k].mix != nil && bounds[k - 1].mixOut ? k - 1 : k
                    if cut > 0, ring.truncate(to: bounds[cut].ringFrame) {         // audible track untouched
                        let keep = bounds[cut]
                        bounds.removeSubrange(cut...)
                        clock.phase = ring.totalWritten
                        resetTransition()
                        endOfGroup = false; groupNext = nil; offered = 0; offeredFrames = 0
                        if cut < k, let e = entry(keep.entryID), let o = try? openTrack(e, settings: cfg, rates: rates, clock: clock, loadRAMNow: false) {
                            // write the outgoing track's tail again, unmixed, from where the overlap began
                            o.source.seek(to: Int64(keep.offset))
                            src = o.source; srcID = keep.entryID; tailID = srcID; srcPos = keep.offset; exhausted = false
                        } else {
                            src = nil; srcID = bounds[cut - 1].entryID; tailID = srcID; exhausted = true
                        }
                    } else { src = nil; try seekHeard(to: pos) }
                } else if endOfGroup {
                    endOfGroup = false; groupNext = nil; exhausted = true; src = nil
                }
            }
            return nil
        }

        while !stopFlag.load(ordering: .relaxed) {
            if let exit = try service() { return exit }

            if endOfGroup {
                if ring.availableToRead == 0 { usleep(150_000); return groupNext.map { .continueAt($0, seconds: 0) } ?? .finished }
                usleep(10_000)
            } else if exhausted {
                advance()
            } else {
                if offered == offeredFrames {
                    if mixing == nil, src != nil {
                        prepareTransition()
                        if let p = pendingMix, srcPos >= p.plan.mixStart { startMix(p) }
                    }
                    if let s = src {
                        var want = chunk
                        if mixing == nil, let p = pendingMix { want = min(want, max(1, p.plan.mixStart - srcPos)) }   // stop exactly at the mix start
                        offeredFrames = s.read(into: scratch, frames: want); offered = 0
                        if mixing == nil { srcPos += offeredFrames }
                        if offeredFrames == 0 {
                            if mixing != nil { finishMix(); continue }
                            exhausted = true; src = nil; continue
                        }
                    } else { exhausted = true; continue }
                }
                let n = ring.write(scratch + offered * fmt.channels, frames: offeredFrames - offered)
                offered += n
                if n == 0 { usleep(4_000) }
            }

            if !prefilled && (ring.availableToRead >= min(ring.capacity / 2, prefillFrames) || endOfGroup) {
                prefilled = true; ring.paused.store(userPaused, ordering: .relaxed)
            }

            if Date().timeIntervalSince(lastUpdate) > 0.05 {
                lastUpdate = Date()
                let (b, pos) = heard()
                if lastHeard != b.entryID {
                    lastHeard = b.entryID
                    prefetch(after: b.entryID, heard: b.entryID, settings: cfg, rates: rates)
                    heardIndexHint = snapshot().entries.firstIndex { $0.id == b.entryID } ?? heardIndexHint
                }
                let q = snapshot().entries
                update {
                    $0.state = userPaused ? .paused : .playing
                    $0.trackID = b.entryID
                    $0.trackIndex = q.firstIndex { $0.id == b.entryID } ?? 0
                    $0.info = b.info; $0.sourceInfo = b.opened.raw; $0.pipeline = b.opened.stages + (b.mix.map { [$0.note] } ?? [])
                    $0.mixingInto = b.mix?.intoID
                    $0.mixProgress = b.mix.map { max(0, min(1, Double(ring.totalConsumed - $0.startRing) / Double(max(1, $0.frames)))) }
                    $0.position = Double(pos) / b.info.sampleRate; $0.duration = b.info.duration
                    $0.bufferedSeconds = Double(ring.availableToRead) / fmt.sampleRate
                    $0.underruns = underruns.n.load(ordering: .relaxed)
                    $0.transparentStream = b.info.transparent && b.mix == nil && !renderer.useDSP.load(ordering: .relaxed) && $0.rtStages.isEmpty
                    $0.bitPerfect = report.bitPerfect && $0.transparentStream
                    $0.replayGainDB = b.opened.gainDB
                    $0.live = b.opened.live?.snapshot
                    $0.ramBytes = cache.usedBytes
                    $0.dspActive = renderer.useDSP.load(ordering: .relaxed)
                    $0.dspSummary = $0.dspActive ? "Parametric EQ" + (dsp.plugins.isEmpty ? "" : " + " + dsp.plugins.map { $0.name }.joined(separator: ", ")) : nil
                }
            }
        }
        return .finished
    }
}

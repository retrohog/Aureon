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
    private var heardIndexHint = 0           // engine thread only

    let dsp = DSPChain()
    let replayGain = ReplayGainStore()
    let cache = TrackCache(budgetBytes: 1 << 30)
    let analysisTap = AnalysisTap()
    private let rtQueue = DispatchQueue(label: "aureon.rtbuild", qos: .userInitiated)
    private let rtGeneration = Atomic<Int>(0)
    private var irCache: [String: PreparedIR] = [:]
    private let irLock = NSLock()
    private(set) lazy var analysis = AnalysisEngine(tap: analysisTap)

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
    func clearQueue() { lock.lock(); entries = []; queueVersion += 1; lock.unlock() }

    // MARK: lifecycle

    func start(startID: UUID? = nil, startSeconds: Double = 0, options: PlayerOptions) {
        stop()
        stopFlag.store(false, ordering: .relaxed)
        lock.lock(); _status = PlayerStatus(); commands = []; lock.unlock()
        underruns.n.store(0, ordering: .relaxed)
        userPaused = false
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

    private struct Opened { var source: FrameSource; var raw: StreamInfo; var stages: [String]; var gainDB: Double?; var live: LiveMetadata? = nil }

    private struct DecodePlan { var base: FrameSource; var raw: StreamInfo; var key: String; var isDoP: Bool; var stages: [String]; var live: LiveMetadata? = nil }

    static func isStreamURL(_ path: String) -> Bool { path.hasPrefix("http://") || path.hasPrefix("https://") }

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
            let f = try LosslessFile(path: path)
            var stages: [String] = []
            if !f.info.transparent { stages.append("Lossy source: not bit-perfect by definition") }
            return DecodePlan(base: f, raw: f.info, key: path + "|pcm", isDoP: false, stages: stages)
        }
        let file = try DsdContainer(path: path)
        let codec = dsdRateName(file.dsdRate)
        let raw = StreamInfo(sampleRate: file.dsdRate, channels: file.channels, sourceBits: 1, totalFrames: Int64(file.totalBits), codec: codec)
        var stages: [String] = []
        var mode = s.dsd.mode
        let dopRate = file.dsdRate / 16
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
        guard let target = (rates.isEmpty ? candidates.first : candidates.first { nearest($0, in: rates) }) ?? candidates.first,
              let src = DsdToPcmSource(file, codec: codec, pcmRate: target, gainDB: s.dsd.gainDB) else {
            throw AureonError.message("cannot convert \(codec) to PCM")
        }
        stages.append("\(codec) → PCM \(Int(target)) Hz (FIR decimation)")
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
        if plan.isDoP {
            if s.upsampling.mode != .off || s.replayGain.mode != .off || s.polarityInverted {
                stages.append("Upsampling, ReplayGain and polarity are bypassed for DoP")
            }
            chain = DoPStampSource(chain, clock: clock)
        } else {
            // sample rate
            let rate = chain.info.sampleRate
            var target = upsamplingTarget(source: rate, mode: s.upsampling.mode, deviceRates: rates, maxRate: s.upsampling.maxRate)
            if isLive, s.radio.upscale, !rates.isEmpty {
                target = upsamplingTarget(source: rate, mode: .deviceMax, deviceRates: rates, maxRate: s.radio.maxRate)
                if target == nil, !nearest(rate, in: rates) { target = fitRate(source: rate, deviceRates: rates) }
            }
            if target == nil, s.upsampling.downsampleToFit, !rates.isEmpty, !nearest(rate, in: rates) { target = fitRate(source: rate, deviceRates: rates) }
            if s.upsampling.mode != .off && target == nil {
                stages.append("Upsampling: no suitable device rate above \(Int(rate)) Hz, keeping native rate")
            }
            if let t = target, let r = ResamplingSource(chain, outRate: t, config: s.upsampling.filter) {
                chain = r
                stages.append("Resample \(Int(rate)) → \(Int(t)) Hz, \(s.upsampling.filter.phase.title.lowercased()), \(Int(s.upsampling.filter.stopbandDB)) dB stop-band")
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
        }
        return Opened(source: chain, raw: plan.raw, stages: stages, gainDB: gainDB, live: plan.live)
    }

    /// Decodes upcoming tracks into RAM (and warms ReplayGain data) on a background queue.
    private func prefetch(after id: UUID, heard: UUID, settings s: PlaybackSettings, rates: [Double]) {
        let q = snapshot().entries
        guard let i = q.firstIndex(where: { $0.id == id }) else { return }
        let upcoming = Array(q[(i + 1)..<min(i + 3, q.count)]).filter { !Self.isStreamURL($0.path) }
        replayGain.prefetch(paths: upcoming.map(\.path), settings: s.replayGain)
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
            update { $0.rtStages = state?.description ?? []; $0.rtLatencyFrames = state?.latencyFrames ?? 0 }
            notes.forEach(note)
        }
        if async { rtQueue.async(execute: work) } else { work() }
    }

    // MARK: one format group

    private struct Boundary { var ringFrame: Int; var entryID: UUID; var offset: Int; var opened: Opened; var info: StreamInfo }

    private func playGroup(startID: UUID, startSeconds: Double, sink: AudioSink, options: PlayerOptions) throws -> GroupExit {
        var snap = snapshot()
        guard let startEntry = snap.entries.first(where: { $0.id == startID }) else {
            if let f = snap.entries.first { return .continueAt(f.id, seconds: 0) }
            return .finished
        }
        var cfg = snap.settings
        var seenSettings = snap.settingsVersion, seenQueue = snap.version, seenPlugins = snap.pluginsVersion
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

        let ring = RingBuffer(frames: max(8192, Int(fmt.sampleRate * options.bufferSeconds)), channels: fmt.channels)
        ring.paused.store(true, ordering: .relaxed)                       // held until prefilled: no false underruns
        let renderer = Renderer(ring: ring, channels: fmt.channels, dsp: dsp, underruns: underruns, tap: analysisTap)
        analysisTap.sampleRate.store(Int(fmt.sampleRate), ordering: .relaxed)
        func applyDSP(_ d: DSPSettings) {
            dsp.apply(d.eq)
            if d.enabled && !renderer.useDSP.load(ordering: .relaxed) {
                do { try dsp.prepare(sampleRate: fmt.sampleRate, channels: fmt.channels, ring: ring); renderer.useDSP.store(true, ordering: .relaxed) }
                catch { note("DSP unavailable: \(error.localizedDescription)") }
            } else if !d.enabled && renderer.useDSP.load(ordering: .relaxed) {
                renderer.useDSP.store(false, ordering: .relaxed); usleep(30_000); dsp.teardown()
            }
        }
        applyDSP(cfg.dsp)
        publishRT(cfg.rt, renderer: renderer, rate: fmt.sampleRate, channels: fmt.channels, async: false)
        try sink.start(renderer: renderer)
        defer { renderer.useDSP.store(false, ordering: .relaxed); sink.stop(); dsp.teardown() }

        // producer state
        var src: FrameSource? = opened0.source
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
            if src == nil || srcID != b.entryID {
                guard let e = entry(b.entryID) else { return }
                src = try openTrack(e, settings: cfg, rates: rates, clock: clock, loadRAMNow: false).source
                srcID = b.entryID
            }
            ring.flush()
            let t = max(0, min(target, max(0, Int(b.info.totalFrames) - 1)))
            src?.seek(to: Int64(t))
            offered = 0; offeredFrames = 0; exhausted = false; endOfGroup = false; groupNext = nil; tailID = b.entryID
            bounds.append(Boundary(ringFrame: ring.totalWritten, entryID: b.entryID, offset: t, opened: b.opened, info: b.info))
        }

        func neighbour(of id: UUID, _ delta: Int) -> QueueEntry? {
            let q = snapshot().entries
            guard let i = q.firstIndex(where: { $0.id == id }), q.indices.contains(i + delta) else { return nil }
            return q[i + delta]
        }

        /// Chain the next queue entry gaplessly, or end the group.
        func advance() {
            let q = snapshot().entries
            guard var ni = q.firstIndex(where: { $0.id == tailID }).map({ $0 + 1 }) else { endOfGroup = true; groupNext = nil; return }
            while ni < q.count {
                let e = q[ni]
                do {
                    let o = try openTrack(e, settings: cfg, rates: rates, clock: clock, loadRAMNow: false)
                    let i = o.source.info
                    if i.sampleRate == fmt.sampleRate && i.channels == fmt.channels && i.isDoP == fmt.isDoP {
                        src = o.source; srcID = e.id; tailID = e.id; exhausted = false
                        bounds.append(Boundary(ringFrame: ring.totalWritten, entryID: e.id, offset: 0, opened: o, info: i))
                    } else { endOfGroup = true; groupNext = e.id }
                    return
                } catch {
                    note("skipped \((e.path as NSString).lastPathComponent): \(error.localizedDescription)")
                    ni += 1
                }
            }
            endOfGroup = true; groupNext = nil
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
                    }
                }
                applyDSP(cfg.dsp)
                if cfg.rt != old.rt { publishRT(cfg.rt, renderer: renderer, rate: fmt.sampleRate, channels: fmt.channels, async: true) }
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
                var mismatch: Int? = nil
                var expect = hi
                for k in 1..<max(1, bounds.count) {
                    expect += 1
                    if expect >= ids.count || ids[expect] != bounds[k].entryID { mismatch = k; break }
                }
                if let k = mismatch {
                    if ring.truncate(to: bounds[k].ringFrame) {                    // audible track untouched
                        bounds.removeSubrange(k...)
                        src = nil; srcID = bounds[k - 1].entryID; tailID = srcID
                        exhausted = true; endOfGroup = false; groupNext = nil; offered = 0; offeredFrames = 0
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
                    if let s = src {
                        offeredFrames = s.read(into: scratch, frames: chunk); offered = 0
                        if offeredFrames == 0 { exhausted = true; src = nil; continue }
                    } else { exhausted = true; continue }
                }
                let n = ring.write(scratch + offered * fmt.channels, frames: offeredFrames - offered)
                offered += n
                if n == 0 { usleep(4_000) }
            }

            if !prefilled && (ring.availableToRead >= min(ring.capacity / 2, 4096) || endOfGroup) {
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
                    $0.info = b.info; $0.sourceInfo = b.opened.raw; $0.pipeline = b.opened.stages
                    $0.position = Double(pos) / b.info.sampleRate; $0.duration = b.info.duration
                    $0.bufferedSeconds = Double(ring.availableToRead) / fmt.sampleRate
                    $0.underruns = underruns.n.load(ordering: .relaxed)
                    $0.transparentStream = b.info.transparent && !renderer.useDSP.load(ordering: .relaxed) && $0.rtStages.isEmpty
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

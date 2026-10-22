import Foundation
import Synchronization
import AureonNeuralCore

// The neural upscaler ("Real-Time Audio Enhancer" in the Intelligence tab).
//
//   lossy source ─► [sinc resample to the model rate] ─► NeuralUpscaleSource ─► [sinc resample to the device rate] ─► … ─► ring ─► render
//                                                         │            ▲
//                                    PENDING jobs (AUOla) ▼            │ DONE jobs
//                                                  worker thread: CoreML (Neural Engine / CPU)
//
// Everything here runs on the player's decode thread or on the worker thread. The render callback is not touched: it keeps reading
// the same lock-free ring, which already holds seconds of finished audio. Inference therefore never runs on, waits for, or allocates
// on the audio thread, and a late block costs nothing there: the decode thread commits that block as fallback (the sinc-resampled
// input) without waiting, and the overlap-add crossfades into and out of it.
//
// The Intelligence settings own the switch: `IntelligenceGate.isEnabled(.audioEnhancer)` (master switch, Intel opt-in and the feature
// toggle) is read once per block, and the model is the one the user picked there, already checked against the size cap.

/// What the enhancer is doing, for the Intelligence tab. Counters are atomics; the text is behind a lock (not for the audio thread).
final class NeuralUpscaleStatus: @unchecked Sendable {
    static let shared = NeuralUpscaleStatus()

    enum State: Equatable, Sendable {
        /// The feature is switched off (or the master switch is).
        case off
        /// The model is being compiled, loaded and timed.
        case loading
        /// The model is loaded; nothing lossy is playing.
        case ready
        /// A stream is being enhanced.
        case active
        /// The classic resampler is playing instead, for the reason given.
        case bypassed(String)
    }

    private let code = Atomic<Int>(0)
    private let neural = Atomic<Int>(0)
    private let fallback = Atomic<Int>(0)
    private let rtfBits = Atomic<UInt64>(0)
    private let lock = NSLock()
    private var reason = ""
    private var error: String?

    var state: State {
        switch code.load(ordering: .relaxed) {
        case 1: return .loading
        case 2: return .ready
        case 3: return .active
        case 4: lock.lock(); defer { lock.unlock() }; return .bypassed(reason)
        default: return .off
        }
    }
    /// Blocks played with the model's output since the enhancer was last switched on.
    var windowsNeural: Int { neural.load(ordering: .relaxed) }
    /// Blocks played with the classic resampler's output instead (late, failed, or while bypassed).
    var windowsFallback: Int { fallback.load(ordering: .relaxed) }
    /// Inference time ÷ audio time per block. Below 1 keeps up; the enhancer bypasses itself above 0.8.
    var realTimeFactor: Double { Double(bitPattern: rtfBits.load(ordering: .relaxed)) }
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return error }

    func set(_ s: State) {
        let c: Int
        switch s {
        case .off: c = 0
        case .loading: c = 1
        case .ready: c = 2
        case .active: c = 3
        case .bypassed(let why): lock.lock(); reason = why; lock.unlock(); c = 4
        }
        code.store(c, ordering: .relaxed)
    }
    func setError(_ e: String?) { lock.lock(); error = e; lock.unlock() }
    /// For the Intelligence tab (`EnhancerStatusBoard`): atomics and one short lock, never blocks for long.
    func snapshot() -> EnhancerStatusSnapshot {
        let s: EnhancerStatusSnapshot.State
        switch state {
        case .off: s = .off
        case .ready: s = .ready
        case .loading: s = .loading
        case .active: s = .active
        case .bypassed(let why): s = .bypassed(why)
        }
        return EnhancerStatusSnapshot(state: s, windowsNeural: UInt64(max(0, windowsNeural)), windowsFallback: UInt64(max(0, windowsFallback)),
                                      realTimeFactor: realTimeFactor, lastError: lastError)
    }

    func countWindow(neural n: Bool) {
        if n { neural.add(1, ordering: .relaxed) } else { fallback.add(1, ordering: .relaxed) }
    }
    func setRealTimeFactor(_ r: Double) { rtfBits.store(r.bitPattern, ordering: .relaxed) }
    func resetCounters() { neural.store(0, ordering: .relaxed); fallback.store(0, ordering: .relaxed); rtfBits.store(0, ordering: .relaxed) }
}

/// How much finished audio is queued for the device, so the decode thread knows how long it may wait for a block.
/// Read and attached on the player's decode thread.
final class PlayoutGauge: @unchecked Sendable {
    private let lock = NSLock()
    private weak var ring: RingBuffer?
    private var rate = 0.0

    func attach(_ ring: RingBuffer, rate: Double) { lock.lock(); self.ring = ring; self.rate = rate; lock.unlock() }

    /// Seconds queued for the device, or nil while nothing drains the ring (not started, prefilling or paused): then there is no deadline.
    var headroomSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let r = ring, rate > 0, !r.paused.load(ordering: .relaxed) else { return nil }
        return Double(r.availableToRead) / rate
    }
}

/// One stream's share of the upscaler: its overlap-add buffers and breaker (C++, preallocated), and the model bindings for its slots.
final class UpscaleStream: @unchecked Sendable {
    let ola: OpaquePointer
    let breaker: OpaquePointer
    let backend: UpscaleBackend
    let channels: Int
    /// Signalled by the worker each time one of this stream's blocks is finished.
    let finished = DispatchSemaphore(value: 0)
    private var bindings: [AnyObject?]          // worker thread only
    private var bindFailed: [Bool]              // worker thread only
    fileprivate var lastError: String?          // worker thread only

    static let lookahead = 4
    static let slots = 6

    init?(backend: UpscaleBackend, channels: Int) {
        let i = backend.info
        guard i.isValid, (1...2).contains(channels) else { return nil }
        var cfg = AUOlaConfig(channels: Int32(channels), window: Int32(i.window), hop: Int32(i.hop), slots: Int32(Self.slots), lookahead: Int32(Self.lookahead))
        guard let o = au_ola_create(&cfg) else { return nil }
        var g = AUGuardConfig(hopSeconds: Double(i.hop) / i.sampleRate, tripRTF: 0.8, missSpan: 16, missLimit: 3, warmupWindows: 8,
                              probeWindows: 32, cooldownSeconds: 10, maxCooldownSeconds: 160)
        guard let b = au_guard_create(&g) else { au_ola_destroy(o); return nil }
        ola = o; breaker = b; self.backend = backend; self.channels = channels
        bindings = Array(repeating: nil, count: Self.slots)
        bindFailed = Array(repeating: false, count: Self.slots)
    }

    deinit { au_guard_destroy(breaker); au_ola_destroy(ola) }

    /// Worker thread: runs one pending block of this stream. Returns false when there was none.
    fileprivate func runOne() -> Bool {
        let slot = au_ola_worker_take(ola)
        guard slot >= 0 else { return false }
        let s = Int(slot)
        let t0 = DispatchTime.now().uptimeNanoseconds
        var ok: Int32 = 0
        if bindings[s] == nil && !bindFailed[s], let i = au_ola_slot_input(ola, slot), let o = au_ola_slot_output(ola, slot) {
            do { bindings[s] = try backend.bind(input: i, output: o, channels: channels) }
            catch { bindFailed[s] = true; lastError = error.localizedDescription }
        }
        if let b = bindings[s] {
            do { try backend.run(b); ok = 1 } catch { lastError = error.localizedDescription }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        au_ola_worker_finish(ola, slot, ok, seconds)
        finished.signal()
        return true
    }
}

/// The process-wide upscaler service: loads the model the Intelligence settings name, runs one worker thread for every stream, and
/// tells the player when a stream should be rebuilt with (or could be built without) the enhancer.
final class NeuralUpscaler: @unchecked Sendable {
    static let shared = NeuralUpscaler(gate: .shared, status: .shared, loader: CoreMLUpscaleBackend.load)

    typealias Loader = (URL?, HostHardware) throws -> UpscaleBackend

    let gate: IntelligenceGate
    let status: NeuralUpscaleStatus
    private let loader: Loader
    private let lock = NSLock()
    private var backend: UpscaleBackend?
    private var loadedKey: String?               // model path the backend (or the last failure) belongs to
    private var streams: [UpscaleStream] = []
    private var worker: Thread?
    private let jobs = DispatchSemaphore(value: 0)
    private let changes = Atomic<UInt64>(0)
    private let loadQueue = DispatchQueue(label: "aureon.upscaler.load", qos: .utility)
    private var observer: NSObjectProtocol?
    /// A model slower than this (inference time ÷ audio time, measured when it loads) is refused outright.
    var admissionRTF = 0.7

    init(gate: IntelligenceGate, status: NeuralUpscaleStatus, loader: @escaping Loader) {
        self.gate = gate; self.status = status; self.loader = loader
    }

    /// Follows the Intelligence settings from now on, loads the model if the enhancer is on, and feeds the Intelligence tab's status line.
    /// Idempotent and callable from any thread: the app calls it at launch, and the player on first use (for the headless daemon).
    func observeSettings() {
        lock.lock()
        guard observer == nil else { lock.unlock(); return }
        observer = NotificationCenter.default.addObserver(forName: .intelligenceSettingsChanged, object: gate, queue: nil) { [weak self] _ in self?.reconcile() }
        lock.unlock()
        let st = status
        EnhancerStatusBoard.shared.register { st.snapshot() }
        reconcile()
    }

    /// Bumped whenever whether a new stream would get the enhancer may have changed. The player compares it once per loop.
    var generation: UInt64 { changes.load(ordering: .acquiring) }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return backend != nil }
    var modelInfo: UpscaleModelInfo? { lock.lock(); defer { lock.unlock() }; return backend?.info }

    /// Streams the enhancer is for: lossy (not bit-transparent) PCM with one or two channels, outside the DJ decks.
    static func applies(to raw: StreamInfo, deckRate: Double?) -> Bool {
        !raw.transparent && !raw.isDoP && deckRate == nil && (1...2).contains(raw.channels)
    }

    func wouldInsert(for raw: StreamInfo, deckRate: Double?) -> Bool {
        Self.applies(to: raw, deckRate: deckRate) && gate.isEnabled(.audioEnhancer) && isReady
    }

    /// Loads, swaps or drops the model to match the settings. Asynchronous unless `wait` (tests).
    func reconcile(wait: Bool = false) {
        let work = { [self] in
            let enabled = gate.isEnabled(.audioEnhancer)
            let url = enabled ? gate.enhancerModelURL : nil
            let key = enabled ? (url?.standardizedFileURL.path ?? "") : nil
            lock.lock(); let same = key == loadedKey; lock.unlock()
            if same { if !enabled { status.set(.off) }; return }
            guard enabled, let key else {
                lock.lock(); backend = nil; loadedKey = nil; lock.unlock()
                status.set(.off); status.setError(nil)
                _ = changes.wrappingAdd(1, ordering: .releasing)
                return
            }
            status.set(.loading)
            do {
                let b = try loader(url, gate.hardware)
                let rtf = try Self.measure(b)
                guard rtf <= admissionRTF else { throw UpscalerError.tooSlow(rtf) }
                lock.lock(); backend = b; loadedKey = key; lock.unlock()
                status.resetCounters(); status.setRealTimeFactor(rtf); status.setError(nil); status.set(.ready)
            } catch {
                lock.lock(); backend = nil; loadedKey = key; lock.unlock()
                let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status.setError(why); status.set(.bypassed(why))
            }
            _ = changes.wrappingAdd(1, ordering: .releasing)
        }
        if wait { loadQueue.sync(execute: work) } else { loadQueue.async(execute: work) }
    }

    /// Times the model on silence (one warm-up block, then the median of three) and returns inference time ÷ audio time for stereo.
    static func measure(_ b: UpscaleBackend) throws -> Double {
        let w = b.info.window, ch = 2
        let input = UnsafeMutablePointer<Float>.allocate(capacity: w * ch), output = UnsafeMutablePointer<Float>.allocate(capacity: w * ch)
        defer { input.deallocate(); output.deallocate() }
        input.initialize(repeating: 0, count: w * ch); output.initialize(repeating: 0, count: w * ch)
        let binding = try b.bind(input: input, output: output, channels: ch)
        try b.run(binding)
        var times: [Double] = []
        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try b.run(binding)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
        }
        return times.sorted()[1] / (Double(b.info.hop) / b.info.sampleRate)
    }

    /// Builds the enhancer stage for `upstream` (decode thread). Nil when it does not apply, is off, or the model is not loaded.
    func makeNode(upstream: FrameSource, raw: StreamInfo, deckRate: Double?, gauge: PlayoutGauge?) -> (source: FrameSource, stages: [String])? {
        guard wouldInsert(for: raw, deckRate: deckRate) else { return nil }
        lock.lock(); let b = backend; lock.unlock()
        guard let b else { return nil }
        var chain = upstream, stages: [String] = []
        let rate = chain.info.sampleRate, modelRate = b.info.sampleRate
        if abs(rate - modelRate) > 0.5 {
            guard let r = ResamplingSource(chain, outRate: modelRate, config: .standard) else { return nil }
            chain = r
            stages.append("Resample \(Int(rate)) → \(Int(modelRate)) Hz for the enhancer model")
        }
        guard let stream = UpscaleStream(backend: b, channels: chain.info.channels) else { return nil }
        register(stream)
        let node = NeuralUpscaleSource(chain, stream: stream, service: self, gauge: gauge)
        let ms = Double(b.info.window) / modelRate * 1000
        stages.append(String(format: "AI enhancer: %@, %.0f ms blocks, %d× overlap, on this Mac only; falls back to the sinc resampler when late", b.info.name, ms, b.info.window / b.info.hop))
        return (node, stages)
    }

    // MARK: worker

    private func register(_ s: UpscaleStream) {
        lock.lock()
        streams.append(s)
        if worker == nil {
            let t = Thread { [weak self] in self?.workerLoop() }
            t.name = "aureon.upscaler.infer"
            t.qualityOfService = .userInitiated
            worker = t
            t.start()
        }
        lock.unlock()
    }

    func unregister(_ s: UpscaleStream) {
        lock.lock()
        streams.removeAll { $0 === s }
        let idle = streams.isEmpty
        lock.unlock()
        if idle, case .active = status.state { status.set(isReady ? .ready : .off) }
    }

    /// Wakes the worker for `count` new blocks.
    func signal(_ count: Int) { for _ in 0..<max(0, count) { jobs.signal() } }

    var activeStreams: Int { lock.lock(); defer { lock.unlock() }; return streams.count }

    /// Runs every stream's pending blocks, oldest first within a stream. Exits after a few idle seconds with no stream left;
    /// `register` starts a new one when needed.
    private func workerLoop() {
        var lastWork = DispatchTime.now().uptimeNanoseconds
        while true {
            if jobs.wait(timeout: .now() + 1) == .timedOut {
                lock.lock()
                if streams.isEmpty && DispatchTime.now().uptimeNanoseconds - lastWork > 5_000_000_000 { worker = nil; lock.unlock(); return }
                lock.unlock()
            }
            var progressed = true
            while progressed {
                lock.lock(); let list = streams; lock.unlock()     // strong references: a stream closed meanwhile stays valid until we are done
                progressed = false
                for s in list where s.runOne() {
                    progressed = true
                    lastWork = DispatchTime.now().uptimeNanoseconds
                    if let e = s.lastError { status.setError(e); s.lastError = nil }
                }
            }
        }
    }
}

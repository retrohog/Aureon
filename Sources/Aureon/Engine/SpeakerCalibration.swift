import Foundation
import CoreAudio
import Synchronization

// Level calibration for several outputs playing one stream.
//
// Two outputs set to the same volume are not equally loud: their volume controls follow different curves, a speaker that plays only the
// ambience or only the bass carries a fraction of the music's energy, and a device with no volume control cannot follow the slider at all.
// This file turns "the main output is at this volume, and these are the jobs of the others" into a level for every output, and moves each
// output to its new level without a step.
//
// Where things run:
//  • The render threads only ever touch `SmoothGain` (one atomic load per block, then arithmetic on locals) and `OutputStage`. No allocation,
//    no lock, no Swift/Obj-C messaging.
//  • Everything else (curves, planning, hardware volume writes, the ramp timer) runs on the control side: the main thread that calls the sink,
//    and the follower's own serial queue.

// MARK: - A gain that moves smoothly and can be set from any thread

/// A linear gain with a lock-free hand-off. Any thread may call `setTarget`; the one render thread that owns the gain moves toward the target
/// with a one-pole smoother, so a change of level never produces a step (a click) and the render thread never waits for the setter.
final class SmoothGain: @unchecked Sendable {
    /// The most the digital path will multiply by (+12 dB).
    static let ceiling: Float = 4
    /// Closer than this, the gain lands on the target exactly (which also keeps a fade to zero out of the denormal range).
    static let snap: Float = 1e-6

    private let targetBits: Atomic<UInt32>
    private var current: Float                       // render thread only (control side only while the stream is stopped)
    private var k: Float                             // per-sample smoothing coefficient; set before the stream runs

    init(gain: Float = 1, rate: Double = 44_100, timeConstant: Double = 0.03) {
        let g = Self.clamp(gain)
        targetBits = Atomic(g.bitPattern); current = g
        k = Self.coefficient(rate: rate, timeConstant: timeConstant)
    }

    private static func clamp(_ g: Float) -> Float { g.isFinite ? min(max(g, 0), ceiling) : 1 }
    static func coefficient(rate: Double, timeConstant: Double) -> Float {
        guard rate > 0, timeConstant > 0 else { return 1 }
        return Float(1 - exp(-1 / (rate * timeConstant)))
    }
    static func linear(db: Double) -> Float { db.isFinite ? clamp(Float(pow(10, db / 20))) : 1 }

    /// Control side, before the stream runs: the smoothing time for this sample rate.
    func configure(rate: Double, timeConstant: Double = 0.03) { k = Self.coefficient(rate: rate, timeConstant: timeConstant) }

    /// Any thread. The render thread follows within a few tens of milliseconds. Not-a-number is ignored.
    func setTarget(_ g: Float) { if g.isFinite { targetBits.store(Self.clamp(g).bitPattern, ordering: .relaxed) } }
    func setTarget(db: Double) { if db.isFinite { setTarget(Self.linear(db: db)) } }
    var target: Float { Float(bitPattern: targetBits.load(ordering: .relaxed)) }

    /// Control side, while the stream is stopped: lands on a level at once (a stream that is about to start should start at its level).
    func reset(to g: Float) { let v = Self.clamp(g); current = v; targetBits.store(v.bitPattern, ordering: .relaxed) }

    /// The gain as the render thread last left it. Read it from the render thread, or from anywhere once rendering has stopped.
    var value: Float { current }

    // render thread
    @inline(__always) func loadTarget() -> Float { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
    @inline(__always) var coefficient: Float { k }
    @inline(__always) func store(_ g: Float) { current = g }

    /// One step of the smoother.
    @inline(__always) static func step(_ g: Float, toward t: Float, k: Float) -> Float {
        let d = t - g
        let n = g + d * k
        return abs(d) <= snap || n == g ? t : n            // n == g: the step is below what a Float can add; land on the target
    }

    /// Scales interleaved floats in place, moving toward the target as it goes.
    func apply(_ p: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let t = loadTarget(), k = self.k
        var g = current
        if g == t { if t != 1 { for i in 0..<(frames * channels) { p[i] *= t } }; return }
        for f in 0..<frames {
            g = Self.step(g, toward: t, k: k)
            for c in 0..<channels { p[f * channels + c] *= g }
        }
        current = g
    }

    /// Scales interleaved Int32 samples in place (full-scale or left-justified, either way). At exactly unity the samples are not touched.
    func apply(_ p: UnsafeMutablePointer<Int32>, frames: Int, channels: Int) {
        let t = loadTarget(), k = self.k
        var g = current
        if g == 1 && t == 1 { return }
        for f in 0..<frames {
            g = Self.step(g, toward: t, k: k)
            if g == 1 { continue }
            for c in 0..<channels {
                let i = f * channels + c
                p[i] = Int32(max(-2_147_483_648.0, min(2_147_483_520.0, Double(p[i]) * Double(g))))
            }
        }
        current = g
    }

    /// Keeps a boosted signal from wrapping or hard-clipping: untouched up to 0.98, then rounded off smoothly to 1.
    @inline(__always) static func guardPeak(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.98 { return x }
        let s = 0.98 + 0.02 * tanhf((a - 0.98) / 0.02)
        return x < 0 ? -s : s
    }
}

// MARK: - The render thread's view of one output

/// role → (already done by the caller) → delay → level → Int32. The level comes after the delay on purpose: a delay of up to half a second
/// in front of it would make a level change arrive that much later than the hardware volume change it goes with.
enum OutputStage {
    @inline(__always)
    static func run(processor: RoleProcessor, delay: StereoDelay, level: SmoothGain, input: UnsafePointer<Float>, frames: Int, into out: UnsafeMutablePointer<Int32>) {
        let t = level.loadTarget(), k = level.coefficient
        var g = level.value
        for i in 0..<frames {
            let (a, b) = processor.process(input[i * 2], input[i * 2 + 1])
            var (da, db) = delay.process(a, b)
            g = SmoothGain.step(g, toward: t, k: k)
            if g != 1 {
                da *= g; db *= g
                if g > 1 { da = SmoothGain.guardPeak(da); db = SmoothGain.guardPeak(db) }
            }
            out[i * 2] = Int32(max(-2_147_483_648.0, min(2_147_483_520.0, Double(da) * 2_147_483_648.0)))
            out[i * 2 + 1] = Int32(max(-2_147_483_648.0, min(2_147_483_520.0, Double(db) * 2_147_483_648.0)))
        }
        level.store(g)
    }
}

// MARK: - A device's volume curve

/// How a device's 0…1 volume maps to decibels. Two devices at the same scalar are generally at different levels; the same decibels are the
/// same level. Built from the device's own table, or the generic curve when it will not say.
struct VolumeCurve: Equatable {
    private(set) var scalars: [Float]
    private(set) var dbs: [Double]

    /// nil when there are fewer than two usable points or the points do not span at least 1 dB.
    init?(points: [(scalar: Float, db: Double)]) {
        let clean = points.filter { $0.scalar.isFinite && $0.db.isFinite }
            .map { (scalar: min(max($0.scalar, 0), 1), db: $0.db) }
            .sorted { $0.scalar < $1.scalar }
        guard clean.count >= 2 else { return nil }
        var s: [Float] = [], d: [Double] = []
        for p in clean {
            if let last = s.last, last == p.scalar { continue }
            s.append(p.scalar); d.append(max(p.db, d.last ?? p.db))       // a volume control only ever gets louder
        }
        guard s.count >= 2, let lo = d.first, let hi = d.last, hi - lo >= 1 else { return nil }
        scalars = s; dbs = d
    }

    /// 60 dB between silence and full, linear in decibels. Used for a device that will not describe its own curve; with it on every
    /// output the same scalar is the same level, which is what matching volumes did before curves were read.
    static let generic = VolumeCurve(points: (0...16).map { (Float($0) / 16, -60 * (1 - Double($0) / 16)) })!

    var minDB: Double { dbs.first! }
    var maxDB: Double { dbs.last! }

    func db(at scalar: Float) -> Double {
        let s = scalar.isFinite ? min(max(scalar, 0), 1) : 0
        guard let hi = scalars.firstIndex(where: { $0 >= s }) else { return maxDB }
        if hi == 0 || scalars[hi] == s { return dbs[hi] }
        let lo = hi - 1, f = Double((s - scalars[lo]) / (scalars[hi] - scalars[lo]))
        return dbs[lo] + (dbs[hi] - dbs[lo]) * f
    }

    /// The scalar for a level, held to the device's range.
    func scalar(forDB db: Double) -> Float {
        guard db.isFinite else { return db > 0 ? 1 : 0 }
        if db <= minDB { return scalars.first! }
        if db >= maxDB { return scalars.last! }
        let hi = dbs.firstIndex(where: { $0 >= db })!, lo = hi - 1
        let span = dbs[hi] - dbs[lo]
        return span <= 0 ? scalars[hi] : scalars[lo] + Float((db - dbs[lo]) / span) * (scalars[hi] - scalars[lo])
    }
}

extension OutputDevice {
    /// The device's own volume-to-decibel table, sampled at `steps` + 1 points; nil when it has none.
    func volumeCurve(steps: Int = 32) -> VolumeCurve? {
        for element in [UInt32(0), 1] {
            let a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalarToDecibels, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            var probe = a
            guard AudioObjectHasProperty(id, &probe) else { continue }
            var pts: [(scalar: Float, db: Double)] = []
            for i in 0...steps {
                let s = Float32(i) / Float32(steps)
                guard let db: Float32 = getValue(id, a, default: s) else { break }      // the property translates in place: scalar in, decibels out
                pts.append((s, Double(db)))
            }
            if pts.count == steps + 1, let c = VolumeCurve(points: pts) { return c }
        }
        return nil
    }
}

// MARK: - Planning

/// What one output should do for a given master level, split between the device's own volume and our digital gain.
struct OutputLevel: Equatable {
    /// Where the device's volume control should sit; nil when it has none (or is not ours to move).
    var hardwareDB: Double?
    /// What the digital path adds on top: usually zero while the hardware has range, and the remainder when it has not.
    var digitalDB: Double
}

enum SpeakerCalibration {
    /// The most the digital path boosts; hardware headroom is used first, and a boosted signal is also peak-guarded.
    static let digitalBoostLimitDB = 3.0
    static let digitalFloorDB = -90.0
    static let trimRangeDB = -30.0...12.0

    /// What typical music looks like to a speaker that plays only part of it.
    struct Assumptions: Equatable {
        /// How alike the two channels usually are (0 = unrelated, 1 = mono). Pop and rock mixes sit around 0.6.
        var correlation = 0.6
        /// The share of the centre signal's energy that lies below a typical subwoofer crossover.
        var bassShare = 0.3
        /// The most a role is brought up to match the others.
        var maxMakeupDB = 6.0
    }

    /// The share of one main channel's energy that this role's channels carry, for music like `a`.
    static func energyShare(_ role: SpeakerRole, _ a: Assumptions = Assumptions()) -> Double {
        let r = a.correlation.isFinite ? min(max(a.correlation, 0), 1) : Assumptions().correlation, mid = (1 + r) / 2, side = (1 - r) / 2
        switch role {
        case .main, .left, .right: return 1
        case .center: return mid
        case .surround: return max(side, 1e-3)
        case .bass: return max(mid * (a.bassShare.isFinite ? min(max(a.bassShare, 0), 1) : Assumptions().bassShare), 1e-3)
        }
    }

    /// How far a role sits from the main level, in dB: first brought up to the loudness of a full-range speaker (limited to `maxMakeupDB`),
    /// then placed where it belongs in the room: bass sits 3 dB behind the music, and ambience 6 dB behind it (see `ambienceOffsetDB`).
    /// Ambience is a layer behind the music, never level with it or above it. (Boosting it to match the energy of a full-range speaker made the room louder
    /// than the beat: the whole sound went hall-like.)
    static let ambienceOffsetDB = -6.0

    static func roleOffsetDB(_ role: SpeakerRole, _ a: Assumptions = Assumptions()) -> Double {
        let makeup = min(max(-10 * log10(energyShare(role, a)), 0), a.maxMakeupDB)
        switch role {
        case .main, .left, .right, .center: return makeup
        case .surround: return ambienceOffsetDB
        case .bass: return makeup - 3
        }
    }

    /// The level each member should play at relative to the master volume: the automatic role balance (when switched on) plus the user's own trim.
    static func offsetsDB(_ members: [SpeakerMember], autoLevel: Bool, _ a: Assumptions = Assumptions()) -> [Double] {
        members.map { m in
            let trim = m.trimDB.isFinite ? min(max(m.trimDB, trimRangeDB.lowerBound), trimRangeDB.upperBound) : 0
            return (autoLevel ? roleOffsetDB(m.role, a) : 0) + trim
        }
    }

    struct Spec {
        var curve: VolumeCurve?       // nil: no hardware volume
        var isMain: Bool              // the main output's hardware volume is the master: the user moves it, not us
        var offsetDB: Double
    }

    /// `masterDB` is where the main output's volume control is (nil when it will not say: hardware is then left alone).
    ///
    /// Every output ends up `offsetDB` away from the master, by the device's own volume first and our digital gain for the remainder.
    /// While the master moves inside every device's range the digital gain does not move at all.
    static func solve(masterDB: Double?, _ specs: [Spec]) -> [OutputLevel] {
        specs.map { s in
            let offset = s.offsetDB.isFinite ? s.offsetDB : 0
            func digital(_ d: Double) -> Double { min(max(d, digitalFloorDB), digitalBoostLimitDB) }
            if s.isMain { return OutputLevel(hardwareDB: masterDB, digitalDB: digital(offset)) }
            guard let master = masterDB else { return OutputLevel(hardwareDB: nil, digitalDB: digital(offset)) }
            let total = master + offset
            guard let c = s.curve else { return OutputLevel(hardwareDB: nil, digitalDB: digital(total)) }
            let hw = min(max(total, c.minDB), c.maxDB)
            return OutputLevel(hardwareDB: hw, digitalDB: digital(total - hw))
        }
    }
}

// MARK: - Moving a hardware volume without a step

/// A level that travels toward its target at a steady rate in dB, so a jump of the volume is a short, even slide on every output.
struct LevelRamp: Equatable {
    static let slewDBPerSecond = 150.0
    static let maxDuration = 0.12

    private(set) var current: Double
    private(set) var target: Double
    private var rate = LevelRamp.slewDBPerSecond

    init(at db: Double) { current = db; target = db }

    /// A new target from wherever the ramp is now: small moves track at the slew rate, large ones take `maxDuration`.
    mutating func retarget(to db: Double) {
        target = db
        rate = max(Self.slewDBPerSecond, abs(target - current) / Self.maxDuration)
    }

    var settled: Bool { current == target }

    @discardableResult
    mutating func advance(by seconds: Double) -> Double {
        let step = rate * max(0, seconds)
        if abs(target - current) <= step { current = target } else { current += target > current ? step : -step }
        return current
    }
}

/// Keeps every output of a multi-device sink at its calibrated level. Runs on its own serial queue, never on a render thread: it moves the
/// hardware volumes in short slides and hands the digital levels to the render threads through `SmoothGain`.
final class LevelFollower: @unchecked Sendable {
    final class Output: @unchecked Sendable {
        let name: String
        let isMain: Bool
        let curve: VolumeCurve?
        let gain: SmoothGain
        let write: (@Sendable (Float) -> Void)?
        fileprivate var ramp: LevelRamp?
        fileprivate var written: Float = -1
        init(name: String, isMain: Bool, curve: VolumeCurve?, gain: SmoothGain, write: (@Sendable (Float) -> Void)?) {
            self.name = name; self.isMain = isMain; self.curve = curve; self.gain = gain; self.write = write
        }
    }

    static let tick = 0.008
    /// Hardware volume steps smaller than this are not worth a CoreAudio call (the last one of a slide is always written).
    static let writeResolution: Float = 0.002

    private let queue = DispatchQueue(label: "aureon.levelFollower", qos: .userInitiated)
    private let outputs: [Output]
    private let manualClock: Bool
    private var offsets: [Double]
    private var masterDB: Double?
    private var timer: DispatchSourceTimer?
    private var lastTick: UInt64 = 0
    private(set) var writes = 0                               // hardware writes made, for tests and diagnostics (queue only)

    /// `manualClock` leaves the timer off; the caller moves time with `advance`.
    init(outputs: [Output], offsets: [Double], manualClock: Bool = false) {
        self.outputs = outputs; self.offsets = offsets; self.manualClock = manualClock
    }

    private var mainCurve: VolumeCurve { outputs.first { $0.isMain }?.curve ?? .generic }

    // MARK: control

    /// Before the stream starts: puts every output on its level at once.
    func prime(masterScalar: Float?) {
        queue.sync { masterDB = masterScalar.map { mainCurve.db(at: $0) }; retarget(immediate: true) }
    }

    /// The master (main output) volume changed.
    func setMaster(scalar: Float) {
        queue.async { [self] in masterDB = mainCurve.db(at: scalar); retarget(immediate: false) }
    }

    /// Roles or trims changed.
    func setOffsets(_ new: [Double]) {
        queue.async { [self] in offsets = new; retarget(immediate: false) }
    }

    func stop() { queue.sync { timer?.cancel(); timer = nil } }

    /// Waits for everything queued so far.
    func flush() { queue.sync {} }

    /// Where every output is aiming right now.
    var levels: [OutputLevel] { queue.sync { plan() } }

    /// Moves time on by hand (tests, or a caller with its own clock).
    func advance(_ seconds: Double) {
        queue.sync {
            var left = seconds
            while left > 1e-12 { let dt = min(left, Self.tick); step(dt); left -= dt }
        }
    }

    var hardwareWrites: Int { queue.sync { writes } }
    func hardwareDB(of index: Int) -> Double? { queue.sync { outputs.indices.contains(index) ? outputs[index].ramp?.current : nil } }

    // MARK: queue-only

    private func plan() -> [OutputLevel] {
        SpeakerCalibration.solve(masterDB: masterDB, outputs.indices.map { i in
            SpeakerCalibration.Spec(curve: outputs[i].curve, isMain: outputs[i].isMain, offsetDB: i < offsets.count ? offsets[i] : 0)
        })
    }

    private func retarget(immediate: Bool) {
        var sliding = false
        for (o, level) in zip(outputs, plan()) {
            if immediate { o.gain.reset(to: SmoothGain.linear(db: level.digitalDB)) } else { o.gain.setTarget(db: level.digitalDB) }
            guard !o.isMain, let write = o.write, let hw = level.hardwareDB else { o.ramp = nil; continue }
            if immediate || o.ramp == nil {
                o.ramp = LevelRamp(at: hw)
                put(o, hw, write)
            } else {
                o.ramp!.retarget(to: hw)
                sliding = sliding || !o.ramp!.settled
            }
        }
        if sliding { startTimer() }
    }

    private func put(_ o: Output, _ db: Double, _ write: @Sendable (Float) -> Void) {
        let s = (o.curve ?? .generic).scalar(forDB: db)
        write(s); o.written = s; writes += 1
    }

    private func step(_ dt: Double) {
        var moving = false
        for o in outputs {
            guard var r = o.ramp, !r.settled, let write = o.write else { continue }
            r.advance(by: dt)
            o.ramp = r
            let s = (o.curve ?? .generic).scalar(forDB: r.current)
            if r.settled || abs(s - o.written) >= Self.writeResolution { write(s); o.written = s; writes += 1 }
            moving = moving || !r.settled
        }
        if !moving { timer?.cancel(); timer = nil }
    }

    private func startTimer() {
        guard !manualClock, timer == nil else { return }
        lastTick = DispatchTime.now().uptimeNanoseconds
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let dt = min(0.05, Double(now &- self.lastTick) / 1e9)
            self.lastTick = now
            self.step(dt)
        }
        timer = t
        t.resume()
    }
}

// MARK: - Latest value wins

/// Sends the newest of a stream of values one at a time, in order, skipping the ones that were overtaken while a send was in flight. For a
/// volume slider talking to a network speaker: nothing queues up, nothing arrives out of order, and the last value always arrives.
final class CoalescingSender<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var running = false
    private let send: @Sendable (Value) async -> Void

    init(send: @escaping @Sendable (Value) async -> Void) { self.send = send }

    func submit(_ v: Value) {
        lock.lock()
        pending = v
        let start = !running
        running = true
        lock.unlock()
        if start { Task.detached { [self] in await drain() } }
    }

    private func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let next = pending else { running = false; return nil }
        pending = nil
        return next
    }

    private func drain() async {
        while let next = take() { await send(next) }
    }
}

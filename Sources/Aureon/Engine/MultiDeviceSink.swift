import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

// Several output devices at once, each with a job. A MacBook's own speakers next to a pair of table speakers on the headphone jack, for example:
// the table speakers play the stereo picture, the MacBook plays the centre (voice) or the ambience, and either can take the bass.
//
// One device is the clock master: its callback pulls the audio from the engine, plays its own part, and hands a copy to every other device
// through a lock-free ring. The other devices play from those rings. Each part has its own crossover filter, level and delay (the delay
// follows from how far each speaker is from the listener, so the sound from all of them arrives together).

enum SpeakerRole: String, Codable, CaseIterable, Identifiable {
    case main, left, right, center, surround, bass
    var id: String { rawValue }
    var title: String {
        switch self {
        case .main: "Stereo (left and right)"
        case .left: "Left only"
        case .right: "Right only"
        case .center: "Centre / voice"
        case .surround: "Ambience / surround"
        case .bass: "Bass"
        }
    }
    var blurb: String {
        switch self {
        case .main: "Plays both channels as recorded."
        case .left: "Plays the left channel on every output of this device."
        case .right: "Plays the right channel on every output of this device."
        case .center: "Plays what the two channels have in common, which is where vocals and dialogue sit."
        case .surround: "Plays the music whole at the low notes, so the beat stays, and adds the room above them: what differs between the channels, with the centre kept low. Sits 6 dB behind the stereo speakers."
        case .bass: "Plays only the low notes, from both channels combined."
        }
    }
    var symbol: String {
        switch self { case .main: "hifispeaker.2"; case .left: "arrow.left.circle"; case .right: "arrow.right.circle"; case .center: "person.wave.2"; case .surround: "dot.radiowaves.left.and.right"; case .bass: "waveform.path" }
    }
}

struct SpeakerMember: Codable, Equatable, Identifiable {
    var uid: String
    var name: String
    var role = SpeakerRole.main
    /// How far the speaker is from where you sit, in metres (0 = not set). The nearer speakers are delayed so everything arrives together.
    var distanceM = 0.0
    var extraDelayMs = 0.0
    var trimDB = 0.0
    var id: String { uid }
}

struct SpeakerSetup: Codable, Equatable {
    var enabled = false
    var members: [SpeakerMember] = []
    var crossoverHz = 100.0
    /// When a device plays the bass, the others stop playing it (they are high-passed at the crossover).
    var bassManagement = true
    /// Balances the outputs by their jobs (see `SpeakerCalibration`) and keeps them balanced when the volume changes.
    var autoLevel = true

    enum CodingKeys: String, CodingKey { case enabled, members, crossoverHz, bassManagement, autoLevel }
}

extension SpeakerSetup {
    /// Saves from before `autoLevel` existed have no such key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        members = try c.decodeIfPresent([SpeakerMember].self, forKey: .members) ?? []
        crossoverHz = try c.decodeIfPresent(Double.self, forKey: .crossoverHz) ?? 100
        bassManagement = try c.decodeIfPresent(Bool.self, forKey: .bassManagement) ?? true
        autoLevel = try c.decodeIfPresent(Bool.self, forKey: .autoLevel) ?? true
    }
}

/// What each member does, worked out from the setup. Pure arithmetic, so it can be tested.
enum SpeakerPlan {
    struct Entry: Equatable { var role: SpeakerRole; var gain: Float; var delayFrames: Int; var highPass: Bool }
    static let speedOfSound = 343.0

    /// The delay each output needs so that all of them play at the same moment: the one that is slowest to get sound out needs none, the others wait for it.
    /// An output whose latency is unknown is taken to be as slow as the slowest known one (it is left alone).
    static func alignmentSeconds(latencies: [Double?]) -> [Double] {
        let known = latencies.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        guard let slowest = known.max() else { return latencies.map { _ in 0 } }
        return latencies.map { l in if let l, l.isFinite, l >= 0 { return slowest - l } else { return 0 } }
    }

    /// `latencySeconds`: how late each output plays what it is given (from the device); the earlier ones are delayed to match the latest. `extraDelayMs` is a
    /// trim by ear for each output, and may be negative (earlier): everything is then moved later together, so no delay is ever below zero.
    static func entries(_ members: [SpeakerMember], rate: Double, bassManagement: Bool, extraLatencyFrames: [Int], latencySeconds: [Double?] = [], maxDelaySeconds: Double = 0.5) -> [Entry] {
        let far = members.map(\.distanceM).max() ?? 0
        let hasBass = members.contains { $0.role == .bass }
        let align = alignmentSeconds(latencies: members.indices.map { $0 < latencySeconds.count ? latencySeconds[$0] : nil })
        let raw = members.enumerated().map { i, m -> Double in
            let travel = m.distanceM > 0 ? max(0, far - m.distanceM) / speedOfSound : 0
            let extra = m.extraDelayMs.isFinite ? m.extraDelayMs : 0
            return travel + align[i] + extra / 1000
        }
        let lift = max(0, -(raw.min() ?? 0))
        return members.enumerated().map { i, m in
            let seconds = min(maxDelaySeconds, max(0, raw[i] + lift))
            let frames = Int((seconds * rate).rounded()) + (i < extraLatencyFrames.count ? extraLatencyFrames[i] : 0)
            return Entry(role: m.role, gain: Float(pow(10, max(-30, min(12, m.trimDB)) / 20)), delayFrames: frames, highPass: bassManagement && hasBass && m.role != .bass)
        }
    }
}

// MARK: - DSP

/// One second-order section (transposed direct form II), in Double so low crossovers stay accurate.
struct CrossoverBiquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    static func butterworth(low: Bool, freq: Double, rate: Double) -> CrossoverBiquad {
        let f = min(max(10, freq), rate * 0.45), w = 2 * Double.pi * f / rate, c = cos(w), alpha = sin(w) / (2 * 0.70710678118654752)
        let a0 = 1 + alpha
        var q = CrossoverBiquad()
        if low { q.b0 = (1 - c) / 2 / a0; q.b1 = (1 - c) / a0; q.b2 = (1 - c) / 2 / a0 }
        else { q.b0 = (1 + c) / 2 / a0; q.b1 = -(1 + c) / a0; q.b2 = (1 + c) / 2 / a0 }
        q.a1 = -2 * c / a0; q.a2 = (1 - alpha) / a0
        return q
    }

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Fourth-order Linkwitz-Riley: two Butterworth sections in a row. Low and high outputs add back to a flat response.
struct LR4 {
    var s1: CrossoverBiquad, s2: CrossoverBiquad
    init(low: Bool, freq: Double, rate: Double) { s1 = .butterworth(low: low, freq: freq, rate: rate); s2 = s1 }
    @inline(__always) mutating func process(_ x: Double) -> Double { s2.process(s1.process(x)) }
}

/// The part one device plays: picks the signal for its role and filters it. Filter state lives here, so a new one is made when the role,
/// the crossover or the high-pass changes. The level is not applied here: it lives in the output's `SmoothGain`, so changing a level
/// neither restarts the filters nor steps.
final class RoleProcessor: @unchecked Sendable {
    let role: SpeakerRole
    private var low: LR4, highA: LR4, highB: LR4
    private var ambienceMid: LR4, ambienceSide: LR4          // the high-pass of the centre and of the sides, for the ambience role
    private let highPass: Bool
    /// How much of the centre the ambience role keeps above the crossover: about -12 dB, so the sides lead there but the beat is still in the room.
    static let ambienceCentre = 0.25
    /// Where the ambience role starts to differ from the stereo speakers: everything below 150 Hz is kept exactly as it is.
    static let ambienceCrossover = 200.0

    init(entry: SpeakerPlan.Entry, crossover: Double, rate: Double) {
        role = entry.role; highPass = entry.highPass
        low = LR4(low: true, freq: crossover, rate: rate)
        highA = LR4(low: false, freq: crossover, rate: rate); highB = highA
        ambienceMid = LR4(low: false, freq: Self.ambienceCrossover, rate: rate); ambienceSide = ambienceMid
    }

    @inline(__always) func process(_ l: Float, _ r: Float) -> (Float, Float) {
        var a = Double(l), b = Double(r)
        switch role {
        case .main: break
        case .left: b = a
        case .right: a = b
        case .center: a = (a + b) * 0.5; b = a
        case .surround:
            // Ambience keeps the music whole where it carries the beat and the weight, and adds the room above the crossover. Below the crossover it plays the centre
            // exactly as the stereo speakers do (same phase, so the two reinforce and never cancel); above it the sides (what differs between the channels: width and
            // reverb) lead and the centre is held back (to about -12 dB at the top of the range, easing in through the middle). Nothing is inverted, delayed or decorrelated.
            let mid = (a + b) * 0.5, side = (a - b) * 0.5
            a = mid - (1 - Self.ambienceCentre) * ambienceMid.process(mid) + ambienceSide.process(side); b = a
        case .bass: a = low.process((a + b) * 0.5); b = a
        }
        if highPass { a = highA.process(a); b = highB.process(b) }
        return (Float(a), Float(b))
    }
}

/// A delay of whole frames on a stereo pair, in a buffer allocated once (nothing is allocated or locked while it runs). When the length changes, the output
/// cross-fades from the old length to the new over a few milliseconds instead of jumping, so a retune never clicks. Used by one render thread only.
final class StereoDelay: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<Float>
    private let cap: Int
    private var w = 0
    private var current = 0, previous = 0, fadeStep = Int.max
    private var started = false           // the first length is taken as it is, with no fade from nothing
    /// The length of the cross-fade (frames).
    static let fadeFrames = 512
    let frames = Atomic<Int>(0)
    init(maxFrames: Int) { cap = maxFrames + 1; buf = .allocate(capacity: cap * 2); buf.initialize(repeating: 0, count: cap * 2) }
    deinit { buf.deallocate() }

    var capacity: Int { cap - 1 }
    func setFrames(_ n: Int) { frames.store(min(max(0, n), cap - 1), ordering: .relaxed) }

    @inline(__always) private func tap(_ d: Int) -> (Float, Float) {
        var r = w - d; if r < 0 { r += cap }
        return (buf[r * 2], buf[r * 2 + 1])
    }

    @inline(__always) func process(_ a: Float, _ b: Float) -> (Float, Float) {
        let want = frames.load(ordering: .relaxed)
        if !started { started = true; current = want; previous = want }
        else if want != current { previous = current; current = want; fadeStep = 0 }
        buf[w * 2] = a; buf[w * 2 + 1] = b
        var out = tap(current)
        if fadeStep < Self.fadeFrames {
            let t = Float(fadeStep + 1) / Float(Self.fadeFrames), old = tap(previous)
            out = (old.0 + (out.0 - old.0) * t, old.1 + (out.1 - old.1) * t)
            fadeStep += 1
        }
        w += 1; if w == cap { w = 0 }
        return out
    }
}

/// Single-producer, single-consumer ring of stereo frames. Wait-free on both sides.
final class StereoRing: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<Float>
    private let cap: Int, mask: Int
    private let head = Atomic<Int>(0)          // consumer position (frames since start)
    private let tail = Atomic<Int>(0)          // producer position
    init(frames: Int) {
        var c = 1; while c < frames { c <<= 1 }
        cap = c; mask = c - 1
        buf = .allocate(capacity: c * 2); buf.initialize(repeating: 0, count: c * 2)
    }
    deinit { buf.deallocate() }

    var fill: Int { tail.load(ordering: .acquiring) - head.load(ordering: .acquiring) }

    /// Returns how many frames fitted; the rest are dropped (the consumer is behind).
    @inline(__always) func write(_ p: UnsafePointer<Float>, frames n: Int) -> Int {
        let t = tail.load(ordering: .relaxed), h = head.load(ordering: .acquiring)
        let room = cap - (t - h), k = min(n, room)
        for i in 0..<k { let j = ((t + i) & mask) * 2; buf[j] = p[i * 2]; buf[j + 1] = p[i * 2 + 1] }
        tail.store(t + k, ordering: .releasing)
        return k
    }

    @inline(__always) func read(into p: UnsafeMutablePointer<Float>, frames n: Int) -> Int {
        let h = head.load(ordering: .relaxed), t = tail.load(ordering: .acquiring)
        let k = min(n, t - h)
        for i in 0..<k { let j = ((h + i) & mask) * 2; p[i * 2] = buf[j]; p[i * 2 + 1] = buf[j + 1] }
        head.store(h + k, ordering: .releasing)
        return k
    }

    /// Consumer side: throws away the oldest `n` frames.
    @inline(__always) func discard(_ n: Int) {
        let h = head.load(ordering: .relaxed), t = tail.load(ordering: .acquiring)
        head.store(h + min(n, t - h), ordering: .releasing)
    }
}

// MARK: - The sink

/// What a `RoleProcessor` was built for: when none of it changed, the running one (and its filter state) stays.
struct ProcessorShape: Equatable { var role: SpeakerRole; var highPass: Bool; var crossover: Double; var rate: Double }

final class MultiDeviceSink: AudioSink, @unchecked Sendable {
    /// One device taking part.
    final class Part: @unchecked Sendable {
        let device: OutputDevice
        let member: SpeakerMember
        let delay: StereoDelay
        let processor = RCUBox<RoleProcessor>()
        let level = SmoothGain()               // trim + role balance + whatever the device's own volume cannot cover
        var shape: ProcessorShape?             // what `processor` was built for (control side)
        let ring: StereoRing?                // nil for the clock master
        var proc: AudioDeviceIOProcID?
        var scratch: UnsafeMutablePointer<Int32>?
        var pull: UnsafeMutablePointer<Float>?
        var map: UnsafeMutablePointer<Int>?
        var primed = false
        var originalVolume: Float?
        init(device: OutputDevice, member: SpeakerMember, ring: StereoRing?) { self.device = device; self.member = member; self.ring = ring; delay = StereoDelay(maxFrames: 262_144) }
    }

    private(set) var setup: SpeakerSetup
    private let primaryID: AudioDeviceID
    private let primaryOutput: CoreAudioSink
    private var parts: [Part] = []
    private let lock = NSLock()
    private var follower: LevelFollower!
    private var rate = 44_100.0
    private(set) var skipped: [String] = []
    /// How late each output plays what it is given (seconds, nil when it will not say), measured when the stream is configured and again on every format change.
    private(set) var outputLatencies: [Double?] = []
    private let blockMax = 16_384

    var deviceName: String { parts.isEmpty ? primaryOutput.deviceName : parts.map { $0.device.name }.joined(separator: " + ") }
    let supportedRates: [Double]
    var outputChannels: Int { 2 }
    var speakers: [Speaker?]? { [.fl, .fr] }

    /// nil when fewer than two of the chosen devices are present (the caller then plays through the normal output).
    init?(setup: SpeakerSetup, primaryID: AudioDeviceID?) {
        let all = listOutputDevices()
        let wanted = setup.members.compactMap { m in all.first { $0.uid == m.uid }.map { (m, $0) } }
        guard wanted.count >= 2 else { return nil }
        let primary = wanted.first { $0.1.id == primaryID } ?? wanted[0]
        guard let main = CoreAudioSink(deviceID: primary.1.id) else { return nil }
        self.setup = setup; self.primaryID = primary.1.id; primaryOutput = main
        var rates: [Double]? = nil
        for (_, info) in wanted where !info.rates.isEmpty { rates = rates.map { r in r.filter { x in info.rates.contains { abs($0 - x) < 0.5 } } } ?? info.rates }
        supportedRates = rates ?? []
        skipped = setup.members.filter { m in !all.contains { $0.uid == m.uid } }.map(\.name)
        // the master first, then the rest in the order chosen
        var order = [primary]
        order += wanted.filter { $0.1.id != primary.1.id }
        for (m, info) in order {
            guard let d = info.id == primary.1.id ? main.device : OutputDevice(id: info.id) else { continue }
            parts.append(Part(device: d, member: m, ring: info.id == primary.1.id ? nil : StereoRing(frames: 1 << 16)))
        }
        guard parts.count >= 2 else { return nil }
        // curves and volume controls are read here, once, off the render threads
        let initial = SpeakerCalibration.offsetsDB(parts.map(\.member), autoLevel: setup.autoLevel)
        var outputs: [LevelFollower.Output] = []
        for (i, p) in parts.enumerated() {
            let dev = p.device
            let hasVolume = dev.hasHardwareVolume
            let curve: VolumeCurve? = hasVolume ? (dev.volumeCurve() ?? VolumeCurve.generic) : nil
            var writer: (@Sendable (Float) -> Void)?
            if i > 0, hasVolume { writer = { v in dev.writeVolume(v) } }
            outputs.append(LevelFollower.Output(name: dev.name, isMain: i == 0, curve: curve, gain: p.level, write: writer))
        }
        follower = LevelFollower(outputs: outputs, offsets: initial)
    }

    /// The volume an output starts at when it joins: the main output's, or, when that is unknown, no more than a cautious level.
    static func joiningVolume(current: Float?, main: Float?) -> Float? {
        if let main { return min(1, max(0, main)) }
        return current.map { min($0, 0.35) }
    }

    /// Keeps the other outputs in balance with the main output while its volume is changed: each follows in decibels (not in scalar steps,
    /// which are different loudness on different devices) and slides to its level in a few milliseconds.
    func matchOthers(to volume: Float) { follower.setMaster(scalar: volume) }

    /// What each output is aiming at now, in order (the main output first).
    var outputLevels: [OutputLevel] { follower.levels }

    // MARK: configure / start

    func configure(for info: StreamInfo, options: PlayerOptions) -> SinkReport {
        rate = info.sampleRate
        for p in parts { p.level.configure(rate: rate) }
        var lines = primaryOutput.configure(for: info, options: options).lines
        for p in parts.dropFirst() {
            if options.rateSwitch, p.device.canRun(at: info.sampleRate) { _ = p.device.setRate(info.sampleRate) }
            _ = p.device.requestInt32Virtual(rate: info.sampleRate, channels: 2)
        }
        outputLatencies = parts.map { $0.device.outputLatencySeconds }
        lines.append("Speaker setup: " + parts.map { "\($0.device.name) as \($0.member.role.title.lowercased())" }.joined(separator: ", "))
        if !skipped.isEmpty { lines.append("Not connected, left out: " + skipped.joined(separator: ", ")) }
        // an output that joins in must not come in at whatever level it was last left at: it comes in at its calibrated level before any sound reaches it
        let main = primaryOutput.device.readVolume()
        for p in parts.dropFirst() { p.originalVolume = p.device.readVolume() }
        publish(setup)
        if main == nil {
            // nothing to follow: the others are held to a cautious level
            for p in parts.dropFirst() { if let v = Self.joiningVolume(current: p.originalVolume, main: nil) { p.device.writeVolume(v) } }
        }
        follower.prime(masterScalar: main)
        lines.append(main != nil ? "Outputs levelled against the main output's volume (\(Int((main ?? 0) * 100)) %)" + (setup.autoLevel ? ", balanced by role" : "") : "The main output does not report a volume: the others were limited to a low level")
        return SinkReport(lines: lines, bitPerfect: false)
    }

    /// Applies new roles, levels, delays and crossover to a running setup, without stopping the music.
    func update(_ new: SpeakerSetup) {
        lock.lock(); defer { lock.unlock() }
        setup = new
        publish(new)
    }

    private var ringLatency: Int { Int(rate * 0.04) }

    private func publish(_ s: SpeakerSetup) {
        let current = parts.map { p in s.members.first { $0.uid == p.member.uid } ?? p.member }
        let entries = SpeakerPlan.entries(current, rate: rate, bassManagement: s.bassManagement, extraLatencyFrames: parts.indices.map { $0 == 0 ? ringLatency : 0 }, latencySeconds: outputLatencies, maxDelaySeconds: 1.0)
        for (i, p) in parts.enumerated() {
            // a new processor restarts the filters: only when something it was built for changed (a level or a delay never does)
            let shape = ProcessorShape(role: entries[i].role, highPass: entries[i].highPass, crossover: s.crossoverHz, rate: rate)
            if p.shape != shape { p.processor.publish(RoleProcessor(entry: entries[i], crossover: s.crossoverHz, rate: rate)); p.shape = shape }
            p.delay.setFrames(entries[i].delayFrames)
        }
        follower.setOffsets(SpeakerCalibration.offsetsDB(current, autoLevel: s.autoLevel))
    }

    func start(renderer: Renderer) throws {
        let fileCh = renderer.channels, blockMax = self.blockMax
        let target = ringLatency
        for p in parts {
            p.scratch = .allocate(capacity: blockMax * 2); p.scratch!.initialize(repeating: 0, count: blockMax * 2)
            p.pull = .allocate(capacity: blockMax * 2); p.pull!.initialize(repeating: 0, count: blockMax * 2)
            let ch = max(p.device.outputChannelCount, 2)
            p.map = .allocate(capacity: ch); p.map!.initialize(repeating: -1, count: ch); p.map![0] = 0; p.map![1] = 1
            p.primed = false
        }
        let master = parts[0]
        let rings = parts.dropFirst().compactMap(\.ring)
        let masterBuf = UnsafeMutablePointer<Int32>.allocate(capacity: blockMax * max(fileCh, 1))
        masterBuf.initialize(repeating: 0, count: blockMax * max(fileCh, 1))
        masterScratch = masterBuf
        let masterFloat = UnsafeMutablePointer<Float>.allocate(capacity: blockMax * 2)
        masterFloat.initialize(repeating: 0, count: blockMax * 2)
        masterFloatScratch = masterFloat

        // secondaries first: they wait for the ring to fill
        for p in parts.dropFirst() { try startSecondary(p, target: target) }

        let isFloat = (master.device.virtualFormat()?.mFormatFlags ?? kAudioFormatFlagIsFloat) & kAudioFormatFlagIsFloat != 0
        let devCh = max(master.device.outputChannelCount, 2)
        let mScratch = master.scratch!, mMap = master.map!
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, master.device.id, nil) { _, _, _, outData, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outData)
            guard let b = abl.first else { return }
            let nch = max(Int(b.mNumberChannels), 1)
            let frames = min(Int(b.mDataByteSize) / (nch * 4), blockMax)
            let got = renderer.render(into: masterBuf, frames: frames)
            let k = fileCh
            for i in 0..<got {
                masterFloat[i * 2] = Float(masterBuf[i * k]) / 2_147_483_648.0
                masterFloat[i * 2 + 1] = Float(masterBuf[i * k + (k > 1 ? 1 : 0)]) / 2_147_483_648.0
            }
            for r in rings { _ = r.write(masterFloat, frames: got) }
            Self.play(part: master, from: masterFloat, frames: got, into: mScratch)
            ChannelCopy.fill(source: mScratch, sourceChannels: 2, validFrames: got, frames: frames, buffers: abl, map: mMap, mapCount: devCh, float: isFloat)
        }, "AudioDeviceCreateIOProcID")
        guard let procID else { throw AureonError.message("could not create IOProc") }
        master.proc = procID
        try check(AudioDeviceStart(master.device.id, procID), "AudioDeviceStart")
    }

    private var masterScratch: UnsafeMutablePointer<Int32>?
    private var masterFloatScratch: UnsafeMutablePointer<Float>?

    /// role → crossover → delay → smoothed level → Int32 (left-justified) for the device.
    @inline(__always) private static func play(part: Part, from input: UnsafePointer<Float>, frames: Int, into out: UnsafeMutablePointer<Int32>) {
        _ = part.processor.read { proc in
            OutputStage.run(processor: proc, delay: part.delay, level: part.level, input: input, frames: frames, into: out)
        } ?? { for i in 0..<(frames * 2) { out[i] = 0 } }()
    }

    private func startSecondary(_ p: Part, target: Int) throws {
        guard let ring = p.ring, let scratch = p.scratch, let pull = p.pull, let map = p.map else { return }
        let isFloat = (p.device.virtualFormat()?.mFormatFlags ?? kAudioFormatFlagIsFloat) & kAudioFormatFlagIsFloat != 0
        let devCh = max(p.device.outputChannelCount, 2), blockMax = self.blockMax
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, p.device.id, nil) { _, _, _, outData, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outData)
            guard let b = abl.first else { return }
            let nch = max(Int(b.mNumberChannels), 1)
            let frames = min(Int(b.mDataByteSize) / (nch * 4), blockMax)
            var got = 0
            if !p.primed, ring.fill >= target { p.primed = true }
            if p.primed {
                // the clocks of two devices are never exactly equal: keep the backlog near the target by skipping ahead or, if it ran dry, waiting to refill
                let fill = ring.fill
                if fill > target + frames * 3 { ring.discard(fill - target - frames) }
                got = ring.read(into: pull, frames: frames)
                if got < frames { p.primed = false }
            }
            Self.play(part: p, from: pull, frames: got, into: scratch)
            ChannelCopy.fill(source: scratch, sourceChannels: 2, validFrames: got, frames: frames, buffers: abl, map: map, mapCount: devCh, float: isFloat)
        }, "AudioDeviceCreateIOProcID")
        guard let procID else { throw AureonError.message("could not create IOProc for \(p.device.name)") }
        p.proc = procID
        try check(AudioDeviceStart(p.device.id, procID), "AudioDeviceStart")
    }

    func stop() {
        for p in parts {
            if let id = p.proc { AudioDeviceStop(p.device.id, id); AudioDeviceDestroyIOProcID(p.device.id, id); p.proc = nil }
        }
        for p in parts {
            p.scratch?.deallocate(); p.scratch = nil
            p.pull?.deallocate(); p.pull = nil
            p.map?.deallocate(); p.map = nil
        }
        masterScratch?.deallocate(); masterScratch = nil
        masterFloatScratch?.deallocate(); masterFloatScratch = nil
    }

    func shutdown() {
        stop()
        follower.stop()
        for p in parts.dropFirst() {
            if let v = p.originalVolume { p.device.writeVolume(v) }
            p.device.restore()
        }
        primaryOutput.shutdown()
    }
}

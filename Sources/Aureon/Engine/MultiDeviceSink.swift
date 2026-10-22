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
        case .surround: "Plays what differs between the channels: reverb, room sound and wide effects."
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
}

/// What each member does, worked out from the setup. Pure arithmetic, so it can be tested.
enum SpeakerPlan {
    struct Entry: Equatable { var role: SpeakerRole; var gain: Float; var delayFrames: Int; var highPass: Bool }
    static let speedOfSound = 343.0

    static func entries(_ members: [SpeakerMember], rate: Double, bassManagement: Bool, extraLatencyFrames: [Int], maxDelaySeconds: Double = 0.5) -> [Entry] {
        let far = members.map(\.distanceM).max() ?? 0
        let hasBass = members.contains { $0.role == .bass }
        return members.enumerated().map { i, m in
            let travel = m.distanceM > 0 ? max(0, far - m.distanceM) / speedOfSound : 0
            let seconds = min(maxDelaySeconds, max(0, travel + m.extraDelayMs / 1000))
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

/// The part one device plays: picks the signal for its role, filters it, scales it. Filter state lives here, so a new one is made when settings change.
final class RoleProcessor: @unchecked Sendable {
    let role: SpeakerRole
    let gain: Double
    private var low: LR4, highA: LR4, highB: LR4
    private let highPass: Bool

    init(entry: SpeakerPlan.Entry, crossover: Double, rate: Double) {
        role = entry.role; gain = Double(entry.gain); highPass = entry.highPass
        low = LR4(low: true, freq: crossover, rate: rate)
        highA = LR4(low: false, freq: crossover, rate: rate); highB = highA
    }

    @inline(__always) func process(_ l: Float, _ r: Float) -> (Float, Float) {
        var a = Double(l), b = Double(r)
        switch role {
        case .main: break
        case .left: b = a
        case .right: a = b
        case .center: a = (a + b) * 0.5; b = a
        case .surround: a = (a - b) * 0.5; b = a
        case .bass: a = low.process((a + b) * 0.5); b = a
        }
        if highPass { a = highA.process(a); b = highB.process(b) }
        return (Float(a * gain), Float(b * gain))
    }
}

/// A delay of whole frames on a stereo pair. The length can change at any time (silence is inserted, or the oldest samples are skipped).
final class StereoDelay: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<Float>
    private let cap: Int
    private var w = 0
    let frames = Atomic<Int>(0)
    init(maxFrames: Int) { cap = maxFrames + 1; buf = .allocate(capacity: cap * 2); buf.initialize(repeating: 0, count: cap * 2) }
    deinit { buf.deallocate() }

    func setFrames(_ n: Int) { frames.store(min(max(0, n), cap - 1), ordering: .relaxed) }

    @inline(__always) func process(_ a: Float, _ b: Float) -> (Float, Float) {
        let d = frames.load(ordering: .relaxed)
        buf[w * 2] = a; buf[w * 2 + 1] = b
        var r = w - d; if r < 0 { r += cap }
        let out = (buf[r * 2], buf[r * 2 + 1])
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

final class MultiDeviceSink: AudioSink, @unchecked Sendable {
    /// One device taking part.
    final class Part: @unchecked Sendable {
        let device: OutputDevice
        let member: SpeakerMember
        let delay: StereoDelay
        let processor = RCUBox<RoleProcessor>()
        let ring: StereoRing?                // nil for the clock master
        var proc: AudioDeviceIOProcID?
        var scratch: UnsafeMutablePointer<Int32>?
        var pull: UnsafeMutablePointer<Float>?
        var map: UnsafeMutablePointer<Int>?
        var primed = false
        init(device: OutputDevice, member: SpeakerMember, ring: StereoRing?) { self.device = device; self.member = member; self.ring = ring; delay = StereoDelay(maxFrames: 96_000) }
    }

    private(set) var setup: SpeakerSetup
    private let primaryID: AudioDeviceID
    private let primaryOutput: CoreAudioSink
    private var parts: [Part] = []
    private let lock = NSLock()
    private var rate = 44_100.0
    private(set) var skipped: [String] = []
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
    }

    // MARK: configure / start

    func configure(for info: StreamInfo, options: PlayerOptions) -> SinkReport {
        rate = info.sampleRate
        var lines = primaryOutput.configure(for: info, options: options).lines
        for p in parts.dropFirst() {
            if options.rateSwitch, p.device.canRun(at: info.sampleRate) { _ = p.device.setRate(info.sampleRate) }
            _ = p.device.requestInt32Virtual(rate: info.sampleRate, channels: 2)
        }
        lines.append("Speaker setup: " + parts.map { "\($0.device.name) as \($0.member.role.title.lowercased())" }.joined(separator: ", "))
        if !skipped.isEmpty { lines.append("Not connected, left out: " + skipped.joined(separator: ", ")) }
        publish(setup)
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
        let entries = SpeakerPlan.entries(current, rate: rate, bassManagement: s.bassManagement, extraLatencyFrames: parts.indices.map { $0 == 0 ? ringLatency : 0 })
        for (i, p) in parts.enumerated() {
            p.processor.publish(RoleProcessor(entry: entries[i], crossover: s.crossoverHz, rate: rate))
            p.delay.setFrames(entries[i].delayFrames)
        }
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

    /// role → crossover → level → delay → Int32 (left-justified) for the device.
    @inline(__always) private static func play(part: Part, from input: UnsafePointer<Float>, frames: Int, into out: UnsafeMutablePointer<Int32>) {
        _ = part.processor.read { proc in
            for i in 0..<frames {
                let (a, b) = proc.process(input[i * 2], input[i * 2 + 1])
                let (da, db) = part.delay.process(a, b)
                out[i * 2] = Int32(max(-2_147_483_648.0, min(2_147_483_520.0, Double(da) * 2_147_483_648.0)))
                out[i * 2 + 1] = Int32(max(-2_147_483_648.0, min(2_147_483_520.0, Double(db) * 2_147_483_648.0)))
            }
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
        for p in parts.dropFirst() { p.device.restore() }
        primaryOutput.shutdown()
    }
}

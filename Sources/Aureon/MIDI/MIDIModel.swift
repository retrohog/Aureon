import Foundation
import Synchronization

// MIDI control surfaces, part 1: the value types. Nothing here touches CoreMIDI, the UI or the audio engine,
// so all of it can be exercised without hardware.
//
//   CoreMIDI thread ─► MIDIEventRing (lock-free) ─► main-thread drain ─► mapping ─► model setters ─► atomics ─► audio thread
//
// The audio render thread never sees MIDI. Continuous controls end up in the same `ParamF` / `ParamI` atomics that the
// on-screen knobs already write, and the parametric EQ goes through `DSPModel`, which hands settings to the engine thread.

// MARK: - Messages

enum MIDIControlKind: String, Codable, Sendable { case note, cc, pitchBend }

/// One physical control: a key, a knob or fader, or the bend wheel, on a MIDI channel.
struct MIDIControl: Hashable, Codable, Sendable {
    var kind: MIDIControlKind
    /// 0 … 15 (channel 1 … 16).
    var channel: Int
    /// Note or controller number; 0 for the pitch-bend wheel.
    var number: Int

    init(kind: MIDIControlKind, channel: Int, number: Int) {
        self.kind = kind; self.channel = max(0, min(15, channel)); self.number = kind == .pitchBend ? 0 : max(0, min(127, number))
    }

    var title: String {
        switch kind {
        case .note: return "Ch \(channel + 1) · Note \(number) (\(MIDIControl.noteName(number)))"
        case .cc: return "Ch \(channel + 1) · CC \(number)"
        case .pitchBend: return "Ch \(channel + 1) · Pitch bend"
        }
    }

    static func noteName(_ n: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[((n % 12) + 12) % 12] + String(n / 12 - 1)
    }

    /// For a 14-bit controller pair the least-significant byte arrives on controller `n + 32`.
    var lsbPartner: MIDIControl? { kind == .cc && number < 32 ? MIDIControl(kind: .cc, channel: channel, number: number + 32) : nil }
}

/// A message from a control. Notes carry the velocity (0 = released), controllers 0 … 127, the bend wheel 0 … 16383.
struct MIDIMessage: Equatable, Sendable {
    var control: MIDIControl
    var value: Int

    var maxValue: Int { control.kind == .pitchBend ? 16_383 : 127 }
    /// Pressed: a note-on, or a controller at or above half scale (buttons that send 127 / 0).
    var isPress: Bool { control.kind == .pitchBend ? value > 8_192 : value >= (control.kind == .note ? 1 : 64) }

    var summary: String { "\(control.title) = \(value)" }

    // Packed into 32 bits so the CoreMIDI thread can hand it over through one atomic ring slot:
    // kind (2) | channel (4) | number (7) | value (14).
    var packed: UInt32 {
        let k: UInt32 = control.kind == .note ? 0 : control.kind == .cc ? 1 : 2
        return k << 25 | UInt32(control.channel) << 21 | UInt32(control.number) << 14 | UInt32(max(0, min(16_383, value)))
    }

    init(control: MIDIControl, value: Int) { self.control = control; self.value = max(0, min(control.kind == .pitchBend ? 16_383 : 127, value)) }

    init?(packed p: UInt32) {
        let kind: MIDIControlKind
        switch (p >> 25) & 3 { case 0: kind = .note; case 1: kind = .cc; case 2: kind = .pitchBend; default: return nil }
        self.init(control: MIDIControl(kind: kind, channel: Int((p >> 21) & 15), number: Int((p >> 14) & 127)), value: Int(p & 16_383))
    }

    /// Reads one Universal MIDI Packet word of a MIDI 1.0 channel-voice message (message type 2). Everything else
    /// (clock, active sensing, sysex, program change, aftertouch) is not a control and gives nil.
    static func parse(word: UInt32) -> MIDIMessage? {
        guard (word >> 28) & 0xF == 2 else { return nil }
        let opcode = Int((word >> 20) & 0xF), ch = Int((word >> 16) & 0xF), d1 = Int((word >> 8) & 0x7F), d2 = Int(word & 0x7F)
        switch opcode {
        case 0x8: return MIDIMessage(control: MIDIControl(kind: .note, channel: ch, number: d1), value: 0)
        case 0x9: return MIDIMessage(control: MIDIControl(kind: .note, channel: ch, number: d1), value: d2)       // velocity 0 is a release
        case 0xB: return MIDIMessage(control: MIDIControl(kind: .cc, channel: ch, number: d1), value: d2)
        case 0xE: return MIDIMessage(control: MIDIControl(kind: .pitchBend, channel: ch, number: 0), value: d2 << 7 | d1)
        default: return nil
        }
    }
}

// MARK: - Lock-free hand-over

/// A single-producer / single-consumer ring of packed messages. The producer is CoreMIDI's input thread, the consumer the main
/// thread. Preallocated, no locks, no allocation; when it is full the newest message is dropped and counted.
final class MIDIEventRing: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let buf: UnsafeMutablePointer<UInt32>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let lost = Atomic<Int>(0)

    init(capacity: Int = 4_096) {
        var c = 2; while c < max(2, capacity) { c <<= 1 }
        self.capacity = c; mask = c - 1
        buf = .allocate(capacity: c); buf.initialize(repeating: 0, count: c)
    }
    deinit { buf.deallocate() }

    var dropped: Int { lost.load(ordering: .relaxed) }
    var isEmpty: Bool { head.load(ordering: .acquiring) == tail.load(ordering: .acquiring) }

    /// Producer thread only.
    @discardableResult
    func push(_ v: UInt32) -> Bool {
        let h = head.load(ordering: .relaxed), t = tail.load(ordering: .acquiring)
        if h - t >= capacity { _ = lost.add(1, ordering: .relaxed); return false }
        buf[h & mask] = v
        head.store(h + 1, ordering: .releasing)
        return true
    }

    /// Consumer thread only.
    func pop() -> UInt32? {
        let t = tail.load(ordering: .relaxed), h = head.load(ordering: .acquiring)
        if t == h { return nil }
        let v = buf[t & mask]
        tail.store(t + 1, ordering: .releasing)
        return v
    }
}

// MARK: - Value interpretation

/// How a control's numbers become a value.
enum MIDIValueMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 0 … 127 (or the bend wheel's 14 bits) is the whole range of the target.
    case absolute
    /// A fader or knob that sends its most significant byte on controller n and the least on n + 32 (Pioneer DDJ).
    case absolute14
    /// Encoders: 64 is zero, above is clockwise (Pioneer jog wheels).
    case relativeOffset
    /// Encoders: 1 … 63 clockwise, 127 … 65 counter-clockwise.
    case relativeTwos
    /// Encoders: bit 6 is the direction, the low bits the speed.
    case relativeSignBit

    var id: String { rawValue }
    var title: String {
        switch self {
        case .absolute: "Absolute (7-bit)"; case .absolute14: "Absolute (14-bit pair)"
        case .relativeOffset: "Relative (64 = still)"; case .relativeTwos: "Relative (two's complement)"; case .relativeSignBit: "Relative (sign bit)"
        }
    }
    var isRelative: Bool { self == .relativeOffset || self == .relativeTwos || self == .relativeSignBit }

    /// Ticks (positive = clockwise) for an encoder message.
    func ticks(_ v: Int) -> Int {
        switch self {
        case .relativeOffset: return v - 64
        case .relativeTwos: return v < 64 ? v : v - 128
        case .relativeSignBit: return v < 64 ? v : -(v - 64)
        default: return 0
        }
    }
}

/// How the target's own scale relates to the 0 … 1 travel of a control.
enum MIDICurve: Sendable {
    case linear
    /// Frequency and Q: equal steps are equal ratios.
    case logarithmic
    /// A DJ EQ knob: its centre detent is flat (0 dB), the bottom is a full kill (−26 dB → −60), the top +6 dB.
    case djEQ

    func value(_ n: Double, in r: ClosedRange<Double>) -> Double {
        let n = max(0, min(1, n.isFinite ? n : 0))
        switch self {
        case .linear: return r.lowerBound + n * (r.upperBound - r.lowerBound)
        case .logarithmic: return r.lowerBound * pow(r.upperBound / r.lowerBound, n)
        case .djEQ: return n < 0.5 ? r.lowerBound * (1 - n / 0.5) : r.upperBound * ((n - 0.5) / 0.5)
        }
    }

    func norm(_ v: Double, in r: ClosedRange<Double>) -> Double {
        let v = max(r.lowerBound, min(r.upperBound, v.isFinite ? v : r.lowerBound))
        switch self {
        case .linear: return (v - r.lowerBound) / (r.upperBound - r.lowerBound)
        case .logarithmic: return log(v / r.lowerBound) / log(r.upperBound / r.lowerBound)
        case .djEQ: return v <= 0 ? 0.5 * (1 - v / r.lowerBound) : 0.5 + 0.5 * v / r.upperBound
        }
    }
}

// MARK: - Targets

enum MIDITargetKind: Sendable {
    /// A level: faders and knobs.
    case continuous
    /// A button: acts on press.
    case trigger
    /// A relative-only control: jog wheels and the seek encoder.
    case encoder
}

struct MIDITarget: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let group: String
    let kind: MIDITargetKind
    let range: ClosedRange<Double>
    let curve: MIDICurve
    /// Travel (as a fraction of the whole range) per encoder tick when a relative control drives a continuous target.
    let step: Double
    /// Never jump to the control's position: used where a sudden change could hurt (the output volume).
    let alwaysPickup: Bool

    static func == (a: MIDITarget, b: MIDITarget) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    func value(_ n: Double) -> Double { curve.value(n, in: range) }
    func norm(_ v: Double) -> Double { curve.norm(v, in: range) }
}

/// Every control of the app that a surface can drive. Identifiers are what is saved, so they never change.
enum MIDITargets {
    static let groups = ["Deck A", "Deck B", "Mixer", "Headphones", "Parametric EQ", "Player"]

    private static func level(_ id: String, _ title: String, _ group: String, _ range: ClosedRange<Double>, curve: MIDICurve = .linear, step: Double = 1.0 / 100, pickup: Bool = false) -> MIDITarget {
        MIDITarget(id: id, title: title, group: group, kind: .continuous, range: range, curve: curve, step: step, alwaysPickup: pickup)
    }
    private static func button(_ id: String, _ title: String, _ group: String) -> MIDITarget {
        MIDITarget(id: id, title: title, group: group, kind: .trigger, range: 0...1, curve: .linear, step: 0, alwaysPickup: false)
    }
    private static func encoder(_ id: String, _ title: String, _ group: String) -> MIDITarget {
        MIDITarget(id: id, title: title, group: group, kind: .encoder, range: -1...1, curve: .linear, step: 0, alwaysPickup: false)
    }

    private static func deck(_ side: String) -> [MIDITarget] {
        let g = "Deck \(side)", p = "deck\(side)."
        var t: [MIDITarget] = [
            button(p + "play", "Play / pause", g), button(p + "cue", "Cue", g), button(p + "sync", "Sync tempo", g),
            button(p + "pfl", "Headphone cue (PFL)", g),
            level(p + "fader", "Channel fader", g, 0...1),
            level(p + "trim", "Trim (dB)", g, -12...12),
            level(p + "eqHigh", "EQ high", g, DJMath.eqRange, curve: .djEQ),
            level(p + "eqMid", "EQ mid", g, DJMath.eqRange, curve: .djEQ),
            level(p + "eqLow", "EQ low", g, DJMath.eqRange, curve: .djEQ),
            button(p + "killHigh", "Kill high", g), button(p + "killMid", "Kill mid", g), button(p + "killLow", "Kill low", g),
            level(p + "filter", "Filter (low-pass ◂ ▸ high-pass)", g, -1...1),
            level(p + "pitch", "Tempo fader", g, -1...1),
            button(p + "fxToggle", "Effect on / off", g),
            level(p + "fxWet", "Effect wet", g, 0...1), level(p + "fxParam", "Effect parameter", g, 0...1),
            button(p + "loopIn", "Loop in", g), button(p + "loopOut", "Loop out", g), button(p + "loopToggle", "Loop on / off", g), button(p + "loop4", "Auto loop 4 beats", g),
            button(p + "brake", "Brake", g),
            encoder(p + "jog", "Jog wheel (pitch bend)", g),
        ]
        for i in 1...DJDeckHotCues.count { t.append(button(p + "hotcue\(i)", "Hot cue \(i)", g)) }
        return t
    }

    static let eqBandCount = 10

    private static let mixer: [MIDITarget] = [
        level("mixer.crossfader", "Crossfader", "Mixer", -1...1),
        button("mixer.crossfaderLeft", "Crossfader to A", "Mixer"), button("mixer.crossfaderCenter", "Crossfader to centre", "Mixer"), button("mixer.crossfaderRight", "Crossfader to B", "Mixer"),
        button("mixer.crossfaderReverse", "Reverse crossfader", "Mixer"),
        button("mixer.autoMix", "Auto-mix to the other deck", "Mixer"),
        level("mixer.masterLevel", "Master level", "Mixer", 0...1.25),
        level("mixer.masterHigh", "Master EQ high", "Mixer", DJMath.eqRange, curve: .djEQ),
        level("mixer.masterMid", "Master EQ mid", "Mixer", DJMath.eqRange, curve: .djEQ),
        level("mixer.masterLow", "Master EQ low", "Mixer", DJMath.eqRange, curve: .djEQ),
        button("mixer.limiter", "Limiter on / off", "Mixer"),
        level("phones.mix", "Cue / master mix", "Headphones", 0...1),
        level("phones.level", "Headphone level", "Headphones", 0...1.5),
    ]

    private static let peq: [MIDITarget] = {
        var t: [MIDITarget] = [button("peq.enabled", "Equaliser on / off", "Parametric EQ"), level("peq.preamp", "Preamp (dB)", "Parametric EQ", -24...12)]
        for i in 1...eqBandCount {
            t.append(level("peq.band\(i).gain", "Band \(i) gain (dB)", "Parametric EQ", -12...12))
            t.append(level("peq.band\(i).freq", "Band \(i) frequency", "Parametric EQ", 20...20_000, curve: .logarithmic))
            t.append(level("peq.band\(i).q", "Band \(i) Q", "Parametric EQ", 0.2...10, curve: .logarithmic))
            t.append(button("peq.band\(i).on", "Band \(i) on / off", "Parametric EQ"))
        }
        return t
    }()

    private static let player: [MIDITarget] = [
        button("player.playPause", "Play / pause", "Player"), button("player.next", "Next track", "Player"), button("player.previous", "Previous track", "Player"),
        button("player.seekBack", "Back 10 s", "Player"), button("player.seekForward", "Forward 10 s", "Player"),
        encoder("player.seek", "Seek (1 s per click)", "Player"),
        level("player.volume", "Output volume", "Player", 0...1, pickup: true),
    ]

    static let all: [MIDITarget] = deck("A") + deck("B") + mixer + peq + player
    static let byID: [String: MIDITarget] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static func target(_ id: String) -> MIDITarget? { byID[id] }
    static func targets(in group: String) -> [MIDITarget] { all.filter { $0.group == group } }
}

/// The number of hot-cue pads on a deck (the deck model's own constant).
enum DJDeckHotCues { static let count = HotCueStore.count }

// MARK: - Mappings

/// One control driving one target.
struct MIDIMapping: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var control: MIDIControl
    var target: String
    var mode: MIDIValueMode = .absolute
    /// Reverses the direction of the control.
    var inverted = false
    /// Do nothing until the control reaches the on-screen value, so moving a knob never makes a sudden jump.
    var pickup = true
    /// Relative controls: a multiplier on the target's step per tick.
    var sensitivity = 1.0

    init(id: UUID = UUID(), control: MIDIControl, target: String, mode: MIDIValueMode = .absolute, inverted: Bool = false, pickup: Bool = true, sensitivity: Double = 1) {
        self.id = id; self.control = control; self.target = target; self.mode = mode; self.inverted = inverted; self.pickup = pickup; self.sensitivity = sensitivity
    }

    private enum Keys: String, CodingKey { case id, control, target, mode, inverted, pickup, sensitivity }
    // Tolerant of older or hand-edited files: every field after the control and the target has a default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        control = try c.decode(MIDIControl.self, forKey: .control)
        target = try c.decode(String.self, forKey: .target)
        mode = try c.decodeIfPresent(MIDIValueMode.self, forKey: .mode) ?? .absolute
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        pickup = try c.decodeIfPresent(Bool.self, forKey: .pickup) ?? true
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 1
    }
}

struct MIDISettingsFile: Codable {
    var enabled = true
    /// Sources the person switched off, by CoreMIDI unique ID. Everything else is listened to.
    var disabledSources: [Int32] = []
    var mappings: [MIDIMapping] = []

    init() {}
    private enum Keys: String, CodingKey { case enabled, disabledSources, mappings }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        disabledSources = try c.decodeIfPresent([Int32].self, forKey: .disabledSources) ?? []
        mappings = try c.decodeIfPresent([MIDIMapping].self, forKey: .mappings) ?? []
    }
}

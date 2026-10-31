import SwiftUI
import Combine
import CoreAudio

// MARK: - Layout presets and window rules

/// The DJ console comes in two layouts. Pro is the full console and has a window minimum; Compact is the smaller, customisable one.
enum DJLayoutPreset: String, CaseIterable, Identifiable, Codable {
    case pro, compact
    var id: String { rawValue }
    var title: String { self == .pro ? "PRO" : "COMPACT" }

    /// The smallest window (content area, in points) the layout is designed for.
    var minimumWindow: CGSize { self == .pro ? DJProMetrics.minimumWindow : CGSize(width: 1280, height: 540) }

    static let key = "aureon.dj.preset"
    static func load(_ d: UserDefaults = .standard) -> DJLayoutPreset { d.string(forKey: key).flatMap(DJLayoutPreset.init(rawValue:)) ?? .pro }
    func save(_ d: UserDefaults = .standard) { d.set(rawValue, forKey: Self.key) }
}

/// Every size of the Pro console in one place. Controls have fixed sizes; only the waveforms, the library and the spacing flex with the window.
enum DJProMetrics {
    static let minimumWindow = CGSize(width: 1180, height: 760)
    static let outer: CGFloat = 8                  // window edge to the panels
    static let gap: CGFloat = 6                    // between panels
    static let deckPad: CGFloat = 10
    static let modesColumn: CGFloat = 62
    static let tempoBlock: CGFloat = 122
    static let pitchBlock: CGFloat = 62
    static let jogMin: CGFloat = 136
    static let jogMax: CGFloat = 196
    static let mixerMin: CGFloat = 256
    static let mixerMax: CGFloat = 330
    static let stripMin: CGFloat = 56
    static let libraryMin: CGFloat = 220
    static let treeWidth: CGFloat = 150
    static let sideWidth: CGFloat = 190

    /// Widths of the three console columns for a window width: the mixer takes about a fifth, the decks share the rest.
    static func columns(window w: CGFloat) -> (deck: CGFloat, mixer: CGFloat) {
        let usable = max(minimumWindow.width, w) - 2 * outer - 2 * gap
        let mixer = min(mixerMax, max(mixerMin, (usable * 0.215).rounded()))
        return (((usable - mixer) / 2).rounded(.down), mixer)
    }

    static let toolbarHeight: CGFloat = 44
    static let stageMin: CGFloat = 110
    static let stageMax: CGFloat = 280
    /// The measured height of the decks, mixer and effect units at full size, used until the real console has been measured.
    static let bodyHeightEstimate: CGFloat = 830

    /// How the console sits in a window: the scale that makes it fit, the height of the stage, and whether the library fits under it.
    struct Fit: Equatable {
        var scale: CGFloat
        var stageHeight: CGFloat
        var libraryInline: Bool
        /// Height of stage and body together before scaling.
        var consoleHeight: CGFloat
    }

    /// `bodyHeight` is the natural height of the deck row and the effect row together. Nothing here depends on the window being taller than the minimum:
    /// a short window scales the console down (never up) and puts the library in a drawer, so no part of the console ever needs scrolling.
    static func fit(window: CGSize, bodyHeight: CGFloat) -> Fit {
        let room = window.height - outer - toolbarHeight - gap          // under the toolbar
        let minConsole = stageMin + gap + bodyHeight
        let spare = room - minConsole - gap - libraryMin
        if spare >= 0 {
            let stage = min(stageMax, stageMin + (spare * 0.4).rounded(.down))
            return Fit(scale: 1, stageHeight: stage, libraryInline: true, consoleHeight: stage + gap + bodyHeight)
        }
        // no room for the library: the stage takes what is left over, or the console shrinks to fit
        let stage = min(stageMax, stageMin + max(0, (room - minConsole).rounded(.down)))
        return Fit(scale: max(0.5, min(1, room / minConsole)), stageHeight: stage, libraryInline: false, consoleHeight: stage + gap + bodyHeight)
    }

    /// The disc grows a little with a wide window (never below its minimum, so nothing around it moves or overlaps).
    static func jog(deckWidth d: CGFloat) -> CGFloat {
        let room = d - 2 * deckPad - modesColumn - tempoBlock - pitchBlock - 3 * 10
        return max(jogMin, min(jogMax, room.rounded(.down)))
    }
}

// MARK: - Pads

enum PadMode: String, CaseIterable, Identifiable {
    case cues = "CUES", loop = "LOOP", roll = "ROLL", fx = "FX", slicer = "SLICER", sampler = "SAMPLER"
    var id: String { rawValue }

    /// Banks (pages of eight pads) each mode has.
    var banks: Int {
        switch self {
        case .cues: return 1
        case .loop, .roll, .fx: return 2
        case .slicer: return 4
        case .sampler: return 1
        }
    }
}

/// The sizes the loop and roll pads offer, in beats.
enum DJPadSets {
    static let loopBeats: [Double] = [0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 0.0625, 128, 0.75, 1.5, 3, 6]
    static let rollBeats: [Double] = [0.0625, 0.125, 0.25, 0.5, 1, 2, 4, 8, 0.75, 1.5, 3, 6, 12, 16, 24, 32]

    /// An effect pad: which effect, how strong, and the label shown on it.
    struct FXPreset: Equatable { let kind: DeckFXKind; let param: Double; let wet: Double; let title: String; let detail: String }
    static let fx: [FXPreset] = [
        FXPreset(kind: .echo, param: 0.25, wet: 0.5, title: "ECHO", detail: "1/4"), FXPreset(kind: .echo, param: 0.5, wet: 0.5, title: "ECHO", detail: "1/2"),
        FXPreset(kind: .echo, param: 1.0, wet: 0.5, title: "ECHO", detail: "1 beat"), FXPreset(kind: .echo, param: 0.75, wet: 0.7, title: "ECHO", detail: "3/4 wide"),
        FXPreset(kind: .reverb, param: 0.3, wet: 0.35, title: "REVERB", detail: "room"), FXPreset(kind: .reverb, param: 0.7, wet: 0.45, title: "REVERB", detail: "hall"),
        FXPreset(kind: .reverb, param: 1.0, wet: 0.7, title: "REVERB", detail: "cathedral"), FXPreset(kind: .reverb, param: 0.6, wet: 1.0, title: "REVERB", detail: "wash"),
        FXPreset(kind: .flanger, param: 0.2, wet: 0.5, title: "FLANGE", detail: "slow"), FXPreset(kind: .flanger, param: 0.5, wet: 0.5, title: "FLANGE", detail: "mid"),
        FXPreset(kind: .flanger, param: 0.9, wet: 0.6, title: "FLANGE", detail: "fast"), FXPreset(kind: .flanger, param: 0.5, wet: 1.0, title: "FLANGE", detail: "full"),
        FXPreset(kind: .gate, param: 0.25, wet: 1.0, title: "GATE", detail: "1/4"), FXPreset(kind: .gate, param: 0.5, wet: 1.0, title: "GATE", detail: "1/8"),
        FXPreset(kind: .gate, param: 0.75, wet: 1.0, title: "GATE", detail: "1/16"), FXPreset(kind: .gate, param: 1.0, wet: 1.0, title: "GATE", detail: "1/32"),
    ]

    /// Beats in one slicer bank, and the number of slices in it.
    static let slicerBeats = 8.0
    static let slices = 8

    static func label(beats b: Double) -> String {
        switch b {
        case 0.0625: return "1/16"
        case 0.125: return "1/8"
        case 0.25: return "1/4"
        case 0.5: return "1/2"
        case 0.75: return "3/4"
        default: return b == b.rounded() ? "\(Int(b))" : String(format: "%g", b)
        }
    }
}

// MARK: - Effect units

/// One of the three shared effect units. A channel is assigned to at most one of them; its settings follow the unit.
@MainActor
final class DJFXUnit: ObservableObject, Identifiable {
    let index: Int
    var id: Int { index }
    @Published var kind: DeckFXKind { didSet { changed?() } }
    @Published var on = false { didSet { changed?() } }
    @Published var wet = 0.4 { didSet { changed?() } }
    @Published var param = 0.5 { didSet { changed?() } }
    var changed: (() -> Void)?
    init(index: Int, kind: DeckFXKind) { self.index = index; self.kind = kind }
    var title: String { kind.title }
}

// MARK: - Live input channels

/// The microphone or auxiliary channel of the mixer: it takes an input device and has the same strip as a deck.
@MainActor
final class DJLineChannel: ObservableObject, Identifiable {
    let name: String
    var id: String { name }
    private(set) var mix: DJMixerCore.Deck
    @Published var trim = 0.0 { didSet { mix.params.trim.value = Float(pow(10, trim / 20)) } }
    @Published var low = 0.0 { didSet { mix.params.low.value = Float(DJMath.eqGainDB(low)) } }
    @Published var mid = 0.0 { didSet { mix.params.mid.value = Float(DJMath.eqGainDB(mid)) } }
    @Published var high = 0.0 { didSet { mix.params.high.value = Float(DJMath.eqGainDB(high)) } }
    @Published var filter = 0.0 { didSet { mix.params.filter.value = Float(filter) } }
    @Published var channel = 0.0 { didSet { onMix?() } }
    @Published var pfl = false { didSet { mix.cue.value = pfl ? 1 : 0 } }
    /// 0 = none, 1…3 = effect unit.
    @Published var fxUnit = 0 { didSet { onFX?() } }
    /// The device it listens to; nil = the system's default input.
    @Published var deviceID: AudioDeviceID? { didSet { if oldValue != deviceID { restart?() } } }
    @Published private(set) var running = false
    @Published private(set) var error: String?
    var onMix: (() -> Void)?
    var onFX: (() -> Void)?
    var restart: (() -> Void)?
    private var input: CoreAudioLineInput?
    private var killed: [String: Double] = [:]

    init(name: String, mix: DJMixerCore.Deck, defaultFader: Double) { self.name = name; self.mix = mix; channel = defaultFader }

    /// Rebinds to a fresh mixer channel (the mixer is rebuilt every time the console opens) and re-applies every setting.
    func attach(_ m: DJMixerCore.Deck) {
        mix = m
        m.params.trim.value = Float(pow(10, trim / 20)); m.params.filter.value = Float(filter)
        m.params.low.value = Float(DJMath.eqGainDB(low)); m.params.mid.value = Float(DJMath.eqGainDB(mid)); m.params.high.value = Float(DJMath.eqGainDB(high))
        m.cue.value = pfl ? 1 : 0
        onMix?(); onFX?()
    }

    func toggleKill(_ band: String) {
        func flip(_ v: Double, _ set: (Double) -> Void) {
            if v <= DJMath.eqRange.lowerBound + 0.5 { set(killed[band] ?? 0); killed[band] = nil }
            else { killed[band] = v; set(DJMath.eqRange.lowerBound) }
        }
        switch band { case "low": flip(low) { low = $0 }; case "mid": flip(mid) { mid = $0 }; default: flip(high) { high = $0 } }
    }
    func isKilled(_ band: String) -> Bool { (band == "low" ? low : band == "mid" ? mid : high) <= DJMath.eqRange.lowerBound + 0.5 }

    func start(rate: Double, device: InputDeviceInfo?) {
        stop()
        guard let dev = device else { error = "No input device"; return }
        let i = CoreAudioLineInput(device: dev, channel: mix, mixerRate: rate)
        do { try i.start(); input = i; running = true; error = nil } catch { self.error = "\(error)"; running = false }
    }
    func stop() { input?.stop(); input = nil; running = false }
    var peak: (Float, Float) { (mix.peakL.value, mix.peakR.value) }
}

// MARK: - Strips

/// What a channel strip needs from a channel, whatever kind it is: a deck or a live input.
@MainActor
struct DJStripBindings {
    let name: String
    let color: Color
    let trim: Binding<Double>, high: Binding<Double>, mid: Binding<Double>, low: Binding<Double>, filter: Binding<Double>
    let fader: Binding<Double>
    let pfl: Binding<Bool>
    let fxUnit: Binding<Int>
    let isKilled: (String) -> Bool
    let toggleKill: (String) -> Void
    let peak: () -> (Float, Float)
}

// MARK: - Maths for the disc and the grid

enum DJProMath {
    /// One turn of the disc takes this long at normal speed (33⅓ rpm).
    static let secondsPerTurn = 1.8

    /// The disc's angle in degrees for a position in the track.
    static func discAngle(position: Double) -> Double { (position / secondsPerTurn).truncatingRemainder(dividingBy: 1) * 360 }

    /// The angle (degrees, 0 = up, clockwise) of a point relative to the disc's centre.
    static func angle(x: Double, y: Double) -> Double { var a = atan2(x, -y) * 180 / .pi; if a < 0 { a += 360 }; return a }

    /// The smallest signed turn from one angle to another, in degrees.
    static func turn(from a: Double, to b: Double) -> Double { var d = (b - a).truncatingRemainder(dividingBy: 360); if d > 180 { d -= 360 } else if d < -180 { d += 360 }; return d }

    /// The speed of the track under a hand moving the disc by `degrees` in `seconds` (1 = normal speed forwards).
    static func scratchSpeed(degrees: Double, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return max(-8, min(8, degrees / 360 * secondsPerTurn / seconds))
    }

    /// Positions of the beats of a grid inside a span of the track.
    static func beats(from a: Double, to b: Double, bpm: Double, firstBeat: Double) -> [(time: Double, index: Int)] {
        guard bpm > 0, b > a else { return [] }
        let p = 60 / bpm
        var out: [(Double, Int)] = []
        var i = Int(((a - firstBeat) / p).rounded(.down))
        while true {
            let t = firstBeat + Double(i) * p
            if t > b || out.count > 4_000 { break }
            if t >= a { out.append((t, i)) }
            i += 1
        }
        return out
    }

    /// Bar number (1-based) and beat in the bar at a time.
    static func barBeat(at t: Double, bpm: Double, firstBeat: Double) -> (bar: Int, beat: Int) {
        guard bpm > 0 else { return (1, 1) }
        let n = Int(((t - firstBeat) / (60 / bpm)).rounded(.down))
        let idx = max(0, n)
        return (idx / 4 + 1, idx % 4 + 1)
    }

    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// How far a pitch fader position (-1…1 of its travel) is, as a fraction of the range; the fader is top = slower, as on a turntable.
    static func pitchFromFader(_ y: Double, range: Double) -> Double { max(-range, min(range, y * range)) }

    /// Camelot names for the semitone-shifted key, so the key chip shows what is playing after a shift.
    static func shifted(_ key: MusicalKey?, semitones: Int) -> MusicalKey? {
        guard let k = key, semitones != 0 else { return key }
        return MusicalKey(pitchClass: ((k.pitchClass + semitones) % 12 + 12) % 12, minor: k.minor)
    }
}

/// A rolling-window store of beat-grid offsets per track (seconds the grid was moved by hand).
enum GridStore {
    private static let key = "aureon.dj.gridoffsets"
    private static var enabled: Bool { ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil && ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil }
    static var overrideDefaults: UserDefaults?
    private static var defaults: UserDefaults { overrideDefaults ?? .standard }
    static func load(path: String) -> Double {
        guard enabled || overrideDefaults != nil else { return 0 }
        return ((defaults.dictionary(forKey: key) as? [String: Double]) ?? [:])[path] ?? 0
    }
    static func save(path: String, offset: Double) {
        guard enabled || overrideDefaults != nil else { return }
        var d = (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
        d[path] = abs(offset) < 1e-6 ? nil : offset
        defaults.set(d, forKey: key)
    }
}

// MARK: - A zoomed waveform

/// A finer view of a track for the scrolling waveform: 100 bins a second, each with the peak of the low band (below about 250 Hz) and of the rest.
struct DJWaveDetail: Equatable {
    static let binsPerSecond = 100.0
    var low: [UInt8]
    var high: [UInt8]
    var count: Int { low.count }

    /// Decodes the file and reduces it. Runs off the main thread.
    static func build(path: String, cancelled: () -> Bool = { false }) -> DJWaveDetail? {
        guard let f = try? openLossless(path: path), f.info.totalFrames > 0 else { return nil }
        let info = f.info, ch = info.channels
        let per = max(1, Int(info.sampleRate / binsPerSecond))
        let bins = Int(info.totalFrames) / per + 1
        var lo = [UInt8](repeating: 0, count: bins), hi = [UInt8](repeating: 0, count: bins)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 16_384 * ch); defer { buf.deallocate() }
        let alpha = 1 - exp(-2 * Double.pi * 250 / info.sampleRate)          // the bass band
        let alphaHigh = 1 - exp(-2 * Double.pi * 700 / info.sampleRate)      // everything above about 700 Hz is the upper band
        var lp = 0.0, lpHigh = 0.0, frame = 0
        var binLow = 0.0, binHigh = 0.0, inBin = 0, bin = 0
        while true {
            if cancelled() { return nil }
            let n = f.read(into: buf, frames: 16_384)
            if n == 0 { break }
            for i in 0..<n {
                var mono = 0.0
                for c in 0..<ch { mono += Double(buf[i * ch + c]) / 2_147_483_648 }
                mono /= Double(ch)
                lp += alpha * (mono - lp); lpHigh += alphaHigh * (mono - lpHigh)
                binLow = max(binLow, abs(lp)); binHigh = max(binHigh, abs(mono - lpHigh))
                inBin += 1
                if inBin == per {
                    if bin < bins { lo[bin] = UInt8(max(0, min(255, (binLow * 255).rounded()))); hi[bin] = UInt8(max(0, min(255, (binHigh * 255 * 1.6).rounded()))) }
                    bin += 1; inBin = 0; binLow = 0; binHigh = 0
                }
            }
            frame += n
        }
        if inBin > 0, bin < bins { lo[bin] = UInt8(max(0, min(255, (binLow * 255).rounded()))); hi[bin] = UInt8(max(0, min(255, (binHigh * 255 * 1.6).rounded()))) }
        return DJWaveDetail(low: lo, high: hi)
    }

    /// Peak values for a bin range (inclusive of the start, exclusive of the end), 0…1, clamped at the edges of the track.
    func peaks(from a: Int, to b: Int) -> (low: Float, high: Float) {
        guard count > 0 else { return (0, 0) }
        let lo = max(0, a), hi = min(count, max(lo + 1, b))
        guard lo < count else { return (0, 0) }
        var l: UInt8 = 0, h: UInt8 = 0
        for i in lo..<hi { l = max(l, low[i]); h = max(h, high[i]) }
        return (Float(l) / 255, Float(h) / 255)
    }
}

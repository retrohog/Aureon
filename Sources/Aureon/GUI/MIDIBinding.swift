import Foundation

/// The player-wide actions a surface can trigger, kept separate from `PlayerModel` so tests can stand in for it.
@MainActor
protocol MIDITransport: AnyObject {
    func transportTogglePlay()
    func transportNext()
    func transportPrevious()
    func transportSeek(by seconds: Double)
    /// The output device's volume, 0 … 1, or nil when the device reports none.
    var transportVolume: Double? { get }
    func transportSetVolume(_ v: Double)
}

extension PlayerModel: MIDITransport {
    func transportTogglePlay() { togglePlay() }
    func transportNext() { player.send(.next) }
    func transportPrevious() { player.send(.previous) }
    func transportSeek(by seconds: Double) { player.send(.seekBy(seconds)) }
    var transportVolume: Double? { hasVolume ? Double(volume) : nil }
    /// Goes through `setVolume`, so the volume ceiling from Settings still applies.
    func transportSetVolume(_ v: Double) { setVolume(Float(v)) }
}

/// Connects MIDI targets to the models the on-screen controls already use. Nothing here touches the audio thread: the DJ models
/// write the same lock-free atomics as their knobs, and the parametric EQ goes through `DSPModel`'s throttled hand-over to the engine.
@MainActor
final class MIDIBinder: MIDITargetResolver {
    private let dj: DJModel
    private let dsp: DSPModel
    private weak var transport: MIDITransport?
    /// Deck and mixer targets do nothing while the DJ console is closed (the tests turn this off).
    var requireDJMode = true
    private var jogRelease: [ObjectIdentifier: DispatchWorkItem] = [:]

    init(dj: DJModel, dsp: DSPModel, transport: MIDITransport?) { self.dj = dj; self.dsp = dsp; self.transport = transport }

    private enum Ref {
        case deck(DJDeck, String), mixer(String), phones(String), peq(String), player(String)
    }

    private func ref(_ id: String) -> Ref? {
        guard let dot = id.firstIndex(of: ".") else { return nil }
        let head = String(id[..<dot]), rest = String(id[id.index(after: dot)...])
        switch head {
        case "deckA": return .deck(dj.a, rest)
        case "deckB": return .deck(dj.b, rest)
        case "mixer": return .mixer(rest)
        case "phones": return .phones(rest)
        case "peq": return .peq(rest)
        case "player": return .player(rest)
        default: return nil
        }
    }

    /// "band3.gain" → (2, "gain")
    private func band(_ s: String) -> (index: Int, field: String)? {
        guard s.hasPrefix("band"), let dot = s.firstIndex(of: "."), let n = Int(s[s.index(s.startIndex, offsetBy: 4)..<dot]) else { return nil }
        let i = n - 1
        return dsp.draft.eq.bands.indices.contains(i) ? (i, String(s[s.index(after: dot)...])) : nil
    }

    func isAvailable(_ id: String) -> Bool {
        switch ref(id) {
        case .deck, .mixer, .phones: return !requireDJMode || dj.active
        case .peq(let s): return s.hasPrefix("band") ? band(s) != nil : true
        case .player(let s): return s == "volume" ? transport?.transportVolume != nil : transport != nil
        case nil: return false
        }
    }

    func current(_ id: String) -> Double? {
        switch ref(id) {
        case .deck(let d, let n):
            switch n {
            case "fader": return d.channel
            case "trim": return d.trim
            case "eqHigh": return d.high
            case "eqMid": return d.mid
            case "eqLow": return d.low
            case "filter": return d.filter
            case "pitch": return d.pitchRange > 0 ? d.pitch / d.pitchRange : 0
            case "fxWet": return d.fxWet
            case "fxParam": return d.fxParam
            default: return nil
            }
        case .mixer(let n):
            switch n {
            case "crossfader": return dj.crossfader
            case "masterLevel": return dj.masterLevel
            case "masterHigh": return dj.masterHigh
            case "masterMid": return dj.masterMid
            case "masterLow": return dj.masterLow
            default: return nil
            }
        case .phones(let n): return n == "mix" ? dj.cueMix : n == "level" ? dj.cueLevel : nil
        case .peq(let s):
            if s == "preamp" { return dsp.draft.eq.preampDB }
            guard let (i, f) = band(s) else { return nil }
            let b = dsp.draft.eq.bands[i]
            return f == "gain" ? b.gainDB : f == "freq" ? b.frequency : f == "q" ? b.q : nil
        case .player(let s): return s == "volume" ? transport?.transportVolume : nil
        case nil: return nil
        }
    }

    func set(_ id: String, value v: Double) {
        guard v.isFinite else { return }
        switch ref(id) {
        case .deck(let d, let n):
            switch n {
            case "fader": d.channel = max(0, min(1, v))
            case "trim": d.trim = max(-12, min(12, v))
            case "eqHigh": d.high = v
            case "eqMid": d.mid = v
            case "eqLow": d.low = v
            case "filter": d.filter = max(-1, min(1, v))
            case "pitch": d.pitch = max(-d.pitchRange, min(d.pitchRange, v * d.pitchRange))
            case "fxWet": d.fxWet = max(0, min(1, v))
            case "fxParam": d.fxParam = max(0, min(1, v))
            default: break
            }
        case .mixer(let n):
            switch n {
            case "crossfader": dj.crossfader = max(-1, min(1, v))
            case "masterLevel": dj.masterLevel = v
            case "masterHigh": dj.masterHigh = v
            case "masterMid": dj.masterMid = v
            case "masterLow": dj.masterLow = v
            default: break
            }
        case .phones(let n):
            if n == "mix" { dj.cueMix = max(0, min(1, v)) } else if n == "level" { dj.cueLevel = max(0, min(1.5, v)) }
        case .peq(let s):
            if s == "preamp" { dsp.draft.eq.preampDB = (v * 10).rounded() / 10; return }
            guard let (i, f) = band(s) else { return }
            switch f {
            case "gain": dsp.draft.eq.bands[i].gainDB = (v * 10).rounded() / 10
            case "freq": dsp.draft.eq.bands[i].frequency = (v * 10).rounded() / 10
            case "q": dsp.draft.eq.bands[i].q = (v * 100).rounded() / 100
            default: break
            }
            if dsp.draft.eq.enabled { dsp.draft.enabled = true }
        case .player(let s): if s == "volume" { transport?.transportSetVolume(max(0, min(1, v))) }
        case nil: break
        }
    }

    func fire(_ id: String) {
        switch ref(id) {
        case .deck(let d, let n):
            switch n {
            case "play": d.togglePlay()
            case "cue": d.cuePressed()
            case "sync": dj.sync(d)
            case "pfl": d.pfl.toggle()
            case "killHigh": d.toggleKill("high")
            case "killMid": d.toggleKill("mid")
            case "killLow": d.toggleKill("low")
            case "fxToggle": d.fxOn.toggle()
            case "loopIn": d.setLoopIn()
            case "loopOut": d.setLoopOut()
            case "loopToggle": d.toggleLoop()
            case "loop4": d.autoLoop(beats: 4)
            case "brake": d.brake()
            default:
                if n.hasPrefix("hotcue"), let k = Int(n.dropFirst(6)) { d.hotCue(k - 1) }
            }
        case .mixer(let n):
            switch n {
            case "crossfaderLeft": dj.crossfader = -1
            case "crossfaderCenter": dj.crossfader = 0
            case "crossfaderRight": dj.crossfader = 1
            case "crossfaderReverse": dj.crossfaderReverse.toggle()
            case "autoMix": dj.autoMix(seconds: 8)
            case "limiter": dj.limiter.toggle()
            default: break
            }
        case .peq(let s):
            if s == "enabled" {
                let on = !dsp.draft.eq.enabled
                dsp.draft.eq.enabled = on
                if on { dsp.draft.enabled = true }
            } else if let (i, f) = band(s), f == "on" {
                dsp.draft.eq.bands[i].enabled.toggle()
                if dsp.draft.eq.enabled { dsp.draft.enabled = true }
            }
        case .player(let s):
            switch s {
            case "playPause": transport?.transportTogglePlay()
            case "next": transport?.transportNext()
            case "previous": transport?.transportPrevious()
            case "seekBack": transport?.transportSeek(by: -10)
            case "seekForward": transport?.transportSeek(by: 10)
            default: break
            }
        case .phones, nil: break
        }
    }

    func turn(_ id: String, ticks: Double) {
        switch ref(id) {
        case .deck(let d, "jog"):
            // the wheel nudges the speed while it turns and lets go when it stops
            d.bend(max(-1, min(1, ticks * 0.35)))
            let key = ObjectIdentifier(d)
            jogRelease[key]?.cancel()
            let w = DispatchWorkItem { [weak d] in MainActor.assumeIsolated { d?.bend(0) } }
            jogRelease[key] = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: w)
        case .player("seek"): transport?.transportSeek(by: ticks)
        default: break
        }
    }
}

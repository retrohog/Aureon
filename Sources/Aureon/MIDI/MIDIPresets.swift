import Foundation

/// A ready-made set of mappings for a known controller.
struct MIDIPreset: Identifiable {
    let id: String
    let name: String
    /// Lower-cased fragments of the name CoreMIDI reports for the device.
    let deviceHints: [String]
    let summary: String
    let mappings: [MIDIMapping]

    func matches(deviceName: String) -> Bool {
        let n = deviceName.lowercased().replacingOccurrences(of: " ", with: "")
        return deviceHints.contains { n.contains($0.replacingOccurrences(of: " ", with: "")) }
    }
}

enum MIDIPresets {
    static let all: [MIDIPreset] = [ddj400, nanoKontrol2Mixer, nanoKontrol2Equaliser]

    static func suggestions(for deviceName: String) -> [MIDIPreset] { all.filter { $0.matches(deviceName: deviceName) } }

    private static func cc(_ ch: Int, _ n: Int) -> MIDIControl { MIDIControl(kind: .cc, channel: ch, number: n) }
    private static func note(_ ch: Int, _ n: Int) -> MIDIControl { MIDIControl(kind: .note, channel: ch, number: n) }

    // MARK: Pioneer DDJ-400
    //
    // Taken from the controller's published MIDI map (the Mixxx project's Pioneer DDJ-400 mapping). Deck 1 sends on channel 1 and deck 2
    // on channel 2 (pads on channels 8 and 10), the mixer section on channel 7. Faders, knobs and the tempo slider are 14-bit pairs.
    static let ddj400: MIDIPreset = {
        var m: [MIDIMapping] = []
        for (i, side) in ["A", "B"].enumerated() {
            let t = "deck\(side)."
            func fine(_ n: Int, _ target: String, _ ch: Int) { m.append(MIDIMapping(control: cc(ch, n), target: target, mode: .absolute14)) }
            func key(_ n: Int, _ target: String) { m.append(MIDIMapping(control: note(i, n), target: target)) }
            fine(0x13, t + "fader", i); fine(0x04, t + "trim", i)
            fine(0x07, t + "eqHigh", i); fine(0x0B, t + "eqMid", i); fine(0x0F, t + "eqLow", i)
            fine(0x17 + i, t + "filter", 6)
            fine(0x00, t + "pitch", i)
            key(0x0B, t + "play"); key(0x0C, t + "cue"); key(0x58, t + "sync"); key(0x54, t + "pfl")
            key(0x10, t + "loopIn"); key(0x11, t + "loopOut"); key(0x4D, t + "loopToggle")
            // hot-cue pads: channel 8 for deck 1, channel 10 for deck 2
            for p in 0..<8 { m.append(MIDIMapping(control: note(7 + 2 * i, p), target: t + "hotcue\(p + 1)")) }
            // jog: the side ring (0x21), the platter in vinyl mode (0x22) and out of it (0x23) all send 64-centred relative values
            for n in [0x21, 0x22, 0x23] { m.append(MIDIMapping(control: cc(i, n), target: t + "jog", mode: .relativeOffset)) }
        }
        m.append(MIDIMapping(control: cc(6, 0x1F), target: "mixer.crossfader", mode: .absolute14))
        m.append(MIDIMapping(control: cc(6, 0x0D), target: "phones.level", mode: .absolute14))
        return MIDIPreset(id: "ddj400", name: "Pioneer DDJ-400", deviceHints: ["ddj-400", "ddj400"],
                          summary: "Channel faders, trim, 3-band EQ, filters, tempo sliders, crossfader, headphone level, transport, loops, hot-cue pads and jog wheels for both decks.",
                          mappings: dedupe(m))
    }()

    // MARK: Korg nanoKONTROL2 (factory CC mode, channel 1)
    //
    // Fader n = CC n-1, knob n = CC 15+n, S/M/R = CC 31+n / 47+n / 63+n; transport: play 41, stop 42, rewind 43, forward 44, record 45,
    // cycle 46, track ◂ ▸ 58 59, marker set 60, marker ◂ ▸ 61 62. Buttons send 127 when pressed and 0 when released.
    static let nanoKontrol2Mixer: MIDIPreset = {
        var m: [MIDIMapping] = []
        func add(_ n: Int, _ target: String) { m.append(MIDIMapping(control: cc(0, n), target: target)) }
        // faders: channel A, channel B, tempo A, tempo B, crossfader, master, headphone level, cue/master mix
        for (n, t) in ["deckA.fader", "deckB.fader", "deckA.pitch", "deckB.pitch", "mixer.crossfader", "mixer.masterLevel", "phones.level", "phones.mix"].enumerated() { add(n, t) }
        // knobs: deck A high, mid, low, trim; deck B high, mid, low, trim
        for (n, t) in ["deckA.eqHigh", "deckA.eqMid", "deckA.eqLow", "deckA.trim", "deckB.eqHigh", "deckB.eqMid", "deckB.eqLow", "deckB.trim"].enumerated() { add(16 + n, t) }
        // S: kills and headphone cue
        for (n, t) in ["deckA.killHigh", "deckA.killMid", "deckA.killLow", "deckA.pfl", "deckB.killHigh", "deckB.killMid", "deckB.killLow", "deckB.pfl"].enumerated() { add(32 + n, t) }
        // M: play, cue, sync, effect
        for (n, t) in ["deckA.play", "deckA.cue", "deckA.sync", "deckA.fxToggle", "deckB.play", "deckB.cue", "deckB.sync", "deckB.fxToggle"].enumerated() { add(48 + n, t) }
        // R: hot cues 1-4 per deck
        for (n, t) in ((1...4).map { "deckA.hotcue\($0)" } + (1...4).map { "deckB.hotcue\($0)" }).enumerated() { add(64 + n, t) }
        add(46, "mixer.autoMix"); add(58, "mixer.crossfaderLeft"); add(59, "mixer.crossfaderRight"); add(60, "mixer.crossfaderCenter")
        add(61, "mixer.limiter"); add(62, "mixer.crossfaderReverse")
        add(41, "player.playPause"); add(43, "player.previous"); add(44, "player.next")
        return MIDIPreset(id: "nanokontrol2-mixer", name: "Korg nanoKONTROL2 — DJ mixer", deviceHints: ["nanokontrol2"],
                          summary: "Eight faders for channel, tempo, crossfader and levels; knobs for each deck's 3-band EQ and trim; S, M and R buttons for kills, transport and hot cues.",
                          mappings: dedupe(m))
    }()

    static let nanoKontrol2Equaliser: MIDIPreset = {
        var m: [MIDIMapping] = []
        func add(_ n: Int, _ target: String) { m.append(MIDIMapping(control: cc(0, n), target: target)) }
        for i in 0..<8 { add(i, "peq.band\(i + 1).gain"); add(32 + i, "peq.band\(i + 1).on") }      // faders and S buttons: bands 1-8
        add(16, "peq.band9.gain"); add(17, "peq.band10.gain"); add(48, "peq.band9.on"); add(49, "peq.band10.on")
        add(18, "peq.preamp"); add(41, "peq.enabled")
        add(19, "player.volume")
        add(43, "player.previous"); add(44, "player.next"); add(42, "player.playPause")
        return MIDIPreset(id: "nanokontrol2-peq", name: "Korg nanoKONTROL2 — Parametric EQ", deviceHints: ["nanokontrol2"],
                          summary: "Faders 1–8 set the gain of bands 1–8, knobs 1–2 bands 9–10, S and M buttons switch bands on and off, knob 3 is the preamp, Play switches the equaliser.",
                          mappings: dedupe(m))
    }()

    /// One mapping per control, and one per target (a jog wheel may have several rings), the first wins: a preset never fights itself.
    private static func dedupe(_ list: [MIDIMapping]) -> [MIDIMapping] {
        var controls = Set<MIDIControl>(), targets = Set<String>()
        var out: [MIDIMapping] = []
        for m in list {
            if controls.contains(m.control) { continue }
            if targets.contains(m.target) && !m.target.hasSuffix(".jog") { continue }
            controls.insert(m.control); targets.insert(m.target); out.append(m)
        }
        return out
    }
}

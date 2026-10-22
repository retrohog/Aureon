import Foundation
import CoreMIDI

func midiTests() -> [(String, TestFn)] {
    let t = MIDITests()
    return [
        ("midi.parse", t.parsingAndPacking), ("midi.ring", t.ringKeepsOrderAndDropsWhenFull), ("midi.ringThreads", t.ringBetweenTwoThreads),
        ("midi.curves", t.curvesAndCatalog), ("midi.codable", t.mappingsDecodeFromOlderFiles), ("midi.learn", t.learnAssignsOneControlPerTarget),
        ("midi.pickup", t.softTakeover), ("midi.14bit", t.fourteenBitPairs), ("midi.relative", t.relativeEncoders),
        ("midi.buttons", t.buttonsFireOncePerPress), ("midi.coalesce", t.fastFadersAreCoalescedButButtonsAreNot), ("midi.presets", t.presetsAreConsistent),
        ("midi.presetApply", t.applyingAPresetReplacesConflicts), ("midi.persist", t.mappingsPersist), ("midi.binder", t.binderDrivesTheModels),
        ("midi.everyTarget", t.everyTargetIsWired), ("midi.jog", t.jogWheelNudgesAndReleases), ("midi.coreMIDI", t.coreMIDIDeliversThroughTheRing),
    ]
}

@MainActor
private final class FakeResolver: MIDITargetResolver {
    var values: [String: Double] = [:]
    var unavailable: Set<String> = []
    var writes: [(id: String, value: Double)] = []
    var fired: [String] = []
    var turned: [(id: String, ticks: Double)] = []
    func isAvailable(_ id: String) -> Bool { !unavailable.contains(id) }
    func current(_ id: String) -> Double? { values[id] }
    func set(_ id: String, value: Double) { values[id] = value; writes.append((id, value)) }
    func fire(_ id: String) { fired.append(id) }
    func turn(_ id: String, ticks: Double) { turned.append((id, ticks)) }
}

@MainActor
private final class FakeTransport: MIDITransport {
    var toggles = 0, nexts = 0, previouses = 0
    var seeks: [Double] = []
    var volume: Double?
    var volumeWrites: [Double] = []
    func transportTogglePlay() { toggles += 1 }
    func transportNext() { nexts += 1 }
    func transportPrevious() { previouses += 1 }
    func transportSeek(by s: Double) { seeks.append(s) }
    var transportVolume: Double? { volume }
    func transportSetVolume(_ v: Double) { volumeWrites.append(v); volume = v }
}

struct MIDITests {
    private func cc(_ ch: Int, _ n: Int, _ v: Int) -> MIDIMessage { MIDIMessage(control: MIDIControl(kind: .cc, channel: ch, number: n), value: v) }
    private func note(_ ch: Int, _ n: Int, _ v: Int) -> MIDIMessage { MIDIMessage(control: MIDIControl(kind: .note, channel: ch, number: n), value: v) }
    private func ccControl(_ ch: Int, _ n: Int) -> MIDIControl { MIDIControl(kind: .cc, channel: ch, number: n) }
    private func spin(_ s: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(s)
        while Date() < end && !done() { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }
    private func word(_ type: UInt32, _ op: UInt32, _ ch: UInt32, _ d1: UInt32, _ d2: UInt32) -> UInt32 { type << 28 | op << 20 | ch << 16 | d1 << 8 | d2 }

    // MARK: messages

    func parsingAndPacking() {
        expect(MIDIMessage.parse(word: word(2, 0x9, 3, 60, 100)) == note(3, 60, 100), "note on")
        expect(MIDIMessage.parse(word: word(2, 0x8, 3, 60, 64)) == note(3, 60, 0), "note off carries no velocity")
        expect(MIDIMessage.parse(word: word(2, 0x9, 0, 36, 0)) == note(0, 36, 0), "note on with velocity 0 is a release")
        expect(MIDIMessage.parse(word: word(2, 0xB, 15, 7, 127)) == cc(15, 7, 127), "controller on channel 16")
        expect(MIDIMessage.parse(word: word(2, 0xE, 1, 0x00, 0x40))?.value == 8_192, "bend wheel centre")
        expect(MIDIMessage.parse(word: word(2, 0xE, 1, 0x7F, 0x7F))?.value == 16_383, "bend wheel top")
        for (type, op) in [(UInt32(1), UInt32(0xF)), (4, 0x9), (2, 0xC), (2, 0xA), (2, 0xD), (0, 0), (3, 0)] { expect(MIDIMessage.parse(word: word(type, op, 0, 1, 1)) == nil, "type \(type) opcode \(op) is not a control") }
        for m in [note(0, 0, 0), note(15, 127, 127), cc(7, 64, 33), cc(0, 0, 0), MIDIMessage(control: MIDIControl(kind: .pitchBend, channel: 9, number: 0), value: 12_345)] {
            expect(MIDIMessage(packed: m.packed) == m, "pack round trip \(m.summary)")
        }
        expect(MIDIMessage(packed: 3 << 25) == nil, "an unknown kind is refused")
        expect(MIDIControl(kind: .note, channel: 3, number: 60).title == "Ch 4 · Note 60 (C4)", MIDIControl(kind: .note, channel: 3, number: 60).title)
        expect(ccControl(0, 0x13).lsbPartner == ccControl(0, 0x33) && ccControl(0, 40).lsbPartner == nil, "14-bit partners")
        expect(cc(0, 1, 63).isPress == false && cc(0, 1, 64).isPress && note(0, 1, 1).isPress && !note(0, 1, 0).isPress, "press rules")
    }

    func ringKeepsOrderAndDropsWhenFull() {
        let r = MIDIEventRing(capacity: 8)
        for i in 0..<8 { expect(r.push(UInt32(i)), "fits") }
        expect(!r.push(99) && r.dropped == 1, "the ninth is dropped and counted")
        for i in 0..<8 { expect(r.pop() == UInt32(i), "in order") }
        expect(r.pop() == nil && r.isEmpty, "empty again")
        for round in 0..<20 {
            for i in 0..<6 { r.push(UInt32(round * 10 + i)) }
            for i in 0..<6 { expect(r.pop() == UInt32(round * 10 + i), "after wrapping") }
        }
    }

    func ringBetweenTwoThreads() {
        let r = MIDIEventRing(capacity: 256)
        let total = 300_000
        let done = DispatchSemaphore(value: 0)
        let producer = Thread {
            var v: UInt32 = 0
            while Int(v) < total { if r.push(v) { v += 1 } else { sched_yield() } }
            done.signal()
        }
        producer.start()
        var next: UInt32 = 0, bad = 0
        let end = Date().addingTimeInterval(20)
        while Int(next) < total && Date() < end {
            if let v = r.pop() { if v != next { bad += 1 }; next += 1 } else { sched_yield() }
        }
        _ = done.wait(timeout: .now() + 5)
        expect(Int(next) == total && bad == 0, "every message arrives once, in order (\(next) of \(total), \(bad) out of order)")
    }

    // MARK: targets

    func curvesAndCatalog() {
        let eq = MIDITargets.target("deckA.eqHigh")!
        expect(abs(eq.value(0.5)) < 1e-9, "the centre of an EQ knob is flat")
        expect(eq.value(0) == -26 && eq.value(1) == 6, "ends: kill and +6 dB")
        expect(DJMath.eqGainDB(eq.value(0)) == DJMath.killDB, "the bottom of the knob is a full kill in the deck")
        for n in stride(from: 0.0, through: 1.0, by: 0.05) { expect(abs(eq.norm(eq.value(n)) - n) < 1e-9, "EQ curve round trip at \(n)") }
        let f = MIDITargets.target("peq.band1.freq")!
        expect(abs(f.value(0) - 20) < 1e-9 && abs(f.value(1) - 20_000) < 1e-6 && abs(f.value(0.5) - (20.0 * 20_000.0).squareRoot()) < 1e-6, "frequency is logarithmic")
        expect(abs(f.norm(1_000) - log(50) / log(1_000)) < 1e-9, "…and inverts")
        let lin = MIDITargets.target("mixer.masterLevel")!
        expect(lin.value(-3) == 0 && lin.value(9) == 1.25 && lin.value(.nan) == 0, "out-of-range and NaN are clamped")
        expect(Set(MIDITargets.all.map(\.id)).count == MIDITargets.all.count, "identifiers are unique")
        for g in MIDITargets.groups { expect(!MIDITargets.targets(in: g).isEmpty, "\(g) has targets") }
        expect(MIDITargets.all.allSatisfy { MIDITargets.groups.contains($0.group) }, "every target is in a known group")
        expect(MIDITargets.target("deckB.hotcue8") != nil && MIDITargets.target("deckB.hotcue9") == nil, "eight pads per deck")
        expect(MIDITargets.target("player.volume")?.alwaysPickup == true, "the volume never jumps")
    }

    func mappingsDecodeFromOlderFiles() {
        let m = MIDIMapping(control: ccControl(2, 9), target: "mixer.crossfader", mode: .absolute14, inverted: true, pickup: false, sensitivity: 2)
        let d = try! JSONEncoder().encode(m)
        expect(try! JSONDecoder().decode(MIDIMapping.self, from: d) == m, "round trip")
        let old = #"{"control":{"kind":"cc","channel":1,"number":7},"target":"deckA.fader"}"#.data(using: .utf8)!
        let o = try! JSONDecoder().decode(MIDIMapping.self, from: old)
        expect(o.mode == .absolute && !o.inverted && o.pickup && o.sensitivity == 1, "missing fields take their defaults")
        let empty = try! JSONDecoder().decode(MIDISettingsFile.self, from: "{}".data(using: .utf8)!)
        expect(empty.enabled && empty.mappings.isEmpty && empty.disabledSources.isEmpty, "an empty file is a clean start")
    }

    // MARK: learn

    func learnAssignsOneControlPerTarget() {
        MainActor.assumeIsolated {
            let c = MIDIController(url: nil), r = FakeResolver()
            c.resolver = r
            c.beginLearn("nonsense"); expect(c.learning == nil, "unknown targets cannot be learned")
            c.beginLearn("deckA.fader")
            c.ingest([note(0, 5, 0)]); expect(c.learning == "deckA.fader", "a release is not a choice")
            c.ingest([cc(0, 7, 64)])
            expect(c.learning == nil && c.mapping(for: "deckA.fader")?.control == ccControl(0, 7) && c.mapping(for: "deckA.fader")?.mode == .absolute, "the first movement is taken")
            expect(r.writes.isEmpty && r.fired.isEmpty, "learning does not act on the target")
            c.beginLearn("deckA.jog"); c.ingest([cc(0, 30, 65)])
            expect(c.mapping(for: "deckA.jog")?.mode == .relativeOffset, "encoders default to relative")
            c.beginLearn("deckB.fader"); c.ingest([cc(0, 7, 10)])
            expect(c.mapping(for: "deckA.fader") == nil && c.mapping(for: "deckB.fader")?.control == ccControl(0, 7), "a control drives one target: the old assignment goes")
            c.beginLearn("deckB.fader"); c.ingest([cc(1, 8, 10)])
            expect(c.mappings.filter { $0.target == "deckB.fader" }.count == 1 && c.mapping(for: "deckB.fader")?.control == ccControl(1, 8), "re-learning replaces")
            c.beginLearn("deckA.play"); c.cancelLearn(); c.ingest([cc(3, 3, 3)])
            expect(c.mapping(for: "deckA.play") == nil, "cancelled")
            c.clear(target: "deckB.fader"); expect(c.mapping(for: "deckB.fader") == nil)
            c.beginLearn("mixer.crossfader")
            c.ingest([MIDIMessage(control: MIDIControl(kind: .pitchBend, channel: 2, number: 0), value: 9_000)])
            expect(c.mapping(for: "mixer.crossfader")?.control.kind == .pitchBend, "the bend wheel can be learned")
        }
    }

    // MARK: interpretation

    func softTakeover() {
        MainActor.assumeIsolated {
            let c = MIDIController(url: nil), r = FakeResolver()
            c.resolver = r
            let id = "mixer.masterLevel"                                       // 0 … 1.25
            r.values[id] = 1.0                                                // on screen at 80 %
            let map = MIDIMapping(control: ccControl(0, 7), target: id)
            c.add(map)
            c.ingest([cc(0, 7, 0)])
            expect(r.writes.isEmpty && c.waitingForPickup.contains(map.id), "a knob far from the on-screen value does nothing")
            c.ingest([cc(0, 7, 60)]); expect(r.writes.isEmpty, "…until it reaches it")
            c.ingest([cc(0, 7, 127)])
            expect(r.writes.count == 1 && abs(r.writes[0].value - 1.25) < 1e-9 && c.waitingForPickup.isEmpty, "crossing the value takes over")
            c.ingest([cc(0, 7, 64)])
            expect(r.writes.count == 2 && abs(r.writes[1].value - 1.25 * 64 / 127) < 1e-9, "then it follows")
            r.values[id] = 0.25                                               // changed on screen
            c.ingest([cc(0, 7, 100)])
            expect(r.writes.count == 2 && c.waitingForPickup.contains(map.id), "after an outside change it has to catch up again")
            c.ingest([cc(0, 7, 10)])
            expect(r.writes.count == 3, "and takes over when it crosses")

            // without pickup the control is followed at once; inverted flips it
            let c2 = MIDIController(url: nil), r2 = FakeResolver(); c2.resolver = r2
            r2.values[id] = 0.1
            c2.add(MIDIMapping(control: ccControl(0, 1), target: id, mode: .absolute, inverted: true, pickup: false))
            c2.ingest([cc(0, 1, 127)]); expect(r2.writes.count == 1 && abs(r2.writes[0].value) < 1e-9, "inverted, no pickup: full travel is zero")

            // the output volume always waits, whatever the mapping says
            let c3 = MIDIController(url: nil), r3 = FakeResolver(); c3.resolver = r3
            r3.values["player.volume"] = 0.3
            c3.add(MIDIMapping(control: ccControl(0, 2), target: "player.volume", pickup: false))
            c3.ingest([cc(0, 2, 127)]); expect(r3.writes.isEmpty, "a volume knob at full cannot jump the volume")
            c3.ingest([cc(0, 2, 30)]); expect(r3.writes.count == 1, "it takes over at the current level")
        }
    }

    func fourteenBitPairs() {
        MainActor.assumeIsolated {
            let c = MIDIController(url: nil), r = FakeResolver(); c.resolver = r
            c.add(MIDIMapping(control: ccControl(0, 0x13), target: "deckA.fader", mode: .absolute14, pickup: false))
            c.ingest([cc(0, 0x33, 100)]); expect(r.writes.isEmpty, "a least-significant byte alone waits for its partner")
            c.ingest([cc(0, 0x13, 64)])
            expect(r.writes.count == 1 && abs(r.writes[0].value - Double(64 << 7 | 100) / 16_383) < 1e-12, "MSB with the remembered LSB")
            c.ingest([cc(0, 0x33, 127)])
            expect(r.writes.count == 2 && abs(r.writes[1].value - Double(64 << 7 | 127) / 16_383) < 1e-12, "a new LSB refines the value")
            c.ingest([cc(0, 0x13, 127), cc(0, 0x33, 127)])
            expect(abs((r.values["deckA.fader"] ?? 0) - 1) < 1e-12, "full travel reaches exactly 1")
            c.ingest([cc(0, 0x13, 0), cc(0, 0x33, 0)])
            expect(r.values["deckA.fader"] == 0, "and 0")
        }
    }

    func relativeEncoders() {
        expect(MIDIValueMode.relativeOffset.ticks(65) == 1 && MIDIValueMode.relativeOffset.ticks(63) == -1 && MIDIValueMode.relativeOffset.ticks(64) == 0, "offset")
        expect(MIDIValueMode.relativeTwos.ticks(1) == 1 && MIDIValueMode.relativeTwos.ticks(127) == -1 && MIDIValueMode.relativeTwos.ticks(63) == 63 && MIDIValueMode.relativeTwos.ticks(64) == -64, "two's complement")
        expect(MIDIValueMode.relativeSignBit.ticks(1) == 1 && MIDIValueMode.relativeSignBit.ticks(65) == -1 && MIDIValueMode.relativeSignBit.ticks(127) == -63, "sign bit")
        expect(MIDIValueMode.absolute.ticks(5) == 0, "absolute has no ticks")
        MainActor.assumeIsolated {
            let c = MIDIController(url: nil), r = FakeResolver(); c.resolver = r
            c.add(MIDIMapping(control: ccControl(0, 30), target: "deckA.jog", mode: .relativeOffset))
            c.ingest([cc(0, 30, 65), cc(0, 30, 62), cc(0, 30, 64)])
            expect(r.turned.map { $0.ticks } == [1, -2], "every tick is delivered, zeros are not: \(r.turned)")
            c.add(MIDIMapping(control: ccControl(0, 31), target: "player.seek", mode: .relativeTwos, inverted: true, sensitivity: 2))
            c.ingest([cc(0, 31, 3)])
            expect(r.turned.last?.ticks == -6, "inverted and doubled: \(String(describing: r.turned.last))")
            // an encoder driving a level moves it by steps of the target's travel
            r.values["deckA.filter"] = 0
            c.add(MIDIMapping(control: ccControl(0, 32), target: "deckA.filter", mode: .relativeOffset))
            c.ingest([cc(0, 32, 74)])
            expect(abs((r.values["deckA.filter"] ?? 9) - 0.2) < 1e-9, "ten clicks of a 1 % step on a −1…1 range: \(String(describing: r.values["deckA.filter"]))")
            c.add(MIDIMapping(control: ccControl(0, 33), target: "deckA.filter", mode: .relativeOffset, sensitivity: 2))
            c.ingest([cc(0, 33, 54)])
            expect(abs((r.values["deckA.filter"] ?? 9) - (0.2 - 0.4)) < 1e-9, "twice as sensitive, counter-clockwise")
        }
    }

    func buttonsFireOncePerPress() {
        MainActor.assumeIsolated {
            let c = MIDIController(url: nil), r = FakeResolver(); c.resolver = r
            c.add(MIDIMapping(control: MIDIControl(kind: .note, channel: 0, number: 0x0B), target: "deckA.play"))
            c.add(MIDIMapping(control: ccControl(0, 41), target: "player.playPause"))
            c.ingest([note(0, 0x0B, 100)]); c.ingest([note(0, 0x0B, 0)]); c.ingest([note(0, 0x0B, 90)]); c.ingest([note(0, 0x0B, 0)])
            expect(r.fired == ["deckA.play", "deckA.play"], "two presses, two actions: \(r.fired)")
            r.fired = []
            c.ingest([note(0, 0x0B, 100), note(0, 0x0B, 110)]); expect(r.fired.count == 1, "a held key is one press")
            r.fired = []
            c.ingest([cc(0, 41, 127)]); c.ingest([cc(0, 41, 127)]); c.ingest([cc(0, 41, 0)]); c.ingest([cc(0, 41, 127)])
            expect(r.fired == ["player.playPause", "player.playPause"], "controller buttons: 127 presses, 0 releases")
            r.fired = []; r.unavailable = ["deckA.play"]
            c.ingest([note(0, 0x0B, 0)]); c.ingest([note(0, 0x0B, 100)]); expect(r.fired.isEmpty, "an unavailable target is ignored")
            c.enabled = false; r.unavailable = []
            c.ingest([cc(0, 41, 0)]); c.ingest([cc(0, 41, 127)]); expect(r.fired.isEmpty, "switched off: nothing acts")
        }
    }

    func fastFadersAreCoalescedButButtonsAreNot() {
        MainActor.assumeIsolated {
            let c = MIDIController(url: nil), r = FakeResolver(); c.resolver = r
            c.add(MIDIMapping(control: ccControl(0, 7), target: "mixer.masterLevel", pickup: false))
            c.add(MIDIMapping(control: ccControl(0, 20), target: "player.next"))
            c.add(MIDIMapping(control: ccControl(0, 21), target: "deckA.jog", mode: .relativeOffset))
            var batch: [MIDIMessage] = (0..<500).map { cc(0, 7, $0 % 128) }
            batch += [cc(0, 20, 127), cc(0, 20, 0), cc(0, 20, 127), cc(0, 20, 0)]
            batch += [cc(0, 21, 65), cc(0, 21, 66), cc(0, 21, 63)]
            batch.append(cc(0, 7, 90))
            c.ingest(batch)
            expect(r.writes.count == 1 && abs(r.writes[0].value - 1.25 * 90 / 127) < 1e-9, "a fader that moved 501 times is applied once, at its last position: \(r.writes.count)")
            expect(r.fired == ["player.next", "player.next"], "quick taps are all counted: \(r.fired)")
            expect(r.turned.map { $0.ticks } == [1, 2, -1], "every encoder tick is counted: \(r.turned)")
        }
    }

    // MARK: presets

    func presetsAreConsistent() {
        expect(MIDIPresets.all.count >= 3)
        for p in MIDIPresets.all {
            expect(p.mappings.count > 15, "\(p.name) maps a useful number of controls")
            var controls = Set<MIDIControl>()
            for m in p.mappings {
                expect(MIDITargets.target(m.target) != nil, "\(p.name): \(m.target) exists")
                expect(controls.insert(m.control).inserted, "\(p.name): \(m.control.title) is used once")
                if m.mode == .absolute14 { expect(m.control.lsbPartner != nil, "\(p.name): \(m.control.title) has a partner byte") }
                if let t = MIDITargets.target(m.target), t.kind == .encoder { expect(m.mode.isRelative, "\(p.name): \(m.target) needs a relative control") }
            }
            for m in p.mappings where m.mode == .absolute14 { if let l = m.control.lsbPartner { expect(!p.mappings.contains { $0.control == l }, "\(p.name): the partner byte of \(m.control.title) is not mapped on its own") } }
        }
        let ddj = MIDIPresets.ddj400
        func find(_ target: String) -> [MIDIMapping] { ddj.mappings.filter { $0.target == target } }
        expect(find("deckA.play").first?.control == MIDIControl(kind: .note, channel: 0, number: 0x0B), "deck 1 play is note 0x0B on channel 1")
        expect(find("deckB.play").first?.control == MIDIControl(kind: .note, channel: 1, number: 0x0B), "deck 2 on channel 2")
        expect(find("mixer.crossfader").first?.control == ccControl(6, 0x1F) && find("mixer.crossfader").first?.mode == .absolute14, "crossfader on the mixer channel, 14-bit")
        expect(find("deckB.filter").first?.control == ccControl(6, 0x18), "deck 2 filter")
        expect(find("deckB.hotcue1").first?.control == MIDIControl(kind: .note, channel: 9, number: 0), "deck 2 pads are on channel 10")
        expect(find("deckA.jog").count == 3 && find("deckA.jog").allSatisfy { $0.mode == .relativeOffset }, "three jog rings")
        expect(find("deckA.eqHigh").first?.control == ccControl(0, 0x07) && find("deckA.eqLow").first?.control == ccControl(0, 0x0F), "EQ knobs")
        expect(MIDIPresets.suggestions(for: "DDJ-400").map(\.id) == ["ddj400"] && MIDIPresets.suggestions(for: "Pioneer DDJ-400 MIDI 1").count == 1, "the DDJ-400 is recognised")
        expect(MIDIPresets.suggestions(for: "nanoKONTROL2 SLIDER/KNOB").count == 2, "the nanoKONTROL2 has two presets")
        expect(MIDIPresets.suggestions(for: "Some Synth").isEmpty, "others are not guessed")
    }

    func applyingAPresetReplacesConflicts() {
        MainActor.assumeIsolated {
            let c = MIDIController(url: nil)
            c.add(MIDIMapping(control: ccControl(0, 0x13), target: "mixer.limiter"))             // uses a control the preset wants
            c.add(MIDIMapping(control: ccControl(5, 5), target: "deckA.fader"))                  // uses a target the preset wants
            c.add(MIDIMapping(control: ccControl(5, 6), target: "peq.preamp"))                   // unrelated
            c.apply(MIDIPresets.ddj400)
            expect(c.mapping(for: "mixer.limiter") == nil, "a mapping on a control the preset takes is replaced")
            expect(c.mapping(for: "deckA.fader")?.control == ccControl(0, 0x13), "a mapping on a target the preset sets is replaced")
            expect(c.mapping(for: "peq.preamp")?.control == ccControl(5, 6), "unrelated mappings stay")
            expect(c.mappings.count == MIDIPresets.ddj400.mappings.count + 1 && c.notice != nil, "all of the preset arrived")
            let again = c.mappings.count
            c.apply(MIDIPresets.ddj400); expect(c.mappings.count == again, "applying twice changes nothing")
            c.removeAll(); expect(c.mappings.isEmpty)
        }
    }

    func mappingsPersist() {
        MainActor.assumeIsolated {
            let url = tempDir("midi").appendingPathComponent("midi.json")
            try? FileManager.default.removeItem(at: url)
            let a = MIDIController(url: url)
            expect(a.mappings.isEmpty && a.enabled)
            a.apply(MIDIPresets.nanoKontrol2Mixer); a.setSource(42, enabled: false)
            let b = MIDIController(url: url)
            expect(b.mappings.count == a.mappings.count && !b.isSourceEnabled(42) && b.isSourceEnabled(7) && b.enabled, "a second launch finds everything")
            expect(b.mapping(for: "deckA.fader")?.control == ccControl(0, 0), "…and the mapping is indexed for use")
            let r = FakeResolver(); b.resolver = r
            b.update({ var m = b.mapping(for: "deckA.fader")!; m.pickup = false; return m }())
            b.ingest([cc(0, 0, 127)]); expect(r.values["deckA.fader"] == 1, "loaded mappings act")
            b.enabled = false
            expect(!MIDIController(url: url).enabled, "the switch is remembered")
            let bogus = #"{"mappings":[{"control":{"kind":"cc","channel":0,"number":1},"target":"deckZ.nothing"},{"control":{"kind":"cc","channel":0,"number":2},"target":"deckA.fader"}]}"#
            try! bogus.data(using: .utf8)!.write(to: url)
            expect(MIDIController(url: url).mappings.map(\.target) == ["deckA.fader"], "mappings for targets that no longer exist are dropped")
            try! "not json".data(using: .utf8)!.write(to: url)
            expect(MIDIController(url: url).mappings.isEmpty, "a damaged file is a clean start")
        }
    }

    // MARK: the real models

    func binderDrivesTheModels() {
        MainActor.assumeIsolated {
            let dj = DJModel(), dsp = DSPModel(url: nil), tr = FakeTransport()
            let b = MIDIBinder(dj: dj, dsp: dsp, transport: tr)
            expect(!b.isAvailable("deckA.fader") && !b.isAvailable("mixer.crossfader"), "deck and mixer targets wait for the DJ console")
            expect(b.isAvailable("peq.preamp") && b.isAvailable("player.playPause") && !b.isAvailable("nonsense.id"), "the rest is always available")
            b.requireDJMode = false
            // EQ: centre flat, bottom a kill, all the way into the audio thread's atomics
            let low = MIDITargets.target("deckA.eqLow")!
            b.set(low.id, value: low.value(0.5)); expect(dj.a.low == 0 && dj.a.mix.params.low.value == 0, "centre is flat")
            b.set(low.id, value: low.value(0)); expect(dj.a.mix.params.low.value == Float(DJMath.killDB), "bottom kills the band")
            b.set(low.id, value: low.value(1)); expect(dj.a.mix.params.low.value == 6, "top is +6 dB")
            b.set("deckA.filter", value: 0.4); expect(dj.a.mix.params.filter.value == 0.4)
            b.set("deckA.trim", value: -6); expect(abs(Double(dj.a.mix.params.trim.value) - pow(10, -0.3)) < 1e-6, "trim in dB")
            b.set("deckB.fxWet", value: 0.8); expect(dj.b.mix.params.fxWet.value == 0.8)
            // pitch is a fraction of the deck's range
            dj.a.pitchRange = 0.08
            b.set("deckA.pitch", value: 0.5); expect(abs(dj.a.pitch - 0.04) < 1e-12 && abs((b.current("deckA.pitch") ?? 9) - 0.5) < 1e-12, "tempo fader")
            dj.a.pitchRange = 0.16; expect(abs((b.current("deckA.pitch") ?? 9) - 0.25) < 1e-12, "the same pitch is a smaller fraction of a wider range")
            // crossfader and channel faders reach the gains
            dj.a.channel = 1; dj.b.channel = 1; dj.curve = .linear
            b.set("mixer.crossfader", value: -1); expect(dj.a.mix.gain.value == 1 && dj.b.mix.gain.value == 0, "hard left")
            b.fire("mixer.crossfaderRight"); expect(dj.crossfader == 1 && dj.a.mix.gain.value == 0, "button to B")
            b.fire("mixer.crossfaderCenter"); expect(dj.crossfader == 0)
            b.fire("mixer.crossfaderReverse"); expect(dj.crossfaderReverse); b.fire("mixer.crossfaderReverse"); expect(!dj.crossfaderReverse)
            b.set("phones.level", value: 1.5); b.set("phones.mix", value: 0.25)
            expect(dj.cueLevel == 1.5 && dj.cueMix == 0.25 && dj.core.cueLevel.value == 1.5 && dj.core.cueMix.value == 0.25, "headphone controls reach the mixer core")
            b.set("mixer.masterHigh", value: 3); expect(dj.core.masterHigh.value == 3)
            b.fire("mixer.limiter"); expect(!dj.limiter && dj.core.limiterOn.value == 0)
            // buttons
            b.fire("deckA.killLow"); expect(dj.a.isKilled("low")); b.fire("deckA.killLow"); expect(!dj.a.isKilled("low"), "kill toggles back")
            b.fire("deckA.pfl"); expect(dj.a.pfl && dj.a.mix.cue.value == 1, "PFL")
            b.fire("deckB.fxToggle"); expect(dj.b.fxOn && dj.b.mix.params.fxOn.value == 1)
            for n in ["play", "cue", "sync", "loopIn", "loopOut", "loopToggle", "loop4", "brake", "hotcue1", "hotcue8"] { b.fire("deckA.\(n)") }
            expect(!dj.a.playing && dj.a.track == nil, "transport on an empty deck is harmless")
            // parametric EQ goes through the DSP model, 10 bands
            b.set("peq.band3.gain", value: 4.04); expect(dsp.draft.eq.bands[2].gainDB == 4.0, "gain is rounded to 0.1 dB")
            b.set("peq.band3.freq", value: 1_234.56); expect(dsp.draft.eq.bands[2].frequency == 1_234.6)
            b.set("peq.band3.q", value: 2.345); expect(abs(dsp.draft.eq.bands[2].q - 2.35) < 1e-9 || abs(dsp.draft.eq.bands[2].q - 2.34) < 1e-9)
            b.set("peq.preamp", value: -3.04); expect(dsp.draft.eq.preampDB == -3.0)
            expect(b.isAvailable("peq.band10.gain") && !b.isAvailable("peq.band11.gain"), "bands that do not exist are unavailable")
            expect(!dsp.draft.eq.enabled && !dsp.draft.enabled)
            b.fire("peq.enabled"); expect(dsp.draft.eq.enabled && dsp.draft.enabled, "switching the equaliser on switches the DSP path on, like the page does")
            b.fire("peq.enabled"); expect(!dsp.draft.eq.enabled)
            let was = dsp.draft.eq.bands[1].enabled
            b.fire("peq.band2.on"); expect(dsp.draft.eq.bands[1].enabled != was, "band switch")
            // player
            b.fire("player.playPause"); b.fire("player.next"); b.fire("player.previous"); b.fire("player.seekBack"); b.fire("player.seekForward"); b.turn("player.seek", ticks: 3)
            expect(tr.toggles == 1 && tr.nexts == 1 && tr.previouses == 1 && tr.seeks == [-10, 10, 3], "transport: \(tr.seeks)")
            expect(!b.isAvailable("player.volume"), "no volume to control on this device")
            tr.volume = 0.4; expect(b.isAvailable("player.volume") && b.current("player.volume") == 0.4)
            b.set("player.volume", value: 0.9); expect(tr.volumeWrites == [0.9])
        }
    }

    func everyTargetIsWired() {
        MainActor.assumeIsolated {
            let dj = DJModel(), dsp = DSPModel(url: nil), tr = FakeTransport()
            tr.volume = 0.5
            let b = MIDIBinder(dj: dj, dsp: dsp, transport: tr)
            b.requireDJMode = false
            for t in MIDITargets.all {
                expect(b.isAvailable(t.id), "\(t.id) is available")
                switch t.kind {
                case .continuous:
                    for n in [0.0, 0.3, 1.0] {
                        let v = t.value(n)
                        b.set(t.id, value: v)
                        let back = b.current(t.id)
                        expect(back != nil && abs(back! - v) <= 0.011 * max(1, abs(v)), "\(t.id): set \(v), read \(String(describing: back))")
                    }
                case .trigger: b.fire(t.id)
                case .encoder: b.turn(t.id, ticks: 1)
                }
            }
            // every catalog entry reaches a place: nothing falls through to "unknown"
            expect(MIDITargets.all.count > 120, "the catalog is complete: \(MIDITargets.all.count)")
        }
    }

    func jogWheelNudgesAndReleases() {
        MainActor.assumeIsolated {
            let dj = DJModel(), b = MIDIBinder(dj: dj, dsp: DSPModel(url: nil), transport: nil)
            b.requireDJMode = false
            b.turn("deckA.jog", ticks: 2); expect(abs(dj.a.bending - 0.7) < 1e-9, "two clicks nudge by 0.7")
            b.turn("deckA.jog", ticks: -10); expect(dj.a.bending == -1, "clamped")
            spin(1) { dj.a.bending == 0 }
            expect(dj.a.bending == 0, "the nudge ends when the wheel stops")
            expect(dj.b.bending == 0, "the other deck is untouched")
        }
    }

    // MARK: CoreMIDI

    /// Real MIDI from a virtual source through CoreMIDI, the receive block, the lock-free ring and the main-queue wake-up, to the mapping.
    func coreMIDIDeliversThroughTheRing() {
        MainActor.assumeIsolated {
            var client = MIDIClientRef()
            guard MIDIClientCreate("Aureon test" as CFString, nil, nil, &client) == noErr else { return }       // no MIDI service here: nothing to test
            defer { MIDIClientDispose(client) }
            var source = MIDIEndpointRef()
            guard MIDISourceCreateWithProtocol(client, "Aureon test source" as CFString, ._1_0, &source) == noErr else { return }
            defer { MIDIEndpointDispose(source) }

            let c = MIDIController(url: nil), r = FakeResolver()
            c.resolver = r; c.minDrainInterval = 0.004
            c.add(MIDIMapping(control: ccControl(2, 10), target: "mixer.masterLevel", pickup: false))
            c.add(MIDIMapping(control: MIDIControl(kind: .note, channel: 0, number: 60), target: "player.playPause"))
            c.add(MIDIMapping(control: ccControl(0, 21), target: "deckA.jog", mode: .relativeOffset))
            c.start()
            expect(c.error == nil, "the MIDI service opened: \(c.error ?? "")")
            guard c.error == nil else { return }
            expect(c.sources.contains { $0.name.contains("Aureon test source") }, "our source is listed: \(c.sources.map(\.name))")

            func send(_ words: [UInt32]) {
                let size = 16_384
                let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8); defer { raw.deallocate() }
                let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
                var start = 0
                while start < words.count {                                        // a list holds a few hundred words: send big bursts in chunks
                    var pkt = MIDIEventListInit(list, ._1_0)
                    for w in words[start..<min(words.count, start + 200)] { var x = w; pkt = MIDIEventListAdd(list, size, pkt, 0, 1, &x) }
                    MIDIReceivedEventList(source, list)
                    start += 200
                }
            }
            send([word(2, 0x9, 0, 60, 100), word(2, 0x8, 0, 60, 0), word(2, 0xB, 2, 10, 127), 0x10F8_0000, word(2, 0xB, 0, 21, 65), word(2, 0xB, 0, 21, 62)])
            spin(3) { !r.writes.isEmpty && r.fired.count == 1 && r.turned.count == 2 }
            expect(r.fired == ["player.playPause"], "the key press arrived once: \(r.fired)")
            expect(r.writes.count == 1 && abs(r.writes[0].value - 1.25) < 1e-9, "the controller arrived: \(r.writes)")
            expect(r.turned.map { $0.ticks } == [1, -2], "relative ticks arrived in order: \(r.turned)")
            expect(c.activity.count > 0 && c.activity.last != nil, "the activity line saw it")

            // a burst: 3 000 controller messages, then the last value wins
            r.writes = []
            send((0..<3_000).map { word(2, 0xB, 2, 10, UInt32($0 % 128)) } + [word(2, 0xB, 2, 10, 64)])
            spin(3) { r.values["mixer.masterLevel"].map { abs($0 - 1.25 * 64 / 127) < 1e-9 } ?? false }
            expect(abs((r.values["mixer.masterLevel"] ?? 0) - 1.25 * 64 / 127) < 1e-9 && r.writes.count < 3_000, "a burst ends at the last value with far fewer writes: \(r.writes.count)")

            // switching a device off stops it being heard
            if let id = c.sources.first(where: { $0.name.contains("Aureon test source") })?.id {
                c.setSource(id, enabled: false)
                r.fired = []
                send([word(2, 0x9, 0, 60, 100)])
                spin(0.4)
                expect(r.fired.isEmpty, "a disabled source is not heard")
                c.setSource(id, enabled: true)
                send([word(2, 0x9, 0, 60, 100)])
                spin(3) { !r.fired.isEmpty }
                expect(r.fired == ["player.playPause"], "and is heard again when switched back on")
            }
            c.stop()
            expect(c.sources.isEmpty, "stopped")
        }
    }
}

import Foundation
import Combine

// MIDI control surfaces, part 3: interpreting messages. Runs on the main actor; the CoreMIDI thread only fills a ring.

/// What the controller needs from the app to act on a target. `PlayerModel` provides one (MIDIBinder); the tests provide a fake.
@MainActor
protocol MIDITargetResolver: AnyObject {
    /// False when the target cannot act right now (a deck target while the DJ console is closed): the message is ignored.
    func isAvailable(_ id: String) -> Bool
    /// The target's current value on its own scale, or nil when unknown.
    func current(_ id: String) -> Double?
    func set(_ id: String, value: Double)
    func fire(_ id: String)
    func turn(_ id: String, ticks: Double)
}

/// A tiny observable for the "something is arriving" readout, so a busy fader redraws one small view and not the whole page.
@MainActor
final class MIDIActivity: ObservableObject {
    @Published private(set) var last: MIDIMessage?
    @Published private(set) var count = 0
    fileprivate func note(_ m: MIDIMessage) { last = m; count += 1 }
}

@MainActor
final class MIDIController: ObservableObject {
    // person-facing state
    @Published var enabled = true { didSet { if enabled != oldValue { enabledChanged(); persist() } } }
    @Published private(set) var sources: [MIDISourceInfo] = []
    @Published private(set) var disabledSources: Set<Int32> = []
    @Published private(set) var mappings: [MIDIMapping] = [] { didSet { reindex() } }
    /// The target waiting for the person to move a control (MIDI learn).
    @Published private(set) var learning: String?
    /// Mappings whose control has not yet reached the on-screen value (soft takeover).
    @Published private(set) var waitingForPickup: Set<UUID> = []
    @Published private(set) var error: String?
    /// Short notice after a preset or a learn.
    @Published private(set) var notice: String?
    let activity = MIDIActivity()

    var resolver: MIDITargetResolver?
    /// How often, at most, queued messages are applied (a fast fader sends hundreds per second; the screen shows 120).
    var minDrainInterval = 1.0 / 125

    private let url: URL?
    private var input: MIDIInput?
    private var drainScheduled = false
    private var lastDrain = 0.0
    private var byControl: [MIDIControl: [MIDIMapping]] = [:]
    private var byLSB: [MIDIControl: [MIDIMapping]] = [:]
    private var needsEveryMessage: Set<MIDIControl> = []
    // per-mapping run-time state
    private struct Pickup { var engaged = false; var last: Double?; var written: Double? }
    private var pickup: [UUID: Pickup] = [:]
    private var down: Set<UUID> = []
    private var msb: [UUID: Int] = [:], lsb: [UUID: Int] = [:]
    private(set) var droppedMessages = 0

    nonisolated static var defaultURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/midi.json") }

    init(url: URL? = MIDIController.defaultURL) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(MIDISettingsFile.self, from: d) {
            enabled = f.enabled; disabledSources = Set(f.disabledSources); mappings = f.mappings.filter { MIDITargets.target($0.target) != nil }
            reindex()                       // property observers do not run inside init
        }
    }

    // MARK: life cycle

    /// Opens the MIDI service and starts listening (when switched on). Safe to call again.
    func start() {
        guard enabled, input == nil else { return }
        let i = MIDIInput { [weak self] in MainActor.assumeIsolated { self?.scheduleDrain() } }
        i.onTopologyChange = { [weak self] in MainActor.assumeIsolated { self?.refreshSources() } }
        do {
            i.setDisabled(disabledSources)
            try i.start()
            input = i; error = nil
            refreshSources()
        } catch { self.error = "\(error)" }
    }

    func stop() {
        input?.stop(); input = nil
        sources = []; waitingForPickup = []
    }

    private func enabledChanged() { if enabled { start() } else { stop(); learning = nil } }

    private func refreshSources() { sources = MIDIInput.sources().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    func setSource(_ id: Int32, enabled on: Bool) {
        if on { disabledSources.remove(id) } else { disabledSources.insert(id) }
        input?.setDisabled(disabledSources)
        persist()
    }
    func isSourceEnabled(_ id: Int32) -> Bool { !disabledSources.contains(id) }

    // MARK: draining

    private func scheduleDrain() {
        let now = ProcessInfo.processInfo.systemUptime
        let wait = minDrainInterval - (now - lastDrain)
        if wait <= 0 { drain() }
        else if !drainScheduled {
            drainScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in MainActor.assumeIsolated { self?.drainScheduled = false; self?.drain() } }
        }
    }

    /// Takes everything queued by the CoreMIDI thread and applies it.
    func drain() {
        guard let input else { return }
        lastDrain = ProcessInfo.processInfo.systemUptime
        var batch: [MIDIMessage] = []
        while let w = input.ring.pop() { if let m = MIDIMessage(packed: w) { batch.append(m) } }
        droppedMessages = input.ring.dropped
        if !batch.isEmpty { ingest(batch) }
    }

    /// Applies a batch in arrival order. A fader that moved ten times since the last drain is applied once, at its last position
    /// (a 14-bit pair once per byte); notes, buttons and encoders always see every message.
    func ingest(_ batch: [MIDIMessage]) {
        guard !batch.isEmpty else { return }
        var keep = [Bool](repeating: true, count: batch.count)
        var seen = Set<MIDIControl>()
        for i in stride(from: batch.count - 1, through: 0, by: -1) {
            let c = batch[i].control
            if c.kind == .note || needsEveryMessage.contains(c) { continue }
            if !seen.insert(c).inserted { keep[i] = false }
        }
        for (i, m) in batch.enumerated() where keep[i] { process(m) }
        activity.note(batch[batch.count - 1])
    }

    // MARK: learn

    func beginLearn(_ target: String) {
        guard MIDITargets.target(target) != nil else { return }
        learning = target; notice = nil
    }
    func cancelLearn() { learning = nil }

    private func learn(_ m: MIDIMessage) {
        guard let id = learning, let t = MIDITargets.target(id) else { return }
        // a release or a controller at rest is not the person's choice; wait for a press or a movement
        if m.control.kind == .note && m.value == 0 { return }
        learning = nil
        var map = MIDIMapping(control: m.control, target: id)
        if t.kind == .encoder { map.mode = .relativeOffset }
        if m.control.kind == .pitchBend { map.mode = .absolute }
        add(map)
        notice = "\(t.title) ← \(m.control.title)"
    }

    // MARK: editing

    func mapping(for target: String) -> MIDIMapping? { mappings.first { $0.target == target } }

    /// Adds a mapping. One control drives one target: anything already using this control or this target is replaced.
    func add(_ map: MIDIMapping) {
        guard MIDITargets.target(map.target) != nil else { return }
        mappings.removeAll { $0.target == map.target || $0.control == map.control }
        mappings.append(map)
        persist()
    }

    func clear(target: String) {
        mappings.removeAll { $0.target == target }
        persist()
    }

    func update(_ m: MIDIMapping) {
        guard let i = mappings.firstIndex(where: { $0.id == m.id }) else { return }
        mappings[i] = m
        pickup[m.id] = nil; waitingForPickup.remove(m.id)
        persist()
    }

    func removeAll() { mappings = []; persist() }

    /// Adds a preset's mappings. A mapping already using one of its controls or targets is replaced.
    func apply(_ preset: MIDIPreset) {
        var map = mappings
        for p in preset.mappings { map.removeAll { $0.control == p.control || $0.target == p.target } }
        map += preset.mappings
        mappings = map
        persist()
        notice = "\(preset.name): \(preset.mappings.count) controls mapped"
    }

    // MARK: interpreting

    private func reindex() {
        byControl = [:]; byLSB = [:]; needsEveryMessage = []
        for m in mappings {
            byControl[m.control, default: []].append(m)
            if m.mode == .absolute14, let l = m.control.lsbPartner { byLSB[l, default: []].append(m) }
            // buttons on controllers, and encoders, must see every message; levels only need the latest
            if m.mode.isRelative || MIDITargets.target(m.target)?.kind != .continuous { needsEveryMessage.insert(m.control) }
        }
        let ids = Set(mappings.map(\.id))
        pickup = pickup.filter { ids.contains($0.key) }; down = down.intersection(ids); msb = msb.filter { ids.contains($0.key) }; lsb = lsb.filter { ids.contains($0.key) }
        waitingForPickup = waitingForPickup.intersection(ids)
    }

    func process(_ m: MIDIMessage) {
        if learning != nil { learn(m); return }
        guard enabled, let resolver else { return }
        if let list = byLSB[m.control] { for map in list { apply(m, to: map, resolver: resolver, isLSB: true) } }
        if let list = byControl[m.control] { for map in list { apply(m, to: map, resolver: resolver, isLSB: false) } }
    }

    private func apply(_ m: MIDIMessage, to map: MIDIMapping, resolver: MIDITargetResolver, isLSB: Bool) {
        guard let t = MIDITargets.target(map.target), resolver.isAvailable(t.id) else { return }
        switch t.kind {
        case .trigger:
            if isLSB { return }
            if m.isPress { if down.insert(map.id).inserted { resolver.fire(t.id) } } else { down.remove(map.id) }
        case .encoder:
            guard map.mode.isRelative, !isLSB else { return }
            let ticks = Double(map.mode.ticks(m.value)) * map.sensitivity * (map.inverted ? -1 : 1)
            if ticks != 0 { resolver.turn(t.id, ticks: ticks) }
        case .continuous:
            if map.mode.isRelative {
                guard !isLSB, let cur = resolver.current(t.id) else { return }
                let ticks = Double(map.mode.ticks(m.value)) * map.sensitivity * (map.inverted ? -1 : 1)
                if ticks == 0 { return }
                resolver.set(t.id, value: t.value(t.norm(cur) + ticks * (t.step > 0 ? t.step : 0.01)))
                return
            }
            var raw = m.value, top = Double(m.maxValue)
            if map.mode == .absolute14 {
                if isLSB { lsb[map.id] = m.value } else { msb[map.id] = m.value }
                raw = (msb[map.id] ?? 0) << 7 | (lsb[map.id] ?? 0); top = 16_383
                if msb[map.id] == nil { return }                  // wait for the first most-significant byte
            }
            var n = Double(raw) / top
            if map.inverted { n = 1 - n }
            absolute(n, map: map, target: t, resolver: resolver)
        }
    }

    /// Soft takeover: the control must first reach (or cross) the on-screen value; after that it follows, until the value is changed from
    /// somewhere else (the screen, another surface), when it has to catch up again.
    private func absolute(_ n: Double, map: MIDIMapping, target t: MIDITarget, resolver: MIDITargetResolver) {
        var st = pickup[map.id] ?? Pickup()
        defer { pickup[map.id] = st }
        let cur = resolver.current(t.id).map { t.norm($0) }
        if map.pickup || t.alwaysPickup, let cur {
            if st.engaged, let w = st.written, abs(cur - w) > 0.03 { st.engaged = false }          // moved elsewhere: catch up again
            if !st.engaged {
                let near = abs(n - cur) <= 0.02
                let crossed = st.last.map { ($0 - cur) * (n - cur) <= 0 } ?? false
                if near || crossed { st.engaged = true } else {
                    st.last = n
                    if !waitingForPickup.contains(map.id) { waitingForPickup.insert(map.id) }
                    return
                }
            }
        }
        st.engaged = true; st.last = n
        let v = t.value(n)
        resolver.set(t.id, value: v)
        st.written = resolver.current(t.id).map { t.norm($0) } ?? n
        if waitingForPickup.contains(map.id) { waitingForPickup.remove(map.id) }
    }

    // MARK: storage

    private func persist() {
        guard let url, ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil, ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil || url != MIDIController.defaultURL else { return }
        var f = MIDISettingsFile(); f.enabled = enabled; f.disabledSources = disabledSources.sorted(); f.mappings = mappings
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: url, options: .atomic) }
    }
}

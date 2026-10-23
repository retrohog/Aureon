import SwiftUI

/// Settings → MIDI: devices, controller presets and MIDI learn.
struct MIDIPage: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View { MIDIView(midi: m.midi, djMode: m.djMode) }
}

private struct GroupChip: Hashable, Identifiable { var id: String }

struct MIDIView: View {
    @ObservedObject var midi: MIDIController
    let djMode: Bool
    @StateObject private var group = Box(GroupChip(id: "Deck A"))

    var body: some View {
        VStack(spacing: 16) {
            devicesCard
            presetsCard
            controlsCard
        }
    }

    // MARK: devices

    private var devicesCard: some View {
        Card(title: "MIDI controllers", subtitle: "DJ controllers, fader banks and knob boxes. Plug one in and it appears here.") {
            Toggle("Use MIDI controllers", isOn: $midi.enabled)
            if let e = midi.error { Note(text: e, color: .red) }
            if midi.enabled {
                if midi.sources.isEmpty {
                    Note(text: "No MIDI device found. USB class-compliant controllers need no driver; Bluetooth ones are connected in Audio MIDI Setup.")
                } else {
                    ForEach(midi.sources) { s in deviceRow(s) }
                }
                MIDIActivityView(activity: midi.activity)
                if !djMode { Note(text: "Deck and mixer controls act while the DJ console is open (top-right button). The parametric EQ and player controls always work.") }
                if midi.droppedMessages > 0 { Note(text: "\(midi.droppedMessages) messages were dropped because the controller sent faster than they could be handled.", color: Brand.caution) }
            }
        }
    }

    private func deviceRow(_ s: MIDISourceInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(get: { midi.isSourceEnabled(s.id) }, set: { midi.setSource(s.id, enabled: $0) })) { Text(s.name) }
                if !s.online { Badge(text: "Offline", color: .secondary) }
            }
            ForEach(MIDIPresets.suggestions(for: s.name)) { p in
                HStack(spacing: 8) {
                    Badge(text: "Preset available", color: Brand.accentText)
                    Text(p.name).font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                    Spacer()
                    Button("Apply") { midi.apply(p) }.controlSize(.small)
                }
            }
        }
    }

    // MARK: presets

    private var presetsCard: some View {
        Card(title: "Controller presets", subtitle: "Ready-made mappings. Applying one replaces mappings that use the same controls or targets; the rest are kept.") {
            ForEach(MIDIPresets.all) { p in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(Typo.sans(13.5, .semibold))
                        Text(p.summary).font(Typo.caption).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Apply") { midi.apply(p) }
                }
            }
            if let n = midi.notice { Note(text: n, color: Brand.accentText) }
            Note(text: "Presets follow each maker's published MIDI map. If a control does nothing or moves the wrong way, use Learn below to reassign it, or Reverse direction in its ⋯ menu.")
        }
    }

    // MARK: controls

    private var controlsCard: some View {
        Card(title: "Controls", subtitle: "Press Learn, then move the knob or press the key on your controller") {
            SectionChips(items: MIDITargets.groups.map { GroupChip(id: $0) }, selection: $group.v, label: \.id)
            if let id = midi.learning, let t = MIDITargets.target(id) {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Brand.caution)
                    Text("Move a control for “\(t.title)”…").font(Typo.sans(13, .medium))
                    Spacer()
                    Button("Cancel") { midi.cancelLearn() }.controlSize(.small)
                }
                .padding(12).background(RoundedRectangle(cornerRadius: Metrics.radius(8), style: .continuous).fill(Brand.caution.opacity(0.14)))
            }
            VStack(spacing: 0) {
                let list = MIDITargets.targets(in: group.v.id)
                ForEach(list) { t in
                    row(t)
                    if t.id != list.last?.id { Divider().opacity(0.5) }
                }
            }
            HStack {
                Spacer()
                Button("Remove all mappings") {
                    if askToProceed(title: "Remove every MIDI mapping?", message: "You can bring them back with a controller preset or by learning them again.", proceed: "Remove all") { midi.removeAll() }
                }.controlSize(.small).disabled(midi.mappings.isEmpty)
            }
        }
    }

    private func row(_ t: MIDITarget) -> some View {
        let maps = midi.mappings.filter { $0.target == t.id }
        let learning = midi.learning == t.id
        return HStack(spacing: 8) {
            Text(t.title).font(Typo.sans(13)).frame(maxWidth: .infinity, alignment: .leading)
            if let first = maps.first {
                if midi.waitingForPickup.contains(where: { id in maps.contains { $0.id == id } }) {
                    Badge(text: "move to pick up", color: Brand.caution)
                }
                Text(first.control.title + (maps.count > 1 ? "  +\(maps.count - 1)" : "")).font(Typo.mono(11.5)).foregroundStyle(Brand.inkSecondary)
                optionsMenu(first, target: t)
                Button { midi.clear(target: t.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Brand.inkSecondary).help("Remove this mapping")
            }
            Button(learning ? "Cancel" : (maps.isEmpty ? "Learn" : "Re-learn")) { learning ? midi.cancelLearn() : midi.beginLearn(t.id) }
                .controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    private func optionsMenu(_ map: MIDIMapping, target t: MIDITarget) -> some View {
        return Menu {
            if t.kind != .trigger {
                Picker("Control type", selection: Binding(get: { map.mode }, set: { v in var x = map; x.mode = v; midi.update(x) })) {
                    ForEach(MIDIValueMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Reverse direction", isOn: Binding(get: { map.inverted }, set: { v in var x = map; x.inverted = v; midi.update(x) }))
            }
            if t.kind == .continuous {
                Toggle("Wait for the control to reach the on-screen value", isOn: Binding(get: { map.pickup || t.alwaysPickup }, set: { v in var x = map; x.pickup = v; midi.update(x) })).disabled(t.alwaysPickup)
            }
            if t.kind == .encoder || map.mode.isRelative {
                Picker("Sensitivity", selection: Binding(get: { map.sensitivity }, set: { v in var x = map; x.sensitivity = v; midi.update(x) })) {
                    ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { Text("×\(String(format: "%g", $0))").tag($0) }
                }
            }
            if t.kind == .trigger { Text("Buttons act when pressed.") }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

/// The last message heard: a small view of its own, so a busy fader redraws this line and nothing else.
struct MIDIActivityView: View {
    @ObservedObject var activity: MIDIActivity
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(activity.last == nil ? Brand.inkSecondary.opacity(0.4) : Brand.accentText).frame(width: 8, height: 8)
            Text(activity.last?.summary ?? "Move a control on your device to see its message here").font(Typo.mono(12)).foregroundStyle(Brand.inkSecondary)
        }
    }
}

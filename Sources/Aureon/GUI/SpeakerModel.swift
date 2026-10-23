import SwiftUI
import CoreAudio

@MainActor
final class SpeakerModel: ObservableObject {
    @Published var setup = SpeakerSetup() {
        didSet {
            guard setup != oldValue else { return }
            save()
            let shape: (SpeakerSetup) -> [String] = { $0.enabled ? $0.members.map(\.uid) : [] }
            if shape(setup) != shape(oldValue) { onRouteChange?() }           // a device joined or left: the output is rebuilt
            else if setup.enabled { sink?.update(setup) }                      // roles, delays, levels: changed while playing
        }
    }
    var onRouteChange: (() -> Void)?
    private weak var sink: MultiDeviceSink?
    private let defaults = UserDefaults.standard
    private static let key = "aureon.speakers"

    init() {
        if let d = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(SpeakerSetup.self, from: d) { setup = s }
    }

    private func save() { if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil { defaults.set(try? JSONEncoder().encode(setup), forKey: Self.key) } }

    /// True when the setup is on and at least two of its devices are present.
    func isActive(devices: [OutputDeviceInfo]) -> Bool { setup.enabled && setup.members.filter { m in devices.contains { $0.uid == m.uid } }.count >= 2 }

    func sinkFactory(primary: AudioDeviceID) -> ((PlayerOptions) -> AudioSink?)? {
        guard setup.enabled else { return nil }
        let s = setup
        return { [weak self] _ in
            guard let sink = MultiDeviceSink(setup: s, primaryID: primary) else { return nil }
            DispatchQueue.main.async { self?.sink = sink }
            return sink
        }
    }

    func member(_ uid: String) -> Binding<SpeakerMember>? {
        guard setup.members.contains(where: { $0.uid == uid }) else { return nil }
        return Binding(get: { self.setup.members.first { $0.uid == uid } ?? SpeakerMember(uid: uid, name: "") },
                       set: { v in if let i = self.setup.members.firstIndex(where: { $0.uid == uid }) { self.setup.members[i] = v } })
    }

    /// The volume of the main output changed: the others follow it, each slid to its calibrated level.
    func matchVolume(_ v: Float) { sink?.matchOthers(to: v) }

    /// What the automatic balance adds for this member on top of the user's own level, in dB (0 when it is switched off).
    func balanceDB(_ m: SpeakerMember) -> Double { setup.autoLevel ? SpeakerCalibration.roleOffsetDB(m.role) : 0 }

    func add(_ d: OutputDeviceInfo) {
        guard !d.uid.isEmpty, !setup.members.contains(where: { $0.uid == d.uid }) else { return }
        setup.members.append(SpeakerMember(uid: d.uid, name: d.name))
    }
    func remove(_ uid: String) { setup.members.removeAll { $0.uid == uid } }

    /// Switching on: make sure the device already in use is part of it.
    func enable(primary: OutputDeviceInfo?) {
        if let p = primary { add(p) }
        setup.enabled = true
    }

    // MARK: presets

    private func isBuiltIn(_ name: String) -> Bool { let n = name.lowercased(); return n.contains("macbook") || n.contains("built-in") || n.contains("imac") || n.contains("mac mini speakers") || n.contains("mac studio speakers") || n.contains("studio display") }

    enum Preset: String, CaseIterable, Identifiable {
        case sameEverywhere = "Same sound on every speaker", laptopCentre = "Laptop plays the centre (voice)", laptopAmbience = "Laptop plays the ambience"
        var id: String { rawValue }
    }

    func apply(_ p: Preset) {
        var s = setup
        for i in s.members.indices {
            let builtIn = isBuiltIn(s.members[i].name)
            switch p {
            case .sameEverywhere: s.members[i].role = .main
            case .laptopCentre: s.members[i].role = builtIn ? .center : .main
            case .laptopAmbience: s.members[i].role = builtIn ? .surround : .main
            }
        }
        setup = s
    }
}

/// A button that shows the current choice and opens a list in a popover. Used instead of the system pop-up menus.
struct PopoverPicker<T: Hashable>: View {
    @Binding var selection: T
    let items: [T]
    let label: (T) -> String
    var icon: ((T) -> String)? = nil
    @StateObject private var openBox = Box(false)
    private var open: Bool { get { openBox.v } nonmutating set { openBox.v = newValue } }
    private var openBinding: Binding<Bool> { Binding(get: { openBox.v }, set: { openBox.v = $0 }) }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon(selection)).foregroundStyle(Brand.accent) }
                Text(label(selection)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(Typo.sans(9, .semibold)).foregroundStyle(Brand.inkSecondary)
            }
            .padding(.horizontal, 12).frame(height: 26).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Metrics.radius(7), style: .continuous).fill(Brand.ink.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: openBinding, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.self) { it in
                    Button { selection = it; open = false } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").opacity(it == selection ? 1 : 0).frame(width: 14)
                            if let icon { Image(systemName: icon(it)).frame(width: 18) }
                            Text(label(it))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(8).frame(minWidth: 220)
        }
    }
}

struct SpeakerSetupCard: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var sp: SpeakerModel

    var body: some View {
        Card(title: "Speaker setup", subtitle: "Use several outputs at once: the laptop's own speakers together with speakers on the headphone jack, a USB DAC or anything else") {
            Toggle("Play through more than one output", isOn: Binding(get: { sp.setup.enabled }, set: { on in
                if on { m.refreshDevices(); sp.enable(primary: m.devices.first { $0.id == m.deviceID }) } else { sp.setup.enabled = false }
            }))
            if sp.setup.enabled {
                if sp.setup.members.count < 2 { Note(text: "Add at least one more output below. Until then the sound plays through the main output only.", color: Brand.caution) }
                ForEach(sp.setup.members) { mem in
                    if let b = sp.member(mem.uid) { memberRow(b, isMain: m.devices.first { $0.uid == mem.uid }?.id == m.deviceID) }
                }
                HStack(spacing: 12) {
                    AddSpeakerButton()
                    QuickSetups()
                }
                if sp.setup.members.contains(where: { $0.role == .bass }) {
                    HStack {
                        Text("Crossover").frame(width: 110, alignment: .leading)
                        ValueSlider(value: $sp.setup.crossoverHz, in: 50...250, step: 5)
                        Text("\(Int(sp.setup.crossoverHz)) Hz").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                    Toggle("Keep the bass out of the other speakers", isOn: $sp.setup.bassManagement)
                }
                Toggle("Balance the speakers by their jobs and keep them balanced when the volume changes", isOn: $sp.setup.autoLevel)
                Note(text: "Every output has a job. Stereo plays the left and right channels; Centre plays what both have in common (voices); Ambience adds the room around the music (width and reverb above the low notes, which it plays as the stereo speakers do, so the beat stays); Bass plays only the low notes. Aureon asks each output how late it plays and delays the earlier ones, so a built-in speaker and a Bluetooth one still arrive together; “Extra delay” trims that by ear, and can be negative. Tell Aureon how far each speaker is from where you sit and it delays the nearer ones so the sound from all of them arrives together; “extra delay” fine-tunes by ear. The laptop's speakers are small: they do centre and ambience well, bass poorly.")
                Note(text: "When the volume is changed, every output follows in decibels and slides to its level in a few milliseconds, so none jumps ahead of the others. “Level” is for what Aureon cannot know, such as one speaker simply being more sensitive than another. The outputs share one stream, so Aureon plays all of them at one sample rate they all support, and the sound is no longer bit-perfect. The main output (the one chosen in the sidebar) sets the timing; the others follow it and are kept in step automatically.")
            }
        }
    }

    private func memberRow(_ b: Binding<SpeakerMember>, isMain: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: b.wrappedValue.role.symbol).foregroundStyle(Brand.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(b.wrappedValue.name).fontWeight(.medium)
                    if isMain { Text("Main output (sets the timing)").font(Typo.caption2).foregroundStyle(Brand.inkTertiary) }
                }
                Spacer()
                PopoverPicker(selection: b.role, items: SpeakerRole.allCases, label: { $0.title }, icon: { $0.symbol })
                if !isMain { Button { sp.remove(b.wrappedValue.uid) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Brand.inkSecondary).help("Remove this speaker") }
            }
            Note(text: b.wrappedValue.role.blurb)
            HStack {
                Text("Distance").frame(width: 90, alignment: .leading)
                ValueSlider(value: b.distanceM, in: 0...6, step: 0.1)
                Text(b.wrappedValue.distanceM == 0 ? "not set" : String(format: "%.1f m", b.wrappedValue.distanceM)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            HStack {
                Text("Extra delay").frame(width: 90, alignment: .leading)
                ValueSlider(value: b.extraDelayMs, in: -50...500, step: 0.5)
                Text(String(format: "%.1f ms", b.wrappedValue.extraDelayMs)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            HStack {
                Text("Level").frame(width: 90, alignment: .leading)
                ValueSlider(value: b.trimDB, in: -12...6, step: 0.5)
                Text(String(format: "%+.1f dB", b.wrappedValue.trimDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            if sp.setup.autoLevel {
                let auto = sp.balanceDB(b.wrappedValue)
                Text(abs(auto) < 0.05 ? "Automatic balance: none needed for this job" : String(format: "Automatic balance: %+.1f dB for this job, on top of the level above", auto))
                    .font(Typo.sans(11)).foregroundStyle(Brand.inkTertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.radius(10), style: .continuous).fill(Brand.ink.opacity(0.05)))
    }
}

private struct QuickSetups: View {
    @EnvironmentObject var sp: SpeakerModel
    @StateObject private var openBox = Box(false)

    var body: some View {
        Button { openBox.v.toggle() } label: { Label("Quick set-ups", systemImage: "wand.and.stars") }
            .popover(isPresented: Binding(get: { openBox.v }, set: { openBox.v = $0 }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SpeakerModel.Preset.allCases) { p in
                        Button { sp.apply(p); openBox.v = false } label: { HStack { Text(p.rawValue); Spacer(minLength: 0) }.padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle()) }.buttonStyle(.plain)
                    }
                    Text("Roles are set by device name: the laptop's own speakers are recognised, everything else counts as external.").font(Typo.caption2).foregroundStyle(Brand.inkSecondary).padding(8).frame(width: 250, alignment: .leading)
                }.padding(8).frame(minWidth: 260)
            }
    }
}

private struct AddSpeakerButton: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var sp: SpeakerModel
    @StateObject private var openBox = Box(false)
    private var open: Bool { get { openBox.v } nonmutating set { openBox.v = newValue } }
    private var openBinding: Binding<Bool> { Binding(get: { openBox.v }, set: { openBox.v = $0 }) }

    var body: some View {
        let free = m.devices.filter { d in !d.uid.isEmpty && !sp.setup.members.contains { $0.uid == d.uid } }
        Button { m.refreshDevices(); open.toggle() } label: { Label("Add an output…", systemImage: "plus") }
            .popover(isPresented: openBinding, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    if free.isEmpty { Text("No other outputs found. Plug one in and try again.").font(Typo.caption).foregroundStyle(Brand.inkSecondary).padding(8) }
                    ForEach(free) { d in
                        Button { sp.add(d); open = false } label: { HStack { Image(systemName: "hifispeaker"); Text(d.name); Spacer(minLength: 0) }.padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle()) }.buttonStyle(.plain)
                    }
                }.padding(8).frame(minWidth: 240)
            }
    }
}

/// The output chooser in the sidebar, above the layout switch: what the sound plays through, one click away from anywhere.
struct OutputSwitcher: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var sp: SpeakerModel
    @StateObject private var hover = Box(false)
    @StateObject private var openBox = Box(false)
    private var open: Bool { get { openBox.v } nonmutating set { openBox.v = newValue } }
    private var openBinding: Binding<Bool> { Binding(get: { openBox.v }, set: { openBox.v = $0 }) }

    var body: some View {
        let multi = sp.isActive(devices: m.devices)
        Button { m.refreshDevices(); open.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: multi ? "hifispeaker.2.fill" : "hifispeaker").font(Typo.sans(13, .light)).frame(width: 20).foregroundStyle(Brand.inkSecondary)
                Text(m.selectedDevice?.name ?? "Output").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                if multi { Text("+\(max(0, sp.setup.members.count - 1))").font(Typo.sans(10, .bold)).padding(.horizontal, 4).padding(.vertical, 1).background(Slab().fill(Brand.accent.opacity(0.25))) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(Typo.sans(9, .semibold)).foregroundStyle(Brand.inkSecondary)
            }
            .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
            .background(Rectangle().fill(Brand.ink.opacity(hover.v ? 0.04 : 0)))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.help("Choose where the sound plays")
        .popover(isPresented: openBinding, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("OUTPUT").font(Typo.caption2.weight(.semibold)).foregroundStyle(Brand.inkSecondary).padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(m.devices) { d in
                    Button { m.deviceID = d.id; open = false } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").opacity(d.id == m.deviceID ? 1 : 0).frame(width: 14)
                            Text(d.name)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Divider().padding(.vertical, 4)
                if sp.setup.members.count >= 2 {
                    Toggle("Use all set-up speakers", isOn: Binding(get: { sp.setup.enabled }, set: { sp.setup.enabled = $0 })).padding(.horizontal, 8)
                }
                Button { open = false; withAnimation(.easeOut(duration: 0.14)) { m.djMode = false; m.tab = .audio } } label: {
                    HStack(spacing: 8) { Image(systemName: "slider.horizontal.3").frame(width: 14); Text("Speaker setup…"); Spacer(minLength: 0) }.padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(8).frame(minWidth: 250)
        }
    }
}

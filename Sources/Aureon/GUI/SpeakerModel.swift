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

    private func save() { defaults.set(try? JSONEncoder().encode(setup), forKey: Self.key) }

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
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon(selection)).foregroundStyle(Brand.accent) }
                Text(label(selection)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: 26).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.ink.opacity(0.09)))
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
                        }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
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
                if on { m.refreshDevices(); sp.enable(primary: m.selectedDevice.flatMap { d in listOutputDevices().first { $0.id == d.id } }) } else { sp.setup.enabled = false }
            }))
            if sp.setup.enabled {
                if sp.setup.members.count < 2 { Note(text: "Add at least one more output below. Until then the sound plays through the main output only.", color: .orange) }
                ForEach(sp.setup.members) { mem in
                    if let b = sp.member(mem.uid) { memberRow(b, isMain: listOutputDevices().first { $0.uid == mem.uid }?.id == m.deviceID) }
                }
                HStack(spacing: 10) {
                    AddSpeakerButton()
                    Menu("Quick set-ups") { ForEach(SpeakerModel.Preset.allCases) { p in Button(p.rawValue) { sp.apply(p) } } }.fixedSize()
                }
                if sp.setup.members.contains(where: { $0.role == .bass }) {
                    HStack {
                        Text("Crossover").frame(width: 110, alignment: .leading)
                        Slider(value: $sp.setup.crossoverHz, in: 50...250, step: 5)
                        Text("\(Int(sp.setup.crossoverHz)) Hz").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                    Toggle("Keep the bass out of the other speakers", isOn: $sp.setup.bassManagement)
                }
                Note(text: "Every output has a job. Stereo plays the left and right channels; Centre plays what both have in common (voices); Ambience plays what differs between them (room sound, width); Bass plays only the low notes. Tell Aureon how far each speaker is from where you sit and it delays the nearer ones so the sound from all of them arrives together; “extra delay” fine-tunes by ear. The laptop's speakers are small: they do centre and ambience well, bass poorly.")
                Note(text: "The outputs share one stream, so Aureon plays all of them at one sample rate they all support, and the sound is no longer bit-perfect. The main output (the one chosen in the sidebar) sets the timing; the others follow it and are kept in step automatically.")
            }
        }
    }

    private func memberRow(_ b: Binding<SpeakerMember>, isMain: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: b.wrappedValue.role.symbol).foregroundStyle(Brand.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(b.wrappedValue.name).fontWeight(.medium)
                    if isMain { Text("Main output (sets the timing)").font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer()
                PopoverPicker(selection: b.role, items: SpeakerRole.allCases, label: { $0.title }, icon: { $0.symbol })
                if !isMain { Button { sp.remove(b.wrappedValue.uid) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this speaker") }
            }
            Note(text: b.wrappedValue.role.blurb)
            HStack {
                Text("Distance").frame(width: 90, alignment: .leading)
                Slider(value: b.distanceM, in: 0...6, step: 0.1)
                Text(b.wrappedValue.distanceM == 0 ? "not set" : String(format: "%.1f m", b.wrappedValue.distanceM)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            HStack {
                Text("Extra delay").frame(width: 90, alignment: .leading)
                Slider(value: b.extraDelayMs, in: 0...100, step: 0.5)
                Text(String(format: "%.1f ms", b.wrappedValue.extraDelayMs)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            HStack {
                Text("Level").frame(width: 90, alignment: .leading)
                Slider(value: b.trimDB, in: -12...6, step: 0.5)
                Text(String(format: "%+.1f dB", b.wrappedValue.trimDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.ink.opacity(0.05)))
    }
}

private struct AddSpeakerButton: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var sp: SpeakerModel
    @StateObject private var openBox = Box(false)
    private var open: Bool { get { openBox.v } nonmutating set { openBox.v = newValue } }
    private var openBinding: Binding<Bool> { Binding(get: { openBox.v }, set: { openBox.v = $0 }) }

    var body: some View {
        let free = listOutputDevices().filter { d in !d.uid.isEmpty && !sp.setup.members.contains { $0.uid == d.uid } }
        Button { m.refreshDevices(); open.toggle() } label: { Label("Add an output…", systemImage: "plus") }
            .popover(isPresented: openBinding, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    if free.isEmpty { Text("No other outputs found. Plug one in and try again.").font(.caption).foregroundStyle(.secondary).padding(8) }
                    ForEach(free) { d in
                        Button { sp.add(d); open = false } label: { HStack { Image(systemName: "hifispeaker"); Text(d.name); Spacer(minLength: 0) }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle()) }.buttonStyle(.plain)
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
        let multi = sp.isActive(devices: listOutputDevices())
        Button { m.refreshDevices(); open.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: multi ? "hifispeaker.2.fill" : "hifispeaker").font(.system(size: 14)).frame(width: 20).foregroundStyle(Brand.accent)
                Text(m.selectedDevice?.name ?? "Output").font(.system(size: 13, weight: .medium)).lineLimit(1)
                if multi { Text("+\(max(0, sp.setup.members.count - 1))").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Brand.accent.opacity(0.25))) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.06 : 0)))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.help("Choose where the sound plays")
        .popover(isPresented: openBinding, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("OUTPUT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(m.devices) { d in
                    Button { m.deviceID = d.id; open = false } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").opacity(d.id == m.deviceID ? 1 : 0).frame(width: 14)
                            Text(d.name)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Divider().padding(.vertical, 4)
                if sp.setup.members.count >= 2 {
                    Toggle("Use all set-up speakers", isOn: Binding(get: { sp.setup.enabled }, set: { sp.setup.enabled = $0 })).padding(.horizontal, 8)
                }
                Button { open = false; withAnimation(.easeOut(duration: 0.14)) { m.djMode = false; m.tab = .audio } } label: {
                    HStack(spacing: 8) { Image(systemName: "slider.horizontal.3").frame(width: 14); Text("Speaker setup…"); Spacer(minLength: 0) }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(8).frame(minWidth: 250)
        }
    }
}

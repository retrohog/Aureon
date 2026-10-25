import SwiftUI
import CoreAudio

// The quick control panel: switch the output device in one click, and a few of the settings that are reached for most. It opens from the rail, from the
// player bar, from ⌥⌘D and from ⌘K. Nothing in it keeps a setting of its own: every control reads and writes the same value as its place in Atelier → Sound.

/// Where the output popover is anchored. Each place that can show it has its own, so two chips on one screen never present it twice (the second would
/// close the first, and the popover would vanish the moment it opened).
enum QuickPanelAnchor: Hashable { case rail, bar, stage }

/// What a device switch needs from the app.
@MainActor
protocol DeviceSwitching: AnyObject {
    var devices: [OutputDeviceInfo] { get }
    var deviceID: AudioDeviceID { get set }
}
extension PlayerModel: DeviceSwitching {}

enum QuickDevices {
    enum Outcome: Equatable { case switched, unchanged, gone }

    /// Switches to a device through the one existing path (setting the model's device, which restarts the stream in place at the same position). A device
    /// that has disappeared since the list was drawn changes nothing.
    @MainActor static func switchTo(_ id: AudioDeviceID, on host: DeviceSwitching) -> Outcome {
        guard host.devices.contains(where: { $0.id == id }) else { return .gone }
        guard host.deviceID != id else { return .unchanged }
        host.deviceID = id
        return .switched
    }

    /// The name cut for a small place: the first words that fit in about 16 characters.
    static func shortName(_ name: String) -> String {
        guard name.count > 16 else { return name }
        var out = ""
        for w in name.split(separator: " ") {
            let next = out.isEmpty ? String(w) : out + " " + w
            if next.count > 16 { break }
            out = next
        }
        return out.isEmpty ? String(name.prefix(15)) + "…" : out
    }

    /// What a device can do, in a line of SF Mono: its rate range and its outputs.
    static func capability(_ d: OutputDeviceInfo) -> String {
        guard let lo = d.rates.min(), let hi = d.rates.max() else { return "\(d.channels) ch" }
        let range = lo == hi ? formatRate(lo) : "\(rateNumber(lo))–\(formatRate(hi))"
        return range + (d.channels > 2 ? " · \(d.channels) ch" : "")
    }
    private static func rateNumber(_ hz: Double) -> String { hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000))" : String(format: "%.1f", hz / 1000) }
}

/// The settings in the panel that are plain on/off switches, with where each one lives.
enum QuickToggle: String, CaseIterable, Identifiable {
    case exclusive, upsampling, equaliser
    var id: String { rawValue }
    var title: String { switch self { case .exclusive: "Bit-perfect, exclusive access"; case .upsampling: "Upsampling"; case .equaliser: "Equaliser and plug-ins" } }
    var detail: String {
        switch self {
        case .exclusive: "The device is yours alone, at the song's own rate"
        case .upsampling: "Resample to a higher rate. Changes the samples"
        case .equaliser: "Parametric EQ and hosted plug-ins"
        }
    }
    @MainActor func isOn(_ m: PlayerModel) -> Bool {
        switch self { case .exclusive: m.exclusive; case .upsampling: m.settings.upsampling.mode != .off; case .equaliser: m.settings.dsp.enabled }
    }
    @MainActor func set(_ on: Bool, _ m: PlayerModel) {
        switch self {
        case .exclusive: m.exclusive = on
        case .upsampling:
            // off remembers the target it had, and on brings it back
            if on { m.settings.upsampling.mode = UpsamplingMode(rawValue: UserDefaults.standard.string(forKey: "aureon.upsampling.last") ?? "") ?? .powerOfTwo }
            else { if m.settings.upsampling.mode != .off { UserDefaults.standard.set(m.settings.upsampling.mode.rawValue, forKey: "aureon.upsampling.last") }; m.settings.upsampling.mode = .off }
        case .equaliser: m.settings.dsp.enabled = on; m.dspModel.draft.enabled = on
        }
    }
}

/// The panel's state: a short message when a switch did not take.
@MainActor
final class QuickPanelModel: ObservableObject {
    @Published var message: String?
    @Published var cursor = 0
    private var watch: Task<Void, Never>?

    /// Switches, and watches the next moment: if the stream reports a new error and the device is still the new one, goes back to the old and says so.
    func choose(_ info: OutputDeviceInfo, on m: PlayerModel) {
        let old = m.selectedDevice
        let errorsBefore = m.status.errors.count
        switch QuickDevices.switchTo(info.id, on: m) {
        case .gone:
            message = "\(info.name) is no longer connected."
            m.refreshDevices()
        case .unchanged: message = nil
        case .switched:
            message = nil
            watch?.cancel()
            watch = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard !Task.isCancelled, m.deviceID == info.id, m.status.errors.count > errorsBefore else { return }
                if let old, m.devices.contains(where: { $0.id == old.id }) { m.deviceID = old.id }
                message = "Could not switch to \(info.name). Staying on \(old?.name ?? "the previous device")."
            }
        }
    }
}

struct QuickPanelView: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var panel = QuickPanelModel()
    @FocusState private var listFocus: Bool

    static let width: CGFloat = 372

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Output")
            deviceList
            if let msg = panel.message {
                Text(msg).font(Typo.sans(11.5)).foregroundStyle(Brand.caution).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 8).transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Button { m.quickPanel = nil; withAnimation(Motion.page) { m.go(.tab(.rooms)) } } label: {
                HStack(spacing: 8) {
                    Text("Multi-room and zones").font(Typo.sans(12, .regular))
                    Image(systemName: "arrow.right").font(Typo.sans(10, .regular))
                    Spacer()
                }
                .foregroundStyle(Brand.accentText).padding(.horizontal, 20).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Multi-room and zones, in Rooms")
            Button { m.showLevelSpeakers() } label: {
                HStack(spacing: 8) {
                    Text("Level speakers").font(Typo.sans(12, .regular))
                    Image(systemName: "arrow.right").font(Typo.sans(10, .regular))
                    Text("balance several outputs").font(Typo.sans(11)).foregroundStyle(Brand.inkTertiary)
                    Spacer()
                }
                .foregroundStyle(Brand.accentText).padding(.horizontal, 20).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Level speakers, in Rooms").accessibilityHint("Opens the speaker set-up, where the outputs are balanced")
            Rule().padding(.vertical, 8)
            sectionTitle("Quick settings")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow(.exclusive)
                row("Volume") { VolumeControl(width: 150, readout: true) }
                row("Between songs") {
                    SegmentedChoice(selection: $m.settings.transition.mode, items: Array(TransitionMode.allCases), label: { $0.title }, singleLine: true)
                }
                row("Levelling") {
                    SegmentedChoice(selection: $m.settings.replayGain.mode, items: Array(ReplayGainMode.allCases), label: { $0 == .loudness ? "R128" : ($0 == .off ? "Off" : $0.title.replacingOccurrences(of: " gain", with: "")) }, singleLine: true)
                }
                toggleRow(.upsampling)
                toggleRow(.equaliser)
                row("Shuffle") {
                    SegmentedChoice(selection: Binding(get: { m.shuffle }, set: { ShuffleChoices.select($0, in: m) }), items: Array(ShuffleMode.allCases), label: { $0 == .smart ? "Smart" : $0.title }, singleLine: true)
                }
                row("Repeat") {
                    SegmentedChoice(selection: $m.repeatMode, items: Array(RepeatMode.allCases), label: { $0 == .off ? "Off" : ($0 == .all ? "All" : "One") }, singleLine: true)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
            Rule()
            Button { m.quickPanel = nil; withAnimation(Motion.page) { m.showSound(.output) } } label: {
                HStack(spacing: 8) {
                    Text("More sound settings").font(Typo.sans(12, .medium)).tracking(0.3)
                    Image(systemName: "arrow.right").font(Typo.sans(10, .regular))
                    Spacer()
                }
                .foregroundStyle(Brand.ink).padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("More sound settings, in Atelier, Sound")
        }
        .padding(.top, 16)
        .frame(width: Self.width)
        .toggleStyle(.rule)
        .glassPopover()
        .foregroundStyle(Brand.ink)
        .onAppear { m.refreshDevices(); panel.cursor = activeIndex; listFocus = true }
        .onKeyPress(.escape) { m.quickPanel = nil; return .handled }
        .animation(Motion.touch, value: panel.message)
    }

    private var activeIndex: Int { m.devices.firstIndex { $0.id == m.deviceID } ?? 0 }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).microLabel().foregroundStyle(Brand.inkTertiary).padding(.horizontal, 20).padding(.bottom, 8).accessibilityAddTraits(.isHeader)
    }

    /// Every device: its name, its rates in SF Mono, a gold dot on the one in use. Up and Down move, Return switches; the wheel scrolls it when it is long.
    private var deviceList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(m.devices.enumerated()), id: \.element.id) { i, d in
                    DeviceRow(device: d, active: d.id == m.deviceID, focused: panel.cursor == i && listFocus) { panel.cursor = i; panel.choose(d, on: m) }
                }
                if m.devices.isEmpty { Text("No output devices found").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).padding(.horizontal, 20).padding(.vertical, 12) }
            }
        }
        .frame(height: min(214, CGFloat(max(1, m.devices.count)) * 40))
        .focusable().focused($listFocus).focusEffectDisabled()
        .onKeyPress(.upArrow) { panel.cursor = max(0, panel.cursor - 1); return .handled }
        .onKeyPress(.downArrow) { panel.cursor = min(max(0, m.devices.count - 1), panel.cursor + 1); return .handled }
        .onKeyPress(.return) { if m.devices.indices.contains(panel.cursor) { panel.choose(m.devices[panel.cursor], on: m) }; return .handled }
        .accessibilityElement(children: .contain).accessibilityLabel("Output devices")
    }

    private func toggleRow(_ t: QuickToggle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { t.isOn(m) }, set: { t.set($0, m) })) { Text(t.title).font(Typo.sans(13)) }
            Text(t.detail).font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary)
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(Typo.sans(13)).frame(width: 96, alignment: .leading)
            control().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct DeviceRow: View {
    let device: OutputDeviceInfo
    let active: Bool
    let focused: Bool
    let choose: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                Circle().fill(active ? Brand.accent : Color.clear).frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(Brand.ink.opacity(active ? 0 : 0.25), lineWidth: Metrics.hairline))
                Text(device.name).font(Typo.sans(13, active ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 8)
                Text(QuickDevices.capability(device)).font(Typo.mono(10, .regular)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.vertical, 8).contentShape(Rectangle())
            .background(Rectangle().fill(Brand.ink.opacity(hover.v || focused ? 0.07 : 0)))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .accessibilityLabel(device.name).accessibilityValue(active ? "in use" : "").accessibilityHint(QuickDevices.capability(device))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The entry button: a small speaker; the current device's short name appears beside it on hover. It opens the panel as a popover.
struct QuickPanelButton: View {
    @EnvironmentObject var m: PlayerModel
    let anchor: QuickPanelAnchor
    @StateObject private var hover = Box(false)

    var body: some View {
        let name = m.selectedDevice.map { QuickDevices.shortName($0.name) } ?? "No device"
        Button { withAnimation(Motion.glide) { m.toggleQuickPanel(anchor) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker").font(Typo.sans(13, .light))
                if hover.v && anchor == .rail { Text(name).font(Typo.mono(10, .regular)).tracking(0.4).lineLimit(1).transition(.opacity) }
            }
            .foregroundStyle(m.quickPanel == anchor || hover.v ? Brand.ink : Brand.inkSecondary)
            .padding(.horizontal, 8).frame(height: anchor == .rail ? 32 : 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .help("Output: \(m.selectedDevice?.name ?? "none"). Quick controls (⌥⌘D)")
        .accessibilityLabel("Quick controls").accessibilityValue(m.selectedDevice?.name ?? "no device")
        .windowPopover(isPresented: Binding(get: { m.quickPanel == anchor }, set: { if !$0, m.quickPanel == anchor { m.quickPanel = nil } }), edge: anchor == .rail ? .bottom : .top) {
            QuickPanelView().environmentObject(m)
        }
    }
}

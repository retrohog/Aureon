import SwiftUI
import AppKit

// MARK: - Shared components

/// View-local state without the @State macro (its compiler plugin ships only with full Xcode).
final class Box<T>: ObservableObject { @Published var v: T; init(_ v: T) { self.v = v } }

struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
            }
            content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.09)))
    }
}

struct Badge: View {
    let text: String; let color: Color
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.22))).foregroundStyle(color)
    }
}

struct Note: View {
    let text: String; var color: Color = .secondary
    var body: some View { Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true) }
}

func formatRate(_ hz: Double) -> String { hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000)) kHz" : String(format: "%.1f kHz", hz / 1000) }

func formatBytes(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }

struct OutputCard: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        Card(title: "Output") {
            Picker("Device", selection: $m.deviceID) { ForEach(m.devices) { Text($0.name).tag($0.id) } }
            if let d = m.selectedDevice { Note(text: "Supported rates: " + d.rates.map { formatRate($0) }.joined(separator: ", ")) }
            Toggle("Follow each track's sample rate", isOn: $m.followRate)
            Toggle("Exclusive access (hog mode)", isOn: $m.exclusive)
            Toggle("Invert polarity (not bit-transparent)", isOn: $m.settings.polarityInverted)
            Divider()
            if m.hasVolume {
                HStack {
                    Image(systemName: "speaker.fill")
                    FluidSlider(value: Binding(get: { Double(m.volume) }, set: { m.setVolume(Float($0)) }), tint: m.volume > 0.85 ? .orange : .white.opacity(0.9), restingHeight: 4, enabled: true,
                                bubble: { "\(Int($0 * 100))%" }, safe: true)
                    Image(systemName: "speaker.wave.3.fill")
                    Text("\(Int(m.volume * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Note(text: m.volume > 0.85 ? "High device volume: check your amplifier before playing." : "Grab the knob to change the volume; a click elsewhere only nudges it. It is applied by the device itself, so the samples stay untouched.",
                     color: m.volume > 0.85 ? .orange : .secondary)
            } else {
                Note(text: "This device does not report a volume Aureon can read or set. Use your DAC, amplifier or the system volume: samples are never scaled here.")
            }
            if !m.status.errors.isEmpty {
                Divider()
                ForEach(m.status.errors, id: \.self) { Note(text: $0, color: .red) }
            }
        }
    }
}


/// A row of buttons of which one is chosen. Made of plain buttons rather than the system's segmented control, which did not react to clicks inside this window.
struct SegmentedChoice<T: Hashable>: View {
    @Binding var selection: T
    let items: [T]
    let label: (T) -> String
    var icon: ((T) -> String)? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { it in
                let on = it == selection
                Button { selection = it } label: {
                    HStack(spacing: 4) {
                        if let icon { Image(systemName: icon(it)).font(.system(size: 11)) }
                        Text(label(it)).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 26).padding(.horizontal, 6)
                    .foregroundStyle(on ? Color.white : Color.primary.opacity(0.85))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Brand.accent : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink.opacity(0.09)))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

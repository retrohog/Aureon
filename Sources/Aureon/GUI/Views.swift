import SwiftUI
import AppKit

// MARK: - Shared components

/// View-local state without the @State macro (its compiler plugin ships only with full Xcode).
final class Box<T>: ObservableObject { @Published var v: T; init(_ v: T) { self.v = v } }

/// A section of a page: a hairline above, a serif heading with its explanation beneath, then the controls. No fill, no frame: the rule is the
/// only structure, and the space around it does the rest.
struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Typo.serif(24, .regular)).tracking(-0.3)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            VStack(alignment: .leading, spacing: 16) { content }.font(Typo.sans(13))
        }
        .padding(.top, 24).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rule() }
    }
}

/// A small status tag: tracked capitals in a hairline frame, tinted by `color`.
struct Badge: View {
    let text: String; let color: Color
    var body: some View {
        Text(text).font(Typo.sans(10, .medium)).tracking(1.2).textCase(.uppercase).padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Slab().strokeBorder(color.opacity(0.7), lineWidth: Metrics.hairline)).foregroundStyle(color)
    }
}

struct Note: View {
    let text: String; var color: Color = .secondary
    var body: some View { Text(text).font(Typo.sans(12.5)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true).lineSpacing(1.5) }
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
                // the volume: a wide line, a mark you can see, and the number
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Volume").microLabel().foregroundStyle(Brand.inkTertiary)
                        Spacer()
                        Text("\(Int((Double(m.volume) * 100).rounded()))%").font(Typo.mono(20, .light)).foregroundStyle(m.volume > 0.85 ? Brand.caution : Brand.ink)
                    }
                    VolumeControl(width: nil, readout: false)
                    Note(text: m.volume > 0.85 ? "High device volume: check your amplifier before playing." : "Drag the mark, scroll over the line, or use the arrow keys; double-click for half. It is applied by the device itself, so the samples stay untouched.",
                         color: m.volume > 0.85 ? Brand.caution : Brand.inkSecondary)
                }
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


/// A row of buttons of which one is chosen, as a hairline-framed strip. The chosen one is set in the ink with a champagne line under it; the rest are
/// quiet. Made of plain buttons rather than the system's segmented control, which did not react to clicks inside this window.
struct SegmentedChoice<T: Hashable>: View {
    @Binding var selection: T
    let items: [T]
    let label: (T) -> String
    var icon: ((T) -> String)? = nil
    /// Keep every label on one line (shrinking it a little if it must): for narrow controls.
    var singleLine = false
    /// Choices that are shown but cannot be picked.
    var isDisabled: (T) -> Bool = { _ in false }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { it in
                let on = it == selection
                Button { selection = it } label: {
                    HStack(spacing: 4) {
                        if let icon { Image(systemName: icon(it)).font(Typo.sans(11, .light)) }
                        Text(label(it)).font(Typo.sans(12, on ? .medium : .regular)).tracking(0.3).lineLimit(singleLine ? 1 : 2).minimumScaleFactor(singleLine ? 0.7 : 1).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32).padding(.horizontal, 8)
                    .foregroundStyle(on ? Brand.ink : Brand.inkSecondary)
                    .background(Rectangle().fill(Brand.ink.opacity(on ? 0.06 : 0)))
                    .overlay(alignment: .bottom) { Rectangle().fill(Brand.gradient).frame(height: 1).opacity(on ? 1 : 0) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled(it)).opacity(isDisabled(it) ? 0.4 : 1)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).strokeBorder(Brand.ink.opacity(0.28), lineWidth: Metrics.hairline))
        .animation(Motion.touch, value: selection)
    }
}

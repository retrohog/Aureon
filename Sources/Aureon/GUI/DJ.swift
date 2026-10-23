import SwiftUI
import Combine
import CoreAudio

// MARK: - Controls

/// What a knob's value means, so its readout can say it in the right words.
enum KnobKind {
    case db                    // plain gain in dB
    case eq                    // a DJ EQ band: dB, with the bottom of the range being a full cut
    case percent               // 0…1 shown as a percentage
    case filter                // -1 low-pass … 0 off … +1 high-pass
    case level                 // 1 = unity, shown as a percentage of it
    case blend                 // headphone cue / master mix

    func text(_ v: Double, range: ClosedRange<Double>) -> String {
        switch self {
        case .db: return String(format: "%+.1f dB", v)
        case .eq: return v <= range.lowerBound + 0.5 ? "KILL" : String(format: "%+.1f dB", v)
        case .percent, .level: return "\(Int((v * 100).rounded())) %"
        case .filter: return abs(v) < 0.02 ? "OFF" : (v < 0 ? "LP " : "HP ") + "\(Int((abs(v) * 100).rounded())) %"
        case .blend: return v < 0.02 ? "CUE" : v > 0.98 ? "MASTER" : "\(Int((v * 100).rounded())) % MST"
        }
    }
}

/// A rotary control. Under the pointer it grows and shows its value underneath, so the setting is easy to see and to change in small steps:
/// drag up or down (hold ⇧ for fine steps), scroll, or double-click to return to the centre position.
struct Knob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var tint: Color = Brand.accent
    var size: CGFloat = 38
    var reset = 0.0
    var kind: KnobKind = .db
    @StateObject private var drag = Box<(start: Double, fine: Bool)?>(nil)
    @StateObject private var hover = Box(false)

    private var span: Double { range.upperBound - range.lowerBound }
    private var fraction: Double { max(0, min(1, (value - range.lowerBound) / span)) }
    private var zero: Double { max(0, min(1, (reset - range.lowerBound) / span)) }
    private var grown: Bool { hover.v || drag.v != nil }

    var body: some View {
        let scale: CGFloat = grown ? 1.75 : 1
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(Color.black.opacity(grown ? 0.6 : 0.35))
                Circle().strokeBorder(grown ? tint.opacity(0.7) : Brand.ink.opacity(0.12), lineWidth: grown ? 1.2 : 0.8)
                // the whole travel, faint, and the part from the centre detent to the value, bright
                Circle().trim(from: 0.125, to: 0.875).stroke(Brand.ink.opacity(0.14), style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).rotationEffect(.degrees(90)).padding(3)
                Circle().trim(from: 0.125 + 0.75 * min(zero, fraction), to: 0.125 + 0.75 * max(zero, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(90)).padding(3)
                Slab().fill(.white).frame(width: 2.5, height: size * 0.3).offset(y: -size * 0.27).rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .animation(Motion.glide, value: grown)
            .animation(.interactiveSpring(response: 0.1, dampingFraction: 0.9), value: value)
            .overlay(alignment: .bottom) {
                Text(kind.text(value, range: range)).font(Typo.mono(11, .bold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Slab().fill(.black.opacity(0.72))).foregroundStyle(.white).fixedSize()
                    .opacity(grown ? 1 : 0).offset(y: grown ? size * 0.375 + 14 : size * 0.2).allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.14), value: grown)
            }
            Text(label).microLabel().foregroundStyle(Brand.inkSecondary).opacity(grown ? 0.0 : 1)
        }
        .frame(height: nil)
        .zIndex(grown ? 10 : 0)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { d in
            if drag.v == nil { drag.v = (value, NSEvent.modifierFlags.contains(.shift)) }
            guard let st = drag.v else { return }
            let travel: Double = (NSEvent.modifierFlags.contains(.shift) ? 700 : 190)
            var v = st.start - Double(d.translation.height) / travel * span
            v = max(range.lowerBound, min(range.upperBound, v))
            if abs(v - reset) < span * 0.015 && reset > range.lowerBound && reset < range.upperBound { v = reset }          // a soft stop at the centre
            value = v
        }.onEnded { _ in drag.v = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { withAnimation(.easeOut(duration: 0.2)) { value = reset } })
        .onHover { hover.v = $0 }
        .scrollAdjustable(hovering: hover.v) { n in value = ScrollStep.apply(value: value, notches: n, range: range, perNotch: 0.02); return true }
        .help("\(label): drag, scroll or double-click to reset")
        .accessibilityElement().accessibilityLabel(Text(label)).accessibilityValue(Text(kind.text(value, range: range)))
        .accessibilityAdjustableAction { dir in value = max(range.lowerBound, min(range.upperBound, value + (dir == .increment ? 1 : -1) * span * 0.02)) }
    }
}

/// A thin level bar for a deck's output.
struct LevelBar: View {
    let value: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(max(Double(value), 1e-5)), f = max(0, min(1, (db + 48) / 48))
            ZStack(alignment: .bottom) {
                Slab().fill(Brand.ink.opacity(0.08))
                Slab().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .bottom, endPoint: .top)).frame(height: g.size.height * CGFloat(f))
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * CGFloat(f)) }
            }
        }.frame(width: 6)
    }
}


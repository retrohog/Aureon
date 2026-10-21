import SwiftUI
import Combine
import CoreAudio

// MARK: - Controls

/// A rotary control: drag up/down, double-click to centre.
struct Knob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var tint: Color = Brand.accent
    var size: CGFloat = 38
    var reset = 0.0
    var unit = "dB"
    @StateObject private var drag = Box<Double?>(nil)
    @StateObject private var hover = Box(false)

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    private var zero: Double { (reset - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(.black.opacity(0.35))
                Circle().strokeBorder(Brand.ink.opacity(0.12), lineWidth: 0.8)
                // arc from the centre detent to the value
                Circle().trim(from: 0.125 + 0.75 * min(zero, fraction), to: 0.125 + 0.75 * max(zero, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(90)).padding(3)
                Capsule().fill(.white).frame(width: 2.5, height: size * 0.3).offset(y: -size * 0.27).rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: size, height: size)
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                if drag.v == nil { drag.v = value }
                let span = range.upperBound - range.lowerBound
                value = max(range.lowerBound, min(range.upperBound, (drag.v ?? value) - Double(d.translation.height) / 150 * span))
            }.onEnded { _ in drag.v = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = reset })
            .onHover { hover.v = $0 }
            .scrollAdjustable(hovering: hover.v) { n in value = ScrollStep.apply(value: value, notches: n, range: range, perNotch: 0.03); return true }
            Text(label).microLabel().foregroundStyle(.secondary)
        }
        .accessibilityElement().accessibilityLabel(Text(label)).accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { dir in value = max(range.lowerBound, min(range.upperBound, value + (dir == .increment ? 1 : -1))) }
    }
}

/// A thin level bar for a deck's output.
struct LevelBar: View {
    let value: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(max(Double(value), 1e-5)), f = max(0, min(1, (db + 48) / 48))
            ZStack(alignment: .bottom) {
                Capsule().fill(Brand.ink.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .bottom, endPoint: .top)).frame(height: g.size.height * CGFloat(f))
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * CGFloat(f)) }
            }
        }.frame(width: 6)
    }
}


import SwiftUI

// The transport symbols, drawn as fine strokes instead of filled system symbols: one line weight, round joins, nothing else.

struct TransportGlyphShape: Shape {
    enum Kind { case play, pause, previous, next }
    let kind: Kind

    func path(in r: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        switch kind {
        case .play:
            p.move(to: pt(0.24, 0.10)); p.addLine(to: pt(0.90, 0.50)); p.addLine(to: pt(0.24, 0.90)); p.closeSubpath()
        case .pause:
            p.move(to: pt(0.30, 0.12)); p.addLine(to: pt(0.30, 0.88))
            p.move(to: pt(0.70, 0.12)); p.addLine(to: pt(0.70, 0.88))
        case .previous:
            p.move(to: pt(0.12, 0.14)); p.addLine(to: pt(0.12, 0.86))
            p.move(to: pt(0.90, 0.14)); p.addLine(to: pt(0.30, 0.50)); p.addLine(to: pt(0.90, 0.86)); p.closeSubpath()
        case .next:
            p.move(to: pt(0.88, 0.14)); p.addLine(to: pt(0.88, 0.86))
            p.move(to: pt(0.10, 0.14)); p.addLine(to: pt(0.70, 0.50)); p.addLine(to: pt(0.10, 0.86)); p.closeSubpath()
        }
        return p
    }
}

/// A transport symbol in the current foreground style.
struct TransportGlyph: View {
    let kind: TransportGlyphShape.Kind
    var size: CGFloat = 14
    var body: some View {
        TransportGlyphShape(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: size >= 20 ? 1.5 : 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The play key: a square with a champagne hairline, the glyph in ink; the accent washes in under the pointer.
struct PlayKeyStyle: ButtonStyle {
    var size: CGFloat = 48
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, size: size) }
    private struct Inner: View {
        let configuration: Configuration
        let size: CGFloat
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(Brand.ink.opacity(enabled ? 1 : 0.35))
                .frame(width: size, height: size)
                .background(Rectangle().fill(Brand.accent.opacity(configuration.isPressed ? 0.22 : (hover.v && enabled ? 0.12 : 0))))
                .overlay(Rectangle().strokeBorder(Brand.coachline.opacity(enabled ? 1 : 0.4), lineWidth: Metrics.hairline))
                .contentShape(Rectangle())
                .animation(Motion.touch, value: hover.v)
                .animation(Motion.touch, value: configuration.isPressed)
                .onHover { hover.v = $0 }
        }
    }
}

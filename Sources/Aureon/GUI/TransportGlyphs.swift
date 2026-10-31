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
        // heavy solid glyphs with rounded corners: the shape is filled and outlined in the same colour, so every corner and bar end is round
        TransportGlyphShape(kind: kind)
            .fill()
            .overlay(TransportGlyphShape(kind: kind).stroke(style: StrokeStyle(lineWidth: TransportMetrics.stroke(size), lineCap: .round, lineJoin: .round)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Sizes of the hairline transport: fine outline glyphs with no plate. Every hit area is at least 44 points.
enum TransportMetrics {
    static let minHit: CGFloat = 44
    /// Line weight: about 1.4 in a 24-point box, a little more for the large play glyph so it does not look thin next to the others.
    static func stroke(_ glyph: CGFloat) -> CGFloat { max(2.4, glyph * 0.15) }
    /// Play / pause: a 52-point glyph in a 72-point hit area, both scaled by `k` (never below the minimum hit area).
    static func play(_ k: CGFloat = 1) -> (glyph: CGFloat, hit: CGFloat) { (52 * k, max(minHit, 72 * k)) }
    /// Previous / next: a 28-point glyph in a 52-point hit area.
    static func skip(_ k: CGFloat = 1) -> (glyph: CGFloat, hit: CGFloat) { (28 * k, max(minHit, 52 * k)) }
    /// Shuffle / repeat: 22 points, in a 44-point hit area.
    static let modeGlyph: CGFloat = 22
}

/// The transport key: a heavy solid glyph alone, in the theme's ink; gold (the theme's accent) under the pointer; a slight press; a focus ring for the keyboard.
/// No plate, no container, no gloss.
struct HairlineKeyStyle: ButtonStyle {
    var hit: CGFloat
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, hit: max(hit, TransportMetrics.minHit)) }
    private struct Inner: View {
        let configuration: Configuration
        let hit: CGFloat
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(hover.v && enabled ? Brand.accentText : Brand.ink.opacity(enabled ? 1 : 0.3))
                .frame(width: hit, height: hit)
                .overlay(Circle().strokeBorder(Brand.accentText, lineWidth: 1.5).padding(2).opacity(focused ? 1 : 0))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(Motion.touch, value: hover.v)
                .animation(Motion.touch, value: configuration.isPressed)
                .onHover { hover.v = $0 }
        }
    }
}

/// The play key: a filled accent circle with the glyph in the label colour; it brightens under the pointer.
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
                .foregroundStyle(Brand.onAccent)
                .frame(width: size, height: size)
                .background(Circle().fill(Brand.accent))
                .brightness(configuration.isPressed ? -0.08 : (hover.v && enabled ? 0.06 : 0))
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(hover.v && enabled && !configuration.isPressed ? 1.04 : 1)
                .contentShape(Circle())
                .animation(Motion.touch, value: hover.v)
                .animation(Motion.touch, value: configuration.isPressed)
                .onHover { hover.v = $0 }
        }
    }
}

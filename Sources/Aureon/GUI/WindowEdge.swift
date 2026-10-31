import SwiftUI

// The soft edge around the whole window: a very faint shade that falls in from the rim and fades to nothing. There is no line anywhere, no stroke and
// no highlight, so it can only be read as a little depth. One static layer on the root view: it is drawn once (and again only when the window is resized
// or the setting or the theme changes), never per frame, and it takes no clicks, scrolls or keys.

enum WindowEdgeStrength: String, Codable, CaseIterable, Identifiable {
    case off, subtle, strong
    var id: String { rawValue }
    var title: String { switch self { case .off: "Off"; case .subtle: "Subtle"; case .strong: "Strong" } }

    /// Opacity of the shade at the very rim, on a dark theme and on a light one. Low enough that the rim never reads as a dark line.
    var shade: (dark: Double, light: Double) { switch self { case .off: (0, 0); case .subtle: (0.10, 0.04); case .strong: (0.20, 0.08) } }
    /// How far the shade reaches in, at most: wide, so the fall-off is gradual (limited to a share of the smaller side, so a small window is not covered).
    var reach: CGFloat { switch self { case .off: 0; case .subtle: 72; case .strong: 110 } }

    /// Opacity of the shade `t` of the way in (0 at the rim, 1 where it has faded out): an eased curve with no step and no slope at the end.
    static func fade(_ t: Double) -> Double { let x = min(1, max(0, 1 - t)); return x * x * x }
}

struct WindowEdgeOverlay: View {
    let strength: WindowEdgeStrength
    let light: Bool

    /// The corner radius of the window itself.
    static var cornerRadius: CGFloat { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 26 : 10 }

    private func gradient(_ alpha: Double, _ colour: Color, from: UnitPoint, to: UnitPoint) -> LinearGradient {
        LinearGradient(stops: (0...16).map { i in
            let t = Double(i) / 16
            return Gradient.Stop(color: colour.opacity(alpha * WindowEdgeStrength.fade(t)), location: t)
        }, startPoint: from, endPoint: to)
    }

    var body: some View {
        if strength != .off {
            GeometryReader { g in
                let reach = min(strength.reach, min(g.size.width, g.size.height) * 0.16)
                let alpha = light ? strength.shade.light : strength.shade.dark
                let colour = light ? Color(white: 0.1) : Color.black
                ZStack {
                    Rectangle().fill(gradient(alpha, colour, from: .top, to: .bottom)).frame(height: reach).frame(maxHeight: .infinity, alignment: .top)
                    Rectangle().fill(gradient(alpha, colour, from: .bottom, to: .top)).frame(height: reach).frame(maxHeight: .infinity, alignment: .bottom)
                    Rectangle().fill(gradient(alpha, colour, from: .leading, to: .trailing)).frame(width: reach).frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(gradient(alpha, colour, from: .trailing, to: .leading)).frame(width: reach).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .drawingGroup()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

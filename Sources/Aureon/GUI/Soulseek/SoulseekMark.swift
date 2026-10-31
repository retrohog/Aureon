import SwiftUI

/// Aureon's own mark for the Soulseek page: two nodes joined by a rounded S-shaped wave, for sharing between two people. A template glyph: it takes the
/// colour of the control around it, so it follows hover, selection and every theme.
struct SoulseekMarkShape: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x / 24, y: r.minY + r.height * y / 24) }
        var p = Path()
        p.move(to: pt(6.5, 17.5))
        p.addCurve(to: pt(12, 12), control1: pt(6.5, 13.5), control2: pt(9, 12))
        p.addCurve(to: pt(17.5, 6.5), control1: pt(15, 12), control2: pt(17.5, 10.5))
        return p
    }
}

struct SoulseekMark: View {
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            SoulseekMarkShape().stroke(style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))
            Circle().stroke(lineWidth: size * 0.075).frame(width: size * 0.2, height: size * 0.2).position(x: size * 6.5 / 24, y: size * 18.5 / 24)
            Circle().stroke(lineWidth: size * 0.075).frame(width: size * 0.2, height: size * 0.2).position(x: size * 17.5 / 24, y: size * 5.5 / 24)
            Circle().fill().frame(width: size * 0.06, height: size * 0.06).position(x: size * 12 / 24, y: size * 12 / 24)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

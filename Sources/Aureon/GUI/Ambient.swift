import SwiftUI
import AppKit

/// A slowly drifting mesh gradient in the colours of the current cover, with a blurred copy of the cover mixed in.
struct AmbientBackground: View {
    let palette: ArtPalette
    var image: NSImage?
    var animated = true
    var intensity: Double = 1

    private static let base: [SIMD2<Float>] = [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.5, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]]

    private func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        guard animated else { return Self.base }
        return Self.base.enumerated().map { i, p in
            // corners stay put; edge midpoints slide along their edge; the centre wanders
            let a = Float(t * 0.11) + Float(i) * 1.7, b = Float(t * 0.09) + Float(i) * 2.3
            switch i {
            case 1, 7: return [p.x + 0.12 * sin(a), p.y]
            case 3, 5: return [p.x, p.y + 0.12 * sin(b)]
            case 4: return [p.x + 0.1 * sin(a), p.y + 0.1 * cos(b)]
            default: return p
            }
        }
    }

    var body: some View {
        ZStack {
            Color(white: 0.06)
            TimelineView(.animation(minimumInterval: animated ? 1.0 / 24 : 3600, paused: !animated)) { tl in
                MeshGradient(width: 3, height: 3, points: points(tl.date.timeIntervalSinceReferenceDate), colors: palette.grid.map(\.color), smoothsColors: true)
            }
            .opacity(intensity)
            if let image {
                // sized by the available space, never by the picture's own pixel size
                GeometryReader { g in
                    Image(nsImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                        .blur(radius: 90).saturation(1.3).opacity(0.28 * intensity).blendMode(.plusLighter)
                }
            }
            // legibility: darken towards the bottom, soften the corners
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 200, endRadius: 900)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

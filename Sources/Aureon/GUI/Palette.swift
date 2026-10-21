import SwiftUI
import AppKit

struct RGB: Equatable, Sendable {
    var r: Double, g: Double, b: Double
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    /// hue, saturation, brightness in 0…1
    var hsb: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    init(h: Double, s: Double, v: Double) {
        let c = v * s, x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h * 6) % 6 { case 0: (r, g, b) = (c, x, 0); case 1: (r, g, b) = (x, c, 0); case 2: (r, g, b) = (0, c, x); case 3: (r, g, b) = (0, x, c); case 4: (r, g, b) = (x, 0, c); default: (r, g, b) = (c, 0, x) }
        self.init(r + m, g + m, b + m)
    }
}

/// The colours a cover lends to the interface: a 3×3 grid for a mesh gradient and one accent for controls.
struct ArtPalette: Equatable, Sendable {
    var grid: [RGB]          // row-major, 9 entries
    var accent: RGB

    static let neutral = ArtPalette(grid: Array(repeating: RGB(0.16, 0.17, 0.2), count: 9), accent: RGB(0.62, 0.68, 0.95))

    /// Samples the image on a 3×3 grid and tunes each colour for use behind white text: saturated enough to feel like the cover,
    /// dark enough to keep text legible.
    static func extract(from image: CGImage) -> ArtPalette {
        let n = 48
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .neutral }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return .neutral }
        var cells: [RGB] = []
        let step = n / 3
        for row in 0..<3 {
            for col in 0..<3 {
                var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
                for y in (row * step)..<((row + 1) * step) {
                    for x in (col * step)..<((col + 1) * step) {
                        // a bitmap context stores its top row first, whatever the drawing coordinate system
                        let o = (y * n + x) * 4
                        let c = RGB(Double(p[o]) / 255, Double(p[o + 1]) / 255, Double(p[o + 2]) / 255)
                        let w = 0.15 + c.hsb.s            // vivid pixels count more than grey ones
                        sr += c.r * w; sg += c.g * w; sb += c.b * w; sw += w
                    }
                }
                cells.append(RGB(sr / sw, sg / sw, sb / sw))
            }
        }
        let grid = cells.map(tuned)
        // accent: the most colourful cell, lifted so it reads on a dark background
        let best = cells.max { vibrancy($0) < vibrancy($1) } ?? cells[0]
        let h = best.hsb
        let accent = RGB(h: h.h, s: h.s < 0.12 ? h.s : min(0.85, max(0.45, h.s)), v: max(0.82, h.v))
        return ArtPalette(grid: grid, accent: accent)
    }

    private static func vibrancy(_ c: RGB) -> Double { let h = c.hsb; return h.s * (0.35 + h.v) }

    private static func tuned(_ c: RGB) -> RGB {
        let h = c.hsb
        let s = h.s < 0.08 ? h.s : min(1, max(h.s * 1.25, 0.3))
        return RGB(h: h.h, s: s, v: min(0.78, max(0.24, h.v)))
    }

    /// Artwork-less albums still get a stable, pleasant identity derived from their name.
    static func fallback(seed: String) -> ArtPalette {
        var hash: UInt64 = 1469598103934665603
        for b in seed.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let base = Double(hash % 360) / 360
        func at(_ i: Int) -> RGB {
            let k = Double((hash >> (8 + UInt64(i) * 3)) % 100) / 100
            return RGB(h: (base + 0.12 * (Double(i % 3) - 1) + 0.05 * k).truncatingRemainder(dividingBy: 1), s: 0.55 + 0.25 * k, v: 0.32 + 0.28 * Double((i * 5) % 9) / 8)
        }
        return ArtPalette(grid: (0..<9).map(at), accent: RGB(h: base, s: 0.5, v: 0.95))
    }
}

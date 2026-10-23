import SwiftUI
import AppKit

// Layout, shape and contrast tokens of the interface. Spacing sits on an 8-point grid (4 for the tight steps), rules are hairlines, and corners
// are square-ish: nothing is rounder than 4 points, and there are no pills.

enum Metrics {
    /// The grid unit. Layout values are multiples of it (or of half of it).
    static let unit: CGFloat = 8
    static func grid(_ n: CGFloat) -> CGFloat { n * unit }
    /// A hairline: half a point, which is one device pixel on a Retina display.
    static let hairline: CGFloat = 0.5

    /// Any corner radius that is asked for, brought into the 2…4 point range (tiny radii on bars and ticks stay as they are).
    static func radius(_ r: CGFloat) -> CGFloat {
        if r < 2.5 { return r }
        if r <= 9 { return 2 }
        if r <= 16 { return 3 }
        return 4
    }
    static let controlRadius: CGFloat = 3
    static let tagRadius: CGFloat = 2

    /// The nearest step of the 4-point grid (4, 8, 12, 16, …); used for values that came from the old, free-hand layout.
    static func snap4(_ v: CGFloat) -> CGFloat { v <= 0 ? 0 : max(4, (v / 4).rounded() * 4) }
}

/// A rectangle with the interface's smallest radius, standing in for capsules: tracks, tags, indicator bars.
struct Slab: InsettableShape {
    var radius: CGFloat = Metrics.tagRadius
    var inset: CGFloat = 0
    init() {}
    init(style: RoundedCornerStyle) {}
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return Path(roundedRect: r, cornerRadius: min(radius, min(r.width, r.height) / 2), style: .continuous)
    }
    func inset(by amount: CGFloat) -> Slab { var s = self; s.inset += amount; return s }
}

/// A hairline rule across the available width (or height).
struct Rule: View {
    var vertical = false
    var strength = 1.0
    var body: some View {
        Rectangle().fill(Brand.rule.opacity(strength))
            .frame(width: vertical ? Metrics.hairline : nil, height: vertical ? nil : Metrics.hairline)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A hairline frame with a square-ish corner, in place of a card.
    func ruled(radius: CGFloat = Metrics.controlRadius, strength: Double = 1) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Brand.rule.opacity(strength), lineWidth: Metrics.hairline))
    }
}

// MARK: - Contrast

/// WCAG 2 relative luminance and contrast ratio, on sRGB colours.
enum WCAG {
    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func luminance(_ c: RGB) -> Double { 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b) }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    /// `top` at `alpha` over an opaque `bottom`, blended the way the window server blends (in sRGB values).
    static func over(_ top: RGB, alpha: Double, _ bottom: RGB) -> RGB {
        RGB(top.r * alpha + bottom.r * (1 - alpha), top.g * alpha + bottom.g * (1 - alpha), top.b * alpha + bottom.b * (1 - alpha))
    }

    /// `c` moved towards white (on a dark `background`) or black (on a light one), in small steps of lightness, until it reaches `minimum`:1.
    /// The hue and most of the saturation are kept; if even the extreme is not enough the extreme is returned.
    static func fit(_ c: RGB, against background: RGB, minimum: Double) -> RGB {
        if contrast(c, background) >= minimum { return c }
        let towardWhite = luminance(background) < 0.4
        var t = 0.0
        while t < 1 {
            t += 0.02
            let s = towardWhite ? RGB(c.r + (1 - c.r) * t, c.g + (1 - c.g) * t, c.b + (1 - c.b) * t) : RGB(c.r * (1 - t), c.g * (1 - t), c.b * (1 - t))
            if contrast(s, background) >= minimum { return s }
        }
        return towardWhite ? RGB(1, 1, 1) : RGB(0, 0, 0)
    }

    /// Black or white, whichever reads better on `background`: the colour of a label on a solid accent.
    static func onColor(_ background: RGB) -> RGB { contrast(RGB(0, 0, 0), background) >= contrast(RGB(1, 1, 1), background) ? RGB(0.04, 0.04, 0.04) : RGB(1, 1, 1) }
}

extension RGB {
    /// This colour mixed with `other`, `t` of the way (0 = this, 1 = other), in sRGB values.
    func mixed(with other: RGB, _ t: Double) -> RGB { RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t) }

    /// The same hue with its saturation and brightness replaced.
    func with(saturation s: Double? = nil, brightness v: Double? = nil) -> RGB { let h = hsb; return RGB(h: h.h, s: s ?? h.s, v: v ?? h.v) }

    /// The same colour with the hue turned by `delta` (a fraction of the colour wheel).
    func hueShifted(_ delta: Double) -> RGB { let h = hsb; var n = (h.h + delta).truncatingRemainder(dividingBy: 1); if n < 0 { n += 1 }; return RGB(h: n, s: h.s, v: h.v) }
}

// MARK: - Motion

/// Slow, damped, unhurried: every transition is an ease of 0.2 to 0.45 s with no overshoot. SwiftUI drives them at display rate.
enum Motion {
    /// The default ease for changes of state (hover, selection, a control moving): quick enough to feel direct, long enough to feel calm.
    static let glide = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.32)
    /// Hover and press feedback.
    static let touch = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2)
    /// A page changing: a calm cross-fade.
    static let page = Animation.timingCurve(0.3, 0.1, 0.3, 1, duration: 0.38)
    /// Whole-page moves: Now Playing opening and closing, panels sliding in.
    static let carpet = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.45)
    /// Colours into colours when the track (or the backdrop) changes.
    static let backdrop = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.8)
}

import Foundation

/// OKLab / OKLCH (Björn Ottosson's perceptual colour space), for moving the lightness of a colour without moving its hue or its colourfulness.
/// `L` is lightness 0…1, `C` chroma, `h` hue in radians.
enum OKLab {
    struct LCh: Equatable { var L: Double; var C: Double; var h: Double }

    private static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func fromLinear(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    static func lch(_ c: RGB) -> LCh {
        let r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return LCh(L: L, C: (a * a + bb * bb).squareRoot(), h: atan2(bb, a))
    }

    /// The colour for these values, brought into the sRGB gamut by lowering the chroma (the lightness and hue are kept).
    static func rgb(_ x: LCh) -> RGB {
        var chroma = x.C
        for _ in 0..<24 {
            if let c = convert(LCh(L: x.L, C: chroma, h: x.h)) { return c }
            chroma *= 0.9
        }
        return convert(LCh(L: x.L, C: 0, h: x.h), clamp: true) ?? RGB(0, 0, 0)
    }

    private static func convert(_ x: LCh, clamp: Bool = false) -> RGB? {
        let a = x.C * cos(x.h), b = x.C * sin(x.h)
        let l = pow(x.L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(x.L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(x.L - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        let eps = 1e-6
        if !clamp, [r, g, bl].contains(where: { $0 < -eps || $0 > 1 + eps }) { return nil }
        func cv(_ v: Double) -> Double { min(1, max(0, fromLinear(min(1, max(0, v))))) }
        return RGB(cv(r), cv(g), cv(bl))
    }

    /// The colour with its lightness moved by `delta` (in OKLab L units).
    static func lightened(_ c: RGB, by delta: Double) -> RGB {
        var x = lch(c)
        x.L = min(1, max(0, x.L + delta))
        return rgb(x)
    }
}

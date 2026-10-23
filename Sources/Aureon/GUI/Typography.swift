import SwiftUI

// The type system, in one place. Three voices, all macOS built-ins reached through `Font.system(design:)`, so there is nothing to license or download:
//
//   New York (the system serif)   titles, album and artist names, section headings: light and regular, large, with air around them
//   SF Pro, light and regular     everything else, at tight tracking; emphasis is one step (regular → medium), never bold
//   SF Mono, tabular figures      every technical readout: sample rate, bit depth, time, dB, BPM, counts
//
// Micro-labels are small, upper-case and widely tracked. Call sites use the voices below (`Typo.sans(13, .medium)`, `Typo.mono(11)`,
// `Typo.serif(20)`) or the `typo(_:)` roles, never `.system(size:)` directly.

enum Typo {
    // MARK: voices

    /// The sizes the interface uses. Odd sizes asked for are rounded to the nearest step.
    static let scale: [CGFloat] = [9, 10, 11, 12, 13, 15, 17, 20, 24, 28, 34, 40, 56]
    static func snap(_ size: CGFloat) -> CGFloat { scale.min { abs($0 - size) < abs($1 - size) } ?? size }

    /// Serif: light from 20 points up, regular below, medium only where a small serif has to stand out.
    static func serifWeight(_ w: Font.Weight, size: CGFloat) -> Font.Weight {
        switch w {
        case .black, .heavy, .bold, .semibold, .medium: return size >= 20 ? .regular : .medium
        case .ultraLight, .thin, .light: return .light
        default: return size >= 20 ? .light : .regular
        }
    }
    /// Sans: regular and medium; bold and semibold both mean "medium". Light only when asked for (large symbols).
    static func sansWeight(_ w: Font.Weight) -> Font.Weight {
        switch w {
        case .black, .heavy, .bold, .semibold: return .medium
        case .ultraLight, .thin: return .light
        default: return w
        }
    }
    static func monoWeight(_ w: Font.Weight, size: CGFloat) -> Font.Weight {
        switch w {
        case .black, .heavy, .bold, .semibold: return .medium
        case .ultraLight, .thin: return .light
        default: return size >= 20 ? .light : w
        }
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { let s = snap(size); return .system(size: s, weight: serifWeight(weight, size: s), design: .serif) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: snap(size), weight: sansWeight(weight), design: .default) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { let s = snap(size); return .system(size: s, weight: monoWeight(weight, size: s), design: .monospaced).monospacedDigit() }

    // MARK: roles

    static func title(_ size: CGFloat = 40) -> Font { serif(size, .light) }
    static let artist = serif(20, .regular)
    static let album = serif(15, .regular).italic()
    static let kicker = sans(10, .regular)
    static let composer = serif(15, .regular).italic()
    static let readout = mono(11, .regular)

    // The system text styles, mapped onto the voices (`.font(.caption)` became `.font(Typo.caption)`).
    static let largeTitle = serif(40, .light)
    static let t1 = serif(28, .light)
    static let t2 = serif(24, .light)
    static let t3 = serif(17, .regular)
    static let headline = sans(13, .medium)
    static let body = sans(13)
    static let callout = sans(13)
    static let subheadline = sans(12)
    static let footnote = sans(11)
    static let caption = sans(11)
    static let caption2 = sans(10)

    // MARK: tracking

    /// Tight tracking for running text; micro-labels open up.
    static let bodyTracking: CGFloat = -0.1
    static let microTracking: CGFloat = 2.0
}

/// A font with the tracking and case that belong to it.
struct TypoStyle {
    let font: Font
    var tracking: CGFloat = Typo.bodyTracking
    var uppercase = false

    static let display = TypoStyle(font: Typo.serif(56, .light), tracking: -1.2)
    static let pageTitle = TypoStyle(font: Typo.serif(40, .light), tracking: -0.8)
    static let heading = TypoStyle(font: Typo.serif(20, .regular), tracking: -0.2)
    static let itemTitle = TypoStyle(font: Typo.sans(13, .medium))
    static let body = TypoStyle(font: Typo.sans(13))
    static let secondary = TypoStyle(font: Typo.sans(12))
    static let label = TypoStyle(font: Typo.sans(10, .regular), tracking: Typo.microTracking, uppercase: true)
    static let labelMono = TypoStyle(font: Typo.mono(10, .regular), tracking: 1.4, uppercase: true)
    static let readout = TypoStyle(font: Typo.mono(11, .regular), tracking: 0)
}

extension View {
    func typo(_ s: TypoStyle) -> some View {
        font(s.font).tracking(s.tracking).textCase(s.uppercase ? .uppercase : nil)
    }

    /// Small, upper-case, widely tracked sans: section headings, kickers and column titles.
    func microLabel() -> some View { typo(.label) }

    /// The same label in SF Mono, for labels that are themselves technical ("24-BIT", "ON AIR").
    func microMono() -> some View { typo(.labelMono) }

    func kicker() -> some View { typo(.label) }
}

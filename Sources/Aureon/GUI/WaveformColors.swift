import SwiftUI

// The colours of the waveform, chosen so it can always be read: the played part against the background, and the played part against the part still to play.
// The background under it is not one colour: the page's own, the Album backdrop at its strongest, the glass of the player bar. The colours are fitted against
// the hardest of those, with a computed guard, so no theme, backdrop mode or intensity can leave the waveform faint.

enum WaveformColors {
    struct Set: Equatable {
        var played: RGB
        var played2: RGB
        var unplayed: RGB
    }

    /// WCAG asks 3:1 for graphics; the waveform aims for 4.5:1.
    static let playedAgainstBackground = 4.5
    static let playedAgainstUnplayed = 3.0
    /// The part still to play must still be seen.
    static let unplayedAgainstBackground = 1.3

    /// The backgrounds the waveform can sit on in `theme`: its page and bar colours, the Album backdrop at each intensity (on a page and on the stage, up to its allowance),
    /// and the glass of the player bar and of pop-ups at their worst.
    static func surfaces(for theme: Theme) -> [RGB] {
        var out = [theme.canvasRGB, theme.sidebarRGB, theme.backdropLimitRGB]
        for level in BackdropIntensity.allCases {
            for share in [1.0, 0.85] { out.append(theme.canvasRGB.mixed(with: theme.backdropLimitRGB, min(1, level.reach * share))) }
        }
        out.append(GlassPolicy.worstCaseSurface(theme))
        out.append(GlassPolicy.worstCaseSurface(theme, scrim: GlassPolicy.popoverScrim))
        return out
    }

    /// The colours for `theme`: the accent gradient's two ends pushed (never replaced) to the contrast, and a quiet colour for the unplayed part.
    static func resolve(_ theme: Theme) -> Set {
        let surfaces = surfaces(for: theme)
        func contrastAll(_ c: RGB) -> Double { surfaces.map { WCAG.contrast(c, $0) }.min() ?? 21 }
        var target = playedAgainstBackground
        var result = Set(played: theme.accentRGB, played2: theme.accent2RGB, unplayed: theme.canvasRGB)
        for _ in 0..<4 {
            var p1 = theme.accentRGB, p2 = theme.accent2RGB
            for s in surfaces { p1 = WCAG.fit(p1, against: s, minimum: target); p2 = WCAG.fit(p2, against: s, minimum: target) }
            // the unplayed colour: the strongest tint of the ink that is still 3:1 away from both ends of the played colour, and seen on every surface
            var chosen: RGB?
            var t = 0.6
            while t >= 0.08 {
                let u = theme.canvasRGB.mixed(with: theme.inkRGB, t)
                if contrastAll(u) >= unplayedAgainstBackground, WCAG.contrast(p1, u) >= playedAgainstUnplayed, WCAG.contrast(p2, u) >= playedAgainstUnplayed { chosen = u; break }
                t -= 0.02
            }
            result = Set(played: p1, played2: p2, unplayed: chosen ?? theme.canvasRGB.mixed(with: theme.inkRGB, 0.08))
            if chosen != nil { return result }
            target += 1.5          // not separable yet: ask more of the played colour and look again
        }
        return result
    }

    nonisolated(unsafe) private static var cache: [String: Set] = [:]
    /// The colours for the theme in use (worked out once per theme).
    static var current: Set {
        let t = Theme.current
        if let c = cache[t.id] { return c }
        let c = resolve(t); cache[t.id] = c; return c
    }
}

/// A short pulse of the seek marker where the waveform was clicked: no movement, no bounce; restarted by every click.
struct SeekPulse: Equatable {
    private(set) var count = 0
    private(set) var x: CGFloat = 0
    mutating func fire(at x: CGFloat) { count += 1; self.x = x }
}

/// The marker itself: a thin gold line at the seek position that clears over a third of a second. A new one (a new `count`) replaces it, so every seek shows.
struct SeekPulseMark: View {
    let x: CGFloat
    let height: CGFloat
    @State private var opacity = 0.9

    var body: some View {
        Rectangle().fill(Brand.accent).frame(width: 1.5, height: height)
            .overlay(Circle().fill(Brand.accent).frame(width: 5, height: 5).offset(y: -height / 2))
            .offset(x: x - 0.75)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.36)) { opacity = 0 } }
    }
}

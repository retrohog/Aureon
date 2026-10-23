import SwiftUI

/// A colour theme: the surfaces, the ink drawn on them and the accent pair. Chrome is neutral (warm graphite by night, bone paper by day);
/// colour comes from the accent alone, which drives the few gradients of the interface (Now Playing, waveform fill, active indicators, the
/// progress rule). Everything the interface paints with comes from here (through `Brand`). Every family has a dark and a light variant.
///
/// The values are stored as `RGB` so contrast can be computed on them: `ink`, its two lighter steps and the accent are all held to WCAG AA
/// against both surfaces, which the self-test checks for every theme.
struct Theme: Identifiable, Equatable {
    let id: String
    let family: String
    let name: String
    let blurb: String
    var isLight = false
    var canvasRGB: RGB            // page background
    var sidebarRGB: RGB           // the sidebar and the player bar
    var inkRGB: RGB               // text and hairlines: bone on dark themes, near-black on light ones
    var accentRGB: RGB
    var accent2RGB: RGB           // the other end of the accent gradient: a neighbouring hue, never a complementary one

    var canvas: Color { canvasRGB.color }
    var sidebar: Color { sidebarRGB.color }
    var ink: Color { inkRGB.color }
    var accent: Color { accentRGB.color }
    var accent2: Color { accent2RGB.color }

    /// The lightest (dark themes) or darkest (light themes) the page can get once a backdrop is laid on it. Backdrops are held to this, and every
    /// text colour is checked against it too, so a backdrop can never cost text its contrast.
    var backdropLimitRGB: RGB { canvasRGB.mixed(with: isLight ? RGB(0, 0, 0) : RGB(1, 1, 1), isLight ? 0.08 : 0.14) }

    /// The surfaces text has to be legible on.
    var surfaces: [RGB] { [canvasRGB, sidebarRGB, backdropLimitRGB] }

    /// Ink at the lowest opacity that still gives `target`:1 on every surface, as an opaque colour over the canvas.
    private func inkStep(target: Double) -> RGB {
        var alpha = 0.3
        while alpha < 1 {
            // the step is one opaque colour, used on every surface: it is the ink at `alpha` over the canvas
            let step = WCAG.over(inkRGB, alpha: alpha, canvasRGB)
            if surfaces.allSatisfy({ WCAG.contrast(step, $0) >= target }) { return step }
            alpha += 0.01
        }
        return inkRGB
    }
    /// Secondary text (artist lines, captions): AAA, 7:1.
    var inkSecondaryRGB: RGB { Theme.cachedStep(self, 7) }
    /// Tertiary text (hints, units, placeholders): AA, 4.5:1.
    var inkTertiaryRGB: RGB { Theme.cachedStep(self, 4.5) }
    var inkSecondary: Color { inkSecondaryRGB.color }
    var inkTertiary: Color { inkTertiaryRGB.color }

    nonisolated(unsafe) private static var stepCache: [String: RGB] = [:]
    private static func cachedStep(_ t: Theme, _ target: Double) -> RGB {
        let key = "\(t.id)|\(t.inkRGB.r)|\(t.canvasRGB.r)|\(target)"
        if let c = stepCache[key] { return c }
        let v = t.inkStep(target: target)
        stepCache[key] = v
        return v
    }

    /// The accent as small text: nudged until it reads at 4.5:1 on both surfaces.
    var accentTextRGB: RGB { surfaces.reduce(accentRGB) { WCAG.fit($0, against: $1, minimum: 4.5) } }
    var accentText: Color { accentTextRGB.color }
    /// The label colour on a solid accent fill.
    var onAccentRGB: RGB { WCAG.onColor(accentRGB) }
    var onAccent: Color { onAccentRGB.color }

    static func rgbValue(_ hex: UInt32) -> RGB { RGB(Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255) }
    static func rgb(_ hex: UInt32) -> Color { rgbValue(hex).color }

    typealias Palette = (canvas: UInt32, sidebar: UInt32, ink: UInt32, accent: UInt32, accent2: UInt32)

    private static func make(_ family: String, _ name: String, _ blurb: String, dark d: Palette, light l: Palette) -> (dark: Theme, light: Theme) {
        func theme(_ p: Palette, light: Bool) -> Theme {
            Theme(id: light ? family + ".light" : family, family: family, name: name, blurb: blurb, isLight: light, canvasRGB: rgbValue(p.canvas), sidebarRGB: rgbValue(p.sidebar),
                  inkRGB: rgbValue(p.ink), accentRGB: rgbValue(p.accent), accent2RGB: rgbValue(p.accent2))
        }
        return (theme(d, light: false), theme(l, light: true))
    }

    /// Obsidian: near-black with a faint blue cast, ivory ink, champagne gold. Ivory is its day version: bone paper, warm black ink, deep brass.
    static let obsidian: Palette = (0x0D0E11, 0x090A0C, 0xEFEAE0, 0xC9A96E, 0xA68A52)
    static let ivory: Palette = (0xF5F1E8, 0xECE7DB, 0x1A1814, 0x7F6228, 0x8F7438)

    static let families: [(id: String, name: String, blurb: String, dark: Theme, light: Theme)] = {
        let defs: [(String, String, String, Palette, Palette)] = [
            ("obsidian", "Obsidian", "Midnight black and ivory, with champagne gold; Ivory by day", obsidian, ivory),
            ("bespoke", "Bespoke", "Deep green-black and pale stone, with the same gold", (0x0B1210, 0x070C0B, 0xE9E7DC, 0xC9A96E, 0xA68A52), (0xEFEFE6, 0xE4E5DA, 0x16201B, 0x7F6228, 0x8F7438)),
            ("aureon", "Graphite", "Warm graphite and bone, with brass", (0x1A1917, 0x131210, 0xEDE9E2, 0xC9A96E, 0xA68A52), (0xF3EFE7, 0xE9E4D9, 0x1C1A17, 0x7F6228, 0x8F7438)),
            ("evergreen", "Evergreen", "Forest at night, morning meadow by day", (0x131A16, 0x0E1411, 0xE6EDE7, 0x8FBF7A, 0xC9B458), (0xF1F3EC, 0xE6E9DF, 0x182019, 0x3F7A3A, 0x8A7A1C)),
            ("nord", "Nord", "Arctic, muted blues", (0x2E3440, 0x272C36, 0xECEFF4, 0x88C0D0, 0xA3BE8C), (0xECEFF4, 0xE0E5EC, 0x2E3440, 0x4A6C8F, 0x5E8A6E)),
            ("gruvbox", "Gruvbox", "Retro warm browns and amber", (0x282828, 0x1D2021, 0xEBDBB2, 0xFABD2F, 0xFE8019), (0xFBF1C7, 0xEBDBB2, 0x3C3836, 0x9A5B0C, 0xAF3A03)),
        ]
        return defs.map { d in
            let pair = make(d.0, d.1, d.2, dark: d.3, light: d.4)
            return (d.0, d.1, d.2, pair.dark, pair.light)
        }
    }()

    /// The theme used before anything is chosen and when an id is unknown (themes that were removed, such as the old "album" colours): Obsidian.
    static let aureon = families[0].dark
    static let all: [Theme] = families.flatMap { [$0.dark, $0.light] }

    /// "obsidian", "obsidian.light" (or the old plain "light", which was the light default).
    static func named(_ id: String?) -> Theme {
        if id == "light" { return families[0].light }
        return all.first { $0.id == id } ?? .aureon
    }

    static func resolve(family: String, light: Bool) -> Theme {
        let f = families.first { $0.id == family } ?? families[0]
        return light ? f.light : f.dark
    }

    /// The theme in use. Set on the main thread when the user picks one; read by `Brand` while views are built.
    nonisolated(unsafe) static var current = Theme.aureon
}

/// How the backdrop behind the pages is painted. Each theme remembers its own choice.
enum BackdropMode: String, CaseIterable, Identifiable {
    /// Flat theme colour.
    case off
    /// A restrained two-tone wash of the theme's own colours.
    case soft
    /// The current cover, blurred, laid under the page.
    case album
    /// The soft wash with a sparse field of fine stars drifting very slowly over it (dark themes only).
    case starlight
    var id: String { rawValue }
    var title: String { switch self { case .off: "Flat"; case .soft: "Soft"; case .album: "Album"; case .starlight: "Starlight" } }
    var hint: String { switch self { case .off: "Plain theme colour behind every page"; case .soft: "A quiet two-tone wash of the theme's colours"; case .album: "The cover that is playing, blurred, behind the page"; case .starlight: "A sparse field of fine stars, drifting very slowly" } }
}

/// Two neighbouring hues derived from one colour (a cover's accent), fitted to the surfaces they are drawn on. Used for the Album backdrop's tint.
enum AccentPair {
    /// The pair when there is nothing to derive from (no cover, or a grey one): champagne into brass.
    static let fallback: (accent: RGB, accent2: RGB) = (Theme.rgbValue(0xC9A96E), Theme.rgbValue(0xA68A52))

    /// A colour is "grey" below this saturation: its hue means nothing.
    static let greyBelow = 0.14

    /// `source`'s hue at a restrained saturation, and a second hue a few degrees away from it (towards cyan from blues, towards red from magentas,
    /// towards yellow from the rest), so the gradient between them stays one colour family and never crosses through purple.
    /// On a dark surface both are light and on a light one both are dark; either way the first reaches 4.5:1 and the second 3:1 on every surface.
    static func derive(from source: RGB, onDark: Bool, against surfaces: [RGB]) -> (accent: RGB, accent2: RGB) {
        let h = source.hsb
        var a: RGB, b: RGB
        if h.s < greyBelow {
            a = onDark ? fallback.accent : Theme.rgbValue(0x7F6228)
            b = onDark ? fallback.accent2 : Theme.rgbValue(0x8F7438)
        } else {
            let s = min(0.82, max(0.5, h.s))
            let shift: Double = h.h >= 0.5 && h.h < 0.75 ? -0.05 : 0.05
            a = RGB(h: h.h, s: s, v: onDark ? 0.93 : 0.7)
            b = a.hueShifted(shift).with(saturation: min(0.9, s + 0.05), brightness: onDark ? 0.82 : 0.6)
        }
        for bg in surfaces { a = WCAG.fit(a, against: bg, minimum: 4.5); b = WCAG.fit(b, against: bg, minimum: 3) }
        return (a, b)
    }
}

/// Which variant of the chosen theme to use.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "Auto"; case .light: "Light"; case .dark: "Dark" } }
    var icon: String { switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" } }
}

/// A grid of theme previews to pick from, with the dark / light switch.
struct ThemePicker: View {
    @EnvironmentObject var m: PlayerModel
    @AppStorage(ScrollVolumeMode.storageKey) private var scrollVolumeRaw = ScrollVolumeMode.optionOnly.rawValue
    private var scrollVolume: Binding<ScrollVolumeMode> { Binding(get: { ScrollVolumeMode(rawValue: scrollVolumeRaw) ?? .optionOnly }, set: { scrollVolumeRaw = $0.rawValue }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                SegmentedChoice(selection: $m.appearance, items: Array(AppearanceMode.allCases), label: { $0.title }, icon: { $0.icon }).frame(width: 264)
                Text(m.appearance == .system ? "Follows your Mac's appearance" : "Every theme has a dark and a light version").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)], alignment: .leading, spacing: 16) {
                ForEach(Theme.families, id: \.id) { f in swatch(f.id, f.name, f.blurb) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Backdrop").microLabel().foregroundStyle(Brand.inkTertiary)
                HStack(spacing: 16) {
                    SegmentedChoice(selection: $m.backdrop, items: BackdropMode.allCases.filter { $0 != .starlight || !m.theme.isLight }, label: { $0.title }).frame(width: 352)
                    Text(m.backdrop.hint).font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
                if m.backdrop == .album {
                    HStack(spacing: 16) {
                        SegmentedChoice(selection: $m.backdropIntensity, items: Array(BackdropIntensity.allCases), label: { $0.title }).frame(width: 264)
                        Text(m.backdropIntensity.hint).font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                    }
                    .transition(.opacity)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Glass").microLabel().foregroundStyle(Brand.inkTertiary)
                HStack(spacing: 16) {
                    Toggle("Glass accents", isOn: $m.glassAccents).labelsHidden().accessibilityLabel("Glass accents")
                    Text("Liquid glass on the player bar, the Now Playing panels, the palette and pop-ups. Off keeps them flat.").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Page transitions").microLabel().foregroundStyle(Brand.inkTertiary)
                HStack(spacing: 16) {
                    SegmentedChoice(selection: $m.pageTransitions, items: Array(TabMotion.Mode.allCases), label: { $0.title }).frame(width: 176)
                    Text(m.pageTransitions == .fade ? "Pages change with a quick fade, in place. Nothing slides or moves." : "Pages change at once.").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Scroll to change volume").microLabel().foregroundStyle(Brand.inkTertiary)
                HStack(spacing: 16) {
                    SegmentedChoice(selection: scrollVolume, items: Array(ScrollVolumeMode.allCases), label: { $0.title }).frame(width: 380)
                    Text(ScrollVolumeMode(rawValue: scrollVolumeRaw)?.hint ?? "").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Launch").microLabel().foregroundStyle(Brand.inkTertiary)
                HStack(spacing: 16) {
                    Toggle("Launch animation", isOn: $m.launchAnimation).labelsHidden().accessibilityLabel("Launch animation")
                    Text("A short animation of the mark before the window opens. A click or a key skips it.").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
            }
        }
    }

    private func swatch(_ id: String, _ name: String, _ blurb: String) -> some View {
        let t = Theme.resolve(family: id, light: m.theme.isLight)
        let on = m.themeFamily == id
        return Button { withAnimation(.easeOut(duration: 0.2)) { m.themeFamily = id } } label: {
            VStack(alignment: .leading, spacing: 8) {
                // a miniature of the interface in this theme: sidebar, a title line, a rule, the accent gradient
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(t.canvas)
                    HStack(spacing: 0) {
                        Rectangle().fill(t.sidebar).frame(width: 32)
                        Rectangle().fill(t.ink.opacity(0.14)).frame(width: Metrics.hairline)
                        VStack(alignment: .leading, spacing: 6) {
                            Rectangle().fill(t.ink.opacity(0.85)).frame(width: 48, height: 4)
                            Rectangle().fill(t.ink.opacity(0.14)).frame(height: Metrics.hairline)
                            Rectangle().fill(t.ink.opacity(0.4)).frame(width: 64, height: 3)
                            Rectangle().fill(LinearGradient(colors: [t.accent, t.accent2], startPoint: .leading, endPoint: .trailing)).frame(width: 56, height: 2)
                        }.padding(8)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in Rectangle().fill(i == 0 ? t.accent : t.ink.opacity(0.4)).frame(width: i == 0 ? 20 : 22, height: 2) }
                    }.padding(.leading, 6).padding(.top, 8)
                }
                .frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(on ? t.accentText : Brand.rule, lineWidth: on ? 1.5 : Metrics.hairline))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(name).font(Typo.serif(15, .medium))
                        if on { Image(systemName: "checkmark").font(Typo.sans(10, .medium)).foregroundStyle(t.accentText) }
                    }
                    Text(blurb).font(Typo.caption).foregroundStyle(Brand.inkSecondary).lineLimit(2).frame(height: 28, alignment: .topLeading)
                }
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}


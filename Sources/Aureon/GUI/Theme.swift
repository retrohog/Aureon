import SwiftUI

/// A colour theme: the surfaces, the ink drawn on them and the accent. Pulse has nine: six dark (Graphite, AMOLED, Midnight, Forest, Plum, Cocoa)
/// and three softened light ones (Stone, Sage, Paper). Three surfaces carry the layout: the window behind everything (`sidebarRGB`, also the
/// colour of the top bar and the rail), the main panel (`canvasRGB`, the page itself and the player bar) and the raised surface (`panel2RGB`: cards,
/// chips, the selected rail item). Everything the interface paints with comes from here (through `Brand`).
///
/// The values are stored as `RGB` so contrast can be computed on them: `ink`, its two lighter steps and the accent are all held to WCAG AA
/// against every surface, for every theme.
struct Theme: Identifiable, Equatable {
    /// "graphite" (dark), "graphite.light", and "graphite.black" for the dark one on pure black.
    let id: String
    /// The family: "graphite", "midnight", "forest", "plum", "cocoa".
    let family: String
    /// The family's name (the same for its dark and light halves).
    let name: String
    let blurb: String
    var isLight = false
    /// Dark on pure black: the window is black and the panels sit just above it.
    var pureBlack = false
    var canvasRGB: RGB            // the main panel: pages and the player bar
    var sidebarRGB: RGB           // the window behind the panels: top bar and rail
    var panel2RGB: RGB            // raised surfaces: cards, chips, the selected rail item
    var inkRGB: RGB               // text and hairlines: warm white on dark themes, near-black on light ones
    var accentRGB: RGB
    var accent2RGB: RGB           // the other end of the accent gradient: a neighbouring hue, never a complementary one

    var canvas: Color { canvasRGB.color }
    var sidebar: Color { sidebarRGB.color }
    var panel2: Color { panel2RGB.color }
    var ink: Color { inkRGB.color }
    var accent: Color { accentRGB.color }
    var accent2: Color { accent2RGB.color }

    /// The lightest (dark themes) or darkest (light themes) the page can get once a backdrop is laid on it. Backdrops are held to this, and every
    /// text colour is checked against it too, so a backdrop can never cost text its contrast.
    var backdropLimitRGB: RGB { canvasRGB.mixed(with: isLight ? RGB(0, 0, 0) : RGB(1, 1, 1), isLight ? 0.08 : 0.14) }

    /// The surfaces text has to be legible on.
    var surfaces: [RGB] { [canvasRGB, sidebarRGB, panel2RGB, backdropLimitRGB] }

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
        let key = "\(t.id)|\(t.inkRGB.r)|\(t.canvasRGB.r)|\(t.panel2RGB.r)|\(t.sidebarRGB.r)|\(target)"
        if let c = stepCache[key] { return c }
        let v = t.inkStep(target: target)
        stepCache[key] = v
        return v
    }

    /// The accent as small text: nudged until it reads at 4.5:1 on every surface.
    var accentTextRGB: RGB { surfaces.reduce(accentRGB) { WCAG.fit($0, against: $1, minimum: 4.5, towardWhite: !isLight) } }
    var accentText: Color { accentTextRGB.color }
    /// The label colour on a solid accent fill.
    var onAccentRGB: RGB { WCAG.onColor(accentRGB) }
    var onAccent: Color { onAccentRGB.color }

    static func rgbValue(_ hex: UInt32) -> RGB { RGB(Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255) }
    static func rgb(_ hex: UInt32) -> Color { rgbValue(hex).color }

    /// window, panel, raised surface, ink, accent
    typealias Palette = (window: UInt32, panel: UInt32, panel2: UInt32, ink: UInt32, accent: UInt32)

    private static func make(_ family: String, _ name: String, _ blurb: String, light: Bool, _ p: Palette) -> Theme {
        let accent = rgbValue(p.accent)
        return Theme(id: light ? family + ".light" : family, family: family, name: name, blurb: blurb, isLight: light, canvasRGB: rgbValue(p.panel), sidebarRGB: rgbValue(p.window), panel2RGB: rgbValue(p.panel2),
                     inkRGB: rgbValue(p.ink), accentRGB: accent, accent2RGB: companion(of: accent))
    }

    /// The second end of an accent gradient: the same colour family, a few degrees along the wheel and a little deeper.
    static func companion(of accent: RGB) -> RGB {
        let h = accent.hsb
        let shift: Double = h.h >= 0.5 && h.h < 0.75 ? -0.04 : 0.04
        return accent.hueShifted(shift).with(saturation: min(1, h.s * 1.05), brightness: h.v * 0.86)
    }

    /// A colour family: one palette for the night and one for the day. Which of them is used is the Appearance mode (Dark, Light or Auto).
    struct Family: Identifiable {
        let id: String
        let name: String
        let blurb: String
        let dark: Theme
        let light: Theme
    }

    /// The five families. The light halves are muted on purpose: panels sit a step darker than paper white (see `Look.lightBrightness`).
    static let families: [Family] = [
        family("graphite", "Graphite", "Warm charcoal with amber; warm grey by day", dark: (0x0C0C0E, 0x161619, 0x222227, 0xF6F3EC, 0xF2B84B), light: (0xC0BEB6, 0xCBC9C1, 0xB5B3AA, 0x201D18, 0x6A4300)),
        family("midnight", "Midnight", "Deep navy with a clear blue; blue-grey by day", dark: (0x080B14, 0x0F1424, 0x1A2036, 0xEEF2FF, 0x7FA6FF), light: (0xB4BDCB, 0xC2CAD6, 0xA6B0C0, 0x121827, 0x2F4F9E)),
        family("forest", "Forest", "Green-black with soft leaf green; sage by day", dark: (0x0A110D, 0x111B15, 0x1B2A21, 0xEEF4EA, 0x9ED38A), light: (0xB9C0B2, 0xC5CCBE, 0xABB3A3, 0x181D16, 0x2B5436)),
        family("plum", "Plum", "Aubergine with rose; lilac-grey by day", dark: (0x100A12, 0x1A1220, 0x28192F, 0xF7EEF6, 0xF09AD0), light: (0xC4BBC9, 0xD0C8D5, 0xB6ACBC, 0x1E1424, 0x7A2E6E)),
        family("cocoa", "Cocoa", "Dark roast with apricot; warm paper by day", dark: (0x120D0A, 0x1D1511, 0x2B201A, 0xF6EEE6, 0xF0A36B), light: (0xCAC0AC, 0xD4CBB8, 0xBDB39E, 0x1E1913, 0x7E3418)),
    ]

    private static func family(_ id: String, _ name: String, _ blurb: String, dark: Palette, light: Palette) -> Family {
        Family(id: id, name: name, blurb: blurb, dark: make(id, name, blurb, light: false, dark), light: make(id, name, blurb, light: true, light))
    }

    /// Every theme: each family's dark half and its light half.
    static let all: [Theme] = families.flatMap { [$0.dark, $0.light] }
    static let dark: [Theme] = all.filter { !$0.isLight }
    static let light: [Theme] = all.filter { $0.isLight }

    /// The theme used before anything is chosen and when an id is unknown: Graphite.
    static let aureon = families[0].dark
    static let defaultLight = families[0].light

    /// This dark theme on pure black: the window is #000000 and the panels are the family's own, taken most of the way down, so the tint stays.
    var onPureBlack: Theme {
        guard !isLight else { return self }
        var t = Theme(id: family + ".black", family: family, name: name, blurb: blurb, isLight: false, pureBlack: true, canvasRGB: canvasRGB.mixed(with: RGB(0, 0, 0), 0.55),
                      sidebarRGB: RGB(0, 0, 0), panel2RGB: panel2RGB.mixed(with: RGB(0, 0, 0), 0.32), inkRGB: inkRGB, accentRGB: accentRGB, accent2RGB: accent2RGB)
        t.isLight = false
        return t
    }

    /// Ids of earlier versions and what they became (an id that ends in ".black" is a family on pure black).
    static let legacy: [String: String] = [
        "obsidian": "graphite", "aureon": "graphite", "bespoke": "forest", "evergreen": "forest", "nord": "midnight", "gruvbox": "cocoa",
        "obsidian.light": "graphite.light", "light": "graphite.light", "aureon.light": "graphite.light", "bespoke.light": "forest.light", "evergreen.light": "forest.light",
        "nord.light": "midnight.light", "gruvbox.light": "cocoa.light",
        // the nine themes of the first Pulse builds
        "amoled": "graphite.black", "stone": "graphite.light", "sage": "forest.light", "paper": "cocoa.light",
    ]

    /// A theme by id (earlier ids are carried over; anything else is Graphite).
    static func named(_ id: String?) -> Theme {
        guard let id else { return .aureon }
        let key = legacy[id] ?? id
        if key.hasSuffix(".black") { return named(String(key.dropLast(6))).onPureBlack }
        return all.first { $0.id == key } ?? .aureon
    }

    /// The theme to show for a family in a mode (pure black only applies to the dark half).
    static func resolve(family: String, light: Bool, pureBlack: Bool) -> Theme {
        let f = families.first { $0.id == family } ?? families[0]
        return light ? f.light : (pureBlack ? f.dark.onPureBlack : f.dark)
    }

    /// An old saved choice (a theme id, with the appearance it was shown in) as a family, a mode and the pure black switch.
    static func migrated(id: String?, light: Bool?) -> (family: String, light: Bool, pureBlack: Bool) {
        let t = named(id)
        return (t.family, light ?? t.isLight, t.pureBlack)
    }

    /// The light themes at a brightness between 0 and 1 (0.35 is the designed tone): towards a quieter grey below it, towards paper above it.
    /// Dark themes are returned as they are.
    func adjusted(lightBrightness b: Double) -> Theme {
        guard isLight else { return self }
        let d = min(1, max(0, b)) - 0.35
        func tone(_ c: RGB) -> RGB { d >= 0 ? c.mixed(with: RGB(1, 1, 1), d * 0.55) : c.mixed(with: RGB(0, 0, 0), -d * 0.2) }
        var t = self
        t.canvasRGB = tone(canvasRGB); t.sidebarRGB = tone(sidebarRGB); t.panel2RGB = tone(panel2RGB)
        return t
    }

    /// The same theme with another accent colour (the accent picker). The label on it and its text colour are derived again.
    func withAccent(_ c: RGB?) -> Theme {
        guard let c else { return self }
        var t = self
        t.accentRGB = c; t.accent2RGB = Theme.companion(of: c)
        return t
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
                Text(m.appearance == .system ? "Follows your Mac: your dark theme at night, your light theme by day" : "Pick any of the nine; light themes are soft on purpose").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 168), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(Theme.all) { t in swatch(t) }
            }
            if m.theme.isLight {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Light brightness").microLabel().foregroundStyle(Brand.inkTertiary)
                    LookSliderRow(title: "Brightness", hint: "From a quiet grey to paper. The default is easy on the eyes.", value: $m.look.lightBrightness, defaultValue: LookSettings.defaults.lightBrightness, deferred: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Accent").microLabel().foregroundStyle(Brand.inkTertiary)
                AccentPicker()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Density").microLabel().foregroundStyle(Brand.inkTertiary)
                HStack(spacing: 16) {
                    SegmentedChoice(selection: $m.look.density, items: UIDensity.allCases, label: { $0.title }).frame(width: 264)
                    Text(m.look.density.hint).font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Font").microLabel().foregroundStyle(Brand.inkTertiary)
                HStack(spacing: 16) {
                    SegmentedChoice(selection: $m.look.weight, items: TypeWeight.allCases, label: { $0.title }).frame(width: 264)
                    Text(TypeFace.hasPreferred ? "Figtree, Regular by default" : "Avenir Next stands in until Figtree is installed").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
                LookSliderRow(title: "Text size", hint: "Scales every size in the interface.", value: textScaleBinding, defaultValue: (1 - LookSettings.textScaleRange.lowerBound) / (LookSettings.textScaleRange.upperBound - LookSettings.textScaleRange.lowerBound), deferred: true, format: { "\(Int((Look.lerp(LookSettings.textScaleRange.lowerBound, LookSettings.textScaleRange.upperBound, $0) * 100).rounded()))%" })
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Backdrop").microLabel().foregroundStyle(Brand.inkTertiary)
                HStack(spacing: 16) {
                    SegmentedChoice(selection: $m.backdrop, items: Array(BackdropMode.allCases), label: { $0.title }).frame(width: 352)
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
                    Toggle("", isOn: $m.launchAnimation).accessibilityLabel("Launch animation").fixedSize()
                    Text("A short animation of the mark before the window opens. A click or a key skips it.").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
            }
        }
    }

    /// The text size as a 0…1 position on its range.
    private var textScaleBinding: Binding<Double> {
        let r = LookSettings.textScaleRange
        return Binding(get: { (m.look.textScale - r.lowerBound) / (r.upperBound - r.lowerBound) }, set: { m.look.textScale = r.lowerBound + $0 * (r.upperBound - r.lowerBound) })
    }

    private func swatch(_ t: Theme) -> some View {
        let on = m.theme.id == t.id
        return Button { withAnimation(.easeOut(duration: 0.2)) { m.choose(theme: t) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                // a miniature of the shell in this theme: rail, panel with a title, a tag, and the player bar
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.sidebar)
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.panel2).frame(width: 22).padding(8)
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.canvas).padding(.leading, 38).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 34)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(t.ink).frame(width: 64, height: 8)
                        Capsule().fill(t.ink.opacity(0.7)).frame(width: 90, height: 5)
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(t.accent).frame(width: 36, height: 14)
                    }.padding(.leading, 46).padding(.top, 16)
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.canvas).frame(height: 20).padding(.leading, 38).padding(.trailing, 8)
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8)
                    Circle().fill(t.accent).frame(width: 12, height: 12).padding(.leading, 44).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 12)
                }
                .frame(height: 92)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Brand.accentText : Brand.rule, lineWidth: on ? 2 : Metrics.hairline))
                HStack(spacing: 4) {
                    Text(t.name).font(Typo.sans(13.5, .regular))
                    if on { Image(systemName: "checkmark").font(Typo.sans(10, .medium)).foregroundStyle(Brand.accentText) }
                }
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(t.name).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The accent colour: the theme's own, six presets, or any colour from the system's picker. A chosen colour is kept readable by the theme (text
/// uses a fitted version of it; labels on it flip between black and white).
struct AccentPicker: View {
    @EnvironmentObject var m: PlayerModel
    static let presets: [(String, String)] = [("F2B84B", "Amber"), ("7FA6FF", "Blue"), ("9ED38A", "Leaf"), ("F09AD0", "Rose"), ("F0A36B", "Apricot"), ("5FD1C9", "Teal")]

    private var custom: Binding<Color> {
        Binding(get: { (m.look.accentHex.flatMap(Look.color(hex:)) ?? Theme.current.accentRGB).color },
                set: { c in if let rgb = NSColor(c).usingColorSpace(.sRGB) { m.look.accentHex = Look.hex(RGB(Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))) } })
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { m.look.accentHex = nil } label: {
                Text("Theme").font(Typo.sans(12.5, m.look.accentHex == nil ? .medium : .regular))
                    .padding(.horizontal, 12).frame(height: 28)
                    .foregroundStyle(m.look.accentHex == nil ? Brand.panel : Brand.ink)
                    .background(Capsule().fill(m.look.accentHex == nil ? Brand.ink : Brand.panel2))
            }.buttonStyle(.plain).accessibilityLabel("Use each theme's own accent")
            ForEach(Self.presets, id: \.0) { p in
                let on = m.look.accentHex == p.0
                Button { m.look.accentHex = p.0 } label: {
                    Circle().fill(Theme.rgb(UInt32(p.0, radix: 16) ?? 0)).frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Brand.ink, lineWidth: on ? 2 : 0).padding(-3))
                }.buttonStyle(.plain).accessibilityLabel(p.1).accessibilityAddTraits(on ? .isSelected : [])
            }
            ColorPicker("Any colour", selection: custom, supportsOpacity: false).labelsHidden().accessibilityLabel("Choose any accent colour")
            Text(m.look.accentHex.map { "#" + $0 } ?? "Each theme's own").font(Typo.mono(11)).foregroundStyle(Brand.inkSecondary)
        }
    }
}

/// A row with a slider in the Appearance groups: what it changes, the value, a reset, the slider and a line of explanation. `deferred` is for the values
/// that re-colour or re-size the whole interface (light brightness, text size): the slider moves freely and the change is applied when it pauses, so the
/// control being dragged is not rebuilt under the pointer.
struct LookSliderRow: View {
    let title: String
    var hint: String = ""
    @Binding var value: Double
    let defaultValue: Double
    var deferred = false
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }
    @StateObject private var draft = Box<Double?>(nil)
    @StateObject private var pending = Box<Task<Void, Never>?>(nil)

    private var shown: Double { draft.v ?? value }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Typo.sans(13, .medium))
                Spacer(minLength: 8)
                Text(format(shown)).font(Typo.mono(11)).foregroundStyle(Brand.inkSecondary).frame(minWidth: 32, alignment: .trailing)
                Button("Reset") { draft.v = nil; pending.v?.cancel(); value = defaultValue }.buttonStyle(.rule).controlSize(.mini).disabled(abs(shown - defaultValue) < 0.005)
            }
            ValueSlider(value: Binding(get: { shown }, set: { new in
                if deferred {
                    draft.v = new
                    pending.v?.cancel()
                    pending.v = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        guard !Task.isCancelled else { return }
                        value = new; draft.v = nil
                    }
                } else { value = new }
            }), in: 0...1)
            if !hint.isEmpty { Text(hint).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

import SwiftUI

/// A colour theme: the surfaces, the ink drawn on them and two accent colours. Everything the interface paints with comes from here (through `Brand`).
/// Every family has a dark and a light variant; `Theme` is one resolved variant.
struct Theme: Identifiable, Equatable {
    let id: String
    let family: String
    let name: String
    let blurb: String
    var isLight = false
    var canvas: Color          // page background
    var sidebar: Color
    var ink: Color             // text and hairlines: white-ish on dark themes, black-ish on light ones
    var accent: Color
    var accent2: Color
    /// Translucent system sidebar (only the default theme keeps it; the others paint their own).
    var vibrant = false

    static func rgb(_ hex: UInt32) -> Color { Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }

    private static func make(_ family: String, _ name: String, _ blurb: String, dark d: (canvas: UInt32, sidebar: UInt32, ink: UInt32, accent: UInt32, accent2: UInt32),
                             light l: (canvas: UInt32, sidebar: UInt32, ink: UInt32, accent: UInt32, accent2: UInt32), vibrantDark: Bool = false) -> (dark: Theme, light: Theme) {
        (Theme(id: family, family: family, name: name, blurb: blurb, isLight: false, canvas: rgb(d.canvas), sidebar: rgb(d.sidebar), ink: rgb(d.ink), accent: rgb(d.accent), accent2: rgb(d.accent2), vibrant: vibrantDark),
         Theme(id: family + ".light", family: family, name: name, blurb: blurb, isLight: true, canvas: rgb(l.canvas), sidebar: rgb(l.sidebar), ink: rgb(l.ink), accent: rgb(l.accent), accent2: rgb(l.accent2)))
    }

    static let families: [(id: String, name: String, blurb: String, dark: Theme, light: Theme)] = {
        let defs: [(String, String, String, (UInt32, UInt32, UInt32, UInt32, UInt32), (UInt32, UInt32, UInt32, UInt32, UInt32), Bool)] = [
            ("aureon", "Aureon", "The default: graphite and coral", (0x1B1B1B, 0x252525, 0xFFFFFF, 0xFF4566, 0xFF8C4D), (0xF7F7F9, 0xE9E9EE, 0x000000, 0xE5334F, 0xFF7A3D), true),
            ("album", "Album", "Colours flow from the cover that is playing", (0x1B1B1B, 0x141414, 0xFFFFFF, 0xFF4566, 0xFF8C4D), (0xF4F4F6, 0xE8E8EC, 0x111111, 0xE5334F, 0xFF7A3D), false),
            ("evergreen", "Evergreen", "Forest at night, morning meadow by day", (0x0F1B15, 0x14271D, 0xE8F5EC, 0x3DDC84, 0xC9F27B), (0xF3F8F4, 0xE0EDE5, 0x14281D, 0x1E9E5B, 0x7FA82A), false),
            ("nord", "Nord", "Arctic, muted blues", (0x2E3440, 0x3B4252, 0xECEFF4, 0x88C0D0, 0xA3BE8C), (0xECEFF4, 0xE0E5EC, 0x2E3440, 0x5E81AC, 0x7AA18E), false),
            ("catppuccin", "Catppuccin", "Mocha and Latte: soft pastels", (0x1E1E2E, 0x181825, 0xCDD6F4, 0xCBA6F7, 0xF5C2E7), (0xEFF1F5, 0xE6E9EF, 0x4C4F69, 0x8839EF, 0xEA76CB), false),
            ("dracula", "Dracula", "Purple and pink on charcoal, Alucard by day", (0x282A36, 0x21222C, 0xF8F8F2, 0xBD93F9, 0xFF79C6), (0xFFFBEB, 0xF0EAD6, 0x1F1F1F, 0x644AC9, 0xA3144D), false),
            ("gruvbox", "Gruvbox", "Retro warm browns and amber", (0x282828, 0x1D2021, 0xEBDBB2, 0xFABD2F, 0xFE8019), (0xFBF1C7, 0xEBDBB2, 0x3C3836, 0xB57614, 0xAF3A03), false),
            ("synthwave", "Synthwave", "Funky: neon magenta and cyan", (0x1A1033, 0x130A28, 0xF4E9FF, 0xFF2BD6, 0x00E5FF), (0xFBF3FF, 0xEFE3FA, 0x2B1055, 0xD100A8, 0x0097B5), false),
        ]
        return defs.map { d in
            let pair = make(d.0, d.1, d.2, dark: (d.3.0, d.3.1, d.3.2, d.3.3, d.3.4), light: (d.4.0, d.4.1, d.4.2, d.4.3, d.4.4), vibrantDark: d.5)
            return (d.0, d.1, d.2, pair.dark, pair.light)
        }
    }()

    static let aureon = families[0].dark
    static let all: [Theme] = families.flatMap { [$0.dark, $0.light] }

    /// "evergreen", "evergreen.light" (or the old plain "light", which was the light Aureon).
    static func named(_ id: String?) -> Theme {
        if id == "light" { return families[0].light }
        return all.first { $0.id == id } ?? .aureon
    }

    /// The "Album" theme: surfaces, ink and accents taken from the colours of the current cover. Rebuilt whenever the cover changes.
    static func album(from p: ArtPalette, light: Bool) -> Theme {
        func tint(_ c: RGB, s: Double, v: Double) -> Color { let h = c.hsb; return RGB(h: h.h, s: max(0, min(1, h.s * s)), v: max(0, min(1, v))).color }
        let base = p.grid[4], edge = p.grid[0], side = p.grid[6], a = p.accent.hsb, second = p.grid[2]
        if light {
            return Theme(id: "album.light", family: "album", name: "Album", blurb: "Colours flow from the cover that is playing", isLight: true,
                         canvas: tint(base, s: 0.22, v: 0.97), sidebar: tint(edge, s: 0.32, v: 0.91), ink: tint(base, s: 0.55, v: 0.14),
                         accent: RGB(h: a.h, s: max(0.55, min(0.9, a.s)), v: 0.62).color, accent2: tint(second, s: 1.1, v: 0.6))
        }
        return Theme(id: "album", family: "album", name: "Album", blurb: "Colours flow from the cover that is playing", isLight: false,
                     canvas: tint(base, s: 0.95, v: 0.19), sidebar: tint(side, s: 0.95, v: 0.13), ink: .white,
                     accent: RGB(h: a.h, s: max(0.4, min(0.9, a.s)), v: 0.95).color, accent2: tint(second, s: 1.1, v: 0.95))
    }

    static func resolve(family: String, light: Bool) -> Theme {
        let f = families.first { $0.id == family } ?? families[0]
        return light ? f.light : f.dark
    }

    /// The theme in use. Set on the main thread when the user picks one; read by `Brand` while views are built.
    nonisolated(unsafe) static var current = Theme.aureon
}

/// Which variant of the chosen theme to use.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "Auto"; case .light: "Light"; case .dark: "Dark" } }
    var icon: String { switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max.fill"; case .dark: "moon.fill" } }
}

/// A grid of theme previews to pick from, with the dark / light switch.
struct ThemePicker: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Picker("", selection: $m.appearance) { ForEach(AppearanceMode.allCases) { Label($0.title, systemImage: $0.icon).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Text(m.appearance == .system ? "Follows your Mac's appearance" : "Every theme has a dark and a light version").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(Theme.families, id: \.id) { f in swatch(f.id, f.name, f.blurb) }
            }
        }
    }

    private func swatch(_ id: String, _ name: String, _ blurb: String) -> some View {
        let t = id == "album" ? Theme.album(from: m.hero.palette, light: m.theme.isLight) : Theme.resolve(family: id, light: m.theme.isLight)
        let on = m.themeFamily == id
        return Button { withAnimation(.easeOut(duration: 0.2)) { m.themeFamily = id } } label: {
            VStack(alignment: .leading, spacing: 7) {
                // a miniature of the interface in this theme
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.canvas)
                    HStack(spacing: 0) {
                        Rectangle().fill(t.sidebar).frame(width: 34)
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().fill(t.ink.opacity(0.85)).frame(width: 46, height: 5)
                            Capsule().fill(t.ink.opacity(0.35)).frame(width: 64, height: 4)
                            HStack(spacing: 4) { Circle().fill(t.accent).frame(width: 11, height: 11); Circle().fill(t.accent2).frame(width: 11, height: 11); Capsule().fill(t.accent.opacity(0.4)).frame(width: 30, height: 5) }
                        }.padding(8)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in Capsule().fill(i == 0 ? t.accent : t.ink.opacity(0.4)).frame(width: i == 0 ? 20 : 22, height: 4) }
                    }.padding(.leading, 6).padding(.top, 9)
                }
                .frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? t.accent : Brand.ink.opacity(0.12), lineWidth: on ? 2 : 0.8))
                HStack(spacing: 5) {
                    Text(name).font(.system(size: 12.5, weight: .semibold))
                    if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(t.accent) }
                }
                Text(blurb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.ink.opacity(on ? 0.1 : 0.04)))
        }.buttonStyle(.plain)
    }
}

/// A sun / moon switch for the sidebar: flips between the dark and light version of the current theme.
struct AppearanceToggle: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var hover = Box(false)
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.25)) { m.appearance = m.theme.isLight ? .dark : .light } } label: {
            ZStack {
                Image(systemName: "moon.fill").opacity(m.theme.isLight ? 0 : 1).rotationEffect(.degrees(m.theme.isLight ? 90 : 0)).scaleEffect(m.theme.isLight ? 0.4 : 1)
                Image(systemName: "sun.max.fill").opacity(m.theme.isLight ? 1 : 0).rotationEffect(.degrees(m.theme.isLight ? 0 : -90)).scaleEffect(m.theme.isLight ? 1 : 0.4)
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.accent)
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.10 : 0.05)))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .help(m.theme.isLight ? "Switch to the dark version of \(m.theme.name)" : "Switch to the light version of \(m.theme.name)")
    }
}

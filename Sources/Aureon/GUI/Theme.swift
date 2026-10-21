import SwiftUI

/// A colour theme: the surfaces, the ink drawn on them and two accent colours. Everything the interface paints with comes from here (through `Brand`).
struct Theme: Identifiable, Equatable {
    let id: String
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

    static let aureon = Theme(id: "aureon", name: "Aureon", blurb: "The default: graphite and coral", canvas: Color(white: 0.105), sidebar: Color(white: 0.145), ink: .white,
                              accent: rgb(0xFF4566), accent2: rgb(0xFF8C4D), vibrant: true)
    static let light = Theme(id: "light", name: "Light", blurb: "Clean and bright", isLight: true, canvas: rgb(0xF7F7F9), sidebar: rgb(0xE9E9EE), ink: .black,
                             accent: rgb(0xE5334F), accent2: rgb(0xFF7A3D))
    static let evergreen = Theme(id: "evergreen", name: "Evergreen", blurb: "Forest at night", canvas: rgb(0x0F1B15), sidebar: rgb(0x14271D), ink: rgb(0xE8F5EC),
                                 accent: rgb(0x3DDC84), accent2: rgb(0xC9F27B))
    static let nord = Theme(id: "nord", name: "Nord", blurb: "Arctic, muted blues", canvas: rgb(0x2E3440), sidebar: rgb(0x3B4252), ink: rgb(0xECEFF4),
                            accent: rgb(0x88C0D0), accent2: rgb(0xA3BE8C))
    static let catppuccin = Theme(id: "catppuccin", name: "Catppuccin", blurb: "Mocha: soft pastels on warm dark", canvas: rgb(0x1E1E2E), sidebar: rgb(0x181825), ink: rgb(0xCDD6F4),
                                  accent: rgb(0xCBA6F7), accent2: rgb(0xF5C2E7))
    static let dracula = Theme(id: "dracula", name: "Dracula", blurb: "Purple and pink on charcoal", canvas: rgb(0x282A36), sidebar: rgb(0x21222C), ink: rgb(0xF8F8F2),
                               accent: rgb(0xBD93F9), accent2: rgb(0xFF79C6))
    static let gruvbox = Theme(id: "gruvbox", name: "Gruvbox", blurb: "Retro warm browns and amber", canvas: rgb(0x282828), sidebar: rgb(0x1D2021), ink: rgb(0xEBDBB2),
                               accent: rgb(0xFABD2F), accent2: rgb(0xFE8019))
    static let synthwave = Theme(id: "synthwave", name: "Synthwave", blurb: "Funky: neon magenta and cyan", canvas: rgb(0x1A1033), sidebar: rgb(0x130A28), ink: rgb(0xF4E9FF),
                                 accent: rgb(0xFF2BD6), accent2: rgb(0x00E5FF))

    static let all: [Theme] = [.aureon, .light, .evergreen, .nord, .catppuccin, .dracula, .gruvbox, .synthwave]
    static func named(_ id: String?) -> Theme { all.first { $0.id == id } ?? .aureon }

    /// The theme in use. Set on the main thread when the user picks one; read by `Brand` while views are built.
    nonisolated(unsafe) static var current = Theme.aureon
}

/// A grid of theme previews to pick from.
struct ThemePicker: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(Theme.all) { t in swatch(t) }
        }
    }

    private func swatch(_ t: Theme) -> some View {
        let on = m.theme == t
        return Button { withAnimation(.easeOut(duration: 0.2)) { m.theme = t } } label: {
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
                    Text(t.name).font(.system(size: 12.5, weight: .semibold))
                    if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(t.accent) }
                }
                Text(t.blurb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.ink.opacity(on ? 0.1 : 0.04)))
        }.buttonStyle(.plain)
    }
}

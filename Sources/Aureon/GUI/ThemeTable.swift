import Foundation

// The colours of every theme, as data: one table, no code per theme. A family has a dark half and (except AMOLED) a light half; each half is ten colours.
// The numbers were checked together: text on the window and the surfaces reads at 7:1 or better, secondary text at 4.5:1, tertiary text at 3:1, the accent at
// 3:1 and the label on a solid accent at 4.5:1.

/// The ten colours of one half of a family (hex, 0xRRGGBB).
struct ThemeTokens: Equatable {
    var bg: UInt32          // the window behind everything: top bar and rail
    var surface: UInt32     // the main panel: pages and the player bar
    var surface2: UInt32    // raised surfaces: cards, chips, the selected rail item
    var surface3: UInt32    // the next step up: pressed and hovered raised surfaces
    var line: UInt32        // dividers
    var text: UInt32
    var textSecondary: UInt32
    var textTertiary: UInt32
    var accent: UInt32
    var onAccent: UInt32
}

struct FamilySpec {
    let id: String
    let name: String
    let blurb: String
    let dark: ThemeTokens
    /// Nil for a family that has no light half (AMOLED): in Light mode it shows Graphite's light half.
    let light: ThemeTokens?
}

enum ThemeTable {
    private static func t(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, _ e: UInt32, _ f: UInt32, _ g: UInt32, _ h: UInt32, _ i: UInt32, _ j: UInt32) -> ThemeTokens {
        ThemeTokens(bg: a, surface: b, surface2: c, surface3: d, line: e, text: f, textSecondary: g, textTertiary: h, accent: i, onAccent: j)
    }

    /// AMOLED first (it is pinned at the top of the picker), then the others in the order they are shown.
    static let families: [FamilySpec] = [
        FamilySpec(id: "amoled", name: "AMOLED", blurb: "True black, for OLED screens. Dark only",
                   dark: t(0x000000, 0x0A0A0C, 0x121215, 0x1A1A1E, 0x26262B, 0xF5F5F7, 0xADB1B8, 0x898C92, 0x96C9FE, 0x06070A), light: nil),
        FamilySpec(id: "graphite", name: "Graphite", blurb: "Neutral charcoal with a clear blue",
                   dark: t(0x0D1014, 0x161A1F, 0x1E2227, 0x282C31, 0x34383E, 0xEDEEF1, 0xAFB1B5, 0x84868B, 0x89C3FE, 0x141619),
                   light: t(0xF4F7FB, 0xEEF0F4, 0xE5E8EC, 0xDCDEE2, 0xCBCED2, 0x181B1F, 0x4A4D53, 0x60636A, 0x0065B0, 0xF4F9FE)),
        FamilySpec(id: "midnight", name: "Midnight", blurb: "Deep navy with sky blue",
                   dark: t(0x070F20, 0x10192D, 0x172137, 0x202B42, 0x2C3850, 0xEAEFF8, 0xAAB1C0, 0x7E8697, 0x91C1FF, 0x0F1720),
                   light: t(0xF3F7FE, 0xE9F0FF, 0xE1E8F8, 0xD7DEEE, 0xC7CEDD, 0x121A2B, 0x424D64, 0x58637B, 0x0061BE, 0xF5F9FE)),
        FamilySpec(id: "ocean", name: "Ocean", blurb: "Deep teal with bright aqua",
                   dark: t(0x001319, 0x011E24, 0x06262D, 0x103038, 0x1D3D45, 0xE6F1F3, 0xA4B5B9, 0x768A8F, 0x28D6DF, 0x0A191A),
                   light: t(0xEAFAFE, 0xE2F4F9, 0xDAECF0, 0xD0E2E6, 0xC0D1D6, 0x061E24, 0x365259, 0x4C6970, 0x007176, 0xF1FBFB)),
        FamilySpec(id: "forest", name: "Forest", blurb: "Green-black with leaf green",
                   dark: t(0x061308, 0x0E1E11, 0x152619, 0x1E3022, 0x2B3D2E, 0xEAF1EB, 0xAAB4AB, 0x7E8A80, 0x7BD77F, 0x111811),
                   light: t(0xEFFAF1, 0xE8F4EA, 0xE0EBE2, 0xD6E1D8, 0xC6D1C8, 0x111E14, 0x415244, 0x57695A, 0x01791E, 0xF4FAF4)),
        FamilySpec(id: "mint", name: "Mint", blurb: "Dark pine with fresh mint",
                   dark: t(0x01140E, 0x071E18, 0x0E2720, 0x183129, 0x243E36, 0xE8F1EE, 0xA7B5B0, 0x7A8A85, 0x51DAA7, 0x0E1914),
                   light: t(0xECFBF5, 0xE5F4EF, 0xDDECE6, 0xD3E2DD, 0xC3D2CC, 0x0C1F19, 0x3C534B, 0x516961, 0x007654, 0xF3FBF7)),
        FamilySpec(id: "plum", name: "Plum", blurb: "Aubergine with pink",
                   dark: t(0x180A16, 0x231322, 0x2C1B2B, 0x372435, 0x443042, 0xF3ECF2, 0xB9ADB7, 0x8F818D, 0xF897E4, 0x1C131A),
                   light: t(0xFFF2FD, 0xF8ECF7, 0xF0E3EE, 0xE6D9E4, 0xD6C9D4, 0x231522, 0x594657, 0x6F5C6D, 0x983488, 0xFDF6FB)),
        FamilySpec(id: "violet", name: "Violet", blurb: "Indigo with lavender",
                   dark: t(0x110B20, 0x1B152C, 0x231C36, 0x2D2642, 0x3A334F, 0xEFEDF8, 0xB2AEC0, 0x878397, 0xBCB2FF, 0x161421),
                   light: t(0xF7F5FF, 0xF1EDFE, 0xE9E5F7, 0xDFDBED, 0xCECBDD, 0x1C172B, 0x4F4863, 0x655E7B, 0x6649BE, 0xF8F7FF)),
        FamilySpec(id: "rose", name: "Rose", blurb: "Wine red with soft rose",
                   dark: t(0x1B090D, 0x281217, 0x31191F, 0x3C2329, 0x4A2F35, 0xF6EBED, 0xBDACAF, 0x948084, 0xFE9EAD, 0x1E1214),
                   light: t(0xFFF4F6, 0xFDEBEE, 0xF5E3E6, 0xEBD9DC, 0xDAC9CC, 0x271419, 0x5F454A, 0x765B60, 0xAF234C, 0xFFF6F7)),
        FamilySpec(id: "ember", name: "Ember", blurb: "Burnt umber with glowing orange",
                   dark: t(0x1D0903, 0x29120A, 0x331A11, 0x3E231A, 0x4C3026, 0xF7ECE8, 0xBFADA7, 0x95817A, 0xFFA47A, 0x1F130D),
                   light: t(0xFFF4F1, 0xFEECE5, 0xF6E3DD, 0xECD9D3, 0xDCC9C3, 0x29150D, 0x61463C, 0x785C52, 0xA24100, 0xFFF6F3)),
        FamilySpec(id: "cocoa", name: "Cocoa", blurb: "Dark roast with apricot",
                   dark: t(0x180C05, 0x23160D, 0x2D1E14, 0x37271D, 0x443429, 0xF4EDE9, 0xB9AFA8, 0x8F847C, 0xF3AD66, 0x1B150F),
                   light: t(0xFEF5EF, 0xF9EEE7, 0xF0E5DF, 0xE6DCD5, 0xD6CBC5, 0x231810, 0x59493F, 0x705F55, 0x8E5300, 0xFDF7F2)),
        FamilySpec(id: "dune", name: "Dune", blurb: "Sand and gold",
                   dark: t(0x150E03, 0x1F180A, 0x282111, 0x322A1A, 0x3F3726, 0xF1EEE8, 0xB5B1A7, 0x8B867A, 0xDCBA5C, 0x19160E),
                   light: t(0xFBF6EC, 0xF5F0E5, 0xECE7DD, 0xE3DDD3, 0xD2CDC3, 0x201A0D, 0x544C3C, 0x6A6252, 0x7A6001, 0xFBF8F1)),
        FamilySpec(id: "slate", name: "Slate", blurb: "Cool steel with ice blue",
                   dark: t(0x091016, 0x121B21, 0x19232A, 0x222D34, 0x2F3A41, 0xEBEFF2, 0xACB2B7, 0x80878D, 0x7AC8F5, 0x12171A),
                   light: t(0xF1F8FD, 0xEAF1F6, 0xE2E9EE, 0xD8DFE4, 0xC8CFD4, 0x141C21, 0x444F56, 0x5A656D, 0x006C97, 0xF2FAFE)),
    ]

    /// The family a light request falls back to when the family has no light half.
    static let lightFallback = "graphite"
}

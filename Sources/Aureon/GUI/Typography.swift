import SwiftUI
import AppKit
import CoreText

// The type system, in one place. One voice for reading and one for numbers:
//
//   Figtree (bundled, SIL Open Font License; Avenir Next stands in when it is not installed)
//                   everything that is read: titles, names, rows, buttons. Regular by default, Medium for titles and emphasis, never bold.
//                   The weight is a setting (Light, Regular, Medium) and so is the text size.
//   SF Mono, tabular figures
//                   every technical readout: sample rate, bit depth, time, dB, BPM, counts
//
// Micro-labels are small and open-tracked. Call sites use the voices below (`Typo.sans(13, .medium)`, `Typo.mono(11)`, `Typo.serif(20)`) or the
// roles, never `.system(size:)` directly. `Typo.serif` is kept for titles and names: it is the same family, set one step heavier. The roles are
// computed, so they follow the weight and size settings the next time a view is built (the root view is rebuilt when either changes).

/// The families the interface can be set in. The system font (SF Pro) is always there; the others are fonts bundled with the app (each with its own licence file in
/// `Contents/Resources/Fonts`) and are offered only when their file is there. Chillax is added by a build that has it in a local folder that is not part of the
/// source (`Packaging/Fonts-local`), and is never in the repository.
enum FontFamily: String, CaseIterable, Identifiable, Codable {
    case system, figtree, plusJakartaSans, dmSans, manrope, inter, chillax
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"; case .figtree: "Figtree"; case .plusJakartaSans: "Plus Jakarta Sans"; case .dmSans: "DM Sans"; case .manrope: "Manrope"; case .inter: "Inter"; case .chillax: "Chillax"
        }
    }
    /// The family as the font system knows it (nil for the system font).
    var name: String? { self == .system ? nil : title }
    /// What the licence is called, for the Settings line.
    var licence: String { self == .system ? "SF Pro, part of macOS" : (self == .chillax ? "ITF Free Font License" : "SIL Open Font License") }
    /// Whether it can be used: the system font always, the others when their font is bundled (or installed).
    var isAvailable: Bool { name.map(TypeFace.has) ?? true }
    static var available: [FontFamily] { allCases.filter(\.isAvailable) }
    /// The licence file kept with the font in `Packaging/Fonts` (nil for the system font and for Chillax, which is never in the repository).
    var licenceFile: String? {
        switch self { case .system, .chillax: nil; case .figtree: "OFL.txt"; default: "OFL-" + title.replacingOccurrences(of: " ", with: "") + ".txt" }
    }
}

/// Finding and registering the interface font.
enum TypeFace {
    static let preferred = "Figtree"
    static let fallback = "Avenir Next"

    /// Registers every font file shipped in the app's `Fonts` folder (and, when running from the build folder, `Packaging/Fonts`) for this process.
    /// Safe to call more than once. Returns how many files were registered.
    @discardableResult
    static func registerBundled(bundle: Bundle = .main, extraFolders: [URL] = []) -> Int {
        var folders = extraFolders
        if let r = bundle.resourceURL { folders.append(r.appendingPathComponent("Fonts")) }
        var n = 0
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
                var err: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(f as CFURL, .process, &err) { n += 1 }
            }
        }
        cached = nil; known = [:]
        return n
    }

    /// The bundled fonts are registered the first time a family is asked for, before any view is built. When the app runs from a build folder
    /// (no bundle), `AUREON_FONTS`, `Packaging/Fonts` or `Packaging/Fonts-local` in the working directory is read instead.
    private static let registeredOnce: Int = {
        var extra: [URL] = []
        if let e = ProcessInfo.processInfo.environment["AUREON_FONTS"] { extra.append(URL(fileURLWithPath: e)) }
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        extra.append(here.appendingPathComponent("Packaging/Fonts")); extra.append(here.appendingPathComponent("Packaging/Fonts-local"))
        return registerBundled(extraFolders: extra)
    }()

    nonisolated(unsafe) private static var cached: Bool?
    nonisolated(unsafe) private static var known: [String: Bool] = [:]
    /// Whether a family can be found (bundled or installed).
    static func has(_ family: String) -> Bool {
        _ = registeredOnce
        if let k = known[family] { return k }
        let ok = NSFont(name: family, size: 12) != nil || NSFontManager.shared.availableFontFamilies.contains(family)
        known[family] = ok
        return ok
    }
    /// Whether Figtree can be found (bundled or installed).
    static var hasPreferred: Bool {
        _ = registeredOnce
        if let c = cached { return c }
        let ok = has(preferred)
        cached = ok
        return ok
    }
    /// The family in use: the one chosen in Settings when it can be found, else Figtree, else the system font.
    static var chosen: FontFamily {
        let want = FontFamily(rawValue: Look.current.fontFamily) ?? .figtree
        if want.isAvailable { return want }
        return hasPreferred ? .figtree : .system
    }
    /// The name of the family in use (the system font is "System"; Avenir Next stands in only when neither Figtree nor a choice is there).
    static var family: String { chosen == .system && !hasPreferred && Look.current.fontFamily != FontFamily.system.rawValue ? fallback : chosen.title }
}

enum Typo {
    // MARK: voices

    /// The sizes the interface uses. Odd sizes asked for are rounded to the nearest step.
    static let scale: [CGFloat] = [9, 10, 11, 12, 13, 14.5, 16, 18, 20, 22, 24, 28, 34, 44, 56]
    static func snap(_ size: CGFloat) -> CGFloat { scale.min { abs($0 - size) < abs($1 - size) } ?? size }
    /// A designed size with the text-size setting applied.
    static func sized(_ size: CGFloat) -> CGFloat { snap(size) * CGFloat(Look.current.textScale) }

    /// Sans: the weight the user chose is "regular"; "medium" (and anything heavier) is one step above it, never bold. Light only when asked for.
    static func sansWeight(_ w: Font.Weight, _ look: LookSettings = Look.current) -> Font.Weight {
        switch w {
        case .black, .heavy, .bold, .semibold, .medium: return look.weight.emphasis
        case .ultraLight, .thin, .light: return .light
        default: return look.weight.base
        }
    }
    /// Titles and names (the old serif voice): one step heavier than running text, so they stand out without growing.
    static func titleWeight(_ w: Font.Weight, size: CGFloat, _ look: LookSettings = Look.current) -> Font.Weight {
        switch w {
        case .ultraLight, .thin, .light: return size >= 20 ? look.weight.emphasis : look.weight.base
        case .black, .heavy, .bold, .semibold, .medium: return look.weight.emphasis
        default: return size >= 20 ? look.weight.emphasis : look.weight.base
        }
    }
    static func monoWeight(_ w: Font.Weight, size: CGFloat) -> Font.Weight {
        switch w {
        case .black, .heavy, .bold, .semibold: return .medium
        case .ultraLight, .thin: return .light
        default: return size >= 20 ? .light : w
        }
    }

    /// The interface face at a final size and weight, in the family chosen in Settings. The system font and the bundled variable fonts have every weight; Avenir
    /// Next (which stands in only when Figtree cannot be found) has no Light and is read in Regular.
    static func face(_ size: CGFloat, _ w: Font.Weight) -> Font {
        let c = TypeFace.chosen
        if c == .system { return TypeFace.hasPreferred || Look.current.fontFamily == FontFamily.system.rawValue ? .system(size: size, weight: w) : .custom(TypeFace.fallback, size: size).weight(w == .light ? .regular : w) }
        if let n = c.name { return .custom(n, size: size).weight(w) }
        return .custom(TypeFace.fallback, size: size).weight(w == .light ? .regular : w)
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { let s = snap(size); return face(s * CGFloat(Look.current.textScale), titleWeight(weight, size: s)) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { face(sized(size), sansWeight(weight)) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { let s = snap(size); return .system(size: s * CGFloat(Look.current.textScale), weight: monoWeight(weight, size: s), design: .monospaced).monospacedDigit() }

    // MARK: roles

    static func title(_ size: CGFloat = 44) -> Font { serif(size, .medium) }
    static var artist: Font { serif(20, .regular) }
    static var album: Font { sans(14.5, .regular).italic() }
    static var kicker: Font { sans(10, .regular) }
    static var composer: Font { sans(14.5, .regular).italic() }
    static var readout: Font { mono(11, .regular) }

    // The system text styles, mapped onto the voices (`.font(.caption)` became `.font(Typo.caption)`).
    static var largeTitle: Font { serif(44, .medium) }
    static var t1: Font { serif(28, .medium) }
    static var t2: Font { serif(22, .medium) }
    static var t3: Font { serif(16, .medium) }
    static var headline: Font { sans(13, .medium) }
    static var body: Font { sans(13) }
    static var callout: Font { sans(13) }
    static var subheadline: Font { sans(12) }
    static var footnote: Font { sans(11) }
    static var caption: Font { sans(11) }
    static var caption2: Font { sans(10) }

    // MARK: tracking

    /// Tight tracking for running text; micro-labels open up a little.
    static let bodyTracking: CGFloat = -0.05
    static let microTracking: CGFloat = 1.2
}

/// A font with the tracking and case that belong to it.
struct TypoStyle {
    let font: Font
    var tracking: CGFloat = Typo.bodyTracking
    var uppercase = false

    static var display: TypoStyle { TypoStyle(font: Typo.serif(56, .medium), tracking: -0.6) }
    static var pageTitle: TypoStyle { TypoStyle(font: Typo.serif(44, .medium), tracking: -0.5) }
    static var heading: TypoStyle { TypoStyle(font: Typo.serif(22, .medium), tracking: -0.2) }
    static var itemTitle: TypoStyle { TypoStyle(font: Typo.sans(14.5, .medium)) }
    static var body: TypoStyle { TypoStyle(font: Typo.sans(13)) }
    static var secondary: TypoStyle { TypoStyle(font: Typo.sans(12)) }
    static var label: TypoStyle { TypoStyle(font: Typo.sans(10, .medium), tracking: Typo.microTracking, uppercase: true) }
    static var labelMono: TypoStyle { TypoStyle(font: Typo.mono(10, .regular), tracking: 1.0, uppercase: true) }
    static var readout: TypoStyle { TypoStyle(font: Typo.mono(11, .regular), tracking: 0) }
}

extension View {
    func typo(_ s: TypoStyle) -> some View {
        font(s.font).tracking(s.tracking).textCase(s.uppercase ? .uppercase : nil)
    }

    /// Small, upper-case, tracked sans: section headings, kickers and column titles.
    func microLabel() -> some View { typo(.label) }

    /// The same label in SF Mono, for labels that are themselves technical ("24-BIT", "ON AIR").
    func microMono() -> some View { typo(.labelMono) }

    func kicker() -> some View { typo(.label) }
}

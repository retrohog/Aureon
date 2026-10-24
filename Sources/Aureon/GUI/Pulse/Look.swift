import SwiftUI

// The adjustable parts of the look, in one place. Every number is 0…1 with a sensible middle; the tokens (type, spacing, surfaces, edges, the
// backdrop, motion) read them through `Look.current`, so a page never has to know about them. They are saved as one record and changed in
// Settings → Appearance. What the user can see change is shown live while that page is open and nowhere else.

/// How much room the interface takes. Compact is the default: smaller covers, tighter rows. Comfortable is roomier.
enum UIDensity: String, CaseIterable, Identifiable, Codable {
    case compact, comfortable
    var id: String { rawValue }
    var title: String { self == .compact ? "Compact" : "Comfortable" }
    var hint: String { self == .compact ? "Smaller covers and tighter rows: more of the collection on screen" : "Larger covers and roomier rows" }
    /// Multiplier on cover sizes and grid cells.
    var cover: CGFloat { self == .compact ? 0.82 : 1 }
    /// Multiplier on the vertical rhythm of lists and shelves.
    var rhythm: CGFloat { self == .compact ? 0.88 : 1 }
    /// Height of one song row.
    var rowHeight: CGFloat { self == .compact ? 44 : 54 }
}

/// The weight the interface is set in. Regular by default; nothing heavier than Medium for emphasis, ever.
enum TypeWeight: String, CaseIterable, Identifiable, Codable {
    case light, regular, medium
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var base: Font.Weight { switch self { case .light: .light; case .regular: .regular; case .medium: .medium } }
    /// Emphasis sits one step above the base, capped at Medium.
    var emphasis: Font.Weight { switch self { case .light: .regular; case .regular, .medium: .medium } }
}

/// How large the lyrics are set in Now Playing (Large is the designed size).
enum LyricSize: String, CaseIterable, Identifiable, Codable {
    case medium, large, huge
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scale: CGFloat { switch self { case .medium: 0.85; case .large: 1; case .huge: 1.2 } }
}

/// The seek bar of Now Playing: each layout's own, or one choice for all.
enum SeekChoice: String, CaseIterable, Identifiable, Codable {
    case layout, waveform, line
    var id: String { rawValue }
    var title: String { switch self { case .layout: "Layout's own"; case .waveform: "Waveform"; case .line: "Line" } }
}

/// How often a shooting star crosses the Starlight backdrop.
enum ShootingStars: String, CaseIterable, Identifiable, Codable {
    case off, rare, sometimes, often
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// The wait between two stars, in seconds (min, max); nil when there are none.
    var interval: (min: Double, max: Double)? {
        switch self { case .off: nil; case .rare: (25, 70); case .sometimes: (10, 28); case .often: (4, 11) }
    }
}

/// The colour of the stars.
enum StarTint: String, CaseIterable, Identifiable, Codable {
    case white, accent, cover
    var id: String { rawValue }
    var title: String { switch self { case .white: "White"; case .accent: "Accent"; case .cover: "Cover" } }
}

/// How much is said about the format of a song next to it.
enum FormatTagMode: String, CaseIterable, Identifiable, Codable {
    case compact, detailed
    var id: String { rawValue }
    var title: String { self == .compact ? "Compact" : "Detailed" }
    var hint: String { self == .compact ? "Quality class, codec and the rate: one short line" : "Source, processing and output in aligned groups" }
}

struct StarlightSettings: Codable, Equatable {
    /// How many stars and how bright the sky is (0 = sparse, 1 = dense).
    var intensity = 0.55
    /// How fast the sky drifts and twinkles (0 = nearly still, 1 = lively).
    var motion = 0.4
    /// How much the low notes of the music move the sky (0 = not at all).
    var reaction = 0.35
    var reacts = true
    var shooting = ShootingStars.rare
    var twinkle = true
    var tint = StarTint.white

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = StarlightSettings()
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? d.intensity
        motion = try c.decodeIfPresent(Double.self, forKey: .motion) ?? d.motion
        reaction = try c.decodeIfPresent(Double.self, forKey: .reaction) ?? d.reaction
        reacts = try c.decodeIfPresent(Bool.self, forKey: .reacts) ?? d.reacts
        shooting = try c.decodeIfPresent(ShootingStars.self, forKey: .shooting) ?? d.shooting
        twinkle = try c.decodeIfPresent(Bool.self, forKey: .twinkle) ?? d.twinkle
        tint = try c.decodeIfPresent(StarTint.self, forKey: .tint) ?? d.tint
    }
    private enum Keys: String, CodingKey { case intensity, motion, reaction, reacts, shooting, twinkle, tint }
}

struct LookSettings: Codable, Equatable {
    var density = UIDensity.compact
    var weight = TypeWeight.regular
    /// Text size as a factor of the designed sizes (0.85…1.3).
    var textScale = 1.0
    /// Light themes only: from a quiet grey (0) to paper (1); 0.35 is the designed tone.
    var lightBrightness = 0.35
    /// The accent chosen by the user as "RRGGBB"; nil keeps each theme's own.
    var accentHex: String?
    /// How strong hairlines, outlines and separators are.
    var edge = 0.5
    /// The Album backdrop: how far the cover's colours reach into the page.
    var backdrop = 0.62
    /// How fast the interface animates (0 = unhurried, 1 = brisk).
    var motion = 0.5
    var formatTags = FormatTagMode.detailed
    /// Tags beside each song in the Collection lists (compact).
    var rowTags = true
    var starlight = StarlightSettings()
    /// The Now Playing layout chosen in Settings (an id of `NowPlayingLayout`), and whether synchronised lyrics are shown in it.
    var nowPlayingLayout = "stage"
    var showLyrics = true
    var lyricSize = LyricSize.large
    var seekChoice = SeekChoice.layout
    /// On Now Playing: the add-to-playlist button beside the heart, the credits under the artist, the format tags and the signal path.
    var showPlaylistButton = true
    var showCredits = true
    var showSignalTags = true
    /// The mini player and the menu bar item.
    var mini = MiniSettings()
    /// What is remembered between launches, and what happens to playback when Aureon opens.
    var memory = MemorySettings()

    static let defaults = LookSettings()
    static let textScaleRange = 0.85...1.3

    init() {}
    /// Saved records from an earlier version (missing keys) read with the defaults in their place.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = LookSettings()
        density = try c.decodeIfPresent(UIDensity.self, forKey: .density) ?? d.density
        weight = try c.decodeIfPresent(TypeWeight.self, forKey: .weight) ?? d.weight
        textScale = try c.decodeIfPresent(Double.self, forKey: .textScale) ?? d.textScale
        lightBrightness = try c.decodeIfPresent(Double.self, forKey: .lightBrightness) ?? d.lightBrightness
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex)
        edge = try c.decodeIfPresent(Double.self, forKey: .edge) ?? d.edge
        backdrop = try c.decodeIfPresent(Double.self, forKey: .backdrop) ?? d.backdrop
        motion = try c.decodeIfPresent(Double.self, forKey: .motion) ?? d.motion
        formatTags = try c.decodeIfPresent(FormatTagMode.self, forKey: .formatTags) ?? d.formatTags
        rowTags = try c.decodeIfPresent(Bool.self, forKey: .rowTags) ?? d.rowTags
        starlight = try c.decodeIfPresent(StarlightSettings.self, forKey: .starlight) ?? d.starlight
        nowPlayingLayout = try c.decodeIfPresent(String.self, forKey: .nowPlayingLayout) ?? d.nowPlayingLayout
        showLyrics = try c.decodeIfPresent(Bool.self, forKey: .showLyrics) ?? d.showLyrics
        lyricSize = try c.decodeIfPresent(LyricSize.self, forKey: .lyricSize) ?? d.lyricSize
        seekChoice = try c.decodeIfPresent(SeekChoice.self, forKey: .seekChoice) ?? d.seekChoice
        showPlaylistButton = try c.decodeIfPresent(Bool.self, forKey: .showPlaylistButton) ?? d.showPlaylistButton
        showCredits = try c.decodeIfPresent(Bool.self, forKey: .showCredits) ?? d.showCredits
        showSignalTags = try c.decodeIfPresent(Bool.self, forKey: .showSignalTags) ?? d.showSignalTags
        mini = try c.decodeIfPresent(MiniSettings.self, forKey: .mini) ?? d.mini
        memory = try c.decodeIfPresent(MemorySettings.self, forKey: .memory) ?? d.memory
    }
    private enum Keys: String, CodingKey { case density, weight, textScale, lightBrightness, accentHex, edge, backdrop, motion, formatTags, rowTags, starlight, nowPlayingLayout, showLyrics, lyricSize, seekChoice, showPlaylistButton, showCredits, showSignalTags, mini, memory }

    static let storageKey = "aureon.look.pulse"

    /// The saved record (missing keys take their defaults), with `AUREON_LOOK="density=comfortable,weight=medium,accent=3FA7FF,light=0.5,tags=compact"` laid over it.
    static func load(_ d: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> LookSettings {
        var s = d.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(LookSettings.self, from: $0) } ?? LookSettings()
        if let e = environment["AUREON_LOOK"] { s.apply(environment: e) }
        return s.clamped()
    }

    mutating func apply(environment e: String) {
        for part in e.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let v = Double(kv[1])
            switch kv[0] {
            case "density": if let x = UIDensity(rawValue: kv[1]) { density = x }
            case "weight": if let x = TypeWeight(rawValue: kv[1]) { weight = x }
            case "scale": if let v { textScale = v }
            case "light": if let v { lightBrightness = v }
            case "accent": accentHex = kv[1].isEmpty || kv[1] == "none" ? nil : kv[1]
            case "edge": if let v { edge = v }
            case "backdrop": if let v { backdrop = v }
            case "motion": if let v { motion = v }
            case "tags": if let t = FormatTagMode(rawValue: kv[1]) { formatTags = t }
            case "rowtags": rowTags = kv[1] != "0"
            case "star": if let v { starlight.intensity = v }
            case "starmotion": if let v { starlight.motion = v }
            case "starreact": if let v { starlight.reaction = v; starlight.reacts = v > 0 }
            case "shooting": if let x = ShootingStars(rawValue: kv[1]) { starlight.shooting = x }
            case "twinkle": starlight.twinkle = kv[1] != "0"
            case "tint": if let x = StarTint(rawValue: kv[1]) { starlight.tint = x }
            case "np": nowPlayingLayout = kv[1]
            case "lyrics": showLyrics = kv[1] != "0"
            case "lyricsize": if let x = LyricSize(rawValue: kv[1]) { lyricSize = x }
            case "seek": if let x = SeekChoice(rawValue: kv[1]) { seekChoice = x }
            case "playlistbutton": showPlaylistButton = kv[1] != "0"
            case "credits": showCredits = kv[1] != "0"
            case "signaltags": showSignalTags = kv[1] != "0"
            case "mini": if let x = MiniLayout(rawValue: kv[1]) { mini.layout = x }
            case "minibg": if let x = MiniBackground(rawValue: kv[1]) { mini.background = x }
            case "menubar": mini.menuBar.show = kv[1] != "0"
            case "resume": if let x = ResumeMode(rawValue: kv[1]) { memory.resume = x }
            default: break
            }
        }
    }

    func clamped() -> LookSettings {
        func c(_ v: Double) -> Double { min(1, max(0, v)) }
        var s = self
        s.textScale = min(Self.textScaleRange.upperBound, max(Self.textScaleRange.lowerBound, textScale))
        s.lightBrightness = c(lightBrightness); s.edge = c(edge); s.backdrop = c(backdrop); s.motion = c(motion)
        s.starlight.intensity = c(starlight.intensity); s.starlight.motion = c(starlight.motion); s.starlight.reaction = c(starlight.reaction)
        s.mini.strength = c(mini.strength); s.mini.opacity = min(1, max(0.4, mini.opacity))
        if !MenuBarSettings.autoCloseChoices.contains(mini.menuBar.autoCloseSeconds) { s.mini.menuBar.autoCloseSeconds = MenuBarSettings().autoCloseSeconds }
        if let hex = accentHex, Look.color(hex: hex) == nil { s.accentHex = nil }
        return s
    }

    func save(_ d: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.storageKey) } }
}

/// The values in force, read by the tokens while views are built. Written on the main thread by `PlayerModel`.
enum Look {
    nonisolated(unsafe) static var current = LookSettings()

    /// `a` to `b` by `t`.
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// "RRGGBB" (with or without a leading #) as a colour; nil if it is not six hex digits.
    static func color(hex: String) -> RGB? {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Theme.rgbValue(v)
    }
    static func hex(_ c: RGB) -> String {
        func b(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", b(c.r), b(c.g), b(c.b))
    }

    /// The theme as it is shown: the chosen palette with the light brightness and the user's accent applied.
    static func themed(_ t: Theme, _ s: LookSettings = Look.current) -> Theme {
        t.adjusted(lightBrightness: s.lightBrightness).withAccent(s.accentHex.flatMap(color(hex:)))
    }

    // MARK: derived tokens

    /// Hairlines and outlines: the ink at this strength (0.5 on the slider keeps 14 % / 18 %).
    static func ruleOpacity(light: Bool, _ s: LookSettings = Look.current) -> Double {
        let base = light ? 0.18 : 0.14
        return base * lerp(0.5, 1.5, s.edge)
    }
    /// Outlines of controls (buttons, segmented strips, fields).
    static func outlineOpacity(_ s: LookSettings = Look.current) -> Double { 0.28 * lerp(0.5, 1.5, s.edge) }

    /// Seconds of an animation: the nominal length scaled by the motion setting (0.5 keeps it, 1 is half as long, 0 is half as long again).
    static func duration(_ nominal: Double, _ s: LookSettings = Look.current) -> Double { nominal * lerp(1.5, 0.5, s.motion) }
}

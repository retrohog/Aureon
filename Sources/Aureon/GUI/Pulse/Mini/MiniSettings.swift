import SwiftUI

// How the mini player and the menu bar item are set up. One saved record (inside the look), with defaults for everything, so a record from an earlier
// version still reads. The mini player itself is in MiniWindow.swift, its layouts in MiniViews.swift and its Settings page in MiniSettingsView.swift.

/// The ways the mini player can look. The popover lives under the menu bar item; the rest are windows that float.
enum MiniLayout: String, CaseIterable, Identifiable, Codable {
    case bar, strip, card, cardLyrics, popover
    var id: String { rawValue }
    var title: String {
        switch self { case .bar: "Compact bar"; case .strip: "Thin strip"; case .card: "Card"; case .cardLyrics: "Card with lyrics"; case .popover: "Menu bar popover" }
    }
    var blurb: String {
        switch self {
        case .bar: "Cover, title, tags and controls in one bar."
        case .strip: "One line that sits on the edge of a screen."
        case .card: "Large cover and full controls in a small window."
        case .cardLyrics: "Narrow window with the lyric line in view."
        case .popover: "Lives in the menu bar, opens on click."
        }
    }
    /// The size of the window or popover.
    var size: CGSize {
        switch self { case .bar: CGSize(width: 520, height: 96); case .strip: CGSize(width: 520, height: 48); case .card: CGSize(width: 380, height: 620)
                      case .cardLyrics: CGSize(width: 260, height: 620); case .popover: CGSize(width: 340, height: 236) }
    }
    var cornerRadius: CGFloat { switch self { case .bar: 16; case .strip: 14; case .card, .cardLyrics: 22; case .popover: 16 } }
    /// Whether it is a window (the others are shown from the menu bar item).
    var isWindow: Bool { self != .popover }
}

enum MiniBackground: String, CaseIterable, Identifiable, Codable {
    case solid, gradient, blur
    var id: String { rawValue }
    var title: String { switch self { case .solid: "Solid"; case .gradient: "Gradient"; case .blur: "Blur and glow" } }
}

enum MenuBarShows: String, CaseIterable, Identifiable, Codable {
    case logo, logoTitle, title
    var id: String { rawValue }
    var title: String { switch self { case .logo: "Logo"; case .logoTitle: "Logo + title"; case .title: "Title" } }
}

enum MenuBarOpenOn: String, CaseIterable, Identifiable, Codable {
    case click, hover
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct MenuBarSettings: Codable, Equatable {
    var show = false
    var shows = MenuBarShows.logoTitle
    var openOn = MenuBarOpenOn.click
    /// A click anywhere else closes the popover.
    var closeOnOutsideClick = true
    /// Seconds until it closes by itself; 0 = never.
    var autoCloseSeconds = 5
    /// The countdown waits while the pointer is over the popover.
    var keepOpenWhileOver = true

    static let autoCloseChoices = [0, 3, 5, 10, 30]
    static func label(_ s: Int) -> String { s == 0 ? "Never" : "\(s) s" }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = MenuBarSettings()
        show = try c.decodeIfPresent(Bool.self, forKey: .show) ?? d.show
        shows = try c.decodeIfPresent(MenuBarShows.self, forKey: .shows) ?? d.shows
        openOn = try c.decodeIfPresent(MenuBarOpenOn.self, forKey: .openOn) ?? d.openOn
        closeOnOutsideClick = try c.decodeIfPresent(Bool.self, forKey: .closeOnOutsideClick) ?? d.closeOnOutsideClick
        autoCloseSeconds = try c.decodeIfPresent(Int.self, forKey: .autoCloseSeconds) ?? d.autoCloseSeconds
        keepOpenWhileOver = try c.decodeIfPresent(Bool.self, forKey: .keepOpenWhileOver) ?? d.keepOpenWhileOver
    }
    private enum Keys: String, CodingKey { case show, shows, openOn, closeOnOutsideClick, autoCloseSeconds, keepOpenWhileOver }
}

struct MiniSettings: Codable, Equatable {
    var layout = MiniLayout.bar
    var background = MiniBackground.gradient
    /// How strong the gradient, blur and glow are (0…1).
    var strength = 0.6
    var opacity = 0.92
    var alwaysOnTop = true
    var formatTags = true
    var onEveryDesktop = false
    var rememberPosition = true
    /// The floating player stays open when the popover closes.
    var keepFloating = true
    var menuBar = MenuBarSettings()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = MiniSettings()
        layout = try c.decodeIfPresent(MiniLayout.self, forKey: .layout) ?? d.layout
        background = try c.decodeIfPresent(MiniBackground.self, forKey: .background) ?? d.background
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? d.alwaysOnTop
        formatTags = try c.decodeIfPresent(Bool.self, forKey: .formatTags) ?? d.formatTags
        onEveryDesktop = try c.decodeIfPresent(Bool.self, forKey: .onEveryDesktop) ?? d.onEveryDesktop
        rememberPosition = try c.decodeIfPresent(Bool.self, forKey: .rememberPosition) ?? d.rememberPosition
        keepFloating = try c.decodeIfPresent(Bool.self, forKey: .keepFloating) ?? d.keepFloating
        menuBar = try c.decodeIfPresent(MenuBarSettings.self, forKey: .menuBar) ?? d.menuBar
    }
    private enum Keys: String, CodingKey { case layout, background, strength, opacity, alwaysOnTop, formatTags, onEveryDesktop, rememberPosition, keepFloating, menuBar }

    /// The window opacity kept where it can still be seen.
    var clampedOpacity: Double { min(1, max(0.4, opacity)) }

    /// Where a window of this size goes when there is no remembered place: the top right of the visible screen, under the menu bar.
    static func defaultOrigin(size: CGSize, in visible: CGRect) -> CGPoint { CGPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24) }

    /// A remembered origin, brought back onto a screen if the display it was on is gone: `nil` when it is still fully usable as it was.
    static func onScreen(origin: CGPoint, size: CGSize, screens: [CGRect]) -> CGPoint? {
        let frame = CGRect(origin: origin, size: size)
        guard let best = screens.max(by: { $0.intersection(frame).width * $0.intersection(frame).height < $1.intersection(frame).width * $1.intersection(frame).height }) else { return nil }
        let seen = best.intersection(frame)
        if seen.width >= min(size.width, 120) && seen.height >= min(size.height, 40) { return nil }
        return CGPoint(x: min(max(origin.x, best.minX), best.maxX - size.width), y: min(max(origin.y, best.minY), best.maxY - size.height))
    }
}

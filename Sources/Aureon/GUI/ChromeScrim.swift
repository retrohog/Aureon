import SwiftUI

// The bar across the top must never show content sliding legibly under it. Pages scroll *under* the bar (they start below it, by a content inset)
// and the bar puts a scrim between: the theme's background at 92 % over a background blur, and a hairline along its lower edge that fades in only
// once content has scrolled under it. With Reduce Transparency the scrim is fully opaque and has no blur. One container and one modifier serve the
// rail, the sub-header and any sticky header; no page does its own.

/// Whether the page under the bar has scrolled (so content is beneath it). Set by the page's scroll view, read by the scrim.
@MainActor
final class ChromeState: ObservableObject {
    @Published var scrolled = false
}

/// The numbers of the scrim. Pure, so they are testable.
enum ScrimStyle {
    /// How much of the theme's background the scrim lays over what is behind it.
    static func tint(reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : 0.92 }
    static func usesBlur(reduceTransparency: Bool) -> Bool { !reduceTransparency }
    /// The hairline: nothing at the top of the page, fully there once content has scrolled under by 8 points.
    static func rule(offset: CGFloat) -> Double { Double(min(1, max(0, offset / 8))) }
    /// Whether the scrim is shown at all: while content is under it.
    static func visible(scrolledUnder: Bool) -> Bool { scrolledUnder }
}

/// The inset that pages keep clear at the top of the main panel: a margin, and the chips of a destination that has them.
enum ChromeInset {
    static let rail: CGFloat = 12
    static let subNav: CGFloat = 52
    /// The second line of chips (the tabs of Sound → Sound).
    static let thirdNav: CGFloat = 40
    static func height(hasSubNav: Bool, hasThirdNav: Bool = false) -> CGFloat { rail + (hasSubNav ? subNav : 0) + (hasThirdNav ? thirdNav : 0) }
}

private struct ChromeInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    /// How far the top of a page's scrolling content starts below the window's top edge (what the bar covers).
    var chromeInset: CGFloat {
        get { self[ChromeInsetKey.self] }
        set { self[ChromeInsetKey.self] = newValue }
    }
}

/// The scrim itself: background blur, the theme's colour at 92 %, and the lower hairline.
struct ScrimBackground: View {
    let scrolledUnder: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let on = ScrimStyle.visible(scrolledUnder: scrolledUnder)
        ZStack(alignment: .bottom) {
            if ScrimStyle.usesBlur(reduceTransparency: reduceTransparency) { Rectangle().fill(.regularMaterial) }
            Rectangle().fill(Brand.canvas.opacity(ScrimStyle.tint(reduceTransparency: reduceTransparency)))
            Rule().opacity(on ? 1 : 0)
        }
        .opacity(on ? 1 : 0)
        .animation(Motion.touch, value: on)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Puts the scrim behind a header: it appears once the content below has scrolled under it.
    func scrim(scrolledUnder: Bool) -> some View { background(ScrimBackground(scrolledUnder: scrolledUnder)) }

    /// A page's scroll view: its content starts below the bar (`chromeInset`) but scrolls under it, and it tells the scrim when it has.
    func underChrome(_ chrome: ChromeState, inset: CGFloat) -> some View {
        contentMargins(.top, inset, for: .scrollContent)
            .contentMargins(.top, inset, for: .scrollIndicators)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y > -g.contentInsets.top + 2 } action: { _, scrolled in
                if chrome.scrolled != scrolled { chrome.scrolled = scrolled }
            }
    }
}

/// The rail and the sub-header with the scrim behind them: the one container the top of every page uses.
struct ChromeBar<Content: View>: View {
    @EnvironmentObject var chrome: ChromeState
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .scrim(scrolledUnder: chrome.scrolled)
    }
}

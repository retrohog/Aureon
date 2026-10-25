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

    /// A page's scroll view: its content starts below the bar (`chromeInset`) but scrolls under it, it tells the scrim when it has, and where it is scrolled
    /// is remembered for the page (see `ScrollMemory`).
    func underChrome(_ chrome: ChromeState, inset: CGFloat) -> some View { modifier(UnderChrome(chrome: chrome, inset: inset)) }
}

/// Where each page was scrolled to, so a page opens where it was left (also after a restart). Plain storage, not observed: scrolling must not redraw anything.
final class ScrollMemory: @unchecked Sendable {
    static let shared = ScrollMemory()
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    /// How many pages are kept.
    static let limit = 40

    func offset(_ key: String) -> Double? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ key: String, _ y: Double) { lock.lock(); values[key] = y <= 1 ? nil : y; lock.unlock() }
    var all: [String: Double] {
        get { lock.lock(); defer { lock.unlock() }; return values }
        set { lock.lock(); values = Dictionary(uniqueKeysWithValues: newValue.prefix(Self.limit).map { ($0.key, $0.value) }); lock.unlock() }
    }
}

private struct ScrollKeyKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    /// Names the page for `ScrollMemory` (the page, and what is open on it).
    var scrollKey: String {
        get { self[ScrollKeyKey.self] }
        set { self[ScrollKeyKey.self] = newValue }
    }
}

private struct UnderChrome: ViewModifier {
    let chrome: ChromeState
    let inset: CGFloat
    @Environment(\.scrollKey) private var key
    @State private var position = ScrollPosition(edge: .top)
    @State private var restoring = true

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, inset, for: .scrollContent)
            .contentMargins(.top, inset, for: .scrollIndicators)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y > -g.contentInsets.top + 2 } action: { _, scrolled in
                if chrome.scrolled != scrolled { chrome.scrolled = scrolled }
            }
            .onScrollGeometryChange(for: Double.self) { g in Double(g.contentOffset.y) } action: { _, y in
                if !restoring, !key.isEmpty { ScrollMemory.shared.set(key, y) }
            }
            .onAppear {
                guard !key.isEmpty, let y = ScrollMemory.shared.offset(key) else { restoring = false; return }
                // after the page has laid itself out (a grid of covers is built as it is asked for)
                // (a settings page is laid out at once, so it is put back at once: nothing is seen to jump when the interface is rebuilt)
                let delay = key.hasPrefix(Tab.settings.rawValue + "|") ? 0.02 : 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { position.scrollTo(y: CGFloat(y)); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restoring = false } }
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

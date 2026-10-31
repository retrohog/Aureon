import SwiftUI

// One tab line for the whole interface: small tracked capitals, the active one in the ink, a gold line under it that glides to the next one.

struct TabLineItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
}

/// A chip: a pill with a title, filled with the ink when it is the chosen one. Used for the pages of a destination, filters and tabs.
struct PillChip: View {
    let title: String
    var on: Bool
    var height: CGFloat = 32
    var action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.sans(13, on ? .medium : .regular)).lineLimit(1)
                .foregroundStyle(on ? Brand.panel : Brand.ink)
                .padding(.horizontal, 14).frame(height: height)
                .background(Capsule().fill(on ? Brand.ink : (hover.v ? Brand.ink.opacity(0.14) : Brand.panel2)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .animation(Motion.touch, value: hover.v)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct TabLine<ID: Hashable>: View {
    let items: [TabLineItem<ID>]
    @Binding var selection: ID
    var tracking: CGFloat = 2
    var spacing: CGFloat = 8
    var height: CGFloat = 32
    var labelPrefix = "Tab"

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                PillChip(title: item.title, on: item.id == selection, height: height - 4) { selection = item.id }
                    .accessibilityLabel("\(labelPrefix) \(item.title)")
            }
        }
        .fixedSize()
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Switching tabs

/// How a change of tab is drawn: calmly, and in place. The page that leaves fades out as the one that arrives fades in, over the same spot, in a short ease-out.
/// Nothing slides, scales or blurs, and no layout is animated, so nothing large ever moves on the screen.
enum TabMotion {
    /// Short: the response to a click is there at once.
    static let duration = 0.18
    static let allowedDurations = 0.12...0.22
    static let animation = Animation.timingCurve(0.2, 0, 0, 1, duration: duration)        // ease-out

    /// Whether pages change with a fade or at once (a Settings choice; Reduce Motion gives the same quick fade).
    enum Mode: String, CaseIterable, Identifiable {
        case fade, none
        var id: String { rawValue }
        var title: String { self == .fade ? "Fade" : "None" }
        static func saved(_ raw: String?) -> Mode { raw.flatMap(Mode.init(rawValue:)) ?? .fade }
    }

    struct Plan: Equatable {
        var animated: Bool
        var duration: Double
        var animation: Animation? { animated ? TabMotion.animation : nil }
        static func == (a: Plan, b: Plan) -> Bool { a.animated == b.animated && a.duration == b.duration }
    }
    static func plan(mode: Mode) -> Plan { mode == .none ? Plan(animated: false, duration: 0) : Plan(animated: true, duration: duration) }
}

private struct PageTransitionsKey: EnvironmentKey { static let defaultValue = TabMotion.Mode.fade }
extension EnvironmentValues {
    var pageTransitions: TabMotion.Mode {
        get { self[PageTransitionsKey.self] }
        set { self[PageTransitionsKey.self] = newValue }
    }
}

/// The state of a tab switcher: the page on screen, the page leaving (at most one: a new change while one is running retargets at once), and how opaque each is.
/// A plain value type, so the logic can be tested without a window.
struct TabSwitchState<Tag: Hashable> {
    private(set) var incoming: Tag
    private(set) var outgoing: Tag?
    private(set) var generation = 0
    private(set) var opacities: [Tag: Double]
    /// Pages that arrived through a change (as opposed to the first one) build one turn of the run loop after they are placed, so the change starts at once.
    private(set) var deferred: Set<Tag> = []

    init(_ tag: Tag) { incoming = tag; opacities = [tag: 1] }

    /// Starts a change to `tag`. The page that was arriving (or on show) becomes the one leaving, from where it stands; any page already leaving is dropped.
    /// Returns false when `tag` is already on show. The arriving page starts clear: call `settle` to fade it in.
    mutating func switchTo(_ tag: Tag) -> Bool {
        guard tag != incoming else { return false }
        if let old = outgoing, old != tag { opacities[old] = nil }
        if outgoing == tag { outgoing = nil }               // coming back to the page that was leaving: it carries on from where it is
        outgoing = incoming; incoming = tag
        generation += 1
        if opacities[tag] == nil { opacities[tag] = 0; deferred.insert(tag) }
        return true
    }

    /// The target of the fade: the arriving page opaque, the leaving one clear.
    mutating func settle() {
        opacities[incoming] = 1
        if let out = outgoing { opacities[out] = 0 }
    }

    /// A change with no fade: the page is simply replaced.
    mutating func replace(with tag: Tag) {
        guard tag != incoming else { return }
        opacities = [tag: 1]; outgoing = nil; incoming = tag; deferred = []
        generation += 1
    }

    /// The change is over: the leaving page is gone from the tree.
    mutating func finish(generation g: Int) {
        guard g == generation, let out = outgoing else { return }
        opacities[out] = nil; outgoing = nil
    }
    mutating func built(_ tag: Tag) { deferred.remove(tag) }

    /// The pages in the tree, leaving first, so the arriving one is on top.
    var pages: [Tag] { (outgoing.map { [$0] } ?? []) + [incoming] }
    /// Only the page that is arriving (or on show) answers clicks, from the first moment of a change.
    func answersClicks(_ tag: Tag) -> Bool { tag == incoming }
    func opacity(_ tag: Tag) -> Double { opacities[tag] ?? 1 }
}

/// Draws `content(tag)` for the current `tag`, changing between pages with `TabMotion`. Used for the rail's pages, and for the panels of Now Playing and the
/// tabs of Sound: the same container, so every switch looks the same. Only opacity is animated.
struct TabSwitcher<Tag: Hashable, Content: View>: View {
    let tag: Tag
    @ViewBuilder let content: (Tag) -> Content
    @State private var state: TabSwitchState<Tag>
    @State private var started = 0
    @Environment(\.pageTransitions) private var mode

    init(tag: Tag, @ViewBuilder content: @escaping (Tag) -> Content) {
        self.tag = tag; self.content = content
        _state = State(initialValue: TabSwitchState(tag))
    }

    var body: some View {
        ZStack {
            ForEach(state.pages, id: \.self) { page in
                DeferredPage(deferred: state.deferred.contains(page), built: { state.built(page); begin(state.generation) }) { content(page) }
                    .opacity(state.opacity(page))
                    .allowsHitTesting(state.answersClicks(page))
                    .accessibilityHidden(!state.answersClicks(page))
                    .zIndex(state.answersClicks(page) ? 1 : 0)
            }
        }
        .onChangeCompat(of: tag) { _, new in change(to: new) }
    }

    private func change(to new: Tag) {
        let plan = TabMotion.plan(mode: HWPanel.snapshot ? .none : mode)
        var instant = Transaction(); instant.disablesAnimations = true
        guard plan.animated else {
            withTransaction(instant) { state.replace(with: new) }
            return
        }
        var changed = false
        withTransaction(instant) { changed = state.switchTo(new) }
        guard changed else { return }
        let g = state.generation
        // the arriving page is laid out (built, if it is new) before it starts to appear
        if !state.deferred.contains(new) { DispatchQueue.main.async { begin(g) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { begin(g) }          // a page that is slow to build does not hold the change up for long
    }

    /// Starts the fade of change `g` (once).
    private func begin(_ g: Int) {
        guard g == state.generation, started != g else { return }
        started = g
        withAnimation(TabMotion.animation) { state.settle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + TabMotion.duration + 0.05) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { state.finish(generation: g) }
        }
    }
}

/// A page whose content is built one turn of the run loop after the page is placed, when it arrives through a change: the change starts at once and a heavy
/// page fills in as it fades up. A page on show from the start is built straight away.
private struct DeferredPage<Content: View>: View {
    let deferred: Bool
    let built: () -> Void
    @ViewBuilder let content: Content
    @State private var ready = false

    var body: some View {
        Group {
            if ready || !deferred { content } else { Color.clear }
        }
        .onAppear { if deferred && !ready { DispatchQueue.main.async { ready = true; built() } } }
    }
}

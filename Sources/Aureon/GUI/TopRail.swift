import SwiftUI

// The slim rail across the top: the planet mark, five destinations in widely tracked small capitals with a champagne line under the one you are in,
// and the quick-find. On the Gallery it rests: it fades after a few seconds without the pointer, and returns with any movement or key.

/// Whether the interface is awake. Pointer movement and keys wake it; a few seconds of nothing lets the Gallery's controls and the rail fall away.
/// One timer, rescheduled lazily: a pointer move only records the time, so waking costs nothing per event.
@MainActor
final class IdleTracker: ObservableObject {
    @Published private(set) var awake = true
    /// Whether to stay awake whatever the time (not on the Gallery, paused, in tests and snapshots).
    var holdsAwake: () -> Bool = { false }
    static let delay: TimeInterval = 3.5
    /// Tests and snapshots show the whole interface (`AUREON_IDLE=1` asks a snapshot for the resting one).
    static let disabled: Bool = {
        let e = ProcessInfo.processInfo.environment
        return e["AUREON_IDLE"] == nil && (e["AUREON_TESTING"] != nil || e["AUREON_SNAPSHOT"] != nil)
    }()
    private var lastPoke = Date()
    private var timer: Timer?

    func poke() {
        lastPoke = Date()
        if !awake { withAnimation(Motion.glide) { awake = true } }
        if timer == nil { schedule(Self.delay) }
    }

    private func schedule(_ after: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        timer = nil
        let idle = Date().timeIntervalSince(lastPoke)
        if idle < Self.delay { schedule(Self.delay - idle); return }
        if Self.disabled || holdsAwake() { schedule(Self.delay); return }
        withAnimation(Motion.carpet) { awake = false }
    }

    /// Starts resting at once (a snapshot of the resting state).
    func rest() { withAnimation(Motion.carpet) { awake = false } }
}

/// The planet mark: a small world with its orbit, drawn with fine strokes. The only ornament of the interface.
struct PlanetMark: View {
    var size: CGFloat = 24
    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2), r = min(sz.width, sz.height) * 0.27
            let gold = Brand.accentText
            // the far half of the orbit passes behind the planet, the near half in front
            let orbit = CGRect(x: c.x - sz.width * 0.46, y: c.y - sz.height * 0.14, width: sz.width * 0.92, height: sz.height * 0.28)
            var ring = Path(ellipseIn: orbit)
            ring = ring.applying(CGAffineTransform(translationX: -c.x, y: -c.y).rotated(by: -.pi / 9).translatedBy(x: c.x, y: c.y))
            ctx.stroke(ring, with: .color(gold.opacity(0.55)), lineWidth: 0.75)
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.fill(disc, with: .color(Brand.canvas))
            ctx.fill(disc, with: .color(gold.opacity(0.14)))
            ctx.stroke(disc, with: .color(gold), lineWidth: 1)
            // a fine meridian across the planet, and the moon on the orbit
            var meridian = Path(); meridian.addArc(center: c, radius: r, startAngle: .degrees(-100), endAngle: .degrees(100), clockwise: false)
            meridian = meridian.applying(CGAffineTransform(translationX: -c.x, y: -c.y).scaledBy(x: 0.45, y: 1).translatedBy(x: c.x, y: c.y))
            ctx.stroke(meridian, with: .color(gold.opacity(0.6)), lineWidth: 0.5)
            let moon = CGPoint(x: c.x + sz.width * 0.40, y: c.y - sz.height * 0.14)
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - 1.6, y: moon.y - 1.6, width: 3.2, height: 3.2)), with: .color(gold))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Aureon")
    }
}

/// The rail.
struct TopRail: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var idle: IdleTracker
    @Namespace private var railLine

    private var resting: Bool { !idle.awake && m.tab == .player && !m.djMode }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Color.clear.frame(width: 84, height: 1)          // the window buttons are placed over the left of this row by `WindowChrome`
                NavButtons()
                PlanetMark(size: 28).padding(.leading, 8).help("Aureon")
                Spacer(minLength: 0)
            }
            HStack(spacing: 40) {
                ForEach([RailDestination.listen, .collection, .rooms, .atelier], id: \.self) { RailItem(destination: $0, line: railLine) }
            }
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                QuickPanelButton(anchor: .rail)
                AppearanceSwitch()
                QuickFindButton()
                RailGear()
            }
            .padding(.trailing, 16)
            // ⌥⌘D: the quick control panel
            Button { withAnimation(Motion.glide) { m.toggleQuickPanel(.rail) } } label: { Color.clear }
                .buttonStyle(.plain).keyboardShortcut("d", modifiers: [.option, .command]).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .frame(height: WindowChrome.band)
        .opacity(resting ? 0 : 1)
        .allowsHitTesting(!resting)
        .accessibilityElement(children: .contain)
    }
}

extension PlayerModel {
    /// The destination that is on screen. Diagnostics are a section of the settings page that belongs to the Atelier.
    var currentDestination: RailDestination {
        if djMode { return .atelier }
        if tab == .settings && settingsSection == .system && settingsPage == nil { return .atelier }
        return RailDestination.of(tab)
    }
}

struct RailItem: View {
    @EnvironmentObject var m: PlayerModel
    let destination: RailDestination
    let line: Namespace.ID
    @StateObject private var hover = Box(false)

    var body: some View {
        let on = m.currentDestination == destination
        Button {
            withAnimation(Motion.page) { m.go(on ? destination.home : target) }
        } label: {
            Text(destination.rawValue).font(Typo.sans(11, on ? .medium : .regular)).tracking(2.6).textCase(.uppercase)
                .foregroundStyle(on ? Brand.ink : (hover.v ? Brand.ink : Brand.inkSecondary))
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    if on { Rectangle().fill(Brand.gradient).frame(height: 1).padding(.trailing, -2.6).matchedGeometryEffect(id: "rail.underline", in: line) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .animation(Motion.touch, value: hover.v)
        .animation(TabMotion.animation, value: on)
        .accessibilityLabel(destination.rawValue)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The page of the destination that was open last, else its first.
    private var target: NavTarget { m.lastPage[destination] ?? destination.home }
}

struct RailGear: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var hover = Box(false)
    var body: some View {
        let on = m.currentDestination == .settings
        Button { withAnimation(Motion.page) { m.go(.settings(m.settingsSection)) } } label: {
            Image(systemName: "gearshape").font(Typo.sans(14, .light))
                .foregroundStyle(on ? Brand.accentText : (hover.v ? Brand.ink : Brand.inkSecondary))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .help("Settings").accessibilityLabel("Settings")
    }
}

struct QuickFindButton: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var hover = Box(false)
    var body: some View {
        Button { withAnimation(Motion.glide) { m.showPalette = true } } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(Typo.sans(13, .light))
                Text("⌘K").font(Typo.mono(10, .regular)).tracking(1)
            }
            .foregroundStyle(hover.v ? Brand.ink : Brand.inkSecondary)
            .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .keyboardShortcut("k", modifiers: .command)
        .help("Find anything (⌘K)").accessibilityLabel("Quick find")
    }
}

/// The quiet sub-header under the rail: every page of the destination as small capitals in one line, a champagne line under the one you are on. It
/// tightens its spacing when the window is narrow and, if that is not enough, scrolls sideways under soft edges.
struct SubNavBar: View {
    @EnvironmentObject var m: PlayerModel
    let destination: RailDestination
    @Namespace private var lineSpace

    private func hidden(_ t: NavTarget) -> Bool { if case .tab(let tab) = t { return m.sidebar.isHidden(tab) } else { return false } }

    private func line(spacing: CGFloat, tracking: CGFloat, _ items: [NavTarget]) -> some View {
        HStack(spacing: spacing) { ForEach(items) { SubNavItem(target: $0, tracking: tracking, line: lineSpace) } }.fixedSize()
    }

    var body: some View {
        let items = destination.subNav.filter { !hidden($0) || m.isCurrent($0) }
        ViewThatFits(in: .horizontal) {
            line(spacing: 28, tracking: 2, items)
            line(spacing: 20, tracking: 1.4, items)
            line(spacing: 14, tracking: 1, items)
            ScrollView(.horizontal, showsIndicators: false) { line(spacing: 14, tracking: 1, items).padding(.horizontal, 32) }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05), .init(color: .black, location: 0.95), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        }
        .frame(maxWidth: .infinity).frame(height: 32)
    }
}

struct SubNavItem: View {
    @EnvironmentObject var m: PlayerModel
    let target: NavTarget
    var tracking: CGFloat = 2
    let line: Namespace.ID
    @StateObject private var hover = Box(false)
    var body: some View {
        let on = m.isCurrent(target)
        Button { withAnimation(Motion.page) { m.go(target) } } label: {
            Text(target.title).font(Typo.sans(10, on ? .medium : .regular)).tracking(tracking).textCase(.uppercase)
                .foregroundStyle(on ? Brand.ink : (hover.v ? Brand.inkSecondary : Brand.inkTertiary))
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { if on { Rectangle().fill(Brand.gradient).frame(height: 1).matchedGeometryEffect(id: "subnav.underline", in: line) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .animation(Motion.touch, value: hover.v).animation(TabMotion.animation, value: on)
        .accessibilityLabel(target.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

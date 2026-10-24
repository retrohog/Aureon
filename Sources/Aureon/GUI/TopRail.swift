import SwiftUI

// The top bar and the rail of the Pulse shell. The top bar holds the window buttons, the mark, Back and Forward, Home, the always-visible search,
// the output chip and Settings; the rail down the left holds Library, Playlists, Radio, Rooms and Sound. On Now Playing the bar rests: it fades after
// a few seconds without the pointer, and returns with any movement or key.

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

/// A round icon button of the top bar and the player bar: 36 points, a soft disc under the pointer, the accent when it is on.
struct RoundIconStyle: ButtonStyle {
    var on = false
    var size: CGFloat = 36
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, on: on, size: size) }
    private struct Inner: View {
        let configuration: Configuration
        let on: Bool
        let size: CGFloat
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(Typo.sans(16, .regular))
                .foregroundStyle(on ? Brand.accentText : (hover.v || configuration.isPressed ? Brand.ink : Brand.inkSecondary).opacity(enabled ? 1 : 0.4))
                .frame(width: size, height: size)
                .background(Circle().fill(Brand.ink.opacity(configuration.isPressed ? 0.14 : (hover.v && enabled ? 0.08 : 0))))
                .contentShape(Circle())
                .animation(Motion.touch, value: hover.v)
                .onHover { hover.v = $0 }
        }
    }
}

/// The bar across the top of the window.
struct PulseTopBar: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var idle: IdleTracker

    private var resting: Bool { !idle.awake && m.tab == .player && !m.djMode }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Color.clear.frame(width: 84, height: 1)          // the window buttons are placed over the left of this row by `WindowChrome`
                PlanetMark(size: 28).help("Aureon")
                NavButtons().padding(.leading, 12)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                HomeButton()
                TopSearchField()
            }
            .frame(maxWidth: 520).padding(.horizontal, 250)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                OutputChip()
                SettingsButton()
            }
            .padding(.trailing, 16)
            // ⌥⌘D: the quick control panel
            Button { withAnimation(Motion.glide) { m.toggleQuickPanel(.rail) } } label: { Color.clear }
                .buttonStyle(.plain).keyboardShortcut("d", modifiers: [.option, .command]).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .frame(height: Metrics.topBarHeight)
        .opacity(resting ? 0 : 1)
        .allowsHitTesting(!resting)
        .accessibilityElement(children: .contain)
    }
}

extension PlayerModel {
    /// The destination that is on screen. Diagnostics are a section of the settings page that belongs to Sound.
    var currentDestination: RailDestination {
        if djMode { return .sound }
        if tab == .settings && settingsSection == .system && settingsPage == nil { return .sound }
        return RailDestination.of(tab)
    }
}

struct HomeButton: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        let on = m.currentDestination == .home && m.tab == .home
        Button { withAnimation(Motion.page) { m.go(.tab(.home)) } } label: { Image(systemName: on ? "house.fill" : "house") }
            .buttonStyle(RoundIconStyle(on: on, size: 40))
            .help("Home").accessibilityLabel("Home").accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct SettingsButton: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        let on = m.currentDestination == .settings
        Button { withAnimation(Motion.page) { m.go(.settings(m.settingsSection)) } } label: { Image(systemName: "gearshape") }
            .buttonStyle(RoundIconStyle(on: on, size: 40)).help("Settings").accessibilityLabel("Settings")
    }
}

/// The search field, always in the bar. It opens the quick-find (⌘K), which searches the library, the pages and the settings.
struct TopSearchField: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var hover = Box(false)
    var body: some View {
        Button { withAnimation(Motion.glide) { m.showPalette = true } } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(Typo.sans(14, .regular))
                Text("Search songs, albums, artists").font(Typo.sans(14.5, .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text("⌘K").font(Typo.mono(11, .regular)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Metrics.tagRadius, style: .continuous).fill(Brand.ink.opacity(0.08)))
            }
            .foregroundStyle(hover.v ? Brand.ink : Brand.inkSecondary)
            .padding(.horizontal, 16).frame(height: 38).frame(maxWidth: .infinity)
            .background(Capsule().fill(Brand.panel2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .keyboardShortcut("k", modifiers: .command)
        .help("Find anything (⌘K)").accessibilityLabel("Search")
    }
}

/// The output and its rate, as a chip: a dot in the accent, the device, the rate it runs at. It opens the quick controls.
struct OutputChip: View {
    @EnvironmentObject var m: PlayerModel
    /// The top bar's chip is `.rail`; the chip in the controls of Now Playing is `.stage`.
    var anchor: QuickPanelAnchor = .rail
    @StateObject private var hover = Box(false)

    private var text: String {
        let name = m.selectedDevice.map { QuickDevices.shortName($0.name) } ?? "No device"
        guard m.isActive, let rate = m.status.info?.sampleRate, rate > 0 else { return name }
        return name + " · " + formatRate(rate)
    }

    var body: some View {
        Button { withAnimation(Motion.glide) { m.toggleQuickPanel(anchor) } } label: {
            HStack(spacing: 8) {
                Circle().fill(Brand.accent).frame(width: 8, height: 8)
                Text(text).font(Typo.sans(13, .medium)).lineLimit(1)
            }
            .foregroundStyle(m.quickPanel == anchor || hover.v ? Brand.ink : Brand.inkSecondary)
            .padding(.horizontal, 14).frame(height: Metrics.pillHeight)
            .background(Capsule().fill(Brand.ink.opacity(m.quickPanel == anchor ? 0.1 : (hover.v ? 0.06 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .help("Output: \(m.selectedDevice?.name ?? "none"). Quick controls (⌥⌘D)")
        .accessibilityLabel("Output").accessibilityValue(text)
        .popover(isPresented: Binding(get: { m.quickPanel == anchor }, set: { if !$0, m.quickPanel == anchor { m.quickPanel = nil } }), arrowEdge: anchor == .rail ? .bottom : .top) {
            QuickPanelView().environmentObject(m)
        }
    }
}

/// The rail down the left: five destinations, each a symbol over a small label. The one you are in sits on a raised plate.
struct PulseRail: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(RailDestination.rail) { RailItem(destination: $0) }
            Spacer(minLength: 0)
        }
        .padding(.top, 8).frame(width: Metrics.railWidth)
        .accessibilityElement(children: .contain)
    }
}

struct RailItem: View {
    @EnvironmentObject var m: PlayerModel
    let destination: RailDestination
    @StateObject private var hover = Box(false)

    var body: some View {
        let on = m.currentDestination == destination
        Button {
            withAnimation(Motion.page) { m.go(on ? destination.home : target) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: destination.icon).font(Typo.sans(20, .regular)).frame(height: 24)
                Text(destination.rawValue).font(Typo.sans(11, on ? .medium : .regular)).lineLimit(1)
            }
            .foregroundStyle(on || hover.v ? Brand.ink : Brand.inkSecondary)
            .frame(width: 60, height: 58)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Brand.panel2 : Brand.ink.opacity(hover.v ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

/// The chips along the top of a destination's pages: every page of it in one line, the one you are on filled. They tighten when the window is narrow
/// and, if that is not enough, scroll sideways under soft edges.
struct SubNavBar: View {
    @EnvironmentObject var m: PlayerModel
    let destination: RailDestination

    private func hidden(_ t: NavTarget) -> Bool { if case .tab(let tab) = t { return m.sidebar.isHidden(tab) } else { return false } }

    private func line(_ items: [NavTarget]) -> some View {
        HStack(spacing: 8) {
            ForEach(items) { t in
                PillChip(title: t.title, on: m.isCurrent(t)) { withAnimation(Motion.page) { m.go(t) } }
            }
        }.fixedSize()
    }

    var body: some View {
        let items = destination.subNav.filter { !hidden($0) || m.isCurrent($0) }
        ViewThatFits(in: .horizontal) {
            line(items).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) { line(items) }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        }
        .padding(.horizontal, 24).frame(height: ChromeInset.subNav)
    }
}

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

    /// What to do when the timer fires: keep the interface in view (resting is off, a snapshot or test, or something needs it), wait for the rest of the delay, or rest.
    enum Decision: Equatable { case stayAwake, waitMore(TimeInterval), rest }
    static func decision(restControls: Bool, idle: TimeInterval, holds: Bool, disabled: Bool) -> Decision {
        if !restControls { return .stayAwake }
        if idle < delay { return .waitMore(delay - idle) }
        return disabled || holds ? .waitMore(delay) : .rest
    }

    private func check() {
        timer = nil
        switch Self.decision(restControls: Look.current.restControls, idle: Date().timeIntervalSince(lastPoke), holds: holdsAwake(), disabled: Self.disabled) {
        case .stayAwake: if !awake { awake = true }
        case .waitMore(let t): schedule(t)
        case .rest: withAnimation(Motion.carpet) { awake = false }
        }
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
    @State private var width: CGFloat = 1100
    @State private var rightWidth: CGFloat = 280

    private var resting: Bool { !idle.awake && m.tab == .player && !m.djMode }
    /// In a narrow window the Add folder button is its icon only.
    private var compact: Bool { width < 1000 }

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
                AddFolderButton(compact: compact)
            }
            .frame(maxWidth: 600)
            // the search sits between the buttons at the left and the controls at the right, whatever their width (they never overlap it)
            .padding(.leading, 250).padding(.trailing, max(250, rightWidth + 28))
            HStack(spacing: 8) {
                OutputChip().frame(maxWidth: 230)
                MiniToggleButton()
                SettingsButton()
            }
            .fixedSize()
            // what the controls at the right need: the search keeps clear of it
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { rightWidth = $0 + 16 }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            // ⌥⌘D: the quick control panel
            Button { withAnimation(Motion.glide) { m.toggleQuickPanel(.rail) } } label: { Color.clear }
                .buttonStyle(.plain).keyboardShortcut("d", modifiers: [.option, .command]).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .frame(height: Metrics.topBarHeight)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .opacity(resting ? 0 : 1)
        .allowsHitTesting(!resting)
        .accessibilityElement(children: .contain)
    }
}

/// Add folder, beside the search, on every page: it opens the same choice of folders as the Library's own button. In a narrow window it is the icon alone.
struct AddFolderButton: View {
    @EnvironmentObject var m: PlayerModel
    var compact = false
    @StateObject private var hover = Box(false)

    var body: some View {
        Button { m.chooseMusicFolders() } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").font(Typo.sans(14, .regular))
                if !compact { Text("Add folder").font(Typo.sans(13.5, .medium)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(hover.v ? Brand.ink : Brand.inkSecondary)
            .padding(.horizontal, compact ? 12 : 16).frame(height: 38)
            .background(Capsule().fill(Brand.panel2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .help("Add a music folder…").accessibilityLabel("Add folder").layoutProbe("top.addFolder")
    }
}

extension PlayerModel {
    /// The choice of music folders (the one the Library's Add folder button opens).
    func chooseMusicFolders() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = "Choose the folder(s) that contain your music"
        DispatchQueue.main.async { [weak self] in if p.runModal() == .OK { p.urls.forEach { self?.library.addFolder($0) } } }
    }
}

extension PlayerModel {
    /// The destination that is on screen. Diagnostics are a section of the settings page that belongs to Sound.
    var currentDestination: RailDestination {
        if djMode { return .sound }
        return RailDestination.of(tab)
    }
}

struct HomeButton: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        let on = m.currentDestination == .home && m.tab == .home
        Button { withAnimation(Motion.page) { m.go(.tab(.home)) } } label: { Image(systemName: on ? "house.fill" : "house") }
            .buttonStyle(RoundIconStyle(on: on, size: 40))
            .help("Home").accessibilityLabel("Home").accessibilityAddTraits(on ? .isSelected : []).layoutProbe("top.home")
    }
}

/// The mini player button of the top bar, on every page and in every Now Playing layout: it opens the mini player, or puts it away when it is open.
struct MiniToggleButton: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        let on = m.mini.isFloatingOpen || m.mini.isPopoverOpen
        Button { m.mini.toggle() } label: { Image(systemName: "pip") }
            .buttonStyle(RoundIconStyle(on: on, size: 40)).help("Mini player (⌥⌘M)")
            .accessibilityLabel("Mini player").accessibilityIdentifier("top.mini").layoutProbe("top.mini")
    }
}

struct SettingsButton: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        let on = m.currentDestination == .settings
        Button { withAnimation(Motion.page) { m.go(.settings(m.settingsSection)) } } label: { Image(systemName: "gearshape") }
            .buttonStyle(RoundIconStyle(on: on, size: 40)).help("Settings").accessibilityLabel("Settings").layoutProbe("top.settings")
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
        .help("Find anything (⌘K)").accessibilityLabel("Search").layoutProbe("top.search")
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
        .accessibilityLabel("Output").accessibilityValue(text).layoutProbe("output.\(anchor)")
        .windowPopover(isPresented: Binding(get: { m.quickPanel == anchor }, set: { if !$0, m.quickPanel == anchor { m.quickPanel = nil } }), edge: anchor == .rail ? .bottom : .top) {
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
        .accessibilityLabel(destination.rawValue).layoutProbe("rail.\(destination.rawValue)")
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
        .layoutProbe("subnav")
    }
}

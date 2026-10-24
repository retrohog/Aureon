import SwiftUI
import AppKit

// The windows of the mini player: a floating panel for the bar, the strip and the cards, and an item in the menu bar that opens a popover. Both read the
// same settings (`look.mini`) and change at once when they are changed. Nothing is created until it is asked for, and everything is closed and released
// when it is put away.

/// The floating panel. It can become key (so its controls answer) without making the app active, and it is dragged by its background.
final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// When the countdown of the popover runs, and whether it waits. Pure, so the rule is testable.
enum PopoverCountdown {
    enum Action: Equatable { case close, wait(TimeInterval), none }
    /// What to do when `elapsed` seconds have passed since it opened: nothing when it never closes by itself; wait while the pointer is over it (if asked
    /// to); close once the time is up.
    static func action(autoClose seconds: Int, elapsed: TimeInterval, pointerInside: Bool, keepWhileOver: Bool) -> Action {
        guard seconds > 0 else { return .none }
        if elapsed < Double(seconds) { return .wait(Double(seconds) - elapsed) }
        return pointerInside && keepWhileOver ? .wait(1) : .close
    }
}

@MainActor
final class MiniPlayerController: NSObject, NSWindowDelegate, NSPopoverDelegate {
    private weak var model: PlayerModel?
    private var panel: MiniPanel?
    private var shownLayout: MiniLayout?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var titleTimer: Timer?
    private var countdown: Timer?
    private var openedAt = Date()
    fileprivate var pointerInside = false
    private let defaults = UserDefaults.standard

    init(model: PlayerModel) { self.model = model; super.init() }

    private var settings: MiniSettings { model?.look.mini ?? MiniSettings() }
    var isFloatingOpen: Bool { panel?.isVisible == true }
    /// What the open window looks like (for tests): its frame, level, opacity and whether it follows to other desktops.
    var floatingState: (frame: NSRect, level: NSWindow.Level, alpha: CGFloat, onEveryDesktop: Bool)? {
        panel.map { ($0.frame, $0.level, $0.alphaValue, $0.collectionBehavior.contains(.canJoinAllSpaces)) }
    }
    var isPopoverOpen: Bool { popover?.isShown == true }
    private var snapshot: Bool { ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil || ProcessInfo.processInfo.environment["AUREON_TESTING"] != nil }

    // MARK: entry points

    /// The mini player button: opens the chosen layout, or puts it away when it is open.
    func toggle() {
        if settings.layout == .popover { togglePopover(); return }
        if isFloatingOpen { closeFloating() } else { showFloating() }
    }

    /// Called when the settings change: a window is resized, re-levelled and re-dressed; the menu bar item appears, changes or goes.
    func settingsChanged() {
        if let panel, isFloatingOpen {
            if settings.layout.isWindow { place(panel, for: settings.layout) } else { closeFloating() }
        }
        syncStatusItem()
    }

    /// At launch: the menu bar item, if it is switched on.
    func start() { guard !snapshot else { return }; syncStatusItem() }

    func shutDown() { closeFloating(); closePopover(); removeStatusItem() }

    // MARK: the floating window

    func showFloating() {
        guard let model, settings.layout.isWindow else { togglePopover(); return }
        let layout = settings.layout
        let p = panel ?? makePanel()
        panel = p
        let host = NSHostingView(rootView: root(model, layout: layout))
        host.frame = NSRect(origin: .zero, size: layout.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        place(p, for: layout, firstTime: true)
        p.orderFrontRegardless()
        p.makeKey()
    }

    func closeFloating() {
        guard let p = panel else { return }
        saveOrigin(p)
        p.orderOut(nil); p.contentView = nil
        panel = nil; shownLayout = nil
    }

    private func makePanel() -> MiniPanel {
        let p = MiniPanel(contentRect: NSRect(origin: .zero, size: CGSize(width: 520, height: 96)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        return p
    }

    private func root(_ model: PlayerModel, layout: MiniLayout) -> AnyView {
        var actions = MiniActions()
        actions.interactive = true
        actions.close = { [weak self] in self?.closeFloating() }
        actions.togglePin = { [weak self] in guard let self, let m = self.model else { return }; m.look.mini.alwaysOnTop.toggle() }
        actions.openApp = { [weak self] in self?.openApp() }
        actions.isPinned = settings.alwaysOnTop
        return AnyView(MiniLayoutView(layout: layout).environment(\.miniActions, actions).miniEnvironment(model))
    }

    /// Size, level, opacity, desktops and place for the layout; the content is replaced when the layout changed.
    private func place(_ p: MiniPanel, for layout: MiniLayout, firstTime: Bool = false) {
        let s = settings
        if shownLayout != layout, let model, !firstTime { p.contentView = NSHostingView(rootView: root(model, layout: layout)) }
        else if let model, !firstTime { (p.contentView as? NSHostingView<AnyView>)?.rootView = root(model, layout: layout) }
        let size = layout.size
        let old = p.frame
        var origin = old.origin
        if firstTime || shownLayout == nil { origin = restoredOrigin(size: size, layout: layout) }
        else { origin.y += old.height - size.height }                          // grows and shrinks from the top edge
        p.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        p.level = s.alwaysOnTop ? .floating : .normal
        p.alphaValue = CGFloat(s.clampedOpacity)
        p.collectionBehavior = s.onEveryDesktop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
        shownLayout = layout
    }

    private func restoredOrigin(size: CGSize, layout: MiniLayout) -> CGPoint {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let fallback = MiniSettings.defaultOrigin(size: size, in: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        guard settings.rememberPosition, let a = defaults.array(forKey: "aureon.mini.origin") as? [Double], a.count == 2 else { return fallback }
        var o = CGPoint(x: a[0], y: a[1] + (defaults.double(forKey: "aureon.mini.height") - size.height))
        o = MiniSettings.onScreen(origin: o, size: size, screens: screens) ?? o
        return o
    }

    private func saveOrigin(_ p: NSWindow) {
        guard settings.rememberPosition, !snapshot else { return }
        defaults.set([Double(p.frame.origin.x), Double(p.frame.origin.y)], forKey: "aureon.mini.origin")
        defaults.set(Double(p.frame.height), forKey: "aureon.mini.height")
    }

    func windowDidMove(_ notification: Notification) { if let w = notification.object as? NSWindow, w === panel { saveOrigin(w) } }

    func openApp() {
        guard let model else { return }
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.windows.first { $0.canBecomeMain && !($0 is MiniPanel) })?.makeKeyAndOrderFront(nil)
        if !(settings.keepFloating) { closeFloating() }
        closePopover()
        if model.tab != .player { model.tab = .player }
    }

    // MARK: the menu bar item and its popover

    private func syncStatusItem() {
        let wants = settings.menuBar.show || settings.layout == .popover       // the popover layout lives under the item, so it needs one
        guard wants, !snapshot else { removeStatusItem(); return }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            if let b = item.button {
                b.target = self; b.action = #selector(statusClicked(_:))
                b.sendAction(on: [.leftMouseUp])
                b.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
                b.setAccessibilityLabel("Aureon")
            }
        }
        updateStatusLook()
        titleTimer?.invalidate()
        if settings.menuBar.shows != .logo { titleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateStatusLook() } } }
    }

    private func removeStatusItem() {
        titleTimer?.invalidate(); titleTimer = nil
        closePopover()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    /// The logo (a small template drawing of the mark) and/or the title of the song, as the settings say.
    private func updateStatusLook() {
        guard let b = statusItem?.button else { return }
        let s = settings.menuBar
        b.image = s.shows == .title ? nil : Self.logo
        b.imagePosition = s.shows == .logoTitle ? .imageLeft : .imageOnly
        let title = model?.focusDisplay?.title ?? ""
        let shown = title.count > 28 ? String(title.prefix(27)) + "…" : title
        b.title = s.shows == .logo ? "" : (shown.isEmpty ? "Aureon" : " " + shown)
        if s.shows == .title { b.imagePosition = .noImage }
    }

    /// The mark drawn as a template image, so the system colours it for the menu bar.
    static let logo: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let c = NSPoint(x: r.midX, y: r.midY)
            let planet = NSBezierPath(ovalIn: NSRect(x: c.x - 4.6, y: c.y - 4.6, width: 9.2, height: 9.2)); planet.lineWidth = 1.4; planet.stroke()
            let orbit = NSBezierPath(ovalIn: NSRect(x: c.x - 8.2, y: c.y - 2.4, width: 16.4, height: 4.8)); orbit.lineWidth = 0.9
            var t = AffineTransform(translationByX: c.x, byY: c.y); t.rotate(byDegrees: 20); t.translate(x: -c.x, y: -c.y)
            orbit.transform(using: t); orbit.stroke()
            NSBezierPath(ovalIn: NSRect(x: c.x + 5.3, y: c.y + 2.2, width: 2.6, height: 2.6)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()

    @objc private func statusClicked(_ sender: Any?) { togglePopover() }

    @objc func mouseEntered(with event: NSEvent) { if settings.menuBar.openOn == .hover, !isPopoverOpen { showPopover() } }

    func togglePopover() { if isPopoverOpen { closePopover() } else { showPopover() } }

    func showPopover() {
        guard let model, !snapshot else { return }
        if statusItem == nil { syncStatusItem() }
        guard let button = statusItem?.button else { return }
        let pop = NSPopover()
        pop.behavior = settings.menuBar.closeOnOutsideClick ? .transient : .applicationDefined
        pop.animates = true
        pop.delegate = self
        var actions = MiniActions(); actions.openApp = { [weak self] in self?.openApp() }
        let view = MiniPopoverView().environment(\.miniActions, actions).onHover { [weak self] inside in self?.pointerInside = inside }.miniEnvironment(model)
        pop.contentViewController = NSHostingController(rootView: view)
        pop.contentSize = MiniLayout.popover.size
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = pop
        openedAt = Date(); pointerInside = false
        scheduleCountdown(after: Double(settings.menuBar.autoCloseSeconds))
    }

    func closePopover() {
        countdown?.invalidate(); countdown = nil
        let wasOpen = popover?.isShown == true
        popover?.close(); popover = nil
        if wasOpen, !settings.keepFloating { closeFloating() }
    }

    func popoverDidClose(_ notification: Notification) {
        countdown?.invalidate(); countdown = nil
        popover = nil
        if !settings.keepFloating { closeFloating() }
    }

    private func scheduleCountdown(after delay: TimeInterval) {
        countdown?.invalidate()
        guard delay > 0 else { return }
        countdown = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.countdownFired() } }
    }

    private func countdownFired() {
        let s = settings.menuBar
        switch PopoverCountdown.action(autoClose: s.autoCloseSeconds, elapsed: Date().timeIntervalSince(openedAt), pointerInside: pointerInside, keepWhileOver: s.keepOpenWhileOver) {
        case .close: closePopover()
        case .wait(let t): scheduleCountdown(after: max(0.2, t))
        case .none: break
        }
    }
}

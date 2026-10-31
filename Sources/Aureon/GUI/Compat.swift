import SwiftUI
import AppKit

// SwiftUI and AppKit pieces that arrived after macOS 13, with a fallback for each. On macOS 15 (or 14 where noted) every shim calls the system
// API, so behaviour there is unchanged. The fallbacks run on the main thread only and do no work per frame beyond one comparison.

// MARK: - onChange with the old value (macOS 14)

private final class Last<V>: @unchecked Sendable { var v: V; init(_ v: V) { self.v = v } }

private struct OnChangeBefore14<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void
    @State private var last: Last<V>

    init(value: V, initial: Bool, action: @escaping (V, V) -> Void) {
        self.value = value; self.initial = initial; self.action = action
        _last = State(initialValue: Last(value))
    }

    func body(content: Content) -> some View {
        content
            .onAppear { if initial { action(value, value) } }
            .onChange(of: value) { new in let old = last.v; last.v = new; action(old, new) }
    }
}

extension View {
    /// `onChange(of:initial:_:)` with the old and the new value.
    @ViewBuilder func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        if #available(macOS 14, *) { onChange(of: value, initial: initial, action) }
        else { modifier(OnChangeBefore14(value: value, initial: initial, action: action)) }
    }

    /// `onChange(of:initial:_:)` for a closure that needs neither value.
    @ViewBuilder func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        onChangeCompat(of: value, initial: initial) { _, _ in action() }
    }

    /// `focusEffectDisabled()` (macOS 14): the ring is not drawn on macOS 13 either, because the controls draw their own focus.
    @ViewBuilder func focusEffectDisabledCompat() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
    }

    /// `transaction(value:_:)` (macOS 14). Before that the transaction is built once and its animation is attached to the value.
    @ViewBuilder func transactionCompat<V: Equatable>(value: V, _ body: @escaping (inout Transaction) -> Void) -> some View {
        if #available(macOS 14, *) { transaction(value: value, body) }
        else {
            let animation: Animation? = { var t = Transaction(); body(&t); return t.animation }()
            self.animation(animation, value: value)
        }
    }

    /// `scrollBounceBehavior(.basedOnSize)` (macOS 13.3).
    @ViewBuilder func scrollBounceBasedOnSize() -> some View {
        if #available(macOS 13.3, *) { scrollBounceBehavior(.basedOnSize) } else { self }
    }

    /// The toggle trait (macOS 14); the on/off value is spoken through `accessibilityValue` on every version.
    @ViewBuilder func accessibilityToggleTrait() -> some View {
        if #available(macOS 14, *) { accessibilityAddTraits(.isToggle) } else { self }
    }
}

// MARK: - Key presses (macOS 14)

enum CompatKeyResult { case handled, ignored }

struct CompatKeyPress {
    var key: KeyEquivalent?
    var modifiers: EventModifiers
}

extension View {
    /// `onKeyPress` for one key, or for every key when `key` is nil. `whileFocused` is the owner's focus state: on macOS 13 there is no per-view key
    /// handling, so the fallback listens to the window's key events and only acts while that is true (nil: whenever the window is key).
    func onKeyPressCompat(_ key: KeyEquivalent? = nil, whileFocused: Bool? = nil, repeats: Bool = false, _ action: @escaping (CompatKeyPress) -> CompatKeyResult) -> some View {
        modifier(KeyPressModifier(key: key, whileFocused: whileFocused, repeats: repeats, action: action))
    }

    func onKeyPressCompat(_ key: KeyEquivalent, whileFocused: Bool? = nil, repeats: Bool = false, _ action: @escaping () -> CompatKeyResult) -> some View {
        onKeyPressCompat(key, whileFocused: whileFocused, repeats: repeats) { _ in action() }
    }
}

private struct KeyPressModifier: ViewModifier {
    let key: KeyEquivalent?
    let whileFocused: Bool?
    let repeats: Bool
    let action: (CompatKeyPress) -> CompatKeyResult

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            let phases: KeyPress.Phases = repeats ? [.down, .repeat] : .down
            if let key {
                content.onKeyPress(key, phases: phases) { p in action(CompatKeyPress(key: p.key, modifiers: p.modifiers)) == .handled ? .handled : .ignored }
            } else {
                content.onKeyPress(phases: phases) { p in action(CompatKeyPress(key: p.key, modifiers: p.modifiers)) == .handled ? .handled : .ignored }
            }
        } else {
            content.background(KeyMonitor(key: key, active: whileFocused, repeats: repeats, action: action))
        }
    }
}

private struct KeyMonitor: NSViewRepresentable {
    let key: KeyEquivalent?
    let active: Bool?
    let repeats: Bool
    let action: (CompatKeyPress) -> CompatKeyResult

    final class Coordinator {
        var monitor: Any?
        var parent: KeyMonitor
        weak var view: NSView?
        init(_ p: KeyMonitor) { parent = p }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let view = self.view, let window = view.window, window.isKeyWindow, window === e.window else { return e }
                let p = self.parent
                if p.active == false || (e.isARepeat && !p.repeats) { return e }
                let mods = Self.modifiers(e.modifierFlags)
                let k = Self.key(e)
                if let want = p.key, want != k { return e }
                return p.action(CompatKeyPress(key: k, modifiers: mods)) == .handled ? nil : e
            }
        }

        static func modifiers(_ f: NSEvent.ModifierFlags) -> EventModifiers {
            var m: EventModifiers = []
            if f.contains(.shift) { m.insert(.shift) }
            if f.contains(.control) { m.insert(.control) }
            if f.contains(.option) { m.insert(.option) }
            if f.contains(.command) { m.insert(.command) }
            return m
        }

        static func key(_ e: NSEvent) -> KeyEquivalent? {
            switch e.keyCode {
            case 123: .leftArrow
            case 124: .rightArrow
            case 125: .downArrow
            case 126: .upArrow
            case 36, 76: .return
            case 53: .escape
            case 48: .tab
            case 49: .space
            case 51: .delete
            default: e.charactersIgnoringModifiers?.first.map { KeyEquivalent($0) }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView { let v = NSView(); context.coordinator.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { context.coordinator.parent = self; context.coordinator.view = v; context.coordinator.start() }
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { if let m = coordinator.monitor { NSEvent.removeMonitor(m); coordinator.monitor = nil } }
}

extension View {
    /// Window-level key handling on every macOS version (a local event monitor), for fields where the system's own key handling would take the key first:
    /// the arrow keys in a text field, for example. Acts only while `active`, and a handled key never reaches the field.
    func onKeyMonitor(_ key: KeyEquivalent, active: Bool, repeats: Bool = true, _ action: @escaping () -> CompatKeyResult) -> some View {
        background(KeyMonitor(key: key, active: active, repeats: repeats) { _ in action() })
    }
}

// MARK: - Scroll tracking (macOS 15)

/// Finds the NSScrollView that a SwiftUI `ScrollView` puts next to this view's background and reports its scrolling: the content offset, the
/// start of a scroll by the user, and (once) a requested offset. It can also give the content a top inset, which is what `contentMargins`
/// does on newer systems.
private struct LegacyScrollBridge: NSViewRepresentable {
    var topInset: CGFloat = 0
    var restore: Double?
    var onOffset: ((Double) -> Void)?
    var onUserScroll: (() -> Void)?

    final class Coordinator {
        var parent: LegacyScrollBridge
        weak var scroll: NSScrollView?
        var tokens: [NSObjectProtocol] = []
        var restored = false
        var insetApplied = false
        init(_ p: LegacyScrollBridge) { parent = p }
        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

        func attach(_ view: NSView) {
            guard scroll == nil, let found = Self.findScrollView(near: view) else { return }
            scroll = found
            let clip = found.contentView
            clip.postsBoundsChangedNotifications = true
            if parent.topInset > 0 {
                found.automaticallyAdjustsContentInsets = false
                found.contentInsets = NSEdgeInsets(top: parent.topInset, left: 0, bottom: 0, right: 0)
                found.scrollerInsets = NSEdgeInsets(top: parent.topInset, left: 0, bottom: 0, right: 0)
                if clip.bounds.origin.y > -parent.topInset { clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: -parent.topInset)); found.reflectScrolledClipView(clip) }
                insetApplied = true
            }
            tokens.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.parent.onOffset?(Double(clip.bounds.origin.y))
            })
            tokens.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: found, queue: .main) { [weak self] _ in
                self?.parent.onUserScroll?()
            })
            parent.onOffset?(Double(clip.bounds.origin.y))
        }

        func applyRestore() {
            guard !restored, let y = parent.restore, let found = scroll else { return }
            restored = true
            let clip = found.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: CGFloat(y)))
            found.reflectScrolledClipView(clip)
        }

        static func findScrollView(near view: NSView) -> NSScrollView? {
            var node: NSView? = view.superview
            for _ in 0..<6 {
                guard let n = node else { return nil }
                var queue: [NSView] = [n], depth = 0
                while !queue.isEmpty, depth < 400 {
                    let v = queue.removeFirst(); depth += 1
                    if let s = v as? NSScrollView { return s }
                    queue.append(contentsOf: v.subviews)
                }
                node = n.superview
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async { context.coordinator.attach(v); context.coordinator.applyRestore() }
    }
}

extension View {
    /// Reports the vertical scroll offset of the `ScrollView` this is applied to (`onScrollGeometryChange` on macOS 15).
    @ViewBuilder func onScrollOffsetChange(_ action: @escaping (Double) -> Void) -> some View {
        if #available(macOS 15, *) { onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.y) } action: { _, y in action(y) } }
        else { background(LegacyScrollBridge(onOffset: action)) }
    }

    /// Calls `action` when the user starts scrolling by hand (`onScrollPhaseChange` to `.interacting` on macOS 15).
    @ViewBuilder func onUserScrollStart(_ action: @escaping () -> Void) -> some View {
        if #available(macOS 15, *) { onScrollPhaseChange { _, new in if new == .interacting { action() } } }
        else { background(LegacyScrollBridge(onUserScroll: action)) }
    }
}

/// The scroll view of a page: content starts `inset` below the top but scrolls under it. Reports "scrolled under" and where the page is
/// scrolled (for `ScrollMemory`), and puts it back where it was left.
struct UnderChromeScroll: ViewModifier {
    let chrome: ChromeState
    let inset: CGFloat
    @Environment(\.scrollKey) private var key
    @State private var restoring = true
    @State private var pendingRestore: Double?

    func body(content: Content) -> some View {
        content
            .modifier(ScrollInset(inset: inset, restore: pendingRestore) { y in
                let scrolled = y > -inset + 2
                if chrome.scrolled != scrolled { chrome.scrolled = scrolled }
                if !restoring, !key.isEmpty { ScrollMemory.shared.set(key, y) }
            })
            .onAppear {
                guard !key.isEmpty, let y = ScrollMemory.shared.offset(key) else { restoring = false; return }
                // after the page has laid itself out (a grid of covers is built as it is asked for)
                // (a settings page is laid out at once, so it is put back at once: nothing is seen to jump when the interface is rebuilt)
                let delay = key.hasPrefix(Tab.settings.rawValue + "|") ? 0.02 : 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    pendingRestore = y
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restoring = false }
                }
            }
    }
}

private struct ScrollInset: ViewModifier {
    let inset: CGFloat
    let restore: Double?
    let report: (Double) -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) { Modern(inset: inset, restore: restore, report: report, content: content) }
        else { content.background(LegacyScrollBridge(topInset: inset, restore: restore, onOffset: report)) }
    }

    @available(macOS 15, *)
    private struct Modern: View {
        let inset: CGFloat
        let restore: Double?
        let report: (Double) -> Void
        let content: Content
        @State private var position = ScrollPosition(edge: .top)

        var body: some View {
            content
                .contentMargins(.top, inset, for: .scrollContent)
                .contentMargins(.top, inset, for: .scrollIndicators)
                .scrollPosition($position)
                .onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.y) } action: { _, y in report(y) }
                .onChange(of: restore) { _, y in if let y { position.scrollTo(y: CGFloat(y)) } }
        }
    }
}

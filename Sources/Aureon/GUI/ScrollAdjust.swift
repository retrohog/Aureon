import SwiftUI
import AppKit

/// Turning a scroll-wheel or trackpad movement into slider steps. Pure, so the rules are testable.
enum ScrollStep {
    /// A mouse wheel reports about one unit per click; a trackpad reports points, about 14 per "click".
    static func notches(deltaY: Double, precise: Bool) -> Double { precise ? deltaY / 14 : deltaY }

    /// The new value after `notches` clicks: each click moves `perNotch` of the range (never more than `maxMove` of it in one event), clamped to the range.
    static func apply(value: Double, notches: Double, range: ClosedRange<Double>, perNotch: Double = 0.02, maxMove: Double = 0.1) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, notches.isFinite else { return value }
        let move = max(-maxMove, min(maxMove, notches * perNotch)) * span
        return max(range.lowerBound, min(range.upperBound, value + move))
    }
}

/// Decides, event by event, whether scrolling belongs to a slider or to the page. A trackpad gesture adjusts a slider only if it *began* over one,
/// and then stays with it until its momentum ends or it has been quiet for a moment, so it can never be left holding the scrolling.
/// A mouse wheel adjusts a slider only with ⌥ held.
struct ScrollGate {
    enum Action: Equatable { case adjust, page }
    private(set) var capturing = false
    private var lastAt = 0.0

    mutating func decide(now: Double, phased: Bool, begins: Bool, momentumEnded: Bool, option: Bool, overControl: Bool) -> Action {
        guard phased else { return option && overControl ? .adjust : .page }
        if begins { capturing = overControl }
        else if capturing && now - lastAt > 0.3 { capturing = false }          // a gesture is never silent for this long: it is over, or was never ours
        lastAt = now
        let action: Action = capturing ? .adjust : .page
        if momentumEnded { capturing = false }
        return action
    }
}

/// Sends scroll-wheel movement to the slider under the pointer, so every slider in the app can be adjusted by scrolling over it:
/// controls drawn by Aureon register themselves while hovered; any system slider (NSSlider) is found by hit-testing.
@MainActor
final class ScrollRouter {
    static let shared = ScrollRouter()
    private var current: (id: UUID, handler: (Double) -> Bool, view: () -> NSView?, plainWheel: Bool)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) ?? e }
        }
    }

    /// Called by a control when the pointer enters (handler) or leaves (nil) it. `handler` returns whether it used the movement.
    func hover(_ id: UUID, _ handler: ((Double) -> Bool)?, view: @escaping () -> NSView? = { nil }, plainWheel: Bool = false) {
        if let handler { current = (id, handler, view, plainWheel) } else if current?.id == id { current = nil }
    }

    /// Whether the control under the pointer takes a plain mouse wheel (no ⌥): the volume does.
    private func plainWheelUnderPointer(_ e: NSEvent) -> Bool {
        guard let c = current, c.plainWheel, let v = c.view(), v.window === e.window, v.window != nil else { return false }
        return v.bounds.contains(v.convert(e.locationInWindow, from: nil))
    }

    /// The registered control counts only while the pointer really is over it (hover state goes stale when a page scrolls under a still pointer).
    private func currentUnderPointer(_ e: NSEvent) -> (Double) -> Bool {
        guard let c = current, let v = c.view(), v.window === e.window, v.window != nil else { return { _ in false } }
        return v.bounds.contains(v.convert(e.locationInWindow, from: nil)) ? c.handler : { _ in false }
    }

    private var gate = ScrollGate()

    /// Scrolling must never get stuck on a slider (see `ScrollGate`). Everything that is not meant for a slider scrolls the page.
    private func handle(_ e: NSEvent) -> NSEvent? {
        let notches = ScrollStep.notches(deltaY: Double(e.scrollingDeltaY), precise: e.hasPreciseScrollingDeltas)
        let phased = !e.phase.isEmpty || !e.momentumPhase.isEmpty
        let begins = e.phase.contains(.began) || e.phase.contains(.mayBegin)
        let over = begins || !phased ? (sliderUnderPointer(e) != nil || currentUnderPointer(e)(0)) : false
        let action = gate.decide(now: e.timestamp, phased: phased, begins: begins, momentumEnded: e.momentumPhase.contains(.ended) || e.phase.contains(.cancelled),
                                 option: e.modifierFlags.contains(.option) || plainWheelUnderPointer(e), overControl: over)
        switch action {
        case .adjust:
            if notches != 0, adjustUnderPointer(e, notches) { return nil }
            return phased ? nil : e
        case .page:
            return scrollUnderPointer(e) ? nil : e
        }
    }

    /// Hands the movement to the scroll view that is under the pointer *now*. AppKit remembers the view the pointer was last over, so after a
    /// page is swapped for another beneath a still pointer, scrolling would otherwise go nowhere until the next click or mouse movement.
    private func scrollUnderPointer(_ e: NSEvent) -> Bool {
        guard let w = e.window, w.level == .normal, let content = w.contentView, let sup = content.superview,
              let hit = content.hitTest(sup.convert(e.locationInWindow, from: nil)) else { return false }
        let vertical = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX)
        var v: NSView? = hit
        while let x = v {
            if let sv = x as? NSScrollView, let doc = sv.documentView {
                let room = vertical ? doc.frame.height - sv.contentView.bounds.height : doc.frame.width - sv.contentView.bounds.width
                if room > 1 { sv.scrollWheel(with: e); return true }
            }
            v = x.superview
        }
        return false
    }

    private func sliderUnderPointer(_ e: NSEvent) -> NSSlider? {
        guard let w = e.window, let content = w.contentView, let sup = content.superview,
              let hit = content.hitTest(sup.convert(e.locationInWindow, from: nil)) else { return nil }
        var v: NSView? = hit
        while let x = v { if let s = x as? NSSlider, s.isEnabled { return s }; v = x.superview }
        return nil
    }

    private func adjustUnderPointer(_ e: NSEvent, _ notches: Double) -> Bool {
        if currentUnderPointer(e)(notches) { return true }
        if let s = sliderUnderPointer(e) { adjust(s, notches); return true }
        return false
    }

    private func adjust(_ s: NSSlider, _ notches: Double) {
        let range = s.minValue...s.maxValue
        s.doubleValue = ScrollStep.apply(value: s.doubleValue, notches: notches, range: range)
        s.sendAction(s.action, to: s.target)
    }
}

extension View {
    /// While the pointer is over this view, scrolling adjusts it: `apply` gets the number of wheel clicks (positive = up) and returns whether it used them.
    func scrollAdjustable(hovering: Bool, plainWheel: Bool = false, apply: @escaping (Double) -> Bool) -> some View { modifier(ScrollAdjustable(hovering: hovering, plainWheel: plainWheel, apply: apply)) }
}

private struct ScrollAdjustable: ViewModifier {
    let hovering: Bool
    var plainWheel = false
    let apply: (Double) -> Bool
    @StateObject private var id = Box(UUID())
    @StateObject private var anchor = ViewAnchor()

    func body(content: Content) -> some View {
        content
            .background(AnchorView(anchor: anchor))
            .onChangeCompat(of: hovering) { _, now in ScrollRouter.shared.hover(id.v, now ? apply : nil, view: { [weak anchor] in anchor?.view }, plainWheel: plainWheel) }
            .onDisappear { ScrollRouter.shared.hover(id.v, nil) }
    }
}

/// How a drag on a guarded slider (the volume) turns into a value.
/// Pressing changes nothing; dragging moves the value by the distance dragged, from wherever you pressed; a click without movement only
/// nudges the value toward the press point by a small step. So no press can ever jump the value to the far end, yet dragging works from anywhere.
enum SliderDrag {
    static let clickSlop: Double = 4          // points of movement that still count as a click

    static func relative(start: Double, dx: Double) -> Double { min(1, max(0, start + dx)) }

    static func clickNudge(current: Double, press: Double, step: Double) -> Double {
        min(1, max(0, current + min(step, max(-step, press - current))))
    }
}

/// Gives the router the on-screen view of a control, so it can tell whether the pointer is over it.
final class ViewAnchor: ObservableObject { weak var view: NSView? }

private struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor
    final class Passive: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    func makeNSView(context: Context) -> NSView { let v = Passive(); anchor.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
}

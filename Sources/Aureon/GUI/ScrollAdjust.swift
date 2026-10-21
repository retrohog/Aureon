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

/// Sends scroll-wheel movement to the slider under the pointer, so every slider in the app can be adjusted by scrolling over it:
/// controls drawn by Aureon register themselves while hovered; any system slider (NSSlider) is found by hit-testing.
@MainActor
final class ScrollRouter {
    static let shared = ScrollRouter()
    private var current: (id: UUID, handler: (Double) -> Bool)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) ?? e }
        }
    }

    /// Called by a control when the pointer enters (handler) or leaves (nil) it. `handler` returns whether it used the movement.
    func hover(_ id: UUID, _ handler: ((Double) -> Bool)?) {
        if let handler { current = (id, handler) } else if current?.id == id { current = nil }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        let notches = ScrollStep.notches(deltaY: Double(e.scrollingDeltaY), precise: e.hasPreciseScrollingDeltas)
        guard notches != 0 else { return e }
        if let c = current, c.handler(notches) { return nil }
        if let w = e.window, let content = w.contentView, let sup = content.superview,
           let hit = content.hitTest(sup.convert(e.locationInWindow, from: nil)) {
            var v: NSView? = hit
            while let x = v { if let s = x as? NSSlider, s.isEnabled { adjust(s, notches); return nil }; v = x.superview }
        }
        return e
    }

    private func adjust(_ s: NSSlider, _ notches: Double) {
        let range = s.minValue...s.maxValue
        s.doubleValue = ScrollStep.apply(value: s.doubleValue, notches: notches, range: range)
        s.sendAction(s.action, to: s.target)
    }
}

extension View {
    /// While the pointer is over this view, scrolling adjusts it: `apply` gets the number of wheel clicks (positive = up) and returns whether it used them.
    func scrollAdjustable(hovering: Bool, apply: @escaping (Double) -> Bool) -> some View { modifier(ScrollAdjustable(hovering: hovering, apply: apply)) }
}

private struct ScrollAdjustable: ViewModifier {
    let hovering: Bool
    let apply: (Double) -> Bool
    @StateObject private var id = Box(UUID())

    func body(content: Content) -> some View {
        content
            .onChange(of: hovering) { _, now in ScrollRouter.shared.hover(id.v, now ? apply : nil) }
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

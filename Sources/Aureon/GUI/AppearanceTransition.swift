import SwiftUI
import AppKit
import QuartzCore

// Light and dark: one switch in the rail, and the change between them as a soft circular reveal that grows from the switch. The old window is captured
// once as a bitmap and laid over the new one; Core Animation then widens a hole in it (a mask path) and fades it out. The view hierarchy is never
// redrawn per frame, the overlay never answers a click, and it is gone when the animation ends.

enum AppearanceSwitching {
    /// The mode a tap on the switch goes to: the opposite of what is shown now (also when the mode is Auto).
    static func target(isLight: Bool) -> AppearanceMode { isLight ? .dark : .light }

    /// What the switch says it will do: the paired theme of the family in the other appearance.
    static func tooltip(family: String, isLight: Bool) -> String {
        let name = Theme.families.first { $0.id == family }?.name ?? "Obsidian"
        return isLight ? "Switch to dark (\(name))" : "Switch to light (\(name))"
    }
}

extension PlayerModel {
    /// Taps on the switch: to the other appearance, with the reveal growing from `anchor` (or from where the switch last said it was).
    func toggleAppearance(from anchor: CGPoint?) {
        let next = AppearanceSwitching.target(isLight: theme.isLight)
        let window = NSApp?.keyWindow ?? NSApp?.windows.first { $0.contentView != nil }
        ThemeTransition.run(in: window, anchor: anchor ?? switchAnchor, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { [self] in appearance = next }
    }
}

@MainActor
enum ThemeTransition {
    static let duration = 0.62
    static let reducedDuration = 0.2

    static func duration(reduceMotion: Bool) -> Double { reduceMotion ? reducedDuration : duration }

    /// The radius that covers the window from `p`: the distance to its farthest corner.
    static func coveringRadius(from p: CGPoint, in size: CGSize) -> CGFloat {
        let dx = max(p.x, size.width - p.x), dy = max(p.y, size.height - p.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The old appearance, laid over the window while the new one is built underneath.
    final class Overlay: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }          // clicks go through to the window below, always
        override var acceptsFirstResponder: Bool { false }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }

    private(set) static var overlay: Overlay?
    /// The overlay is on screen.
    static var isRunning: Bool { overlay != nil }

    /// Removes the overlay at once (a second change while one runs, and the end of each).
    static func finish() {
        overlay?.layer?.removeAllAnimations()
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// Captures `window`, applies `change` (which switches the theme), and animates the old picture away. `completion` runs when the overlay is gone.
    static func run(in window: NSWindow?, anchor: CGPoint?, reduceMotion: Bool, change: @escaping () -> Void, completion: (() -> Void)? = nil) {
        finish()
        guard let content = window?.contentView, content.bounds.width > 1, content.bounds.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { change(); completion?(); return }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let cg = rep.cgImage else { change(); completion?(); return }

        let host = content.superview ?? content
        let view = Overlay(frame: host === content ? content.bounds : content.frame)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.contents = cg
        view.layer?.contentsGravity = .resize
        view.layer?.contentsScale = window?.backingScaleFactor ?? 2
        host.addSubview(view, positioned: .above, relativeTo: nil)
        overlay = view
        change()

        let total = duration(reduceMotion: reduceMotion)
        let size = view.bounds.size
        // one beat for the new appearance to be built underneath before the picture starts to leave
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard overlay === view, let layer = view.layer else { completion?(); return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { if overlay === view { finish() }; completion?() } }
            if reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1; fade.toValue = 0; fade.duration = total
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.opacity = 0
                layer.add(fade, forKey: "fade")
            } else {
                // the old picture shows outside a circle that grows from the switch; inside it the new appearance shows through
                let a = anchor ?? CGPoint(x: size.width - 80, y: 26)
                let centre = CGPoint(x: a.x, y: size.height - a.y)           // layers have their origin at the bottom left
                func path(_ r: CGFloat) -> CGPath {
                    let p = CGMutablePath()
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
                    return p
                }
                let mask = CAShapeLayer()
                mask.frame = CGRect(origin: .zero, size: size)
                mask.fillRule = .evenOdd
                mask.fillColor = NSColor.black.cgColor
                let end = coveringRadius(from: a, in: size) + 8
                mask.path = path(end)
                let grow = CABasicAnimation(keyPath: "path")
                grow.fromValue = path(1); grow.toValue = path(end); grow.duration = total
                grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                mask.add(grow, forKey: "grow")
                layer.mask = mask
                // and the whole picture dissolves over the last part, so the edge of the circle is soft rather than a line
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.55, 1]; fade.duration = total
                layer.opacity = 0
                layer.add(fade, forKey: "fade")
            }
            CATransaction.commit()
        }
        // never left behind, whatever happens to the animation
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.5) { MainActor.assumeIsolated { if overlay === view { finish(); completion?() } } }
    }
}

/// The switch in the rail: a sun and a moon side by side, the one in use lit in gold. Which mode is on is plain at a glance.
struct AppearanceSwitch: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var hover = Box(false)

    var body: some View {
        let light = m.theme.isLight
        Button { m.toggleAppearance(from: m.switchAnchor) } label: {
            HStack(spacing: 0) {
                glyph("sun.max", lit: light)
                glyph("moon", lit: !light)
            }
            .overlay(Rectangle().strokeBorder(Brand.ink.opacity(hover.v ? 0.4 : 0.26), lineWidth: Metrics.hairline))
            .frame(height: 24).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .background(AnchorReporter { m.switchAnchor = $0 })
        .help(AppearanceSwitching.tooltip(family: m.themeFamily, isLight: light))
        .accessibilityLabel("Appearance").accessibilityValue(light ? "Light" : "Dark").accessibilityHint(AppearanceSwitching.tooltip(family: m.themeFamily, isLight: light))
        .accessibilityAddTraits(.isToggle)
    }

    private func glyph(_ name: String, lit: Bool) -> some View {
        Image(systemName: name).font(Typo.sans(11, lit ? .medium : .light))
            .foregroundStyle(lit ? Brand.onAccent : Brand.inkTertiary)
            .frame(width: 26, height: 24)
            .background(Rectangle().fill(lit ? Brand.accent : Color.clear))
    }
}

/// Reports the centre of the view it sits behind, in window coordinates (top-left origin).
private struct AnchorReporter: View {
    let report: (CGPoint) -> Void
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear
                .onAppear { report(CGPoint(x: f.midX, y: f.midY)) }
                .onChange(of: f.midX) { _, x in report(CGPoint(x: x, y: f.midY)) }
        }
    }
}

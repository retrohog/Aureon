import SwiftUI
import AppKit

/// Makes the window look like part of the app instead of a title bar: no title, content under the bar, and the three window buttons moved into
/// the sidebar's header row (centred in a 52-point band, matching `Sidebar`'s header).
struct WindowChrome: NSViewRepresentable {
    static let band: CGFloat = 52

    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let w = window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            // Not movable by its background: SwiftUI wraps every AppKit control (sliders, pop-up menus, check boxes) in a container that counts as
            // background, so with this on, pressing on any of them started dragging the window instead of reaching the control. The title bar still drags.
            w.isMovableByWindowBackground = false
            layoutButtons()
            for n in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.layoutButtons() })
            }
            DispatchQueue.main.async { [weak self] in self?.layoutButtons() }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func layoutButtons() {
            guard let w = window, let close = w.standardWindowButton(.closeButton), let bar = close.superview, let container = bar.superview else { return }
            let band = WindowChrome.band
            // grow the title bar container to the band so the buttons can sit in its middle
            if abs(container.frame.height - band) > 0.5, let frame = container.superview {
                container.frame = NSRect(x: 0, y: frame.bounds.height - band, width: frame.bounds.width, height: band)
                bar.frame = container.bounds
            }
            var x: CGFloat = 20
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = w.standardWindowButton(type) else { continue }
                b.setFrameOrigin(NSPoint(x: x, y: (bar.frame.height - b.frame.height) / 2))
                x += b.frame.width + 8
            }
        }
    }
}

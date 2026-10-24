import AppKit

// Keeps the main window's size and place for each display, and puts it back there at the next launch. The decisions (which frame, kept on a screen) are
// in `WindowMemory`; this only watches the window and writes them.

@MainActor
final class WindowMemoryController: NSObject {
    static let shared = WindowMemoryController()
    private var memory = WindowMemory.load()
    private weak var window: NSWindow?
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    static let minimum = CGSize(width: 860, height: 540)

    private var enabled: Bool { AppDelegate.model?.look.memory.rememberWindow ?? LookSettings.load().memory.rememberWindow }
    private var active: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["AUREON_SNAPSHOT"] == nil && e["AUREON_TESTING"] == nil
    }

    /// The identity of a display that survives restarts.
    static func displayKey(_ s: NSScreen) -> String {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return s.localizedName }
        if let u = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue(), let str = CFUUIDCreateString(nil, u) as String? { return str }
        return "display-\(n)"
    }

    private func visibleFrames() -> [String: CGRect] { Dictionary(NSScreen.screens.map { (Self.displayKey($0), $0.visibleFrame) }, uniquingKeysWith: { a, _ in a }) }

    /// Finds the app's own window (it may take a moment to exist), puts it where it was and starts watching it.
    func attachMainWindow(attempt: Int = 0) {
        guard active else { return }
        guard let w = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is MiniPanel) && !($0 is SplashWindow) }) else {
            if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.attachMainWindow(attempt: attempt + 1) } }
            return
        }
        guard w !== window else { return }
        window = w
        if enabled {
            let key = (w.screen ?? NSScreen.main).map(Self.displayKey)
            if let f = memory.frame(display: key, visible: visibleFrames(), minimum: Self.minimum) { w.setFrame(f, display: true) }
        }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        for n in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.changed() } })
        }
    }

    private func changed() {
        guard active, enabled, let w = window, !w.styleMask.contains(.fullScreen) else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func saveNow() {
        guard active, enabled, let w = window, !w.styleMask.contains(.fullScreen), let s = w.screen ?? NSScreen.main else { return }
        memory.record(w.frame, display: Self.displayKey(s))
        memory.save()
    }

    /// Forgets every remembered frame (Settings → General → Reset window size).
    func forget() { memory = WindowMemory(); WindowMemory.forget() }
}

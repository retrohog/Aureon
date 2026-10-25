import SwiftUI

/// Lets the self-test ask where parts of Now Playing ended up. Nothing is measured unless a test has switched it on, so the views are unchanged for the listener.
@MainActor
enum LayoutProbe {
    static var enabled = false
    /// The window being measured; views that belong to an older one (still tearing down) are ignored.
    private(set) static var token = 0
    private(set) static var frames: [String: CGRect] = [:]
    /// Starts a new measurement and returns the token its window's root view must carry (`.environment(\.probeToken, token)`).
    static func begin() -> Int { token += 1; frames = [:]; return token }
    /// The style each seek bar on screen is drawn in (a seek bar leaves the list when it leaves the window).
    private static var scrubberList: [UUID: String] = [:]
    static var scrubbers: Set<String> { Set(scrubberList.values) }
    static func note(scrubber id: UUID, style: String) { if enabled { scrubberList[id] = style } }
    static func drop(scrubber id: UUID) { scrubberList[id] = nil }
    fileprivate static func record(_ name: String, _ frame: CGRect, token t: Int) { if t == token { frames[name] = frame } }
}

private struct ProbeTokenKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var probeToken: Int { get { self[ProbeTokenKey.self] } set { self[ProbeTokenKey.self] = newValue } }
}

private struct ProbeModifier: ViewModifier {
    let name: String
    @Environment(\.probeToken) private var token
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { LayoutProbe.record(name, $0, token: token) }
    }
}

extension View {
    /// Reports this view's frame (in the window) under `name` while a test is looking.
    @ViewBuilder func layoutProbe(_ name: String) -> some View {
        if LayoutProbe.enabled {
            modifier(ProbeModifier(name: name))
        } else {
            self
        }
    }
}

import Foundation
import SwiftUI
import AppKit

nonisolated(unsafe) private var stageKeepAlive: [AnyObject] = []

/// Opening Now Playing from the player bar and closing it again must leave the whole window clickable: the real ContentView in an ordered-in,
/// far off-screen window, driven with real mouse events.
struct StageInteractionTests {
    @MainActor private func pump(_ secs: Double, _ host: NSView) {
        let end = Date().addingTimeInterval(secs)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    }

    /// Every accessibility element under `root` as (role, label, frame in screen coordinates).
    @MainActor static func elements(_ root: Any, depth: Int = 0) -> [(role: String, label: String, frame: NSRect)] {
        guard depth < 40 else { return [] }
        var out: [(String, String, NSRect)] = []
        let kids: [Any]
        if let e = root as? NSAccessibilityElementProtocol {
            let role = (root as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? ""
            let label = (root as? NSAccessibilityProtocol)?.accessibilityLabel() ?? ""
            let frame = (root as? NSAccessibilityProtocol)?.accessibilityFrame() ?? .zero
            _ = e
            out.append((role, label, frame))
            kids = (root as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
        } else { kids = [] }
        for k in kids { out += elements(k, depth: depth + 1) }
        return out
    }

    @MainActor private func click(_ win: NSWindow, at p: NSPoint) {
        // p in window coordinates (origin bottom-left)
        func ev(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let d = ev(.leftMouseDown) { win.sendEvent(d) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if let u = ev(.leftMouseUp) { win.sendEvent(u) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private struct Rig {
        let m: PlayerModel, stage: StageModel, win: NSWindow, host: NSHostingView<AnyView>
    }

    @MainActor private func makeRig() -> Rig {
        let m = PlayerModel()
        stageKeepAlive.append(m)
        let stage = StageModel()
        stageKeepAlive.append(stage)
        let wav = tempDir("stage").appendingPathComponent("Interactive Tune.wav")
        writeWAV(wav, rate: 8000, bits: 16, frames: 16_000) { f, _ in Int(6000 * sin(Double(f) * 0.2)) }
        m.add(urls: [wav])
        m.tab = .home
        let host = NSHostingView(rootView: AnyView(ContentView(stage: stage).environmentObject(m).frame(width: 1200, height: 800).preferredColorScheme(.dark)))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        win.makeKeyAndOrderFront(nil)
        return Rig(m: m, stage: stage, win: win, host: host)
    }

    /// A click at `p`, measured from the window's top-left corner.
    @MainActor private func click(_ r: Rig, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: r.host.bounds.height - p.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: r.win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { r.win.sendEvent(e) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private struct Probe { var rail = 0, bar = 0 }

    /// How many points of the top rail and of the player bar react to a click (each click is undone straight away).
    @MainActor private func probe(_ r: Rig) -> Probe {
        var out = Probe()
        func reset() {
            r.m.tab = .home; r.m.djMode = false; r.m.showQueue = false; r.m.quickPanel = nil; r.stage.immersive = false; r.stage.lyricsPending = false
            UserDefaults.standard.set(false, forKey: "aureon.lyrics.show"); UserDefaults.standard.set(false, forKey: "aureon.lyrics.expanded")
        }
        reset(); r.win.makeFirstResponder(nil); pump(0.5, r.host)
        // the rail: five destinations down the left of the window
        for y in stride(from: 70.0, to: 420.0, by: 10.0) {
            click(r, CGPoint(x: 36, y: y))
            if r.m.tab != .home || r.m.djMode { out.rail += 1 }
            reset(); RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        pump(0.4, r.host)
        // the bar: the queue button is in its right column, beside lyrics and the output
        for x in stride(from: 900.0, to: 1060.0, by: 6.0) {
            click(r, CGPoint(x: x, y: r.host.bounds.height - PlayerBar.height / 2))
            if r.m.showQueue { out.bar += 1 }
            reset(); RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        pump(0.4, r.host)
        return out
    }

    /// Opening the Gallery from the bar and leaving it again through the rail must leave the whole window clickable: the outgoing page used to stay in
    /// the view tree, invisible, with its scroll view over the window, and swallow the clicks meant for what was under it.
    @MainActor func closeNowPlayingStaysInteractive() {
        guard !NSScreen.screens.isEmpty else { return }
        // lyrics scroll the page to the current line, which is not what is being tested here
        let ud = UserDefaults.standard, savedShow = ud.object(forKey: "aureon.lyrics.show")
        ud.set(false, forKey: "aureon.lyrics.show")
        let savedExpanded = ud.object(forKey: "aureon.lyrics.expanded")
        let r = makeRig()
        defer { r.win.orderOut(nil); r.win.contentView = nil; ud.set(savedShow, forKey: "aureon.lyrics.show"); ud.set(savedExpanded, forKey: "aureon.lyrics.expanded") }
        pump(1.0, r.host)
        let before = probe(r)
        expect(before.rail > 10 && before.bar > 0, "the window answers clicks to begin with: \(before)")
        for round in 0..<3 {
            // open: click the cover in the bar, the way the owner does
            r.m.tab = .home; r.m.showQueue = false; pump(0.4, r.host)
            var opened = false
            for x in stride(from: 30.0, to: 90.0, by: 6.0) where !opened {
                click(r, CGPoint(x: x, y: r.host.bounds.height - PlayerBar.height / 2))
                opened = r.m.tab == .player
            }
            expect(opened, "round \(round): a click on the bar's cover opens the Gallery")
            pump(1.5, r.host)
            // leave: a click on Home in the top bar
            var left = false
            for x in stride(from: 340.0, to: 400.0, by: 6.0) where !left {
                click(r, CGPoint(x: x, y: 32))
                left = r.m.tab != .player
            }
            expect(left, "round \(round): a click on Home leaves the Gallery")
            pump(1.5, r.host)
            let after = probe(r)
            expect(after.rail >= before.rail - 2 && after.bar >= before.bar - 1, "round \(round): after the Gallery the rail and the bar answer as before: \(after) vs \(before)")
            if round == 0 {
                // nothing invisible is left over the window
                func ghosts(_ v: NSView) -> Int { (v is NSScrollView && v.alphaValue < 0.01 ? 1 : 0) + v.subviews.reduce(0) { $0 + ghosts($1) } }
                expect(ghosts(r.host) == 0, "no invisible scroll view is left over the window")
            }
        }
    }
}

func stageInteractionTests() -> [(String, TestFn)] {
    let t = StageInteractionTests()
    return [("ui.closeNowPlayingStaysInteractive", { MainActor.assumeIsolated { t.closeNowPlayingStaysInteractive() } })]
}

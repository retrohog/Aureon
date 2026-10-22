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

    private struct Probe { var sidebar = 0, bar = 0 }

    /// How many points of the sidebar and of the player bar react to a click (each click is undone straight away).
    @MainActor private func probe(_ r: Rig) -> Probe {
        var out = Probe()
        func reset() {
            r.m.tab = .home; r.m.showQueue = false; r.stage.immersive = false; r.stage.lyricsPending = false
            UserDefaults.standard.set(false, forKey: "aureon.lyrics.show"); UserDefaults.standard.set(false, forKey: "aureon.lyrics.expanded")
        }
        reset(); r.win.makeFirstResponder(nil); pump(0.5, r.host)
        for y in stride(from: 140.0, to: 680.0, by: 12.0) {
            click(r, CGPoint(x: 90, y: y))
            if r.m.tab != .home || r.m.djMode { out.sidebar += 1 }
            r.m.djMode = false; reset(); RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        pump(0.4, r.host)
        // the bar: the queue button is at its right end
        for x in stride(from: 1060.0, to: 1190.0, by: 6.0) {
            click(r, CGPoint(x: x, y: r.host.bounds.height - 12 - 39))
            if r.m.showQueue { out.bar += 1 }
            reset(); RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        pump(0.4, r.host)
        return out
    }

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
        if let out = ProcessInfo.processInfo.environment["AUREON_UI_SHOT"] {
            let rep = r.host.bitmapImageRepForCachingDisplay(in: r.host.bounds)!
            r.host.cacheDisplay(in: r.host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        if ProcessInfo.processInfo.environment["AUREON_UI_DUMP"] != nil {
            for y in stride(from: 700.0, to: 800.0, by: 10.0) {
                var line = "y \(Int(y)):"
                for x in stride(from: 240.0, to: 1200.0, by: 80.0) {
                    let v = r.host.hitTest(NSPoint(x: x, y: 800 - y))
                    line += " " + (v.map { String(String(describing: type(of: $0)).prefix(14)) } ?? "nil")
                }
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        }
        FileHandle.standardError.write(Data("PROBE before: sidebar \(before.sidebar) bar \(before.bar) tab \(r.m.tab)\n".utf8))
        if ProcessInfo.processInfo.environment["AUREON_UI_DUMP"] != nil { let again = probe(r); FileHandle.standardError.write(Data("PROBE again (no open/close): sidebar \(again.sidebar) bar \(again.bar)\n".utf8)) }
        expect(before.sidebar > 10 && before.bar > 0, "the window answers clicks to begin with: \(before)")
        for round in 0..<3 {
            // open: click the cover in the bar, the way the owner does
            r.m.tab = .home; r.m.showQueue = false; pump(0.4, r.host)
            var opened = false
            for x in stride(from: 410.0, to: 440.0, by: 5.0) where !opened {
                click(r, CGPoint(x: x, y: r.host.bounds.height - 12 - 39))
                opened = r.stage.immersive
            }
            expect(opened, "round \(round): a click on the bar's cover opens Now Playing")
            if round == 0, let out = ProcessInfo.processInfo.environment["AUREON_UI_SHOT"] {
                pump(0.15, r.host)
                let rep = r.host.bitmapImageRepForCachingDisplay(in: r.host.bounds)!
                r.host.cacheDisplay(in: r.host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + ".early.png"))
            }
            pump(1.5, r.host)
            if round == 0, let out = ProcessInfo.processInfo.environment["AUREON_UI_SHOT"] {
                let rep = r.host.bitmapImageRepForCachingDisplay(in: r.host.bounds)!
                r.host.cacheDisplay(in: r.host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + ".open.png"))
            }
            // close: the chevron next to the window buttons, top left
            var closed = false
            outer: for y in stride(from: 10.0, to: 60.0, by: 6.0) {
                for x in stride(from: 70.0, to: 130.0, by: 8.0) {
                    click(r, CGPoint(x: x, y: y))
                    if !r.stage.immersive { closed = true; break outer }
                }
            }
            expect(closed, "round \(round): a click on the chevron closes Now Playing")
            pump(1.5, r.host)
            if round == 0, let out = ProcessInfo.processInfo.environment["AUREON_UI_SHOT"] {
                let rep = r.host.bitmapImageRepForCachingDisplay(in: r.host.bounds)!
                r.host.cacheDisplay(in: r.host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + ".closed.png"))
                for y in stride(from: 60.0, to: 400.0, by: 60.0) {
                    var chain: [String] = []
                    var v = r.host.hitTest(NSPoint(x: 90, y: r.host.bounds.height - y))
                    while let x = v { chain.append(String(String(describing: type(of: x)).prefix(30))); v = x.superview; if chain.count > 8 { break } }
                    FileHandle.standardError.write(Data("HIT y=\(Int(y)) \(chain.joined(separator: " < "))  tab=\(r.m.tab) imm=\(r.stage.immersive)\n".utf8))
                }
            }
            if ProcessInfo.processInfo.environment["AUREON_UI_DUMP"] != nil {
                for wait in [0.0, 0.3, 1.0] {
                    r.m.tab = .home; pump(0.3, r.host)
                    click(r, CGPoint(x: 70, y: 311)); pump(wait, r.host)
                    FileHandle.standardError.write(Data("DBG round \(round) wait \(wait): tab=\(r.m.tab) key=\(r.win.isKeyWindow) first=\(String(describing: r.win.firstResponder.map { type(of: $0) }))\n".utf8))
                }
            }
            let after = probe(r)
            FileHandle.standardError.write(Data("PROBE round \(round) after close: sidebar \(after.sidebar) bar \(after.bar)\n".utf8))
            expect(after.sidebar == before.sidebar && after.bar == before.bar, "round \(round): after closing Now Playing the sidebar and the bar answer as before: \(after) vs \(before)")
        }
    }
}

func stageInteractionTests() -> [(String, TestFn)] {
    let t = StageInteractionTests()
    return [("ui.closeNowPlayingStaysInteractive", { MainActor.assumeIsolated { t.closeNowPlayingStaysInteractive() } })]
}

import SwiftUI
import AppKit

struct AureonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        WindowGroup("Aureon") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 680)
                .onOpenURL { model.add(urls: [$0]) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Music…") {
                    let p = NSOpenPanel()
                    p.allowsMultipleSelection = true; p.canChooseDirectories = true
                    if p.runModal() == .OK { model.add(urls: p.urls) }
                }.keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
}

func runGUI() { AureonApp.main() }

// MARK: - Snapshot hook (development aid)
// AUREON_SNAPSHOT=/path/out.png [AUREON_TAB=Audio] [AUREON_SNAPSHOT_PLAY=1] Aureon files… renders the real view hierarchy to a PNG and exits.

/// Realistic content for screenshots and previews (never used in normal runs).
@MainActor enum DemoData {
    static func populate(_ m: PlayerModel) {
        func sym(_ n: Int, _ cond: String, _ ens: String, _ album: String, _ year: Int, soloist: String? = nil) -> (facts: FileFacts, tags: TrackMetadata) {
            var t = TrackMetadata(); let names = ["Allegro con brio", "Andante con moto", "Scherzo: Allegro", "Allegro"]
            t.title = "\(n). \(names[n - 1])"; t.album = album; t.year = year; t.trackNumber = n
            t.workTitle = "Symphony No. 5 in C minor"; t.catalog = "Op. 67"; t.key = "C minor"; t.movementNumber = n; t.movementTotal = 4; t.movementTitle = names[n - 1]
            t.credits = [Credit(role: .composer, name: "Ludwig van Beethoven"), Credit(role: .conductor, name: cond), Credit(role: .ensemble, name: ens), Credit(role: .albumArtist, name: ens)]
            if let s = soloist { t.credits.append(Credit(role: .soloist, name: s, instrument: "piano")) }
            return (FileFacts(path: "/demo/\(album)/\(n).flac", duration: 380 + Double(n * 40), sampleRate: 96_000, bitDepth: 24, channels: 2, codec: "FLAC", mtime: 1, size: 1), t)
        }
        var items: [(facts: FileFacts, tags: TrackMetadata)] = []
        for n in 1...4 { items.append(sym(n, "Carlos Kleiber", "Wiener Philharmoniker", "Beethoven: Symphonies 5 & 7", 1975)) }
        for n in 1...4 { items.append(sym(n, "Herbert von Karajan", "Berliner Philharmoniker", "Beethoven: Complete Symphonies", 1962)) }
        for n in 1...3 {
            var t = TrackMetadata(); t.title = ["So What", "Blue in Green", "All Blues"][n - 1]; t.album = "Kind of Blue"; t.year = 1959; t.trackNumber = n
            t.credits = [Credit(role: .artist, name: "Miles Davis"), Credit(role: .albumArtist, name: "Miles Davis")]
            items.append((FileFacts(path: "/demo/kob/\(n).flac", duration: 540, sampleRate: 192_000, bitDepth: 24, channels: 2, codec: "FLAC", mtime: 1, size: 1), t))
        }
        m.library.store?.upsert(items)
        m.library.refresh()
        m.deepDive.state = .loaded(DeepDive.sample)
        if let p = AutoEQParser.parse(HeadphoneEQTests.sample, name: "Sennheiser HD 650", source: "oratory1990") {
            m.settings.rt.headphoneEQ = HeadphoneEQSettings(enabled: true, profile: p); m.settings.rt.crossfeed = CrossfeedSettings(enabled: true, cutoffHz: 700, feedDB: 4.5)
        }
    }
}

extension DemoData {
    /// Procedural album art (no copyrighted covers): a gradient with concentric rings.
    static func coverPNG(_ a: NSColor, _ b: NSColor, accent: NSColor, size: Int = 1400) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])
        let c = CGPoint(x: CGFloat(size) * 0.62, y: CGFloat(size) * 0.42)
        for i in 1...9 {
            ctx.setStrokeColor(accent.withAlphaComponent(0.55 - CGFloat(i) * 0.045).cgColor); ctx.setLineWidth(CGFloat(size) / 90)
            let r = CGFloat(i) * CGFloat(size) * 0.075
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        ctx.setFillColor(accent.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 70, y: c.y - 70, width: 140, height: 140))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 7))
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// Copies of `source` carrying real tags and embedded covers, so snapshots exercise the real import path.
    static func taggedCopies(of source: String) -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aureon-demo-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let kob = coverPNG(NSColor(red: 0.05, green: 0.12, blue: 0.35, alpha: 1), NSColor(red: 0.18, green: 0.42, blue: 0.75, alpha: 1), accent: NSColor(red: 0.98, green: 0.82, blue: 0.4, alpha: 1))
        let sym = coverPNG(NSColor(red: 0.35, green: 0.05, blue: 0.1, alpha: 1), NSColor(red: 0.85, green: 0.3, blue: 0.2, alpha: 1), accent: NSColor(red: 1, green: 0.9, blue: 0.7, alpha: 1))
        let specs: [(String, [(String, String)], Data?)] = [
            ("1 So What", [("TITLE", "So What"), ("ARTIST", "Miles Davis"), ("ALBUM", "Kind of Blue"), ("TRACKNUMBER", "1"), ("TRACKTOTAL", "5"), ("DATE", "1959"), ("GENRE", "Jazz"), ("COMPOSER", "Miles Davis")], kob),
            ("2 Blue in Green", [("TITLE", "Blue in Green"), ("ARTIST", "Miles Davis"), ("ALBUM", "Kind of Blue"), ("TRACKNUMBER", "2"), ("TRACKTOTAL", "5"), ("DATE", "1959"), ("GENRE", "Jazz")], kob),
            ("3 Allegro", [("TITLE", "Symphony No. 5 in C minor, Op. 67: I. Allegro con brio"), ("ARTIST", "Wiener Philharmoniker"), ("ALBUM", "Beethoven: Symphonies 5 & 7"), ("TRACKNUMBER", "1"), ("TRACKTOTAL", "8"),
                              ("DATE", "1975"), ("GENRE", "Classical"), ("COMPOSER", "Ludwig van Beethoven")], sym),
            ("4 Untagged cover", [("TITLE", "No Cover Track"), ("ARTIST", "Unknown Artist"), ("ALBUM", "A Record Without Art"), ("TRACKNUMBER", "1"), ("DATE", "2020"), ("GENRE", "Ambient")], nil)]
        var out: [String] = []
        for (name, tags, art) in specs {
            let f = dir.appendingPathComponent(name + ".flac")
            try? FileManager.default.removeItem(at: f)
            try? FileManager.default.copyItem(atPath: source, toPath: f.path)
            injectVorbisComments(f.path, tags)
            if let art { injectFLACPicture(f.path, image: art) }
            out.append(f.path)
        }
        return out
    }
}

@MainActor func runSnapshot(out: String, files: [String]) {
    _ = NSApplication.shared
    let model = PlayerModel()
    let env = ProcessInfo.processInfo.environment
    if let t = env["AUREON_TAB"], let tab = Tab(rawValue: t) { model.tab = tab }
    let files = env["AUREON_DEMO_ART"] != nil && !files.isEmpty ? DemoData.taggedCopies(of: files[0]) : files
    model.add(urls: files.map { URL(fileURLWithPath: $0) })
    if env["AUREON_DEMO"] != nil { DemoData.populate(model) }
    if env["AUREON_SNAPSHOT_PLAY"] != nil, let first = model.items.first { model.play(first.id) }
    if env["AUREON_DSP"] != nil { model.settings.dsp.enabled = true; model.settings.dsp.eq.enabled = true; model.settings.dsp.eq.bands[5].gainDB = 4; model.settings.dsp.eq.bands[1].gainDB = -3 }
    if env["AUREON_DEMO"] != nil, env["AUREON_TAB"] == "Library" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated {
            if env["AUREON_LIB_WORK"] != nil { model.library.category = .works } 
        } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { MainActor.assumeIsolated { if let r = model.library.rows.first { model.library.selectedID = r.id } } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { MainActor.assumeIsolated {
            if env["AUREON_LIB_WORK"] == nil, case .works(let ws) = model.library.detail, let w = ws.first { model.library.open(work: w) }
        } }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        MainActor.assumeIsolated {
            let h = CGFloat(Double(env["AUREON_HEIGHT"] ?? "") ?? 900), w = CGFloat(Double(env["AUREON_WIDTH"] ?? "") ?? 1100)
            let host = NSHostingView(rootView: ContentView().environmentObject(model).frame(width: w, height: h).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: w, height: h)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            model.player.stop()
            exit(0)
        }
    }
    RunLoop.main.run()
}

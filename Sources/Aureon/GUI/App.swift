import SwiftUI
import AppKit

struct AureonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        WindowGroup("Aureon") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 540)
                .onOpenURL { model.add(urls: [$0]) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 700)
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { ScrollRouter.shared.install() }
        // earlier versions opened large; once per size policy, bring the window to a comfortable default (users can still resize it afterwards)
        let key = "aureon.windowPolicy", policy = 2
        if UserDefaults.standard.integer(forKey: key) < policy {
            UserDefaults.standard.set(policy, forKey: key)
            DispatchQueue.main.async {
                guard let w = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
                w.setContentSize(NSSize(width: 1080, height: 700)); w.center()
            }
        }
    }
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

    /// A small library on disk (real files, real tags, generated covers) imported through the real importer.
    static func importDemoLibrary(of source: String, into model: PlayerModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aureon-demolib-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let albums: [(String, String, Int, String, Double, Int)] = [
            ("Kind of Blue", "Miles Davis", 1959, "Jazz", 0.60, 5), ("Neon Harbour", "Aurora Lane", 2019, "Electronic", 0.80, 9), ("Paper Moons", "The Quiet Hours", 2016, "Indie", 0.08, 11),
            ("Low Tide", "Mara Voss", 2022, "Ambient", 0.48, 7), ("Glass Cathedral", "Ensemble Nord", 2011, "Classical", 0.97, 8), ("Golden Hour", "Sol & Ember", 2021, "Pop", 0.12, 10),
            ("Static Bloom", "Kite Runner", 2018, "Rock", 0.0, 12), ("Cartography", "Ines Calder", 2023, "Folk", 0.33, 9), ("Deep Field", "Halcyon Drift", 2020, "Electronic", 0.68, 6)]
        for (i, a) in albums.enumerated() {
            let dir = root.appendingPathComponent("\(a.1)/\(a.0)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let c1 = NSColor(hue: a.4, saturation: 0.75, brightness: 0.28, alpha: 1), c2 = NSColor(hue: (a.4 + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.85, alpha: 1)
            let art = coverPNG(c1, c2, accent: NSColor(hue: (a.4 + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 1, alpha: 1), size: 700)
            for n in 1...(i == 0 ? 3 : 2) {
                let f = dir.appendingPathComponent("0\(n) Track \(n).flac")
                try? FileManager.default.copyItem(atPath: source, toPath: f.path)
                injectVorbisComments(f.path, [("TITLE", i == 0 ? ["So What", "Freddie Freeloader", "Blue in Green"][n - 1] : "\(a.0) — Part \(n)"), ("ARTIST", a.1), ("ALBUM", a.0),
                                              ("TRACKNUMBER", "\(n)"), ("TRACKTOTAL", "\(a.5)"), ("DATE", "\(a.2)"), ("GENRE", a.3)])
                injectFLACPicture(f.path, image: art)
            }
        }
        _ = model.library.store?.importFolder(root)
        model.library.refresh()
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
    if ProcessInfo.processInfo.environment["AUREON_SLIDER_PROBE"] != nil {
        // does SwiftUI's Slider sit on an NSSlider that the scroll router can find and drive?
        final class Probe: ObservableObject { @Published var v = 0.3 }
        let probe = Probe()
        struct V: View { @ObservedObject var p: Probe; var body: some View { Slider(value: $p.v, in: 0...1).frame(width: 300).padding(20) } }
        let host = NSHostingView(rootView: V(p: probe)); host.frame = NSRect(x: 0, y: 0, width: 340, height: 80)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = host
        host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.3)); host.layoutSubtreeIfNeeded()
        var found: NSSlider?
        func walk(_ v: NSView) { if let sl = v as? NSSlider { found = sl }; v.subviews.forEach(walk) }
        walk(host)
        if let sl = found {
            let before = probe.v
            sl.doubleValue = ScrollStep.apply(value: sl.doubleValue, notches: 2, range: sl.minValue...sl.maxValue)
            sl.sendAction(sl.action, to: sl.target)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            print("NSSlider found: \(type(of: sl)); binding \(before) -> \(probe.v); action set: \(sl.action != nil)")
        } else { print("NO NSSlider in hierarchy") }
        exit(0)
    }
    if ProcessInfo.processInfo.environment["AUREON_AVATAR_TEST"] != nil {
        // portraits are rarely square: render avatars with tall and wide pictures to look for edge artefacts
        func pic(_ w: Int, _ h: Int, _ top: NSColor) -> NSImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(NSColor.darkGray.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(top.cgColor); ctx.fill(CGRect(x: 0, y: h - 40, width: w, height: 40))
            ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
            let cg = ctx.makeImage()!
            return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        }
        // the real ArtistsView, with portraits of several shapes preloaded
        let art = ArtistArt()
        let shapes: [(Int, Int, NSColor)] = [(300, 480, .red), (480, 300, .green), (400, 400, .yellow), (600, 900, .red), (900, 600, .orange), (480, 480, .cyan)]
        var rows: [LibraryModel.Row] = []
        for (i, t) in shapes.enumerated() { rows.append(LibraryModel.Row(id: "a\(i)", title: "Artist \(i)", subtitle: "", count: i + 1)); art.preload(id: "a\(i)", image: pic(t.0, t.1, t.2), portrait: true) }
        let view = ScrollView { ArtistsView(rows: rows, opts: ViewOptions.defaults(for: .artists), open: { _ in }).padding(24) }.environmentObject(art).background(Color(white: 0.06)).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!; host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)); exit(0)
    }
    let model = PlayerModel()
    let env = ProcessInfo.processInfo.environment
    if let t = env["AUREON_TAB"], let tab = Tab(rawValue: t) { model.tab = tab }
    let files = env["AUREON_DEMO_ART"] != nil && !files.isEmpty ? DemoData.taggedCopies(of: files[0]) : files
    model.add(urls: files.map { URL(fileURLWithPath: $0) })
    if env["AUREON_DEMO_LIB"] != nil, let src = ProcessInfo.processInfo.arguments.dropFirst().last { DemoData.importDemoLibrary(of: src, into: model) }
    if env["AUREON_DEMO"] != nil { DemoData.populate(model) }
    if env["AUREON_SNAPSHOT_PLAY"] != nil, let first = model.items.first { model.play(first.id) }
    if env["AUREON_DSP"] != nil { model.settings.dsp.enabled = true; model.settings.dsp.eq.enabled = true; model.settings.dsp.eq.bands[5].gainDB = 4; model.settings.dsp.eq.bands[1].gainDB = -3 }
    if let q = env["AUREON_SEARCH"] { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { model.searchText = q } } }
    // a local fake radio station, so the live Now Playing display can be shown without a network
    if env["AUREON_FAKE_RADIO"] != nil, let aac = RadioTests().aacData(seconds: 6), let srv = try? FakeRadio(audio: aac, mode: .icy(metaint: 4096)) {
        let st = RadioStation(id: "demo", name: "Aurora FM", url: srv.url.absoluteString, favicon: nil, country: "Norway", countryCode: "NO", language: "english", tags: ["ambient"], codec: "AAC", bitrate: 96, votes: 1, homepage: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { model.play(station: st) } }
    }
    if env["AUREON_DJ"] != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { MainActor.assumeIsolated {
            model.djMode = true
            model.library.category = .songs
        } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { MainActor.assumeIsolated {
            let songs = model.library.songs
            if songs.count >= 2 { model.dj.load(model.dj.track(songs[0]), into: model.dj.a); model.dj.load(model.dj.track(songs[3]), into: model.dj.b) }
            model.dj.a.pitch = 0.025; model.dj.b.pitch = -0.012; model.dj.a.low = -8; model.dj.b.high = 3; model.dj.crossfader = -0.25
        } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { MainActor.assumeIsolated { model.dj.a.play(); model.dj.a.seek(to: 4) } }
    }
    // radio and podcast pages fetch from the network when they appear; an offscreen snapshot never "appears", so drive them explicitly
    if env["AUREON_TAB"] == "Radio" {
        Task { @MainActor in
            if let sec = env["AUREON_RADIO_SECTION"], let s = RadioModel.Section(rawValue: sec) { model.radio.section = s }
            await model.radio.load()
            try? await Task.sleep(nanoseconds: 800_000_000)
            for st in model.radio.stations.prefix(40) { if let f = st.favicon { _ = await RemoteImages.shared.image(f, maxPixel: 300) } }
            model.radio.objectWillChange.send()
        }
    }
    if env["AUREON_TAB"] == "Podcasts" {
        Task { @MainActor in
            await model.podcasts.loadShows()
            for sh in model.podcasts.shows.prefix(40) { if let a = sh.artwork { _ = await RemoteImages.shared.image(a, maxPixel: 360) } }
            model.podcasts.objectWillChange.send()
            if env["AUREON_SHOW_FIRST"] != nil, let first = model.podcasts.shows.first {
                model.podcasts.selected = first
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                for u in [model.podcasts.feed?.image, first.artwork].compactMap({ $0 }) { _ = await RemoteImages.shared.image(u, maxPixel: 480) }
                model.podcasts.objectWillChange.send()
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated { for r in model.library.rows { model.artistArt.load(id: r.id, name: r.title) } } }
    // grid cells load their cover when they scroll into view; an offscreen snapshot never "appears", so load them up front
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated { for a in model.library.albums { model.albumArt.load(a) } } }
    if env["AUREON_OPEN_FIRST"] != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated {
            let lib = model.library
            if let id = model.tab == .albums ? lib.albums.first?.id : lib.rows.first?.id { lib.selectedID = id }
        } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { MainActor.assumeIsolated {
            if env["AUREON_OPEN_WORK"] != nil, case .works(let ws) = model.library.detail, let w = ws.first { model.library.open(work: w) }
        } }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        MainActor.assumeIsolated {
            let h = CGFloat(Double(env["AUREON_HEIGHT"] ?? "") ?? 900), w = CGFloat(Double(env["AUREON_WIDTH"] ?? "") ?? 1100)
            let host = NSHostingView(rootView: ContentView().environmentObject(model).frame(width: w, height: h).preferredColorScheme(model.theme.isLight ? .light : .dark))
            host.frame = NSRect(x: 0, y: 0, width: w, height: h)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSAppearance(named: model.theme.isLight ? .aqua : .darkAqua)
            host.layoutSubtreeIfNeeded()
            if env["AUREON_BENCH"] != nil {
                // how long does it take to swap between two heavy pages? (layout + display, synchronous)
                var times: [Double] = []
                let tabs: [Tab] = [.audio, .dsp]
                for i in 0..<16 {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    model.tab = tabs[i % 2]
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    times.append((CFAbsoluteTimeGetCurrent() - t0 - 0.02) * 1000)
                }
                // and the idle cost: 3 s of playback ticks with nothing else going on
                let c0 = CFAbsoluteTimeGetCurrent(); var redraws = 0
                let sub = model.objectWillChange.sink { redraws += 1 }
                RunLoop.current.run(until: Date().addingTimeInterval(3)); sub.cancel()
                FileHandle.standardError.write(Data(String(format: "BENCH switch ms: first %.0f, median %.0f, max %.0f [all: \(times.map { String(Int($0)) }.joined(separator: " "))]; model publishes during 3 s of playback: %d (%.1f s)\n",
                    times[0], times.sorted()[times.count / 2], times.max() ?? 0, redraws, CFAbsoluteTimeGetCurrent() - c0).utf8))
                model.player.stop(); exit(0)
            }
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            model.player.stop()
            exit(0)
        }
    }
    RunLoop.main.run()
}

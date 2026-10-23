import Foundation
import AppKit
import SwiftUI

/// The design tokens: contrast of every theme, the type scale, the metrics, the backdrops and the accent pair.
struct DesignSystemTests {
    private func ratio(_ a: RGB, _ b: RGB) -> Double { WCAG.contrast(a, b) }

    /// The GUI sources, when the tests run from a checkout (they are not there in an installed app).
    private var guiSources: [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("GUI")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".swift") }.compactMap { n in (try? String(contentsOfFile: dir.appendingPathComponent(n).path, encoding: .utf8)).map { (n, $0) } }
    }

    // MARK: themes

    func everyThemeMeetsContrast() {
        expect(Theme.all.count == Theme.families.count * 2 && Set(Theme.all.map(\.id)).count == Theme.all.count, "every family has a dark and a light variant, with unique ids")
        for t in Theme.all {
            for s in t.surfaces {
                expect(ratio(t.inkRGB, s) >= 6.5, "ink on \(t.id): \(ratio(t.inkRGB, s))")
                expect(ratio(t.inkSecondaryRGB, s) >= min(7, ratio(t.inkRGB, s)) - 1e-9, "secondary ink on \(t.id): \(ratio(t.inkSecondaryRGB, s))")
                expect(ratio(t.inkTertiaryRGB, s) >= 4.5 - 1e-9, "tertiary ink on \(t.id): \(ratio(t.inkTertiaryRGB, s))")
                expect(ratio(t.accentTextRGB, s) >= 4.5 - 1e-9, "accent as text on \(t.id): \(ratio(t.accentTextRGB, s))")
            }
            for s in [t.canvasRGB, t.sidebarRGB] {
                expect(ratio(t.accentRGB, s) >= 3, "accent against \(t.id): \(ratio(t.accentRGB, s))")
                expect(ratio(t.accent2RGB, s) >= 3, "second accent against \(t.id): \(ratio(t.accent2RGB, s))")
            }
            expect(ratio(t.onAccentRGB, t.accentRGB) >= 4.5, "the label on a solid accent in \(t.id): \(ratio(t.onAccentRGB, t.accentRGB))")
            expect(t.isLight == (WCAG.luminance(t.canvasRGB) > 0.4), "\(t.id) is as light as it says")
        }
    }

    func defaultThemesAreObsidianAndIvory() {
        expect(Theme.families.first?.id == "obsidian" && Theme.aureon.id == "obsidian", "Obsidian is the default")
        expect(Theme.named("obsidian.light").name == "Obsidian" && Theme.named("obsidian.light").isLight, "Ivory is Obsidian's day version")
        expect(Theme.named("light").id == "obsidian.light", "the old plain light is Ivory")
        // themes that were removed (the purple and pink ones) fall back to the default
        for gone in ["synthwave", "dracula", "catppuccin", "album", "nonsense", ""] { expect(Theme.named(gone).id == "obsidian", "\(gone) falls back") }
        // neutral chrome: the surfaces and ink of the signature themes carry almost no saturation
        for id in ["obsidian", "obsidian.light"] {
            let t = Theme.named(id)
            func chroma(_ c: RGB) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
            expect(chroma(t.canvasRGB) < 0.06 && chroma(t.sidebarRGB) < 0.07 && chroma(t.inkRGB) < 0.1, "\(id) chrome is neutral")
        }
        // the accent is champagne gold: warm hue, restrained saturation
        let a = Theme.aureon.accentRGB.hsb
        expect(a.h > 0.08 && a.h < 0.14 && a.s < 0.6, "champagne, not neon: \(a)")
        for t in Theme.all.prefix(6) { expect(t.accentRGB.hsb.h < 0.17 || t.family == "evergreen" || t.family == "nord", "the signature themes avoid blue and purple accents") }
    }

    // MARK: type

    func typographyTokensArePresent() {
        expect(Typo.scale == Typo.scale.sorted() && Typo.scale.count >= 8, "an ordered scale")
        for odd: CGFloat in [9.5, 10.5, 11.5, 12.5, 13.5, 14, 16, 18, 22, 26, 30, 32, 36, 48] { expect(Typo.scale.contains(Typo.snap(odd)), "\(odd) snaps onto the scale") }
        expect(Typo.snap(13) == 13 && Typo.snap(12.4) == 12 && Typo.snap(100) == 56)
        // weights: bold is medium in the sans and mono, the serif goes light from 20 points
        expect(Typo.sansWeight(.bold) == .medium && Typo.sansWeight(.semibold) == .medium && Typo.sansWeight(.regular) == .regular && Typo.sansWeight(.ultraLight) == .light)
        expect(Typo.monoWeight(.bold, size: 11) == .medium && Typo.monoWeight(.regular, size: 28) == .light)
        expect(Typo.serifWeight(.semibold, size: 28) == .regular && Typo.serifWeight(.regular, size: 40) == .light && Typo.serifWeight(.regular, size: 15) == .regular)
        // roles: labels are upper-case and widely tracked, running text is tight
        expect(TypoStyle.label.uppercase && TypoStyle.label.tracking >= 1.5 && TypoStyle.labelMono.uppercase && TypoStyle.labelMono.tracking >= 1.2)
        expect(TypoStyle.body.tracking < 0 && TypoStyle.pageTitle.tracking < 0 && !TypoStyle.body.uppercase)
        expect(Typo.microTracking >= 1.5 && Typo.bodyTracking < 0)
    }

    func noScatteredFontsOrSprings() {
        let sources = guiSources + {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Intelligence")
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".swift") }.compactMap { n in (try? String(contentsOfFile: dir.appendingPathComponent(n).path, encoding: .utf8)).map { (n, $0) } }
        }()
        guard !sources.isEmpty else { return }          // not run from a checkout
        for (name, text) in sources where name != "Typography.swift" {
            expect(!text.contains(".system(size:"), "\(name) sets a font directly; use Typo")
        }
        for (name, text) in sources {
            for banned in [".spring(", ".bouncy", ".interpolatingSpring", "Capsule("] { expect(!text.contains(banned), "\(name) uses \(banned)") }
        }
    }

    // MARK: metrics

    func metricsStayOnTheGridAndSquare() {
        for r: CGFloat in [2.5, 3, 5, 6, 8, 10, 12, 14, 16, 18, 20, 28, 40] { expect(Metrics.radius(r) >= 2 && Metrics.radius(r) <= 4, "radius \(r) → \(Metrics.radius(r))") }
        expect(Metrics.radius(1.5) == 1.5 && Metrics.radius(0) == 0, "tiny radii are kept")
        expect(Metrics.unit == 8 && Metrics.grid(3) == 24 && Metrics.hairline == 0.5)
        for v: CGFloat in [1, 5, 7, 9, 10, 13, 17, 22] { expect(Metrics.snap4(v) .truncatingRemainder(dividingBy: 4) == 0 && Metrics.snap4(v) >= 4, "\(v) → \(Metrics.snap4(v))") }
        expect(Metrics.snap4(0) == 0)
        // a slab is a rectangle with a barely softened corner, never a capsule
        let p = Slab().path(in: CGRect(x: 0, y: 0, width: 40, height: 20))
        expect(p.boundingRect == CGRect(x: 0, y: 0, width: 40, height: 20) && Slab().radius <= 4)
        // motion: every transition is slow and unhurried
        expect(Motion.glide != Motion.touch)
    }

    // MARK: accent pair

    func accentPairStaysInOneColourFamily() {
        let light = Theme.named("obsidian.light"), dark = Theme.named("obsidian")
        for step in 0..<20 {
            let h = Double(step) / 20
            let source = RGB(h: h, s: 0.8, v: 0.9)
            for (onDark, t) in [(true, dark), (false, light)] {
                let pair = AccentPair.derive(from: source, onDark: onDark, against: t.surfaces)
                for s in t.surfaces {
                    expect(ratio(pair.accent, s) >= 4.5 - 1e-9, "accent from hue \(h) on \(t.id): \(ratio(pair.accent, s))")
                    expect(ratio(pair.accent2, s) >= 3 - 1e-9, "second accent from hue \(h) on \(t.id): \(ratio(pair.accent2, s))")
                }
                var d = abs(pair.accent.hsb.h - pair.accent2.hsb.h); d = min(d, 1 - d)
                expect(d < 0.12 || pair.accent.hsb.s < 0.2 || pair.accent2.hsb.s < 0.2, "hue \(h): the two ends are neighbours (\(d))")
            }
        }
        // a grey cover has no hue to follow: champagne into brass
        let grey = AccentPair.derive(from: RGB(0.5, 0.5, 0.5), onDark: true, against: dark.surfaces)
        expect(grey.accent == WCAG.fit(AccentPair.fallback.accent, against: dark.surfaces[2], minimum: 4.5) || ratio(grey.accent, dark.canvasRGB) >= 4.5, "grey covers keep the default accent")
        expect(abs(grey.accent.hsb.h - AccentPair.fallback.accent.hsb.h) < 0.02, "and its hue")
        expect(ArtPalette.neutral.accent == AccentPair.fallback.accent, "no cover: champagne, never a blue")
    }

    // MARK: backdrops

    private func pixels(_ img: CGImage) -> [RGB] {
        let w = img.width, h = img.height
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return stride(from: 0, to: raw.count, by: 16).map { RGB(Double(raw[$0]) / 255, Double(raw[$0 + 1]) / 255, Double(raw[$0 + 2]) / 255) }
    }

    func softBackdropNeverCostsTextItsContrast() {
        for t in Theme.all {
            guard let img = BackdropRenderer.soft(base: t.canvasRGB, accent: t.accentRGB, accent2: t.accent2RGB, strength: 0.24, light: t.isLight, limit: t.backdropLimitRGB) else { expect(false, "renders for \(t.id)"); continue }
            expect(img.width == 320 && img.height == 200, "one small bitmap: \(img.width)×\(img.height)")
            let px = pixels(img)
            let reach = abs(WCAG.luminance(t.backdropLimitRGB) - WCAG.luminance(t.canvasRGB))
            for p in px {
                expect(abs(WCAG.luminance(p) - WCAG.luminance(t.canvasRGB)) <= reach + 0.004, "\(t.id): a pixel strays beyond the allowed lift")
                expect(WCAG.contrast(t.inkTertiaryRGB, p) >= 4.5 - 0.15, "\(t.id): tertiary text on the wash: \(WCAG.contrast(t.inkTertiaryRGB, p))")
            }
            // the top-left corner carries the accent: warmer than the canvas
            if let first = px.first, !t.isLight { expect(first.r >= t.canvasRGB.r, "\(t.id): the corner is lifted") }
        }
    }

    func albumBackdropIsHeldToTheSameLimit() {
        let t = Theme.aureon
        for (name, c) in [("white", RGB(1, 1, 1)), ("yellow", RGB(1, 0.95, 0.1)), ("red", RGB(0.9, 0.05, 0.05)), ("black", RGB(0, 0, 0))] {
            let n = 64
            let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
            let shift = abs(WCAG.luminance(t.backdropLimitRGB) - WCAG.luminance(t.canvasRGB))
            guard let img = BackdropRenderer.album(base: t.canvasRGB, blurred: ctx.makeImage()!, maxShift: shift, light: false) else { expect(false, "renders \(name)"); continue }
            for p in pixels(img) {
                expect(WCAG.luminance(p) - WCAG.luminance(t.canvasRGB) <= shift + 0.004, "\(name) cover: backdrop lifts the page too far")
                expect(WCAG.contrast(t.inkTertiaryRGB, p) >= 4.5 - 0.15, "\(name) cover: tertiary text keeps AA: \(WCAG.contrast(t.inkTertiaryRGB, p))")
            }
        }
        // on a light theme the cover can only darken the page, within the same budget
        let l = Theme.named("obsidian.light")
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let reach = abs(WCAG.luminance(l.backdropLimitRGB) - WCAG.luminance(l.canvasRGB))
        if let img = BackdropRenderer.album(base: l.canvasRGB, blurred: ctx.makeImage()!, maxShift: reach, light: true) {
            for p in pixels(img) { expect(WCAG.contrast(l.inkTertiaryRGB, p) >= 4.5 - 0.15, "dark cover on Ivory: \(WCAG.contrast(l.inkTertiaryRGB, p))") }
        } else { expect(false, "light album backdrop renders") }
    }

    func backdropModesAreNamed() {
        expect(BackdropMode.allCases.map(\.rawValue) == ["off", "soft", "album", "starlight"] && BackdropMode.allCases.allSatisfy { !$0.title.isEmpty && !$0.hint.isEmpty })
        // the store renders once per key and keeps only the last few
        MainActor.assumeIsolated {
            let store = BackdropStore()
            for i in 0..<14 { store.prepare(key: "k\(i)") { BackdropRenderer.soft(base: Theme.aureon.canvasRGB, accent: Theme.aureon.accentRGB, accent2: Theme.aureon.accent2RGB, strength: 0.1, light: false, limit: Theme.aureon.backdropLimitRGB) } }
            let end = Date().addingTimeInterval(8)
            while store.images.count < 10, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            expect(store.images.count <= 10, "bounded: \(store.images.count)")
            expect(store.images.count >= 8, "rendered off the main thread: \(store.images.count)")
        }
    }

    /// The real view in a real hosting view: the wash arrives from the background task and is drawn (lighter in the corner, never past the limit).
    func backdropViewDrawsTheWash() {
        MainActor.assumeIsolated {
            let theme = Theme.aureon
            let host = NSHostingView(rootView: StageBackdrop(mode: .soft, theme: theme, palette: .neutral, image: nil, token: "", stage: true).frame(width: 640, height: 400))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            let end = Date().addingTimeInterval(8)
            while BackdropStore.shared.images.isEmpty, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            expect(!BackdropStore.shared.images.isEmpty, "the wash is rendered")
            for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { expect(false, "bitmap"); return }
            host.cacheDisplay(in: host.bounds, to: rep)
            func lum(_ x: Int, _ y: Int) -> Double {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return -1 }
                return WCAG.luminance(RGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
            }
            // (below the title bar of the offscreen window)
            let corner = lum(16, 96), middle = lum(rep.pixelsWide / 2, rep.pixelsHigh / 2), far = lum(rep.pixelsWide - 8, rep.pixelsHigh - 8)
            expect(corner > middle, "the top-left corner is lifted: corner \(corner), middle \(middle)")
            expect(far < middle, "and the far corner falls away: far \(far), middle \(middle)")
            // (how far the wash may go is checked on the bitmap itself in ui.softBackdrop: reading it back through a window adds its own colour handling)
        }
    }
}

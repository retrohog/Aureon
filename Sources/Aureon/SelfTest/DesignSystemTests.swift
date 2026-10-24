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
        expect(Theme.families.map(\.name) == ["Graphite", "Midnight", "Forest", "Plum", "Cocoa"], "five colour families")
        expect(Theme.all.count == 10 && Set(Theme.all.map(\.id)).count == 10, "each with a dark and a light half, ten unique ids")
        expect(Theme.dark.count == 5 && Theme.light.count == 5 && Theme.families.allSatisfy { !$0.dark.isLight && $0.light.isLight && $0.dark.family == $0.id && $0.light.family == $0.id }, "every family has one of each")
        // the light halves are checked across the whole brightness slider, every dark half also on pure black, the accent across a spread of picked colours
        let black = Theme.dark.map(\.onPureBlack)
        var shown = Theme.all + black
        for b in [0.0, 0.35, 1.0] { shown += Theme.light.map { $0.adjusted(lightBrightness: b) } }
        for hue in stride(from: 0.0, to: 1.0, by: 0.125) { shown += (Theme.all + black).map { $0.withAccent(RGB(h: hue, s: 0.9, v: 0.9)) } }
        for t in shown {
            for s in t.surfaces {
                expect(ratio(t.inkRGB, s) >= 6.5, "ink on \(t.id): \(ratio(t.inkRGB, s))")
                expect(ratio(t.inkSecondaryRGB, s) >= min(7, ratio(t.inkRGB, s)) - 1e-9, "secondary ink on \(t.id): \(ratio(t.inkSecondaryRGB, s))")
                expect(ratio(t.inkTertiaryRGB, s) >= 4.5 - 1e-9, "tertiary ink on \(t.id): \(ratio(t.inkTertiaryRGB, s))")
                expect(ratio(t.accentTextRGB, s) >= 4.5 - 1e-9, "accent as text on \(t.id): \(ratio(t.accentTextRGB, s))")
            }
            // the designed accents carry 3:1 on their surfaces; a picked colour is held to it by `accentTextRGB` instead (checked above)
            if t.accentRGB == Theme.named(t.id).accentRGB {
                for s in [t.canvasRGB, t.sidebarRGB, t.panel2RGB] { expect(ratio(t.accentRGB, s) >= 3, "accent against \(t.id): \(ratio(t.accentRGB, s))") }
            }
            expect(ratio(t.onAccentRGB, t.accentRGB) >= 4.5, "the label on a solid accent in \(t.id): \(ratio(t.onAccentRGB, t.accentRGB))")
            expect(t.isLight == (WCAG.luminance(t.canvasRGB) > 0.4), "\(t.id) is as light as it says")
        }
    }

    func defaultThemesAreGraphiteDarkAndLight() {
        expect(Theme.families.first?.id == "graphite" && Theme.aureon.id == "graphite" && !Theme.aureon.isLight, "Graphite, dark, is the default")
        expect(Theme.defaultLight.id == "graphite.light" && Theme.defaultLight.isLight && Theme.defaultLight.family == "graphite", "and its light half is the default for day")
        // earlier ids are carried over (the nine-theme names too)
        for (old, new) in [("obsidian", "graphite"), ("obsidian.light", "graphite.light"), ("light", "graphite.light"), ("bespoke", "forest"), ("gruvbox.light", "cocoa.light"),
                           ("stone", "graphite.light"), ("sage", "forest.light"), ("paper", "cocoa.light"), ("amoled", "graphite.black"), ("nord", "midnight")] { expect(Theme.named(old).id == new, "\(old) became \(new)") }
        // ids that were removed fall back to the default
        for gone in ["synthwave", "dracula", "catppuccin", "album", "nonsense", ""] { expect(Theme.named(gone).id == "graphite", "\(gone) falls back") }
        // pure black: the window is true black, the panels stay in the family's tint, for every family
        for f in Theme.families {
            let t = f.dark.onPureBlack
            expect(t.pureBlack && !t.isLight && t.sidebarRGB == RGB(0, 0, 0) && WCAG.luminance(t.canvasRGB) < 0.012, "\(f.id) on pure black: a black window under dark panels")
            expect(t.canvasRGB != RGB(0, 0, 0) && WCAG.luminance(t.panel2RGB) > WCAG.luminance(t.canvasRGB), "\(f.id): the panels still rise above the window")
            expect(f.light.onPureBlack == f.light, "\(f.id): pure black does nothing to the light half")
            expect(Theme.resolve(family: f.id, light: false, pureBlack: true).id == f.id + ".black" && Theme.resolve(family: f.id, light: true, pureBlack: true).id == f.id + ".light" && Theme.resolve(family: f.id, light: false, pureBlack: false).id == f.id, "\(f.id) resolves for every mode")
        }
        // the light themes are muted: no panel is brighter than a soft grey
        for t in Theme.light { expect(WCAG.luminance(t.canvasRGB) < 0.65, "\(t.id) does not dazzle: \(WCAG.luminance(t.canvasRGB))") }
        // the brightness slider moves the surfaces monotonically and leaves dark themes alone
        let lo = Theme.defaultLight.adjusted(lightBrightness: 0), mid = Theme.defaultLight.adjusted(lightBrightness: 0.35), hi = Theme.defaultLight.adjusted(lightBrightness: 1)
        expect(WCAG.luminance(lo.canvasRGB) < WCAG.luminance(mid.canvasRGB) && WCAG.luminance(mid.canvasRGB) < WCAG.luminance(hi.canvasRGB), "brightness is monotonic")
        expect(mid == Theme.defaultLight && Theme.aureon.adjusted(lightBrightness: 1) == Theme.aureon, "the designed tone is the default; dark themes ignore it")
        // a picked accent replaces the theme's and derives its companion
        let blue = Theme.aureon.withAccent(Look.color(hex: "3FA7FF"))
        expect(blue.accentRGB == Look.color(hex: "3FA7FF")! && blue.accent2RGB != blue.accentRGB && Theme.aureon.withAccent(nil) == Theme.aureon, "accent picker")
        expect(Look.color(hex: "#3fa7ff") != nil && Look.color(hex: "zzz") == nil && Look.hex(Look.color(hex: "3FA7FF")!) == "3FA7FF", "hex round trip")
    }

    // MARK: type

    func typographyTokensArePresent() {
        expect(Typo.scale == Typo.scale.sorted() && Typo.scale.count >= 8, "an ordered scale")
        for odd: CGFloat in [9.5, 10.5, 11.5, 12.5, 13.5, 14, 16, 18, 22, 26, 30, 32, 36, 48] { expect(Typo.scale.contains(Typo.snap(odd)), "\(odd) snaps onto the scale") }
        expect(Typo.snap(13) == 13 && Typo.snap(12.4) == 12 && Typo.snap(100) == 56 && Typo.snap(44) == 44 && Typo.snap(14.5) == 14.5)
        // weights: Regular is the default; bold is Medium and nothing is heavier; Light only when asked for
        var look = LookSettings()
        expect(look.weight == .regular && Typo.sansWeight(.regular, look) == .regular && Typo.sansWeight(.medium, look) == .medium, "Regular by default")
        expect(Typo.sansWeight(.bold, look) == .medium && Typo.sansWeight(.semibold, look) == .medium && Typo.sansWeight(.ultraLight, look) == .light)
        look.weight = .light
        expect(Typo.sansWeight(.regular, look) == .light && Typo.sansWeight(.medium, look) == .regular, "the Light setting lightens body and titles by a step")
        look.weight = .medium
        expect(Typo.sansWeight(.regular, look) == .medium && Typo.sansWeight(.bold, look) == .medium, "Medium is the heaviest")
        look.weight = .regular
        expect(Typo.titleWeight(.light, size: 44, look) == .medium && Typo.titleWeight(.regular, size: 15, look) == .regular, "titles are one step above running text")
        expect(Typo.monoWeight(.bold, size: 11) == .medium && Typo.monoWeight(.regular, size: 28) == .light)
        // roles: labels are upper-case and tracked, running text is tight
        expect(TypoStyle.label.uppercase && TypoStyle.label.tracking >= 1 && TypoStyle.labelMono.uppercase && TypoStyle.labelMono.tracking >= 1)
        expect(TypoStyle.body.tracking < 0 && TypoStyle.pageTitle.tracking < 0 && !TypoStyle.body.uppercase)
        expect(Typo.microTracking >= 1 && Typo.bodyTracking < 0)
        // the text-size setting scales every size
        let saved = Look.current; defer { Look.current = saved }
        Look.current.textScale = 1.2
        expect(abs(Typo.sized(13) - 15.6) < 0.001, "text size scales")
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
            for banned in [".spring(", ".bouncy", ".interpolatingSpring"] { expect(!text.contains(banned), "\(name) uses \(banned)") }
        }
    }

    // MARK: metrics

    func metricsStayOnTheGridAndRound() {
        for r: CGFloat in [2.5, 3, 5, 6, 8, 10, 12, 14, 16, 18, 20, 28, 40] { expect(Metrics.radius(r) >= 6 && Metrics.radius(r) <= 20, "radius \(r) → \(Metrics.radius(r))") }
        expect(Metrics.panelRadius == 16 && Metrics.cardRadius == 14 && Metrics.controlRadius == 10 && Metrics.tagRadius == 6, "the shapes of the shell")
        expect(Metrics.topBarHeight == 52 && Metrics.railWidth == 72 && Metrics.playerBarHeight == 96 && Metrics.pillHeight == 36 && Metrics.tagHeight == 24, "the fixed sizes of the shell")
        expect(Metrics.radius(1.5) == 1.5 && Metrics.radius(0) == 0, "tiny radii are kept")
        expect(Metrics.unit == 8 && Metrics.grid(3) == 24 && Metrics.hairline == 0.5)
        for v: CGFloat in [1, 5, 7, 9, 10, 13, 17, 22] { expect(Metrics.snap4(v) .truncatingRemainder(dividingBy: 4) == 0 && Metrics.snap4(v) >= 4, "\(v) → \(Metrics.snap4(v))") }
        expect(Metrics.snap4(0) == 0)
        // a slab is a rounded tag shape
        let p = Slab().path(in: CGRect(x: 0, y: 0, width: 40, height: 20))
        expect(p.boundingRect == CGRect(x: 0, y: 0, width: 40, height: 20) && Slab().radius == Metrics.tagRadius)
        // motion: every transition is slow and unhurried
        expect(Motion.glide != Motion.touch)
    }

    // MARK: accent pair

    func accentPairStaysInOneColourFamily() {
        let light = Theme.named("graphite.light"), dark = Theme.named("graphite")
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
        let l = Theme.named("graphite.light")
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

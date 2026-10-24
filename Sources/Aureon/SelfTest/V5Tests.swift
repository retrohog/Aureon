import SwiftUI
import AppKit
import CoreAudio

nonisolated(unsafe) private var v5KeepAlive: [AnyObject] = []

/// The Album backdrop's intensity levels and the glass accents.
struct BackdropGlassTests {
    private func cover() -> CGImage {
        // four colours, so there is something to take hues from
        let n = 96
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cols: [(Double, Double, Double)] = [(0.9, 0.2, 0.15), (0.15, 0.4, 0.95), (0.2, 0.8, 0.3), (0.95, 0.8, 0.1)]
        for (i, c) in cols.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: (i % 2) * n / 2, y: (i / 2) * n / 2, width: n / 2, height: n / 2))
        }
        return ctx.makeImage()!
    }

    private func pixels(_ img: CGImage) -> [RGB] {
        let w = img.width, h = img.height
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return stride(from: 0, to: raw.count, by: 8).map { RGB(Double(raw[$0]) / 255, Double(raw[$0 + 1]) / 255, Double(raw[$0 + 2]) / 255) }
    }

    func intensityLevelsAreDistinctAndSafe() {
        for id in ["graphite", "stone"] {
            let t = Theme.named(id)
            let shift = abs(WCAG.luminance(t.backdropLimitRGB) - WCAG.luminance(t.canvasRGB))
            var reach: [Double] = []
            for level in BackdropIntensity.allCases {
                guard let img = BackdropRenderer.album(base: t.canvasRGB, blurred: cover(), maxShift: shift, light: t.isLight, intensity: level) else { expect(false, "renders \(id) \(level)"); continue }
                var total = 0.0
                for p in pixels(img) {
                    let d = WCAG.luminance(p) - WCAG.luminance(t.canvasRGB)
                    expect((t.isLight ? -d : d) <= shift * level.reach + 0.006, "\(id) \(level): a pixel is lifted past the level's allowance")
                    expect(WCAG.contrast(t.inkTertiaryRGB, p) >= 4.5 - 0.15, "\(id) \(level): tertiary text keeps AA: \(WCAG.contrast(t.inkTertiaryRGB, p))")
                    expect(WCAG.contrast(t.inkSecondaryRGB, p) >= 7 - 0.3, "\(id) \(level): secondary text keeps 7:1")
                    total += abs(p.r - t.canvasRGB.r) + abs(p.g - t.canvasRGB.g) + abs(p.b - t.canvasRGB.b)
                }
                reach.append(total)
            }
            expect(reach.count == 3 && reach[0] < reach[1] * 0.85 && reach[1] < reach[2] * 0.85, "\(id): subtle < rich < vivid, clearly: \(reach)")
        }
        expect(BackdropIntensity.allCases.map(\.rawValue) == ["subtle", "rich", "vivid"] && BackdropIntensity.rich.reach > BackdropIntensity.subtle.reach && BackdropIntensity.vivid.reach > BackdropIntensity.rich.reach)
    }

    func coverHuesAreTakenAndGreyHasNone() {
        let hues = BackdropRenderer.dominantHues(of: cover(), light: false, saturation: 1)
        expect(hues.count == 3, "three colours")
        let h = hues.map { $0.hsb.h }
        func apart(_ a: Double, _ b: Double) -> Bool { let d = abs(a - b); return min(d, 1 - d) > 0.05 }
        expect(apart(h[0], h[1]) && apart(h[1], h[2]) && apart(h[0], h[2]), "three different hues: \(h)")
        expect(hues.allSatisfy { $0.hsb.s >= 0.39 && $0.hsb.s <= 0.86 }, "clean saturation, never neon")
        let n = 32
        let g = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        g.setFillColor(CGColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)); g.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let grey = BackdropRenderer.dominantHues(of: g.makeImage()!, light: false, saturation: 1)
        expect(grey.count == 3 && grey.allSatisfy { $0.hsb.s < 0.05 }, "a grey cover lends greys")
    }

    func glassFallsBackToFlat() {
        expect(GlassPolicy.surface(enabled: true, reduceTransparency: false) == .glass)
        expect(GlassPolicy.surface(enabled: false, reduceTransparency: false) == .flat, "the setting off: flat")
        expect(GlassPolicy.surface(enabled: true, reduceTransparency: true) == .flat, "Reduce Transparency: flat")
        expect(GlassPolicy.surface(enabled: false, reduceTransparency: true) == .flat)
        expect(GlassPolicy.radius >= 10 && GlassPolicy.radius <= 14 && GlassPolicy.popoverRadius >= 10 && GlassPolicy.flatRadius <= Metrics.panelRadius, "glass stays within the shell's radii")
        MainActor.assumeIsolated {
            let m = PlayerModel(); v5KeepAlive.append(m)
            expect(m.glassAccents || ProcessInfo.processInfo.environment["AUREON_GLASS"] == "0", "on by default")
        }
    }

    func textKeepsContrastOnGlass() {
        for t in Theme.all {
            let s = GlassPolicy.worstCaseSurface(t)
            expect(WCAG.contrast(t.inkRGB, s) >= 6, "\(t.id): ink on glass \(WCAG.contrast(t.inkRGB, s))")
            expect(WCAG.contrast(t.inkSecondaryRGB, s) >= 4.5, "\(t.id): secondary text on glass \(WCAG.contrast(t.inkSecondaryRGB, s))")
            expect(WCAG.contrast(t.inkTertiaryRGB, s) >= 4.5 - 0.5, "\(t.id): tertiary text on glass \(WCAG.contrast(t.inkTertiaryRGB, s))")
            let p = GlassPolicy.worstCaseSurface(t, scrim: GlassPolicy.popoverScrim)
            expect(WCAG.contrast(t.inkSecondaryRGB, p) >= 4.5 && WCAG.contrast(t.inkTertiaryRGB, p) >= 4.5 - 0.5, "\(t.id): text in a pop-up")
        }
    }
}

func backdropGlassTests() -> [(String, TestFn)] {
    let t = BackdropGlassTests()
    return [("ui.intensityLevels", t.intensityLevelsAreDistinctAndSafe), ("ui.coverHues", t.coverHuesAreTakenAndGreyHasNone), ("ui.glassPolicy", t.glassFallsBackToFlat), ("ui.glassContrast", t.textKeepsContrastOnGlass)]
}

/// Atelier → Sound in tabs, and the quick control panel.
@MainActor
struct SoundQuickTests {
    func everySoundSettingIsOnExactlyOneTab() {
        let all = SoundSection.allCases.flatMap(\.groups)
        expect(Set(all).count == all.count, "no group on two tabs")
        for g in SoundGroup.allCases { expect(SoundSection.holding(g) != nil, "\(g) is on a tab") }
        expect(Set(all) == Set(SoundGroup.allCases), "the tabs hold exactly the groups")
        // the fourteen groups of the old single page
        expect(SoundGroup.allCases.map(\.rawValue).sorted() == ["dither", "dsdFiles", "extremeResolution", "headphones", "levelling", "memory", "multichannel", "output", "pcmToDSD", "radio", "room", "transitions", "upsampling", "visualiser"], "nothing was dropped")
        expect(SoundSection.allCases.allSatisfy { $0.groups.count >= 2 && $0.groups.count <= 4 }, "no tab is a wall")
        expect(SoundSection.allCases.map(\.title) == ["Output", "Conversion", "Levels", "Headphones & room", "Playback"])
        let ids = Set(PaletteCatalog.all.map(\.id))
        for s in SoundSection.allCases { expect(ids.contains("sound:" + s.rawValue), "the palette reaches \(s)") }
    }

    func soundTabIsRemembered() {
        let ud = UserDefaults.standard, saved = ud.string(forKey: "aureon.soundSection")
        defer { if let saved { ud.set(saved, forKey: "aureon.soundSection") } else { ud.removeObject(forKey: "aureon.soundSection") } }
        let m = PlayerModel(); v5KeepAlive.append(m)
        m.go(.tab(.albums)); m.showSound(.levels)
        expect(m.tab == .audio && m.soundSection == .levels && !m.djMode, "the palette entry goes to the tab")
        expect(SoundSection.saved("space") == .space && SoundSection.saved("nonsense") == .output && SoundSection.saved(nil) == .output)
        PaletteRunner.run(.sound(.playback), m: m, stage: StageModel(), reduceMotion: true)
        expect(m.soundSection == .playback && m.isCurrent(.tab(.audio)))
    }

    private final class StubDevices: DeviceSwitching {
        var devices: [OutputDeviceInfo]
        var sets = 0
        var deviceID: AudioDeviceID { didSet { sets += 1 } }
        init(_ d: [OutputDeviceInfo], active: AudioDeviceID) { devices = d; deviceID = active; sets = 0 }
    }
    private let devs = [OutputDeviceInfo(id: 11, name: "MacBook Air Speakers", rates: [44_100, 48_000]), OutputDeviceInfo(id: 22, name: "External Headphones", rates: [44_100, 48_000, 88_200, 96_000]),
                        OutputDeviceInfo(id: 33, name: "Studio DAC USB Audio Class 2.0", rates: [44_100, 192_000, 384_000], channels: 8)]

    func switchingUsesTheDevicePathOnce() {
        let h = StubDevices(devs, active: 11)
        expect(QuickDevices.switchTo(22, on: h) == .switched && h.sets == 1 && h.deviceID == 22, "one switch, one change of device")
        expect(QuickDevices.switchTo(22, on: h) == .unchanged && h.sets == 1, "the active one changes nothing")
        h.devices.removeAll { $0.id == 33 }
        expect(QuickDevices.switchTo(33, on: h) == .gone && h.sets == 1 && h.deviceID == 22, "a device that vanished is not switched to; the old one stays")
        expect(QuickDevices.shortName("Studio DAC USB Audio Class 2.0") == "Studio DAC USB" && QuickDevices.shortName("External Headphones") == "External" && QuickDevices.shortName("MacBook Air") == "MacBook Air")
        expect(QuickDevices.capability(devs[1]) == "44.1–96 kHz" && QuickDevices.capability(devs[2]) == "44.1–384 kHz · 8 ch", "rates and outputs: \(QuickDevices.capability(devs[2]))")
    }

    func quickSettingsShareTheSoundPageState() {
        let m = PlayerModel(); v5KeepAlive.append(m)
        let ud = UserDefaults.standard, saved = ud.string(forKey: "aureon.upsampling.last")
        defer { if let saved { ud.set(saved, forKey: "aureon.upsampling.last") } else { ud.removeObject(forKey: "aureon.upsampling.last") } }
        // the panel writes what the Sound page reads, and the page writes what the panel reads
        m.settings.upsampling.mode = .off
        QuickToggle.upsampling.set(true, m)
        expect(m.settings.upsampling.mode != .off && QuickToggle.upsampling.isOn(m), "on in the panel is on on the page")
        let chosen = m.settings.upsampling.mode
        m.settings.upsampling.mode = .double
        expect(QuickToggle.upsampling.isOn(m), "the page's change shows in the panel")
        QuickToggle.upsampling.set(false, m)
        expect(m.settings.upsampling.mode == .off && !QuickToggle.upsampling.isOn(m))
        QuickToggle.upsampling.set(true, m)
        expect(m.settings.upsampling.mode == .double && chosen != .off, "turning it back on restores the target it had")
        QuickToggle.equaliser.set(true, m)
        expect(m.settings.dsp.enabled && m.dspModel.draft.enabled && QuickToggle.equaliser.isOn(m))
        QuickToggle.equaliser.set(false, m)
        expect(!m.settings.dsp.enabled && !QuickToggle.equaliser.isOn(m))
        m.settings.transition.mode = .crossfade; m.settings.replayGain.mode = .album
        expect(m.settings.transition.mode == .crossfade && m.settings.replayGain.mode == .album, "segmented controls are the same bindings")
        m.settings.transition.mode = .off; m.settings.replayGain.mode = .off
        expect(QuickToggle.allCases.count == 3 && Set(QuickToggle.allCases.map(\.title)).count == 3)
    }

    func quickPanelOpensFromEverywhere() {
        let m = PlayerModel(); v5KeepAlive.append(m)
        expect(m.quickPanel == nil)
        m.toggleQuickPanel(.bar); expect(m.quickPanel == .bar, "from the bar")
        m.toggleQuickPanel(.rail); expect(m.quickPanel == nil, "a second press closes")
        PaletteRunner.run(.quickPanel, m: m, stage: StageModel(), reduceMotion: true)
        expect(m.quickPanel == .rail, "the palette command opens it")
        let ids = Set(PaletteCatalog.all.map(\.id))
        expect(ids.contains("act:quickpanel") && ids.contains("act:toggleAppearance") && ids.contains("glass:on") && ids.contains("glass:off"))
        for l in BackdropIntensity.allCases { expect(ids.contains("intensity:" + l.rawValue)) }
    }
}

func soundQuickTests() -> [(String, TestFn)] {
    return [("ui.soundTabs", { MainActor.assumeIsolated { SoundQuickTests().everySoundSettingIsOnExactlyOneTab() } }), ("ui.soundTabRemembered", { MainActor.assumeIsolated { SoundQuickTests().soundTabIsRemembered() } }),
            ("ui.quickSwitch", { MainActor.assumeIsolated { SoundQuickTests().switchingUsesTheDevicePathOnce() } }), ("ui.quickSync", { MainActor.assumeIsolated { SoundQuickTests().quickSettingsShareTheSoundPageState() } }),
            ("ui.quickPanelOpens", { MainActor.assumeIsolated { SoundQuickTests().quickPanelOpensFromEverywhere() } })]
}

/// The light/dark switch, and its transition.
@MainActor
struct AppearanceTests {
    func theSwitchTogglesThePairAndRemembers() {
        let ud = UserDefaults.standard
        let keys = ["aureon.appearance", "aureon.darkTheme", "aureon.lightTheme"]
        let saved = keys.map { ud.string(forKey: $0) }
        defer {
            for (k, v) in zip(keys, saved) { if let v { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) } }
            Theme.current = Theme.aureon
        }
        let m = PlayerModel(); v5KeepAlive.append(m)
        m.choose(theme: Theme.named("graphite")); m.appearance = .dark
        expect(!m.theme.isLight && m.theme.id == "graphite")
        m.choose(theme: Theme.named("sage"))
        expect(m.theme.isLight && m.theme.id == "sage" && m.appearance == .light, "choosing a light theme shows it: \(m.theme.id)")
        m.toggleAppearance(from: nil)
        expect(!m.theme.isLight && m.theme.id == "graphite" && m.appearance == .dark && ud.string(forKey: "aureon.appearance") == "dark", "the switch returns to the dark choice")
        m.toggleAppearance(from: nil)
        expect(m.theme.id == "sage" && ud.string(forKey: "aureon.appearance") == "light" && ud.string(forKey: "aureon.lightTheme") == "sage", "and to the light choice, remembered")
        // Auto keeps both choices, whichever is shown
        m.appearance = .system
        m.choose(theme: Theme.named("plum"))
        expect(m.darkThemeID == "plum" && m.lightThemeID == "sage" && m.appearance == .system, "Auto keeps its mode when a theme is picked")
        expect(AppearanceSwitching.target(isLight: true) == .dark && AppearanceSwitching.target(isLight: false) == .light)
        expect(AppearanceSwitching.tooltip(dark: "plum", light: "sage", isLight: false).contains("Sage") && AppearanceSwitching.tooltip(dark: "plum", light: "sage", isLight: true).contains("Plum"))
        expect(AppearanceMode.allCases.map(\.title) == ["Auto", "Light", "Dark"], "Light, Dark, Auto in Settings")
        // resolving a light theme for the dark slot (or the reverse) falls back to a theme of the right kind
        expect(!Theme.resolve(dark: "stone", light: "stone", wantsLight: false).isLight && Theme.resolve(dark: "graphite", light: "plum", wantsLight: true).isLight)
    }

    func autoFollowsTheSystem() {
        let ud = UserDefaults.standard
        let savedMode = ud.string(forKey: "aureon.appearance")
        defer { if let savedMode { ud.set(savedMode, forKey: "aureon.appearance") } else { ud.removeObject(forKey: "aureon.appearance") }; Theme.current = Theme.aureon }
        let m = PlayerModel(); v5KeepAlive.append(m)
        m.choose(theme: Theme.named("graphite")); m.choose(theme: Theme.named("stone"))
        var light = true
        m.systemIsLight = { light }
        m.appearance = .system
        expect(m.theme.isLight, "Auto, with a light system, is light")
        light = false; m.resolveTheme(persist: false)
        expect(!m.theme.isLight, "and follows it to dark")
        m.appearance = .dark; light = true; m.resolveTheme(persist: false)
        expect(!m.theme.isLight, "a fixed choice ignores the system")
    }

    private func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Color.red.frame(width: 400, height: 300))
        return w
    }
    private func spin(until done: () -> Bool, limit: Double = 3) {
        let end = Date().addingTimeInterval(limit)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func theRevealNeverInterceptsAndIsRemoved() {
        let w = window()
        var changed = 0, completed = false
        ThemeTransition.run(in: w, anchor: CGPoint(x: 350, y: 20), reduceMotion: false, change: { changed += 1 }, completion: { completed = true })
        expect(changed == 1, "the change happens once, at the start")
        expect(ThemeTransition.isRunning, "the old picture is laid over the window")
        if let o = ThemeTransition.overlay {
            expect(o.hitTest(NSPoint(x: 200, y: 150)) == nil && o.hitTest(NSPoint(x: 1, y: 1)) == nil, "clicks go through the overlay")
            expect(!o.acceptsFirstResponder && o.superview != nil)
        } else { expect(false, "overlay exists") }
        spin(until: { !ThemeTransition.isRunning })
        expect(!ThemeTransition.isRunning && completed, "removed when it ends")
        expect(w.contentView?.superview?.subviews.allSatisfy { !($0 is ThemeTransition.Overlay) } == true, "and gone from the window")
        // a second change while one runs replaces it, leaving one at most
        ThemeTransition.run(in: w, anchor: nil, reduceMotion: false, change: {})
        ThemeTransition.run(in: w, anchor: nil, reduceMotion: false, change: {})
        expect(w.contentView?.superview?.subviews.filter { $0 is ThemeTransition.Overlay }.count == 1, "never two overlays")
        spin(until: { !ThemeTransition.isRunning })
        expect(!ThemeTransition.isRunning)
    }

    func reduceMotionIsAPlainShortFade() {
        expect(ThemeTransition.duration(reduceMotion: true) == 0.2 && ThemeTransition.duration(reduceMotion: false) >= 0.5 && ThemeTransition.duration(reduceMotion: false) <= 0.7, "0.5 to 0.7 s, or 0.2 s")
        let w = window()
        var changed = false
        let t0 = Date()
        ThemeTransition.run(in: w, anchor: nil, reduceMotion: true, change: { changed = true })
        expect(changed)
        spin(until: { !ThemeTransition.isRunning })
        expect(!ThemeTransition.isRunning && Date().timeIntervalSince(t0) < 1.0, "done quickly, nothing left")
        // no window: the change still happens
        var n = 0
        ThemeTransition.run(in: nil, anchor: nil, reduceMotion: false, change: { n += 1 })
        expect(n == 1 && !ThemeTransition.isRunning)
        expect(abs(ThemeTransition.coveringRadius(from: CGPoint(x: 0, y: 0), in: CGSize(width: 300, height: 400)) - 500) < 0.001, "the circle reaches the far corner")
    }
}

func appearanceTests() -> [(String, TestFn)] {
    return [("ui.appearanceToggle", { MainActor.assumeIsolated { AppearanceTests().theSwitchTogglesThePairAndRemembers() } }), ("ui.appearanceAuto", { MainActor.assumeIsolated { AppearanceTests().autoFollowsTheSystem() } }),
            ("ui.revealOverlay", { MainActor.assumeIsolated { AppearanceTests().theRevealNeverInterceptsAndIsRemoved() } }), ("ui.revealReduceMotion", { MainActor.assumeIsolated { AppearanceTests().reduceMotionIsAPlainShortFade() } })]
}

/// Changes of tab: a calm fade in place, retargeting, the page that leaves.
struct TabSwitchTests {
    func theFadeIsShortAndMovesNothing() {
        expect(TabMotion.allowedDurations.contains(TabMotion.duration) && TabMotion.duration == 0.18, "a quick fade, 0.12 to 0.22 s: \(TabMotion.duration)")
        let fade = TabMotion.plan(mode: .fade), none = TabMotion.plan(mode: .none)
        expect(fade.animated && TabMotion.allowedDurations.contains(fade.duration) && fade.animation != nil, "the default fades")
        expect(!none.animated && none.duration == 0 && none.animation == nil, "None changes pages at once")
        expect(TabMotion.Mode.allCases.map(\.title) == ["Fade", "None"] && TabMotion.Mode.saved(nil) == .fade && TabMotion.Mode.saved("none") == .none && TabMotion.Mode.saved("junk") == .fade, "Fade by default, and remembered")
        var s = TabSwitchState<String>("a")
        _ = s.switchTo("b")
        let fields = Mirror(reflecting: s).children.compactMap(\.label)
        expect(!fields.contains { $0.lowercased().contains("offset") || $0.lowercased().contains("scale") || $0.lowercased().contains("dx") || $0.lowercased().contains("direction") }, "no offset, scale or direction anywhere in the change: \(fields)")
        expect(s.opacity("b") == 0 && s.opacity("a") == 1, "the arriving page starts clear in its place")
        s.settle()
        expect(s.opacity("b") == 1 && s.opacity("a") == 0, "and the fade is all that happens")
    }

    func aChangeRetargetsInsteadOfQueuing() {
        var s = TabSwitchState<String>("a")
        expect(s.pages == ["a"] && s.opacity("a") == 1)
        expect(s.switchTo("b"))
        expect(s.outgoing == "a" && s.incoming == "b" && s.pages == ["a", "b"], "one leaves, one arrives")
        s.settle()
        expect(s.switchTo("c"))
        expect(s.outgoing == "b" && s.incoming == "c" && s.pages == ["b", "c"] && s.opacities["a"] == nil, "never more than one page leaving")
        let before = s.opacity("b")
        expect(s.switchTo("b"))
        expect(s.incoming == "b" && s.outgoing == "c" && s.opacity("b") == before && s.pages == ["c", "b"], "returning reuses the page, no duplicate")
        expect(!s.switchTo("b"), "a change to the page on show is nothing")
    }

    func theOutgoingPageIsInertAndRemoved() {
        var s = TabSwitchState<Int>(1)
        _ = s.switchTo(2)
        expect(!s.answersClicks(1) && s.answersClicks(2), "from the first moment only the arriving page answers clicks")
        let g = s.generation
        s.finish(generation: g - 1)
        expect(s.outgoing == 1, "a stale timer does nothing")
        s.finish(generation: g)
        expect(s.outgoing == nil && s.pages == [2] && s.opacities[1] == nil, "gone from the tree when the change ends")
        _ = s.switchTo(3); _ = s.switchTo(4)
        s.finish(generation: s.generation)
        expect(s.pages == [4] && s.opacities.count == 1, "after quick changes, one page remains")
        expect(s.deferred.contains(4), "a page that arrives through a change is built a beat later, while it is still clear")
        s.built(4); expect(!s.deferred.contains(4))
    }

    func noneReplacesAtOnce() {
        var s = TabSwitchState<Int>(1)
        s.replace(with: 5)
        expect(s.pages == [5] && s.outgoing == nil && s.opacity(5) == 1 && s.answersClicks(5) && !s.answersClicks(1), "the new page is simply there, with nothing left of the old")
        _ = s.switchTo(6)
        s.replace(with: 7)
        expect(s.pages == [7] && s.opacities.count == 1, "even in the middle of a fade")
    }

    func nothingOnTheNowPlayingPageFliesOrResizesInAnimation() {
        expect(StageMotion.expand(false) == StageMotion.expand(true) && StageMotion.collapse(false) == StageMotion.collapse(true), "one motion, with or without Reduce Motion")
    }
}

func tabSwitchTests() -> [(String, TestFn)] {
    let t = TabSwitchTests()
    return [("ui.tabFade", t.theFadeIsShortAndMovesNothing), ("ui.tabRetarget", t.aChangeRetargetsInsteadOfQueuing), ("ui.tabOutgoing", t.theOutgoingPageIsInertAndRemoved), ("ui.tabNone", t.noneReplacesAtOnce), ("ui.tabStageMotion", t.nothingOnTheNowPlayingPageFliesOrResizesInAnimation)]
}

/// The launch animation: when it shows, when it ends, and that nothing of it is left behind.
@MainActor
struct SplashTests {
    private func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -7000, y: -7000, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Color.blue.frame(width: 400, height: 300))
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        return w
    }
    private func spin(until done: () -> Bool, limit: Double = 5) {
        let end = Date().addingTimeInterval(limit)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    /// Splash windows still on screen (a closed window can linger in the list until the autorelease pool drains, but is not visible).
    private var splashWindows: [NSWindow] { NSApp?.windows.filter { $0 is SplashWindow && $0.isVisible } ?? [] }

    func flagsAndSettingTurnItOff() {
        expect(SplashPolicy.enabled(environment: [:], setting: true), "on by default when nothing says otherwise")
        expect(!SplashPolicy.enabled(environment: ["AUREON_NO_SPLASH": "1"], setting: true), "AUREON_NO_SPLASH")
        expect(!SplashPolicy.enabled(environment: ["AUREON_SNAPSHOT": "/tmp/x.png"], setting: true), "never in a snapshot")
        expect(!SplashPolicy.enabled(environment: ["AUREON_TESTING": "1"], setting: true), "never in tests")
        expect(!SplashPolicy.enabled(environment: [:], setting: false), "the Settings switch")
        expect(SplashPolicy.duration >= 2.4 && SplashPolicy.duration <= 2.8 && SplashPolicy.hardCap == 4 && SplashPolicy.dissolve >= 0.4 && SplashPolicy.dissolve <= 0.5, "about 2.6 s, capped at 4 s, 0.4 to 0.5 s dissolve")
        expect(SplashPolicy.reducedHold == 0.6, "Reduce Motion holds the finished mark 0.6 s")
    }

    func endsWhenBothAreDoneOrAtTheCap() {
        var f = SplashFinish()
        expect(!f.shouldFinish(elapsed: 1), "running")
        f.animationDone = true
        expect(!f.shouldFinish(elapsed: 2.4), "the animation alone is not enough: the start-up is still going")
        f.startupDone = true
        expect(f.shouldFinish(elapsed: 2.4), "both done")
        var slow = SplashFinish(); slow.animationDone = true
        expect(!slow.shouldFinish(elapsed: 3.9) && slow.shouldFinish(elapsed: 4.0), "a start-up that never ends cannot hold it past 4 s")
        var early = SplashFinish(); early.startupDone = true
        expect(!early.shouldFinish(elapsed: 1), "quick start-up still lets the animation play")
        var skipped = SplashFinish(); skipped.skipped = true
        expect(skipped.shouldFinish(elapsed: 0.1), "a click or key")
    }

    func theSceneStartsEmptyAndEndsWithTheName() {
        let scene = SplashScene()
        scene.apply(at: 0)
        let group = scene.root.sublayers!.first { $0.name == "mark" }!
        let word = scene.tracks.first { $0.layer is CATextLayer && $0.keyPath == "opacity" }!.layer
        expect(group.opacity == 0 && word.opacity == 0, "starts with nothing on screen")
        scene.apply(at: SplashPolicy.duration)
        expect(word.opacity == 1 && group.opacity == 1, "the mark and the name at the end")
        expect(scene.image(at: 1.3, scale: 1) != nil && scene.image(at: 2.1, scale: 1)?.width == 520, "a real picture at any moment")
        scene.tearDown()
        expect(scene.root.sublayers?.isEmpty ?? true && scene.tracks.isEmpty, "everything let go")
    }

    private func layer(_ scene: SplashScene, _ name: String) -> CALayer? { scene.root.sublayers?.first { $0.name == "mark" }?.sublayers?.first { $0.name == name } }
    private func track(_ scene: SplashScene, _ name: String, _ keyPath: String) -> SplashScene.Track? {
        guard let l = layer(scene, name) else { return nil }
        return scene.tracks.first { $0.layer === l && $0.keyPath == keyPath }
    }
    private func number(_ t: SplashScene.Track?, _ time: Double) -> Double { (t?.value(time) as? NSNumber)?.doubleValue ?? .nan }

    func theLogoNeverMovesAndTheRingIsLayeredAroundThePlanet() {
        let scene = SplashScene()
        let group = scene.root.sublayers!.first { $0.name == "mark" }!
        var seen: Set<String> = []
        for t in stride(from: 0.0, through: SplashPolicy.duration, by: 0.1) {
            scene.apply(at: t)
            seen.insert("\(group.position.x),\(group.position.y)|\(group.transform.m11),\(group.transform.m22)")
        }
        expect(seen.count == 1 && group.position.x == SplashScene.planetX, "the planet's position and size never change: \(seen)")
        expect(!scene.tracks.contains { $0.layer === group && $0.keyPath != "opacity" }, "the mark only fades in: nothing moves or turns it")
        expect(!scene.tracks.contains { $0.keyPath == "transform" }, "nothing is rotated")
        // the layers, bottom to top: the back of the ring is under the planet, the front over it
        let names = group.sublayers!.map { $0.name ?? "" }
        func index(_ n: String) -> Int { names.firstIndex(of: n) ?? -1 }
        let planet = index("planet")
        expect(planet > 0, "the planet is there")
        for back in ["ring.back.A.gold", "ring.back.C.gold", "ring.bitmap.back", "head.back", "ring.glow"] { expect(index(back) >= 0 && index(back) < planet, "\(back) is under the planet") }
        for front in ["ring.front.B.gold", "ring.front.line.1", "ring.bitmap.front", "head.front"] { expect(index(front) > planet, "\(front) is over the planet") }
        expect(layer(scene, "planet")?.opacity == 1 && layer(scene, "planet")?.contents != nil, "the planet is a whole, opaque picture")
    }

    func theRingDrawsItselfIntoAClosedLoop() {
        let scene = SplashScene()
        let A = track(scene, "ring.back.A.gold", "strokeEnd") ?? scene.tracks.first { ($0.layer as? CAShapeLayer)?.name == "ring.back.A" && $0.keyPath == "strokeEnd" }
        func end(_ n: String, _ t: Double) -> Double {
            number(scene.tracks.first { ($0.layer as? CAShapeLayer)?.name == n && $0.keyPath == "strokeEnd" }, t)
        }
        _ = A
        expect(end("ring.back.A", 0.4) == 0 && end("ring.front.B", 0.4) == 0 && end("ring.back.C", 0.4) == 0, "nothing is drawn at first")
        for n in ["ring.back.A", "ring.front.B", "ring.back.C"] { expect(end(n, SplashScene.ringDraw.1) == 1 && end(n, SplashPolicy.duration) == 1, "\(n) is complete when the loop closes") }
        // the pieces draw in turn round the planet: back right, front, back left
        for t in stride(from: 0.4, through: 1.3, by: 0.02) {
            if end("ring.front.B", t) > 0 { expect(end("ring.back.A", t) == 1, "the front is drawn after the back right: t=\(t)") }
            if end("ring.back.C", t) > 0 { expect(end("ring.front.B", t) == 1, "the back left follows the front: t=\(t)") }
        }
        // one closed loop: each piece ends where the next begins, and the last ends where the first began
        let r = (418.0, 103.0, 0.0)
        func pt(_ phi: Double) -> CGPoint { SplashScene.ringPoint(phi: phi, rx: r.0, ry: r.1, cy: r.2) }
        func same(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.001 }
        for (g, h) in [(Double.pi / 2, Double.pi / 2), (3 * Double.pi / 2, 3 * Double.pi / 2), (2 * Double.pi, 0.0)] { expect(same(pt(g), pt(h)), "the pieces meet at \(g)") }
        let boxes = ["ring.back.A", "ring.front.B", "ring.back.C"].map { n in (scene.tracks.compactMap { $0.layer as? CAShapeLayer }.first { $0.name == n }!.path!.boundingBoxOfPath) }
        let full = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        expect(abs(full.width - 2 * 418 * 0.235 * cos(15 * .pi / 180)) < 12 && full.height > 40, "together they go all the way round: \(full)")
        // it starts hidden, behind the planet, and comes out at the planet's edge
        let centre = SplashScene.layerPoint(CGPoint(x: 512, y: 566)), radius = 238 * SplashScene.unit
        let start = SplashScene.headPosition(0)
        expect(hypot(start.x - centre.x, start.y - centre.y) < radius - 4, "the stroke begins inside the planet's disc, where the planet covers it")
        let tip = SplashScene.layerPoint(pt(.pi / 2))
        expect(hypot(tip.x - centre.x, tip.y - centre.y) > radius + 20, "and reaches the open sky past the edge before it crosses the front")
        // the ring's lines follow with a short stagger
        let l1 = number(scene.tracks.first { ($0.layer as? CAShapeLayer)?.name == "ring.front.line.1" && $0.keyPath == "strokeEnd" }, 0.8)
        let l3 = number(scene.tracks.first { ($0.layer as? CAShapeLayer)?.name == "ring.front.line.3" && $0.keyPath == "strokeEnd" }, 0.8)
        expect(l1 >= l3 && l1 > 0, "the fine lines are drawn a little after the band")
    }

    private func bytes(_ img: CGImage) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: img.width * img.height * 4)
        raw.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        return raw
    }
    /// How many pixels inside the planet's disc (less a 4-point margin) differ between two pictures.
    private func differencesInDisc(_ a: CGImage, _ b: CGImage) -> Int {
        let pa = bytes(a), pb = bytes(b), w = a.width, h = a.height
        let cx = SplashScene.planetX, cy = Double(h) - Double(h) / 2, radius = 238 * SplashScene.unit - 4
        var count = 0
        for y in 0..<h {
            for x in 0..<w where hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) < radius {
                let i = (y * w + x) * 4
                if abs(Int(pa[i]) - Int(pb[i])) > 2 || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > 2 || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 2 { count += 1 }
            }
        }
        return count
    }

    func noRingShowsInsideThePlanetWhileItIsBehind() {
        let scene = SplashScene()
        guard let reference = scene.image(at: 0.5, scale: 1) else { expect(false, "renders"); return }
        // the back piece is drawn: it must never show over the planet's face (the front piece has not started)
        let frontStarts = stride(from: 0.4, through: 1.3, by: 0.01).first { number(scene.tracks.first { ($0.layer as? CAShapeLayer)?.name == "ring.front.B" && $0.keyPath == "strokeEnd" }, $0) > 0 } ?? 0.7
        var checked = 0
        for t in stride(from: 0.5, to: frontStarts - 0.01, by: 0.05) {
            guard let img = scene.image(at: t, scale: 1) else { continue }
            expect(differencesInDisc(reference, img) == 0, "t=\(t): the ring shows through the planet (\(differencesInDisc(reference, img)) pixels)")
            checked += 1
        }
        expect(checked >= 2, "frames checked: \(checked)")
        // the front piece appears over the face only once it has been drawn there
        if let early = scene.image(at: frontStarts - 0.02, scale: 1), let late = scene.image(at: 1.2, scale: 1) {
            expect(differencesInDisc(reference, early) == 0 && differencesInDisc(reference, late) > 150, "the front arc crosses the face at the end, not at the start")
            // and the closing back piece (the left side, behind) does not show either: from the front arc's completion to the end of the loop the face is unchanged
            if let a = scene.image(at: 1.12, scale: 1), let b = scene.image(at: 1.27, scale: 1) {
                let doneB = number(scene.tracks.first { ($0.layer as? CAShapeLayer)?.name == "ring.front.B" && $0.keyPath == "strokeEnd" }, 1.12)
                expect(doneB == 1 && differencesInDisc(a, b) == 0, "while the left back piece is drawn, nothing changes on the planet's face")
            }
        }
    }

    func theStarAndTheNameKeepTheirMoments() {
        let scene = SplashScene()
        let starLayer = scene.root.sublayers!.first { $0.contents != nil && $0.bounds.width < 100 && $0.name == nil }!
        let star = scene.tracks.first { $0.layer === starLayer && $0.keyPath == "position" }!
        let starOpacity = scene.tracks.first { $0.layer === starLayer && $0.keyPath == "opacity" }!
        let word = scene.tracks.first { $0.layer is CATextLayer && $0.keyPath == "opacity" }!
        func x(_ t: Double) -> Double { Double((star.value(t) as! NSValue).pointValue.x) }
        func o(_ t: Double, _ tr: SplashScene.Track) -> Double { (tr.value(t) as! NSNumber).doubleValue }
        let closes = SplashScene.ringDraw.1
        expect(o(closes - 0.05, starOpacity) == 0 && o(closes, starOpacity) == 0, "the star does not appear before the loop is closed")
        expect(SplashScene.starFlight.0 >= closes && o(SplashScene.starFlight.0 + 0.1, starOpacity) > 0.9, "it leaves the ring just after the loop closes")
        let tip = SplashScene.scenePoint(SplashScene.ringPoint(phi: .pi / 2, rx: 418, ry: 103, cy: 0))
        expect(abs(x(SplashScene.starFlight.0) - Double(tip.x)) < 1, "from the ring's right end")
        expect(x(1.45) < x(1.6) && x(1.6) < x(1.8) && x(1.8) <= x(1.9), "it shoots off to the right")
        expect(abs(x(2.0) - x(1.9)) < 0.01 && x(1.9) > SplashScene.wordX + 180, "and has arrived, beyond the name")
        expect(o(1.55, word) == 0 && o(1.95, word) == 1 && o(2.3, word) == 1, "the name pops out after the star leaves")
        let wipe = scene.tracks.first { $0.layer is CAGradientLayer && $0.keyPath == "transform.scale.x" && $0.layer.name == nil }!
        func w(_ t: Double) -> Double { (wipe.value(t) as! NSNumber).doubleValue }
        expect(w(1.6) == 0 && w(1.95) > 0.3 && w(1.95) < 0.95 && w(2.3) >= 1, "the mask wipes it open along the trail")
        expect(SplashScene.starFlight == (1.4, 1.9) && SplashScene.ringDraw == (0.4, 1.3) && SplashScene.wordReveal == (1.6, 2.3) && SplashScene.planetIn == (0.0, 0.5), "the timeline")
    }

    func runsAndLeavesNothing() {
        let main = window()
        let c = SplashController.shared
        var readyAt: Date?
        let t0 = Date()
        var done = false
        c.begin(config: .fast, findMain: { main }, startupReady: {
            if readyAt == nil, Date().timeIntervalSince(t0) > 0.7 { readyAt = Date() }
            return readyAt != nil
        }, completion: { done = true })
        expect(c.isRunning && c.window != nil && c.window is SplashWindow, "the splash window is up")
        expect(c.window?.canBecomeKey == false && c.window?.canBecomeMain == false, "it never becomes the key window")
        spin(until: { main.alphaValue == 0 }, limit: 1)
        expect(main.alphaValue == 0 && main.ignoresMouseEvents, "the app's window waits, invisible and inert, while it runs")
        spin(until: { done })
        expect(done && !c.isRunning, "finished")
        expect(Date().timeIntervalSince(t0) >= 0.65, "it waited for the start-up (0.7 s) though the animation took 0.3 s")
        expect(c.window == nil && splashWindows.isEmpty, "no splash window remains")
        expect(main.alphaValue == 1 && !main.ignoresMouseEvents, "the app's window is whole again and takes clicks")
        expect(main.isKeyWindow || !(NSApp?.isActive ?? false), "and it is the key window")
    }

    func theCapEndsItWhateverTheStartupDoes() {
        let main = window()
        let c = SplashController.shared
        var cfg = SplashController.Config.fast
        cfg.hardCap = 0.6
        var done = false
        let t0 = Date()
        c.begin(config: cfg, findMain: { main }, startupReady: { false }, completion: { done = true })
        spin(until: { done }, limit: 4)
        let took = Date().timeIntervalSince(t0)
        expect(done && c.window == nil && splashWindows.isEmpty, "gone")
        expect(took >= 0.55 && took < 2.0, "at the cap, not before and not long after: \(took)")
        expect(main.alphaValue == 1, "the window is shown even though the start-up never reported")
    }

    func aClickOrKeySkipsIt() {
        let main = window()
        let c = SplashController.shared
        var cfg = SplashController.Config.fast
        cfg.duration = 5; cfg.hardCap = 8
        var done = false
        let t0 = Date()
        c.begin(config: cfg, findMain: { main }, startupReady: { true }, completion: { done = true })
        spin(until: { false }, limit: 0.2)
        expect(c.isRunning, "still running a moment in")
        c.skip()
        spin(until: { done }, limit: 3)
        expect(done && c.window == nil && splashWindows.isEmpty, "skipped, and nothing left")
        expect(Date().timeIntervalSince(t0) < 2, "at once, not after the 5 s")
        expect(main.alphaValue == 1, "and the app's window is there")
    }

    func theSplashClosingNeverQuitsTheApp() {
        expect(!AppDelegate.quitsWhenTheLastWindowCloses(appWindowAppeared: false), "before the app's own window has appeared, closing the splash must not quit the app")
        expect(AppDelegate.quitsWhenTheLastWindowCloses(appWindowAppeared: true), "afterwards the app quits when its last window closes, as it always did")
    }

    func theAppWindowIsRequestedWhenNoneOpened() {
        let regular = window()
        let splash = SplashWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        expect(SplashController.needsAppWindow([]) && SplashController.needsAppWindow([splash]), "only the splash (or nothing) is open: the app's window is needed")
        expect(!SplashController.needsAppWindow([splash, regular]) && !SplashController.needsAppWindow([regular]), "a window of the app is open: nothing to do")
    }

    func reduceMotionHoldsTheMarkAndFades() {
        let main = window()
        let c = SplashController.shared
        var cfg = SplashController.Config.fast
        cfg.reduceMotion = true
        var done = false
        let t0 = Date()
        c.begin(config: cfg, findMain: { main }, startupReady: { true }, completion: { done = true })
        expect(c.isRunning)
        spin(until: { done }, limit: 3)
        expect(done && splashWindows.isEmpty && main.alphaValue == 1, "a short hold, a plain fade, nothing left")
        expect(Date().timeIntervalSince(t0) < 1.5)
        expect(SplashPolicy.reducedDissolve == 0.2)
    }
}

func splashTests() -> [(String, TestFn)] {
    return [("ui.splashFlags", { MainActor.assumeIsolated { SplashTests().flagsAndSettingTurnItOff() } }), ("ui.splashFinish", { MainActor.assumeIsolated { SplashTests().endsWhenBothAreDoneOrAtTheCap() } }),
            ("ui.splashScene", { MainActor.assumeIsolated { SplashTests().theSceneStartsEmptyAndEndsWithTheName() } }), ("ui.splashPlanetRing", { MainActor.assumeIsolated { SplashTests().theLogoNeverMovesAndTheRingIsLayeredAroundThePlanet() } }), ("ui.splashLoop", { MainActor.assumeIsolated { SplashTests().theRingDrawsItselfIntoAClosedLoop() } }), ("ui.splashBehind", { MainActor.assumeIsolated { SplashTests().noRingShowsInsideThePlanetWhileItIsBehind() } }), ("ui.splashTiming", { MainActor.assumeIsolated { SplashTests().theStarAndTheNameKeepTheirMoments() } }), ("ui.splashRun", { MainActor.assumeIsolated { SplashTests().runsAndLeavesNothing() } }),
            ("ui.splashCap", { MainActor.assumeIsolated { SplashTests().theCapEndsItWhateverTheStartupDoes() } }), ("ui.splashSkip", { MainActor.assumeIsolated { SplashTests().aClickOrKeySkipsIt() } }),
            ("ui.splashReduceMotion", { MainActor.assumeIsolated { SplashTests().reduceMotionHoldsTheMarkAndFades() } }), ("ui.splashNoQuit", { MainActor.assumeIsolated { SplashTests().theSplashClosingNeverQuitsTheApp() } }), ("ui.splashAppWindow", { MainActor.assumeIsolated { SplashTests().theAppWindowIsRequestedWhenNoneOpened() } })]
}

/// Tester feedback: a waveform that can be read on every background, a seek that always answers, a volume that scrolling cannot jump, and Focus.
@MainActor
struct FeedbackTests {
    func theWaveformIsReadableOnEveryBackground() {
        var worstPlayed = 99.0, worstPair = 99.0, worstUnplayed = 99.0
        for t in Theme.all {
            let wc = WaveformColors.resolve(t)
            for (i, s) in WaveformColors.surfaces(for: t).enumerated() {
                for (name, p) in [("played", wc.played), ("played end", wc.played2)] {
                    let c = WCAG.contrast(p, s)
                    worstPlayed = min(worstPlayed, c)
                    expect(c >= WaveformColors.playedAgainstBackground - 0.05, "\(t.id) surface \(i): \(name) vs background \(c)")
                }
                let u = WCAG.contrast(wc.unplayed, s)
                worstUnplayed = min(worstUnplayed, u)
                expect(u >= WaveformColors.unplayedAgainstBackground - 0.02, "\(t.id) surface \(i): the unplayed part is seen: \(u)")
            }
            for (name, p) in [("played", wc.played), ("played end", wc.played2)] {
                let c = WCAG.contrast(p, wc.unplayed)
                worstPair = min(worstPair, c)
                expect(c >= WaveformColors.playedAgainstUnplayed - 0.02, "\(t.id): \(name) vs unplayed \(c)")
            }
        }
        expect(worstPlayed >= 4.45 && worstPair >= 2.98, "worst case: played \(worstPlayed), pair \(worstPair), unplayed \(worstUnplayed)")
        expect(WaveformColors.surfaces(for: Theme.aureon).count >= 8, "the album intensities, glass and pop-ups are all covered")
    }

    func everySeekAnswers() {
        var p = SeekPulse()
        expect(p.count == 0)
        for i in 1...5 { p.fire(at: CGFloat(i) * 10); expect(p.count == i && p.x == CGFloat(i) * 10, "click \(i) fires its own pulse") }
        expect(p.count == 5, "five rapid clicks, five pulses, none lost")
    }

    func scrollingCannotJumpTheVolume() {
        // by default only ⌥ + scroll; a plain scroll over the bar belongs to the page
        expect(ScrollVolumeMode.saved == .optionOnly || UserDefaults.standard.string(forKey: ScrollVolumeMode.storageKey) != nil, "⌥ + scroll by default")
        expect(!ScrollVolumeMode.optionOnly.takesPlainWheel && !ScrollVolumeMode.off.takesPlainWheel && ScrollVolumeMode.handle.takesPlainWheel, "only the handle mode takes a plain wheel")
        expect(!ScrollVolumeMode.off.listens(pointerX: 100, handleX: 100), "off never listens")
        expect(ScrollVolumeMode.optionOnly.listens(pointerX: 10, handleX: 100), "⌥ mode listens over the bar (the router then insists on ⌥)")
        expect(ScrollVolumeMode.handle.listens(pointerX: 100, handleX: 110) && !ScrollVolumeMode.handle.listens(pointerX: 40, handleX: 110), "the handle mode only on the handle")
        // a plain wheel (no ⌥) over a control is the page's, in the gate
        var gate = ScrollGate()
        expect(gate.decide(now: 1, phased: false, begins: false, momentumEnded: false, option: false, overControl: true) == .page, "a plain wheel over the bar scrolls the page")
        expect(gate.decide(now: 2, phased: false, begins: false, momentumEnded: false, option: true, overControl: true) == .adjust, "⌥ + wheel adjusts")
        // steps: a notch is a percent, a burst is capped at three
        expect(abs(ScrollVolumeMode.apply(value: 0.5, notches: 1) - 0.51) < 1e-9, "one notch, one percent")
        expect(abs(ScrollVolumeMode.apply(value: 0.5, notches: 40) - 0.53) < 1e-9 && abs(ScrollVolumeMode.apply(value: 0.5, notches: -40) - 0.47) < 1e-9, "a burst moves it three percent at most")
        var v = 0.5
        for _ in 0..<10 { v = ScrollVolumeMode.apply(value: v, notches: 100) }
        expect(v <= 0.8 + 1e-9, "ten wild events still move it by thirty percent at most: \(v)")
        expect(ScrollVolumeMode.apply(value: 0.99, notches: 5) <= 1 && ScrollVolumeMode.apply(value: 0.01, notches: -5) >= 0, "always a valid level")
        // the click jump is still capped at 15 %, and the keys still work
        expect(VolumeMath.press(at: 1, current: 0.2) == 0.35 && VolumeMath.key(1, current: 0.5) == 0.52)
        expect(ScrollVolumeMode.allCases.map(\.rawValue) == ["off", "optionOnly", "handle"])
    }

    func focusMakesTheCoverBig() {
        // wide window: free space inside the margins, rail above and progress below
        for size in [CGSize(width: 1152, height: 520), CGSize(width: 1400, height: 700), CGSize(width: 900, height: 400)] {
            let side = FocusLayout.coverSide(free: size, wide: true) + 2 * FocusLayout.mat       // with its mat
            let shorter = min(size.height, size.width)
            expect(side <= size.width + 0.5 && side <= size.height + 0.5, "it fits: \(side) in \(size)")
            expect((side - 2 * FocusLayout.mat) >= 0.8 * shorter - 2 * FocusLayout.mat && side >= 0.8 * shorter, "at least 80% of the shorter free side: \(side) of \(shorter)")
        }
        let narrow = CGSize(width: 480, height: 640)
        let n = FocusLayout.coverSide(free: narrow, wide: false) + 2 * FocusLayout.mat
        expect(n <= narrow.width && n + FocusLayout.infoBelow <= narrow.height + 0.5, "narrow: the cover on top, the names under it, everything fits")
        expect(FocusLayout.coverSide(free: CGSize(width: 50, height: 50), wide: true) >= 120, "never smaller than a readable cover")
    }

    func focusTogglesAndIsRemembered() {
        let ud = UserDefaults.standard, saved = ud.object(forKey: StageModel.focusKey)
        defer { if let saved { ud.set(saved, forKey: StageModel.focusKey) } else { ud.removeObject(forKey: StageModel.focusKey) } }
        ud.set(false, forKey: StageModel.focusKey)
        let s = StageModel()
        expect(!s.focus)
        s.toggle(.queue)
        expect(s.panel == .queue)
        s.toggleFocus()
        expect(s.focus && s.panel == nil, "Focus closes the side panel")
        expect(ud.bool(forKey: StageModel.focusKey) || ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil, "the choice is remembered")
        s.toggleFocus()
        expect(!s.focus && s.panel == .queue, "a second press restores the layout, panel included")
        s.toggleFocus()
        s.toggle(.lyrics)
        expect(!s.focus && s.panel == .lyrics, "asking for a panel ends Focus and opens it")
        s.toggleFocus(); s.toggleFocus()
        expect(!s.focus && s.panel == .lyrics)
        ud.set(true, forKey: StageModel.focusKey)
        expect(StageModel.savedFocus || ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil, "it comes back at the next launch")
        let host = StageTestHost(), st2 = StageModel()
        st2.toggleFocus()
        st2.showLyrics(host, reduceMotion: true)
        expect(!st2.focus && st2.panel == .lyrics, "the Lyrics button leaves Focus")
        ud.set(false, forKey: StageModel.focusKey)
    }

    private func pump(_ secs: Double, _ host: NSView) {
        let end = Date().addingTimeInterval(secs)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    }

    func theAnalyserDoesNotMoveWithTheQueue() {
        let m = PlayerModel(); v5KeepAlive.append(m)
        let stage = StageModel(); v5KeepAlive.append(stage)
        stage.toggle(.analyser)
        m.tab = .player
        let host = NSHostingView(rootView: AnyView(ContentView(stage: stage).environmentObject(m).frame(width: 1280, height: 820).preferredColorScheme(.dark)))
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -7000, y: -7000))
        win.makeKeyAndOrderFront(nil)
        func queue(_ n: Int) { m.items = (0..<n).map { QueueItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/queue-\($0).flac"), title: "Track \($0)") } }
        func picture() -> [UInt8] {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.bitmapData.map { Array(UnsafeBufferPointer(start: $0, count: rep.bytesPerRow * rep.pixelsHigh)) } ?? []
        }
        /// The part of the picture where the side panel is: right of `x` (a fraction of the width), between the rail and the footer.
        func right(_ px: [UInt8], from x: Double) -> [UInt8] {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
            let row = rep.bytesPerRow, start = Int(Double(rep.pixelsWide) * x) * 4
            var out: [UInt8] = []
            for y in Int(Double(rep.pixelsHigh) * 0.17)..<Int(Double(rep.pixelsHigh) * 0.77) { out += px[(y * row + start)..<(y * row + row)] }
            return out
        }
        var shots: [[UInt8]] = []
        queue(3); pump(1.0, host); _ = picture()           // the first picture of a new window is not yet the settled one
        for n in [0, 3, 300] { queue(n); pump(0.7, host); shots.append(picture()) }
        win.orderOut(nil)
        expect(!shots[0].isEmpty && shots[0].count == shots[1].count, "pictures taken")
        expect(shots[1] == shots[2], "with 3 and with 300 tracks queued the Now Playing page is identical, pixel for pixel: nothing moves with the queue length")
        func diffBox(_ a: [UInt8], _ b: [UInt8]) -> String {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds), a.count == b.count else { return "size" }
            let row = rep.bytesPerRow
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, n = 0
            for i in stride(from: 0, to: a.count, by: 4) where a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
                let y = i / row, x = (i % row) / 4
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); n += 1
            }
            return "\(n) px in x \(minX)...\(maxX) y \(minY)...\(maxY)"
        }
        expect(right(shots[0], from: 0.52) == right(shots[1], from: 0.52) && right(shots[1], from: 0.52) == right(shots[2], from: 0.52), "and the analyser panel is the same with none queued: \(diffBox(shots[0], shots[1]))")
    }
}

func feedbackTests() -> [(String, TestFn)] {
    return [("ui.waveformContrast", { MainActor.assumeIsolated { FeedbackTests().theWaveformIsReadableOnEveryBackground() } }), ("ui.seekPulse", { MainActor.assumeIsolated { FeedbackTests().everySeekAnswers() } }),
            ("ui.volumeScroll", { MainActor.assumeIsolated { FeedbackTests().scrollingCannotJumpTheVolume() } }), ("ui.focusLayout", { MainActor.assumeIsolated { FeedbackTests().focusMakesTheCoverBig() } }),
            ("ui.focusToggle", { MainActor.assumeIsolated { FeedbackTests().focusTogglesAndIsRemembered() } }), ("ui.queueNoShift", { MainActor.assumeIsolated { FeedbackTests().theAnalyserDoesNotMoveWithTheQueue() } })]
}


/// Speaker levelling in the New UI: where it can be reached from.
@MainActor
struct LevelEntryTests {
    func levelSpeakersIsReachable() {
        let m = PlayerModel(); v5KeepAlive.append(m)
        m.go(.tab(.albums)); m.quickPanel = .rail
        m.showLevelSpeakers()
        expect(m.tab == .rooms && m.roomsFocus == .levelSpeakers && m.quickPanel == nil && !m.djMode, "the quick panel entry opens Rooms and asks it to show the speaker set-up")
        m.roomsFocus = nil
        PaletteRunner.run(.levelSpeakers, m: m, stage: StageModel(), reduceMotion: true)
        expect(m.tab == .rooms && m.roomsFocus == .levelSpeakers, "so does the palette")
        let ids = Set(PaletteCatalog.all.map(\.id))
        expect(ids.contains("act:levelSpeakers"), "the palette lists it")
        expect(PaletteCatalog.matches("balance").contains { $0.action == .levelSpeakers } && PaletteCatalog.matches("level speakers").first?.action == .levelSpeakers, "and finds it by name")
        expect(SpeakerSetup().autoLevel, "balancing is on by default (the branch's engine)")
    }
}

func levelEntryTests() -> [(String, TestFn)] {
    return [("ui.levelSpeakers", { MainActor.assumeIsolated { LevelEntryTests().levelSpeakersIsReachable() } })]
}

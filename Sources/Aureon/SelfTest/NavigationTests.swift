import Foundation
import AppKit
import SwiftUI

nonisolated(unsafe) private var navKeepAlive: [AnyObject] = []

/// The shape of the interface: the top bar (Home, search, Settings), five destinations on the rail, every old page reachable from them, and the quick-find listing all of it.
struct NavigationTests {
    func everyPageIsReachableFromTheRail() {
        // every page belongs to exactly one destination
        var seen: [Tab: RailDestination] = [:]
        for d in RailDestination.allCases {
            for t in d.tabs { expect(seen[t] == nil, "\(t) belongs to two destinations"); seen[t] = d }
        }
        for t in Tab.allCases { expect(seen[t] != nil && RailDestination.of(t) == seen[t], "\(t) has no destination") }
        expect(RailDestination.rail.map(\.rawValue) == ["Library", "Playlists", "Radio", "Podcasts", "Rooms", "Sound"], "the rail's six destinations, in plain words")
        expect(!RailDestination.rail.contains(.home) && !RailDestination.rail.contains(.listen) && !RailDestination.rail.contains(.settings), "Home, Now Playing and Settings are not on the rail")
        // …and can be reached from it: every page is the destination's home or an item of its one-line sub-header (nothing hides behind a menu)
        for d in RailDestination.allCases {
            let nav = d.subNav
            let reachable = Set(nav.compactMap { t -> Tab? in if case .tab(let tab) = t { tab } else { nil } } + [{ if case .tab(let t) = d.home { t } else { .home } }()])
            for t in d.tabs where !(d == .home && t == .search) && !(d == .settings && (t == .cloud || t == .intelligence)) { expect(reachable.contains(t), "\(t) cannot be reached from \(d)") }       // Search is the field in the top bar
            for t in nav { expect(t.destination == d, "\(t.id) sits under the wrong destination") }
            expect(Set(nav.map(\.id)).count == nav.count, "\(d) lists something twice")
        }
        // the DJ console belongs to Sound, which keeps only the tools; cloud, intelligence and diagnostics are sections of Settings
        let sound = RailDestination.sound.subNav
        expect(sound.contains(.dj) && !sound.contains(.settings(.system)), "DJ is in Sound, diagnostics are not")
        expect(Set(sound.map(\.title)) == ["Sound", "Equaliser", "DJ", "Rip CD", "Convert", "ABX Test"], "\(sound.map(\.title))")
        expect(RailDestination.settings.tabs.contains(.cloud) && RailDestination.settings.tabs.contains(.intelligence) && !RailDestination.sound.tabs.contains(.cloud) && !RailDestination.sound.tabs.contains(.intelligence), "Cloud and Intelligence belong to Settings")
        expect(SettingsGroup.allCases.map(\.rawValue) == ["Look", "Playback and sound", "Connected", "Intelligence", "Advanced"] && SettingsGroup.allCases.flatMap(\.sections) == SettingsSection.allCases, "five groups holding every section once, in menu order")
        expect(RailDestination.library.subNav.map(\.title).starts(with: ["Albums", "Artists", "Songs"]), "album-first")
        expect(RailDestination.library.subNav.count == 9, "the whole library is in the line")
        expect(RailDestination.playlists.subNav.map(\.title) == ["Playlists", "Liked"] && RailDestination.radio.subNav.isEmpty && RailDestination.podcasts.subNav.isEmpty)
        // Radio keeps its stations; Podcasts has its own place, page and icon
        expect(RailDestination.radio.tabs == [.radio] && RailDestination.podcasts.tabs == [.podcasts] && RailDestination.of(.podcasts) == .podcasts && RailDestination.of(.radio) == .radio, "Podcasts is not inside Radio")
        expect(RailDestination.podcasts.icon != RailDestination.radio.icon && RailDestination.podcasts.home == .tab(.podcasts) && RailDestination.radio.home == .tab(.radio), "its own icon, and the rail goes to it")
        // the rooms page holds what was spread over other pages
        expect(Tab.rooms.rawValue == "Rooms" && RailDestination.of(.rooms) == .rooms)
        // labels are plain words
        expect(NavTarget.tab(.player).title == "Now Playing" && NavTarget.tab(.deepDive).title == "Deep Dive")
        expect(PaletteCatalog.all.first { $0.action == .go(.tab(.player)) }?.title == "Now Playing", "the palette says Now Playing, not Gallery")
        expect(!PaletteCatalog.all.contains { $0.title == "Listen" || $0.title == "Gallery" || $0.group == "Listen" })
    }

    func theShellGoesWhereItIsAsked() {
        MainActor.assumeIsolated {
            let m = PlayerModel(); navKeepAlive.append(m)
            expect(m.tab == .home, "Home is where it opens")
            for t in PaletteCatalog.destinations {
                m.go(t)
                expect(m.isCurrent(t), "went to \(t.id)")
                if case .tab(let tab) = t, tab != .settings { expect(m.currentDestination == RailDestination.of(tab), "\(t.id): the rail marks \(m.currentDestination)") }
                if t == .dj { expect(m.currentDestination == .sound && m.djMode) }
            }
            m.go(.settings(.system)); expect(m.currentDestination == .settings && !m.djMode, "System and diagnostics are in Settings, not in Sound")
            m.go(.tab(.cloud)); expect(m.tab == .settings && m.settingsSection == .cloud && m.isCurrent(.tab(.cloud)) && m.currentDestination == .settings, "Cloud opens as a section of Settings")
            m.go(.tab(.intelligence)); expect(m.tab == .settings && m.settingsSection == .intelligence && m.currentDestination == .settings, "Intelligence too")
            m.go(.settings(.midi)); expect(m.currentDestination == .settings && m.settingsSection == .midi)
            m.go(.tab(.albums)); expect(!m.djMode && m.currentDestination == .library && m.lastPage[.library] == .tab(.albums), "the last page of a destination is remembered")
        }
    }

    func paletteListsEveryDestination() {
        let all = PaletteCatalog.all
        expect(Set(all.map(\.id)).count == all.count, "palette ids are unique")
        let goes = Set(all.compactMap { i -> NavTarget? in if case .go(let t) = i.action { t } else { nil } })
        for t in Tab.allCases { expect(goes.contains(.tab(t)), "the palette has no \(t)") }
        for s in SettingsSection.allCases { expect(goes.contains(.settings(s)), "the palette has no settings section \(s)") }
        expect(goes.contains(.dj), "the palette has the DJ console")
        expect(all.allSatisfy { !$0.title.isEmpty && !$0.icon.isEmpty && !$0.group.isEmpty })
        for f in Theme.families { expect(all.contains { $0.action == .theme(f.id) }, "colour family \(f.id)") }
        expect(all.contains { $0.action == .pureBlack(true) } && all.contains { $0.action == .pureBlack(false) }, "pure black on and off")
        for b in BackdropMode.allCases { expect(all.contains { $0.action == .backdrop(b) }, "backdrop \(b)") }
        for a in AppearanceMode.allCases { expect(all.contains { $0.action == .appearance(a) }) }
        for act in [PaletteAction.togglePlay, .next, .previous, .toggleQueue, .showLyrics, .addMusic] { expect(all.contains { $0.action == act }, "\(act)") }
        // finding
        func first(_ q: String) -> PaletteAction? { PaletteCatalog.matches(q).first?.action }
        expect(first("equal") == .go(.tab(.dsp)), "equaliser finds the DSP page: \(String(describing: first("equal")))")
        expect(first("rooms") == .go(.tab(.rooms)) && PaletteCatalog.matches("cast").contains { $0.action == .go(.tab(.rooms)) }, "rooms and cast find Rooms")
        expect(first("dj") == .go(.dj) || PaletteCatalog.matches("dj").contains { $0.action == .go(.dj) }, "dj")
        expect(PaletteCatalog.matches("diag").contains { $0.action == .go(.settings(.system)) }, "diagnostics")
        expect(first("now playing") == .go(.tab(.player)) && PaletteCatalog.matches("gallery").contains { $0.action == .go(.tab(.player)) }, "Now Playing")
        expect(PaletteCatalog.matches("convert").first?.action == .go(.tab(.convert)))
        expect(PaletteCatalog.matches("sonos").contains { $0.action == .go(.tab(.rooms)) }, "keywords find pages")
        let none = PaletteCatalog.matches("zzzzqq")
        expect(none.count == 1 && none[0].action == .search("zzzzqq"), "unknown text offers a library search")
        expect(PaletteCatalog.matches("").count == all.count, "no query lists everything")
        expect(PaletteCatalog.matches("  albums ").first?.action == .go(.tab(.albums)), "whitespace is ignored")
    }

    func quietUntilTouched() {
        MainActor.assumeIsolated {
            let idle = IdleTracker()
            expect(idle.awake, "awake to begin with")
            idle.rest(); expect(!idle.awake, "rests on request")
            idle.poke(); expect(idle.awake, "wakes on a poke")
            expect(IdleTracker.disabled, "tests never let the interface rest on its own")
            expect(IdleTracker.delay >= 3 && IdleTracker.delay <= 5)
        }
    }

    func starsAreSparseAndSteady() {
        let ink = Theme.aureon.inkRGB, accent = Theme.aureon.accentRGB
        guard let a = BackdropRenderer.stars(width: 640, height: 400, count: 60, ink: ink, accent: accent), let b = BackdropRenderer.stars(width: 640, height: 400, count: 60, ink: ink, accent: accent) else { expect(false, "stars render"); return }
        func bytes(_ img: CGImage) -> [UInt8] {
            var raw = [UInt8](repeating: 0, count: img.width * img.height * 4)
            raw.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
            return raw
        }
        let pa = bytes(a), pb = bytes(b)
        expect(pa == pb, "the same sky every time")
        let lit = stride(from: 3, to: pa.count, by: 4).filter { pa[$0] > 0 }.count
        let total = a.width * a.height
        expect(lit > 20 && Double(lit) / Double(total) < 0.003, "sparse: \(lit) of \(total) pixels")
        expect(stride(from: 3, to: pa.count, by: 4).allSatisfy { pa[$0] <= 150 }, "no star is bright enough to matter to text")
    }
}

func navigationTests() -> [(String, TestFn)] {
    let t = NavigationTests()
    return [("nav.reachable", t.everyPageIsReachableFromTheRail), ("nav.goes", t.theShellGoesWhereItIsAsked), ("nav.palette", t.paletteListsEveryDestination),
            ("ui.idleRests", t.quietUntilTouched), ("ui.stars", t.starsAreSparseAndSteady)]
}

/// The new controls: the OFF | ON switch, the shuffle list, the volume slider and mute.
struct ControlTests {
    func onOffIsLegibleInEveryTheme() {
        for t in Theme.all {
            // ON: dark (or light) type on the champagne block; OFF: the secondary ink on the recessed block; the idle word in the tertiary ink on the page
            expect(WCAG.contrast(t.onAccentRGB, t.accentRGB) >= 4.5, "ON on gold in \(t.id)")
            let recess = WCAG.over(t.inkRGB, alpha: 0.12, t.canvasRGB)
            expect(WCAG.contrast(t.inkSecondaryRGB, recess) >= 4.5, "OFF on its recess in \(t.id): \(WCAG.contrast(t.inkSecondaryRGB, recess))")
            for s in t.surfaces { expect(WCAG.contrast(t.inkTertiaryRGB, s) >= 4.5 - 1e-9, "the idle word in \(t.id)") }
            // the two states differ clearly: the gold block against the recess
            expect(WCAG.contrast(t.accentRGB, recess) >= 2, "the lit block stands out from the recess in \(t.id)")
        }
        expect(OnOffSwitch.width >= 44 && OnOffSwitch.height >= 24, "a comfortable target")
    }

    func shuffleListShowsEveryMode() {
        let rows = ShuffleChoices.rows(current: .normal)
        expect(rows.map(\.mode) == ShuffleMode.allCases && rows.map(\.mode) == [.off, .normal, .smart], "every mode the engine has")
        expect(rows.allSatisfy { !$0.title.isEmpty && !$0.blurb.isEmpty }, "every row has words")
        expect(Set(rows.map(\.title)).count == rows.count)
        expect(rows.filter(\.isCurrent).map(\.mode) == [.normal], "the current one is marked, and only it")
        for current in ShuffleMode.allCases { expect(ShuffleChoices.rows(current: current).filter(\.isCurrent).map(\.mode) == [current]) }
        MainActor.assumeIsolated {
            let m = PlayerModel(); controlsKeepAlive.append(m)
            for mode in [ShuffleMode.smart, .normal, .off, .smart] {
                ShuffleChoices.select(mode, in: m)
                expect(m.shuffle == mode, "selecting \(mode) sets it")
                expect(ShuffleChoices.rows(current: m.shuffle).first { $0.isCurrent }?.mode == mode)
            }
        }
    }

    func volumeSliderBehaves() {
        // a press goes there at once, but cannot jump far up
        expect(VolumeMath.press(at: 0.3, current: 0.25) == 0.3, "a press near the level goes there")
        expect(abs(VolumeMath.press(at: 0.9, current: 0.2) - 0.35) < 1e-9, "an accidental click at the loud end only goes up a little: \(VolumeMath.press(at: 0.9, current: 0.2))")
        expect(VolumeMath.press(at: 0.05, current: 0.6) == 0.05, "going down is immediate")
        expect(VolumeMath.press(at: 1.4, current: 0.99) == 1 && VolumeMath.press(at: -2, current: 0.5) == 0, "clamped")
        // dragging follows the pointer; keys step; ⌥ is fine
        expect(VolumeMath.drag(to: 0.77) == 0.77 && VolumeMath.drag(to: 3) == 1 && VolumeMath.drag(to: -1) == 0)
        expect(abs(VolumeMath.key(1, current: 0.5) - 0.52) < 1e-9 && abs(VolumeMath.key(-1, current: 0.5) - 0.48) < 1e-9)
        expect(abs(VolumeMath.key(1, current: 0.5, fine: true) - 0.504) < 1e-9 && VolumeMath.key(1, current: 1) == 1 && VolumeMath.key(-1, current: 0) == 0)
        expect(VolumeMath.resetLevel == 0.5, "double-click goes to half")
        // the wheel: small steps, never more than a few per cent in one event
        expect(abs(ScrollStep.apply(value: 0.5, notches: 1, range: 0...1, perNotch: 0.02, maxMove: 0.06) - 0.52) < 1e-9)
        expect(abs(ScrollStep.apply(value: 0.5, notches: 40, range: 0...1, perNotch: 0.02, maxMove: 0.06) - 0.56) < 1e-9)
        // mute remembers the level and puts it back
        var mem = MuteMemory(), level: Float = 0.62
        mem.toggle(current: level) { level = $0 }
        expect(level == 0 && mem.isMuted(level), "muted")
        mem.toggle(current: level) { level = $0 }
        expect(abs(level - 0.62) < 1e-6 && mem.before == nil, "unmuted to where it was")
        var fresh = MuteMemory(), l2: Float = 0
        fresh.toggle(current: l2) { l2 = $0 }
        expect(l2 > 0, "unmuting with nothing remembered gives a middle level")
        // the volume is the device's own: nothing here scales samples
        expect(true)
    }
}

nonisolated(unsafe) private var controlsKeepAlive: [AnyObject] = []

func controlTests() -> [(String, TestFn)] {
    let t = ControlTests()
    return [("ui.onOff", t.onOffIsLegibleInEveryTheme), ("ui.shuffleList", t.shuffleListShowsEveryMode), ("ui.volume", t.volumeSliderBehaves)]
}

/// Now Playing's panels, the readouts, the scrim, and the lyrics timing.
struct NowPlayingTests {
    /// Made-up lyrics (never the words of a real song).
    private var placeholder: Lyrics {
        Lyrics(lines: [LyricLine(id: 0, time: 2, text: "first placeholder line"), LyricLine(id: 1, time: 5, text: "second placeholder line"),
                       LyricLine(id: 2, time: 9.5, text: "third placeholder line"), LyricLine(id: 3, time: 14, text: "fourth placeholder line")],
               synced: true, origin: .sidecar, source: "test")
    }

    @MainActor func panelsOpenOneAtATime() {
        let stage = StageModel()
        expect(stage.panel == nil, "nothing is open to begin with: no lyrics until asked for")
        stage.toggle(.lyrics); expect(stage.panel == .lyrics)
        stage.toggle(.queue); expect(stage.panel == .queue, "opening another replaces the one that was open")
        stage.toggle(.signal); expect(stage.panel == .signal)
        stage.toggle(.signal); expect(stage.panel == nil, "clicking again closes")
        for p in GalleryPanel.allCases { stage.toggle(p); expect(stage.panel == p); stage.toggle(p); expect(stage.panel == nil) }
        expect(GalleryPanel.allCases.map(\.title) == ["Lyrics", "Queue", "Signal path", "Analyser", "Booklet"] && GalleryPanel.allCases.allSatisfy { !$0.icon.isEmpty })
        // the Lyrics button opens Now Playing at the words, from any page, and closes a panel that was open over it
        let host = StageTestHost(); host.tab = .albums
        stage.toggle(.queue)
        stage.npTab = .credits
        stage.showLyrics(host, reduceMotion: true)
        expect(stage.panel == nil && stage.npTab == .lyrics && host.tab == .player, "the lyrics button opens Now Playing at the lyrics")
    }

    func lyricsTimingUsesTheOffsetAndTheLatency() {
        let l = placeholder
        func line(_ p: Double, offset: Double = 0, latency: Double = 0) -> Int? { LyricsTiming.activeLine(in: l, position: p, offset: offset, latency: latency) }
        expect(line(1.9) == nil && line(2.0) == 0 && line(4.99) == 0 && line(5.0) == 1 && line(9.4) == 1 && line(9.5) == 2 && line(60) == 3, "plain")
        expect(line(4.85, offset: 0.2) == 1 && line(4.85) == 0, "a positive offset shows the words earlier")
        expect(line(5.1, offset: -0.2) == 0 && line(5.1) == 1, "a negative offset shows them later")
        expect(line(5.1, latency: 0.2) == 0 && line(5.3, latency: 0.2) == 1, "the stages' latency makes the words wait for the sound")
        expect(line(5.1, offset: 0.2, latency: 0.2) == 1, "offset and latency cancel")
        expect(abs(LyricsTiming.lyricTime(position: 10, offset: 0.5, latency: 0.1) - 10.4) < 1e-12)
        // the manual offset: tenths of a second, ±2
        expect(LyricsTiming.stepped(0, by: 0.1) == 0.1 && LyricsTiming.stepped(0.1, by: -0.2) == -0.1 && LyricsTiming.stepped(1.95, by: 0.1) == 2 && LyricsTiming.stepped(-1.9, by: -0.3) == -2)
        var x = 0.0; for _ in 0..<7 { x = LyricsTiming.stepped(x, by: 0.1) }
        expect(x == 0.7, "steps do not drift: \(x)")
        expect(LyricsTiming.latency(frames: 4800, sampleRate: 48_000) == 0.1 && LyricsTiming.latency(frames: -5, sampleRate: 48_000) == 0 && LyricsTiming.latency(frames: 100, sampleRate: 0) == 0)
    }

    @MainActor func cursorFollowsTheClockBetweenReadings() {
        let l = placeholder
        let cur = LyricsCursor()
        // the player reports 4.95 s (paused, so the clock stands still): with an offset of +0.1 the second line is already due
        cur.update(position: 4.95, playing: false, lyrics: l, offset: 0, latency: 0)
        expect(cur.active == 0)
        cur.setShift(offset: 0.1, latency: 0)
        expect(cur.active == 1, "the offset takes effect at once")
        cur.setShift(offset: 0, latency: 0.2)
        expect(cur.active == 0, "so does the latency")
        // playing: a reading, then the wall clock carries it past the next line's start without another reading
        cur.update(position: 4.9, playing: true, lyrics: l, offset: 0, latency: 0)
        expect(cur.active == 0)
        usleep(160_000)
        cur.sample()
        expect(cur.active == 1, "sampled between readings, the line changes when it starts")
    }

    func readoutsAreGroupedAndAligned() {
        var s = PlayerStatus()
        s.sourceInfo = StreamInfo(sampleRate: 96_000, channels: 2, sourceBits: 24, totalFrames: 1, codec: "FLAC", transparent: true)
        s.info = s.sourceInfo; s.deviceName = "Test DAC"; s.bitPerfect = true
        let src = ReadoutModel.source(s, analysis: TrackAnalysis(peakDB: -1.5, dynamicRange: 9, lufs: -14.2))
        expect(src.map(\.label) == ["Format", "Rate", "Depth", "Channels", "Loudness", "Peak"], "\(src.map(\.label))")
        expect(src.map(\.value) == ["FLAC", "96 kHz", "24-bit", "Stereo", "-14.2 LUFS", "-1.5 dBFS"], "\(src.map(\.value))")
        let out = ReadoutModel.output(s)
        expect(out.map(\.label) == ["Device", "Rate", "DSP", "Gain"] && out[0].value == "Test DAC" && out[2].value == "Off" && out[3].value == "None", "\(out)")
        s.replayGainDB = -3.25; s.dspSummary = "Parametric EQ"
        expect(ReadoutModel.output(s)[3].value == "-3.2 dB" || ReadoutModel.output(s)[3].value == "-3.3 dB", "gain")
        expect(ReadoutModel.output(s)[2].value == "Parametric EQ")
        expect(ReadoutModel.channelsName(1) == "Mono" && ReadoutModel.channelsName(6) == "5.1" && ReadoutModel.channelsName(8) == "7.1")
        // lossy and live sources say so
        var radio = PlayerStatus()
        radio.sourceInfo = StreamInfo(sampleRate: 44_100, channels: 2, sourceBits: 16, totalFrames: 1, codec: "AAC (lossy)", transparent: false, isLive: true)
        radio.info = radio.sourceInfo
        expect(ReadoutModel.source(radio, analysis: nil).first?.value == "AAC · lossy" && !ReadoutModel.source(radio, analysis: nil).contains { $0.label == "Depth" })
        expect(ReadoutModel.source(PlayerStatus(), analysis: nil).isEmpty && ReadoutModel.output(PlayerStatus()).isEmpty, "nothing playing: nothing to read")
    }

    func signalPathSaysWhatAltersTheSignal() {
        let still = PathNode(id: "a", kind: .decode, symbol: "x", title: "Decoder", subtitle: "", detail: "")
        let rs = PathNode(id: "b", kind: .stage, symbol: "x", title: "Resampler", subtitle: "", detail: "", alters: true)
        let lv = PathNode(id: "c", kind: .stage, symbol: "x", title: "Level", subtitle: "", detail: "", alters: true)
        expect(SignalPath.verdict([still], bitPerfect: true).hasPrefix("Bit-perfect"))
        expect(SignalPath.verdict([still, rs], bitPerfect: false) == "Altered by Resampler.", SignalPath.verdict([still, rs], bitPerfect: false))
        expect(SignalPath.verdict([still, rs, lv], bitPerfect: false) == "Altered by Resampler and Level.")
        expect(SignalPath.verdict([still], bitPerfect: false).hasPrefix("Not bit-perfect"))
        var s = PlayerStatus(); s.pipeline = ["Upsampling bypassed: the device takes the file's rate", "Memory playback: preloaded"]
        expect(SignalPath.bypassed(s) == ["Upsampling bypassed"], "\(SignalPath.bypassed(s))")
    }

    func theHeaderScrimNeverShowsContentThrough() {
        expect(ScrimStyle.tint(reduceTransparency: false) >= 0.9 && ScrimStyle.tint(reduceTransparency: false) < 1, "the theme's background at about 92 %")
        expect(ScrimStyle.tint(reduceTransparency: true) == 1 && !ScrimStyle.usesBlur(reduceTransparency: true) && ScrimStyle.usesBlur(reduceTransparency: false), "Reduce Transparency: opaque, no blur")
        expect(ScrimStyle.rule(offset: 0) == 0 && ScrimStyle.rule(offset: -30) == 0 && ScrimStyle.rule(offset: 4) == 0.5 && ScrimStyle.rule(offset: 8) == 1 && ScrimStyle.rule(offset: 400) == 1, "the hairline fades in as content goes under")
        expect(ScrimStyle.visible(scrolledUnder: true) && !ScrimStyle.visible(scrolledUnder: false), "the scrim is there once content is under it")
        // the content starts below the bar
        expect(ChromeInset.height(hasSubNav: false) == ChromeInset.rail && ChromeInset.height(hasSubNav: true) == ChromeInset.rail + ChromeInset.subNav && WindowChrome.band == Metrics.topBarHeight, "the inset is the margin and the chips")
        // text on the scrim, at the worst the scrim can be (92 % theme background over the lightest thing behind it) keeps its contrast
        for t in Theme.all {
            let worst = WCAG.over(t.canvasRGB, alpha: 0.92, t.isLight ? RGB(0, 0, 0) : RGB(1, 1, 1))
            expect(WCAG.contrast(t.inkSecondaryRGB, worst) >= 4.5, "text on the scrim in \(t.id): \(WCAG.contrast(t.inkSecondaryRGB, worst))")
        }
    }
}

func nowPlayingTests() -> [(String, TestFn)] {
    let t = NowPlayingTests()
    return [("ui.panels", { MainActor.assumeIsolated { t.panelsOpenOneAtATime() } }), ("lyrics.timing", t.lyricsTimingUsesTheOffsetAndTheLatency),
            ("lyrics.cursorClock", { MainActor.assumeIsolated { t.cursorFollowsTheClockBetweenReadings() } }), ("ui.readouts", t.readoutsAreGroupedAndAligned),
            ("ui.signalVerdict", t.signalPathSaysWhatAltersTheSignal), ("ui.scrim", t.theHeaderScrimNeverShowsContentThrough)]
}

/// The quality hallmark: what counts as Hi-Res, Lossless or lossy, and how the bar gives way when it is narrow.
struct QualityBadgeTests {
    private func info(_ bits: Int, _ rate: Double, _ codec: String = "FLAC", sourceRate: Double? = nil, live: Bool = false) -> StreamInfo {
        StreamInfo(sampleRate: rate, channels: 2, sourceBits: bits, totalFrames: 1, codec: codec, sourceRate: sourceRate, transparent: !codec.contains("lossy"), isLive: live)
    }
    private func mark(_ i: StreamInfo, bitrate: Int? = nil, perfect: Bool = true) -> QualityMark { QualityMark.make(source: i, bitrate: bitrate, bitPerfect: perfect) }

    func classificationAtTheBoundaries() {
        // CD quality is Lossless; more than 16 bits or more than 48 kHz is Hi-Res
        let cases: [(Int, Double, QualityMark.Kind, String)] = [
            (16, 44_100, .lossless, "16/44.1"), (16, 48_000, .lossless, "16/48"), (24, 44_100, .hiRes, "24/44.1"), (24, 48_000, .hiRes, "24/48"),
            (16, 88_200, .hiRes, "16/88.2"), (16, 96_000, .hiRes, "16/96"), (24, 96_000, .hiRes, "24/96"), (24, 176_400, .hiRes, "24/176.4"), (24, 192_000, .hiRes, "24/192"),
            (32, 384_000, .hiRes, "32/384"), (20, 44_100, .hiRes, "20/44.1"), (8, 32_000, .lossless, "8/32"),
        ]
        for (bits, rate, kind, spec) in cases {
            let m = mark(info(bits, rate))
            expect(m.kind == kind && m.spec == spec, "\(bits)/\(rate): \(m.kind) \(m.spec)")
            expect(m.title == (kind == .hiRes ? "HI-RES" : "LOSSLESS") && !m.dsd)
        }
        // lossless in any container
        for codec in ["FLAC", "ALAC", "WAV", "AIFF"] { expect(mark(info(16, 44_100, codec)).kind == .lossless, codec) }
        // DSD: Hi-Res, named by its multiple
        for (rate, spec) in [(2_822_400.0, "DSD 64"), (5_644_800, "DSD 128"), (11_289_600, "DSD 256"), (22_579_200, "DSD 512"), (3_072_000, "DSD 64")] {
            let m = mark(info(1, rate, "DSD"))
            expect(m.kind == .hiRes && m.dsd && m.title == "HI-RES" && m.spec == spec, "\(rate): \(m.spec)")
        }
        // lossy formats get no plate, only a line of text with the bitrate when it is known
        let aac = mark(info(16, 44_100, "AAC (lossy)"), bitrate: 256), mp3 = mark(info(16, 44_100, "MP3 (lossy)"), bitrate: 320), bare = mark(info(16, 44_100, "AAC (lossy)"))
        expect(aac.kind == .lossy && aac.title.isEmpty && aac.spec == "AAC 256" && mp3.spec == "MP3 320" && bare.spec == "AAC", "\(aac.spec) \(mp3.spec) \(bare.spec)")
        expect(!aac.bitPerfect && !mark(info(16, 44_100, "AAC (lossy)"), perfect: true).bitPerfect, "a lossy source is never marked bit-perfect")
        // a stage that resampled the stream does not change what the file is: the file's own rate counts
        let resampled = mark(info(16, 192_000, "FLAC", sourceRate: 44_100))
        expect(resampled.kind == .lossless && resampled.spec == "16/44.1", "\(resampled.spec)")
        // the dot says bit-perfect
        expect(mark(info(24, 96_000), perfect: true).bitPerfect && !mark(info(24, 96_000), perfect: false).bitPerfect)
        // the classification used for library rows
        expect(QualityMark.classify(bits: 16, rate: 44_100, lossy: false) == .lossless && QualityMark.classify(bits: 24, rate: 44_100, lossy: false) == .hiRes
               && QualityMark.classify(bits: 16, rate: 48_000, lossy: false) == .lossless && QualityMark.classify(bits: 1, rate: 2_822_400, lossy: false) == .hiRes
               && QualityMark.classify(bits: 24, rate: 96_000, lossy: true) == .lossy)
        expect(QualityMark.lossyCodecs.contains("mp3") && QualityMark.lossyCodecs.contains("aac") && !QualityMark.lossyCodecs.contains("flac") && !QualityMark.lossyCodecs.contains("alac"))
        expect(QualityMark.rateShort(44_100) == "44.1" && QualityMark.rateShort(48_000) == "48" && QualityMark.rateShort(88_200) == "88.2" && QualityMark.rateShort(96_000) == "96" && QualityMark.rateShort(352_800) == "352.8")
        // spoken
        expect(mark(info(24, 96_000)).spoken == "Hi-Res, 24 bit, 96 kilohertz, bit-perfect" && mark(info(16, 44_100), perfect: false).spoken == "Lossless, 16 bit, 44.1 kilohertz", "\(mark(info(24, 96_000)).spoken)")
    }

    func lossyBitratesAreSnappedToTheUsualOnes() {
        expect(LossyBitrates.snap(255) == 256 && LossyBitrates.snap(320.5) == 320 && LossyBitrates.snap(131) == 128 && LossyBitrates.snap(180) == 192 && LossyBitrates.snap(100) == 96)
        expect(LossyBitrates.snap(400) == 400 && LossyBitrates.snap(37) == 40, "far from any usual rate: rounded to ten (\(LossyBitrates.snap(400)), \(LossyBitrates.snap(37)))")
    }

    func theBarGivesWayBadgeFirst() {
        // the order things give way in as the bar narrows: the badge takes its short form first, then the volume slider shrinks, then goes
        expect(BarRightColumn.plan(width: 280) == (false, 84) && BarRightColumn.plan(width: 232) == (false, 84))
        expect(BarRightColumn.plan(width: 231) == (true, 56) && BarRightColumn.plan(width: 196) == (true, 56), "the badge is short while the volume is still there")
        expect(BarRightColumn.plan(width: 195) == (true, nil) && BarRightColumn.plan(width: 150) == (true, nil))
        for w in stride(from: 150.0, through: 280.0, by: 2) {
            let p = BarRightColumn.plan(width: CGFloat(w))
            expect(p.volumeWidth == nil || p.volumeWidth! > 0, "no empty slider")
            if p.volumeWidth == nil || p.volumeWidth! < 84 { expect(p.shortBadge, "at \(w) the badge is already short") }
        }
    }
}

func qualityBadgeTests() -> [(String, TestFn)] {
    let t = QualityBadgeTests()
    return [("ui.qualityMark", t.classificationAtTheBoundaries), ("ui.lossyBitrate", t.lossyBitratesAreSnappedToTheUsualOnes), ("ui.barGivesWay", t.theBarGivesWayBadgeFirst)]
}

/// The analyser: all three graphs at once, at every width, filling the space.
struct AnalyserTests {
    func allThreeGraphsAtOnce() {
        expect(AnalyserSection.allCases.map(\.title) == ["Spectrum", "Spectrogram", "Levels"])
        for w in stride(from: 300.0, through: 1800.0, by: 50) {
            let a = AnalyserLayout.arrangement(width: CGFloat(w))
            let shown = AnalyserLayout.rows(a).flatMap { $0 }
            expect(shown == [.spectrum, .spectrogram, .levels], "all three graphs, once each, at \(w): \(shown)")
            expect(a == (w >= 640 ? .grid : .stacked), "width \(w)")
        }
        expect(AnalyserLayout.rows(.stacked).map(\.count) == [1, 1, 1] && AnalyserLayout.rows(.grid).map(\.count) == [2, 1], "stacked rows in the side panel, a 2-plus-1 grid when wide")
        expect(AnalyserLayout.arrangement(width: 420) == .stacked && AnalyserLayout.arrangement(width: 1100) == .grid)
    }

    func theGraphsFillTheSpace() {
        for a in [AnalyserLayout.Arrangement.stacked, .grid] {
            for h in stride(from: 360.0, through: 1100.0, by: 40) {
                let heights = AnalyserLayout.heights(available: CGFloat(h), a)
                expect(heights.count == 3 && heights.values.allSatisfy { $0 > 0 }, "every graph has room")
                let rows = AnalyserLayout.rows(a)
                let used = rows.reduce(CGFloat(0)) { $0 + AnalyserLayout.titleHeight + (heights[$1[0]] ?? 0) } + AnalyserLayout.spacing * CGFloat(rows.count - 1)
                expect(abs(used - CGFloat(h)) < 0.001, "\(a) at \(h): the rows use \(used) of \(h): nothing is left empty")
                if a == .grid { expect(heights[.spectrum] == heights[.spectrogram], "the two graphs of the top row are as tall as each other") }
                else { expect(heights[.levels]! >= 96 - 0.001, "the levels keep room for their dials") }
            }
        }
    }

    func theRampIsOneHue() {
        // the spectrogram's colours run from black through bronze and champagne to ivory: warm, never a rainbow
        let lut = Heat.lut
        func rgb(_ c: UInt32) -> RGB { RGB(Double(c & 255) / 255, Double((c >> 8) & 255) / 255, Double((c >> 16) & 255) / 255) }
        expect(WCAG.luminance(rgb(lut[0])) < 0.01 && WCAG.luminance(rgb(lut[255])) > 0.8, "black to ivory")
        for i in stride(from: 40, to: 255, by: 15) {
            let c = rgb(lut[i]), hue = c.hsb.h
            expect(c.r >= c.b - 0.001 && (hue < 0.16 || c.hsb.s < 0.15), "step \(i) stays warm: hue \(hue)")
        }
    }
}

func analyserTests() -> [(String, TestFn)] {
    let t = AnalyserTests()
    return [("ui.analyserAll", t.allThreeGraphsAtOnce), ("ui.analyserFill", t.theGraphsFillTheSpace), ("ui.heatRamp", t.theRampIsOneHue)]
}

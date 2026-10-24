import Foundation
import SwiftUI

/// The Pulse look: its settings (saved, restored, overlaid), Home's mix (time of day, the listener's history, a new seed each launch) and the sky.
struct PulseTests {
    private func album(_ n: Int, genres: [String], hiRes: Bool = false, plays: Int = 0, lastPlayed: Double? = nil, added: Double? = nil) -> HomeAlbum {
        HomeAlbum(id: "r\(n)", title: "Album \(n)", artist: "Artist \(n % 5)", year: 2000 + n, genres: genres, hiRes: hiRes, addedAt: added, plays: plays, lastPlayed: lastPlayed, liked: 0)
    }

    private func library(now: Date) -> [HomeAlbum] {
        let t = now.timeIntervalSince1970, day = 86_400.0
        let gs = [["Jazz"], ["Ambient"], ["Electronic"], ["Classical"], ["Folk"], ["Soul"], ["Piano"], ["Indie"]]
        return (0..<60).map { i in
            album(i, genres: gs[i % gs.count], hiRes: i % 3 == 0, plays: i % 4 == 0 ? 0 : (i % 7) * 3, lastPlayed: i % 4 == 0 ? nil : t - Double(20 + i * 6) * day, added: i % 9 == 0 ? t - 5 * day : t - 400 * day)
        }
    }

    func settingsAreSavedAndRestored() {
        let suite = UserDefaults(suiteName: "aureon.test.look.\(UUID().uuidString)")!
        var s = LookSettings()
        expect(s.density == .compact && s.weight == .regular && s.lightBrightness == 0.35 && s.accentHex == nil && s.textScale == 1, "defaults: Compact, Regular, soft light, the theme's own accent")
        s.density = .comfortable; s.weight = .medium; s.accentHex = "3FA7FF"; s.starlight.shooting = .often; s.starlight.tint = .cover; s.starlight.twinkle = false; s.nowPlayingLayout = "carousel"; s.showLyrics = false
        s.save(suite)
        let back = LookSettings.load(suite, environment: [:])
        expect(back == s.clamped(), "the saved record comes back whole")
        // a record from an earlier version (missing keys) reads with the defaults in their place
        suite.set(Data(#"{"density":"comfortable"}"#.utf8), forKey: LookSettings.storageKey)
        let old = LookSettings.load(suite, environment: [:])
        expect(old.density == .comfortable && old.weight == .regular && old.starlight == StarlightSettings() && old.nowPlayingLayout == "stage" && old.showLyrics, "missing keys take defaults")
        // garbage is not trusted
        suite.set(Data("not json".utf8), forKey: LookSettings.storageKey)
        expect(LookSettings.load(suite, environment: [:]) == LookSettings(), "an unreadable record is the defaults")
        // the environment lays over the record (for screenshots and tests), and numbers and colours are held in range
        let env = LookSettings.load(suite, environment: ["AUREON_LOOK": "density=comfortable,weight=light,accent=zzz,light=4,scale=9,shooting=off,np=vinyl,lyrics=0"])
        expect(env.density == .comfortable && env.weight == .light && env.accentHex == nil && env.lightBrightness == 1 && env.textScale == LookSettings.textScaleRange.upperBound && env.starlight.shooting == .off && env.nowPlayingLayout == "vinyl" && !env.showLyrics, "environment overlay is clamped")
        expect(UIDensity.compact.cover < UIDensity.comfortable.cover && UIDensity.compact.rowHeight < UIDensity.comfortable.rowHeight, "Compact is smaller")
        expect(TypeWeight.allCases.allSatisfy { $0.emphasis == .light || $0.emphasis == .regular || $0.emphasis == .medium }, "nothing is heavier than Medium")
    }

    func theMixFollowsTheClockAndTheListener() {
        let cal = Calendar(identifier: .gregorian)
        func date(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: h, minute: m))! }
        for (h, part) in [(2, DayPart.late), (5, .morning), (10, .morning), (11, .afternoon), (16, .afternoon), (17, .evening), (21, .evening), (22, .night), (23, .night)] {
            expect(DayPart.of(hour: Double(h)) == part, "\(h):00 is \(part)")
        }
        let now = date(21, 30)
        let lib = library(now: now)
        let a = HomeRecommender.mix(albums: lib, now: now, seed: 7, calendar: cal)
        let b = HomeRecommender.mix(albums: lib, now: now, seed: 7, calendar: cal)
        expect(a == b, "the same seed, clock and library make the same page")
        let c = HomeRecommender.mix(albums: lib, now: now, seed: 8, calendar: cal)
        expect(a != c, "another seed (the next launch) makes another page")
        expect(a.daypart == .evening && a.greeting == "Good evening" && a.why.hasPrefix("9:30 pm"), "evening at 9:30 pm: \(a.why)")
        let late = HomeRecommender.mix(albums: lib, now: date(1), seed: 7, calendar: cal)
        expect(late.greeting == "Still up" && late.why != a.why, "late at night is a different mood")
        // everything it offers is in the library, once
        let ids = Set(lib.map(\.id))
        expect(a.quick.allSatisfy(ids.contains) && Set(a.quick).count == a.quick.count && a.quick.count == 24, "quick picks are real albums, each once")
        for s in a.shelves {
            expect(s.items.allSatisfy(ids.contains) && Set(s.items).count == s.items.count && s.items.count >= 3, "shelf \(s.id) holds real albums")
        }
        expect(Set(a.shelves.map(\.id)).count == a.shelves.count && !a.shelves.isEmpty, "each shelf once")
        expect(!a.reasons.isEmpty && a.reasons.allSatisfy { !$0.isEmpty }, "there is a reason to show")
        // an empty or tiny library does not break it
        let empty = HomeRecommender.mix(albums: [], now: now, seed: 1, calendar: cal)
        expect(empty.quick.isEmpty && empty.shelves.isEmpty && empty.profile == "New listener", "empty library")
        let tiny = HomeRecommender.mix(albums: [album(1, genres: ["Jazz"])], now: now, seed: 1, calendar: cal)
        expect(tiny.quick == ["r1"] && tiny.shelves.count <= 1, "one album")
    }

    func theListenersHistoryShapesTheMix() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 14))!
        // a listener who plays only jazz: jazz counts most, and the profile says so
        var lib = (0..<20).map { album($0, genres: $0 < 10 ? ["Jazz"] : ["Folk"], plays: $0 < 10 ? 30 : 1) }
        let w = HomeRecommender.profileWeights(lib)
        expect((w["jazz"] ?? 0) > (w["folk"] ?? 0) * 2 && (w["jazz"] ?? 0) <= 3.0001 && (w["folk"] ?? 0) >= 0.3, "weights: \(w)")
        expect(HomeRecommender.profileName(w).hasPrefix("Jazz"), HomeRecommender.profileName(w))
        let mix = HomeRecommender.mix(albums: lib, now: now, seed: 3, calendar: cal)
        let jazzInQuick = mix.quick.prefix(8).filter { id in lib.first { $0.id == id }?.genres == ["Jazz"] }.count
        expect(jazzInQuick >= 5, "the first quick picks follow what is played: \(jazzInQuick) of 8 are jazz")
        // albums last played around this hour come first
        let t = now.timeIntervalSince1970
        lib[15].lastPlayed = t - 3 * 86_400 - 0     // two p.m. three days ago: this hour
        expect(HomeRecommender.lastPlayedPart(lib[15], calendar: cal) == .afternoon, "the hour an album was last played in")
        // filters
        let hi = HomeFilter.hiRes, new = HomeFilter.newToMe
        expect(hi.accepts(album(1, genres: [], hiRes: true)) && !hi.accepts(album(1, genres: [])) && new.accepts(album(1, genres: [], plays: 0)) && !new.accepts(album(1, genres: [], plays: 2)), "chips")
        expect(HomeFilter.focus.accepts(album(1, genres: ["Ambient"])) && !HomeFilter.focus.accepts(album(1, genres: ["Death Metal"])) && HomeFilter.all.accepts(album(1, genres: [])), "mood chips")
        // the aggregate groups tracks by release
        func track(_ n: Int, rel: String, plays: Int?, last: Double?) -> TrackDTO {
            TrackDTO(id: "t\(n)", path: "/m/\(n).flac", title: "T\(n)", trackNumber: n, discNumber: 1, duration: 100, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2, year: 2020, releaseID: rel, releaseTitle: "Rel " + rel, workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil, credits: [], genres: ["Jazz"], mbRecordingID: nil, playCount: plays, lastPlayedAt: last)
        }
        let agg = HomeModel.aggregate([track(1, rel: "A", plays: 2, last: 10), track(2, rel: "A", plays: 3, last: 50), track(3, rel: "B", plays: nil, last: nil)])
        let a = agg.first { $0.id == "A" }, b = agg.first { $0.id == "B" }
        expect(agg.count == 2 && a?.plays == 5 && a?.lastPlayed == 50 && a?.hiRes == true && b?.plays == 0 && b?.lastPlayed == nil, "plays add up, the latest play wins")
    }

    func theSkyFollowsItsSettings() {
        // shooting stars: off means none, and the pace changes with the setting
        expect(ShootingStars.off.interval == nil && ShootingStars.rare.interval!.min > ShootingStars.often.interval!.max, "rare is far slower than often")
        var off = StarlightSky(now: 0, interval: nil, rng: { 0.5 })
        expect((0..<2000).allSatisfy { off.shot(at: Double($0), quiet: false) == nil }, "off: no star, ever")
        var often = StarlightSky(now: 0, interval: ShootingStars.often.interval, rng: { 0.5 })
        var seen = 0, inFlight = false
        for i in 0..<6000 {
            let s = often.shot(at: Double(i) * 0.1, quiet: false)
            if s != nil, !inFlight { seen += 1 }
            inFlight = s != nil
        }
        expect(seen >= 30, "often: a star about every ten seconds: \(seen) in ten minutes")
        var typing = StarlightSky(now: 0, interval: ShootingStars.often.interval, rng: { 0.5 })
        expect((0..<2000).allSatisfy { typing.shot(at: Double($0) * 0.1, quiet: true) == nil }, "none while typing")
        var changed = StarlightSky(now: 0, interval: nil, rng: { 0.5 })
        changed.setInterval(ShootingStars.often.interval, at: 100)
        expect(changed.next > 100 && changed.next < 120, "a changed setting is scheduled afresh")
        // the tint: white leaves the stars alone; the accent tints them without darkening
        let t = Theme.aureon
        expect(StarlightModel.starTint(.white, theme: t, palette: nil) == SIMD3<Float>(1, 1, 1))
        let tinted = StarlightModel.starTint(.accent, theme: t, palette: nil)
        expect(max(tinted.x, tinted.y, tinted.z) <= 1.0001 && min(tinted.x, tinted.y, tinted.z) >= 0.25 && tinted != SIMD3<Float>(1, 1, 1), "accent tint: \(tinted)")
        var st = StarlightSettings(); st.twinkle = false; st.tint = .accent
        let u = StarlightModel.uniforms(time: 5, settings: st, theme: t, palette: nil, energy: 0, veil: 0, size: CGSize(width: 800, height: 600), shoot: nil)
        expect(u.e.x == 0 && u.e.y == tinted.x, "twinkle and tint reach the shader")
        // still when motion is reduced or the window is hidden
        expect(StarlightPolicy.mode(visible: true, appActive: true, lowPower: false, reduceMotion: true, snapshot: false) == .still, "Reduce Motion: one still frame")
        expect(StarlightPolicy.mode(visible: false, appActive: true, lowPower: false, reduceMotion: false, snapshot: false) == .still, "hidden: still")
        expect(StarlightPolicy.mode(visible: true, appActive: true, lowPower: true, reduceMotion: false, snapshot: false) == .live15, "low power: half rate")
    }

    func theFoldersPageReadsStatus() {
        expect(FolderStatus.of(path: "/x", watching: true, importing: false, progress: "", exists: true) == .watching, "watching")
        expect(FolderStatus.of(path: "/x", watching: true, importing: false, progress: "", exists: false) == .missing, "a disk that is gone")
        expect(FolderStatus.of(path: "/x", watching: false, importing: true, progress: "12 of 40 files", exists: true) == .scanning("12 of 40 files"), "scanning shows progress")
        expect(FolderStatus.of(path: "/x", watching: false, importing: false, progress: "", exists: true) == .idle && FolderStatus.missing.detail == "Needs access")
        let suite = UserDefaults(suiteName: "aureon.test.fonts.\(UUID().uuidString)")!; _ = suite
        // the font loader reads nothing from a folder without fonts and never fails
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        expect(TypeFace.registerBundled(bundle: Bundle(for: PulseTestsAnchor.self), extraFolders: [empty]) >= 0 && !TypeFace.family.isEmpty, "the font loader copes with no fonts")
        try? FileManager.default.removeItem(at: empty)
    }
}

extension PulseTests {
    func theLayoutsAreChosenAndRemembered() {
        expect(NowPlayingLayout.allCases.map(\.rawValue) == ["stage", "classic", "fullbleed", "carousel", "lumen", "chillax"], "six layouts, Stage first")
        expect(NowPlayingLayout.standard == .stage && LookSettings().nowPlayingLayout == "stage", "Stage is the default")
        expect(NowPlayingLayout.resolve("lumen") == .lumen && NowPlayingLayout.resolve("vinyl") == .stage && NowPlayingLayout.resolve(nil) == .stage && NowPlayingLayout.resolve("") == .stage, "an unknown id is Stage")
        expect(NowPlayingLayout.allCases.allSatisfy { !$0.title.isEmpty && !$0.blurb.isEmpty } && Set(NowPlayingLayout.allCases.map(\.title)).count == 6, "each has a name and a line")
        expect(NowPlayingLayout.stage.hasTabs && NowPlayingLayout.classic.hasTabs && !NowPlayingLayout.lumen.hasTabs && !NowPlayingLayout.chillax.hasTabs, "tabs where the layout has them")
        let suite = UserDefaults(suiteName: "aureon.test.np.\(UUID().uuidString)")!
        var s = LookSettings(); s.nowPlayingLayout = "chillax"; s.lyricSize = .huge; s.seekChoice = .line; s.showPlaylistButton = false; s.showCredits = false; s.showSignalTags = false
        s.save(suite)
        let back = LookSettings.load(suite, environment: [:])
        expect(back == s && NowPlayingLayout.resolve(back.nowPlayingLayout) == .chillax, "the layout and the screen's options are remembered")
        expect(LookSettings().lyricSize == .large && LookSettings().seekChoice == .layout && LookSettings().showPlaylistButton && LookSettings().showCredits && LookSettings().showSignalTags, "defaults")
        expect(LyricSize.medium.scale < LyricSize.large.scale && LyricSize.large.scale == 1 && LyricSize.large.scale < LyricSize.huge.scale, "lyric sizes")
        // the scale follows the window, within limits
        expect(NPScale.of(CGSize(width: 1440, height: 900)) == 1 && NPScale.of(CGSize(width: 300, height: 200)) == 0.62 && NPScale.of(CGSize(width: 4000, height: 3000)) == 1.25, "the layout is drawn at 1440 × 900 and scaled")
        expect(NPScale.of(CGSize(width: 1440, height: 450)) == 0.62 || NPScale.of(CGSize(width: 1440, height: 450)) == 0.62 + 0, "a short window shrinks it: \(NPScale.of(CGSize(width: 1440, height: 450)))")
    }

    func creditsAndTheSignalPathReadWell() {
        func c(_ role: CreditRole, _ name: String, _ inst: String? = nil) -> CreditDTO { CreditDTO(role: role.rawValue, name: name, instrument: inst, partyID: name) }
        let lines = NPCredits.lines([c(.artist, "Marlowe Quay"), c(.composer, "M. Quay"), c(.lyricist, "Ines Vale"), c(.composer, "M. Quay"), c(.producer, "Tomas Hale"), c(.engineer, "R. Okafor"),
                                     c(.soloist, "Ines Vale", "piano"), c(.performer, "Pier Nine", "field recording"), c(.conductor, "H. Karajan"), c(.ensemble, "Berliner Philharmoniker")])
        expect(lines.map(\.label) == ["Written by", "Produced by", "Engineered by", "Conductor", "Ensemble", "Piano", "Field recording"], "\(lines.map(\.label))")
        expect(lines.first?.value == "M. Quay, Ines Vale" && lines.first { $0.label == "Piano" }?.value == "Ines Vale", "names once each, joined")
        expect(NPCredits.lines([]).isEmpty && NPCredits.lines([c(.artist, "Only Artist")]).isEmpty, "the artist is not a credit; no credits, no lines")
        expect(NPCredits.line(lines, limit: 2) == "Written by M. Quay, Ines Vale · Produced by Tomas Hale", NPCredits.line(lines, limit: 2))
        let src = StreamInfo(sampleRate: 96_000, channels: 2, sourceBits: 24, totalFrames: 96_000 * 200, codec: "FLAC")
        let out = StreamInfo(sampleRate: 192_000, channels: 2, sourceBits: 24, totalFrames: 192_000 * 200, codec: "FLAC")
        let steps = NPSignal.steps(source: src, output: out, stages: [], bitPerfect: true, exclusive: true, device: "DAC-1")
        expect(steps.map(\.title) == ["Source", "Player", "Output"] && steps[0].detail == "FLAC · 24-bit / 96 kHz" && steps[1].detail == "Bit-perfect, no resampling" && steps[2].detail == "Exclusive mode · DAC-1 · 192 kHz", "\(steps)")
        let line = NPSignal.line(source: src, output: out, stages: [], bitPerfect: true, exclusive: true, device: "DAC-1")
        expect(line == "FLAC 24/96 → bit-perfect → exclusive mode → DAC-1 · 192 kHz", line)
        let processed = NPSignal.line(source: src, output: out, stages: ["Upsampling 96 kHz → 192 kHz"], bitPerfect: false, exclusive: false, device: "")
        expect(processed.contains("upsampling") && processed.contains("output") && !processed.contains("bit-perfect"), processed)
        expect(NPSignal.steps(source: nil, output: nil, stages: [], bitPerfect: false, exclusive: false, device: "").isEmpty && NPSignal.line(source: nil, output: nil, stages: [], bitPerfect: false, exclusive: false, device: "").isEmpty, "nothing playing")
        let dsd = StreamInfo(sampleRate: 2_822_400, channels: 2, sourceBits: 1, totalFrames: 1, codec: "DSF")
        expect(NPSignal.steps(source: dsd, output: nil, stages: [], bitPerfect: true, exclusive: false, device: "")[0].detail.contains("DSD"), "DSD is named")
    }

    func theQueueSeenFromNowPlaying() {
        struct It: Identifiable { var id: Int }
        let q = (0..<10).map(It.init)
        expect(NPQueue.upNext(q, current: 3, limit: 4).map(\.id) == [4, 5, 6, 7], "what follows the current song")
        expect(NPQueue.upNext(q, current: 8, limit: 5).map(\.id) == [9], "the end of the queue")
        expect(NPQueue.upNext(q, current: 9, limit: 5).isEmpty && NPQueue.upNext([It](), current: nil, limit: 5).isEmpty, "nothing after the last; nothing in an empty queue")
        expect(NPQueue.upNext(q, current: nil, limit: 3).map(\.id) == [0, 1, 2] && NPQueue.upNext(q, current: 99, limit: 2).map(\.id) == [0, 1], "nothing playing: from the start")
        let n = NPQueue.neighbours(q, current: 5)
        expect(n.previous?.id == 4 && n.next?.id == 6, "the covers beside the centre")
        let first = NPQueue.neighbours(q, current: 0), last = NPQueue.neighbours(q, current: 9)
        expect(first.previous == nil && first.next?.id == 1 && last.previous?.id == 8 && last.next == nil, "no neighbour past either end")
    }
}

extension PulseTests {
    func theMiniPlayerSettingsAreRemembered() {
        let suite = UserDefaults(suiteName: "aureon.test.mini.\(UUID().uuidString)")!
        var s = LookSettings()
        expect(s.mini.layout == .bar && s.mini.background == .gradient && s.mini.alwaysOnTop && s.mini.formatTags && !s.mini.menuBar.show && s.mini.menuBar.autoCloseSeconds == 5 && s.mini.menuBar.closeOnOutsideClick && s.mini.keepFloating && s.mini.rememberPosition && !s.mini.onEveryDesktop, "defaults: the bar, a gradient, on top, closes after five seconds")
        s.mini.layout = .cardLyrics; s.mini.background = .blur; s.mini.strength = 0.3; s.mini.opacity = 0.7; s.mini.menuBar.show = true; s.mini.menuBar.shows = .title; s.mini.menuBar.openOn = .hover; s.mini.menuBar.autoCloseSeconds = 30; s.mini.menuBar.keepOpenWhileOver = false
        s.save(suite)
        expect(LookSettings.load(suite, environment: [:]).mini == s.clamped().mini, "everything comes back")
        suite.set(Data(#"{"mini":{"layout":"strip"}}"#.utf8), forKey: LookSettings.storageKey)
        let old = LookSettings.load(suite, environment: [:]).mini
        expect(old.layout == .strip && old.background == .gradient && old.menuBar == MenuBarSettings(), "an older record reads with the defaults in place of what is missing")
        var wild = LookSettings(); wild.mini.strength = 7; wild.mini.opacity = -2; wild.mini.menuBar.autoCloseSeconds = 17
        let c = wild.clamped().mini
        expect(c.strength == 1 && c.opacity == 0.4 && c.menuBar.autoCloseSeconds == 5, "values are held in range: \(c.strength) \(c.opacity) \(c.menuBar.autoCloseSeconds)")
        expect(LookSettings.load(suite, environment: ["AUREON_LOOK": "mini=card,minibg=solid,menubar=1"]).mini.layout == .card, "the environment overlay reaches it")
        // the layouts
        expect(MiniLayout.allCases.map(\.rawValue) == ["bar", "strip", "card", "cardLyrics", "popover"] && MiniLayout.allCases.allSatisfy { !$0.title.isEmpty && !$0.blurb.isEmpty }, "five layouts")
        expect(MiniLayout.bar.size == CGSize(width: 520, height: 96) && MiniLayout.strip.size.height == 48 && MiniLayout.card.size == CGSize(width: 380, height: 620) && MiniLayout.popover.size == CGSize(width: 340, height: 236), "the sizes of the boards")
        expect(MiniLayout.allCases.filter(\.isWindow).count == 4 && !MiniLayout.popover.isWindow, "the popover is the one that is not a window")
    }

    func positionsComeBackOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875), other = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let size = CGSize(width: 520, height: 96)
        expect(MiniSettings.onScreen(origin: CGPoint(x: 100, y: 100), size: size, screens: [screen]) == nil, "a place on a screen is kept")
        expect(MiniSettings.onScreen(origin: CGPoint(x: 1500, y: 100), size: size, screens: [screen, other]) == nil, "and on the second one")
        let moved = MiniSettings.onScreen(origin: CGPoint(x: 1500, y: 100), size: size, screens: [screen])
        expect(moved != nil && screen.contains(CGRect(origin: moved!, size: size)), "a display that is gone: the window comes back to the one that is left: \(String(describing: moved))")
        let far = MiniSettings.onScreen(origin: CGPoint(x: -4000, y: 5000), size: size, screens: [screen])
        expect(far != nil && screen.contains(CGRect(origin: far!, size: size)), "far away: brought in")
        expect(MiniSettings.onScreen(origin: .zero, size: size, screens: []) == nil, "no screens, nothing to do")
        let o = MiniSettings.defaultOrigin(size: size, in: screen)
        expect(screen.contains(CGRect(origin: o, size: size)) && o.x > screen.midX && o.y > screen.midY, "the first place is the top right")
    }

    func thePopoverClosesOnItsOwnTimeAndWaitsForThePointer() {
        typealias C = PopoverCountdown
        expect(C.action(autoClose: 0, elapsed: 99, pointerInside: false, keepWhileOver: true) == .none, "never: no countdown")
        expect(C.action(autoClose: 5, elapsed: 1, pointerInside: false, keepWhileOver: true) == .wait(4), "waits out the rest of the time")
        expect(C.action(autoClose: 5, elapsed: 5, pointerInside: false, keepWhileOver: true) == .close, "time is up")
        expect(C.action(autoClose: 5, elapsed: 8, pointerInside: true, keepWhileOver: true) == .wait(1), "the pointer is over it: it waits")
        expect(C.action(autoClose: 5, elapsed: 8, pointerInside: true, keepWhileOver: false) == .close, "unless it was told not to")
        expect(MenuBarSettings.autoCloseChoices == [0, 3, 5, 10, 30] && MenuBarSettings.label(0) == "Never" && MenuBarSettings.label(30) == "30 s", "the choices")
    }

    @MainActor func theFloatingWindowFollowsTheSettings() {
        guard !NSScreen.screens.isEmpty else { return }
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let ud = UserDefaults.standard
        let savedOrigin = ud.object(forKey: "aureon.mini.origin"), savedHeight = ud.object(forKey: "aureon.mini.height")
        defer { if let savedOrigin { ud.set(savedOrigin, forKey: "aureon.mini.origin") } else { ud.removeObject(forKey: "aureon.mini.origin") }; if let savedHeight { ud.set(savedHeight, forKey: "aureon.mini.height") } else { ud.removeObject(forKey: "aureon.mini.height") }; m.mini.shutDown() }
        m.look.mini.rememberPosition = false
        m.look.mini.layout = .bar
        m.mini.toggle()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        expect(m.mini.isFloatingOpen, "the button opens the bar")
        if let st = m.mini.floatingState {
            expect(st.frame.size == MiniLayout.bar.size && st.level == .floating && abs(st.alpha - 0.92) < 0.001 && !st.onEveryDesktop, "size, on top, opacity: \(st)")
        } else { expect(false, "there is a window") }
        // changing the settings changes the open window
        m.look.mini.alwaysOnTop = false; m.look.mini.opacity = 0.6; m.look.mini.onEveryDesktop = true
        if let st = m.mini.floatingState { expect(st.level == .normal && abs(st.alpha - 0.6) < 0.001 && st.onEveryDesktop, "level, opacity and desktops follow: \(st)") } else { expect(false, "still there") }
        let top = m.mini.floatingState?.frame.maxY
        m.look.mini.layout = .card
        if let st = m.mini.floatingState { expect(st.frame.size == MiniLayout.card.size && abs(st.frame.maxY - (top ?? 0)) < 0.5, "another layout resizes from the top edge: \(st.frame)") } else { expect(false, "the card") }
        // the popover layout is not a window: the open window is put away
        m.look.mini.layout = .popover
        expect(!m.mini.isFloatingOpen, "the popover is not a floating window")
        m.look.mini.layout = .strip
        m.mini.toggle()
        expect(m.mini.isFloatingOpen && m.mini.floatingState?.frame.size == MiniLayout.strip.size, "the strip")
        m.mini.toggle()
        expect(!m.mini.isFloatingOpen, "the button puts it away again")
    }
}

nonisolated(unsafe) private var pulseKeepAlive: [AnyObject] = []

extension PulseTests {
    /// Each mini layout drawn as the real view (a development aid: `AUREON_MINI_SHOTS=/folder` writes a PNG of each; without it nothing is written).
    @MainActor func theMiniLayoutsDrawWithoutTrouble() {
        guard !NSScreen.screens.isEmpty else { return }
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let out = ProcessInfo.processInfo.environment["AUREON_MINI_SHOTS"]
        for l in MiniLayout.allCases {
            for bg in MiniBackground.allCases {
                m.look.mini.background = bg
                let host = NSHostingView(rootView: MiniLayoutView(layout: l).miniEnvironment(m).frame(width: l.size.width, height: l.size.height))
                host.frame = NSRect(origin: .zero, size: l.size)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.contentView = host; win.setFrameOrigin(NSPoint(x: -9000, y: -9000)); win.orderFront(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { expect(false, "\(l) \(bg): a bitmap"); win.orderOut(nil); continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                var coloured = 0
                if let data = rep.bitmapData { for i in stride(from: 0, to: rep.bytesPerRow * rep.pixelsHigh, by: 64) where data[i] != data[i + 1] || data[i + 1] != data[i + 2] || data[i] > 20 { coloured += 1 } }
                expect(coloured > 20, "\(l) \(bg): something is drawn")
                if let out { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("mini-\(l.rawValue)-\(bg.rawValue).png")) }
                win.orderOut(nil); win.contentView = nil
            }
        }
    }
}

private final class PulseTestsAnchor {}

func pulseTests() -> [(String, TestFn)] {
    let t = PulseTests()
    return [("pulse.settings", t.settingsAreSavedAndRestored), ("pulse.mix", t.theMixFollowsTheClockAndTheListener), ("pulse.history", t.theListenersHistoryShapesTheMix),
            ("pulse.sky", t.theSkyFollowsItsSettings), ("pulse.folders", t.theFoldersPageReadsStatus),
            ("pulse.miniSettings", t.theMiniPlayerSettingsAreRemembered), ("pulse.miniPlaces", t.positionsComeBackOnScreen), ("pulse.miniCountdown", t.thePopoverClosesOnItsOwnTimeAndWaitsForThePointer),
            ("pulse.miniWindow", { MainActor.assumeIsolated { t.theFloatingWindowFollowsTheSettings() } }), ("pulse.miniDraw", { MainActor.assumeIsolated { t.theMiniLayoutsDrawWithoutTrouble() } }), ("pulse.layouts", t.theLayoutsAreChosenAndRemembered), ("pulse.credits", t.creditsAndTheSignalPathReadWell), ("pulse.queue", t.theQueueSeenFromNowPlaying)]
}

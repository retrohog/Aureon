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
        // the bundled font is found where the build puts it, and carries its licence
        let fonts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Packaging/Fonts")
        if FileManager.default.fileExists(atPath: fonts.path) {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: fonts.path)) ?? []).sorted()
            expect(names.contains { $0.hasPrefix("Figtree") && $0.hasSuffix(".ttf") } && names.contains("OFL.txt"), "Figtree and its licence are bundled together: \(names)")
            TypeFace.registerBundled(bundle: Bundle(for: PulseTestsAnchor.self), extraFolders: [fonts])
            expect(TypeFace.hasPreferred && TypeFace.family == "Figtree", "the interface is set in Figtree")
        }
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

private final class KeyableWindow: NSWindow { override var canBecomeKey: Bool { true } }

extension PulseTests {
    /// The history behind the queue panel's History tab.
    @MainActor func playedHistoryKeepsTheOrder() {
        var log = PlayedLog()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        log.note(path: "/a.flac", title: "A", artist: "x", album: "y", at: t0)
        log.note(path: "/b.flac", title: "B", artist: "", album: "", at: t0.addingTimeInterval(60))
        log.note(path: "/b.flac", title: "B", artist: "", album: "", at: t0.addingTimeInterval(61))
        expect(log.entries.map(\.title) == ["B", "A"], "newest first, a repeat straight away is not listed twice: \(log.entries.map(\.title))")
        log.note(path: "/a.flac", title: "A", artist: "x", album: "y", at: t0.addingTimeInterval(120))
        expect(log.entries.map(\.title) == ["A", "B", "A"], "a song heard again later is listed again")
        for i in 0..<300 { log.note(path: "/s\(i).flac", title: "S\(i)", artist: "", album: "") }
        expect(log.entries.count == PlayedLog.limit && log.entries.first?.title == "S299", "the log is bounded and keeps the newest: \(log.entries.count)")
        log.clear()
        expect(log.entries.isEmpty, "clearing empties it")
        let now = Date()
        expect(PlayedLog.age(now, now: now) == "just now" && PlayedLog.age(now.addingTimeInterval(-300), now: now) == "5 min ago" && PlayedLog.age(now.addingTimeInterval(-7200), now: now) == "2 h ago" && PlayedLog.age(now.addingTimeInterval(-100_000), now: now) == "yesterday", "ages read plainly")
        expect(QueueTab.allCases.map(\.rawValue) == ["Queue", "History", "Output"], "three tabs")
    }

    /// Playing songs fills the history, and a click in it plays the song again.
    @MainActor func playingFillsTheHistory() {
        setenv("AUREON_NULLSINK", "1", 1)
        let dir = tempDir("nphist")
        var urls: [URL] = []
        for i in 0..<3 {
            let u = dir.appendingPathComponent("Hist \(i).wav")
            _ = writeWAV(u, rate: 8000, bits: 16, frames: 8000 * 20) { f, _ in Int(2000 * sin(Double(f) * 0.1)) }
            urls.append(u)
        }
        let m = PlayerModel(); pulseKeepAlive.append(m)
        defer { m.clear() }
        m.add(urls: urls, play: false)
        guard m.items.count == 3 else { expect(false, "three songs are queued"); return }
        m.play(m.items[0].id); pumpFor(0.8)
        m.play(m.items[2].id); pumpFor(0.8)
        expect(m.playedLog.entries.map(\.path) == [m.items[2].path, m.items[0].path], "the two songs played are listed, newest first: \(m.playedLog.entries.map(\.title))")
        m.playAgain(path: m.items[0].path); pumpFor(0.8)
        expect(m.status.trackID == m.items[0].id && m.playedLog.entries.first?.path == m.items[0].path, "a click in the history plays the song again")
        m.clearPlayedLog()
        expect(m.playedLog.entries.isEmpty, "and Clear empties it")
    }

    /// What an earlier choice becomes: the family, the mode and the pure black switch.
    @MainActor func savedThemesAreCarriedOver() {
        func start(_ values: [String: String]) -> (family: String, mode: AppearanceMode, pureBlack: Bool) {
            let name = "aureon.test.themes.\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            defer { d.removePersistentDomain(forName: name) }
            for (k, v) in values { d.set(v, forKey: k) }
            return PlayerModel.startingTheme(defaults: d, environmentTheme: nil)
        }
        func check(_ values: [String: String], _ family: String, _ mode: AppearanceMode, black: Bool = false, _ what: String) {
            let r = start(values)
            expect(r.family == family && r.mode == mode && r.pureBlack == black, "\(what): \(r)")
        }
        check([:], "graphite", .dark, "a fresh install is Graphite, dark")
        check(["aureon.appearance": "dark", "aureon.darkTheme": "graphite"], "graphite", .dark, "Graphite")
        check(["aureon.appearance": "dark", "aureon.darkTheme": "amoled"], "graphite", .dark, black: true, "AMOLED is Graphite on pure black")
        for f in ["midnight", "forest", "plum", "cocoa"] { check(["aureon.appearance": "dark", "aureon.darkTheme": f], f, .dark, "\(f) keeps its name") }
        check(["aureon.appearance": "light", "aureon.lightTheme": "stone", "aureon.darkTheme": "plum"], "graphite", .light, "Stone is Graphite, light")
        check(["aureon.appearance": "light", "aureon.lightTheme": "sage"], "forest", .light, "Sage is Forest, light")
        check(["aureon.appearance": "light", "aureon.lightTheme": "paper"], "cocoa", .light, "Paper is Cocoa, light")
        check(["aureon.appearance": "system", "aureon.darkTheme": "plum", "aureon.lightTheme": "sage"], "plum", .system, "Auto keeps the dark choice's family")
        check(["aureon.theme": "nord"], "midnight", .dark, "the first versions' ids are carried over")
        check([PlayerModel.familyKey: "cocoa", "aureon.appearance": "system", "aureon.darkTheme": "plum"], "cocoa", .system, "a saved family wins over old keys")
        check([PlayerModel.familyKey: "nonsense"], "graphite", .dark, "an unknown family falls back")
        // the environment can name a theme for screenshots
        expect(PlayerModel.startingTheme(defaults: UserDefaults(suiteName: "aureon.test.themes.env")!, environmentTheme: Theme.named("plum.light")) == ("plum", .light, false), "AUREON_THEME names a family and mode")
        UserDefaults.standard.removePersistentDomain(forName: "aureon.test.themes.env")
    }

    /// Family × mode × pure black as the model shows them: the dark half follows pure black, the light half ignores it, Auto follows the system as it changes.
    @MainActor func modelShowsFamilyInEveryMode() {
        let ud = UserDefaults.standard
        let keys = ["aureon.appearance", PlayerModel.familyKey]
        let saved = keys.map { ud.string(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) } }; Theme.current = Theme.aureon }
        let m = PlayerModel(); pulseKeepAlive.append(m)
        var systemLight = false
        m.systemIsLight = { systemLight }
        for f in Theme.families {
            m.choose(family: f.id)
            for mode in AppearanceMode.allCases {
                for black in [false, true] {
                    m.appearance = mode; m.look.pureBlack = black
                    systemLight = false; m.resolveTheme(persist: false)
                    let dark = m.theme
                    systemLight = true; m.resolveTheme(persist: false)
                    let day = m.theme
                    switch mode {
                    case .dark: expect(dark.family == f.id && !dark.isLight && dark.pureBlack == black && day == dark, "\(f.id) dark, black \(black)")
                    case .light: expect(dark.isLight && dark == day && !day.pureBlack && day.family == f.id, "\(f.id) light ignores pure black")
                    case .system: expect(!dark.isLight && dark.pureBlack == black && day.isLight && !day.pureBlack && day.family == f.id, "\(f.id) Auto: dark at night (black \(black)), light by day")
                    }
                    expect(Theme.current == m.theme, "\(f.id): the theme in use is the one shown")
                }
            }
        }
        // the window of the dark half is black when asked, whatever the family
        m.appearance = .dark; m.look.pureBlack = true; m.choose(family: "midnight")
        expect(m.theme.sidebarRGB == RGB(0, 0, 0) && m.theme.family == "midnight", "Midnight on pure black")
        m.look.pureBlack = false
        expect(m.theme.sidebarRGB != RGB(0, 0, 0), "and off again")
        // the light half stays dimmed by the brightness slider
        m.appearance = .light
        m.look.lightBrightness = 0
        let dim = WCAG.luminance(m.theme.canvasRGB)
        m.look.lightBrightness = 1
        expect(dim < WCAG.luminance(m.theme.canvasRGB), "the light half is brighter at 1 than at 0")
        m.look.lightBrightness = LookSettings.defaults.lightBrightness
    }

    @MainActor private func pumpFor(_ secs: Double) {
        let end = Date().addingTimeInterval(secs)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// A real click at the middle of a probed frame (measured from the window's top-left corner).
    @MainActor private func clickMiddle(_ win: NSWindow, _ r: CGRect, height: CGFloat) {
        let loc = NSPoint(x: r.midX, y: height - r.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { win.sendEvent(e) }
            pumpFor(0.04)
        }
    }

    /// On Now Playing, in every layout, the output popover and the Add-to-playlist card stay open once opened: after a turn of the run loop, and while the
    /// lyrics keep ticking and redrawing under them.
    @MainActor func popoversStayOpenOnNowPlaying() {
        guard !NSScreen.screens.isEmpty else { return }
        setenv("AUREON_NULLSINK", "1", 1)
        let dir = tempDir("nppop")
        let song = dir.appendingPathComponent("Popover Check.wav")
        _ = writeWAV(song, rate: 8000, bits: 16, frames: 8000 * 40) { f, _ in Int(2500 * sin(Double(f) * 0.12)) }
        let lrc = (0..<12).map { String(format: "[00:%02d.00]A made-up line number %d for the popovers", $0 * 3 + 1, $0) }.joined(separator: "\n")
        try? Data(("[ti:Popover Check]\n" + lrc + "\n").utf8).write(to: dir.appendingPathComponent("Popover Check.lrc"))
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let stage = StageModel(); pulseKeepAlive.append(stage)
        let saved = LyricsService.shared.isOnlineAllowed
        LyricsService.shared.isOnlineAllowed = { false }
        LayoutProbe.enabled = true
        defer { m.clear(); LyricsService.shared.isOnlineAllowed = saved; LayoutProbe.enabled = false }
        m.add(urls: [song], play: false)
        for it in m.items { m.play(it.id) }
        stage.open(m, reduceMotion: true)
        let size = CGSize(width: 1500, height: 900)                 // wide enough for the output chip to be in the controls of every layout
        for layout in NowPlayingLayout.allCases {
            m.look.nowPlayingLayout = layout.rawValue; m.look.showLyrics = true
            let probe = LayoutProbe.begin()
            let host = NSHostingView(rootView: AnyView(ContentView(stage: stage).environmentObject(m).environment(\.probeToken, probe).frame(width: size.width, height: size.height).preferredColorScheme(.dark)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = KeyableWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host; win.setFrameOrigin(NSPoint(x: -9000, y: -9000)); win.makeKeyAndOrderFront(nil)
            pumpFor(1.2)
            for (what, key) in [("output popover", "output.stage"), ("playlist card", "playlistButton")] {
                guard let r = LayoutProbe.frames[key] else { expect(false, "\(layout.rawValue): the \(what) button is on screen"); continue }
                expect(!m.popovers.isOpen, "\(layout.rawValue): nothing is open before the \(what) is opened")
                clickMiddle(win, r, height: size.height)
                pumpFor(0.1)
                expect(m.popovers.isOpen, "\(layout.rawValue): the \(what) opened")
                if what == "output popover" { expect(m.quickPanel == .stage, "\(layout.rawValue): the output popover belongs to the stage chip") }
                expect(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(m.popovers.shownFrame) && m.popovers.shownFrame.width > 50, "\(layout.rawValue): the \(what) is inside the window: \(m.popovers.shownFrame)")
                pumpFor(1.6)                                           // the lyrics tick and redraw meanwhile
                expect(m.popovers.isOpen, "\(layout.rawValue): the \(what) is still open after the lyrics redraw")
                if what == "output popover" { expect(m.quickPanel == .stage, "\(layout.rawValue): the output popover was not closed by a redraw") }
                m.popovers.dismiss(); m.quickPanel = nil
                pumpFor(0.3)
            }
            win.orderOut(nil); win.contentView = nil
            pumpFor(0.15)
        }
    }

    /// The songs that come next have their tags and covers asked for ahead of time (ten, once each), so the Up next lists have pictures when drawn.
    @MainActor func upcomingArtworkIsPrefetched() {
        setenv("AUREON_NULLSINK", "1", 1)
        let dir = tempDir("npart")
        var urls: [URL] = []
        for i in 0..<16 {
            let u = dir.appendingPathComponent(String(format: "Song %02d.wav", i))
            _ = writeWAV(u, rate: 8000, bits: 16, frames: 8000 * 20) { f, _ in Int(2000 * sin(Double(f) * 0.1)) }
            urls.append(u)
        }
        let m = PlayerModel(); pulseKeepAlive.append(m)
        defer { m.clear() }
        m.add(urls: urls, play: false)
        expect(m.items.count == 16, "all sixteen songs are queued")
        guard m.items.count == 16 else { return }
        m.play(m.items[2].id)
        pumpFor(0.6)
        m.prefetchUpcomingArtwork()
        let asked = m.artworkRequested
        for k in 3...12 { expect(asked.contains(m.items[k].id), "song \(k), one of the next ten, was asked for") }
        for k in 13...15 { expect(!asked.contains(m.items[k].id), "song \(k), beyond the next ten, was not asked for yet") }
        let before = m.artworkRequested.count
        m.prefetchUpcomingArtwork(); m.prefetchUpcomingArtwork()
        expect(m.artworkRequested.count == before, "asking again does not ask twice")
        pumpFor(2.5)
        let settled = (3...12).filter { m.items[$0].artSource != .unknown }.count
        expect(settled == 10, "the tags of the next ten were read in the background: \(settled)")
    }

    /// Switching between the Aureon window and the mini player, again and again, from every Now Playing layout and into every mini player form, with the real
    /// window, the real buttons (the top bar's and the controls' of Now Playing) and real mouse events, with the main window put away and left in place.
    @MainActor func switchingToTheMiniPlayerNeverCrashes() {
        guard !NSScreen.screens.isEmpty else { return }
        setenv("AUREON_NULLSINK", "1", 1)
        let ud = UserDefaults.standard
        let savedOrigin = ud.object(forKey: "aureon.mini.origin"), savedHeight = ud.object(forKey: "aureon.mini.height")
        let dir = tempDir("npmini")
        let song = dir.appendingPathComponent("Mini Switch.wav")
        _ = writeWAV(song, rate: 8000, bits: 16, frames: 8000 * 60) { f, _ in Int(2500 * sin(Double(f) * 0.12)) }
        let lrc = (0..<12).map { String(format: "[00:%02d.00]A made-up line number %d for the switch", $0 * 3 + 1, $0) }.joined(separator: "\n")
        try? Data(("[ti:Mini Switch]\n" + lrc + "\n").utf8).write(to: dir.appendingPathComponent("Mini Switch.lrc"))
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let stage = StageModel(); pulseKeepAlive.append(stage)
        let saved = LyricsService.shared.isOnlineAllowed
        LyricsService.shared.isOnlineAllowed = { false }
        LayoutProbe.enabled = true
        let size = CGSize(width: 1100, height: 720)
        let probe = LayoutProbe.begin()
        let host = NSHostingView(rootView: AnyView(ContentView(stage: stage).environmentObject(m).environment(\.probeToken, probe).frame(width: size.width, height: size.height).preferredColorScheme(.dark)))
        host.frame = NSRect(origin: .zero, size: size)
        let win = KeyableWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: 80, y: 80)); win.makeKeyAndOrderFront(nil)
        m.mini.mainWindowProvider = { win }
        defer {
            m.mini.shutDown(); win.orderOut(nil); win.contentView = nil; m.clear()
            LyricsService.shared.isOnlineAllowed = saved; LayoutProbe.enabled = false
            if let savedOrigin { ud.set(savedOrigin, forKey: "aureon.mini.origin") } else { ud.removeObject(forKey: "aureon.mini.origin") }
            if let savedHeight { ud.set(savedHeight, forKey: "aureon.mini.height") } else { ud.removeObject(forKey: "aureon.mini.height") }
        }
        m.add(urls: [song], play: false)
        for it in m.items { m.play(it.id) }
        stage.open(m, reduceMotion: true)
        m.look.mini.rememberPosition = false
        pumpFor(1.0)
        var cycles = 0
        for layout in NowPlayingLayout.allCases {
            m.look.nowPlayingLayout = layout.rawValue; m.look.showLyrics = layout != .chillax
            for mini in MiniLayout.allCases where mini.isWindow {
                for hide in [true, false] {
                    m.look.mini.layout = mini; m.look.mini.hideMainWindow = hide
                    pumpFor(0.3)
                    for key in ["top.mini", "cluster.mini"] {
                        guard let r = LayoutProbe.frames[key] else { expect(false, "\(layout.rawValue): the \(key) button is on screen"); continue }
                        if !win.isVisible { win.makeKeyAndOrderFront(nil); pumpFor(0.2) }
                        clickMiddle(win, r, height: size.height)                       // switch to the mini player
                        pumpFor(0.5)
                        expect(m.mini.isFloatingOpen, "\(layout.rawValue) → \(mini.rawValue), \(key): the mini player opened")
                        expect(win.isVisible == !hide, "\(layout.rawValue) → \(mini.rawValue), \(key): the Aureon window is \(hide ? "put away" : "left in place")")
                        if hide { m.mini.openApp() } else { clickMiddle(win, r, height: size.height) }   // and back: the expand button, or the button again
                        pumpFor(0.4)
                        expect(!m.mini.isFloatingOpen && win.isVisible, "\(layout.rawValue) → \(mini.rawValue), \(key): back in the Aureon window")
                        cycles += 1
                    }
                }
            }
        }
        expect(cycles == NowPlayingLayout.allCases.count * MiniLayout.allCases.filter(\.isWindow).count * 2 * 2, "every combination was switched: \(cycles)")
    }

    /// The Aureon window is put away (not closed) while the mini player is open; the app must not quit because it has no other window on screen.
    @MainActor func theAppStaysOpenWhileTheMiniPlayerHasTheScreen() {
        guard !NSScreen.screens.isEmpty else { return }
        expect(AppDelegate.quitsWhenTheLastWindowCloses(appWindowAppeared: true), "with the app's window closed, the app quits (as before)")
        expect(!AppDelegate.quitsWhenTheLastWindowCloses(appWindowAppeared: true, miniPlayerOpen: true), "but not while the mini player is open")
        expect(!AppDelegate.quitsWhenTheLastWindowCloses(appWindowAppeared: false), "and not before the app's window has appeared")
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let ud = UserDefaults.standard
        let savedOrigin = ud.object(forKey: "aureon.mini.origin"), savedHeight = ud.object(forKey: "aureon.mini.height")
        let main = NSWindow(contentRect: NSRect(x: 220, y: 240, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.orderFront(nil)
        m.mini.mainWindowProvider = { main }
        defer {
            m.mini.shutDown(); main.orderOut(nil); main.contentView = nil
            if let savedOrigin { ud.set(savedOrigin, forKey: "aureon.mini.origin") } else { ud.removeObject(forKey: "aureon.mini.origin") }
            if let savedHeight { ud.set(savedHeight, forKey: "aureon.mini.height") } else { ud.removeObject(forKey: "aureon.mini.height") }
        }
        m.look.mini.rememberPosition = false
        expect(!m.mini.keepsAppAlive, "nothing open: nothing to keep the app for")
        for layout in MiniLayout.allCases where layout.isWindow {
            for hide in [true, false] {
                m.look.mini.layout = layout; m.look.mini.hideMainWindow = hide
                m.mini.showFloating()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                expect(m.mini.keepsAppAlive, "\(layout.rawValue), main window \(hide ? "put away" : "kept"): the app is kept for the mini player")
                expect(!AppDelegate.quitsWhenTheLastWindowCloses(appWindowAppeared: true, miniPlayerOpen: m.mini.keepsAppAlive), "\(layout.rawValue): the app does not quit")
                m.mini.closeFloating()
                expect(!m.mini.keepsAppAlive && main.isVisible, "\(layout.rawValue): closed, the window is back and nothing keeps the app")
            }
        }
    }

    /// All four windows of the mini player are dragged from their body (the cover, the names, empty space), their controls still answer and never drag, the place
    /// is kept fully on a screen, written for the display, and read back by a new controller (the next launch), with the Aureon window put away or kept.
    @MainActor func theMiniPlayerDragsFromAnywhereAndRemembersItsPlace() {
        guard !NSScreen.screens.isEmpty else { return }
        let ud = UserDefaults.standard
        let saved = ud.object(forKey: MiniPlayerController.placesKey)
        let main = NSWindow(contentRect: NSRect(x: 220, y: 240, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.orderFront(nil)
        var models: [PlayerModel] = []
        defer {
            for m in models { m.mini.shutDown() }
            main.orderOut(nil); main.contentView = nil
            if let saved { ud.set(saved, forKey: MiniPlayerController.placesKey) } else { ud.removeObject(forKey: MiniPlayerController.placesKey) }
        }
        // points in the window (origin at the bottom left): on the cover, on the names, in empty space; and one on a control that must not drag
        let spots: [MiniLayout: (body: [NSPoint], control: NSPoint)] = [
            .bar: ([NSPoint(x: 48, y: 48), NSPoint(x: 200, y: 60), NSPoint(x: 300, y: 30)], NSPoint(x: 469, y: 77)),
            .strip: ([NSPoint(x: 24, y: 24), NSPoint(x: 90, y: 24), NSPoint(x: 330, y: 24)], NSPoint(x: 340, y: 24)),
            .card: ([NSPoint(x: 190, y: 400), NSPoint(x: 100, y: 190), NSPoint(x: 190, y: 120)], NSPoint(x: 337, y: 595)),
            .cardLyrics: ([NSPoint(x: 100, y: 590), NSPoint(x: 130, y: 400), NSPoint(x: 130, y: 250)], NSPoint(x: 205, y: 594)),
        ]
        for hide in [true, false] {
            for layout in MiniLayout.allCases where layout.isWindow {
                guard let spot = spots[layout] else { continue }
                let m = PlayerModel(); pulseKeepAlive.append(m); models.append(m)
                m.mini.persistsInTests = true; m.mini.mainWindowProvider = { main }
                m.look.mini.layout = layout; m.look.mini.rememberPosition = true; m.look.mini.hideMainWindow = hide
                ud.removeObject(forKey: MiniPlayerController.placesKey)
                m.mini.showFloating()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                guard let win = m.mini.floatingWindow else { expect(false, "\(layout.rawValue): there is a window"); continue }
                let area = (win.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                win.setFrameOrigin(NSPoint(x: area.midX - win.frame.width / 2, y: area.midY - win.frame.height / 2))        // mid-screen, so a drag has room
                expect(main.isVisible == !hide, "\(layout.rawValue): the Aureon window is \(hide ? "put away" : "kept alongside")")
                func send(_ type: NSEvent.EventType, _ p: NSPoint) {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { win.sendEvent(e) }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                for (i, p) in spot.body.enumerated() {
                    let before = win.frame.origin
                    send(.leftMouseDown, p)
                    send(.leftMouseDragged, NSPoint(x: p.x + 30, y: p.y - 12))
                    send(.leftMouseDragged, NSPoint(x: p.x + 8, y: p.y - 4))
                    send(.leftMouseUp, NSPoint(x: p.x + 8, y: p.y - 4))
                    let d = CGSize(width: win.frame.origin.x - before.x, height: win.frame.origin.y - before.y)
                    expect(abs(d.width - 38) < 2 && abs(d.height + 16) < 2, "\(layout.rawValue), spot \(i): a drag from here moves the window by (38, −16): \(d)")
                }
                // a control answers its click and the window stays where it is
                let at = win.frame.origin
                send(.leftMouseDown, spot.control); send(.leftMouseUp, spot.control)
                expect(win.frame.origin == at, "\(layout.rawValue): a click on a control does not move the window")
                // dropped half off the screen: the whole window is pulled back
                let screen = (win.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                win.setFrameOrigin(NSPoint(x: screen.maxX - 40, y: screen.minY + 5))
                send(.leftMouseDown, spot.body[0]); send(.leftMouseDragged, NSPoint(x: spot.body[0].x + 4, y: spot.body[0].y)); send(.leftMouseUp, NSPoint(x: spot.body[0].x + 4, y: spot.body[0].y))
                expect(screen.insetBy(dx: -1, dy: -1).contains(win.frame), "\(layout.rawValue): a window left half off the screen is pulled fully back: \(win.frame) in \(screen)")
                // moved, closed, and read back by a new controller (the next launch): same place
                let placed = win.frame
                m.mini.closeFloating()
                expect(main.isVisible, "\(layout.rawValue): closing brings the Aureon window back")
                let next = PlayerModel(); pulseKeepAlive.append(next); models.append(next)
                next.mini.persistsInTests = true; next.mini.mainWindowProvider = { main }
                next.look.mini.layout = layout; next.look.mini.rememberPosition = true; next.look.mini.hideMainWindow = hide
                next.mini.showFloating()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                if let again = next.mini.floatingWindow { expect(abs(again.frame.origin.x - placed.origin.x) < 1 && abs(again.frame.maxY - placed.maxY) < 1, "\(layout.rawValue): the next launch opens in the same place: \(again.frame) was \(placed)") }
                else { expect(false, "\(layout.rawValue): it opens again") }
                next.mini.closeFloating()
                main.orderFront(nil)
            }
        }
        // the rule itself: partly off a screen is pulled back; wholly on a screen is left alone
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        expect(MiniSettings.onScreen(origin: CGPoint(x: 1400, y: 100), size: CGSize(width: 520, height: 96), screens: [screen]) == CGPoint(x: 920, y: 100), "partly off the right edge: pulled back in")
        expect(MiniSettings.onScreen(origin: CGPoint(x: 100, y: 100), size: CGSize(width: 520, height: 96), screens: [screen]) == nil, "wholly on: left alone")
    }

    /// Changing a setting leaves the settings page where it is: scrolled to the same place, with the top of its content (and so everything in it) at the same height at
    /// every moment after the change, for pages that rebuild the interface (colours, type, density) and pages that do not.
    @MainActor func settingsPagesStayWhereTheyAreWhenAnythingChanges() {
        guard !NSScreen.screens.isEmpty else { return }
        setenv("AUREON_NULLSINK", "1", 1)
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let stage = StageModel(); pulseKeepAlive.append(stage)
        LayoutProbe.enabled = true
        defer { LayoutProbe.enabled = false; ScrollMemory.shared.all = [:] }
        let size = CGSize(width: 1100, height: 640)
        m.appearance = .dark
        m.pageTransitions = .none                                    // the page is there at once (a fade needs a window that is on a screen)
        let pages: [(SettingsSection, [(String, () -> Void)])] = [
            (.appearance, [
                ("pure black", { m.look.pureBlack.toggle() }), ("pure black off", { m.look.pureBlack = false }),
                ("mode light", { m.appearance = .light }), ("mode auto", { m.appearance = .system }), ("mode dark", { m.appearance = .dark }),
                ("family", { m.choose(family: "forest") }), ("family again", { m.choose(family: "plum") }),
                ("density", { m.look.density = .comfortable }), ("density back", { m.look.density = .compact }),
                ("font weight", { m.look.weight = .medium }), ("font back", { m.look.weight = .regular }),
                ("accent", { m.look.accentHex = "3FA7FF" }), ("accent off", { m.look.accentHex = nil }),
                ("brightness", { m.appearance = .light; m.look.lightBrightness = 0.8 }), ("brightness back", { m.look.lightBrightness = 0.35; m.appearance = .dark }),
                ("backdrop", { m.backdrop = .album }), ("backdrop flat", { m.backdrop = .off }),
                ("starlight", { m.look.starlight.twinkle.toggle() }),
            ]),
            (.nowPlaying, [
                ("lyrics", { m.look.showLyrics.toggle() }), ("lyric size", { m.look.lyricSize = .huge }), ("lyric size back", { m.look.lyricSize = .large }),
                ("playlist button", { m.look.showPlaylistButton.toggle() }), ("credits", { m.look.showCredits.toggle() }), ("tags", { m.look.showSignalTags.toggle() }),
                ("seek", { m.look.seekChoice = .line }), ("seek back", { m.look.seekChoice = .layout }), ("layout", { m.look.nowPlayingLayout = "lumen" }), ("layout back", { m.look.nowPlayingLayout = "stage" }),
                ("rest controls", { m.look.restControls.toggle() }),
            ]),
            (.miniPlayer, [
                ("form", { m.look.mini.layout = .card }), ("form strip", { m.look.mini.layout = .strip }), ("background", { m.look.mini.background = .blur }),
                ("opacity", { m.look.mini.opacity = 0.7 }), ("pin", { m.look.mini.alwaysOnTop.toggle() }), ("hide main", { m.look.mini.hideMainWindow.toggle() }),
            ]),
            (.startup, [
                ("resume", { m.look.memory.resume = .playing }), ("resume ask", { m.look.memory.resume = .ask }), ("remember queue", { m.look.memory.rememberQueue.toggle() }),
            ]),
        ]
        var flips = 0
        for (section, changes) in pages {
            ScrollMemory.shared.set("\(Tab.settings.rawValue)||\(section.rawValue)", 220)
            m.go(.settings(section))
            // the page is chosen first and then shown: a window is only asked to redraw when it is on a screen, and it is shown for the few seconds this takes
            let probe = LayoutProbe.begin()
            let host = NSHostingView(rootView: AnyView(ContentView(stage: stage).environmentObject(m).environment(\.probeToken, probe).frame(width: size.width, height: size.height).preferredColorScheme(.dark)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = KeyableWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            let place = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            win.contentView = host; win.setFrameOrigin(NSPoint(x: place.minX + 20, y: place.minY + 20)); win.orderFrontRegardless()
            defer { win.orderOut(nil); win.contentView = nil }
            func pumpFor(_ secs: Double) {
                let end = Date().addingTimeInterval(secs)
                while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
            }
            pumpFor(1.2)
            guard let base = LayoutProbe.frames["page.content"]?.minY else { expect(false, "\(section.rawValue): the page is on screen"); continue }
            for (name, change) in changes {
                change()
                var worst = 0.0
                for _ in 0..<16 {
                    pumpFor(0.06)
                    if let y = LayoutProbe.frames["page.content"]?.minY { worst = max(worst, abs(y - base)) } else { worst = 999 }
                }
                expect(worst < 2.5, "\(section.rawValue), \(name): the page does not move (at most \(String(format: "%.1f", worst)) pt)")
                flips += 1
            }
        }
        expect(flips > 30, "every control was changed: \(flips)")
    }

    /// Every popover that can be opened from the top bar and the player bar is wholly inside the window, at the smallest window, a usual one and a large one.
    @MainActor func popoversNeverLeaveTheWindow() {
        guard !NSScreen.screens.isEmpty else { return }
        setenv("AUREON_NULLSINK", "1", 1)
        let dir = tempDir("popframe")
        let song = dir.appendingPathComponent("Popover Frame.wav")
        _ = writeWAV(song, rate: 8000, bits: 16, frames: 8000 * 30) { f, _ in Int(2500 * sin(Double(f) * 0.12)) }
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let stage = StageModel(); pulseKeepAlive.append(stage)
        LayoutProbe.enabled = true
        defer { m.clear(); LayoutProbe.enabled = false }
        m.add(urls: [song], play: false)
        for it in m.items { m.play(it.id) }
        m.tab = .home
        var opened = 0
        for size in [CGSize(width: 860, height: 540), CGSize(width: 1100, height: 700), CGSize(width: 1700, height: 1000)] {
            let probe = LayoutProbe.begin()
            let host = NSHostingView(rootView: AnyView(ContentView(stage: stage).environmentObject(m).environment(\.probeToken, probe).frame(width: size.width, height: size.height).preferredColorScheme(.dark)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = KeyableWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host; win.setFrameOrigin(NSPoint(x: -9000, y: -9000)); win.makeKeyAndOrderFront(nil)
            func settle(_ secs: Double) {
                let end = Date().addingTimeInterval(secs)
                while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
            }
            settle(1.2)
            let window = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            func check(_ what: String) {
                settle(0.4)
                let f = m.popovers.shownFrame
                expect(m.popovers.isOpen && f.width > 50 && window.contains(f), "\(Int(size.width))×\(Int(size.height)): \(what) opens wholly inside the window: \(f)")
                opened += 1
                m.popovers.dismiss(); m.quickPanel = nil
                settle(0.3)
                expect(!m.popovers.isOpen, "\(what) closes")
            }
            if let r = LayoutProbe.frames["output.rail"] { clickMiddle(win, r, height: size.height); check("the output list of the top bar") } else { expect(false, "the top bar's output chip is on screen") }
            m.quickPanel = .bar; check("the output list of the player bar")
            if let r = LayoutProbe.frames["shuffle"] { clickMiddle(win, r, height: size.height); check("the shuffle choices") } else { expect(false, "the shuffle button is on screen") }
            win.orderOut(nil); win.contentView = nil
            settle(0.1)
        }
        expect(opened == 9, "every popover was opened: \(opened)")
    }

    /// Every layout of Now Playing, with the lyrics on and off, at the smallest, the usual and a large window: the dock (transport, seek, queue, mini player) is
    /// whole and inside the window, and the controls, the tag row and the lyrics' own controls never overlap.
    @MainActor func everyLayoutKeepsItsControlsApart() {
        guard !NSScreen.screens.isEmpty else { return }
        setenv("AUREON_NULLSINK", "1", 1)
        let dir = tempDir("npfit")
        let song = dir.appendingPathComponent("Layout Check.wav")
        _ = writeWAV(song, rate: 8000, bits: 16, frames: 8000 * 40) { f, _ in Int(2500 * sin(Double(f) * 0.12)) }
        let lrc = (0..<12).map { String(format: "[00:%02d.00]A made-up line number %d for the layout", $0 * 3 + 1, $0) }.joined(separator: "\n")
        try? Data(("[ti:Layout Check]\n" + lrc + "\n").utf8).write(to: dir.appendingPathComponent("Layout Check.lrc"))
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let stage = StageModel(); pulseKeepAlive.append(stage)
        let saved = LyricsService.shared.isOnlineAllowed
        LyricsService.shared.isOnlineAllowed = { false }
        defer { m.clear(); LyricsService.shared.isOnlineAllowed = saved }
        m.add(urls: [song], play: false)
        for it in m.items { m.play(it.id) }
        stage.open(m, reduceMotion: true)
        LayoutProbe.enabled = true
        defer { LayoutProbe.enabled = false }
        let sizes = [CGSize(width: 860, height: 540), CGSize(width: 1080, height: 700), CGSize(width: 1700, height: 1050)]
        var checked = 0
        for density in [UIDensity.compact, .comfortable] {
            m.look.density = density
            for layout in NowPlayingLayout.allCases where ProcessInfo.processInfo.environment["AUREON_NP_ONLY"].map({ $0 == layout.rawValue }) ?? true {
                for lyrics in [true, false] {
                    for size in sizes {
                        m.look.nowPlayingLayout = layout.rawValue; m.look.showLyrics = lyrics
                        let probe = LayoutProbe.begin()
                        let host = NSHostingView(rootView: AnyView(ContentView(stage: stage).environmentObject(m).environment(\.probeToken, probe).frame(width: size.width, height: size.height).preferredColorScheme(.dark)))
                        host.frame = NSRect(origin: .zero, size: size)
                        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                        win.contentView = host; win.setFrameOrigin(NSPoint(x: -9000, y: -9000)); win.orderFront(nil)
                        let end = Date().addingTimeInterval(lyrics ? 2.0 : 0.8)
                        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        let name = "\(layout.rawValue) lyrics \(lyrics ? "on" : "off") \(Int(size.width))×\(Int(size.height)) \(density.rawValue)"
                        let window = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
                        let f = LayoutProbe.frames
                        // the dock is whole and inside the window: seek bar, transport, and the output / queue / mini player / volume cluster
                        for part in ["dock", "seek", "transport", "cluster"] {
                            guard let r = f[part] else { expect(false, "\(name): \(part) is on screen"); continue }
                            expect(window.contains(r), "\(name): \(part) is inside the window: \(r)")
                        }
                        // nothing in the dock or around the title and lyrics touches anything else
                        let parts = ["seek", "transport", "cluster", "tags", "actions", "lyrics"].compactMap { n in f[n].map { (n, $0) } }
                        for i in parts.indices { for j in parts.indices where j > i {
                            let a = parts[i].1.insetBy(dx: 1, dy: 1), b = parts[j].1.insetBy(dx: 1, dy: 1)
                            if a.intersects(b) { print("frames:", f.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
                            expect(!a.intersects(b), "\(name): \(parts[i].0) and \(parts[j].0) overlap: \(parts[i].1) \(parts[j].1)")
                        } }
                        // the words end where the dock begins, and are inside the window
                        if let dock = f["dock"], let words = f["lyrics"] { expect(words.maxY <= dock.minY + 1 && window.contains(words), "\(name): the lyrics reach into the dock or out of the window: \(words) \(dock)") }
                        checked += 1
                        win.orderOut(nil); win.contentView = nil
                        RunLoop.current.run(until: Date().addingTimeInterval(0.15))     // let the old tree finish before the next one is measured
                    }
                }
            }
        }
        expect(checked == 2 * NowPlayingLayout.allCases.count * 2 * 3 || ProcessInfo.processInfo.environment["AUREON_NP_ONLY"] != nil, "every combination was looked at: \(checked)")
    }
}

extension PulseTests {
    /// Picking a song in the queue only jumps to it: with Shuffle off nothing is reordered; with it on, only what is still to come is shuffled.
    @MainActor func pickingFromTheQueueDoesNotReorderIt() {
        setenv("AUREON_NULLSINK", "1", 1)
        let m = PlayerModel(); pulseKeepAlive.append(m)
        defer { m.clear() }
        let dir = tempDir("pickq")
        var urls: [URL] = []
        for i in 0..<8 { let u = dir.appendingPathComponent("Pick \(i).wav"); _ = writeWAV(u, rate: 8000, bits: 16, frames: 8000 * 30) { f, _ in Int(2000 * sin(Double(f) * 0.1)) }; urls.append(u) }
        m.shuffle = .off
        m.add(urls: urls, play: false)
        let ids = m.items.map(\.id)
        expect(ids.count == 8 && m.shuffle == .off, "eight songs queued, Shuffle off")
        m.play(ids[0])
        func settle() { let end = Date().addingTimeInterval(1.5); while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } }
        settle()
        expect(m.player.queue.map(\.id) == ids, "the engine's queue is in the order it was added")
        // choose a song further down: a jump, nothing else
        m.play(ids[5]); settle()
        expect(m.items.map(\.id) == ids && m.player.queue.map(\.id) == ids, "Shuffle off: choosing the sixth song leaves the queue exactly as it was")
        expect(m.status.trackID == ids[5], "and it is the one playing: \(String(describing: m.status.trackID))")
        m.play(ids[2]); settle()
        expect(m.items.map(\.id) == ids && m.status.trackID == ids[2], "going back is a jump too: the songs after it keep their order")
        // not playing at all (stopped, or just restored): choosing a song starts there, and the order is still the same
        m.player.stop(); settle()
        m.play(ids[6]); settle()
        expect(m.items.map(\.id) == ids && m.player.queue.map(\.id) == ids && m.status.trackID == ids[6], "Shuffle off, nothing playing: choosing a song starts it and leaves the queue alone")
        // Shuffle on: only what is still to come is shuffled; what was played stays
        m.play(ids[3]); settle()
        m.shuffle = .normal; settle()
        let order = m.player.queue.map(\.id)
        expect(Array(order[0...3]) == Array(ids[0...3]) && Set(order) == Set(ids), "Shuffle on: the songs up to the current one keep their places, the rest is a permutation of the same songs")
        // choosing a song while shuffled still only jumps
        let before = m.player.queue.map(\.id)
        let pick = before[6]
        m.play(pick); settle()
        expect(m.player.queue.map(\.id) == before && m.status.trackID == pick, "choosing from a shuffled queue does not shuffle it again")
        // and Shuffle off puts the original order back
        m.shuffle = .off; settle()
        expect(m.player.queue.map(\.id) == ids && m.items.map(\.id) == m.player.queue.map(\.id), "Shuffle off restores the order the songs were added in")
    }
}

extension PulseTests {
    /// The mini player is dragged by its body (a real window, real mouse events), its controls still answer, and it swaps places with the Aureon window.
    @MainActor func theMiniPlayerDragsAndSwapsWithTheMainWindow() {
        guard !NSScreen.screens.isEmpty else { return }
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let ud = UserDefaults.standard
        let savedOrigin = ud.object(forKey: "aureon.mini.origin"), savedHeight = ud.object(forKey: "aureon.mini.height")
        let main = NSWindow(contentRect: NSRect(x: 220, y: 240, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.orderFront(nil)
        defer {
            m.mini.shutDown(); main.orderOut(nil); main.contentView = nil
            if let savedOrigin { ud.set(savedOrigin, forKey: "aureon.mini.origin") } else { ud.removeObject(forKey: "aureon.mini.origin") }
            if let savedHeight { ud.set(savedHeight, forKey: "aureon.mini.height") } else { ud.removeObject(forKey: "aureon.mini.height") }
        }
        let mainFrame = main.frame
        m.mini.mainWindowProvider = { main }
        m.look.mini.layout = .bar; m.look.mini.rememberPosition = false; m.look.mini.hideMainWindow = true
        m.mini.showFloating()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        expect(m.mini.isFloatingOpen && !main.isVisible && m.mini.mainIsHidden, "opening the mini player puts the Aureon window away")
        guard let win = m.mini.floatingWindow else { expect(false, "there is a window"); return }
        let area = (win.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        win.setFrameOrigin(NSPoint(x: area.midX - win.frame.width / 2, y: area.midY - win.frame.height / 2))            // mid-screen, so the drag has room
        func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func send(_ type: NSEvent.EventType, _ p: NSPoint) { if let e = event(type, p) { win.sendEvent(e) }; RunLoop.current.run(until: Date().addingTimeInterval(0.06)) }
        // a drag that begins on the body (the bar's middle, away from every control)
        let before = win.frame.origin
        send(.leftMouseDown, NSPoint(x: 300, y: 40))
        send(.leftMouseDragged, NSPoint(x: 340, y: 25))             // 40 right, 15 down: the window follows…
        send(.leftMouseDragged, NSPoint(x: 310, y: 35))             // …so the pointer is back near the grab point; 10 more right and 5 down
        send(.leftMouseUp, NSPoint(x: 310, y: 35))
        let moved = win.frame.origin
        expect(abs((moved.x - before.x) - 50) < 1.5 && abs((moved.y - before.y) + 20) < 1.5, "dragging the body moves the window: from \(before) to \(moved)")
        // a control still answers a click and does not drag: the pin button at the top right
        let pinned = m.look.mini.alwaysOnTop, at = win.frame.origin
        send(.leftMouseDown, NSPoint(x: 469, y: 77)); send(.leftMouseUp, NSPoint(x: 469, y: 77))
        expect(m.look.mini.alwaysOnTop != pinned && win.frame.origin == at, "the pin button answers the click and the window stays")
        // let go far outside every screen: it comes back
        send(.leftMouseDown, NSPoint(x: 300, y: 40))
        send(.leftMouseDragged, NSPoint(x: 300 + 9000, y: 40 - 6000))
        send(.leftMouseUp, NSPoint(x: 300 + 9000, y: 40 - 6000))
        let seen = NSScreen.screens.map(\.visibleFrame).contains { $0.intersects(win.frame) }
        expect(seen, "a window dropped far off every screen is brought back: \(win.frame)")
        // closing it brings the Aureon window back where it was
        m.mini.closeFloating()
        expect(!m.mini.isFloatingOpen && main.isVisible && main.frame == mainFrame && !m.mini.mainIsHidden, "closing the mini player brings the Aureon window back exactly where it was")
        // the expand button and the Dock icon do the same
        m.mini.showFloating()
        expect(!main.isVisible, "hidden again")
        m.mini.openApp()
        expect(!m.mini.isFloatingOpen && main.isVisible && main.frame == mainFrame, "Open Aureon: the app comes back and the mini player goes")
        m.mini.showFloating()
        m.mini.appReopened()
        expect(!m.mini.isFloatingOpen && main.isVisible, "the Dock icon with only the mini player showing brings the app back")
        // the old way, both on screen, is a setting
        m.look.mini.hideMainWindow = false
        m.mini.showFloating()
        expect(m.mini.isFloatingOpen && main.isVisible && !m.mini.mainIsHidden, "with the setting off both stay")
        m.mini.closeFloating()
        expect(main.isVisible && main.frame == mainFrame, "and closing leaves the app alone")
        expect(MiniSettings().hideMainWindow, "the default is to put the app away")
    }
}

extension PulseTests {
    private func record(_ n: Int = 5, current: Int? = 2, position: Double = 72, duration: Double = 278) -> SessionRecord {
        SessionRecord(queue: (0..<n).map { "/m/song\($0).flac" }, current: current, position: position, duration: duration, tab: Tab.albums.rawValue, settingsSection: SettingsSection.appearance.rawValue,
                      selectedID: "album-1", deviceUID: "dac-uid", savedAt: 1, scroll: ["Albums||": 640])
    }

    func theLastSessionIsPlannedFromTheSettings() {
        let all: (String) -> Bool = { _ in true }
        var mem = MemorySettings()
        expect(mem.resume == .paused && mem.rememberQueue && mem.rememberPage && mem.rememberWindow && mem.rememberOutput, "defaults: paused, everything remembered")
        let paused = SessionPlan.restore(record(), memory: mem, exists: all)
        expect(paused?.paths.count == 5 && paused?.current == 2 && paused?.position == 72 && paused?.autoplay == false && paused?.offer == false && paused?.tab == .albums && paused?.selectedID == "album-1" && paused?.deviceUID == "dac-uid", "paused: the song waits where it was left")
        expect(paused?.scroll["Albums||"] == 640 && paused?.section == .appearance, "the page and how far it was scrolled")
        mem.resume = .playing
        expect(SessionPlan.restore(record(), memory: mem, exists: all)?.autoplay == true, "playing: it carries on")
        mem.resume = .ask
        let ask = SessionPlan.restore(record(), memory: mem, exists: all)
        expect(ask?.offer == true && ask?.autoplay == false, "ask: an offer, nothing plays")
        mem.resume = .fresh
        let fresh = SessionPlan.restore(record(), memory: mem, exists: all)
        expect(fresh?.paths.isEmpty == true && fresh?.current == nil && fresh?.autoplay == false && fresh?.offer == false && fresh?.tab == .albums, "fresh: no queue, but the page is still remembered")
        mem.resume = .paused; mem.rememberQueue = false; mem.rememberPage = false; mem.rememberOutput = false
        let none = SessionPlan.restore(record(), memory: mem, exists: all)
        expect(none?.paths.isEmpty == true && none?.tab == nil && none?.selectedID == nil && none?.deviceUID == nil && none?.scroll.isEmpty == true, "each thing can be switched off")
        expect(SessionPlan.restore(nil, memory: MemorySettings(), exists: all) == nil, "nothing saved, nothing to do")
        // songs whose files are gone are left out, and the current one follows
        let gone = SessionPlan.restore(record(), memory: MemorySettings(), exists: { $0 != "/m/song0.flac" && $0 != "/m/song3.flac" })
        expect(gone?.paths == ["/m/song1.flac", "/m/song2.flac", "/m/song4.flac"] && gone?.current == 1 && gone?.position == 72, "a missing file drops out and the index follows: \(String(describing: gone?.current))")
        let lost = SessionPlan.restore(record(), memory: MemorySettings(), exists: { $0 != "/m/song2.flac" })
        expect(lost?.current == 0 && lost?.position == 0, "the current song is gone: the first one waits from its start")
        expect(SessionPlan.restore(record(), memory: MemorySettings(), exists: { _ in false })?.paths.isEmpty == true, "no file left: no queue")
        let end = SessionPlan.restore(record(position: 277.5), memory: MemorySettings(), exists: all)
        expect(end?.position == 0, "a song that was at its very end starts again")
        expect(SessionPlan.restore(record(), memory: MemorySettings(), exists: all)?.duration == 278, "the length comes with it")
    }

    func theSessionRecordIsWrittenSmallAndReadBack() {
        let items = (0..<2000).map { (path: "/m/\($0).flac", isStream: $0 % 100 == 7) }
        let r = SessionRecord.make(items: items, currentID: 1000, position: 12.5, duration: 200, tab: .songs, section: .general, selectedID: nil, deviceUID: nil, now: 5)
        expect(r.queue.count == SessionRecord.queueLimit && !r.queue.contains { $0.hasSuffix("/7.flac") || $0.hasSuffix("/107.flac") }, "radio is not written, the queue is cut to the limit around the song")
        expect(r.current.map { r.queue[$0] } == "/m/1000.flac", "and the current song is still found in it: \(String(describing: r.current))")
        let first = SessionRecord.make(items: items, currentID: 0, position: 0, duration: 0, tab: .home, section: .general, selectedID: nil, deviceUID: nil, now: 5)
        expect(first.queue.first == "/m/0.flac" && first.current == 0, "from the start of the queue")
        let last = SessionRecord.make(items: items, currentID: 1999, position: 0, duration: 0, tab: .home, section: .general, selectedID: nil, deviceUID: nil, now: 5)
        expect(last.queue.last == "/m/1999.flac" && last.current.map { last.queue[$0] } == "/m/1999.flac", "from the end of it")
        let radio = SessionRecord.make(items: [("http://radio/stream", true)], currentID: 0, position: 3, duration: 0, tab: .radio, section: .general, selectedID: nil, deviceUID: nil, now: 5)
        expect(radio.queue.isEmpty && radio.current == nil, "a radio station alone is not a session to resume")
        let bad = SessionRecord.make(items: [("/m/a.flac", false)], currentID: 0, position: .nan, duration: .infinity, tab: .home, section: .general, selectedID: nil, deviceUID: nil, now: 1)
        expect(bad.position == 0 && bad.duration == 0, "numbers that are not numbers are written as zero")
        let suite = UserDefaults(suiteName: "aureon.test.session.\(UUID().uuidString)")!
        let rec = record(); rec.save(suite)
        expect(SessionRecord.load(suite) == rec, "the record comes back whole")
        suite.set(Data("nonsense".utf8), forKey: SessionRecord.storageKey)
        expect(SessionRecord.load(suite) == nil, "an unreadable one is nothing")
        rec.save(suite); SessionRecord.forget(suite)
        expect(SessionRecord.load(suite) == nil, "forgetting forgets")
        var mem = MemorySettings(); mem.resume = .ask; mem.rememberWindow = false
        var look = LookSettings(); look.memory = mem
        let s2 = UserDefaults(suiteName: "aureon.test.memlook.\(UUID().uuidString)")!; look.save(s2)
        expect(LookSettings.load(s2, environment: [:]).memory == mem, "the settings come back")
        s2.set(Data(#"{"memory":{"resume":"playing"}}"#.utf8), forKey: LookSettings.storageKey)
        expect(LookSettings.load(s2, environment: [:]).memory.resume == .playing && LookSettings.load(s2, environment: [:]).memory.rememberQueue, "an older record reads with defaults")
    }

    func theWindowComesBackToItsDisplay() {
        var w = WindowMemory()
        let a = CGRect(x: 0, y: 0, width: 1440, height: 875), b = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let screens = ["A": a, "B": b], min = CGSize(width: 860, height: 540)
        expect(w.frame(display: "A", visible: screens, minimum: min) == nil, "nothing remembered yet")
        w.record(CGRect(x: 100, y: 80, width: 1100, height: 720), display: "A")
        w.record(CGRect(x: 1700, y: 120, width: 1500, height: 900), display: "B")
        expect(w.frame(display: "A", visible: screens, minimum: min) == CGRect(x: 100, y: 80, width: 1100, height: 720), "each display has its own place")
        expect(w.frame(display: "B", visible: screens, minimum: min) == CGRect(x: 1700, y: 120, width: 1500, height: 900), "…and size")
        expect(w.frame(display: "C", visible: screens, minimum: min) == CGRect(x: 1700, y: 120, width: 1500, height: 900), "an unknown display: the one used last")
        expect(w.frame(display: nil, visible: screens, minimum: min)?.width == 1500, "no display given: the last one")
        // the second display is gone: the window comes back onto the first, no larger than it
        let back = w.frame(display: "B", visible: ["A": a], minimum: min)
        expect(back != nil && a.contains(back!), "the display is gone: it comes back onto a screen that is there: \(String(describing: back))")
        w.record(CGRect(x: 0, y: 0, width: 5000, height: 4000), display: "A")
        let big = w.frame(display: "A", visible: screens, minimum: min)
        expect(big != nil && big!.width <= a.width && big!.height <= a.height, "larger than its screen: brought down to it")
        w.record(CGRect(x: 10, y: 10, width: 300, height: 200), display: "A")
        expect(w.frame(display: "A", visible: screens, minimum: min)?.size == min, "never smaller than the window may be")
        let suite = UserDefaults(suiteName: "aureon.test.windows.\(UUID().uuidString)")!
        w.save(suite)
        expect(WindowMemory.load(suite) == w, "it is written and read back")
        WindowMemory.forget(suite)
        expect(WindowMemory.load(suite) == WindowMemory(), "and forgotten")
    }

    @MainActor func theQueueComesBackReadyToPlay() {
        let m = PlayerModel(); pulseKeepAlive.append(m)
        let dir = tempDir("resume")
        var files: [String] = []
        for i in 0..<3 { let u = dir.appendingPathComponent("Song \(i).wav"); writeWAV(u, rate: 8000, bits: 16, frames: 8000) { f, _ in Int(3000 * sin(Double(f) * 0.2)) }; files.append(u.path) }
        let plan = SessionRestore(paths: files, current: 1, position: 40, duration: 100, autoplay: false, offer: true, tab: .albums, section: .appearance, selectedID: nil, deviceUID: nil, scroll: ["Songs||": 300])
        m.apply(plan)
        expect(m.items.count == 3 && m.items.map(\.title) == ["Song 0", "Song 1", "Song 2"], "the queue is back, in order: \(m.items.map(\.title))")
        expect(m.tab == .albums && m.settingsSection == .appearance && ScrollMemory.shared.offset("Songs||") == 300, "the page, the settings page and the scroll are back")
        expect(m.pendingResume?.id == m.items[1].id && m.pendingResume?.position == 40 && m.focusItem?.id == m.items[1].id, "the song is in focus, ready at 40 s")
        expect(m.resumeOffer != nil && !m.isActive, "the offer is shown and nothing plays")
        expect(abs(m.progress.position - 40) < 0.001 && m.progress.duration == 100, "the bar shows where it stopped")
        let rec = m.currentSessionRecord()
        expect(rec.queue == files && rec.current == 1 && rec.position == 40 && rec.duration == 100 && rec.tab == Tab.albums.rawValue, "and what is saved next is the same: \(rec.current ?? -1) \(rec.position)")
        m.declineResumeOffer()
        expect(m.items.isEmpty && m.pendingResume == nil && m.resumeOffer == nil, "Start fresh puts the queue away")
        ScrollMemory.shared.all = [:]
    }

    func scrollMemoryKeepsWhereEachPageWas() {
        let sm = ScrollMemory()
        sm.set("Albums||", 640); sm.set("Songs||", 0.5); sm.set("Home||", 120)
        expect(sm.offset("Albums||") == 640 && sm.offset("Songs||") == nil && sm.offset("Home||") == 120 && sm.offset("nope") == nil, "pages at their top are not kept")
        sm.set("Albums||", 0)
        expect(sm.offset("Albums||") == nil, "back at the top: forgotten")
        var many: [String: Double] = [:]
        for i in 0..<100 { many["page\(i)"] = Double(i + 10) }
        sm.all = many
        expect(sm.all.count == ScrollMemory.limit, "no more pages are kept than the limit")
    }
}

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
            ("pulse.miniWindow", { MainActor.assumeIsolated { t.theFloatingWindowFollowsTheSettings() } }), ("pulse.layoutFit", { MainActor.assumeIsolated { t.everyLayoutKeepsItsControlsApart() } }), ("pulse.playedLog", { MainActor.assumeIsolated { t.playedHistoryKeepsTheOrder() } }), ("pulse.playHistory", { MainActor.assumeIsolated { t.playingFillsTheHistory() } }), ("pulse.themeMigration", { MainActor.assumeIsolated { t.savedThemesAreCarriedOver() } }), ("pulse.themeModes", { MainActor.assumeIsolated { t.modelShowsFamilyInEveryMode() } }), ("pulse.miniDragAnywhere", { MainActor.assumeIsolated { t.theMiniPlayerDragsFromAnywhereAndRemembersItsPlace() } }), ("pulse.settingsStay", { MainActor.assumeIsolated { t.settingsPagesStayWhereTheyAreWhenAnythingChanges() } }), ("pulse.miniKeepsApp", { MainActor.assumeIsolated { t.theAppStaysOpenWhileTheMiniPlayerHasTheScreen() } }), ("pulse.miniSwitch", { MainActor.assumeIsolated { t.switchingToTheMiniPlayerNeverCrashes() } }), ("pulse.popoverFrames", { MainActor.assumeIsolated { t.popoversNeverLeaveTheWindow() } }), ("pulse.popovers", { MainActor.assumeIsolated { t.popoversStayOpenOnNowPlaying() } }), ("pulse.upcomingArt", { MainActor.assumeIsolated { t.upcomingArtworkIsPrefetched() } }), ("pulse.queuePick", { MainActor.assumeIsolated { t.pickingFromTheQueueDoesNotReorderIt() } }), ("pulse.miniDrag", { MainActor.assumeIsolated { t.theMiniPlayerDragsAndSwapsWithTheMainWindow() } }), ("pulse.miniDraw", { MainActor.assumeIsolated { t.theMiniLayoutsDrawWithoutTrouble() } }), ("pulse.session", t.theLastSessionIsPlannedFromTheSettings), ("pulse.sessionRecord", t.theSessionRecordIsWrittenSmallAndReadBack), ("pulse.windows", t.theWindowComesBackToItsDisplay),
            ("pulse.resume", { MainActor.assumeIsolated { t.theQueueComesBackReadyToPlay() } }), ("pulse.scroll", t.scrollMemoryKeepsWhereEachPageWas), ("pulse.layouts", t.theLayoutsAreChosenAndRemembered), ("pulse.credits", t.creditsAndTheSignalPathReadWell), ("pulse.queue", t.theQueueSeenFromNowPlaying)]
}

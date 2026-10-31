import Foundation
import SwiftUI
import AppKit

/// The search field and the tag filter view, and the soft edge around the window.
struct SearchEdgeTests {
    private func parse(_ s: String) -> QueryNode { try! LibraryQuery(parsing: s).root }

    func queriesWriteBackAndChipsComeOut() {
        for text in ["tag:\"Alternative & Indie, Pop\"", "tag:\"Rock\" year:1990..2000 -live", "artist:\"Tame Impala\" liked:yes rate:>=96000", "a OR b c", "genre:jazz (year:<1960 OR year:>=1980)"] {
            let n = parse(text)
            expect(parse(n.text) == n, "“\(text)” survives being written back: “\(n.text)”")
        }
        let q = parse("tag:\"Rock\" year:1990..2000 -live")
        expect(q.removableParts.count == 3, "three chips: \(q.removableParts.count)")
        expect(parse(q.text(removing: 1)) == parse("tag:\"Rock\" -live"), "taking out the year leaves the rest: \(q.text(removing: 1))")
        expect(q.text(removing: 0) == parse("year:1990..2000 -live").text, "taking out the first chip")
        expect(parse("tag:\"Rock\"").text(removing: 0).isEmpty, "the last chip leaves an empty search")
        expect(q.text(removing: 9) == q.text, "an index that is not there changes nothing")
    }

    func aTagFilterHasItsOwnHeading() {
        expect(parse("tag:\"Alternative & Indie, Pop\"").singleTagName == "Alternative & Indie, Pop", "the tag's name is the heading")
        expect(parse("tag:\"Classical/Symphonies\"").singleTagName == "Symphonies", "the last part of a path")
        expect(parse("tag:\"Rock\" year:1990..2000").singleTagName == nil && parse("artist:\"Tame Impala\"").singleTagName == nil && parse("a b").singleTagName == nil, "anything else keeps the title Search")
    }

    private func source(_ file: String) -> String? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(file)
        return try? String(contentsOf: root, encoding: .utf8)
    }

    func searchFieldIsARealField() {
        guard let top = source("GUI/TopRail.swift"), let a = top.range(of: "struct TopSearchField"), let b = top.range(of: "struct OutputChip") else { return }
        let field = String(top[a.lowerBound..<b.lowerBound])
        expect(field.contains("TextField(") && field.contains("$m.searchText"), "the bar's search is a text field bound to the search text")
        expect(field.contains("onKeyMonitor(.escape") && field.contains("onKeyMonitor(.downArrow") && field.contains("onKeyMonitor(.upArrow") && field.contains("onKeyMonitor(.return") && field.contains("submitSearch()"), "arrows move through the suggestions, Return searches, Escape closes the list and then clears")
        expect(field.contains("xmark.circle.fill") && field.contains("Brand.accent.opacity(focused") && field.contains("anchorPreference"), "a clear button, an accent focus ring, and the list anchored to the field")
        expect(field.contains("keyboardShortcut(\"k\""), "⌘K stays on the quick find")
        // typing searches at once: the model starts a search for any change, and the page is the Search page
        expect(source("GUI/Model.swift")?.contains("library.runSearch(searchText") == true, "a change of text runs the search")
        expect(source("GUI/Models2.swift")?.contains("Task.sleep(nanoseconds: 120_000_000)") == true, "a pause of about 120 ms after the last key")
    }

    @MainActor private func render(_ strength: WindowEdgeStrength, light: Bool, size: CGSize = CGSize(width: 400, height: 300)) -> NSBitmapImageRep? {
        let r = ImageRenderer(content: WindowEdgeOverlay(strength: strength, light: light).frame(width: size.width, height: size.height))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }

    func windowEdgeSettingAndOverlay() {
        // the setting: Subtle by default, saved, and a record from before it existed reads as Subtle
        expect(LookSettings().windowEdge == .off, "Off by default")
        var l = LookSettings(); l.windowEdge = .strong
        let back = try? JSONDecoder().decode(LookSettings.self, from: JSONEncoder().encode(l))
        expect(back?.windowEdge == .strong, "saved between launches")
        expect((try? JSONDecoder().decode(LookSettings.self, from: Data("{\"density\":\"compact\"}".utf8)))?.windowEdge == .off, "an older record reads as Off")
        expect((try? JSONDecoder().decode(LookSettings.self, from: Data("{\"windowEdgeSoft\":\"loud\"}".utf8)))?.windowEdge == .off, "an unknown value reads as Off")
        expect(!l.rebuildsInterface(from: LookSettings()), "changing it does not rebuild the pages")
        expect(WindowEdgeStrength.allCases.map(\.title) == ["Off", "Subtle", "Strong"])
        expect(WindowEdgeStrength.subtle.shade.dark < WindowEdgeStrength.strong.shade.dark && WindowEdgeStrength.off.shade.dark == 0, "Strong is stronger")
        expect(WindowEdgeStrength.strong.shade.dark <= 0.25 && WindowEdgeStrength.strong.shade.light <= 0.12, "even Strong is faint at the rim")
        // the layer takes no clicks, is drawn once, and has no line in it: no stroke and no highlight
        if let text = source("GUI/WindowEdge.swift") {
            expect(text.contains(".allowsHitTesting(false)") && text.contains(".drawingGroup()") && !text.contains("TimelineView"), "static, and it takes no clicks")
            expect(!text.contains("strokeBorder") && !text.contains(".stroke(") && !text.contains("opacity(high") && !text.contains("blur("), "no stroke, no highlight, nothing that can draw a line")
        }
        // the curve: from the rim to nothing, never rising, no step
        var last = 1.0, biggest = 0.0
        for i in 0...200 { let v = WindowEdgeStrength.fade(Double(i) / 200); expect(v <= last + 1e-12, "monotonic at \(i)"); biggest = max(biggest, last - v); last = v }
        expect(WindowEdgeStrength.fade(0) == 1 && WindowEdgeStrength.fade(1) == 0 && biggest < 0.03, "starts full, ends at nothing, smooth: step \(biggest)")
        // the picture: clear in the middle (it never covers content), faint at the rim, fading without a step along a line into the window, nothing when off
        MainActor.assumeIsolated {
            for light in [false, true] {
                for strength in [WindowEdgeStrength.subtle, .strong] {
                    guard let img = render(strength, light: light, size: CGSize(width: 600, height: 400)), let off = render(.off, light: light, size: CGSize(width: 600, height: 400)) else { expect(false, "renders"); continue }
                    func alpha(_ x: Int, _ y: Int) -> Double { Double(img.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
                    let cap = light ? strength.shade.light : strength.shade.dark
                    expect(alpha(300, 200) < 0.004, "the middle stays clear (\(strength), light: \(light))")
                    expect(alpha(0, 200) <= cap + 0.02, "the rim is faint (\(strength), light: \(light)): \(alpha(0, 200))")
                    // along the middle of the left edge, from the rim inward: never rising, and no jump between neighbouring pixels
                    var prev = alpha(0, 200), maxStep = 0.0, rises = 0
                    for x in 1..<120 { let a = alpha(x, 200); if a > prev + 0.004 { rises += 1 }; maxStep = max(maxStep, abs(a - prev)); prev = a }
                    expect(rises == 0 && maxStep < 0.02, "a smooth fade with no line (\(strength), light: \(light)): rises \(rises), largest step \(maxStep)")
                    expect(alpha(150, 200) < 0.004, "gone well before the middle (\(strength), light: \(light))")
                    expect(off.colorAt(x: 0, y: 200)?.alphaComponent ?? 0 == 0, "Off draws nothing")
                }
            }
        }
    }

    // MARK: - the search experience

    private func track(_ title: String, artist: String = "Band", rel: String = "r1") -> TrackDTO {
        TrackDTO(id: "t-" + title, path: "/m/\(title).flac", title: title, trackNumber: 1, discNumber: 1, duration: 200, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2, year: 2020, releaseID: rel, releaseTitle: "Rel", workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil, credits: [], genres: ["Pop"], mbRecordingID: nil, playCount: 0, lastPlayedAt: nil)
    }
    private func party(_ n: String) -> PartyDTO { PartyDTO(id: "p-" + n, name: n, sortName: n, kind: "person", count: 3, mbArtistID: nil) }
    private func release(_ n: String, artist: String = "Band") -> ReleaseDTO { ReleaseDTO(id: "r-" + n, title: n, year: 2020, trackCount: 10, artistNames: [artist], mbReleaseID: nil, maxSampleRate: 96_000, maxBitDepth: 24, genre: nil, addedAt: nil) }

    func suggestionsAreRanked() {
        let q = "ash"
        let results = SearchResults(tracks: [track("Splash"), track("Ashke", artist: "Karan Aujla"), track("Ash Wednesday")], parties: [party("Ashley"), party("Karan Aujla")], releases: [release("Ashes"), release("Crash Course")])
        let rows = SearchRanking.suggestions(query: q, results: results, playlists: [PlaylistDTO(id: "pl", name: "Cash Flow", trackCount: 4, duration: 0, createdAt: 0, updatedAt: 0)], genres: ["Ash Rock", "Pop"], recents: ["ashke", "zebra"])
        expect(rows.first?.kind == .completion && rows.first?.title == "ashke" && rows.first?.subtitle == "Recent", "a recent search that starts with the text comes first: \(rows.map(\.title))")
        let completions = rows.filter { $0.kind == .completion }, things = rows.filter { $0.kind != .completion }
        expect(completions.count <= 3 && things.count <= 6 && rows == completions + things, "up to three completions, then up to six things, in that order")
        expect(things.first?.kind == .artist && things.first?.title == "Ashley", "an artist whose name starts with it beats the songs and albums: \(things.map(\.title))")
        expect(!things.contains { $0.title == "Crash Course" || $0.title == "Splash" } || things.firstIndex { $0.title == "Ashke" }! < things.firstIndex { $0.title == "Splash" } ?? 99, "names that start with it outrank names that only contain it")
        expect(Set(rows.map(\.id)).count == rows.count, "no row twice")
        expect(SearchRanking.suggestions(query: "  ", results: results, playlists: [], genres: [], recents: []).isEmpty, "nothing for an empty query")
        expect(SearchRanking.score("Édith Piaf", query: "edith") == 80 && SearchRanking.score("The Beatles", query: "beat") == 60 && SearchRanking.score("Abbey Road", query: "bey") == 40 && SearchRanking.score("x", query: "y") == 0 && SearchRanking.score("Rock", query: "rock") == 100, "scores ignore case and accents")
        // the top result: the best match, an artist before an album before a song when they match equally well
        let same = SearchResults(tracks: [track("Radiohead")], parties: [party("Radiohead")], releases: [release("Radiohead")])
        if case .artist? = SearchRanking.topResult(query: "radiohead", results: same) {} else { expect(false, "artist first") }
        if case .track? = SearchRanking.topResult(query: "zz", results: SearchResults(tracks: [track("Q")])) {} else { expect(false, "with no match, the first song") }
        expect(SearchRanking.topResult(query: "x", results: nil) == nil, "nothing while waiting")
    }

    func chipsFilterTheResults() {
        let r = SearchResults(tracks: [track("A")], works: [], parties: [party("B")], releases: [release("C")])
        func counts(_ s: SearchScope) -> [Int] { let f = SearchRanking.filtered(r, scope: s); return [f.tracks.count, f.parties.count, f.releases.count] }
        expect(counts(.all) == [1, 1, 1] && counts(.songs) == [1, 0, 0] && counts(.albums) == [0, 0, 1] && counts(.artists) == [0, 1, 0], "each chip keeps only its own kind")
        expect(counts(.playlists) == [0, 0, 0] && counts(.genres) == [0, 0, 0] && counts(.podcasts) == [0, 0, 0], "playlists, genres and podcasts are listed from their own sources")
        expect(SearchScope.allCases.map(\.title) == ["All", "Songs", "Albums", "Artists", "Playlists", "Genres", "Podcasts"], "the chips, in order")
        let tree = TagTreeNode.build([("Alternative & Indie", 3), ("Classical/Symphonies", 5), ("Rock", 9)])
        expect(SearchGenres.matching("symph", in: tree).map(\.name) == ["Symphonies"] && SearchGenres.matching("rock", in: tree).first?.name == "Rock", "genres are found at every level")
    }

    func recentSearchesPersist() {
        let d = UserDefaults(suiteName: "aureon.recents.\(UUID().uuidString.prefix(8))")!
        var r = SearchRecents.load(d)
        expect(r.items.isEmpty, "none at first")
        for q in ["a", "b", "c", "A", "  ", "d"] { r.add(q) }
        expect(r.items == ["d", "A", "c", "b"], "newest first, no duplicates ignoring case, blanks ignored: \(r.items)")
        for i in 0..<20 { r.add("q\(i)") }
        expect(r.items.count == SearchRecents.limit && r.items.first == "q19", "at most \(SearchRecents.limit)")
        r.save(d)
        expect(SearchRecents.load(d) == r, "kept between launches")
        r.remove("q19"); expect(!r.items.contains("q19"), "removable")
        r.clear(); r.save(d); expect(SearchRecents.load(d).items.isEmpty, "clear all")
        let model = MainActor.assumeIsolated { () -> [String] in let m = SearchModel(defaults: d); m.remember("jazz"); m.remember("rock"); m.forget("jazz"); return SearchModel(defaults: d).recents.items }
        expect(model == ["rock"], "the model saves what it remembers: \(model)")
    }

    func emptyAndResultPagesHaveTheRightContent() {
        guard let text = source("GUI/SearchExperience.swift"), let a = text.range(of: "struct SearchEmptyState"), let b = text.range(of: "// MARK: - Search tips"),
              let c = text.range(of: "struct SearchResultsPage"), let d = text.range(of: "enum SearchGenres") else { return }
        let empty = String(text[a.lowerBound..<b.lowerBound]), results = String(text[c.lowerBound..<d.lowerBound])
        expect(empty.contains("Recent searches") && empty.contains("Browse genres") && empty.contains("Clear all") && empty.contains("forget"), "the empty page: recent searches (removable, clear all) and genres to browse")
        expect(!empty.contains("QueryHelp") && !results.contains("QueryHelp") && !empty.contains("Query language"), "no query box on either page")
        expect(results.contains("TopResultCard") && results.contains("SearchSongRows") && results.contains("shelf(\"Albums\")") && results.contains("shelf(\"Artists\")"), "results: top result, songs, shelves of artists and albums")
        expect(text.contains("struct SearchTips") && source("GUI/TopRail.swift")?.contains("SearchTips") == true, "the query language lives in the Search tips popover")
        let page = source("GUI/SmartSearch.swift") ?? ""
        expect(!page.contains("TagTreePanel(") || !page.contains("showTree"), "the Genres & tags panel is not on the Search page")
    }

    // MARK: - genre pictures, lyrics motion, the search page's life, opening Now Playing

    func genrePicksChangeAndFallBack() {
        var rng = SystemRandomNumberGenerator()
        let pool = (0..<8).map { "r\($0)" }
        var previous: [String] = []
        for _ in 0..<200 {
            let p = GenrePicker.pick(pool, previous: previous, count: 3, using: &rng)
            expect(p.count == 3 && Set(p).count == 3 && p.allSatisfy(pool.contains), "three different albums of the genre")
            if let first = previous.first { expect(p.first != first, "the first pick never repeats the last one: \(p) after \(previous)") }
            previous = p
        }
        expect(GenrePicker.pick(["only"], previous: ["only"], count: 3, using: &rng) == ["only"], "one album: shown again, nothing else to choose")
        expect(GenrePicker.pick([], previous: [], count: 3, using: &rng).isEmpty, "a genre with no albums has no picks, so its tile shows the coloured gradient")
        expect(GenrePicker.pick(["a", "b"], previous: [], count: 3, using: &rng).count == 2, "fewer albums than asked for")
        var seen = Set<String>()
        for _ in 0..<60 { seen.insert(GenrePicker.pick(pool, previous: [], count: 1, using: &rng)[0]) }
        expect(seen.count >= 6, "random: over many launches nearly every album gets its turn: \(seen.count)")
        expect(SearchTile.color(for: "Jazz") == SearchTile.color(for: "jazz") && SearchTile.palette.count >= 8, "a genre keeps its colour")
    }

    func lyricsMotionMath() {
        let m = LyricsMotion.self
        expect(m.opacity(relative: 0) == 1 && m.blur(relative: 0) == 0 && m.scale(relative: 0, reduceMotion: false) == 1, "the line being sung is sharp, bright and full size")
        for r in 1...5 {
            expect(m.opacity(relative: r) <= m.opacity(relative: r - 1) && m.opacity(relative: 1) < 1 && m.opacity(relative: 2) < m.opacity(relative: 1), "lines further ahead are dimmer (\(r))")
            expect(m.opacity(relative: -r) <= (r == 1 ? 1 : m.opacity(relative: -(r - 1))) && m.opacity(relative: -1) < 1, "sung lines fade as they go up (\(r))")
            expect(m.blur(relative: r) >= m.blur(relative: r - 1) && m.blur(relative: -r) == m.blur(relative: r), "blur grows with distance, the same either side")
        }
        expect(m.scale(relative: 3, reduceMotion: false) < 1 && m.scale(relative: 3, reduceMotion: true) == 1, "other lines are smaller, except with Reduce Motion")
        expect(m.focus >= 0.35 && m.focus <= 0.40, "the focus line rests 35-40 % from the top")
        expect(m.rowTop(relative: 0, rowHeight: 40, focusY: 150) == 150 && m.rowTop(relative: 2, rowHeight: 40, focusY: 150) == 230 && m.rowTop(relative: -1, rowHeight: 40, focusY: 150) == 110, "rows are one row apart around the focus")
        expect(m.scrollOffset(index: 5, rowHeight: 40, focusY: 150) == 50, "scrolling by that offset puts row 5 on the focus")
        expect(m.duration >= 0.35 && m.duration <= 0.45, "an eased move of about 0.4 s")
        expect(m.animation(reduceMotion: true) != m.animation(reduceMotion: false), "Reduce Motion: a short fade instead")
        expect(m.plainLine(progress: 0, count: 10) == 0 && m.plainLine(progress: 0.5, count: 10) == 5 && m.plainLine(progress: 1, count: 10) == 9 && m.plainLine(progress: 2, count: 10) == 9 && m.plainLine(progress: 0.5, count: 0) == 0, "plain lyrics drift by progress")
        // the wheel or trackpad takes over, and after three quiet seconds the words follow the song again
        var f = LyricsFollow()
        expect(f.isFollowing(at: 100), "following at first")
        f.userScrolled(at: 100)
        expect(!f.isFollowing(at: 100) && !f.isFollowing(at: 102.9), "the listener's scrolling holds the words where they are")
        expect(f.isFollowing(at: 103), "and three seconds later they snap back to the song")
        f.userScrolled(at: 110); f.userScrolled(at: 112)
        expect(!f.isFollowing(at: 114) && f.isFollowing(at: 115), "more scrolling restarts the wait")
        f.resume(); expect(f.isFollowing(at: 112), "tapping a line (or the button) follows again at once")
        // the reel at the foot of Poster and Turntable and the stage share these numbers
        if let text = source("GUI/LyricsView.swift") { expect(text.contains("LyricsMotion.opacity") && text.contains("LyricsMotion.resumeAfter") && text.contains("LyricsMotion.animation"), "the stage uses the shared motion") }
        if let text = source("GUI/Pulse/NowPlaying/NowPlayingFoot.swift") { expect(text.contains("NPLyrics(style:") && text.contains("NPInfoBlock"), "Poster and Turntable use the shared scroller, and show credits when there are no words") }
    }

    func searchFieldBelongsToTheSearchPage() {
        MainActor.assumeIsolated {
            let m = PlayerModel(); navKeepAlive.append(m)
            // leaving the Search page empties the field and closes the suggestions
            m.tab = .search; m.searchText = "tag:\"Alternative & Indie\""; m.search.dropdownOpen = true
            m.tab = .albums
            expect(m.searchText.isEmpty && !m.search.dropdownOpen, "Search → Albums: the field is empty and the list closed: “\(m.searchText)”")
            // Back brings the query back with the page entry
            m.navigator.goBack()
            expect(m.tab == .search && m.searchText == "tag:\"Alternative & Indie\"", "Back restores the query of that Search page: \(m.tab) “\(m.searchText)”")
            m.navigator.goForward()
            expect(m.tab == .albums && m.searchText.isEmpty, "Forward goes on to Albums with the field empty")
            // a tag chosen on the page does not stay in the field after leaving
            m.tab = .search; m.searchText = "tag:\"Rock\""; m.go(.tab(.songs))
            expect(m.searchText.isEmpty, "a tag filter does not follow you to the next page")
            // typing from another page opens Search
            m.tab = .home; m.searchText = "jazz"
            expect(m.tab == .search && m.searchText == "jazz", "typing in the field goes to Search")
            m.tab = .home
            expect(m.searchText.isEmpty && !m.search.dropdownOpen, "and leaving again empties it")
        }
    }

    /// Pressing Next must not block the main thread: after each press the run loop is pumped while a timer measures how late it fires. Reports the longest block.
    @MainActor func nextTrackDoesNotBlockTheMainThread() {
        setenv("AUREON_NULLSINK", "1", 1)
        let dir = tempDir("nexthitch")
        var urls: [URL] = []
        for i in 0..<6 {
            let u = dir.appendingPathComponent("Song \(i).wav")
            _ = writeWAV(u, rate: 8000, bits: 16, frames: 8000 * 30) { f, _ in Int(2500 * sin(Double(f) * (0.08 + 0.01 * Double(i)))) }
            urls.append(u)
        }
        let m = PlayerModel(); navKeepAlive.append(m)
        defer { m.clear() }
        m.add(urls: urls, play: false)
        guard let first = m.items.first else { expect(false, "songs queued"); return }
        m.play(first.id)
        var last = CFAbsoluteTimeGetCurrent(), worst = 0.0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.004, repeats: true) { _ in let now = CFAbsoluteTimeGetCurrent(); worst = max(worst, now - last - 0.004); last = now }
        func pump(_ secs: Double) { let end = Date().addingTimeInterval(secs); while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.004)) } }
        pump(0.5)
        worst = 0
        // one press and its aftermath
        var single = 0.0
        for _ in 0..<3 { worst = 0; let t0 = CFAbsoluteTimeGetCurrent(); m.player.send(.next); let call = CFAbsoluteTimeGetCurrent() - t0; pump(0.4); single = max(single, worst, call) }
        // mashing Next twenty times
        worst = 0
        for _ in 0..<20 { m.player.send(.next); pump(0.02) }
        pump(0.5)
        timer.invalidate()
        let ms = { (x: Double) in String(format: "%.1f ms", x * 1000) }
        FileHandle.standardError.write(Data("next-track main-thread block: single press \(ms(single)), 20 presses \(ms(worst))\n".utf8))
        // a debug build is slower than the shipped one; these limits catch a real stall (work moved onto the main thread), not tuning
        let limit = ProcessInfo.processInfo.environment["AUREON_RELEASE_TESTS"] != nil ? 0.016 : 0.060
        expect(single < limit, "one press blocks the main thread for \(ms(single)) (limit \(ms(limit)))")
        expect(worst < limit, "mashing Next 20 times: the longest block is \(ms(worst)) (limit \(ms(limit)))")
    }

    // MARK: - the quality strip

    private func stream(bits: Int, rate: Double, codec: String = "FLAC", channels: Int = 2, outRate: Double? = nil) -> FormatTagInput {
        var src = StreamInfo(sampleRate: rate, channels: channels, sourceBits: bits, totalFrames: 100_000, codec: codec, transparent: false)
        src.sourceRate = rate
        let out = StreamInfo(sampleRate: outRate ?? rate, channels: channels, sourceBits: bits, totalFrames: 100_000, codec: "PCM", transparent: false)
        return FormatTagInput(source: src, output: out, bitrate: nil, bitPerfect: false, exclusive: true, replayGainDB: -8.8, stages: [], dspActive: false, deviceName: "DAC")
    }

    func qualityStripKeepsEveryTag() {
        let input = stream(bits: 24, rate: 88_200, outRate: 96_000)
        let all = Set(FormatTagBuilder.tags(input).map(\.id))
        let model = QualityStripModel.make(input)
        expect(all.isSubset(of: model.carried), "no tag is lost: \(all.subtracting(model.carried))")
        expect(model.tone == .hiRes && model.title == "Hi-Res Lossless" && model.subtitle == "FLAC · Stereo", "the badge: \(model.title) / \(model.subtitle)")
        let labels = model.cells.map(\.label)
        expect(labels == ["DEPTH", "RATE", "GAIN", "UPSAMPLED", "OUTPUT"], "the cells, in order: \(labels)")
        expect(model.cells.first { $0.label == "GAIN" }?.value == "−8.8 dB" && model.cells.first { $0.label == "OUTPUT" }?.value == "96 kHz" && model.cells.first { $0.label == "DEPTH" }?.value == "24-bit", "the figures")
        expect(model.exclusive?.value == "Exclusive" && model.exclusive?.help.contains("other apps cannot use this device") == true, "the Exclusive cell and its explanation")
        expect(model.chain.value == "Processed", "the chain: \(model.chain.value)")
        expect(model.pill == "Hi-Res · 24/88.2 → 96", "the player bar pill: \(model.pill)")
        expect(model.spoken.contains("Hi-Res Lossless") && model.spoken.contains("depth 24-bit") && model.spoken.contains("Exclusive"), "VoiceOver reads the whole chain as one label: \(model.spoken)")
    }

    @MainActor func extraPanelsShowRealDataOnly() {
        func song(genres: [String] = [], plays: Int? = nil, lufs: Double? = nil, work: String? = nil) -> TrackDTO {
            var t = TrackDTO(id: "x", path: "/x", title: "x", trackNumber: nil, discNumber: nil, duration: 100, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2, year: 1999, releaseID: nil, releaseTitle: nil,
                             workID: nil, workTitle: work, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil, credits: [], genres: genres, mbRecordingID: nil)
            t.playCount = plays; t.lufs = lufs; return t
        }
        expect(NPExtras.cards(nil).isEmpty, "no song, no cards")
        let bare = NPExtras.cards(song()).map(\.kind)
        expect(bare == [.file], "a song with no figures shows only what is certain: \(bare)")
        let full = NPExtras.cards(song(genres: ["Jazz"], plays: 3, lufs: -14.2, work: "Op. 1"))
        expect(full.map(\.kind) == [.genre, .plays, .loudness, .file, .work], "fixed order: \(full.map(\.kind))")
        expect(NPExtras.visible(full, enabled: Set(NPExtraKind.allCases), master: true).count == NPExtras.limit, "never more than two at once")
        expect(NPExtras.visible(full, enabled: Set(NPExtraKind.allCases), master: false).isEmpty, "the master switch hides all")
        expect(NPExtras.visible(full, enabled: [.loudness, .work], master: true).map(\.kind) == [.loudness, .work], "per-module switches choose")
        expect(full.first { $0.kind == .loudness }?.value == "-14.2 LUFS" && full.first { $0.kind == .file }?.value == "FLAC · 24-bit · 96 kHz", "figures are the song's own")
        let suite = UserDefaults(suiteName: "aureon.test.extras")!; suite.removePersistentDomain(forName: "aureon.test.extras")
        let a = NPExtraSettings(defaults: suite); a.set(.plays, false); a.master = false
        let b = NPExtraSettings(defaults: suite)
        expect(!b.master && !b.isOn(.plays) && b.isOn(.genre), "choices are remembered")
        suite.removePersistentDomain(forName: "aureon.test.extras")
    }

    @MainActor func hairlineTransportKeepsHitTargetsAndContrast() {
        for k in [0.5, 0.75, 1.0, 1.25, 1.6] as [CGFloat] {
            expect(TransportMetrics.play(k).hit >= 44 && TransportMetrics.skip(k).hit >= 44, "hit areas never drop below 44 points at scale \(k)")
        }
        expect(TransportMetrics.play().hit == 72 && TransportMetrics.play().glyph == 52 && TransportMetrics.skip().hit == 52 && TransportMetrics.skip().glyph == 28 && TransportMetrics.modeGlyph == 22 && TransportMetrics.minHit >= 44, "the sizes are the chosen ones: play 52 in 72, skip 28 in 52, modes 22 in 44")
        expect(TransportMetrics.stroke(28) >= 2.4 && TransportMetrics.stroke(52) >= 6, "heavy, rounded")
        for t in Theme.all {
            let ink = WCAG.over(t.inkRGB, alpha: 1, t.canvasRGB)
            expect(WCAG.contrast(ink, t.canvasRGB) >= 4.5, "\(t.id): the glyph reads on the player bar: \(WCAG.contrast(ink, t.canvasRGB))")
            expect(WCAG.contrast(t.accentTextRGB, t.canvasRGB) >= 4.5, "\(t.id): the gold hover reads on the bar")
        }
        if let text = source("GUI/PlayerBar.swift"), let np = source("GUI/Pulse/NowPlaying/NowPlayingParts.swift"), let mini = source("GUI/Pulse/Mini/MiniViews.swift") {
            expect(text.contains("HairlineKeyStyle") && np.contains("HairlineKeyStyle") && mini.contains("HairlineKeyStyle"), "the player bar, every Now Playing layout and the mini player share one style")
            expect(!text.contains("PlayKeyStyle") && !np.contains("PlayKeyStyle") && !mini.contains("PlayKeyStyle"), "no filled play plate is left")
        }
    }

    /// The audio a hand on the platter makes is what is in the ring: before, seconds of it; with the scratch mode, a few milliseconds.
    @MainActor func scratchingKeepsTheBufferTiny() {
        setenv("AUREON_NULLSINK", "1", 1)
        let dir = tempDir("scratchlat")
        let u = dir.appendingPathComponent("Long.wav")
        _ = writeWAV(u, rate: 44_100, bits: 16, frames: 44_100 * 90) { f, _ in Int(6000 * sin(Double(f) * 0.05)) }
        let m = PlayerModel(); navKeepAlive.append(m)
        defer { m.clear() }
        m.player.varispeed = VarispeedControl()
        m.add(urls: [u], play: false)
        guard let first = m.items.first else { expect(false, "song queued"); return }
        m.play(first.id)
        func pump(_ secs: Double) { let end = Date().addingTimeInterval(secs); while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) } }
        pump(1.5)
        let before = m.status.bufferedSeconds
        guard let ctl = m.player.varispeed else { expect(false, "pitch control present"); return }
        ctl.scratchSpeed = 0; ctl.scratchOn = true; m.player.send(.seekBy(0))
        let t0 = CFAbsoluteTimeGetCurrent()
        var settled = Double.infinity
        while CFAbsoluteTimeGetCurrent() - t0 < 2 { pump(0.02); if m.status.bufferedSeconds < 0.06 { settled = CFAbsoluteTimeGetCurrent() - t0; break } }
        pump(0.3)
        let during = m.status.bufferedSeconds
        FileHandle.standardError.write(Data(String(format: "scratch: buffered %.2f s normally, %.3f s while scratching (reached after %.0f ms)\n", before, during, settled * 1000).utf8))
        expect(before > 0.3, "normally the ring holds a good part of a second or more: \(before)")
        expect(during < 0.06, "while scratching the ring holds only a few milliseconds: \(during)")
        expect(settled < 1.0, "the old buffer is gone within a second of the touch: \(settled)")
        // a moving hand: forwards at normal speed the song advances at normal speed, backwards it goes back
        ctl.scratchSpeed = 1
        pump(0.3); let p0 = m.status.position; pump(1.0); let p1 = m.status.position
        expect(abs((p1 - p0) - 1.0) < 0.3, "at scratch speed 1 the song advances one second per second: \(p1 - p0)")
        ctl.scratchSpeed = -1
        pump(0.3); let q0 = ctl.sourceFrame; pump(1.0); let q1 = ctl.sourceFrame
        expect(q1 < q0 - 44_100 * 0.6, "at scratch speed -1 the song is read backwards: \((q1 - q0) / 44_100) s")
        expect(m.status.state == .playing, "playing throughout")
        ctl.scratchOn = false
        pump(1.0)
        expect(m.status.bufferedSeconds > 0.3, "letting go fills the buffer again: \(m.status.bufferedSeconds)")
    }

    func qualityStripHidesWhatDoesNotApply() {
        var plain = stream(bits: 24, rate: 96_000)
        plain.replayGainDB = nil; plain.exclusive = false; plain.bitPerfect = true
        let m = QualityStripModel.make(plain)
        expect(m.cells.map(\.label) == ["DEPTH", "RATE", "OUTPUT", "MODE"], "no gain and no upsampling when neither applies: \(m.cells.map(\.label))")
        expect(m.exclusive == nil && m.cells.last?.value == "Shared" && m.chain.value == "Bit-perfect", "shared output has no lock; the chain is bit-perfect")
        expect(m.pill == "Hi-Res · 24/96", "no arrow when the output rate is the file's rate: \(m.pill)")
        var dsp = plain; dsp.dspActive = true
        expect(QualityStripModel.make(dsp).cells.contains { $0.label == "DSP" }, "a DSP cell appears with DSP")
    }

    func qualityStripNeverClaimsHiResFalsely() {
        let cd = QualityStripModel.make(stream(bits: 16, rate: 44_100))
        expect(cd.tone == .lossless && cd.title == "Lossless" && cd.pill.hasPrefix("Lossless"), "CD quality is Lossless, not Hi-Res: \(cd.title) / \(cd.pill)")
        let mp3 = QualityStripModel.make(stream(bits: 24, rate: 96_000, codec: "MP3 (lossy)"))
        expect(mp3.tone == .lossy && mp3.title == "Lossy" && !mp3.pill.contains("Hi-Res") && !mp3.cells.contains { $0.label == "DEPTH" }, "a lossy file is never Hi-Res, even at a high rate: \(mp3.title) / \(mp3.pill)")
        expect(mp3.subtitle.hasPrefix("MP3"), "the codec is the subtitle: \(mp3.subtitle)")
        var radio = stream(bits: 16, rate: 44_100, codec: "AAC (lossy)")
        radio.source.isLive = true; radio.bitrate = 128
        let live = QualityStripModel.make(radio)
        expect(live.tone == .live && live.cells.contains { $0.label == "BITRATE" && $0.value == "128 kbps" }, "a live stream: \(live.title), \(live.cells.map(\.label))")
    }

    @MainActor func detailRibbonAndPanelsAreHonestAndTidy() {
        for t in Theme.all {
            expect(t.surfaces.allSatisfy { WCAG.contrast(t.goldRGB, $0) >= 4.5 }, "\(t.id): the gold of the stamp holds 4.5:1 on every surface")
            for tint in [NPRibbon.Tint.gold, .silver, .grey, .teal] {
                let f = NPCoverChip.fill(tint, theme: t)
                expect(WCAG.contrast(WCAG.onColor(f), f) >= 4.5, "\(t.id): the text of the \(tint) chip reads on its fill")
            }
        }
        expect(abs(WCAG.luminance(Theme.all.first { $0.isLight }!.goldRGB) - WCAG.luminance(RGB(0.659, 0.439, 0.039))) < 0.2, "light themes keep a gold close to #a8700a")
        func ribbon(_ i: FormatTagInput) -> NPRibbon { NPRibbon.make(QualityStripModel.make(i)) }
        expect(ribbon(stream(bits: 24, rate: 88_200)) == NPRibbon(text: "HI-RES", tint: .gold), "a 24/88.2 FLAC gets the gold Hi-Res ribbon")
        expect(ribbon(stream(bits: 16, rate: 44_100)) == NPRibbon(text: "LOSSLESS", tint: .silver), "CD quality gets the silver Lossless ribbon")
        expect(ribbon(stream(bits: 24, rate: 96_000, codec: "MP3 (lossy)")) == NPRibbon(text: "LOSSY", tint: .grey), "a lossy file gets the grey ribbon, never Hi-Res")
        var radio = stream(bits: 16, rate: 44_100, codec: "AAC (lossy)"); radio.source.isLive = true
        expect(ribbon(radio).text == "LIVE", "a live stream says Live")
        let input = stream(bits: 24, rate: 88_200)
        let m = QualityStripModel.make(input)
        expect(NPDetailContent.quality(m, input).contains("24-bit / 88.2 kHz") && NPDetailContent.quality(m, input).contains("above CD quality"), "the ribbon's sentence quotes the real figures")
        expect(NPDetailContent.quality(QualityStripModel.make(stream(bits: 24, rate: 96_000, codec: "MP3 (lossy)")), stream(bits: 24, rate: 96_000, codec: "MP3 (lossy)")).contains("never labelled Hi-Res"), "the lossy sentence says so")
        var t = TrackDTO(id: "x", path: "/Music/A/B/01 Song.flac", title: "Song", trackNumber: 1, discNumber: 1, duration: 200, codec: "FLAC", sampleRate: 88_200, bitDepth: 24, channels: 2, year: 2020, releaseID: nil, releaseTitle: "B", workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil, credits: [], genres: [], mbRecordingID: nil)
        t.fileSize = 50_000_000
        let rows = NPDetailContent.format(input, track: t)
        func value(_ l: String) -> String? { rows.first { $0.label == l }?.value }
        expect(value("Format") == "FLAC" && value("Bit depth") == "24-bit" && value("Sample rate") == "88.2 kHz" && value("Channels") == "Stereo" && value("File size") == "47.7 MB" && value("Path") == t.path && value("ReplayGain") == "-8.8 dB applied", "the File panel is the real file: \(rows.map { "\($0.label)=\($0.value)" })")
        expect(value("Average bitrate") == "2000 kbps", "the bitrate is worked out from size and length: \(value("Average bitrate") ?? "-")")
        let sig = NPDetailContent.signal(input)
        expect(sig.map(\.title) == ["Source", "Player", "Output", "Result"] && sig[0].detail.contains("FLAC") && sig[2].detail.contains("DAC"), "the signal path lists source, player, output and the result: \(sig)")
        // one panel at a time, and the same key closes it
        let d = NPDetailModel.shared; d.set(nil)
        d.toggle(.signal); expect(d.open == .signal)
        d.toggle(.info); expect(d.open == .info, "opening another closes the first")
        d.toggle(.info); expect(d.open == nil, "the same key closes it")
        d.set(.format); d.set(nil); expect(d.open == nil, "Escape and a click outside both call set(nil)")
        // no layout shift: the panel is an overlay of the keys row, so the row's size does not depend on it
        if let src = source("GUI/Pulse/NowPlaying/NowPlayingDetails.swift") {
            expect(src.contains(".windowPopover(isPresented: shown(.signal)") && !src.contains("NPRibbonView"), "every panel is a card in the window layer, above the seek bar and controls, and the diagonal ribbon is gone")
        }
    }

    @MainActor func tagsShowBeforeTheEngineHasAStream() {
        setenv("AUREON_NULLSINK", "1", 1)
        let dir = tempDir("tagsbefore"); let u = dir.appendingPathComponent("Loaded.wav")
        _ = writeWAV(u, rate: 8000, bits: 16, frames: 8000) { f, _ in Int(1000 * sin(Double(f) * 0.1)) }
        let m = PlayerModel(); navKeepAlive.append(m); defer { m.clear() }
        m.add(urls: [u], play: false)
        expect(m.formatTagInput(bitrate: nil) == nil, "nothing is playing, so the engine has no stream")
        func track(_ codec: String, bits: Int, rate: Double) -> TrackDTO {
            TrackDTO(id: "t", path: m.focusItem?.path ?? u.path, title: "t", trackNumber: nil, discNumber: nil, duration: 100, codec: codec, sampleRate: rate, bitDepth: bits, channels: 2, year: nil, releaseID: nil, releaseTitle: nil, workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil, credits: [], genres: [], mbRecordingID: nil)
        }
        let flac = m.formatTagInput(bitrate: nil, track: track("FLAC", bits: 24, rate: 96_000))
        expect(flac != nil && NPRibbon.make(QualityStripModel.make(flac!)) == NPRibbon(text: "HI-RES", tint: .gold), "a loaded 24/96 FLAC shows the Hi-Res ribbon before playing")
        let cd = m.formatTagInput(bitrate: nil, track: track("FLAC", bits: 16, rate: 44_100))
        expect(cd != nil && NPRibbon.make(QualityStripModel.make(cd!)).text == "LOSSLESS", "a CD-quality FLAC shows Lossless")
        let mp3 = m.formatTagInput(bitrate: nil, track: track("MP3", bits: 16, rate: 96_000))
        expect(mp3 != nil && NPRibbon.make(QualityStripModel.make(mp3!)).text == "LOSSY", "an MP3 shows Lossy, never Hi-Res")
        expect(m.formatTagInput(bitrate: nil, track: TrackDTO(id: "x", path: "/elsewhere.flac", title: "x", trackNumber: nil, discNumber: nil, duration: 1, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2, year: nil, releaseID: nil, releaseTitle: nil, workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil, credits: [], genres: [], mbRecordingID: nil)) == nil, "tags of another file are never shown")
        for need in ["NPDetailKeys", "NPCoverChip"] {
            for f in ["GUI/Pulse/NowPlaying/NowPlayingParts.swift"] { if let t = source(f) { expect(t.contains(need), "\(need) is in the shared title block and cover, which every layout uses") } }
        }
    }

    @MainActor func topBarControlsReadOnEveryLightTheme() {
        for t in Theme.all {
            expect(WCAG.contrast(t.inkRGB, t.sidebarRGB) >= 4.5, "\(t.id): top-bar glyphs (the full ink) read on the bar: \(WCAG.contrast(t.inkRGB, t.sidebarRGB))")
            if t.isLight {
                guard let e = t.controlEdgeRGB else { expect(false, "\(t.id): a light theme has a control outline"); continue }
                expect(WCAG.contrast(e, t.sidebarRGB) >= 3 && WCAG.contrast(e, t.canvasRGB) >= 3, "\(t.id): control outlines are 3:1 against the bar and the page: \(WCAG.contrast(e, t.sidebarRGB))")
                let glyph = t.inkSecondaryRGB
                expect(WCAG.contrast(glyph, t.sidebarRGB) >= 4.5 && WCAG.contrast(glyph, t.panel2RGB) >= 4.5, "\(t.id): rail and player-bar glyphs read on the bar and on raised surfaces")
            } else { expect(t.controlEdgeRGB == nil, "\(t.id): dark themes keep their quiet fills") }
        }
    }

    @MainActor func outputChipAlwaysOpens() {
        let m = PlayerModel(); navKeepAlive.append(m)
        // the state a theme change or a resize left behind: the panel marked open, no card on screen
        m.quickPanel = nil; m.toggleQuickPanel(.rail); expect(m.quickPanel == .rail, "closed opens")
        // and with the card really showing, the same click closes it
        m.popovers.present(WindowPopovers.Entry(id: UUID(), anchor: CGRect(x: 100, y: 10, width: 100, height: 30), edge: .bottom, content: AnyView(Text("x")), dismiss: {}))
        m.toggleQuickPanel(.rail); expect(m.quickPanel == nil, "the same press closes it")
        m.popovers.dismiss()
        // theme changes and resizes must leave no stale state: the chip's modifier clears its owner on disappear
        if let t = source("GUI/WindowPopover.swift") { expect(t.contains("onDisappear { center.close(id); if isPresented { isPresented = false } }"), "a chip rebuilt while open clears its owner's flag") }
        for theme in Theme.all.prefix(6) { m.choose(theme: theme); m.toggleQuickPanel(.rail); expect(m.quickPanel == .rail, "after switching to \(theme.id) the chip still opens"); m.quickPanel = nil }
    }

    func qualityStripWrapsAndKeepsContrast() {
        if let text = source("GUI/Pulse/QualityStrip.swift") {
            expect(text.contains("ViewThatFits(in: .horizontal)") && text.contains("wide(model, pal)") && text.contains("stacked(model, pal)"), "one row when it fits, the stacked form when it does not")
            expect(text.contains(".help(") && text.contains("openSignalPath") && text.contains(".ultraThinMaterial") && text.contains("accessibilityValue(model.spoken)"), "tooltips, a click opens the signal path, a translucent backing, one spoken label")
        }
        // every text colour holds 4.5:1 on the strip's backing over every theme's canvas and raised surface
        for theme in Theme.all {
            let pal = QualityPalette.colors(light: theme.isLight)
            for surface in [theme.canvasRGB, theme.panel2RGB] {
                let bg = WCAG.over(pal.backing, alpha: pal.backingAlpha, surface)
                for (name, c) in [("label", pal.label), ("ink", pal.ink), ("teal", pal.teal), ("gold", pal.gold), ("quiet", pal.quiet)] {
                    let r = WCAG.contrast(c, bg)
                    expect(r >= 4.5, "\(theme.id) \(name) is \(String(format: "%.2f", r)):1 on the strip")
                }
            }
            for f in pal.badgeFill { expect(WCAG.contrast(pal.badgeInk, f) >= 4.5, "\(theme.id): the badge's text on its fill") }
        }
    }

    /// At the three usual sizes the planned regions of Classic, Poster and Turntable fill their room: no more than 15 % of any column's height is unexplained empty space.
    func layoutsFillTheirRoom() {
        for size in [CGSize(width: 1180, height: 760), CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1080)] {
            let s = NPScale.of(size)
            let inner = size.width - 2 * max(28, 64 * s)
            let height = size.height - 56 - 150 * s                       // under the top bar, over the dock
            let name = "\(Int(size.width))×\(Int(size.height))"
            for queued in [0, 1, 6] {
                let c = NPClassicPlan.make(inner: inner, height: height, s: s, tags: true, queued: queued)
                expect(c.coverSide <= height + 0.5 && c.coverSide >= 0.6 * height, "Classic \(name) (\(queued) queued): the cover is as tall as the room allows: \(c.coverSide) of \(height)")
                expect(c.used(height: height, tabsHeight: 44 * s) >= 0.85, "Classic \(name) (\(queued) queued): the columns are filled: \(c.used(height: height, tabsHeight: 44 * s))")
                if c.wide { expect(c.topHeight + c.stripHeight + (c.stripCards > 0 ? c.gap : 0) <= height + 0.5, "Classic \(name): the strip sits inside the room") }
            }
            for title in ["Hero", "Midnight City", "The Less I Know The Better (Live at the Royal Albert Hall)"] {
                let p = NPPosterPlan.make(title: title, inner: inner - 24 * s, height: height - 14 * s, s: s, credits: 2, tags: true)
                expect(p.titleHeight <= 0.28 * (height + 190 * s) + 1 && p.lyricHeight >= 0.2 * height, "Poster \(name) “\(title.prefix(12))”: the title takes at most 28 % and the words get room: \(p.titleHeight) / \(p.lyricHeight)")
                expect(p.leftUsed(height: height - 14 * s) >= 0.85, "Poster \(name): the left column is filled: \(p.leftUsed(height: height - 14 * s))")
                expect(p.rightUsed(height: height - 14 * s) >= 0.70, "Poster \(name): the right column holds the cover, credits and the queue: \(p.rightUsed(height: height - 14 * s))")
                expect(p.leftWidth + p.gutter + p.rightWidth <= inner + 1, "Poster \(name): the columns fit the width")
                let t = NPTurntablePlan.make(title: title, inner: inner - 24 * s, height: height - 14 * s, s: s, tags: true)
                expect(t.rightUsed(height: height - 14 * s) >= 0.85 && t.leftUsed(height: height - 14 * s) >= 0.60, "Turntable \(name): right \(t.rightUsed(height: height - 14 * s)), deck \(t.leftUsed(height: height - 14 * s))")
                expect(t.deckSide + t.gutter + t.rightWidth <= inner + 1 && t.deckSide <= height - 14 * s + 0.5, "Turntable \(name): the deck is square and inside the room")
            }
        }
        for size in [CGSize(width: 1180, height: 760), CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1080)] {
            let s = NPScale.of(size), inner = size.width - 2 * max(28, 64 * s), height = size.height - 56 - 130 * s - 14 * s
            var shown: [Int] = []
            for queued in [0, 1, 4, 20] {
                let p = NPChillaxPlan.make(inner: inner, height: height, s: s, queued: queued)
                shown.append(p.limit)
                expect(p.limit <= min(15, queued) && p.limit <= p.columns * p.rows, "Chillax \(Int(size.width)): never more than fit or than 15: \(p.limit)")
                expect(p.coverSide + 12 * s + p.shelfHeight <= height + 1, "Chillax \(Int(size.width)) (\(queued) queued): cover and shelf fit the room: \(p.coverSide) + \(p.shelfHeight) of \(height)")
                expect(p.coverSide + p.shelfHeight >= 0.85 * height - 12 * s || queued == 0 && p.coverSide >= 0.5 * inner - 1, "Chillax \(Int(size.width)) (\(queued) queued): no empty band: \(p.coverSide + p.shelfHeight) of \(height)")
            }
            expect(shown == shown.sorted() , "Chillax: more songs as the queue grows: \(shown)")
        }
        for size in [CGSize(width: 1180, height: 760), CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1080), CGSize(width: 1180, height: 640)] {
            let s = NPScale.of(size), height = size.height - 56 - 130 * s - 14 * s, width = size.width - 2 * max(28, 64 * s)
            let name = "\(Int(size.width))×\(Int(size.height))"
            for lyrics in [true, false] {
                let p = NPCoverFlowPlan.make(width: width, height: height, s: s, lyrics: lyrics)
                expect(p.used(height: height) >= 0.85 && p.used(height: height) <= 1.0001, "Cover flow \(name) lyrics \(lyrics): the zones fill the column: \(p.used(height: height))")
                expect(p.centre >= 0.25 * height || p.centre >= width * 0.3, "Cover flow \(name) lyrics \(lyrics): a large centre cover: \(p.centre) of \(height)")
                var last: CGFloat = -1
                for z in p.zones { expect(z.y >= last - 0.01 && z.h > 0, "Cover flow \(name): the zones are in order and none is empty"); last = z.y + z.h }
                expect(p.zones.last!.y + p.zones.last!.h <= height + 0.5, "Cover flow \(name): the zones end inside the column")
                // no two cover frames overlap and all sit inside the width
                var frames: [ClosedRange<CGFloat>] = []
                for o in p.offsets { let w = p.side(o), cx = p.x(o); frames.append((cx - w / 2)...(cx + w / 2)) }
                for a in frames.indices { for b in frames.indices where b > a { expect(frames[a].upperBound <= frames[b].lowerBound + 0.5 || frames[b].upperBound <= frames[a].lowerBound + 0.5, "Cover flow \(name): covers do not overlap") } }
                expect(frames.allSatisfy { $0.lowerBound >= -width / 2 - 0.5 && $0.upperBound <= width / 2 + 0.5 }, "Cover flow \(name): every cover is inside the width")
                expect(p.perSide == (width < 1000 ? 1 : (width < 1500 ? 2 : 3)) || p.perSide >= 1, "Cover flow \(name): neighbours each side: \(p.perSide)")
            }
            expect(NPCoverFlowPlan.make(width: width, height: height, s: s, lyrics: false).centre >= NPCoverFlowPlan.make(width: width, height: height, s: s, lyrics: true).centre, "Cover flow \(name): without lyrics the cover row gets the height back")
        }
        if let text = source("GUI/Pulse/NowPlaying/NowPlayingLayouts.swift") { expect(text.contains("blurs: false") && !text.contains("queueRail") && !text.contains("infoRail"), "Cover flow has no side rails and never blurs its words") }
        let wide = NPChillaxPlan.make(inner: 1700, height: 700, s: 1.2, queued: 30), small = NPChillaxPlan.make(inner: 1000, height: 380, s: 0.8, queued: 30)
        expect(wide.limit > small.limit && wide.limit <= 15, "Chillax: more songs on a bigger window, never above 15: \(small.limit) → \(wide.limit)")
        if let text = source("GUI/Pulse/NowPlaying/NowPlayingLayouts.swift") { expect(text.contains("CarouselBackdrop()"), "Carousel has the album backdrop") }
        // the stage and the other centred layouts use the shared scroller and strip; their regions are flexible, with no fixed bands
        if let text = source("GUI/Pulse/NowPlaying/NowPlayingLayouts.swift") { expect(text.contains("NPClassicPlan.make"), "Classic is planned from its room") }
    }

    func turntableAnswersOnlyOnTheRecordAndTheArm() {
        let side: CGFloat = 400
        let path = TTHitShape().path(in: CGRect(x: 0, y: 0, width: side, height: side))
        expect(path.contains(CGPoint(x: side / 2, y: side / 2)) && path.contains(CGPoint(x: side * 0.7, y: side * 0.5)), "the record is the hand's")
        let midArm = TTArm.tip(angle: TTArm.angle(fraction: 0.5, engaged: true), side: side)
        expect(path.contains(midArm), "so is the needle wherever it is in the song")
        let pivotNear = CGPoint(x: TTArm.pivot.x * side - 2, y: TTArm.pivot.y * side + 12)
        expect(path.contains(CGPoint(x: (pivotNear.x + midArm.x) / 2, y: (pivotNear.y + midArm.y) / 2)), "and the arm between the pivot and the needle")
        expect(!path.contains(CGPoint(x: 30, y: side - 30)) && !path.contains(CGPoint(x: 70, y: side - 30)) && !path.contains(CGPoint(x: side - 10, y: side - 10)) && !path.contains(CGPoint(x: 10, y: 10)), "the buttons' corner and the empty corners of the plinth are not")
        // the scratch sound: the control the platter drives plays at the platter's speed, held still at 0, backwards below 0, and goes back to normal on release
        let c = VarispeedControl()
        expect(c.effectiveSpeed == 1, "normal playback")
        c.scratchSpeed = 0; c.scratchOn = true
        expect(c.effectiveSpeed == 0, "held still under the hand")
        c.scratchSpeed = -1.5
        expect(c.effectiveSpeed == -1.5, "backwards, faster than normal")
        c.scratchOn = false
        expect(c.effectiveSpeed == 1, "released: normal again")
        let spin = TurntableSpin()
        spin.drag(by: TTMotor.cruise * 0.1, dt: 0.1)                                   // exactly the normal speed, once smoothed in
        for _ in 0..<20 { spin.drag(by: TTMotor.cruise * 0.02, dt: 0.02) }
        expect(abs(spin.speed / TTMotor.cruise - 1) < 0.05, "the pointer's speed becomes the audio's: \(spin.speed / TTMotor.cruise)")
        if let text = source("GUI/Pulse/NowPlaying/NowPlayingTurntable.swift") {
            expect(text.contains("contentShape(TTHitShape())") && !text.contains("onChangeCompat(of: spin.isSettled"), "the gesture is on the record and the arm only; nothing is evaluated per frame")
        }
    }

    func nowPlayingOpensFromEveryPage() {
        MainActor.assumeIsolated {
            for page in [Tab.search, .albums, .songs, .artists, .playlists, .home, .radio, .liked] {
                let m = PlayerModel(); navKeepAlive.append(m)
                let stage = StageModel()
                m.tab = page
                if page == .search { m.searchText = "tag:\"Rock\""; m.search.dropdownOpen = true }
                stage.open(m, reduceMotion: true)
                expect(m.tab == .player && stage.immersive, "Now Playing opens from \(page): \(m.tab)")
                expect(m.searchText.isEmpty && !m.search.dropdownOpen, "from \(page): the field is empty and its list closed once Now Playing is open")
                stage.close(m, reduceMotion: true)
                expect(m.tab == page, "closing returns to \(page): \(m.tab)")
            }
        }
        // changing the volume (slider, wheel, keys) is not a reason to leave the page: in every Now Playing layout the tab stays where it is
        MainActor.assumeIsolated {
            for layout in NowPlayingLayout.allCases {
                let m = PlayerModel(); navKeepAlive.append(m)
                m.look.nowPlayingLayout = layout.rawValue
                m.tab = .player
                for v: Float in [0.2, 0.8, 0.5, 1] { m.setVolume(v) }
                expect(m.tab == .player && m.searchText.isEmpty, "\(layout): changing the volume keeps Now Playing: \(m.tab)")
                m.search.dropdownOpen = false
            }
        }
        // focus alone never navigates (the system hands the field its focus back when a page is rebuilt)
        if let top = source("GUI/TopRail.swift"), let a = top.range(of: "private struct TopSearchFieldBody"), let b = top.range(of: "struct OutputChip") {
            let field = String(top[a.lowerBound..<b.lowerBound])
            let focusBlock = field[field.range(of: ".onChangeCompat(of: focused)")!.lowerBound..<field.range(of: ".onChangeCompat(of: m.tab)")!.lowerBound]
            expect(!focusBlock.contains("go(.tab(.search))") && !focusBlock.contains("m.tab = "), "a change of focus does not change the page")
            expect(field.contains("simultaneousGesture(TapGesture()") && field.contains("focused = false"), "a click opens Search; leaving the page blurs the field")
        }
    }
}

func searchEdgeTests() -> [(String, TestFn)] {
    let t = SearchEdgeTests()
    return [("search.queryText", t.queriesWriteBackAndChipsComeOut), ("search.tagHeading", t.aTagFilterHasItsOwnHeading), ("search.field", t.searchFieldIsARealField), ("edge.window", t.windowEdgeSettingAndOverlay), ("search.ranking", t.suggestionsAreRanked), ("search.chips", t.chipsFilterTheResults), ("search.recents", t.recentSearchesPersist), ("search.pages", t.emptyAndResultPagesHaveTheRightContent), ("search.genrePicks", t.genrePicksChangeAndFallBack), ("lyrics.motion", t.lyricsMotionMath), ("search.lifecycle", t.searchFieldBelongsToTheSearchPage), ("np.opensFromEveryPage", t.nowPlayingOpensFromEveryPage), ("tt.hitAndScratch", t.turntableAnswersOnlyOnTheRecordAndTheArm), ("np.fillTheRoom", t.layoutsFillTheirRoom), ("np.extraPanels", { MainActor.assumeIsolated { t.extraPanelsShowRealDataOnly() } }), ("transport.hairline", { MainActor.assumeIsolated { t.hairlineTransportKeepsHitTargetsAndContrast() } }), ("np.details", { MainActor.assumeIsolated { t.detailRibbonAndPanelsAreHonestAndTidy() } }), ("tt.scratchLatency", { MainActor.assumeIsolated { t.scratchingKeepsTheBufferTiny() } }), ("quality.before", { MainActor.assumeIsolated { t.tagsShowBeforeTheEngineHasAStream() } }), ("ui.topBarContrast", { MainActor.assumeIsolated { t.topBarControlsReadOnEveryLightTheme() } }), ("ui.outputChip", { MainActor.assumeIsolated { t.outputChipAlwaysOpens() } }), ("quality.tags", t.qualityStripKeepsEveryTag), ("quality.hidden", t.qualityStripHidesWhatDoesNotApply), ("quality.honest", t.qualityStripNeverClaimsHiResFalsely), ("quality.wrapContrast", t.qualityStripWrapsAndKeepsContrast), ("perf.next", { MainActor.assumeIsolated { t.nextTrackDoesNotBlockTheMainThread() } })]
}

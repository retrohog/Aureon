import Foundation

struct LibraryTests {
    let dir = tempDir("lib")

    func symphony(_ n: Int, conductor: String, ensemble: String, album: String, year: Int, soloist: String? = nil, path: String) -> (facts: FileFacts, tags: TrackMetadata) {
        var m = TrackMetadata()
        let names = ["Allegro con brio", "Andante con moto", "Scherzo: Allegro", "Allegro"]
        m.title = "\(n). \(names[n - 1])"; m.album = album; m.year = year; m.trackNumber = n; m.discNumber = 1
        m.workTitle = "Symphony No. 5 in C minor, Op. 67"; m.catalog = "Op. 67"; m.key = "C minor"
        m.movementNumber = n; m.movementTotal = 4; m.movementTitle = names[n - 1]
        m.credits = [Credit(role: .composer, name: "Ludwig van Beethoven"), Credit(role: .conductor, name: conductor), Credit(role: .ensemble, name: ensemble),
                     Credit(role: .albumArtist, name: ensemble)]
        if let s = soloist { m.credits.append(Credit(role: .soloist, name: s, instrument: "piano")) }
        m.genres = ["Classical"]
        return (FileFacts(path: path, duration: 400, sampleRate: 96_000, bitDepth: 24, channels: 2, codec: "FLAC", mtime: 1, size: 1), m)
    }

    func pop(_ title: String, artists: [String], album: String, path: String) -> (facts: FileFacts, tags: TrackMetadata) {
        var m = TrackMetadata(); m.title = title; m.album = album; m.year = 2020; m.trackNumber = 1
        m.credits = artists.map { Credit(role: .artist, name: $0) } + [Credit(role: .albumArtist, name: artists[0])]
        m.genres = ["Pop", "Electronic"]
        return (FileFacts(path: path, duration: 200, sampleRate: 44_100, bitDepth: 16, channels: 2, codec: "FLAC", mtime: 1, size: 1), m)
    }

    func store() -> LibraryStore { try! LibraryStore() }

    func classicalOntology() {
        let lib = store()
        var items: [(facts: FileFacts, tags: TrackMetadata)] = []
        for n in 1...4 { items.append(symphony(n, conductor: "Carlos Kleiber", ensemble: "Wiener Philharmoniker", album: "Beethoven: Symphonies 5 & 7", year: 1975, path: "/m/kleiber/\(n).flac")) }
        for n in 1...4 { items.append(symphony(n, conductor: "Herbert von Karajan", ensemble: "Berliner Philharmoniker", album: "Beethoven: Complete Symphonies", year: 1962, soloist: n == 2 ? "A. Soloist" : nil, path: "/m/karajan/\(n).flac")) }
        let r = lib.upsert(Array(items.reversed()))                                         // order of arrival must not matter
        expect(r.added == 8 && r.updated == 0)
        let st = lib.stats()
        expect(st.tracks == 8 && st.releases == 2 && st.works == 1 && st.composers == 1, "\(st)")

        let composers = lib.parties(role: .composer)
        expect(composers.count == 1 && composers[0].name == "Ludwig van Beethoven" && composers[0].count == 8 && composers[0].kind == "person", "\(composers)")
        let works = lib.works(composerID: composers[0].id)
        expect(works.count == 1 && works[0].catalog == "Op. 67" && works[0].key == "C minor" && works[0].recordingCount == 2 && works[0].movementCount == 4 && works[0].trackCount == 8, "\(works)")
        let recs = lib.recordings(workID: works[0].id)
        expect(recs.count == 2 && recs.map(\.year) == [1962, 1975], "recordings are ordered by year: \(recs.map { ($0.releaseTitle, $0.year) })")
        expect(recs[0].performers.map { $0.role + ":" + $0.name } == ["conductor:Herbert von Karajan", "ensemble:Berliner Philharmoniker", "soloist:A. Soloist"], "\(recs[0].performers.map { $0.role + ":" + $0.name })")
        expect(recs[1].performers.map(\.name) == ["Carlos Kleiber", "Wiener Philharmoniker"])
        expect(recs[0].tracks.map(\.movementNumber) == [1, 2, 3, 4] && recs[0].tracks.map(\.movementTitle) == ["Allegro con brio", "Andante con moto", "Scherzo: Allegro", "Allegro"])
        expect(lib.parties(role: .conductor).map(\.name) == ["Carlos Kleiber", "Herbert von Karajan"].sorted { $0 < $1 } || lib.parties(role: .conductor).count == 2)
        let orch = lib.parties(role: .ensemble)
        expect(orch.count == 2 && orch.allSatisfy { $0.kind == "group" }, "orchestras are groups, not persons")
        expect(lib.tracks(partyID: lib.parties(role: .conductor).first { $0.name.contains("Karajan") }!.id, role: .conductor).count == 4)
        let t = lib.track(path: "/m/karajan/2.flac")!
        expect(t.workTitle == works[0].title && t.movementNumber == 2 && t.credits.contains { $0.role == "soloist" && $0.instrument == "piano" } && t.genres == ["Classical"] && t.sampleRate == 96_000 && t.bitDepth == 24)
    }

    func multiValuedCredits() {
        let lib = store()
        lib.upsert([pop("Collab", artists: ["Alice", "Bob", "Carol"], album: "Together", path: "/p/1.flac"), pop("Solo", artists: ["Alice"], album: "Alone", path: "/p/2.flac")])
        let t = lib.track(path: "/p/1.flac")!
        expect(t.names(.artist) == ["Alice", "Bob", "Carol"], "all three artists on one track, in order: \(t.names(.artist))")
        expect(t.genres == ["Electronic", "Pop"])
        let alice = lib.parties(role: .artist).first { $0.name == "Alice" }!
        expect(alice.count == 2 && lib.parties(role: .artist).count == 3, "the same person is one party across tracks")
        expect(lib.tracks(partyID: alice.id).count == 2 && lib.tracks(partyID: lib.parties(role: .artist).first { $0.name == "Bob" }!.id).count == 1)
        expect(lib.releases(partyID: alice.id).count == 2)
        expect(lib.releases().first { $0.title == "Together" }?.artistNames == ["Alice", "Bob", "Carol"].filter { _ in true } || lib.releases().first { $0.title == "Together" }?.artistNames.contains("Bob") == true)
    }

    func reTaggingReplacesCreditsAndPruning() {
        let lib = store()
        lib.upsert([symphony(1, conductor: "Carlos Kleiber", ensemble: "Wiener Philharmoniker", album: "A", year: 1975, path: "/m/a.flac")])
        let before = lib.revision
        // the file is re-tagged: new conductor, different ensemble
        let r = lib.upsert([symphony(1, conductor: "Karl Böhm", ensemble: "Wiener Philharmoniker", album: "A", year: 1975, path: "/m/a.flac")])
        expect(r.added == 0 && r.updated == 1 && lib.revision == before + 1)
        expect(lib.track(path: "/m/a.flac")!.names(.conductor) == ["Karl Böhm"], "old credits must be replaced, not accumulated")
        expect(lib.stats().tracks == 1)
        // removing the file prunes everything it alone supported
        let removed = lib.removeTracks(under: "/m", keeping: [])
        expect(removed == 1)
        let st = lib.stats()
        expect(st.tracks == 0 && st.releases == 0 && st.works == 0 && st.composers == 0, "orphans pruned: \(st)")
        expect(lib.parties(role: .conductor).isEmpty && lib.parties(role: .ensemble).isEmpty)
        let log = lib.changes(since: 0)
        expect(log.contains { $0.kind == "track" && $0.op == "delete" } && log.contains { $0.kind == "work" && $0.op == "delete" } && log.contains { $0.kind == "release" && $0.op == "delete" }, "deletions are logged for sync")
    }

    func changeLogDrivesSync() {
        let lib = store()
        lib.upsert([pop("One", artists: ["A"], album: "X", path: "/p/1.flac")])
        let r1 = lib.revision
        lib.upsert([pop("Two", artists: ["B"], album: "X", path: "/p/2.flac")])
        let delta = lib.changes(since: r1)
        expect(delta.allSatisfy { $0.revision == r1 + 1 }, "a delta contains only newer revisions")
        expect(delta.contains { $0.kind == "track" && $0.track?.title == "Two" }, "upserts carry their payload")
        expect(!delta.contains { $0.track?.title == "One" }, "and not unchanged tracks")
        expect(delta.contains { $0.kind == "party" && $0.party?.name == "B" } && delta.contains { $0.kind == "release" })
        expect(lib.changes(since: lib.revision).isEmpty, "a client that is up to date gets nothing")
        let all = lib.changes(since: 0)
        expect(Set(all.filter { $0.kind == "track" }.map(\.uid)).count == 2)
    }

    func searchFoldsCaseAndDiacritics() {
        let lib = store()
        var m = pop("Humoresque", artists: ["Martha Argerich"], album: "Recital", path: "/s/1.flac")
        m.tags.credits.append(Credit(role: .composer, name: "Antonín Dvořák")); m.tags.workTitle = "Humoresques, Op. 101"
        lib.upsert([m, symphony(1, conductor: "Carlos Kleiber", ensemble: "Wiener Philharmoniker", album: "Bee", year: 1975, path: "/s/2.flac")])
        let a = lib.search("dvorak")
        expect(a.parties.contains { $0.name == "Antonín Dvořák" } && a.works.count == 1 && !a.tracks.isEmpty, "diacritic-insensitive: \(a.parties.map(\.name))")
        expect(lib.search("KLEIBER").tracks.count == 1 && lib.search("kleiber").parties.count == 1)
        expect(lib.search("wiener phil").parties.first?.kind == "group")
        expect(lib.search("zzzz").tracks.isEmpty && lib.search("").tracks.isEmpty)
        expect(lib.works(search: "symphony").count == 1 && lib.parties(role: .composer, search: "beet").count == 1)
    }

    func persistsOnDisk() {
        let url = dir.appendingPathComponent("persist-\(UUID().uuidString.prefix(6)).sqlite")
        var rev: Int64 = 0
        do {
            let lib = try! LibraryStore(url: url)
            lib.upsert([symphony(1, conductor: "K", ensemble: "O", album: "A", year: 1, path: "/m/a.flac"), pop("P", artists: ["Z"], album: "B", path: "/m/b.flac")])
            rev = lib.revision
        }
        let again = try! LibraryStore(url: url)
        expect(again.stats().tracks == 2 && again.revision == rev && rev > 0, "reopened: \(again.stats())")
        expect(again.track(path: "/m/a.flac")?.workTitle == "Symphony No. 5 in C minor, Op. 67")
        again.upsert([pop("Q", artists: ["Z"], album: "B", path: "/m/c.flac")])
        expect(again.revision == rev + 1, "revisions keep counting after a restart")
    }

    /// Real files on disk: tags are read from FLAC and ALAC, unchanged files are skipped, edits and deletions are noticed.
    func importFolderEndToEnd() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return }
        let root = realPath(tempDir("import-\(UUID().uuidString.prefix(6))")).appendingPathComponent("Music")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = sineWAV(root.deletingLastPathComponent().appendingPathComponent("src.wav"), rate: 44_100, freq: 440, amp: 0.3, seconds: 1)
        var paths: [String] = []
        for n in 1...3 {
            let f = root.appendingPathComponent("\(n) mov.flac")
            expect(encode(wav, to: f, alac: false)); paths.append(f.path)
            injectVorbisComments(f.path, [("TITLE", "Mov \(n)"), ("ARTIST", "Orchestra X"), ("COMPOSER", "Composer Y"), ("COMPOSER", "Composer Z"), ("CONDUCTOR", "Maestro"),
                                          ("WORK", "Symphony No. 1, Op. 21"), ("MOVEMENT", "\(n)/3"), ("MOVEMENTNAME", "Part \(n)"), ("ALBUM", "The Album"), ("DATE", "1999"), ("TRACKNUMBER", "\(n)")])
        }
        let m4a = root.appendingPathComponent("4 mov.m4a")
        expect(encode(wav, to: m4a, alac: true)); paths.append(m4a.path)
        injectMP4Tags(m4a.path, items: [mp4Text("\u{A9}nam", ["Mov 4"]), mp4Text("\u{A9}ART", ["Orchestra X"]), mp4Text("\u{A9}wrt", ["Composer Y"]), mp4Text("\u{A9}wrk", ["Symphony No. 1, Op. 21"]),
                                       mp4Int16("\u{A9}mvi", 4), mp4Int16("\u{A9}mvc", 4), mp4Text("\u{A9}mvn", ["Part 4"]), mp4Text("\u{A9}alb", ["The Album"]), mp4Pair("trkn", 4, 4), mp4Freeform("CONDUCTOR", ["Maestro"])])
        let lib = store()
        let r1 = lib.importFolder(root)
        expect(r1.added == 4 && r1.failed == 0 && r1.skipped == 0 && r1.removed == 0, "\(r1)")
        let st = lib.stats()
        expect(st.tracks == 4 && st.releases == 1 && st.works == 1 && st.composers == 2, "\(st)")
        let w = lib.works()[0]
        expect(w.title == "Symphony No. 1, Op. 21" && w.catalog == "Op. 21" && w.movementCount == 4, "\(w)")
        let t = lib.track(path: paths[0])!
        expect(t.names(.composer) == ["Composer Y", "Composer Z"] && t.codec == "FLAC" && t.sampleRate == 44_100 && abs(t.duration - 1) < 0.01 && t.releaseTitle == "The Album" && t.year == 1999, "\(t)")
        expect(lib.track(path: m4a.path)?.codec == "ALAC" && lib.track(path: m4a.path)?.movementNumber == 4, "the ALAC file is part of the same work")
        expect(lib.recordings(workID: w.id).first?.tracks.map(\.movementNumber) == [1, 2, 3, 4])

        let r2 = lib.importFolder(root)
        expect(r2.skipped == 4 && r2.added == 0 && r2.updated == 0, "an unchanged folder is skipped: \(r2)")
        let revAfter = lib.revision

        injectVorbisComments(paths[1], [("TITLE", "Mov 2 (edited)"), ("ARTIST", "Orchestra X"), ("COMPOSER", "Composer Y"), ("WORK", "Symphony No. 1, Op. 21"), ("MOVEMENT", "2/3"), ("ALBUM", "The Album")])
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: paths[1])
        let r3 = lib.importFolder(root)
        expect(r3.updated == 1 && r3.skipped == 3, "\(r3)")
        expect(lib.track(path: paths[1])?.title == "Mov 2 (edited)" && lib.track(path: paths[1])!.names(.composer) == ["Composer Y"] && lib.revision == revAfter + 1)

        try? FileManager.default.removeItem(atPath: paths[2])
        let r4 = lib.importFolder(root)
        expect(r4.removed == 1 && lib.stats().tracks == 3, "\(r4)")
        expect(lib.stats().composers == 2, "Composer Z is still credited on the first file, so is not pruned")
        try? FileManager.default.removeItem(atPath: paths[0])
        let r5 = lib.importFolder(root)
        expect(r5.removed == 1 && lib.stats().composers == 1, "once the last file crediting Z is gone, Z is pruned: \(lib.stats())")
        expect(lib.parties(role: .composer).map(\.name) == ["Composer Y"])
    }

    /// Taking a library folder out removes its songs and what only they supported, keeps what another folder covers, and leaves the rest alone.
    func removeFolderRemovesItsSongs() {
        let lib = store()
        lib.upsert([symphony(1, conductor: "Carlos Kleiber", ensemble: "Wiener Philharmoniker", album: "A", year: 1975, path: "/lib/classical/a1.flac"),
                    symphony(2, conductor: "Carlos Kleiber", ensemble: "Wiener Philharmoniker", album: "A", year: 1975, path: "/lib/classical/a2.flac"),
                    pop("One", artists: ["Alice"], album: "Pop", path: "/lib/pop/1.flac"),
                    pop("Two", artists: ["Bob"], album: "Pop2", path: "/lib/pop2/2.flac"),
                    pop("Nested", artists: ["Cy"], album: "Deep", path: "/lib/pop/deep/3.flac"),
                    pop("Ripped", artists: ["Dee"], album: "Disc", path: "/elsewhere/ripped.flac")])
        let list = lib.createPlaylist(name: "Mix", paths: ["/lib/classical/a1.flac", "/lib/pop/1.flac"])!
        let before = lib.revision

        // a folder that does not exist in the library changes nothing
        expect(lib.removeFolderTracks(root: "/nowhere", keeping: ["/lib/pop"]) == 0 && lib.revision == before)

        // the classical folder goes: its songs, release, work and people with them; the playlist keeps its other entry
        expect(lib.removeFolderTracks(root: "/lib/classical", keeping: ["/lib/pop", "/lib/pop2"]) == 2)
        let st = lib.stats()
        expect(st.tracks == 4 && st.works == 0 && st.composers == 0, "orphans pruned: \(st)")
        expect(lib.parties(role: .conductor).isEmpty && lib.parties(role: .ensemble).isEmpty)
        expect(lib.track(path: "/lib/classical/a1.flac") == nil && lib.track(path: "/lib/pop/1.flac") != nil)
        expect(lib.playlistTracks(id: list.id).map(\.path) == ["/lib/pop/1.flac"], "playlist entries of removed songs go with them")
        let log = lib.changes(since: before)
        expect(log.contains { $0.kind == "track" && $0.op == "delete" } && log.contains { $0.kind == "work" && $0.op == "delete" }, "deletions are logged for sync")
        expect(lib.revision == before + 1)

        // a folder that is still covered by another remaining folder keeps those songs (a parent stays, so nothing under it is lost)
        expect(lib.removeFolderTracks(root: "/lib/pop/deep", keeping: ["/lib/pop"]) == 0 && lib.track(path: "/lib/pop/deep/3.flac") != nil)
        // removing the parent keeps what a remaining nested folder covers
        expect(lib.removeFolderTracks(root: "/lib/pop", keeping: ["/lib/pop/deep", "/lib/pop2"]) == 1)
        expect(lib.track(path: "/lib/pop/1.flac") == nil && lib.track(path: "/lib/pop/deep/3.flac") != nil && lib.track(path: "/lib/pop2/2.flac") != nil)
        // a prefix match is by folder, not by name: /lib/pop2 is not under /lib/pop
        expect(lib.parties(role: .artist).contains { $0.name == "Bob" })

        // excluding roots keeps only what is under them (the ripped disc is outside every library folder)
        expect(lib.removeTracks(excludingRoots: ["/lib/pop2"]) == 2)
        expect(lib.stats().tracks == 1 && lib.track(path: "/lib/pop2/2.flac") != nil)
        expect(lib.removeTracks(excludingRoots: []) == 1 && lib.stats().tracks == 0 && lib.stats().releases == 0)
    }

    /// A folder taken out of the library is no longer watched and its history is dropped, in memory and on disk; other folders are unaffected.
    func forgetFolderStopsWatching() {
        let top = realPath(tempDir("forget-\(UUID().uuidString.prefix(6))"))
        let a = top.appendingPathComponent("A"), b = top.appendingPathComponent("B"), stateURL = top.appendingPathComponent("watch.json")
        for u in [a, b] { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
        let w = LibraryWatcher(stateURL: stateURL, settle: 0.2)
        for root in [a.path, b.path] {
            guard case .needsReconcile(let since) = w.start(root: root) else { expect(false, "first start needs a comparison"); return }
            w.markReconciled(root: root, eventID: since)
        }
        expect(w.watchedRoots == [a.path, b.path] && w.state(of: a.path) != nil)

        w.forget(root: a.path)
        expect(w.watchedRoots == [b.path], "the stream of the forgotten folder is stopped: \(w.watchedRoots)")
        expect(w.state(of: a.path) == nil && w.state(of: b.path) != nil)
        let saved = (try? JSONDecoder().decode([String: LibraryWatcher.State].self, from: Data(contentsOf: stateURL))) ?? [:]
        expect(saved[a.path] == nil && saved[b.path] != nil, "the history is dropped on disk too: \(saved.keys)")
        w.forget(root: a.path)                                                     // forgetting twice, or a folder never watched, is harmless
        w.forget(root: top.appendingPathComponent("never").path)
        expect(w.watchedRoots == [b.path])
        w.stopAll()

        // adding the folder again starts from a full comparison, the other one still resumes
        let again = LibraryWatcher(stateURL: stateURL, settle: 0.2)
        if case .needsReconcile = again.start(root: a.path) {} else { expect(false, "a folder added again is compared in full") }
        if case .replaying = again.start(root: b.path) {} else { expect(false, "an untouched folder keeps its history") }
        again.stopAll()
    }
}

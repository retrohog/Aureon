import Foundation

struct CollectionTests {
    private func song(_ title: String, artist: String, album: String, path: String, albumArtist: String? = nil, composer: String? = nil, rate: Double = 44_100, bits: Int = 16, size: Int64 = 1) -> (facts: FileFacts, tags: TrackMetadata) {
        var m = TrackMetadata(); m.title = title; m.album = album; m.year = 2020
        m.credits = [Credit(role: .artist, name: artist), Credit(role: .albumArtist, name: albumArtist ?? artist)]
        if let c = composer { m.credits.append(Credit(role: .composer, name: c)) }
        return (FileFacts(path: path, duration: 200, sampleRate: rate, bitDepth: bits, channels: 2, codec: "FLAC", mtime: 1, size: size), m)
    }

    func featuringIsSplit() {
        let a = TagInterpreter.splitFeaturing("Drake feat. Rihanna & Kanye West")
        expect(a.primary == "Drake" && a.featured == ["Rihanna", "Kanye West"], "\(a)")
        let b = TagInterpreter.splitFeaturing("Song Name (ft. Someone)")
        expect(b.primary == "Song Name" && b.featured == ["Someone"], "\(b)")
        let c = TagInterpreter.splitFeaturing("Left Behind")
        expect(c.primary == "Left Behind" && c.featured.isEmpty, "words that merely contain 'ft' are left alone: \(c)")
        expect(TagInterpreter.splitFeaturing("Simon & Garfunkel").featured.isEmpty, "duos are not guests")
        expect(TagInterpreter.splitFeaturing("A Featuring B").featured == ["B"])
        // through the tag interpreter
        var raw = RawTags()
        raw.add("ARTIST", "Aurora Lane feat. Mara Voss"); raw.add("ALBUMARTIST", "Aurora Lane"); raw.add("TITLE", "Glow"); raw.add("ALBUM", "Neon")
        let m = TagInterpreter.interpret(raw)
        expect(m.credits(.artist).map(\.name) == ["Aurora Lane"] && m.credits(.featured).map(\.name) == ["Mara Voss"], "\(m.credits)")
        var raw2 = RawTags(); raw2.add("ARTIST", "Aurora Lane"); raw2.add("TITLE", "Glow (feat. Ines Calder)")
        expect(TagInterpreter.interpret(raw2).credits(.featured).map(\.name) == ["Ines Calder"], "a guest named only in the title is found")
    }

    func composersAreSplitCleanly() {
        expect(TagInterpreter.splitPeople("John Lennon, Paul McCartney") == ["John Lennon", "Paul McCartney"])
        expect(TagInterpreter.splitPeople("Beethoven, Ludwig van") == ["Beethoven, Ludwig van"], "surname-first stays one name")
        expect(TagInterpreter.splitPeople("Max Martin & Shellback; Savan Kotecha") == ["Max Martin", "Shellback", "Savan Kotecha"])
        expect(TagInterpreter.splitPeople("Johann Sebastian Bach") == ["Johann Sebastian Bach"])
        expect(TagInterpreter.splitPeople("Earth, Wind & Fire") == ["Earth, Wind & Fire"], "a band name with commas stays whole")
    }

    func guestsLiveUnderTheirHostArtist() {
        let lib = try! LibraryStore()
        lib.upsert([song("One", artist: "Aurora Lane", album: "Neon", path: "/a/1.flac"),
                    song("Two", artist: "Aurora Lane", album: "Neon", path: "/a/2.flac")])
        // the second import of the same album arrives with a guest on one track: the way many taggers write it
        var guest = song("Three", artist: "Aurora Lane feat. Mara Voss", album: "Neon", path: "/a/3.flac", albumArtist: "Aurora Lane feat. Mara Voss")
        var raw = RawTags(); raw.add("ARTIST", "Aurora Lane feat. Mara Voss"); raw.add("ALBUMARTIST", "Aurora Lane feat. Mara Voss"); raw.add("TITLE", "Three"); raw.add("ALBUM", "Neon")
        guest.tags = TagInterpreter.interpret(raw); guest.tags.year = 2020
        lib.upsert([guest])
        expect(lib.stats().releases == 1, "one album, not two: \(lib.stats().releases)")
        let artists = lib.parties(role: .artist)
        expect(artists.map(\.name).sorted() == ["Aurora Lane", "Mara Voss"], "the guest is listed once, the host has no variant: \(artists.map(\.name))")
        let host = artists.first { $0.name == "Aurora Lane" }!, mara = artists.first { $0.name == "Mara Voss" }!
        expect(lib.tracks(partyID: host.id, role: .artist).count == 3 && lib.releases(partyID: host.id).count == 1, "all three tracks under the host")
        expect(lib.tracks(partyID: mara.id, role: .artist).map(\.title) == ["Three"], "the guest sees the track she appears on")
        expect(lib.releases(partyID: mara.id).map(\.title) == ["Neon"], "and its album")
        expect(lib.releases()[0].artistNames == ["Aurora Lane"], "the album belongs to the host: \(lib.releases()[0].artistNames)")
        expect(lib.track(path: "/a/3.flac")!.artistLine == "Aurora Lane feat. Mara Voss")
    }

    func existingLibrariesAreTidied() {
        let lib = try! LibraryStore()
        // an older import left the "feat." names as artists of their own
        lib.upsert([song("One", artist: "Aurora Lane", album: "Neon", path: "/b/1.flac"),
                    song("Two", artist: "Aurora Lane feat. Mara Voss", album: "Neon", path: "/b/2.flac", albumArtist: "Aurora Lane feat. Mara Voss"),
                    song("Three", artist: "Aurora Lane ft. Ines Calder", album: "Other", path: "/b/3.flac")])
        // (the new interpreter is not involved: these credits are literal)
        expect(lib.stats().releases == 3 && lib.parties(role: .artist).count == 3, "before: \(lib.stats().releases) albums, \(lib.parties(role: .artist).map(\.name))")
        let n = lib.normalizeArtists()
        expect(n == 2, "two names folded: \(n)")
        expect(lib.stats().releases == 2, "the Neon album is whole again: \(lib.stats().releases)")
        expect(lib.parties(role: .artist).map(\.name).sorted() == ["Aurora Lane", "Ines Calder", "Mara Voss"], "\(lib.parties(role: .artist).map(\.name))")
        let host = lib.parties(role: .artist).first { $0.name == "Aurora Lane" }!
        expect(lib.tracks(partyID: host.id, role: .artist).count == 3)
        expect(lib.normalizeArtists() == 0, "running it again changes nothing")
    }

    func collaborationsFoldIntoTheKnownArtist() {
        let lib = try! LibraryStore()
        lib.upsert([song("Solo", artist: "Badshah", album: "One", path: "/k/1.flac"),
                    song("Duet", artist: "Badshah, Aastha Gill", album: "Singles", path: "/k/2.flac"),
                    song("Trio", artist: "Badshah, Karan Aujla, Hiten", album: "Trio", path: "/k/3.flac"),
                    song("Mix", artist: "Badshah & Sharvi Yadav", album: "Mix", path: "/k/4.flac"),
                    song("Band", artist: "Earth, Wind & Fire", album: "Hits", path: "/k/5.flac"),
                    song("Rap", artist: "Tyler, The Creator", album: "Igor", path: "/k/6.flac"),
                    song("Other", artist: "Arijit Singh, Pritam", album: "Film", path: "/k/7.flac"),
                    song("Own", artist: "Arijit Singh", album: "Own", path: "/k/8.flac")])
        let n = lib.normalizeArtists()
        expect(n == 4, "four collaboration names folded: \(n)")
        let names = lib.parties(role: .artist).map(\.name).sorted()
        expect(names == ["Aastha Gill", "Arijit Singh", "Badshah", "Earth, Wind & Fire", "Hiten", "Karan Aujla", "Pritam", "Sharvi Yadav", "Tyler, The Creator"], "\(names)")
        let badshah = lib.parties(role: .artist).first { $0.name == "Badshah" }!
        expect(lib.tracks(partyID: badshah.id, role: .artist).count == 4, "all four Badshah songs are under him")
        expect(lib.track(path: "/k/3.flac")!.artistLine == "Badshah feat. Karan Aujla, Hiten", lib.track(path: "/k/3.flac")!.artistLine)
        let aa = lib.parties(role: .artist).first { $0.name == "Aastha Gill" }!
        expect(lib.tracks(partyID: aa.id, role: .artist).map(\.title) == ["Duet"], "the guest still finds her song")
        expect(lib.normalizeArtists() == 0)
    }

    func likesAndPlaylists() {
        let lib = try! LibraryStore()
        lib.upsert((1...5).map { song("Song \($0)", artist: "Alice", album: "A", path: "/c/\($0).flac") })
        expect(lib.likedPaths().isEmpty)
        expect(lib.setLiked(paths: ["/c/2.flac", "/c/4.flac", "/nonexistent"], liked: true) == 2 && lib.likedPaths() == ["/c/2.flac", "/c/4.flac"])
        expect(lib.setLiked(paths: ["/c/2.flac"], liked: true) == 0, "liking twice changes nothing")
        expect(lib.likedTracks().map(\.title) == ["Song 2", "Song 4"] || lib.likedTracks().count == 2)
        expect(lib.track(path: "/c/2.flac")!.isLiked && !lib.track(path: "/c/1.flac")!.isLiked)
        lib.setLiked(paths: ["/c/2.flac"], liked: false)
        expect(lib.likedPaths() == ["/c/4.flac"])

        let p = lib.createPlaylist(name: "  Road trip  ", paths: ["/c/3.flac", "/c/1.flac", "/c/3.flac"])!
        expect(p.name == "Road trip" && p.trackCount == 2, "trimmed name, duplicates ignored: \(p)")
        expect(lib.createPlaylist(name: "   ") == nil)
        expect(lib.playlistTracks(id: p.id).map(\.title) == ["Song 3", "Song 1"], "keeps the order it was given")
        expect(lib.addToPlaylist(id: p.id, paths: ["/c/5.flac", "/c/1.flac"]) == 1)
        lib.movePlaylistEntries(id: p.id, from: IndexSet(integer: 2), to: 0)
        expect(lib.playlistTracks(id: p.id).map(\.title) == ["Song 5", "Song 3", "Song 1"], "\(lib.playlistTracks(id: p.id).map(\.title))")
        lib.removeFromPlaylist(id: p.id, paths: ["/c/3.flac"])
        expect(lib.playlistTracks(id: p.id).map(\.title) == ["Song 5", "Song 1"])
        expect(lib.playlistIDs(containing: "/c/1.flac") == [p.id] && lib.playlistIDs(containing: "/c/2.flac").isEmpty)
        lib.renamePlaylist(id: p.id, name: "Drive")
        expect(lib.playlists().first?.name == "Drive" && lib.playlists().first?.trackCount == 2)
        let q = lib.createPlaylist(name: "Empty")!
        expect(lib.playlists().count == 2 && lib.playlistTracks(id: q.id).isEmpty)
        // removing a file from the library removes it from playlists as well
        lib.removeTracks(under: "/c", keeping: ["/c/5.flac"])
        expect(lib.playlistTracks(id: p.id).map(\.title) == ["Song 5"] && lib.playlists().first { $0.id == p.id }?.trackCount == 1, "\(lib.playlistTracks(id: p.id).map(\.title))")
        lib.deletePlaylist(id: p.id)
        expect(lib.playlists().map(\.name) == ["Empty"] && lib.stats().tracks == 1, "deleting a playlist never deletes songs")
        lib.recordPlay(path: "/c/5.flac"); lib.recordPlay(path: "/c/5.flac")
        let t = lib.track(path: "/c/5.flac")!
        expect(t.playCount == 2 && t.lastPlayedAt != nil)
    }
}

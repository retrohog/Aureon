import Foundation

struct DuplicateTests {
    private func t(_ id: String, _ title: String, artist: String, album: String = "A", rid: String? = nil, dur: Double = 200, codec: String = "FLAC", bits: Int = 16, rate: Double = 44_100, size: Int64 = 30_000_000) -> TrackDTO {
        TrackDTO(id: id, path: "/m/\(id).flac", title: title, trackNumber: nil, discNumber: nil, duration: dur, codec: codec, sampleRate: rate, bitDepth: bits, channels: 2, year: nil,
                 releaseID: rid ?? album, releaseTitle: album, workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil,
                 credits: [CreditDTO(role: "artist", name: artist, instrument: nil, partyID: artist)], genres: [], mbRecordingID: nil, fileSize: size)
    }

    func titlesNormalise() {
        expect(DuplicateFinder.normalizedTitle("Glow (feat. Mara Voss)") == "glow")
        expect(DuplicateFinder.normalizedTitle("Glow - Remastered 2011") == "glow")
        expect(DuplicateFinder.normalizedTitle("Glow (2011 Remaster)") == "glow")
        expect(DuplicateFinder.normalizedTitle("  GLOW!! ") == "glow")
        expect(DuplicateFinder.normalizedTitle("Glow (Live)") == "glow live", "a live take is a different recording")
        expect(DuplicateFinder.normalizedTitle("Glow (Acoustic)") != DuplicateFinder.normalizedTitle("Glow"))
        expect(DuplicateFinder.normalizedTitle("Café") == "cafe")
        expect(DuplicateFinder.normalizedEdition("Neon (Deluxe Edition)") == "neon")
    }

    func songDuplicates() {
        let lo = t("1", "Glow", artist: "Aurora Lane", album: "Neon", rid: "r1")
        let hi = t("2", "Glow (feat. Mara Voss)", artist: "Aurora Lane", album: "Singles", rid: "r2", dur: 200.4, bits: 24, rate: 96_000, size: 60_000_000)
        let mp3 = t("3", "Glow", artist: "Aurora Lane", album: "Mixtape", rid: "r3", dur: 199.8, codec: "MP3 (lossy)", bits: 16, size: 8_000_000)
        let live = t("4", "Glow", artist: "Aurora Lane", album: "Live", rid: "r4", dur: 274)
        let other = t("5", "Glow", artist: "Someone Else", album: "Else", rid: "r5")
        let g = DuplicateFinder.songGroups([lo, hi, mp3, live, other])
        expect(g.count == 1, "one group: \(g.count)")
        guard let first = g.first else { return }
        expect(first.items.map(\.track.id) == ["2", "1", "3"], "best first: \(first.items.map(\.track.id))")
        expect(first.keepReason.contains("Higher resolution"), "\(first.keepReason)")
        expect(first.removable.map(\.track.id) == ["1", "3"])
        expect(!first.items.contains { $0.track.id == "4" || $0.track.id == "5" }, "a live version and another artist's song are not duplicates")
        expect(DuplicateFinder.songGroups([lo, mp3]).first?.keepReason.contains("Lossless") == true, "lossless beats lossy")
        expect(DuplicateFinder.songGroups([lo]).isEmpty && DuplicateFinder.songGroups([]).isEmpty)
        // the same group is recognised again, and can be dismissed for good
        let again = DuplicateFinder.songGroups([lo, hi, mp3])
        expect(again.first?.id == first.id)
        expect(DuplicateFinder.songGroups([lo, hi, mp3], ignoring: [first.id]).isEmpty, "ignored groups stay hidden")
    }

    func albumDuplicates() {
        var cd: [TrackDTO] = [], hires: [TrackDTO] = []
        for i in 1...6 {
            cd.append(t("c\(i)", "Song \(i)", artist: "Aurora Lane", album: "Neon", rid: "cd"))
            hires.append(t("h\(i)", "Song \(i)", artist: "Aurora Lane", album: "Neon (Deluxe Edition)", rid: "hr", bits: 24, rate: 96_000, size: 70_000_000))
        }
        let unrelated = (1...4).map { t("u\($0)", "Track \($0)", artist: "Aurora Lane", album: "Paper", rid: "pp") }
        let groups = DuplicateFinder.albumGroups(cd + hires + unrelated)
        expect(groups.count == 1 && groups[0].kind == .album, "\(groups.count)")
        guard let g = groups.first else { return }
        expect(g.items.count == 2 && g.items[0].track.id.hasPrefix("h"), "the hi-res copy is kept")
        expect(g.albumCopies[0].count == 6 && g.albumCopies[1].count == 6)
        expect(g.reason.contains("6 songs in common"), g.reason)
        let all = DuplicateFinder.all(cd + hires + unrelated)
        expect(all.count == 1, "songs inside a duplicate album are not listed again: \(all.count)")
        expect(Set(DuplicateFinder.removalPaths(all)) == Set(cd.map(\.path)), "the CD copy's six files would go")
        // a different album by the same artist sharing one title is not a duplicate
        let half = [t("x1", "Song 1", artist: "Aurora Lane", album: "Neon", rid: "other"), t("x2", "Different", artist: "Aurora Lane", album: "Neon", rid: "other")]
        expect(DuplicateFinder.albumGroups(cd + half).isEmpty, "too little in common")
    }

    func removalFromTheLibrary() {
        let lib = try! LibraryStore()
        func item(_ n: Int, bits: Int) -> (facts: FileFacts, tags: TrackMetadata) {
            var m = TrackMetadata(); m.title = "Glow"; m.album = "A\(n)"; m.credits = [Credit(role: .artist, name: "Aurora Lane"), Credit(role: .albumArtist, name: "Aurora Lane")]
            return (FileFacts(path: "/d/\(n).flac", duration: 200, sampleRate: 44_100, bitDepth: bits, channels: 2, codec: "FLAC", mtime: 1, size: Int64(1_000_000 * bits)), m)
        }
        lib.upsert([item(1, bits: 16), item(2, bits: 24)])
        let groups = DuplicateFinder.songGroups(lib.allTracks())
        expect(groups.count == 1 && groups[0].keep.track.path == "/d/2.flac", "the 24-bit copy is kept: \(groups.map { $0.keep.track.path })")
        let n = lib.removeTracks(paths: DuplicateFinder.removalPaths(groups))
        expect(n == 1 && lib.stats().tracks == 1 && lib.stats().releases == 1, "\(lib.stats())")
        expect(lib.track(path: "/d/1.flac") == nil && lib.track(path: "/d/2.flac") != nil)
    }
}

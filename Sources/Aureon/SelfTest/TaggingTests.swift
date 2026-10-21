import Foundation

struct TagParserTests {
    let dir = tempDir("tags")

    func parse(_ c: [(String, String)]) -> RawTags { VorbisTags.parseComments(vorbisBlock(c)) }

    func vorbisKeepsEveryValueInOrder() {
        let t = parse([("ARTIST", "Alice"), ("artist", "Bob"), ("Artist", "Alice"), ("TITLE", "Song"), ("MUSICBRAINZ_ARTISTID", "id-a"), ("MUSICBRAINZ_ARTISTID", "id-b"), ("EMPTY", "  "), ("METADATA_BLOCK_PICTURE", "xxxx")])
        expect(t.values["ARTIST"] == ["Alice", "Bob", "Alice"], "\(String(describing: t.values["ARTIST"]))")
        expect(t.all("ARTIST") == ["Alice", "Bob"], "all() de-duplicates")
        expect(t.first("title") == "Song" && t.first("MUSICBRAINZ_ARTISTID") == "id-a" && t.all("MusicBrainz Artist Id") == ["id-a", "id-b"], "keys are case/space/underscore-insensitive")
        expect(t.values["EMPTY"] == nil && t.values["METADATABLOCKPICTURE"] == nil, "blank values and embedded pictures are ignored")
        expect(VorbisTags.parseComments(Data([1, 2, 3])).isEmpty, "garbage must not crash")
    }

    func mp4AtomsAndFreeformTags() {
        let moov = mp4Box("moov", mp4Tags([
            mp4Text("\u{A9}nam", ["Allegro con brio"]), mp4Text("\u{A9}ART", ["Carlos Kleiber", "Wiener Philharmoniker"]), mp4Text("\u{A9}wrt", ["Beethoven"]),
            mp4Text("\u{A9}wrk", ["Symphony No. 5"]), mp4Text("\u{A9}mvn", ["Allegro con brio"]), mp4Int16("\u{A9}mvi", 1), mp4Int16("\u{A9}mvc", 4),
            mp4Pair("trkn", 3, 12), mp4Pair("disk", 1, 2),
            mp4Freeform("CONDUCTOR", ["Carlos Kleiber"]), mp4Freeform("PERFORMER", ["Anne-Sophie Mutter (violin)", "Yo-Yo Ma (cello)"]),
            mp4Freeform("MusicBrainz Track Id", ["abc-123"]), mp4Text("\u{A9}gen", ["Classical"]),
        ]))
        let t = MP4Tags.parse(mp4Box("ftyp", Data("M4A ".utf8) + be32(0)) + moov)
        expect(t.first("TITLE") == "Allegro con brio" && t.all("ARTIST") == ["Carlos Kleiber", "Wiener Philharmoniker"], "multi-data atom keeps both values")
        expect(t.first("WORK") == "Symphony No. 5" && t.first("MOVEMENTNAME") == "Allegro con brio" && t.first("MOVEMENT") == "1" && t.first("MOVEMENTTOTAL") == "4", "classical atoms")
        expect(t.first("TRACKNUMBER") == "3" && t.first("TRACKTOTAL") == "12" && t.first("DISCNUMBER") == "1" && t.first("DISCTOTAL") == "2", "trkn/disk")
        expect(t.all("PERFORMER") == ["Anne-Sophie Mutter (violin)", "Yo-Yo Ma (cello)"] && t.first("CONDUCTOR") == "Carlos Kleiber", "freeform atoms")
        expect(t.first("MUSICBRAINZ_TRACKID") == "abc-123", "freeform names normalise like Vorbis keys")
        expect(MP4Tags.parse(Data(count: 64)).isEmpty && MP4Tags.parse(Data([0, 0, 0, 12, 0x6d, 0x6f, 0x6f, 0x76])).isEmpty, "garbage must not crash")
    }

    func realFLACWithInjectedTagsStillDecodesIdentically() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return }
        let wav = sineWAV(dir.appendingPathComponent("t.wav"), rate: 44_100, freq: 440, amp: 0.4, seconds: 1)
        let flac = dir.appendingPathComponent("t.flac")
        expect(encode(wav, to: flac, alac: false))
        let before = readAll(try! LosslessFile(path: flac.path))
        injectVorbisComments(flac.path, [("TITLE", "Test"), ("ARTIST", "A"), ("ARTIST", "B"), ("COMPOSER", "C"), ("WORK", "W"), ("MOVEMENT", "2/3")])
        let t = TagReader.read(path: flac.path)
        expect(t.all("ARTIST") == ["A", "B"] && t.first("COMPOSER") == "C" && t.first("MOVEMENT") == "2/3")
        expect(readAll(try! LosslessFile(path: flac.path)) == before, "tag injection must not disturb the audio")
    }

    func realALACWithInjectedAtomsStillDecodesIdentically() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return }
        let wav = sineWAV(dir.appendingPathComponent("a.wav"), rate: 48_000, freq: 330, amp: 0.4, seconds: 1)
        let m4a = dir.appendingPathComponent("a.m4a")
        expect(encode(wav, to: m4a, alac: true))
        let before = readAll(try! LosslessFile(path: m4a.path))
        expect(before.count > 0 && TagReader.read(path: m4a.path).first("TITLE") == nil, "a fresh afconvert file has no title")
        injectMP4Tags(m4a.path, items: [mp4Text("\u{A9}nam", ["Andante"]), mp4Text("\u{A9}ART", ["X", "Y"]), mp4Text("\u{A9}wrk", ["Work"]), mp4Int16("\u{A9}mvi", 2), mp4Freeform("ENSEMBLE", ["Orch"])])
        let t = TagReader.read(path: m4a.path)
        expect(t.all("ARTIST") == ["X", "Y"] && t.first("WORK") == "Work" && t.first("MOVEMENT") == "2" && t.first("ENSEMBLE") == "Orch", "\(t.values)")
        let after = try? LosslessFile(path: m4a.path)
        expect(after != nil && readAll(after!) == before, "ALAC must still decode bit-identically after the moov box grew")
    }
}

struct TagInterpreterTests {
    func tags(_ c: [(String, String)]) -> TrackMetadata { TagInterpreter.interpret(VorbisTags.parseComments(vorbisBlock(c))) }

    func multipleArtistsAreSplitSafely() {
        let m = tags([("ARTIST", "Alice; Bob"), ("ARTIST", "Carol"), ("ALBUMARTIST", "AC/DC"), ("COMPOSER", "Earth, Wind & Fire"), ("COMPOSER", "Lennon / McCartney")])
        expect(m.credits(.artist).map(\.name) == ["Alice", "Bob", "Carol"], "\(m.credits(.artist).map(\.name))")
        expect(m.credits(.albumArtist).map(\.name) == ["AC/DC"], "a slash without spaces is part of the name")
        expect(m.credits(.composer).map(\.name) == ["Earth, Wind & Fire", "Lennon", "McCartney"], "\(m.credits(.composer).map(\.name))")
        let p = tags([("ARTIST", "Alice"), ("ARTIST", "Bob"), ("ARTISTS", "Alice"), ("ARTISTS", "Bob"), ("MUSICBRAINZ_ARTISTID", "ida"), ("MUSICBRAINZ_ARTISTID", "idb"), ("ARTISTSORT", "A"), ("ARTISTSORT", "B")])
        expect(p.credits(.artist).map { $0.mbid ?? "" } == ["ida", "idb"] && p.credits(.artist).map { $0.sortName ?? "" } == ["A", "B"], "parallel MBID/sort lists")
    }

    func fullClassicalTags() {
        let m = tags([("TITLE", "I. Allegro con brio"), ("COMPOSER", "Ludwig van Beethoven"), ("CONDUCTOR", "Carlos Kleiber"), ("ENSEMBLE", "Wiener Philharmoniker"),
                      ("PERFORMER", "Anne-Sophie Mutter (violin)"), ("PERFORMER", "Berliner Philharmoniker (orchestra)"), ("PERFORMER", "Herbert von Karajan (conductor)"),
                      ("WORK", "Symphony No. 5 in C minor, Op. 67"), ("MOVEMENTNAME", "Allegro con brio"), ("MOVEMENT", "1/4"), ("KEY", "C minor"),
                      ("TRACKNUMBER", "3/12"), ("DISCNUMBER", "1/2"), ("DATE", "1975-05-03"), ("GENRE", "Classical"), ("GENRE", "Orchestral"),
                      ("ALBUM", "Beethoven: Symphonies 5 & 7"), ("MUSICBRAINZ_WORKID", "w-1")])
        expect(m.workTitle == "Symphony No. 5 in C minor, Op. 67" && m.catalog == "Op. 67" && m.key == "C minor" && !m.workInferred)
        expect(m.movementNumber == 1 && m.movementTotal == 4 && m.movementTitle == "Allegro con brio")
        expect(m.trackNumber == 3 && m.trackTotal == 12 && m.discNumber == 1 && m.discTotal == 2 && m.year == 1975 && m.genres == ["Classical", "Orchestral"])
        expect(m.credits(.conductor).map(\.name) == ["Carlos Kleiber", "Herbert von Karajan"], "conductor tag plus a PERFORMER (conductor): \(m.credits(.conductor).map(\.name))")
        expect(m.credits(.ensemble).map(\.name) == ["Wiener Philharmoniker", "Berliner Philharmoniker"], "\(m.credits(.ensemble).map(\.name))")
        expect(m.credits(.performer).map { "\($0.name)|\($0.instrument ?? "")" } == ["Anne-Sophie Mutter|violin"])
        expect(m.mbWorkID == "w-1" && m.isClassical)
    }

    func workAndMovementAreInferredConservatively() {
        let a = tags([("TITLE", "Symphony No. 5 in C minor, Op. 67: II. Andante con moto"), ("COMPOSER", "Beethoven")])
        expect(a.workTitle == "Symphony No. 5 in C minor, Op. 67" && a.workInferred && a.movementNumber == 2 && a.movementTitle == "Andante con moto" && a.catalog == "Op. 67", "\(String(describing: a.workTitle)) / \(String(describing: a.movementTitle))")
        let b = tags([("TITLE", "Mad World: Remastered"), ("ARTIST", "Gary Jules")])
        expect(b.workTitle == nil, "no composer: a pop title with a colon is not a work")
        let c = tags([("TITLE", "Cello Suite No. 1, BWV 1007: Prélude"), ("COMPOSER", "J.S. Bach")])
        expect(c.workTitle == "Cello Suite No. 1, BWV 1007" && c.movementTitle == "Prélude" && c.catalog == "BWV 1007")
        let d = tags([("TITLE", "Allegro"), ("GROUPING", "Piano Concerto No. 1"), ("MOVEMENT", "1")])
        expect(d.workTitle == "Piano Concerto No. 1", "GROUPING is the work when movement tags are present")
    }

    func catalogueNumbers() {
        let cases: [(String, String?)] = [
            ("Brandenburg Concerto No. 3 in G major, BWV 1048", "BWV 1048"), ("Piano Sonata No. 14 in A major, K. 331", "K. 331"), ("Symphony in C major, D. 944", "D. 944"),
            ("Piano Concerto No. 2 in C minor, Op.18", "Op. 18"), ("Sonata in B flat, Op. posth. 960", "Op. posth. 960"), ("Piano Sonata in C major, Hob. XVI:50", "Hob. XVI:50"),
            ("Concerto in D major, RV 93", "RV 93"), ("Messiah, HWV 56", "HWV 56"), ("Piano Sonata No. 32, Opus 111", "Op. 111"), ("Yesterday", nil), ("Track 5 of 10", nil), ("Kind of Blue", nil),
        ]
        for (text, want) in cases { expect(CatalogParser.extract(from: text) == want, "\"\(text)\" → \(String(describing: CatalogParser.extract(from: text))), expected \(String(describing: want))") }
    }

    func romanNumeralsAndLeadingMovements() {
        expect(["I": 1, "IV": 4, "IX": 9, "XIV": 14, "XL": 40, "MMM": nil].allSatisfy { TagInterpreter.roman($0.key) == $0.value })
        expect(TagInterpreter.leadingMovement("II. Andante")?.0 == 2 && TagInterpreter.leadingMovement("II. Andante")?.1 == "Andante")
        expect(TagInterpreter.leadingMovement("3 - Scherzo")?.0 == 3 && TagInterpreter.leadingMovement("IV Finale") == nil, "a roman numeral needs a separator")
        expect(TagInterpreter.leadingMovement("Hello") == nil)
    }

    func mp4ClassicalAtomsInterpret() {
        let raw = MP4Tags.parse(mp4Box("moov", mp4Tags([mp4Text("\u{A9}wrk", ["Symphony No. 9"]), mp4Text("\u{A9}mvn", ["Scherzo"]), mp4Int16("\u{A9}mvi", 2), mp4Int16("\u{A9}mvc", 4),
                                                         mp4Text("\u{A9}wrt", ["Beethoven"]), mp4Freeform("CONDUCTOR", ["Furtwängler", "Karajan"]), mp4Text("\u{A9}nam", ["Scherzo"])])))
        let m = TagInterpreter.interpret(raw)
        expect(m.workTitle == "Symphony No. 9" && m.movementNumber == 2 && m.movementTotal == 4 && m.movementTitle == "Scherzo")
        expect(m.credits(.conductor).map(\.name) == ["Furtwängler", "Karajan"], "multi-valued freeform conductor")
    }
}

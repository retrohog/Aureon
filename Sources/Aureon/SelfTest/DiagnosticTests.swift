import Foundation

/// Regression checks for the problems that made the app hang: queueing a whole library, sorting thousands of songs on every redraw,
/// and tearing the output device down on every song change.
struct DiagnosticTests {
    let dir = tempDir("diag")

    private func track(_ i: Int) -> TrackDTO {
        TrackDTO(id: "t\(i)", path: "/m/\(i).flac", title: "Song number \(i % 997) é\(i)", trackNumber: i % 14, discNumber: 1, duration: Double(120 + i % 300), codec: "FLAC", sampleRate: i % 3 == 0 ? 96_000 : 44_100,
                 bitDepth: i % 3 == 0 ? 24 : 16, channels: 2, year: 1990 + i % 35, releaseID: "r\(i / 12)", releaseTitle: "Album \(i / 12)", workID: nil, workTitle: nil, catalog: nil, movementID: nil,
                 movementNumber: nil, movementTitle: nil, credits: [CreditDTO(role: "artist", name: "Artist \(i % 150)", instrument: nil, partyID: "p\(i % 150)")], genres: ["Genre \(i % 9)"], mbRecordingID: nil,
                 addedAt: Double(i), fileSize: Int64(20_000_000 + i))
    }

    func sortingALargeLibraryIsFast() {
        let songs = (0..<8_000).map(track)
        var worst = 0.0
        for sort in [SortKey.title, .artist, .album, .genre, .year, .quality, .size] {
            var o = ViewOptions(); o.sort = sort
            let t = Date()
            let r = LibraryOrdering.songs(songs, o)
            worst = max(worst, Date().timeIntervalSince(t))
            expect(r.count == songs.count, "\(sort) keeps every song")
        }
        expect(worst < 0.6, "the slowest of seven sorts of 8 000 songs took \(worst) s")
        var o = ViewOptions(); o.sort = .artist
        let r = LibraryOrdering.songs(songs, o)
        let artists = r.map { LibraryStore.fold($0.artistLine) }
        expect(artists == artists.sorted(), "and the order is right")
        o.ascending = false
        expect(LibraryOrdering.songs(songs, o).first?.id == r.last?.id, "descending reverses it")
    }

    func clickingASongQueuesAWindowNotTheLibrary() {
        let r = PlayerModel.queueRange(count: 8_000, index: 4_000)
        expect(r.count == 501 && r.lowerBound == 3_970 && r.contains(4_000), "a window around the song: \(r)")
        expect(PlayerModel.queueRange(count: 8_000, index: 0) == 0..<471, "at the top of the list")
        expect(PlayerModel.queueRange(count: 8_000, index: 7_999) == 7_969..<8_000, "at the end")
        expect(PlayerModel.queueRange(count: 5, index: 2) == 0..<5, "a short list is queued whole")
    }

    private func tone(_ name: String, freq: Double, seconds: Double) -> URL { sineWAV(dir.appendingPathComponent(name), rate: 44_100, bits: 24, freq: freq, amp: 0.4, seconds: seconds) }

    func changingSongsQuicklyNeverBlocks() {
        let files = (0..<6).map { tone("q\($0).wav", freq: 300 + Double($0) * 150, seconds: 6) }
        let sink = RecordingSink(speed: 1)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.25; o.rateSwitch = false
        let p = Player()
        p.setQueue(files.map(\.path)); p.start(options: o)
        let end0 = Date().addingTimeInterval(8)
        while p.status.state != .playing && Date() < end0 { usleep(5_000) }
        expect(p.status.state == .playing, "playing")
        var worstCall = 0.0, last: QueueEntry?
        for i in 0..<24 {
            let t = Date()
            let es = p.replace(with: files.map(\.path), startAt: i % files.count)
            worstCall = max(worstCall, Date().timeIntervalSince(t))
            last = es[i % files.count]
            usleep(40_000)
        }
        expect(worstCall < 0.02, "no call waited on the engine: worst \(worstCall * 1000) ms")
        let end = Date().addingTimeInterval(8)
        while p.status.trackID != last?.id && Date() < end { usleep(5_000) }
        expect(p.status.trackID == last?.id, "it ends up on the last song asked for")
        expect(p.status.state == .playing || p.status.state == .loading, "and is playing, not hung: \(p.status.state)")
        let n0 = sink.frameCount
        usleep(600_000)
        expect(sink.frameCount - n0 > 44_100 / 4, "audio keeps flowing (at least half of real time; sleep() itself runs slow on a busy Mac): \(sink.frameCount - n0) frames in 0.6 s")
        p.send(.stop); _ = p.waitUntilFinished(timeout: 8)
    }

    func theNewSongArrivesBitPerfectAfterAJump() {
        let a = tone("ja.wav", freq: 440, seconds: 5), b = tone("jb.wav", freq: 1000, seconds: 1.5)
        let sink = RecordingSink(speed: 1)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.25; o.rateSwitch = false
        let p = Player(); p.setQueue([a.path]); p.start(options: o)
        let end0 = Date().addingTimeInterval(8)
        while sink.frameCount < 22_050 && Date() < end0 { usleep(5_000) }
        p.replace(with: [b.path], startAt: 0)
        expect(p.waitUntilFinished(timeout: 12), "the new queue plays out")
        let want = readAll(try! LosslessFile(path: b.path)), got = sink.samples
        expect(got.count > want.count && Array(got.suffix(want.count)) == want, "the second song arrives sample for sample (\(got.count) delivered, \(want.count) in the file)")
    }
}

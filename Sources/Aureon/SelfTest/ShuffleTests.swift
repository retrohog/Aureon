import Foundation

struct ShuffleTests {
    private func c(_ n: Int, artist: String, album: String = "", genre: String = "Pop", liked: Bool = false) -> ShuffleCandidate {
        ShuffleCandidate(id: UUID(), path: "/\(n)", artist: artist, album: album.isEmpty ? "Album \(artist)" : album, genres: [genre], year: 2000 + n % 10, liked: liked)
    }

    func normalShuffleIsAPermutation() {
        let ids = (0..<50).map { _ in UUID() }
        var rng = SplitMix(seed: 1)
        let s = Shuffler.normal(ids, using: &rng)
        expect(Set(s) == Set(ids) && s.count == 50 && s != ids, "every song once, in a different order")
        var rng2 = SplitMix(seed: 1)
        expect(Shuffler.normal(ids, using: &rng2) == s, "same seed, same order")
        var rng3 = SplitMix(seed: 2)
        expect(Shuffler.normal(ids, using: &rng3) != s)
        var r4 = SplitMix(seed: 3)
        expect(Shuffler.normal([], using: &r4).isEmpty && Shuffler.normal([ids[0]], using: &r4) == [ids[0]])
    }

    func smartShuffleSpreadsArtists() {
        // six artists with eight songs each: a plain shuffle puts the same artist back to back about 1 in 6 times
        var items: [ShuffleCandidate] = []
        for a in 0..<6 { for k in 0..<8 { items.append(c(a * 8 + k, artist: "Artist \(a)")) } }
        var rng = SplitMix(seed: 5)
        let order = Shuffler.smart(items, using: &rng)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        expect(Set(order) == Set(items.map(\.id)) && order.count == items.count, "a permutation")
        var smartRepeats = 0
        for i in 1..<order.count where byID[order[i]]!.artist == byID[order[i - 1]]!.artist { smartRepeats += 1 }
        var plain = SplitMix(seed: 5)
        let p = Shuffler.normal(items.map(\.id), using: &plain)
        var plainRepeats = 0
        for i in 1..<p.count where byID[p[i]]!.artist == byID[p[i - 1]]!.artist { plainRepeats += 1 }
        expect(smartRepeats <= 2 && smartRepeats < plainRepeats, "back-to-back artists: smart \(smartRepeats), plain \(plainRepeats)")
        // not the same order every time
        var r2 = SplitMix(seed: 6)
        expect(Shuffler.smart(items, using: &r2) != order)
    }

    func smartShuffleKeepsTheCurrentSongFirstAndFavoursLiked() {
        var items = (0..<30).map { c($0, artist: "A\($0 % 10)", liked: $0 % 5 == 0) }
        let start = items.removeFirst()
        var early = 0.0, late = 0.0
        for seed in 1...40 {
            var rng = SplitMix(seed: UInt64(seed))
            let o = Shuffler.smart(items, start: start, using: &rng)
            expect(o.first == start.id && o.count == 30, "the playing song stays first")
            let pos = Dictionary(o.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            for t in items { if t.liked { early += Double(pos[t.id]!) } else { late += Double(pos[t.id]!) } }
        }
        let likedAvg = early / Double(40 * items.filter(\.liked).count), otherAvg = late / Double(40 * items.filter { !$0.liked }.count)
        expect(likedAvg < otherAvg - 1.5, "liked songs come earlier on average: \(likedAvg) vs \(otherAvg)")
    }

    func smartShuffleUsesTheTransitionNetwork() {
        func an(_ bpm: Double, _ k: MusicalKey) -> DJTrackAnalysis { var a = DJTrackAnalysis(peaks: [], bpm: bpm, confidence: 0.7, duration: 200); a.key = k; a.keyStrength = 0.7; a.energy = 0.6; return a }
        let c0 = MusicalKey(pitchClass: 0, minor: false), tri = MusicalKey(pitchClass: 6, minor: false)
        let net = TransitionNet.fresh(); net.pretrain()
        var start = c(0, artist: "S", genre: "X"); start.analysis = an(124, c0)
        var good = c(1, artist: "G", genre: "Y"); good.analysis = an(125, c0)
        var bad = c(2, artist: "B", genre: "Y"); bad.analysis = an(90, tri)
        var wins = 0
        for seed in 1...30 {
            var rng = SplitMix(seed: UInt64(seed))
            if Shuffler.smart([good, bad], start: start, net: net, using: &rng).dropFirst().first == good.id { wins += 1 }
        }
        expect(wins >= 24, "tracks that mix with the current one tend to follow it: \(wins)/30")
    }

    func restoreOrder() {
        let ids = (0..<6).map { _ in UUID() }
        let shuffled = [ids[3], ids[0], ids[5], ids[1], ids[4], ids[2]]
        expect(Shuffler.restore(current: shuffled, original: ids) == ids)
        let extra = UUID()
        expect(Shuffler.restore(current: shuffled + [extra], original: ids) == ids + [extra], "songs added while shuffled go last")
        expect(Shuffler.restore(current: [ids[2], ids[0]], original: ids) == [ids[0], ids[2]], "removed songs are simply gone")
    }
}

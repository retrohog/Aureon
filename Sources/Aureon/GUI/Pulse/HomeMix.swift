import SwiftUI

// What Home offers, worked out from the time of day and from what the listener plays. It is a pure function of the albums (with how often and when each was
// played), the clock and a seed: the seed changes at every launch and with "Refresh mix", so the page is not the same twice; the clock moves the mood with
// the day (morning, afternoon, evening, night, late); the listener's own history sets how strongly each kind of music is wanted. Nothing here touches the
// audio thread or the network, and the whole thing runs off the main thread on a copy of the library's figures.

/// The part of the day.
enum DayPart: String, CaseIterable {
    case late, morning, afternoon, evening, night

    /// 0–5 late, 5–11 morning, 11–17 afternoon, 17–22 evening, 22–24 night.
    static func of(hour: Double) -> DayPart {
        let h = hour.truncatingRemainder(dividingBy: 24)
        return h < 5 ? .late : h < 11 ? .morning : h < 17 ? .afternoon : h < 22 ? .evening : .night
    }
    var greeting: String {
        switch self { case .late: "Still up"; case .morning: "Good morning"; case .afternoon: "Good afternoon"; case .evening: "Good evening"; case .night: "Good night" }
    }
}

/// A mood of the day: a name, what it sounds like, and the genres it leans on.
struct HomeMood: Equatable {
    var title: String
    var sub: String
    var genres: [String]

    static func moods(_ d: DayPart) -> [HomeMood] {
        switch d {
        case .late: [HomeMood(title: "Still up", sub: "Slow electronic and piano", genres: ["electronic", "piano", "ambient"]),
                     HomeMood(title: "Low light", sub: "Ambient, no vocals", genres: ["ambient", "piano"])]
        case .morning: [HomeMood(title: "Morning light", sub: "Folk and gentle jazz", genres: ["folk", "jazz", "soul"]),
                        HomeMood(title: "Slow start", sub: "Piano and strings", genres: ["piano", "classical"])]
        case .afternoon: [HomeMood(title: "Focus", sub: "Instrumental and ambient", genres: ["ambient", "electronic", "piano"]),
                          HomeMood(title: "Steady work", sub: "Minimal and warm", genres: ["electronic", "folk"])]
        case .evening: [HomeMood(title: "Warm room", sub: "Jazz and soul in Hi-Res", genres: ["jazz", "soul", "classical"]),
                        HomeMood(title: "Dinner music", sub: "Acoustic and easy", genres: ["folk", "jazz", "indie"])]
        case .night: [HomeMood(title: "After dark", sub: "Ambient and slow electronic", genres: ["ambient", "electronic"]),
                      HomeMood(title: "Late piano", sub: "Solo piano and strings", genres: ["piano", "classical"])]
        }
    }
}

/// One album as the recommender sees it: its figures and how it has been played.
struct HomeAlbum: Identifiable, Equatable {
    var id: String
    var title: String
    var artist: String
    var year: Int?
    var genres: [String]
    var hiRes: Bool
    var addedAt: Double?
    var plays: Int
    var lastPlayed: Double?
    var liked: Int
}

/// The chips under the greeting.
enum HomeFilter: String, CaseIterable, Identifiable {
    case all, focus, windDown, newToMe, hiRes
    var id: String { rawValue }
    var title: String { switch self { case .all: "All"; case .focus: "Focus"; case .windDown: "Wind down"; case .newToMe: "New to me"; case .hiRes: "Hi-res" } }

    func accepts(_ a: HomeAlbum) -> Bool {
        switch self {
        case .all: return true
        case .focus: return HomeRecommender.matches(a, genres: ["ambient", "electronic", "piano", "classical", "instrumental", "minimal"])
        case .windDown: return HomeRecommender.matches(a, genres: ["jazz", "soul", "folk", "ambient", "classical", "acoustic", "piano"])
        case .newToMe: return a.plays == 0
        case .hiRes: return a.hiRes
        }
    }
}

struct HomeShelf: Identifiable, Equatable {
    var id: String
    var title: String
    var sub: String
    var items: [String]
}

struct HomeMix: Equatable {
    var daypart: DayPart
    var greeting: String
    /// "9:30 pm · Warm room, jazz and soul in Hi-Res"
    var why: String
    /// What the mix leaned on, for "Why these?".
    var reasons: [String]
    var profile: String
    var quick: [String]
    var shelves: [HomeShelf]
}

enum HomeRecommender {
    /// A small deterministic generator (mulberry32), so a seed gives the same page.
    struct Random {
        private var a: UInt32
        init(seed: UInt64) { a = UInt32(truncatingIfNeeded: seed ^ (seed >> 32)) }
        mutating func next() -> Double {
            a &+= 0x6D2B79F5
            var t = a
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double((t ^ (t >> 14))) / 4294967296.0
        }
    }

    static func matches(_ a: HomeAlbum, genres: [String]) -> Bool {
        a.genres.contains { g in let l = g.lowercased(); return genres.contains { l.contains($0) } }
    }

    static func clock(_ hour: Double) -> String {
        let hh = Int(hour), mm = hour.truncatingRemainder(dividingBy: 1) >= 0.5 ? "30" : "00"
        return "\(hh % 12 == 0 ? 12 : hh % 12):\(mm) \(hh >= 12 ? "pm" : "am")"
    }

    /// How strongly the listener plays each genre: play counts, with a floor so nothing is ruled out; the most played is about 3, the least 0.3.
    static func profileWeights(_ albums: [HomeAlbum]) -> [String: Double] {
        var counts: [String: Double] = [:]
        for a in albums {
            let w = Double(a.plays) + Double(a.liked) * 1.5
            for g in a.genres { counts[g.lowercased(), default: 0] += w }
        }
        guard let top = counts.values.max(), top > 0 else { return [:] }
        return counts.mapValues { max(0.3, 3 * $0 / top) }
    }

    /// A short phrase for the listener: the two genres played most ("Jazz and classical"), or nothing yet.
    static func profileName(_ weights: [String: Double]) -> String {
        let top = weights.filter { $0.value > 0.31 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(2).map { $0.key.capitalized }
        switch top.count {
        case 0: return "New listener"
        case 1: return top[0] + " listener"
        default: return top[0] + " and " + top[1].lowercased()
        }
    }

    /// The day part an album was last played in, if it has been.
    static func lastPlayedPart(_ a: HomeAlbum, calendar: Calendar) -> DayPart? {
        guard let t = a.lastPlayed else { return nil }
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
        return DayPart.of(hour: Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60)
    }

    static func mix(albums: [HomeAlbum], now: Date, seed: UInt64, calendar: Calendar = .current) -> HomeMix {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let hour = Double(comps.hour ?? 12) + (Double(comps.minute ?? 0) >= 30 ? 0.5 : 0)
        let part = DayPart.of(hour: hour)
        var rng = Random(seed: seed &* 9973 &+ UInt64(hour * 2))
        let moods = HomeMood.moods(part)
        let mood = moods[Int(rng.next() * Double(moods.count)) % moods.count]
        let weights = profileWeights(albums)

        // what each genre is worth right now: the mood's genres, each scaled by how much the listener plays it
        var blend: [String: Double] = [:]
        for m in moods { for g in m.genres { blend[g, default: 0] += g == mood.genres.first ? 2 : 1.5 } }
        for (g, w) in weights { blend[g] = (blend[g] ?? 0.3) * w }

        func score(_ a: HomeAlbum, base: [String: Double]) -> Double {
            var s = a.genres.map { g -> Double in
                let l = g.lowercased()
                return base.first { l.contains($0.key) }?.value ?? 0.4
            }.max() ?? 0.4
            if lastPlayedPart(a, calendar: calendar) == part { s *= 1.35 }          // what you tend to play at this hour
            if a.liked > 0 { s *= 1.15 }
            return s * (0.6 + rng.next())
        }
        func pick(_ pool: [HomeAlbum], _ n: Int, base: [String: Double], excluding: Set<String> = []) -> [HomeAlbum] {
            let scored = pool.filter { !excluding.contains($0.id) }.map { ($0, score($0, base: base)) }
            return Array(scored.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }.prefix(n).map(\.0))
        }

        let now1 = now.timeIntervalSince1970
        let day = 86_400.0
        let because = pick(albums.filter { $0.plays > 0 }, 1, base: blend).first
        var used = Set<String>(); if let because { used.insert(because.id) }

        var shelves: [HomeShelf] = []
        let rotation = albums.filter { $0.plays > 0 && ($0.lastPlayed ?? 0) < now1 - 90 * day }
        let back = pick(rotation, 14, base: weights.isEmpty ? blend : weights, excluding: used)
        if back.count >= 3 { shelves.append(HomeShelf(id: "rotation", title: "Back in rotation", sub: "Not played for three months", items: back.map(\.id))); used.formUnion(back.map(\.id)) }
        let unheardHiRes = pick(albums.filter { $0.hiRes && $0.plays == 0 }, 14, base: blend, excluding: used)
        if unheardHiRes.count >= 3 { shelves.append(HomeShelf(id: "hires", title: "Hi-Res you haven’t heard", sub: "24-bit and DSD, still unplayed", items: unheardHiRes.map(\.id))); used.formUnion(unheardHiRes.map(\.id)) }
        let fresh = albums.filter { ($0.addedAt ?? 0) > now1 - 45 * day }.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(14).filter { !used.contains($0.id) }
        if fresh.count >= 3 { shelves.append(HomeShelf(id: "new", title: "New in your library", sub: "Added in the last weeks", items: fresh.map(\.id))); used.formUnion(fresh.map(\.id)) }
        if let because {
            let like = pick(albums.filter { a in a.id != because.id && a.genres.contains { g in because.genres.contains { $0.lowercased() == g.lowercased() } } }, 14, base: blend, excluding: used)
            if like.count >= 3 { shelves.append(HomeShelf(id: "because", title: "Because you play “\(because.title)”", sub: "More from the same corner of your library", items: like.map(\.id))); used.formUnion(like.map(\.id)) }
        }
        let moodShelf = pick(albums.filter { matches($0, genres: mood.genres) }, 14, base: blend, excluding: used)
        if moodShelf.count >= 3 { shelves.append(HomeShelf(id: "mood", title: mood.title, sub: mood.sub, items: moodShelf.map(\.id))); used.formUnion(moodShelf.map(\.id)) }
        if shelves.isEmpty {
            let any = pick(albums, 14, base: blend)
            if !any.isEmpty { shelves.append(HomeShelf(id: "library", title: "From your library", sub: "A few to start with", items: any.map(\.id))) }
        }
        // the order of the shelves changes with the launch
        if shelves.count > 1 { for i in stride(from: shelves.count - 1, to: 0, by: -1) { shelves.swapAt(i, Int(rng.next() * Double(i + 1)) % (i + 1)) } }

        let quick = pick(albums, 24, base: blend).map(\.id)
        var reasons = ["It is \(clock(hour)), so the mood is “\(mood.title)”: \(mood.sub.lowercased())."]
        if !weights.isEmpty { reasons.append("You play mostly \(profileName(weights).lowercased()), so those albums count for more.") }
        if albums.contains(where: { lastPlayedPart($0, calendar: calendar) == part }) { reasons.append("Albums you last played around this hour come first.") }
        if let because { reasons.append("“\(because.title)” is one you return to.") }
        reasons.append("A new mix is made at every launch, and when you press Refresh mix.")
        return HomeMix(daypart: part, greeting: part.greeting, why: "\(clock(hour)) · \(mood.title), \(mood.sub.prefix(1).lowercased() + mood.sub.dropFirst())",
                       reasons: reasons, profile: profileName(weights), quick: quick, shelves: shelves)
    }
}

/// Home's data: the library's albums in the recommender's terms, the mix made from them, and the albums to show. Loaded off the main thread.
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var albums: [HomeAlbum] = []
    @Published private(set) var mix: HomeMix?
    @Published private(set) var releases: [String: ReleaseDTO] = [:]
    @Published var filter = HomeFilter.all
    @Published var showReasons = false
    /// A new seed at every launch.
    nonisolated(unsafe) static var launchSeed = UInt64.random(in: 1..<UInt64.max)
    private var seed = HomeModel.launchSeed
    private var loadedFor = -1
    private var task: Task<Void, Never>?

    /// Reads the library's tracks (a few thousand rows at a time, in the background) and makes the mix. `tracks` is the library's count, so a changed
    /// library is read again and an unchanged one is not.
    func load(_ store: LibraryStore?, tracks: Int, force: Bool = false) {
        guard let store, force || loadedFor != tracks else { return }
        loadedFor = tracks
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            var all: [TrackDTO] = []
            var off = 0
            while !Task.isCancelled {
                let page = store.allTracks(offset: off, limit: 2000)
                all += page
                if page.count < 2000 || all.count >= 80_000 { break }
                off += 2000
            }
            guard !Task.isCancelled else { return }
            let albums = HomeModel.aggregate(all)
            await MainActor.run { self?.albums = albums; self?.remake(store) }
        }
    }

    nonisolated static func aggregate(_ tracks: [TrackDTO]) -> [HomeAlbum] {
        var by: [String: HomeAlbum] = [:]
        for t in tracks {
            guard let rid = t.releaseID else { continue }
            var a = by[rid] ?? HomeAlbum(id: rid, title: t.releaseTitle ?? t.title, artist: t.primaryArtistLine, year: t.year, genres: [], hiRes: false, addedAt: nil, plays: 0, lastPlayed: nil, liked: 0)
            for g in t.genres where !a.genres.contains(g) { a.genres.append(g) }
            if t.sampleRate > 48_000 || t.bitDepth > 16 { a.hiRes = true }
            a.addedAt = max(a.addedAt ?? 0, t.addedAt ?? 0)
            a.plays += t.playCount ?? 0
            if let l = t.lastPlayedAt { a.lastPlayed = max(a.lastPlayed ?? 0, l) }
            if t.isLiked { a.liked += 1 }
            by[rid] = a
        }
        return Array(by.values)
    }

    func refreshMix(_ store: LibraryStore?) { seed = seed &* 6364136223846793005 &+ 1442695040888963407; remake(store) }

    private func remake(_ store: LibraryStore?) {
        let m = HomeRecommender.mix(albums: albums, now: Date(), seed: seed)
        mix = m
        guard let store else { return }
        let want = Set(m.quick + m.shelves.flatMap(\.items)).subtracting(releases.keys)
        guard !want.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: ReleaseDTO] = [:]
            for id in want { if let r = store.release(id: id) { found[id] = r } }
            let result = found
            await MainActor.run { self?.releases.merge(result) { $1 } }
        }
    }

    /// The quick picks and shelves under the chosen chip.
    func visibleQuick() -> [ReleaseDTO] {
        guard let mix else { return [] }
        let by = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        return mix.quick.compactMap { id in by[id].flatMap { filter.accepts($0) ? releases[id] : nil } }
    }
    func visibleShelves() -> [(shelf: HomeShelf, items: [ReleaseDTO])] {
        guard let mix else { return [] }
        let by = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        return mix.shelves.compactMap { s in
            let items = s.items.compactMap { id in by[id].flatMap { filter.accepts($0) ? releases[id] : nil } }
            return items.isEmpty ? nil : (s, items)
        }
    }
}

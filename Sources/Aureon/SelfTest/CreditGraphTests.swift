import Foundation

/// The relational credit graph: a session player's page, collaborators, the tags that feed it, the remote endpoint and the album personnel list.
/// All names and titles here are made up.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&value) }
}

struct CreditGraphTests {
    private func track(_ title: String, number: Int, album: String, year: Int, artist: String, path: String, credits: [Credit]) -> (facts: FileFacts, tags: TrackMetadata) {
        var m = TrackMetadata(); m.title = title; m.album = album; m.year = year; m.trackNumber = number; m.discNumber = 1
        m.credits = [Credit(role: .artist, name: artist), Credit(role: .albumArtist, name: artist)] + credits
        return (FileFacts(path: path, duration: 240, sampleRate: 44_100, bitDepth: 16, channels: 2, codec: "FLAC", mtime: 1, size: 1), m)
    }

    /// A small studio scene: one drummer on three other people's records and one of their own, two producers, one engineer.
    func scene() -> LibraryStore {
        let lib = try! LibraryStore()
        let drums = Credit(role: .performer, name: "Sam Rivera", instrument: "drums")
        let ted = Credit(role: .producer, name: "Ted Okoye"), ola = Credit(role: .engineer, name: "Ola Brandt")
        var items: [(facts: FileFacts, tags: TrackMetadata)] = []
        // The Marble Duo, 1977: Sam plays on both tracks; Ted produces, Ola engineers
        items.append(track("Glass Harbor", number: 1, album: "Harbor Lights", year: 1977, artist: "The Marble Duo", path: "/m/duo/1.flac", credits: [drums, ted, ola]))
        items.append(track("Salt Road", number: 2, album: "Harbor Lights", year: 1977, artist: "The Marble Duo", path: "/m/duo/2.flac", credits: [drums, ted, ola]))
        // Nina Vale, 1979: Sam on one track only, Ola again
        items.append(track("Paper Lanterns", number: 1, album: "Lantern Season", year: 1979, artist: "Nina Vale", path: "/m/nina/1.flac", credits: [drums, ola]))
        items.append(track("Quiet Window", number: 2, album: "Lantern Season", year: 1979, artist: "Nina Vale", path: "/m/nina/2.flac", credits: [Credit(role: .performer, name: "Kit Almeida", instrument: "drums"), ola]))
        // Orchid Trio, 1981: Sam plays and produces
        items.append(track("Slow Weather", number: 1, album: "Cloud Study", year: 1981, artist: "Orchid Trio", path: "/m/orchid/1.flac", credits: [drums, Credit(role: .producer, name: "Sam Rivera")]))
        // Sam's own record, 1985
        items.append(track("Brushwork", number: 1, album: "Rivera Plays", year: 1985, artist: "Sam Rivera", path: "/m/sam/1.flac", credits: [Credit(role: .composer, name: "Sam Rivera"), ted]))
        // a record Sam is not on
        items.append(track("Elsewhere", number: 1, album: "Other Rooms", year: 1990, artist: "Kit Almeida", path: "/m/kit/1.flac", credits: [ola]))
        lib.upsert(items)
        return lib
    }

    private func id(_ lib: LibraryStore, _ name: String) -> String { lib.people(search: name).first { $0.name == name }!.id }

    func sessionPlayerPage() {
        let lib = scene()
        let g = lib.creditGraph(partyID: id(lib, "Sam Rivera"))!
        expect(g.person.name == "Sam Rivera" && g.releaseCount == 4 && g.trackCount == 5, "4 records, 5 tracks: \(g.releaseCount) / \(g.trackCount)")
        expect(g.sections.map(\.category) == [.primary, .session, .production, .writing], "sections in a stable order, only those with credits: \(g.sections.map(\.category))")
        let session = g.section(.session)!.releases
        expect(session.map(\.title) == ["Harbor Lights", "Lantern Season", "Cloud Study"], "session records by year: \(session.map(\.title))")
        expect(session[0].tracks.map(\.title) == ["Glass Harbor", "Salt Road"] && session[1].tracks.map(\.title) == ["Paper Lanterns"], "only the tracks they are credited on")
        expect(session[0].roles.map(\.label) == ["drums"] && session[0].artistNames == ["The Marble Duo"] && session[0].year == 1977, "\(session[0])")
        expect(g.section(.production)!.releases.map(\.title) == ["Cloud Study"], "producer credit only on the record they produced")
        expect(g.section(.primary)!.releases.map(\.title) == ["Rivera Plays"])
        expect(g.otherRecords.map(\.title) == ["Harbor Lights", "Lantern Season", "Cloud Study"], "records where they were not the main artist, each once: \(g.otherRecords.map(\.title))")
        expect(g.section(.engineering) == nil, "no empty sections")
    }

    func collaborators() {
        let lib = scene()
        let g = lib.creditGraph(partyID: id(lib, "Sam Rivera"))!
        let names = g.collaborators.map(\.name)
        expect(!names.contains("Sam Rivera"), "a person is not their own collaborator")
        expect(names.first == "Ola Brandt" && names.prefix(2) == ["Ola Brandt", "Ted Okoye"], "most shared records first, ties by name: \(names)")
        let ola = g.collaborators.first { $0.name == "Ola Brandt" }!, ted = g.collaborators.first { $0.name == "Ted Okoye" }!
        expect(ola.sharedReleases == 2 && ola.sharedTracks == 3 && ola.roles.map(\.label) == ["Engineer"], "\(ola)")
        expect(ted.sharedReleases == 2 && ted.sharedTracks == 3, "Ted is on Harbor Lights (2 tracks) and Rivera Plays (1): \(ted)")
        expect(!names.contains("Kit Almeida"), "Kit plays on Lantern Season, but not on the track Sam is credited on")
        expect(g.collaborators.first { $0.name == "Nina Vale" }?.sharedReleases == 1 && names.contains("The Marble Duo"), "the artists they backed are collaborators too: \(names)")
        let capped = lib.creditGraph(partyID: id(lib, "Sam Rivera"), collaboratorLimit: 2)!
        expect(capped.collaborators.count == 2)
        expect(lib.creditGraph(partyID: "no-such-person") == nil)
    }

    func sharedRecords() {
        let lib = scene()
        let s = lib.sharedCredits(id(lib, "Sam Rivera"), id(lib, "Ola Brandt"))!
        expect(s.records.map(\.title) == ["Harbor Lights", "Lantern Season"] && s.records.map(\.trackCount) == [2, 1], "\(s.records.map { ($0.title, $0.trackCount) })")
        expect(s.records[0].first.map(\.label) == ["drums"] && s.records[0].second.map(\.label) == ["Engineer"])
        let nina = lib.sharedCredits(id(lib, "Sam Rivera"), id(lib, "Nina Vale"))!
        expect(nina.records.map(\.title) == ["Lantern Season"], "an artist and the session player they hired share their record")
        let kit = lib.sharedCredits(id(lib, "Ted Okoye"), id(lib, "Kit Almeida"))!
        expect(kit.records.isEmpty, "no shared records is an empty list, not an error")
        expect(lib.sharedCredits(id(lib, "Sam Rivera"), "ghost") == nil)
    }

    func peopleList() {
        let lib = scene()
        let all = lib.people().map(\.name)
        expect(Set(all).count == all.count, "each person once, however many roles: \(all)")
        for n in ["Sam Rivera", "Ola Brandt", "Ted Okoye", "Nina Vale", "Kit Almeida", "The Marble Duo", "Orchid Trio"] { expect(all.contains(n), "\(n) is listed") }
        expect(lib.people(search: "RIVERA").map(\.name) == ["Sam Rivera"], "search ignores case")
        expect(lib.people(search: "okoy").map(\.name) == ["Ted Okoye"], "and matches within a name")
        expect(lib.people(limit: 3).count == 3 && lib.people(search: "zzz").isEmpty)
    }

    func categoriesCoverEveryRole() {
        var seen = Set<CreditCategory>()
        for r in CreditRole.allCases { seen.insert(CreditCategory(role: r)) }
        expect(seen == Set(CreditCategory.allCases), "every category is reachable and every role belongs to one: \(seen.count)")
        expect(CreditCategory(role: .performer) == .session && CreditCategory(role: .soloist) == .session && CreditCategory(role: .producer) == .production)
        expect(CreditCategory(role: .engineer) == .engineering && CreditCategory(role: .arranger) == .writing && CreditCategory(role: .conductor) == .conducting)
        expect(CreditRoleDTO(role: "performer", instrument: "drums").label == "drums" && CreditRoleDTO(role: "producer", instrument: nil).label == "Producer" && CreditRoleDTO(role: "soloist", instrument: "violin").label == "Soloist (violin)")
        expect(CreditCategory.allCases.allSatisfy { !$0.title.isEmpty && !$0.icon.isEmpty })
    }

    func tagsFeedTheGraph() {
        func tags(_ c: [(String, String)]) -> TrackMetadata { TagInterpreter.interpret(VorbisTags.parseComments(vorbisBlock(c))) }
        let m = tags([("TITLE", "Night Shift"), ("ARTIST", "Orchid Trio"), ("ALBUM", "Cloud Study"), ("DATE", "1981"),
                      ("PERFORMER", "Sam Rivera (drums)"), ("PERFORMER", "Jo Park (upright bass)"), ("PRODUCER", "Ted Okoye"), ("COPRODUCER", "Ivy Lang"),
                      ("ENGINEER", "Ola Brandt"), ("MIXENGINEER", "Pat Moss"), ("MASTERINGENGINEER", "Quin Ford")])
        expect(m.credits(.performer).map { "\($0.name)|\($0.instrument ?? "")" } == ["Sam Rivera|drums", "Jo Park|upright bass"], "\(m.credits(.performer))")
        expect(m.credits(.producer).map(\.name) == ["Ted Okoye", "Ivy Lang"], "\(m.credits(.producer).map(\.name))")
        expect(m.credits(.engineer).map(\.name) == ["Ola Brandt", "Pat Moss", "Quin Ford"], "\(m.credits(.engineer).map(\.name))")
        expect(TagInterpreter.roleAndInstrument(from: "mastering").0 == .engineer && TagInterpreter.roleAndInstrument(from: "producer").0 == .producer)

        // the parsed tags reach the graph through the normal import path
        let lib = try! LibraryStore()
        lib.upsert([(FileFacts(path: "/m/o/1.flac", duration: 200, sampleRate: 44_100, bitDepth: 16, channels: 2, codec: "FLAC", mtime: 1, size: 1), m)])
        let g = lib.creditGraph(partyID: id(lib, "Jo Park"))!
        expect(g.section(.session)?.releases.first?.roles.map(\.label) == ["upright bass"] && g.releaseCount == 1)
        let q = lib.creditGraph(partyID: id(lib, "Quin Ford"))!
        expect(q.section(.engineering)?.releases.first?.title == "Cloud Study" && q.collaborators.contains { $0.name == "Sam Rivera" })
    }

    func albumPersonnel() {
        let lib = scene()
        let tracks = lib.tracks(partyID: id(lib, "Ola Brandt")).filter { $0.releaseTitle == "Harbor Lights" }
        expect(tracks.count == 2)
        let p = AlbumPersonnel.people(in: tracks)
        expect(!p.contains { $0.name == "The Marble Duo" }, "the album's artists are not listed as personnel")
        expect(p.map(\.name) == ["Sam Rivera", "Ted Okoye", "Ola Brandt"], "session players first, then producers, then engineers: \(p.map(\.name))")
        expect(p[0].roles == ["drums"] && p[1].roles == ["Producer"] && p[2].roles == ["Engineer"], "\(p.map(\.roles))")
        expect(AlbumPersonnel.people(in: []).isEmpty)
    }

    func remoteEndpoints() {
        let f = RemoteFixture()
        defer { f.stop() }
        let ctl = f.controller
        f.library.upsert([track("Glass Harbor", number: 1, album: "Harbor Lights", year: 1977, artist: "The Marble Duo", path: "/m/duo/1.flac",
                                credits: [Credit(role: .performer, name: "Sam Rivera", instrument: "drums"), Credit(role: .producer, name: "Ted Okoye")])])
        func call(_ m: String, _ p: JSONObject = [:]) -> Result<Data, Error> { runAsync { try await ctl.handle(method: m, params: p) } }
        let people = call("library.people", ["search": "sam"])
        guard case .success(let pd) = people, let list = try? JSONDecoder().decode([PartyDTO].self, from: pd) else { return expect(false, "library.people failed: \(people)") }
        expect(list.map(\.name) == ["Sam Rivera"])
        let credits = call("library.credits", ["partyID": list[0].id])
        guard case .success(let cd) = credits, let g = try? JSONDecoder().decode(CreditGraphDTO.self, from: cd) else { return expect(false, "library.credits failed: \(credits)") }
        expect(g.person.name == "Sam Rivera" && g.section(.session)?.releases.first?.title == "Harbor Lights" && g.collaborators.contains { $0.name == "Ted Okoye" }, "\(g)")
        let ted = f.library.people(search: "Ted").first!.id
        let shared = call("library.sharedCredits", ["partyID": list[0].id, "otherID": ted])
        guard case .success(let sd) = shared, let s = try? JSONDecoder().decode(SharedCreditsDTO.self, from: sd) else { return expect(false, "library.sharedCredits failed: \(shared)") }
        expect(s.records.count == 1 && s.records[0].title == "Harbor Lights")
        if case .failure(let e) = call("library.credits", ["partyID": "ghost"]) { expect((e as? RemoteError)?.code == RemoteErrorCode.invalidParams, "unknown person is invalid params: \(e)") } else { expect(false, "unknown person should fail") }
        if case .failure(let e) = call("library.credits") { expect(e is RemoteError, "missing parameter is an error: \(e)") } else { expect(false, "missing partyID should fail") }
    }

    func concurrentReadsAgree() {
        let lib = scene()
        let sam = id(lib, "Sam Rivera")
        let expected = lib.creditGraph(partyID: sam)!
        // the page is built on background queues while the library is being read elsewhere: the store serialises them and every answer is identical
        let results = Locked<[CreditGraphDTO]>([])
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if let g = lib.creditGraph(partyID: sam) { results.update { $0.append(g) } }
        }
        expect(results.get().count == 12 && results.get().allSatisfy { $0 == expected }, "concurrent reads agree")
        let done = DispatchSemaphore(value: 0), shared = Locked<SharedCreditsDTO?>(nil)
        DispatchQueue.global(qos: .userInitiated).async { shared.update { $0 = lib.sharedCredits(sam, self.id(lib, "Ted Okoye")) }; done.signal() }
        expect(done.wait(timeout: .now() + 10) == .success && shared.get()?.records.map(\.title) == ["Harbor Lights", "Rivera Plays"], "\(String(describing: shared.get()?.records.map(\.title)))")
    }

    func prolificPlayerStaysFast() {
        // 300 records by 300 different artists, one drummer on all of them: one prefetching fetch, not one per record
        let lib = try! LibraryStore()
        let drums = Credit(role: .performer, name: "Sam Rivera", instrument: "drums")
        var items: [(facts: FileFacts, tags: TrackMetadata)] = []
        for i in 0..<300 {
            for n in 1...3 {
                items.append(track("Song \(i)-\(n)", number: n, album: "Record \(i)", year: 1960 + i % 60, artist: "Artist \(i)", path: "/m/\(i)/\(n).flac", credits: [drums, Credit(role: .engineer, name: "Engineer \(i % 7)")]))
            }
        }
        lib.upsert(items)
        let start = Date()
        let g = lib.creditGraph(partyID: id(lib, "Sam Rivera"))!
        let took = Date().timeIntervalSince(start)
        expect(g.releaseCount == 300 && g.trackCount == 900 && g.section(.session)!.releases.count == 300, "\(g.releaseCount) / \(g.trackCount)")
        expect(g.collaborators.count == 60 && g.collaborators.first?.name == "Engineer 0", "capped at 60, the engineers on most of their records first: \(g.collaborators.prefix(2).map(\.name))")
        expect(took < 5, "a 900-track credit page builds in \(took) s")
        let years = g.section(.session)!.releases.compactMap(\.year)
        expect(years == years.sorted(), "oldest first")
    }
}

func creditGraphTests() -> [(String, TestFn)] {
    let t = CreditGraphTests()
    return [("credits.sessionPage", t.sessionPlayerPage), ("credits.collaborators", t.collaborators), ("credits.shared", t.sharedRecords),
            ("credits.people", t.peopleList), ("credits.categories", t.categoriesCoverEveryRole), ("credits.tags", t.tagsFeedTheGraph),
            ("credits.albumPersonnel", t.albumPersonnel), ("credits.remote", t.remoteEndpoints),
            ("credits.concurrent", t.concurrentReadsAgree), ("credits.prolific", t.prolificPlayerStaysFast)]
}

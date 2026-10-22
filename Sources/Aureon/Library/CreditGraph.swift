import Foundation
import CoreData

// The relational view of the library's credits: pick a person and see every record they worked on, and in what capacity, plus the people they
// worked with. It reads the same Track ──< Credit >── Party tables as everything else, in one query for the person's tracks with the
// credits, parties and releases prefetched, so a prolific session player costs one round trip, not one per record. Nothing here touches the
// main thread: callers run it on a background queue (the store serialises access to its context).

/// How a credit relates to the record. Roon-style "focus" pages group a person's credits like this.
enum CreditCategory: String, Codable, CaseIterable, Hashable, Identifiable {
    case primary, session, production, engineering, writing, conducting, remix
    var id: String { rawValue }
    var title: String {
        switch self {
        case .primary: "Artist"; case .session: "Session musician"; case .production: "Producer"; case .engineering: "Engineer"
        case .writing: "Writer & arranger"; case .conducting: "Conductor & ensemble"; case .remix: "Remixer"
        }
    }
    var icon: String {
        switch self {
        case .primary: "music.mic"; case .session: "guitars"; case .production: "slider.horizontal.3"; case .engineering: "dial.medium"
        case .writing: "pencil.and.scribble"; case .conducting: "wand.and.rays"; case .remix: "arrow.triangle.2.circlepath"
        }
    }
    init(role: CreditRole) {
        switch role {
        case .artist, .albumArtist: self = .primary
        case .performer, .soloist, .featured: self = .session
        case .producer: self = .production
        case .engineer: self = .engineering
        case .composer, .lyricist, .arranger: self = .writing
        case .conductor, .ensemble: self = .conducting
        case .remixer: self = .remix
        }
    }
}

struct CreditRoleDTO: Codable, Hashable {
    var role: String
    var instrument: String?
    /// "drums", "Producer", "Soloist (violin)".
    var label: String {
        let r = CreditRole(rawValue: role)?.title ?? role
        guard let i = instrument, !i.isEmpty else { return r }
        return r == "Performer" ? i : "\(r) (\(i))"
    }
}

struct CreditedTrackDTO: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var trackNumber: Int?
    var discNumber: Int?
    var roles: [CreditRoleDTO]
}

/// One record (or loose track) the person is credited on, within one category.
struct CreditedReleaseDTO: Codable, Identifiable, Hashable {
    var id: String                    // the release's id; "track:<id>" for a track that belongs to no release
    var title: String
    var year: Int?
    var artistNames: [String]
    var roles: [CreditRoleDTO]        // what they did on this record, in this category
    var tracks: [CreditedTrackDTO]    // the tracks they are credited on
    var isRelease: Bool { !id.hasPrefix("track:") }
}

struct CreditSectionDTO: Codable, Identifiable, Hashable {
    var category: CreditCategory
    var releases: [CreditedReleaseDTO]
    var id: String { category.rawValue }
}

/// Someone credited on the same tracks as the person in focus.
struct CollaboratorDTO: Codable, Identifiable, Hashable {
    var partyID: String
    var name: String
    var kind: String
    var sharedReleases: Int
    var sharedTracks: Int
    var roles: [CreditRoleDTO]        // what they did on those tracks, most common first
    var id: String { partyID }
}

struct CreditGraphDTO: Codable, Equatable {
    var person: PartyDTO
    var sections: [CreditSectionDTO]
    var collaborators: [CollaboratorDTO]
    var releaseCount: Int
    var trackCount: Int

    func section(_ c: CreditCategory) -> CreditSectionDTO? { sections.first { $0.category == c } }
    /// The records where the person was not the main artist: what a session player's page is for.
    var otherRecords: [CreditedReleaseDTO] {
        let own = Set(section(.primary)?.releases.map(\.id) ?? [])
        var seen = Set<String>(), out: [CreditedReleaseDTO] = []
        for s in sections where s.category != .primary { for r in s.releases where !own.contains(r.id) && seen.insert(r.id).inserted { out.append(r) } }
        return out
    }
}

/// The records two people both worked on.
struct SharedCreditsDTO: Codable, Equatable {
    struct Shared: Codable, Identifiable, Hashable {
        var id: String
        var title: String
        var year: Int?
        var first: [CreditRoleDTO]
        var second: [CreditRoleDTO]
        var trackCount: Int
    }
    var first: PartyDTO
    var second: PartyDTO
    var records: [Shared]
}

extension LibraryStore {
    /// The person's tracks with everything needed to build the page, fetched once.
    private func creditedTracks(partyID: String) -> [NSManagedObject] {
        let r = NSFetchRequest<NSManagedObject>(entityName: "Track")
        r.predicate = NSPredicate(format: "SUBQUERY(credits, $c, $c.party.uid == %@).@count > 0", partyID)
        r.relationshipKeyPathsForPrefetching = ["credits", "credits.party", "release"]
        r.returnsObjectsAsFaults = false
        return (try? ctx.fetch(r)) ?? []
    }

    private func roleDTO(_ c: NSManagedObject) -> CreditRoleDTO { CreditRoleDTO(role: str(c, "role") ?? "", instrument: str(c, "instrument")) }

    /// A track's credits in a fixed order (the relationship is an unordered set, and the page must come out identical every time).
    private func orderedCredits(_ t: NSManagedObject) -> [NSManagedObject] {
        many(t, "credits").sorted {
            let a = (int($0, "order") ?? 0, str($0, "role") ?? "", str($0, "instrument") ?? "", partyID(of: $0) ?? "")
            let b = (int($1, "order") ?? 0, str($1, "role") ?? "", str($1, "instrument") ?? "", partyID(of: $1) ?? "")
            return a < b
        }
    }

    private func partyID(of c: NSManagedObject) -> String? { (c.value(forKey: "party") as? NSManagedObject).flatMap { str($0, "uid") } }

    /// Everything the library knows about one person's credits, grouped by capacity, with the people they were credited alongside.
    func creditGraph(partyID id: String, collaboratorLimit: Int = 60) -> CreditGraphDTO? {
        ctx.performAndWait {
            guard let person = one("Party", "uid == %@", id) else { return nil }
            let tracks = creditedTracks(partyID: id)

            struct Rec { var title: String; var year: Int?; var artists: [String]; var roles: [CreditRoleDTO]; var tracks: [String: CreditedTrackDTO]; var order: [String] }
            var perCategory: [CreditCategory: [String: Rec]] = [:]
            var allReleases = Set<String>()
            struct Collab { var name: String; var kind: String; var releases = Set<String>(); var tracks = 0; var roles: [CreditRoleDTO: Int] = [:] }
            var collabs: [String: Collab] = [:]

            for t in tracks {
                let tid = str(t, "uid") ?? ""
                let rel = t.value(forKey: "release") as? NSManagedObject
                let rid = rel.flatMap { str($0, "uid") } ?? "track:" + tid
                allReleases.insert(rid)
                let credits = orderedCredits(t)
                let mine = credits.filter { partyID(of: $0) == id }
                let title = str(t, "title") ?? "", number = int(t, "trackNumber"), disc = int(t, "discNumber")
                // the record's artist line: its album artists, else the artists on this track
                func names(_ roles: Set<String>) -> [String] {
                    var out: [String] = []
                    for c in credits where roles.contains(str(c, "role") ?? "") {
                        if let n = (c.value(forKey: "party") as? NSManagedObject).flatMap({ str($0, "name") }), !out.contains(n) { out.append(n) }
                    }
                    return out
                }
                let albumArtists = names(["albumArtist"])
                let artists = albumArtists.isEmpty ? names(["artist"]) : albumArtists

                var byCategory: [CreditCategory: [CreditRoleDTO]] = [:]
                for c in mine {
                    guard let role = CreditRole(rawValue: str(c, "role") ?? "") else { continue }
                    let d = roleDTO(c)
                    if !(byCategory[CreditCategory(role: role)]?.contains(d) ?? false) { byCategory[CreditCategory(role: role), default: []].append(d) }
                }
                for (cat, roles) in byCategory {
                    var rec = perCategory[cat]?[rid] ?? Rec(title: rel.flatMap { str($0, "title") } ?? title, year: rel.flatMap { int($0, "year") } ?? int(t, "year"), artists: artists, roles: [], tracks: [:], order: [])
                    for r in roles where !rec.roles.contains(r) { rec.roles.append(r) }
                    if rec.artists.isEmpty { rec.artists = artists }
                    if rec.tracks[tid] == nil { rec.order.append(tid) }
                    rec.tracks[tid] = CreditedTrackDTO(id: tid, title: title, trackNumber: number, discNumber: disc, roles: roles)
                    perCategory[cat, default: [:]][rid] = rec
                }

                // the others credited on this track
                var seenHere = Set<String>()
                for c in credits {
                    guard let pid = partyID(of: c), pid != id, let p = c.value(forKey: "party") as? NSManagedObject else { continue }
                    var e = collabs[pid] ?? Collab(name: str(p, "name") ?? "", kind: str(p, "kind") ?? "person")
                    if seenHere.insert(pid).inserted { e.tracks += 1; e.releases.insert(rid) }
                    e.roles[roleDTO(c), default: 0] += 1
                    collabs[pid] = e
                }
            }

            func sortKey(_ r: CreditedReleaseDTO) -> (Int, String) { (r.year ?? 9999, r.title.lowercased()) }
            let sections: [CreditSectionDTO] = CreditCategory.allCases.compactMap { cat in
                guard let recs = perCategory[cat], !recs.isEmpty else { return nil }
                let releases = recs.map { (rid, rec) -> CreditedReleaseDTO in
                    let ts = rec.tracks.values.sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0, $0.title, $0.id) < ($1.discNumber ?? 1, $1.trackNumber ?? 0, $1.title, $1.id) }
                    return CreditedReleaseDTO(id: rid, title: rec.title, year: rec.year, artistNames: Array(rec.artists.prefix(3)), roles: rec.roles, tracks: ts)
                }.sorted { let x = sortKey($0), y = sortKey($1); return (x.0, x.1, $0.id) < (y.0, y.1, $1.id) }
                return CreditSectionDTO(category: cat, releases: releases)
            }
            let collaborators = collabs.map { pid, e in
                CollaboratorDTO(partyID: pid, name: e.name, kind: e.kind, sharedReleases: e.releases.count, sharedTracks: e.tracks,
                                roles: e.roles.sorted { ($1.value, $0.key.label) < ($0.value, $1.key.label) }.prefix(3).map { $0.key })
            }.sorted { ($0.sharedReleases, $0.sharedTracks, $1.name, $1.partyID) > ($1.sharedReleases, $1.sharedTracks, $0.name, $0.partyID) }

            return CreditGraphDTO(person: partyDTO(person), sections: sections, collaborators: Array(collaborators.prefix(collaboratorLimit)),
                                  releaseCount: allReleases.count, trackCount: tracks.count)
        }
    }

    /// The records two people were both credited on, with what each did there.
    func sharedCredits(_ a: String, _ b: String) -> SharedCreditsDTO? {
        ctx.performAndWait {
            guard let pa = one("Party", "uid == %@", a), let pb = one("Party", "uid == %@", b) else { return nil }
            var recs: [String: (title: String, year: Int?, first: [CreditRoleDTO], second: [CreditRoleDTO], tracks: Int)] = [:]
            for t in creditedTracks(partyID: a) {
                let credits = orderedCredits(t)
                let theirs = credits.filter { partyID(of: $0) == b }
                guard !theirs.isEmpty else { continue }
                let rel = t.value(forKey: "release") as? NSManagedObject
                let rid = rel.flatMap { str($0, "uid") } ?? "track:" + (str(t, "uid") ?? "")
                var r = recs[rid] ?? (rel.flatMap { str($0, "title") } ?? str(t, "title") ?? "", rel.flatMap { int($0, "year") } ?? int(t, "year"), [], [], 0)
                for c in credits where partyID(of: c) == a { let d = roleDTO(c); if !r.first.contains(d) { r.first.append(d) } }
                for c in theirs { let d = roleDTO(c); if !r.second.contains(d) { r.second.append(d) } }
                r.tracks += 1
                recs[rid] = r
            }
            let list = recs.map { SharedCreditsDTO.Shared(id: $0.key, title: $0.value.title, year: $0.value.year, first: $0.value.first, second: $0.value.second, trackCount: $0.value.tracks) }
                .sorted { ($0.year ?? 9999, $0.title.lowercased()) < ($1.year ?? 9999, $1.title.lowercased()) }
            return SharedCreditsDTO(first: partyDTO(pa), second: partyDTO(pb), records: list)
        }
    }

    /// Everyone with at least one credit, in any capacity, matching `search`.
    func people(search: String? = nil, limit: Int = 500) -> [PartyDTO] {
        ctx.performAndWait {
            var preds = [NSPredicate(format: "credits.@count > 0")]
            if let s = search, !s.isEmpty { preds.append(NSPredicate(format: "key CONTAINS %@", Self.fold(s))) }
            return fetch("Party", NSCompoundPredicate(andPredicateWithSubpredicates: preds),
                         sort: [NSSortDescriptor(key: "sortName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))], limit: limit).map { partyDTO($0) }
        }
    }
}

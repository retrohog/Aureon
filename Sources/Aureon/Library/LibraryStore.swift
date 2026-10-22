import Foundation
import CoreData

/// The music library: Core Data with a programmatic model (no .xcdatamodeld, so it builds with the Command Line Tools).
///
///   Track ──< Credit >── Party            multi-valued: any number of artists/composers/conductors/ensembles/soloists per track
///   Track >── Release                      albums, discs
///   Track >── Work ──< Movement ──< Track  classical ontology: Work (catalogue number, key) has Movements; Work >── composer Party
///   Track >──< Genre
///   Change                                 append-only log (revision, kind, uid, op) so a remote client can sync deltas
final class LibraryStore: @unchecked Sendable {
    private let ctx: NSManagedObjectContext
    private var rev: Int64 = 0
    private var seqCounter: Int64 = 0       // unique, gap-free cursor over the change log (a batch shares one revision but every row has its own seq)

    // MARK: model

    private static let model: NSManagedObjectModel = {
        func ent(_ name: String, _ attrs: [(String, NSAttributeType, Bool)]) -> NSEntityDescription {
            let e = NSEntityDescription(); e.name = name; e.managedObjectClassName = "NSManagedObject"
            e.properties = attrs.map { n, t, optional in let a = NSAttributeDescription(); a.name = n; a.attributeType = t; a.isOptional = optional; return a }
            return e
        }
        func link(_ a: NSEntityDescription, _ an: String, _ aMany: Bool, _ aRule: NSDeleteRule, _ b: NSEntityDescription, _ bn: String, _ bMany: Bool, _ bRule: NSDeleteRule) {
            let r1 = NSRelationshipDescription(), r2 = NSRelationshipDescription()
            r1.name = an; r1.destinationEntity = b; r1.isOptional = true; r1.deleteRule = aRule; r1.minCount = 0; r1.maxCount = aMany ? 0 : 1
            r2.name = bn; r2.destinationEntity = a; r2.isOptional = true; r2.deleteRule = bRule; r2.minCount = 0; r2.maxCount = bMany ? 0 : 1
            r1.inverseRelationship = r2; r2.inverseRelationship = r1
            a.properties.append(r1); b.properties.append(r2)
        }
        let s = NSAttributeType.stringAttributeType, i = NSAttributeType.integer32AttributeType, d = NSAttributeType.doubleAttributeType
        let l = NSAttributeType.integer64AttributeType, bo = NSAttributeType.booleanAttributeType
        let track = ent("Track", [("uid", s, false), ("path", s, false), ("title", s, true), ("trackNumber", i, true), ("discNumber", i, true),
                                  ("duration", d, true), ("sampleRate", d, true), ("bitDepth", i, true), ("channels", i, true), ("codec", s, true),
                                  ("fileSize", l, true), ("fileMTime", d, true), ("year", i, true), ("mbRecordingID", s, true), ("workInferred", bo, true), ("addedAt", d, true),
                                  ("liked", bo, true), ("likedAt", d, true), ("playCount", i, true), ("lastPlayedAt", d, true)])
        let release = ent("Release", [("uid", s, false), ("key", s, false), ("title", s, true), ("year", i, true), ("mbReleaseID", s, true), ("label", s, true), ("catalogNumber", s, true)])
        let party = ent("Party", [("uid", s, false), ("key", s, false), ("name", s, false), ("sortName", s, true), ("kind", s, true), ("mbArtistID", s, true)])
        let credit = ent("Credit", [("role", s, false), ("instrument", s, true), ("order", i, true)])
        let work = ent("Work", [("uid", s, false), ("key", s, false), ("title", s, false), ("catalogNumber", s, true), ("musicalKey", s, true), ("mbWorkID", s, true)])
        let movement = ent("Movement", [("uid", s, false), ("number", i, true), ("total", i, true), ("title", s, true)])
        let genre = ent("Genre", [("name", s, false)])
        let playlist = ent("Playlist", [("uid", s, false), ("name", s, false), ("createdAt", d, true), ("updatedAt", d, true)])
        let entry = ent("PlaylistEntry", [("order", i, true), ("addedAt", d, true)])
        let change = ent("Change", [("seq", l, false), ("revision", l, false), ("kind", s, false), ("uid", s, false), ("op", s, false), ("at", d, true)])
        link(track, "release", false, .nullifyDeleteRule, release, "tracks", true, .nullifyDeleteRule)
        link(track, "work", false, .nullifyDeleteRule, work, "tracks", true, .nullifyDeleteRule)
        link(track, "movement", false, .nullifyDeleteRule, movement, "tracks", true, .nullifyDeleteRule)
        link(track, "credits", true, .cascadeDeleteRule, credit, "track", false, .nullifyDeleteRule)
        link(credit, "party", false, .nullifyDeleteRule, party, "credits", true, .cascadeDeleteRule)
        link(work, "composer", false, .nullifyDeleteRule, party, "composedWorks", true, .nullifyDeleteRule)
        link(work, "movements", true, .cascadeDeleteRule, movement, "work", false, .nullifyDeleteRule)
        link(track, "genres", true, .nullifyDeleteRule, genre, "tracks", true, .nullifyDeleteRule)
        link(playlist, "entries", true, .cascadeDeleteRule, entry, "playlist", false, .nullifyDeleteRule)
        link(track, "playlistEntries", true, .cascadeDeleteRule, entry, "track", false, .nullifyDeleteRule)
        let m = NSManagedObjectModel(); m.entities = [track, release, party, credit, work, movement, genre, change, playlist, entry]
        return m
    }()

    // MARK: lifecycle

    /// `url == nil` keeps the library in memory (tests, previews).
    init(url: URL? = nil) throws {
        let coord = NSPersistentStoreCoordinator(managedObjectModel: Self.model)
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coord.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                         options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        } else {
            // An in-memory *SQLite* store (the /dev/null URL): predicates compile to SQL exactly as with the on-disk library,
            // unlike NSInMemoryStoreType, which evaluates them in Foundation and rejects some key-path forms.
            try coord.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: "/dev/null"), options: nil)
        }
        ctx = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        ctx.persistentStoreCoordinator = coord
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        ctx.performAndWait {
            let f = NSFetchRequest<NSDictionary>(entityName: "Change"); f.resultType = .dictionaryResultType
            f.propertiesToFetch = ["revision", "seq"]; f.sortDescriptors = [NSSortDescriptor(key: "seq", ascending: false)]; f.fetchLimit = 1
            let last = (try? ctx.fetch(f))?.first
            rev = (last?["revision"] as? Int64) ?? 0; seqCounter = (last?["seq"] as? Int64) ?? 0
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Library.sqlite")
    }

    var revision: Int64 { ctx.performAndWait { rev } }

    // MARK: normalisation & KVC helpers

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func str(_ o: NSManagedObject, _ k: String) -> String? { o.value(forKey: k) as? String }
    private func int(_ o: NSManagedObject, _ k: String) -> Int? { (o.value(forKey: k) as? NSNumber).map(\.intValue) }
    private func dbl(_ o: NSManagedObject, _ k: String) -> Double { (o.value(forKey: k) as? NSNumber)?.doubleValue ?? 0 }
    private func set(_ o: NSManagedObject, _ k: String, _ v: Any?) { o.setValue(v, forKey: k) }
    private func many(_ o: NSManagedObject, _ k: String) -> [NSManagedObject] { Array((o.value(forKey: k) as? Set<NSManagedObject>) ?? []) }

    private func fetch(_ entity: String, _ predicate: NSPredicate? = nil, sort: [NSSortDescriptor] = [], limit: Int = 0) -> [NSManagedObject] {
        let r = NSFetchRequest<NSManagedObject>(entityName: entity)
        r.predicate = predicate; r.sortDescriptors = sort; r.fetchLimit = limit
        return (try? ctx.fetch(r)) ?? []
    }
    private func one(_ entity: String, _ format: String, _ args: CVarArg...) -> NSManagedObject? {
        fetch(entity, NSPredicate(format: format, argumentArray: args), limit: 1).first
    }

    // MARK: ingest

    private struct Touched { var tracks = Set<String>(), releases = Set<String>(), parties = Set<String>(), works = Set<String>() }

    /// Inserts or updates tracks. All changes in one call share a single revision.
    @discardableResult
    func upsert(_ items: [(facts: FileFacts, tags: TrackMetadata)]) -> (added: Int, updated: Int) {
        ctx.performAndWait {
            var added = 0, updated = 0
            var touched = Touched()
            for item in items {
                let existing = one("Track", "path == %@", item.facts.path)
                let t = existing ?? NSEntityDescription.insertNewObject(forEntityName: "Track", into: ctx)
                if existing == nil { set(t, "uid", UUID().uuidString); set(t, "path", item.facts.path); set(t, "addedAt", Date().timeIntervalSince1970); added += 1 } else { updated += 1 }
                apply(item.tags, item.facts, to: t, &touched)
            }
            commit(touched, deleted: [])
            return (added, updated)
        }
    }

    private func party(_ c: Credit, _ touched: inout Touched) -> NSManagedObject {
        let key = Self.fold(c.name)
        var p: NSManagedObject? = c.mbid.flatMap { one("Party", "mbArtistID == %@", $0) } ?? one("Party", "key == %@", key)
        if p == nil {
            p = NSEntityDescription.insertNewObject(forEntityName: "Party", into: ctx)
            set(p!, "uid", UUID().uuidString); set(p!, "key", key); set(p!, "name", c.name)
        }
        if let id = c.mbid, str(p!, "mbArtistID") == nil { set(p!, "mbArtistID", id) }
        if let sort = c.sortName, str(p!, "sortName") == nil { set(p!, "sortName", sort) }
        if str(p!, "sortName") == nil { set(p!, "sortName", c.name) }
        let ensembleWords = ["orchestra", "orchester", "philharmon", "symphon", "quartet", "quintet", "trio", "choir", "chorus", "ensemble", "consort", "band", "sinfonia", "kammer"]
        let looksLikeGroup = c.role == .ensemble || ensembleWords.contains { key.contains($0) }
        if str(p!, "kind") == nil || looksLikeGroup { set(p!, "kind", looksLikeGroup ? "group" : "person") }
        touched.parties.insert(str(p!, "uid")!)
        return p!
    }

    private func apply(_ m: TrackMetadata, _ f: FileFacts, to t: NSManagedObject, _ touched: inout Touched) {
        set(t, "title", m.title); set(t, "trackNumber", m.trackNumber); set(t, "discNumber", m.discNumber)
        set(t, "duration", f.duration); set(t, "sampleRate", f.sampleRate); set(t, "bitDepth", f.bitDepth); set(t, "channels", f.channels)
        set(t, "codec", f.codec); set(t, "fileSize", f.size); set(t, "fileMTime", f.mtime); set(t, "year", m.year)
        set(t, "mbRecordingID", m.mbRecordingID); set(t, "workInferred", m.workInferred)

        // credits (replace the whole set: a re-tagged file may have removed people)
        for c in many(t, "credits") { ctx.delete(c) }
        for (i, c) in m.credits.enumerated() {
            let cr = NSEntityDescription.insertNewObject(forEntityName: "Credit", into: ctx)
            set(cr, "role", c.role.rawValue); set(cr, "instrument", c.instrument); set(cr, "order", i)
            set(cr, "track", t); set(cr, "party", party(c, &touched))
        }

        // release
        if let rel = releaseObject(m, &touched) { set(t, "release", rel) } else { set(t, "release", nil) }

        // genres
        let wanted = Set(m.genres.map { Self.fold($0) })
        var have: [String: NSManagedObject] = [:]
        for g in many(t, "genres") { have[Self.fold(str(g, "name") ?? "")] = g }
        for (k, g) in have where !wanted.contains(k) { (t.mutableSetValue(forKey: "genres")).remove(g) }
        for g in m.genres where have[Self.fold(g)] == nil {
            let go = one("Genre", "name ==[cd] %@", g) ?? { let o = NSEntityDescription.insertNewObject(forEntityName: "Genre", into: ctx); set(o, "name", g); return o }()
            t.mutableSetValue(forKey: "genres").add(go)
        }

        // work and movement
        if let wt = m.workTitle {
            let composer = m.composers.first
            let composerObj = composer.map { party($0, &touched) }
            let wkey = [composerObj.flatMap { str($0, "key") } ?? "", Self.fold(wt), Self.fold(m.catalog ?? "")].joined(separator: "|")
            var w = one("Work", "key == %@", wkey)
            if w == nil {
                w = NSEntityDescription.insertNewObject(forEntityName: "Work", into: ctx)
                set(w!, "uid", UUID().uuidString); set(w!, "key", wkey); set(w!, "title", wt)
            }
            set(w!, "catalogNumber", m.catalog); set(w!, "musicalKey", m.key); set(w!, "mbWorkID", m.mbWorkID)
            if let c = composerObj { set(w!, "composer", c) }
            set(t, "work", w)
            touched.works.insert(str(w!, "uid")!)
            if m.movementNumber != nil || m.movementTitle != nil {
                let mv = many(w!, "movements").first {
                    (m.movementNumber != nil && int($0, "number") == m.movementNumber) || (m.movementNumber == nil && str($0, "title").map(Self.fold) == m.movementTitle.map(Self.fold))
                } ?? {
                    let o = NSEntityDescription.insertNewObject(forEntityName: "Movement", into: ctx)
                    set(o, "uid", UUID().uuidString); set(o, "work", w!); return o
                }()
                set(mv, "number", m.movementNumber); set(mv, "total", m.movementTotal); if let n = m.movementTitle { set(mv, "title", n) }
                set(t, "movement", mv)
            } else { set(t, "movement", nil) }
        } else { set(t, "work", nil); set(t, "movement", nil) }
        touched.tracks.insert(str(t, "uid")!)
    }

    private func releaseObject(_ m: TrackMetadata, _ touched: inout Touched) -> NSManagedObject? {
        guard let album = m.album else { return nil }
        let albumArtist = (m.credits(.albumArtist).first ?? m.credits(.artist).first)?.name ?? ""
        let key = m.mbReleaseID ?? (Self.fold(album) + "|" + Self.fold(albumArtist))
        var r = one("Release", "key == %@", key)
        if r == nil {
            r = NSEntityDescription.insertNewObject(forEntityName: "Release", into: ctx)
            set(r!, "uid", UUID().uuidString); set(r!, "key", key)
        }
        set(r!, "title", album); set(r!, "mbReleaseID", m.mbReleaseID); set(r!, "label", m.label); set(r!, "catalogNumber", m.releaseCatalogNumber)
        if let y = m.year, int(r!, "year") == nil || int(r!, "year")! > y { set(r!, "year", y) }
        touched.releases.insert(str(r!, "uid")!)
        return r
    }

    private func commit(_ touched: Touched, deleted: [(kind: String, uid: String)]) {
        guard !touched.tracks.isEmpty || !touched.releases.isEmpty || !touched.parties.isEmpty || !touched.works.isEmpty || !deleted.isEmpty else { return }
        rev += 1
        let now = Date().timeIntervalSince1970
        func log(_ kind: String, _ uid: String, _ op: String) {
            let c = NSEntityDescription.insertNewObject(forEntityName: "Change", into: ctx)
            seqCounter += 1; set(c, "seq", seqCounter)
            set(c, "revision", rev); set(c, "kind", kind); set(c, "uid", uid); set(c, "op", op); set(c, "at", now)
        }
        for u in touched.tracks { log("track", u, "upsert") }
        for u in touched.releases { log("release", u, "upsert") }
        for u in touched.parties { log("party", u, "upsert") }
        for u in touched.works { log("work", u, "upsert") }
        for d in deleted { log(d.kind, d.uid, "delete") }
        try? ctx.save()
    }

    // MARK: removal

    /// Deletes tracks (and anything left orphaned) whose files are gone.
    @discardableResult
    func removeTracks(under root: String, keeping existing: Set<String>) -> Int {
        ctx.performAndWait {
            var deleted: [(kind: String, uid: String)] = []
            let prefix = root.hasSuffix("/") ? root : root + "/"
            for t in fetch("Track", NSPredicate(format: "path BEGINSWITH %@", prefix)) where !existing.contains(str(t, "path") ?? "") {
                deleted.append(("track", str(t, "uid") ?? "")); ctx.delete(t)
            }
            guard !deleted.isEmpty else { return 0 }
            try? ctx.save()
            deleted += pruneOrphans()
            commit(Touched(), deleted: deleted)
            return deleted.filter { $0.kind == "track" }.count
        }
    }

    private func pruneOrphans() -> [(kind: String, uid: String)] {
        var out: [(kind: String, uid: String)] = []
        for r in fetch("Release", NSPredicate(format: "tracks.@count == 0")) { out.append(("release", str(r, "uid") ?? "")); ctx.delete(r) }
        for m in fetch("Movement", NSPredicate(format: "tracks.@count == 0")) { ctx.delete(m) }
        for w in fetch("Work", NSPredicate(format: "tracks.@count == 0")) { out.append(("work", str(w, "uid") ?? "")); ctx.delete(w) }
        for g in fetch("Genre", NSPredicate(format: "tracks.@count == 0")) { ctx.delete(g) }
        try? ctx.save()
        for p in fetch("Party", NSPredicate(format: "credits.@count == 0 AND composedWorks.@count == 0")) { out.append(("party", str(p, "uid") ?? "")); ctx.delete(p) }
        try? ctx.save()
        return out
    }

    func knownFile(_ path: String) -> (mtime: Double, size: Int64)? {
        ctx.performAndWait { one("Track", "path == %@", path).map { (dbl($0, "fileMTime"), Int64(dbl($0, "fileSize"))) } }
    }

    // MARK: DTO builders (call inside performAndWait)

    private func creditDTO(_ c: NSManagedObject) -> CreditDTO? {
        guard let p = c.value(forKey: "party") as? NSManagedObject else { return nil }
        return CreditDTO(role: str(c, "role") ?? "", name: str(p, "name") ?? "", instrument: str(c, "instrument"), partyID: str(p, "uid") ?? "")
    }

    private func trackDTO(_ t: NSManagedObject) -> TrackDTO {
        let rel = t.value(forKey: "release") as? NSManagedObject, work = t.value(forKey: "work") as? NSManagedObject, mv = t.value(forKey: "movement") as? NSManagedObject
        let credits = many(t, "credits").sorted { (int($0, "order") ?? 0) < (int($1, "order") ?? 0) }.compactMap(creditDTO)
        return TrackDTO(id: str(t, "uid") ?? "", path: str(t, "path") ?? "", title: str(t, "title") ?? "", trackNumber: int(t, "trackNumber"), discNumber: int(t, "discNumber"),
                        duration: dbl(t, "duration"), codec: str(t, "codec") ?? "", sampleRate: dbl(t, "sampleRate"), bitDepth: int(t, "bitDepth") ?? 0, channels: int(t, "channels") ?? 0,
                        year: int(t, "year"), releaseID: rel.flatMap { str($0, "uid") }, releaseTitle: rel.flatMap { str($0, "title") },
                        workID: work.flatMap { str($0, "uid") }, workTitle: work.flatMap { str($0, "title") }, catalog: work.flatMap { str($0, "catalogNumber") },
                        movementID: mv.flatMap { str($0, "uid") }, movementNumber: mv.flatMap { int($0, "number") }, movementTitle: mv.flatMap { str($0, "title") },
                        credits: credits, genres: many(t, "genres").compactMap { str($0, "name") }.sorted(), mbRecordingID: str(t, "mbRecordingID"),
                        addedAt: dbl(t, "addedAt") > 0 ? dbl(t, "addedAt") : nil, fileSize: Int64(dbl(t, "fileSize")),
                        liked: (t.value(forKey: "liked") as? NSNumber)?.boolValue == true ? true : nil, playCount: int(t, "playCount").flatMap { $0 > 0 ? $0 : nil },
                        lastPlayedAt: dbl(t, "lastPlayedAt") > 0 ? dbl(t, "lastPlayedAt") : nil)
    }

    private func partyDTO(_ p: NSManagedObject, role: CreditRole? = nil) -> PartyDTO {
        let credits = many(p, "credits").filter { role == nil || str($0, "role") == role!.rawValue || (role == .artist && (str($0, "role") == "featured" || str($0, "role") == "albumArtist")) }
        var count = Set(credits.compactMap { ($0.value(forKey: "track") as? NSManagedObject)?.objectID }).count
        if role == .composer { count = max(count, many(p, "composedWorks").reduce(0) { $0 + many($1, "tracks").count }) }
        return PartyDTO(id: str(p, "uid") ?? "", name: str(p, "name") ?? "", sortName: str(p, "sortName") ?? "", kind: str(p, "kind") ?? "person", count: count, mbArtistID: str(p, "mbArtistID"))
    }

    private func workDTO(_ w: NSManagedObject) -> WorkDTO {
        let tracks = many(w, "tracks"), composer = w.value(forKey: "composer") as? NSManagedObject
        let recordings = Set(tracks.compactMap { ($0.value(forKey: "release") as? NSManagedObject)?.objectID })
        return WorkDTO(id: str(w, "uid") ?? "", title: str(w, "title") ?? "", catalog: str(w, "catalogNumber"), key: str(w, "musicalKey"),
                       composerID: composer.flatMap { str($0, "uid") }, composerName: composer.flatMap { str($0, "name") },
                       movementCount: many(w, "movements").count, trackCount: tracks.count, recordingCount: max(recordings.count, tracks.isEmpty ? 0 : 1))
    }

    private func releaseDTO(_ r: NSManagedObject) -> ReleaseDTO {
        let tracks = many(r, "tracks")
        var seen = Set<String>(), artists: [String] = []
        for t in tracks { for c in many(t, "credits") where str(c, "role") == "albumArtist" || str(c, "role") == "artist" {
            if let n = (c.value(forKey: "party") as? NSManagedObject).flatMap({ str($0, "name") }), seen.insert(n).inserted { artists.append(n) } } }
        let genre = tracks.lazy.compactMap { self.many($0, "genres").compactMap { self.str($0, "name") }.sorted().first }.first
        return ReleaseDTO(id: str(r, "uid") ?? "", title: str(r, "title") ?? "", year: int(r, "year"), trackCount: tracks.count, artistNames: Array(artists.prefix(4)), mbReleaseID: str(r, "mbReleaseID"),
                          maxSampleRate: tracks.map { dbl($0, "sampleRate") }.max(), maxBitDepth: tracks.compactMap { int($0, "bitDepth") }.max(), genre: genre,
                          addedAt: tracks.map { dbl($0, "addedAt") }.max())
    }

    // MARK: queries

    private static func trackOrder(_ a: TrackDTO, _ b: TrackDTO) -> Bool {
        (a.discNumber ?? 1, a.movementNumber ?? a.trackNumber ?? 0, a.trackNumber ?? 0, a.title) < (b.discNumber ?? 1, b.movementNumber ?? b.trackNumber ?? 0, b.trackNumber ?? 0, b.title)
    }

    func stats() -> LibraryStats {
        ctx.performAndWait {
            func count(_ e: String, _ p: NSPredicate? = nil) -> Int { let r = NSFetchRequest<NSManagedObject>(entityName: e); r.predicate = p; return (try? ctx.count(for: r)) ?? 0 }
            return LibraryStats(tracks: count("Track"), releases: count("Release"), works: count("Work"),
                                composers: count("Party", NSPredicate(format: "ANY credits.role == %@", "composer")),
                                artists: count("Party", NSPredicate(format: "ANY credits.role == %@ OR ANY credits.role == %@", "artist", "albumArtist")), revision: rev)
        }
    }

    func parties(role: CreditRole, search: String? = nil, limit: Int = 500) -> [PartyDTO] {
        ctx.performAndWait {
            var preds = [role == .artist ? NSPredicate(format: "ANY credits.role == %@ OR ANY credits.role == %@ OR ANY credits.role == %@", "artist", "featured", "albumArtist") : NSPredicate(format: "ANY credits.role == %@", role.rawValue)]
            if let s = search, !s.isEmpty { preds.append(NSPredicate(format: "key CONTAINS %@", Self.fold(s))) }
            return fetch("Party", NSCompoundPredicate(andPredicateWithSubpredicates: preds), sort: [NSSortDescriptor(key: "sortName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))], limit: limit)
                .map { partyDTO($0, role: role) }
        }
    }

    func works(composerID: String? = nil, search: String? = nil, limit: Int = 500) -> [WorkDTO] {
        ctx.performAndWait {
            var preds: [NSPredicate] = []
            if let c = composerID { preds.append(NSPredicate(format: "composer.uid == %@", c)) }
            if let s = search, !s.isEmpty { preds.append(NSPredicate(format: "key CONTAINS %@", Self.fold(s))) }
            let w = fetch("Work", preds.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: preds), sort: [NSSortDescriptor(key: "title", ascending: true)], limit: limit)
            return w.map(workDTO)
        }
    }

    func releases(search: String? = nil, partyID: String? = nil, limit: Int = 500) -> [ReleaseDTO] {
        ctx.performAndWait {
            var preds: [NSPredicate] = []
            if let s = search, !s.isEmpty { preds.append(NSPredicate(format: "key CONTAINS %@", Self.fold(s))) }
            if let p = partyID {
                // two to-many hops are not allowed in one predicate: find the party's tracks first, then their releases
                let uids = Set(fetch("Track", NSPredicate(format: "ANY credits.party.uid == %@", p)).compactMap { ($0.value(forKey: "release") as? NSManagedObject).flatMap { str($0, "uid") } })
                preds.append(NSPredicate(format: "uid IN %@", uids))
            }
            return fetch("Release", preds.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: preds), sort: [NSSortDescriptor(key: "title", ascending: true)], limit: limit).map(releaseDTO)
        }
    }

    func tracks(releaseID: String? = nil, workID: String? = nil, partyID: String? = nil, role: CreditRole? = nil, limit: Int = 5000) -> [TrackDTO] {
        ctx.performAndWait {
            var preds: [NSPredicate] = []
            if let r = releaseID { preds.append(NSPredicate(format: "release.uid == %@", r)) }
            if let w = workID { preds.append(NSPredicate(format: "work.uid == %@", w)) }
            if let p = partyID {
                preds.append(role.map { r in
                    r == .artist ? NSPredicate(format: "SUBQUERY(credits, $c, $c.party.uid == %@ AND ($c.role == %@ OR $c.role == %@ OR $c.role == %@)).@count > 0", p, "artist", "featured", "albumArtist")
                                 : NSPredicate(format: "SUBQUERY(credits, $c, $c.party.uid == %@ AND $c.role == %@).@count > 0", p, r.rawValue) } ?? NSPredicate(format: "ANY credits.party.uid == %@", p))
            }
            return fetch("Track", preds.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: preds), limit: limit).map(trackDTO).sorted(by: Self.trackOrder)
        }
    }

    /// The recordings of a work: its tracks grouped by release, with conductor / ensembles / soloists.
    func recordings(workID: String) -> [RecordingGroupDTO] {
        ctx.performAndWait {
            let tracks = fetch("Track", NSPredicate(format: "work.uid == %@", workID)).map(trackDTO).sorted(by: Self.trackOrder)
            var groups: [String: [TrackDTO]] = [:], order: [String] = []
            for t in tracks { let k = t.releaseID ?? "none-\(t.id)"; if groups[k] == nil { order.append(k) }; groups[k, default: []].append(t) }
            let rank: [String: Int] = ["conductor": 0, "ensemble": 1, "soloist": 2, "performer": 3]
            return order.map { k in
                let ts = groups[k]!
                var perf: [CreditDTO] = [], seen = Set<String>()
                for c in ts.flatMap(\.credits) where rank[c.role] != nil && seen.insert(c.role + "|" + c.name + "|" + (c.instrument ?? "")).inserted { perf.append(c) }
                perf.sort { (rank[$0.role] ?? 9, $0.name) < (rank[$1.role] ?? 9, $1.name) }
                return RecordingGroupDTO(id: k, releaseTitle: ts[0].releaseTitle ?? "Unknown release", year: ts.compactMap(\.year).min(), performers: perf, tracks: ts)
            }.sorted { ($0.year ?? 9999, $0.releaseTitle) < ($1.year ?? 9999, $1.releaseTitle) }
        }
    }

    /// One query for many paths (the queue view): path → track, for files that are in the library.
    func tracks(paths: [String]) -> [String: TrackDTO] {
        guard !paths.isEmpty else { return [:] }
        return ctx.performAndWait {
            var out: [String: TrackDTO] = [:]
            for t in fetch("Track", NSPredicate(format: "path IN %@", paths)) { let d = trackDTO(t); out[d.path] = d }
            return out
        }
    }

    func track(id: String) -> TrackDTO? { ctx.performAndWait { one("Track", "uid == %@", id).map(trackDTO) } }
    func track(path: String) -> TrackDTO? { ctx.performAndWait { one("Track", "path == %@", path).map(trackDTO) } }
    func allTracks(offset: Int = 0, limit: Int = 500) -> [TrackDTO] {
        ctx.performAndWait {
            let r = NSFetchRequest<NSManagedObject>(entityName: "Track"); r.fetchOffset = offset; r.fetchLimit = limit
            r.sortDescriptors = [NSSortDescriptor(key: "path", ascending: true)]
            return ((try? ctx.fetch(r)) ?? []).map(trackDTO)
        }
    }

    func search(_ q: String, limit: Int = 30) -> SearchResults {
        let f = Self.fold(q)
        guard !f.isEmpty else { return SearchResults() }
        return ctx.performAndWait {
            let tr = fetch("Track", NSPredicate(format: "title CONTAINS[cd] %@ OR ANY credits.party.key CONTAINS %@ OR work.key CONTAINS %@ OR release.key CONTAINS %@", q, f, f, f), limit: limit)
            return SearchResults(tracks: tr.map(trackDTO).sorted(by: Self.trackOrder),
                                 works: fetch("Work", NSPredicate(format: "key CONTAINS %@", f), limit: limit).map(workDTO),
                                 parties: fetch("Party", NSPredicate(format: "key CONTAINS %@", f), limit: limit).map { partyDTO($0) },
                                 releases: fetch("Release", NSPredicate(format: "key CONTAINS %@", f), limit: limit).map(releaseDTO))
        }
    }

    // MARK: change log (for remote sync)

    private func changeDTOs(_ raw: [NSManagedObject]) -> [LibraryChange] {
        raw.map { c in
            let kind = str(c, "kind") ?? "", uid = str(c, "uid") ?? "", op = str(c, "op") ?? ""
            var ch = LibraryChange(seq: (c.value(forKey: "seq") as? NSNumber)?.int64Value ?? 0, revision: (c.value(forKey: "revision") as? NSNumber)?.int64Value ?? 0, kind: kind, uid: uid, op: op)
            if op == "upsert" {
                switch kind {
                case "track": ch.track = one("Track", "uid == %@", uid).map(trackDTO)
                case "party": ch.party = one("Party", "uid == %@", uid).map { partyDTO($0) }
                case "release": ch.release = one("Release", "uid == %@", uid).map(releaseDTO)
                case "work": ch.work = one("Work", "uid == %@", uid).map(workDTO)
                default: break
                }
            }
            return ch
        }
    }

    /// Changes made after revision `since` (a batch shares one revision).
    func changes(since: Int64, limit: Int = 100_000) -> [LibraryChange] {
        ctx.performAndWait { changeDTOs(fetch("Change", NSPredicate(format: "revision > %lld", since), sort: [NSSortDescriptor(key: "seq", ascending: true)], limit: limit)) }
    }

    /// Pages through the change log by its unique sequence number: the cursor a sync client keeps. Never skips or repeats a change.
    func changes(afterSeq cursor: Int64, limit: Int = 500) -> [LibraryChange] {
        ctx.performAndWait { changeDTOs(fetch("Change", NSPredicate(format: "seq > %lld", cursor), sort: [NSSortDescriptor(key: "seq", ascending: true)], limit: limit)) }
    }

    var lastSeq: Int64 { ctx.performAndWait { seqCounter } }

    // MARK: folder import

    static let audioExtensions: Set<String> = ["flac", "m4a", "alac", "wav", "aif", "aiff", "caf"]

    /// Scans `folder`, reading tags (never decoding audio) and updating the library. Unchanged files are skipped by mtime/size.
    func importFolder(_ folder: URL, progress: ((Int, Int) -> Void)? = nil) -> ImportReport {
        var report = ImportReport()
        let fm = FileManager.default
        let folder = realPath(folder)                           // stored paths and the prune prefix must agree (/var → /private/var)
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return report }
        let files = (e.allObjects as? [URL] ?? []).filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        var batch: [(facts: FileFacts, tags: TrackMetadata)] = []
        var existing = Set<String>()
        for (i, url) in files.enumerated() {
            report.scanned += 1
            existing.insert(url.path)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if let k = knownFile(url.path), k.mtime == mtime, k.size == size { report.skipped += 1; progress?(i + 1, files.count); continue }
            do {
                var facts = FileFacts(path: url.path, mtime: mtime, size: size)
                if let f = try? LosslessFile(path: url.path) {
                    facts.duration = f.info.duration; facts.sampleRate = f.info.sampleRate; facts.bitDepth = f.info.sourceBits; facts.channels = f.info.channels; facts.codec = f.info.codec
                } else { throw AureonError.message("unreadable audio") }
                batch.append((facts, TagInterpreter.interpret(TagReader.read(path: url.path), fileName: url.lastPathComponent)))
            } catch { report.failed += 1; report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            if batch.count >= 200 { let r = upsert(batch); report.added += r.added; report.updated += r.updated; batch = [] }
            progress?(i + 1, files.count)
        }
        if !batch.isEmpty { let r = upsert(batch); report.added += r.added; report.updated += r.updated }
        report.removed = removeTracks(under: folder.path, keeping: existing)
        return report
    }
}

// MARK: - Likes, play counts and playlists

extension LibraryStore {
    func likedPaths() -> Set<String> {
        ctx.performAndWait { Set(fetch("Track", NSPredicate(format: "liked == YES")).compactMap { str($0, "path") }) }
    }

    /// Marks tracks (by file path) as liked or not. Returns how many changed.
    @discardableResult
    func setLiked(paths: [String], liked: Bool) -> Int {
        ctx.performAndWait {
            var n = 0
            let now = Date().timeIntervalSince1970
            for t in fetch("Track", NSPredicate(format: "path IN %@", paths)) {
                let was = (t.value(forKey: "liked") as? NSNumber)?.boolValue == true
                guard was != liked else { continue }
                set(t, "liked", liked); set(t, "likedAt", liked ? now : nil); n += 1
            }
            if n > 0 { try? ctx.save() }
            return n
        }
    }

    /// Liked songs, most recently liked first.
    func likedTracks() -> [TrackDTO] {
        ctx.performAndWait {
            fetch("Track", NSPredicate(format: "liked == YES"), sort: [NSSortDescriptor(key: "likedAt", ascending: false)]).map(trackDTO)
        }
    }

    func recordPlay(path: String) {
        ctx.performAndWait {
            guard let t = one("Track", "path == %@", path) else { return }
            set(t, "playCount", (int(t, "playCount") ?? 0) + 1); set(t, "lastPlayedAt", Date().timeIntervalSince1970)
            try? ctx.save()
        }
    }

    // MARK: playlists

    private func playlistDTO(_ p: NSManagedObject) -> PlaylistDTO {
        let entries = many(p, "entries")
        let duration = entries.reduce(0.0) { $0 + (($1.value(forKey: "track") as? NSManagedObject).map { dbl($0, "duration") } ?? 0) }
        return PlaylistDTO(id: str(p, "uid") ?? "", name: str(p, "name") ?? "", trackCount: entries.filter { $0.value(forKey: "track") != nil }.count, duration: duration,
                           createdAt: dbl(p, "createdAt"), updatedAt: dbl(p, "updatedAt"))
    }

    func playlists() -> [PlaylistDTO] {
        ctx.performAndWait { fetch("Playlist", sort: [NSSortDescriptor(key: "createdAt", ascending: true)]).map(playlistDTO) }
    }

    @discardableResult
    func createPlaylist(name: String, paths: [String] = []) -> PlaylistDTO? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let id: String = ctx.performAndWait {
            let p = NSEntityDescription.insertNewObject(forEntityName: "Playlist", into: ctx)
            let now = Date().timeIntervalSince1970, uid = UUID().uuidString
            set(p, "uid", uid); set(p, "name", n); set(p, "createdAt", now); set(p, "updatedAt", now)
            try? ctx.save()
            return uid
        }
        if !paths.isEmpty { addToPlaylist(id: id, paths: paths) }
        return playlists().first { $0.id == id }
    }

    func renamePlaylist(id: String, name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        ctx.performAndWait { if let p = one("Playlist", "uid == %@", id) { set(p, "name", n); set(p, "updatedAt", Date().timeIntervalSince1970); try? ctx.save() } }
    }

    func deletePlaylist(id: String) {
        ctx.performAndWait { if let p = one("Playlist", "uid == %@", id) { ctx.delete(p); try? ctx.save() } }
    }

    private func orderedEntries(_ p: NSManagedObject) -> [NSManagedObject] {
        many(p, "entries").filter { $0.value(forKey: "track") != nil }.sorted { (int($0, "order") ?? 0) < (int($1, "order") ?? 0) }
    }

    /// Appends tracks that are not already in the playlist. Returns how many were added.
    @discardableResult
    func addToPlaylist(id: String, paths: [String]) -> Int {
        ctx.performAndWait {
            guard let p = one("Playlist", "uid == %@", id) else { return 0 }
            let existing = orderedEntries(p)
            var have = Set(existing.compactMap { ($0.value(forKey: "track") as? NSManagedObject).flatMap { str($0, "path") } })
            var order = (existing.last.flatMap { int($0, "order") } ?? -1) + 1
            let byPath = Dictionary(fetch("Track", NSPredicate(format: "path IN %@", paths)).compactMap { t in str(t, "path").map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
            var added = 0
            for path in paths where !have.contains(path) {
                guard let t = byPath[path] else { continue }
                let e = NSEntityDescription.insertNewObject(forEntityName: "PlaylistEntry", into: ctx)
                set(e, "order", order); set(e, "addedAt", Date().timeIntervalSince1970); set(e, "playlist", p); set(e, "track", t)
                have.insert(path); order += 1; added += 1
            }
            if added > 0 { set(p, "updatedAt", Date().timeIntervalSince1970); try? ctx.save() }
            return added
        }
    }

    func removeFromPlaylist(id: String, paths: [String]) {
        ctx.performAndWait {
            guard let p = one("Playlist", "uid == %@", id) else { return }
            let drop = Set(paths)
            var n = 0
            for e in orderedEntries(p) {
                if let path = (e.value(forKey: "track") as? NSManagedObject).flatMap({ str($0, "path") }), drop.contains(path) { ctx.delete(e) } else { set(e, "order", n); n += 1 }
            }
            set(p, "updatedAt", Date().timeIntervalSince1970); try? ctx.save()
        }
    }

    /// SwiftUI `onMove` semantics.
    func movePlaylistEntries(id: String, from source: IndexSet, to destination: Int) {
        ctx.performAndWait {
            guard let p = one("Playlist", "uid == %@", id) else { return }
            var list = orderedEntries(p)
            let moving = source.map { list[$0] }
            let before = source.filter { $0 < destination }.count
            for i in source.sorted(by: >) { list.remove(at: i) }
            list.insert(contentsOf: moving, at: max(0, min(destination - before, list.count)))
            for (i, e) in list.enumerated() { set(e, "order", i) }
            set(p, "updatedAt", Date().timeIntervalSince1970); try? ctx.save()
        }
    }

    func playlistTracks(id: String) -> [TrackDTO] {
        ctx.performAndWait {
            guard let p = one("Playlist", "uid == %@", id) else { return [] }
            return orderedEntries(p).compactMap { ($0.value(forKey: "track") as? NSManagedObject).map(trackDTO) }
        }
    }

    func playlistIDs(containing path: String) -> Set<String> {
        ctx.performAndWait {
            guard let t = one("Track", "path == %@", path) else { return [] }
            return Set(many(t, "playlistEntries").compactMap { ($0.value(forKey: "playlist") as? NSManagedObject).flatMap { str($0, "uid") } })
        }
    }

    // MARK: tidying artists

    /// Folds "A feat. B" artists into "A" (with B credited as a featured artist on those tracks) and merges albums that only differed by such a name.
    /// Safe to run again and again; returns the number of artist entries that were folded.
    @discardableResult
    func normalizeArtists() -> Int {
        ctx.performAndWait {
            let candidates = fetch("Party", NSPredicate(format: "key CONTAINS %@ OR key CONTAINS %@ OR key CONTAINS %@ OR key CONTAINS %@ OR key CONTAINS %@ OR key CONTAINS %@", " feat", " ft", "featuring", ", ", " & ", " x "))
            guard !candidates.isEmpty else { return 0 }
            // names that already stand alone in the library: "Badshah, Aastha Gill" is a collaboration because "Badshah" is an artist on his own
            let separators = [", ", " & ", " x "]
            var known = Set<String>()
            for p in fetch("Party") { if let k = str(p, "key"), !separators.contains(where: { k.contains($0) }) { known.insert(k) } }
            var touched = Touched()
            var deleted: [(kind: String, uid: String)] = []
            var releases: [NSManagedObject] = []
            var folded = 0
            for old in candidates {
                let name = str(old, "name") ?? ""
                var (primary, featured) = TagInterpreter.splitFeaturing(name)
                if featured.isEmpty {
                    // "A, B & C" where A is a known artist: A is the artist, the others are guests
                    let parts = name.replacingOccurrences(of: " & ", with: ", ").replacingOccurrences(of: " x ", with: ", ").components(separatedBy: ", ")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if parts.count >= 2, known.contains(Self.fold(parts[0])) { primary = parts[0]; featured = Array(parts.dropFirst()) }
                }
                guard !featured.isEmpty, Self.fold(primary) != Self.fold(name) else { continue }
                let prim = party(Credit(role: .artist, name: primary), &touched)
                guard prim !== old else { continue }
                for c in many(old, "credits") {
                    guard let track = c.value(forKey: "track") as? NSManagedObject else { ctx.delete(c); continue }
                    let role = str(c, "role") ?? "artist"
                    let siblings = many(track, "credits")
                    if siblings.contains(where: { $0 !== c && ($0.value(forKey: "party") as? NSManagedObject) === prim && str($0, "role") == role }) { ctx.delete(c) } else { set(c, "party", prim) }
                    if role == "artist" {
                        for (n, f) in featured.enumerated() {
                            let fp = party(Credit(role: .featured, name: f), &touched)
                            if !many(track, "credits").contains(where: { ($0.value(forKey: "party") as? NSManagedObject) === fp }) {
                                let cr = NSEntityDescription.insertNewObject(forEntityName: "Credit", into: ctx)
                                set(cr, "role", CreditRole.featured.rawValue); set(cr, "order", 99 + n); set(cr, "track", track); set(cr, "party", fp)
                            }
                        }
                    }
                    touched.tracks.insert(str(track, "uid") ?? "")
                    if let r = track.value(forKey: "release") as? NSManagedObject, !releases.contains(where: { $0 === r }) { releases.append(r) }
                }
                deleted.append(("party", str(old, "uid") ?? "")); ctx.delete(old)
                folded += 1
            }
            guard folded > 0 else { return 0 }
            try? ctx.save()
            // releases keyed by album + album artist may now collide
            for r in releases where !r.isDeleted {
                guard str(r, "mbReleaseID") == nil, let title = str(r, "title") else { continue }
                let tracks = many(r, "tracks")
                let credits = tracks.flatMap { many($0, "credits") }
                let pick = credits.filter { str($0, "role") == "albumArtist" }.min { (int($0, "order") ?? 0) < (int($1, "order") ?? 0) }
                    ?? credits.filter { str($0, "role") == "artist" }.min { (int($0, "order") ?? 0) < (int($1, "order") ?? 0) }
                let artist = (pick?.value(forKey: "party") as? NSManagedObject).flatMap { str($0, "name") } ?? ""
                let key = Self.fold(title) + "|" + Self.fold(artist)
                guard key != str(r, "key") else { continue }
                if let other = one("Release", "key == %@", key), other !== r {
                    for t in tracks { set(t, "release", other) }
                    deleted.append(("release", str(r, "uid") ?? "")); touched.releases.insert(str(other, "uid") ?? ""); ctx.delete(r)
                } else { set(r, "key", key); touched.releases.insert(str(r, "uid") ?? "") }
            }
            try? ctx.save()
            deleted += pruneOrphans()
            commit(touched, deleted: deleted)
            return folded
        }
    }
}

// MARK: - Removal by path

extension LibraryStore {
    /// Removes tracks from the library by path (the files themselves are the caller's business).
    @discardableResult
    func removeTracks(paths: [String]) -> Int {
        ctx.performAndWait {
            var deleted: [(kind: String, uid: String)] = []
            for t in fetch("Track", NSPredicate(format: "path IN %@", paths)) { deleted.append(("track", str(t, "uid") ?? "")); ctx.delete(t) }
            guard !deleted.isEmpty else { return 0 }
            try? ctx.save()
            deleted += pruneOrphans()
            commit(Touched(), deleted: deleted)
            return deleted.filter { $0.kind == "track" }.count
        }
    }
}

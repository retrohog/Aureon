import Foundation

struct DeviceDTO: Codable, Equatable { var id: Int; var name: String; var rates: [Double] }

/// The remote API as plain methods: `handle("queue.add", params)` → JSON. No sockets here, so it is tested directly and
/// reused by both the in-app server and the headless daemon.
final class RemoteController: @unchecked Sendable {
    let player: Player
    let library: LibraryStore
    var playerOptions: PlayerOptions
    var serverName: String
    /// Remote clients may only add / import files below these folders (empty = unrestricted).
    var allowedRoots: [String]
    var volume: () -> Double? = { nil }
    var setVolume: (Double) -> Void = { _ in }
    var importFolder: (String) -> ImportReport

    init(player: Player, library: LibraryStore, options: PlayerOptions = PlayerOptions(), name: String = Host.current().localizedName ?? "Aureon",
         allowedRoots: [String] = []) {
        self.player = player; self.library = library; playerOptions = options; serverName = name
        self.allowedRoots = allowedRoots.map { realPath(URL(fileURLWithPath: $0)).path }
        importFolder = { [library] in library.importFolder(URL(fileURLWithPath: $0)) }
    }

    // MARK: snapshots

    private func entryDTOs(_ entries: [QueueEntry]) -> [QueueEntryDTO] {
        let known = library.tracks(paths: entries.map(\.path))
        return entries.map { e in
            if let t = known[e.path] { return QueueEntryDTO(id: e.id.uuidString, path: e.path, title: t.title, artist: t.artistLine, duration: t.duration, trackID: t.id) }
            return QueueEntryDTO(id: e.id.uuidString, path: e.path, title: ((e.path as NSString).lastPathComponent as NSString).deletingPathExtension, artist: "", duration: 0, trackID: nil)
        }
    }

    func queueSnapshot() -> QueueSnapshot {
        let q = player.queue
        return QueueSnapshot(revision: player.queueRevision, currentID: player.status.trackID?.uuidString, entries: entryDTOs(q))
    }

    func statusDTO() -> RemoteStatus {
        let s = player.status
        var title = "", artist = "", album = ""
        if let id = s.trackID, let e = player.queue.first(where: { $0.id == id }) {
            if let t = library.tracks(paths: [e.path])[e.path] { title = t.title; artist = t.artistLine; album = t.releaseTitle ?? "" }
            else { title = ((e.path as NSString).lastPathComponent as NSString).deletingPathExtension }
        }
        let state: String
        switch s.state { case .idle: state = "idle"; case .loading: state = "loading"; case .playing: state = "playing"; case .paused: state = "paused" }
        let raw = s.sourceInfo ?? s.info
        return RemoteStatus(state: state, entryID: s.trackID?.uuidString, title: title, artist: artist, album: album, position: s.position, duration: s.duration,
                            codec: raw?.codec ?? "", bitDepth: raw?.sourceBits ?? 0, sampleRate: raw?.sampleRate ?? 0, bitPerfect: s.bitPerfect, pipeline: s.pipeline,
                            deviceName: s.deviceName, volume: volume(), errors: s.errors, serverTime: Date().timeIntervalSince1970)
    }

    // MARK: parameter helpers

    private func uuid(_ p: JSONObject, _ k: String) throws -> UUID {
        guard let s = p.str(k), let u = UUID(uuidString: s) else { throw RemoteError.invalidParams("\"\(k)\" must be a UUID string") }
        return u
    }
    private func require(_ p: JSONObject, _ k: String) throws -> String {
        guard let s = p.str(k), !s.isEmpty else { throw RemoteError.invalidParams("\"\(k)\" is required") }
        return s
    }

    /// A path is allowed only if, once `..` and symlinks are resolved, it lies inside an allowed root. Non-existent paths are
    /// standardised (resolving `..`) rather than trusted as written.
    private func canonical(_ path: String) -> String {
        let std = URL(fileURLWithPath: path).standardizedFileURL
        return realPath(std).path
    }

    private func checkAllowed(_ path: String) throws {
        guard !allowedRoots.isEmpty else { return }
        let real = canonical(path)
        guard allowedRoots.contains(where: { real == $0 || real.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { throw RemoteError.forbidden("that path is outside the music folders") }
    }

    private func encode<T: Encodable>(_ v: T) throws -> Data { try JSONEncoder.remote.encode(v) }

    // MARK: dispatch

    func handle(method: String, params: JSONObject) async throws -> Data {
        switch method {
        case "ping": return Data("\"pong\"".utf8)

        // transport
        case "status.get": return try encode(statusDTO())
        case "player.play":
            let seconds = params.num("seconds") ?? 0
            if params.str("entryID") != nil {
                let id = try uuid(params, "entryID")
                guard player.queue.contains(where: { $0.id == id }) else { throw RemoteError.notFound("no such queue entry") }
                if player.isRunning && seconds == 0 { player.send(.jump(id)) } else { player.start(startID: id, startSeconds: seconds, options: playerOptions) }
            } else if !player.isRunning {
                guard let first = player.queue.first else { throw RemoteError.invalidParams("the queue is empty") }
                player.start(startID: first.id, startSeconds: seconds, options: playerOptions)
            } else { player.send(.setPaused(false)) }
            return try encode(statusDTO())
        case "player.pause": player.send(.setPaused(true)); return try encode(statusDTO())
        case "player.resume": player.send(.setPaused(false)); return try encode(statusDTO())
        case "player.toggle": player.send(.togglePause); return try encode(statusDTO())
        case "player.next": player.send(.next); return Data("true".utf8)
        case "player.previous": player.send(.previous); return Data("true".utf8)
        case "player.stop": player.stop(); return try encode(statusDTO())
        case "player.seek":
            guard let s = params.num("seconds"), s >= 0 else { throw RemoteError.invalidParams("\"seconds\" must be ≥ 0") }
            player.send(.seekTo(s)); return Data("true".utf8)
        case "player.seekBy":
            guard let s = params.num("seconds") else { throw RemoteError.invalidParams("\"seconds\" is required") }
            player.send(.seekBy(s)); return Data("true".utf8)
        case "volume.set":
            guard let v = params.num("volume"), (0...1).contains(v) else { throw RemoteError.invalidParams("\"volume\" must be between 0 and 1") }
            setVolume(v); return Data("true".utf8)

        // queue
        case "queue.get": return try encode(queueSnapshot())
        case "queue.add":
            var paths: [String] = []
            for id in params.strs("trackIDs") {
                guard let t = library.track(id: id) else { throw RemoteError.notFound("unknown library track \(id)") }
                paths.append(t.path)
            }
            for p in params.strs("paths") {
                try checkAllowed(p)
                guard FileManager.default.fileExists(atPath: p) else { throw RemoteError.notFound("no such file") }
                paths.append(p)
            }
            guard !paths.isEmpty else { throw RemoteError.invalidParams("give \"trackIDs\" or \"paths\"") }
            let at = (params["at"] as? Int)
            let added = player.insert(paths, at: at)
            if params["play"] as? Bool == true, let first = added.first {
                if player.isRunning { player.send(.jump(first.id)) } else { player.start(startID: first.id, options: playerOptions) }
            }
            return try encode(entryDTOs(added))
        case "queue.remove":
            let ids = try params.strs("ids").map { s -> UUID in guard let u = UUID(uuidString: s) else { throw RemoteError.invalidParams("bad id \(s)") }; return u }
            player.remove(ids: Set(ids)); return try encode(queueSnapshot())
        case "queue.move":
            guard let from = params["from"] as? [Int], let to = params["to"] as? Int else { throw RemoteError.invalidParams("\"from\" (indices) and \"to\" are required") }
            let n = player.queue.count
            guard from.allSatisfy({ $0 >= 0 && $0 < n }), to >= 0, to <= n else { throw RemoteError.invalidParams("index out of range") }
            player.move(from: IndexSet(from), to: to); return try encode(queueSnapshot())
        case "queue.clear": player.stop(); player.clearQueue(); return try encode(queueSnapshot())

        // settings
        case "settings.get": return try encode(player.settings)
        case "settings.set":
            guard let obj = params["settings"], JSONSerialization.isValidJSONObject(obj) else { throw RemoteError.invalidParams("\"settings\" must be an object") }
            let data = try JSONSerialization.data(withJSONObject: obj)
            guard let s = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else { throw RemoteError.invalidParams("settings do not match the schema") }
            if let ir = s.rt.convolution.irPath, s.rt.convolution.enabled { try checkAllowed(ir) }
            player.settings = s
            return try encode(player.settings)
        case "devices.list": return try encode(listOutputDevices().map { DeviceDTO(id: Int($0.id), name: $0.name, rates: $0.rates) })

        // library
        case "library.stats": return try encode(library.stats())
        case "library.parties":
            guard let role = CreditRole(rawValue: params.str("role") ?? "") else { throw RemoteError.invalidParams("\"role\" must be one of \(CreditRole.allCases.map(\.rawValue))") }
            return try encode(library.parties(role: role, search: params.str("search"), limit: params["limit"] as? Int ?? 500))
        case "library.works": return try encode(library.works(composerID: params.str("composerID"), search: params.str("search"), limit: params["limit"] as? Int ?? 500))
        case "library.releases": return try encode(library.releases(search: params.str("search"), partyID: params.str("partyID"), limit: params["limit"] as? Int ?? 500))
        case "library.tracks":
            return try encode(library.tracks(releaseID: params.str("releaseID"), workID: params.str("workID"), partyID: params.str("partyID"), role: params.str("role").flatMap(CreditRole.init(rawValue:))))
        case "library.recordings": return try encode(library.recordings(workID: try require(params, "workID")))
        case "library.search": return try encode(library.search(try require(params, "q")))
        case "library.changes":
            let cursor = Int64(params.num("cursor") ?? 0), limit = min(max(params["limit"] as? Int ?? 500, 1), 2000)
            let ch = library.changes(afterSeq: cursor, limit: limit)
            let last = ch.last?.seq ?? cursor
            return try encode(LibraryChangeSet(revision: library.revision, cursor: last, changes: ch, more: ch.count == limit && last < library.lastSeq))
        case "library.import":
            let path = try require(params, "path")
            try checkAllowed(path)
            let r = importFolder(path)
            return try encode(["scanned": r.scanned, "added": r.added, "updated": r.updated, "removed": r.removed, "failed": r.failed])
        case "art.get":
            var path: String?
            if let id = params.str("trackID") { path = library.track(id: id)?.path }
            else if let e = params.str("entryID"), let u = UUID(uuidString: e) { path = player.queue.first { $0.id == u }?.path }
            guard let p = path else { throw RemoteError.notFound("unknown track") }
            guard let data = await Artwork.thumbnail(path: p, maxPixel: min(max(params["size"] as? Int ?? 256, 32), 1024)) else { return Data("null".utf8) }
            return try encode(["mime": "image/jpeg", "base64": data.base64EncodedString()])
        default: throw RemoteError(code: RemoteErrorCode.methodNotFound, message: "unknown method \(method)")
        }
    }
}


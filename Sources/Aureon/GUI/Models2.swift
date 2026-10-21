import SwiftUI
import AppKit
import CoreAudio

// MARK: - Library browsing

@MainActor
final class LibraryModel: ObservableObject {
    enum Category: String, CaseIterable, Identifiable {
        case composers = "Composers", works = "Works", artists = "Artists", albums = "Albums", conductors = "Conductors", ensembles = "Ensembles"
        var id: String { rawValue }
        var icon: String { switch self { case .composers: "music.quarternote.3"; case .works: "book"; case .artists: "person.2"; case .albums: "square.stack"; case .conductors: "wand.and.rays"; case .ensembles: "person.3" } }
    }
    struct Row: Identifiable, Hashable { var id: String; var title: String; var subtitle: String; var count: Int }
    enum Detail { case none, works([WorkDTO]), recordings(WorkDTO, [RecordingGroupDTO]), tracks(String, [TrackDTO]), releases([ReleaseDTO]) }

    let store: LibraryStore?
    @Published var stats = LibraryStats()
    @Published var category: Category = .composers { didSet { selectedID = nil; detail = .none; back = []; reload() } }
    @Published var search = "" { didSet { reload() } }
    @Published var rows: [Row] = []
    @Published var selectedID: String? { didSet { if selectedID != oldValue { select() } } }
    @Published var detail: Detail = .none
    @Published var importing = false
    @Published var importProgress = ""
    @Published var folders: [String] { didSet { UserDefaults.standard.set(folders, forKey: "aureon.musicFolders") } }
    @Published var searchResults: SearchResults?
    private var back: [Detail] = []
    var canGoBack: Bool { !back.isEmpty }
    var onAdd: (([TrackDTO], Bool) -> Void)?

    init() {
        let snapshot = ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil
        store = try? LibraryStore(url: snapshot ? nil : LibraryStore.defaultURL)       // snapshots use a throw-away in-memory library
        folders = UserDefaults.standard.stringArray(forKey: "aureon.musicFolders") ?? []
        refresh()
    }

    func refresh() { guard let store else { return }; Task.detached { let s = store.stats(); await MainActor.run { self.stats = s } }; reload() }

    func reload() {
        guard let store else { return }
        let cat = category, q = search
        Task.detached {
            var out: [Row] = []
            switch cat {
            case .composers: out = store.parties(role: .composer, search: q).map { Row(id: $0.id, title: $0.name, subtitle: $0.kind == "group" ? "Ensemble" : "Composer", count: $0.count) }
            case .artists: out = store.parties(role: .artist, search: q).map { Row(id: $0.id, title: $0.name, subtitle: "", count: $0.count) }
            case .conductors: out = store.parties(role: .conductor, search: q).map { Row(id: $0.id, title: $0.name, subtitle: "", count: $0.count) }
            case .ensembles: out = store.parties(role: .ensemble, search: q).map { Row(id: $0.id, title: $0.name, subtitle: "", count: $0.count) }
            case .works: out = store.works(search: q).map { Row(id: $0.id, title: $0.title, subtitle: [$0.composerName, $0.catalog].compactMap { $0 }.joined(separator: " · "), count: $0.trackCount) }
            case .albums: out = store.releases(search: q).map { Row(id: $0.id, title: $0.title, subtitle: ($0.artistNames.prefix(2) + [$0.year.map(String.init)].compactMap { $0 }).joined(separator: " · "), count: $0.trackCount) }
            }
            let result = out
            await MainActor.run { self.rows = result; self.stats = store.stats() }
        }
    }

    private func select() {
        guard let store, let id = selectedID else { detail = .none; return }
        let cat = category
        Task.detached {
            let d: Detail
            switch cat {
            case .composers: d = .works(store.works(composerID: id))
            case .works:
                let w = store.works(search: nil).first { $0.id == id }
                d = w.map { .recordings($0, store.recordings(workID: id)) } ?? .none
            case .artists: d = .tracks("Tracks", store.tracks(partyID: id, role: .artist))
            case .conductors: d = .tracks("Conducted", store.tracks(partyID: id, role: .conductor))
            case .ensembles: d = .tracks("Performed", store.tracks(partyID: id, role: .ensemble))
            case .albums: d = .tracks("Tracks", store.tracks(releaseID: id))
            }
            await MainActor.run { self.back = []; self.detail = d }
        }
    }

    func open(work: WorkDTO) {
        guard let store else { return }
        Task.detached { let r = store.recordings(workID: work.id); await MainActor.run { self.back.append(self.detail); self.detail = .recordings(work, r) } }
    }

    func goBack() { if let d = back.popLast() { detail = d } }

    func runSearch(_ q: String) {
        guard let store, !q.isEmpty else { searchResults = nil; return }
        Task.detached { let r = store.search(q); await MainActor.run { self.searchResults = r } }
    }

    func tracks(forWork w: WorkDTO) -> [TrackDTO] { store?.tracks(workID: w.id) ?? [] }

    // MARK: import

    func addFolder(_ url: URL) {
        let p = realPath(url).path
        if !folders.contains(p) { folders.append(p) }
        scan([p])
    }

    func rescan() { scan(folders) }

    private func scan(_ paths: [String]) {
        guard let store, !importing else { return }
        importing = true; importProgress = "Scanning…"
        Task.detached {
            var total = ImportReport()
            for p in paths {
                let r = store.importFolder(URL(fileURLWithPath: p)) { n, of in
                    if n % 25 == 0 { Task { @MainActor in self.importProgress = "\(n) of \(of) files in \((p as NSString).lastPathComponent)" } }
                }
                total.added += r.added; total.updated += r.updated; total.removed += r.removed; total.skipped += r.skipped; total.failed += r.failed
            }
            let summary = "\(total.added) added, \(total.updated) updated, \(total.removed) removed" + (total.failed > 0 ? ", \(total.failed) unreadable" : "")
            await MainActor.run { self.importing = false; self.importProgress = summary; self.refresh() }
        }
    }
}

// MARK: - Deep Dive

@MainActor
final class DeepDiveModel: ObservableObject {
    enum State { case idle, loading(String), loaded(DeepDive), failed(String) }
    @Published var state: State = .idle
    @Published var cover: NSImage?
    private var loadedFor: String?
    private let cache = MetadataCache()
    private var covers: CoverArtClient
    var loadedKey: String? { loadedFor }

    init() { covers = CoverArtClient(cache: cache) }

    var current: DeepDive? { if case .loaded(let d) = state { return d }; return nil }
    var coverURL: String? { current?.coverReleaseGroupID.map { "https://coverartarchive.org/release-group/\($0)/front-500" } }

    func load(path: String, recordingID: String?, key: String, acoustID: String, fpcalc: String, force: Bool = false) {
        if !force, loadedFor == key, case .loaded = state { return }
        loadedFor = key; cover = nil
        state = .loading("Starting…")
        Task {
            let svc = DeepDiveService(fingerprinter: FpcalcFingerprinter(explicitPath: fpcalc.isEmpty ? nil : fpcalc), acoustid: AcoustIDClient(), musicbrainz: MusicBrainzClient(cache: cache),
                                      wikipedia: WikipediaClient(cache: cache), cache: cache, apiKey: { acoustID })
            do {
                let d = try await svc.load(path: path, knownRecordingID: recordingID) { stage in Task { @MainActor in if self.loadedFor == key { self.state = .loading(stage.rawValue) } } }
                guard loadedFor == key else { return }
                state = .loaded(d)
                if let rg = d.coverReleaseGroupID, let data = await covers.frontCover(releaseGroupID: rg) { cover = NSImage(data: data) }
            } catch { if loadedFor == key { state = .failed(error.localizedDescription) } }
        }
    }

    func reset() { state = .idle; cover = nil; loadedFor = nil }
}

// MARK: - Connections: Discord, Last.fm, ListenBrainz, AcoustID

struct ConnectionSettings: Codable, Equatable {
    var discordEnabled = false
    var discordClientID = ""
    var lastfmEnabled = false
    var lastfmUser = ""
    var listenbrainzEnabled = false
    var listenbrainzUser = ""
    var acoustIDKey = ""
    var fpcalcPath = ""
    var remoteEnabled = false
    var remotePort = 0
    var remoteName = ""
}

@MainActor
final class SocialModel: ObservableObject {
    @Published var settings = ConnectionSettings() { didSet { if settings != oldValue { save(); applySettings() } } }
    @Published var discordStatus = "Off"
    @Published var lastfmStatus = "Not connected"
    @Published var listenbrainzStatus = "Not connected"
    @Published var lastfmWaitingToken: String?
    @Published var pending = 0
    @Published var message: String?

    let secrets: SecretStore
    private let queue = ScrobbleQueue()
    private let tracker = ScrobbleTracker()
    private var lastfm: LastFMClient?
    private var listenbrainz: ListenBrainzClient?
    private var discord: DiscordIPC?
    private let discordQueue = DispatchQueue(label: "aureon.discord")
    private var lastPresenceKey = "", lastPresenceAt = Date.distantPast, lastDiscordRetry = Date.distantPast
    private var lastFlush = Date.distantPast
    private let defaults = UserDefaults.standard

    init(secrets: SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        if let d = defaults.data(forKey: "aureon.connections"), let s = try? JSONDecoder().decode(ConnectionSettings.self, from: d) { settings = s }
        tracker.onNowPlaying = { [weak self] t in Task { @MainActor in self?.sendNowPlaying(t) } }
        tracker.onScrobble = { [weak self] t, at in Task { @MainActor in self?.record(t, at) } }
        applySettings()
    }

    private func save() { if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: "aureon.connections") } }

    // secrets live in the Keychain, never in preferences
    var lastfmAPIKey: String { get { secrets.get("lastfm.apikey") ?? "" } set { secrets.set(newValue, for: "lastfm.apikey"); applySettings() } }
    var lastfmSecret: String { get { secrets.get("lastfm.secret") ?? "" } set { secrets.set(newValue, for: "lastfm.secret"); applySettings() } }
    var listenbrainzToken: String { get { secrets.get("listenbrainz.token") ?? "" } set { secrets.set(newValue, for: "listenbrainz.token"); applySettings() } }

    private func applySettings() {
        let sk = secrets.get("lastfm.session")
        lastfm = settings.lastfmEnabled && !lastfmAPIKey.isEmpty ? LastFMClient(apiKey: lastfmAPIKey, secret: lastfmSecret, sessionKey: sk) : nil
        if !settings.lastfmEnabled { lastfmStatus = "Off" }
        else if lastfm?.isConfigured == true { lastfmStatus = settings.lastfmUser.isEmpty ? "Signed in" : "Signed in as " + settings.lastfmUser }
        else { lastfmStatus = "Not signed in" }
        listenbrainz = settings.listenbrainzEnabled && !listenbrainzToken.isEmpty ? ListenBrainzClient(token: listenbrainzToken) : nil
        if !settings.listenbrainzEnabled { listenbrainzStatus = "Off" }
        else if listenbrainz != nil { listenbrainzStatus = settings.listenbrainzUser.isEmpty ? "Token set" : "Token set for " + settings.listenbrainzUser }
        else { listenbrainzStatus = "No token" }
        if settings.discordEnabled && !settings.discordClientID.isEmpty {
            if discord?.clientID != settings.discordClientID { discord = DiscordIPC(clientID: settings.discordClientID); discordStatus = "Waiting for Discord" }
        } else {
            clearDiscord(); discord = nil
            discordStatus = settings.discordEnabled ? "Enter a Discord application ID" : "Off"
        }
        pending = queue.pending.count
    }

    private var services: [ScrobbleService] {
        var out: [ScrobbleService] = []
        if let l = lastfm, l.isConfigured { out.append(l) }
        if let b = listenbrainz, b.isConfigured { out.append(b) }
        return out
    }

    // MARK: scrobbling

    func update(_ info: NowPlayingInfo?, position: Double, playing: Bool) {
        tracker.update(info, position: position, playing: playing)
        updateDiscord(info, position: position, playing: playing)
        if Date().timeIntervalSince(lastFlush) > 60 { lastFlush = Date(); flush() }
    }

    private func sendNowPlaying(_ t: ScrobbleTrack) { for s in services { Task { try? await s.nowPlaying(t) } } }

    private func record(_ t: ScrobbleTrack, _ at: Date) {
        let names = services.map(\.name)
        guard !names.isEmpty else { return }
        queue.add(t, playedAt: at, services: names); pending = queue.pending.count
        flush()
    }

    func flush() {
        for s in services {
            Task {
                let o = await queue.flush(s)
                await MainActor.run {
                    pending = queue.pending.count
                    if o.needsAuth { message = "\(s.name) needs you to sign in again" }
                    if s.name == "Last.fm" { lastfmStatus = o.needsAuth ? "Sign-in expired" : lastfmStatus } else { listenbrainzStatus = o.needsAuth ? "Token rejected" : listenbrainzStatus }
                }
            }
        }
    }

    // MARK: Last.fm sign-in

    func beginLastFM() {
        guard !lastfmAPIKey.isEmpty, !lastfmSecret.isEmpty else { message = "Enter your Last.fm API key and shared secret first (last.fm/api/account/create)"; return }
        let c = LastFMClient(apiKey: lastfmAPIKey, secret: lastfmSecret)
        Task {
            do { let (token, url) = try await c.authToken(); lastfmWaitingToken = token; NSWorkspace.shared.open(url); message = "Approve Aureon in your browser, then press “Finish sign-in”." }
            catch { message = "Last.fm: \(error.localizedDescription)" }
        }
    }

    func finishLastFM() {
        guard let token = lastfmWaitingToken else { return }
        let c = LastFMClient(apiKey: lastfmAPIKey, secret: lastfmSecret)
        Task {
            do { let (key, user) = try await c.session(token: token); secrets.set(key, for: "lastfm.session"); lastfmWaitingToken = nil; settings.lastfmUser = user; settings.lastfmEnabled = true; applySettings(); message = nil }
            catch { message = "Last.fm: \(error.localizedDescription)" }
        }
    }

    func signOutLastFM() { secrets.set(nil, for: "lastfm.session"); settings.lastfmUser = ""; applySettings() }

    func validateListenBrainz() {
        let c = ListenBrainzClient(token: listenbrainzToken)
        Task {
            do { let u = try await c.validate(); settings.listenbrainzUser = u; settings.listenbrainzEnabled = true; applySettings(); message = nil }
            catch { message = "ListenBrainz: \(error.localizedDescription)" }
        }
    }

    // MARK: Discord

    private func clearDiscord() { if let d = discord { discordQueue.async { try? d.setActivity(nil); d.close() } } }

    private func updateDiscord(_ info: NowPlayingInfo?, position: Double, playing: Bool) {
        guard let ipc = discord else { return }
        let key = info.map { "\($0.id)|\(playing)" } ?? "none"
        let moved = abs(position - (lastPosition + Date().timeIntervalSince(lastPositionAt) * (playing ? 1 : 0))) > 4
        defer { lastPosition = position; lastPositionAt = Date() }
        guard key != lastPresenceKey || (moved && Date().timeIntervalSince(lastPresenceAt) > 4) else { return }
        if lastPresenceKey == "" || key != lastPresenceKey || moved {
            // Discord allows about five updates per 20 s; retry a missing Discord only every 15 s
            guard Date().timeIntervalSince(lastPresenceAt) > 1.5, Date().timeIntervalSince(lastDiscordRetry) > (discordStatus.hasPrefix("Waiting") ? 15 : 0) else { return }
        }
        lastPresenceKey = key; lastPresenceAt = Date(); lastDiscordRetry = Date()
        let act = info.map { DiscordPresence.activity(for: $0, position: position, playing: playing) }
        discordQueue.async { [weak self] in
            do { try ipc.setActivity(act); Task { @MainActor in self?.discordStatus = act == nil ? "Connected" : "Showing “\(info?.title ?? "")”" } }
            catch { Task { @MainActor in self?.discordStatus = "\(error.localizedDescription)"; self?.lastPresenceKey = "" } }
        }
    }
    private var lastPosition = 0.0, lastPositionAt = Date()
}

// MARK: - Remote control server

@MainActor
final class RemoteModel: ObservableObject {
    @Published var running = false
    @Published var port: UInt16 = 0
    @Published var clients = 0
    @Published var error: String?
    private var server: RemoteServer?
    private(set) var token = ""
    var makeController: (() -> RemoteController)?

    func start(port: UInt16, name: String) {
        stop()
        guard let make = makeController else { return }
        token = loadOrCreateToken(at: supportDirectory().appendingPathComponent("remote-token"))
        let controller = make(); if !name.isEmpty { controller.serverName = name }
        let s = RemoteServer(controller: controller, token: token, advertise: true)
        s.onClientsChanged = { [weak self] n in Task { @MainActor in self?.clients = n } }
        do { self.port = try s.start(port: port); server = s; running = true; error = nil }
        catch { self.error = error.localizedDescription; running = false }
    }

    func stop() { server?.stop(); server = nil; running = false; clients = 0 }
    var controller: RemoteController? { server?.controller }
    var hostName: String { Host.current().localizedName ?? "this Mac" }
}

// MARK: - System optimisation

@MainActor
final class SystemModel: ObservableObject {
    @Published var quietMode = false { didSet { UserDefaults.standard.set(quietMode, forKey: "aureon.quiet") } }
    @Published var promoteEngine = false { didSet { UserDefaults.standard.set(promoteEngine, forKey: "aureon.promote") } }
    @Published var nice: Double = -10 { didSet { quiet.nice = Int32(nice); UserDefaults.standard.set(nice, forKey: "aureon.nice") } }
    @Published var cycleUsage: Double = 0.5 { didSet { UserDefaults.standard.set(cycleUsage, forKey: "aureon.cycle") } }
    @Published var useCycleUsage = false { didSet { UserDefaults.standard.set(useCycleUsage, forKey: "aureon.usecycle") } }
    @Published var helperStatus = "Not installed"
    @Published var helperError: String?
    let quiet = QuietModeController()

    init() {
        let d = UserDefaults.standard
        quietMode = d.bool(forKey: "aureon.quiet"); promoteEngine = d.bool(forKey: "aureon.promote")
        nice = d.object(forKey: "aureon.nice") as? Double ?? -10; cycleUsage = d.object(forKey: "aureon.cycle") as? Double ?? 0.5; useCycleUsage = d.bool(forKey: "aureon.usecycle")
        quiet.nice = Int32(nice)
        quiet.onStatusChange = { [weak self] s in Task { @MainActor in self?.describe(s) } }
        describe(quiet.refreshStatus())
    }

    private func describe(_ s: QuietModeController.Status) {
        switch s {
        case .notInstalled: helperStatus = "Helper not installed (needs the signed build)"
        case .requiresApproval: helperStatus = "Waiting for approval in System Settings → Login Items"
        case .ready: helperStatus = "Helper ready"
        case .active(let names): helperStatus = names.isEmpty ? "Active" : "Paused: " + names.joined(separator: ", ")
        case .failed(let m): helperStatus = "Problem: \(m)"
        }
    }

    func refresh() { describe(quiet.refreshStatus()) }
    func register() { do { try quiet.register(); helperError = nil } catch { helperError = error.localizedDescription }; refresh() }
    func unregister() { do { try quiet.unregister(); helperError = nil } catch { helperError = error.localizedDescription }; refresh() }
}

// MARK: - Headphone profiles (AutoEQ)

@MainActor
final class HeadphoneModel: ObservableObject {
    @Published var query = "" { didSet { results = AutoEQCatalog.search(query, in: index) } }
    @Published var results: [AutoEQEntry] = []
    @Published var loading = false
    @Published var error: String?
    private var index: [AutoEQEntry] = []
    private let catalog = AutoEQCatalog()
    var indexLoaded: Bool { !index.isEmpty }

    func loadIndex() {
        guard !loading, index.isEmpty else { return }
        loading = true; error = nil
        Task {
            do { index = try await catalog.loadIndex(); results = AutoEQCatalog.search(query, in: index) }
            catch { self.error = "Could not load the AutoEQ index: \(error.localizedDescription)" }
            loading = false
        }
    }

    func fetch(_ e: AutoEQEntry, apply: @escaping (HeadphoneProfile) -> Void) {
        loading = true; error = nil
        Task {
            do { apply(try await catalog.profile(for: e)) } catch { self.error = "Could not load \(e.name): \(error.localizedDescription)" }
            loading = false
        }
    }
}

import SwiftUI
import AppKit
import CoreAudio
import Combine

// MARK: - Library browsing

@MainActor
final class LibraryModel: ObservableObject {
    enum Category: String, CaseIterable, Identifiable {
        case composers = "Composers", works = "Works", artists = "Artists", albums = "Albums", conductors = "Conductors", ensembles = "Ensembles", songs = "Songs"
        var id: String { rawValue }
        var icon: String { switch self { case .composers: "music.quarternote.3"; case .works: "book"; case .artists: "person.2"; case .albums: "square.stack"; case .conductors: "wand.and.rays"; case .ensembles: "person.3"; case .songs: "music.note" } }
    }
    struct Row: Identifiable, Hashable { var id: String; var title: String; var subtitle: String; var count: Int }
    enum Detail { case none, works([WorkDTO]), composer([WorkDTO], [TrackDTO]), recordings(WorkDTO, [RecordingGroupDTO]), tracks(String, [TrackDTO]), releases([ReleaseDTO]) }

    let store: LibraryStore?
    @Published var stats = LibraryStats()
    @Published var category: Category = .composers { didSet { selectedID = nil; detail = .none; back = []; clearFocus(); reload() } }
    @Published var search = "" { didSet { reload() } }
    @Published var rows: [Row] = []
    @Published var selectedID: String? { didSet { if selectedID != oldValue { if selectedID != nil { clearFocus() }; select() } } }
    @Published var detail: Detail = .none
    @Published var importing = false
    @Published var importProgress = ""
    @Published var folders: [String] { didSet { UserDefaults.standard.set(folders, forKey: "aureon.musicFolders") } }
    @Published var searchResults: SearchResults?
    private var back: [Detail] = []
    var canGoBack: Bool { !back.isEmpty }
    var onLibraryChanged: (() -> Void)?
    var onAdd: (([TrackDTO], Bool) -> Void)?
    var onReplace: (([TrackDTO]) -> Void)?
    /// The albums page, a page at a time (see AlbumPager). `albums` is what it holds at the moment, not the whole library.
    let pager = AlbumPager()
    var albums: [ReleaseDTO] { pager.resident }
    /// The album whose detail page is open.
    @Published var selectedAlbum: ReleaseDTO?
    var watcher: LibraryWatcher?
    private var pagerTotal: AnyCancellable?
    @Published var artistAlbums: [ReleaseDTO] = []
    @Published var recentAlbums: [ReleaseDTO] = []
    @Published var hiResAlbums: [ReleaseDTO] = []
    @Published var songs: [TrackDTO] = [] { didSet { songsVersion &+= 1 } }
    private var songsVersion = 0
    private var songMemo: (version: Int, options: ViewOptions, result: [TrackDTO])?

    /// Sorted and filtered once per change of the list or of the options (sorting thousands of songs on every redraw made the page crawl).
    func orderedSongs(_ o: ViewOptions) -> [TrackDTO] {
        if let m = songMemo, m.version == songsVersion, m.options == o { return m.result }
        let r = LibraryOrdering.songs(songs, o); songMemo = (songsVersion, o, r); return r
    }
    // loudness analysis
    @Published private(set) var loudnessDone = 0
    @Published private(set) var loudnessTotal = 0
    @Published private(set) var analysingLoudness = false
    private var loudnessTask: Task<Void, Never>?
    // duplicates
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var showDuplicates = false
    @Published var duplicateBanner = false
    @Published var scanningDuplicates = false
    var ignoredDuplicates: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "aureon.ignoredDuplicates") ?? [])

    init() {
        let snapshot = ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil
        store = try? LibraryStore(url: snapshot ? nil : LibraryStore.defaultURL)       // snapshots use a throw-away in-memory library
        folders = UserDefaults.standard.stringArray(forKey: "aureon.musicFolders") ?? []
        pager.store = store
        pagerTotal = pager.$total.removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }      // the page's "N albums" subtitle
        refresh()
        // bring the library up to date from what the file system reports (nothing is scanned when nothing changed)
        if Self.watchingAllowed { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in MainActor.assumeIsolated { self?.startWatching() } } }
        // libraries imported by older versions may hold "A feat. B" as artists of their own: fold them into A once at start-up
        if !snapshot, let store { Task.detached(priority: .utility) { if store.normalizeArtists() > 0 { await MainActor.run { self.refresh() } } } }
    }

    func refresh() {
        guard let store else { return }
        Task.detached {
            let s = store.stats()
            if store.releasesWithoutFigures() > 0 { store.backfillReleaseFigures() }
            let recent = store.releasePage(AlbumQuery(sort: .added, ascending: false), offset: 0, limit: 16)
            let hires = store.releasePage(AlbumQuery(sort: .added, ascending: false, tier: .hiRes), offset: 0, limit: 16)
            await MainActor.run { self.stats = s; self.recentAlbums = recent; self.hiResAlbums = hires }
        }
        pager.reload()
        reload()
    }

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
            case .albums: break                                    // the Albums page is paged (AlbumPager), not a list of rows
            case .songs: break
            }
            let result = out
            var songs: [TrackDTO] = []
            if cat == .songs { var off = 0; while true { let page = store.allTracks(offset: off, limit: 2000); songs += page; if page.count < 2000 || songs.count >= 60_000 { break }; off += 2000 } }
            if cat == .songs, !q.isEmpty { songs = songs.filter { ($0.title + " " + $0.artistLine + " " + ($0.releaseTitle ?? "")).localizedCaseInsensitiveContains(q) } }
            let finalSongs = songs
            await MainActor.run { self.rows = result; self.songs = finalSongs; self.stats = store.stats() }
        }
    }

    private func select() {
        guard let store, let id = selectedID else { detail = .none; return }
        let cat = category
        Task.detached {
            let d: Detail
            var album: ReleaseDTO?
            switch cat {
            case .composers: d = .composer(store.works(composerID: id), store.tracks(partyID: id, role: .composer))
            case .works:
                let w = store.works(search: nil).first { $0.id == id }
                d = w.map { .recordings($0, store.recordings(workID: id)) } ?? .none
            case .artists:
                d = .tracks("Tracks", store.tracks(partyID: id, role: .artist))
                let alb = store.releases(partyID: id)
                await MainActor.run { self.artistAlbums = alb }
            case .conductors: d = .tracks("Conducted", store.tracks(partyID: id, role: .conductor))
            case .ensembles: d = .tracks("Performed", store.tracks(partyID: id, role: .ensemble))
            case .albums: d = .tracks("Tracks", store.tracks(releaseID: id)); album = store.release(id: id)
            case .songs: d = .none
            }
            await MainActor.run { self.back = []; self.selectedAlbum = album; self.detail = d }
        }
    }

    func open(work: WorkDTO) {
        guard let store else { return }
        Task.detached { let r = store.recordings(workID: work.id); await MainActor.run { self.back.append(self.detail); self.detail = .recordings(work, r) } }
    }

    func goBack() { if let d = back.popLast() { detail = d } }

    // MARK: credit focus (the relational graph)

    /// The person whose credits are on show, or nil. Opening someone from the page replaces them and remembers the one before.
    @Published private(set) var focus: CreditGraphDTO?
    @Published private(set) var focusLoading = false
    private var focusBack: [CreditGraphDTO] = []
    private var focusToken = 0
    var canGoBackFocus: Bool { !focusBack.isEmpty }

    /// Loads everything the library credits `partyID` with, on a background queue, and shows it.
    func openPerson(_ partyID: String) {
        guard let store else { return }
        focusToken += 1
        let token = focusToken
        focusLoading = true
        Task.detached {
            let g = store.creditGraph(partyID: partyID)
            await MainActor.run {
                guard token == self.focusToken else { return }
                self.focusLoading = false
                guard let g else { return }
                if let cur = self.focus, cur.person.id != g.person.id { self.focusBack.append(cur) }
                self.focus = g
            }
        }
    }

    func closeFocus() { focusToken += 1; focusLoading = false; if let p = focusBack.popLast() { focus = p } else { focus = nil } }
    func clearFocus() { focusToken += 1; focusLoading = false; focus = nil; focusBack = [] }

    /// Plays, shuffles or queues the tracks with these ids (read off the main thread).
    func playCredited(trackIDs: [String], shuffle: Bool = false, add: Bool = false) {
        guard let store else { return }
        Task.detached {
            var tracks = trackIDs.compactMap { store.track(id: $0) }
            if shuffle { tracks.shuffle() }
            let t = tracks
            await MainActor.run { if add { self.onAdd?(t, false) } else { self.onReplace?(t) } }
        }
    }


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

    /// Indexes a folder once without remembering it as a library folder (ripped discs, for example).
    func importOnce(_ url: URL) { scan([realPath(url).path]) }

    func refreshLoudnessProgress() {
        guard let store else { return }
        Task.detached { let p = store.loudnessProgress(); await MainActor.run { self.loudnessDone = p.done; self.loudnessTotal = p.total } }
    }

    /// Measures EBU R128 loudness, true peak and DR for every song that has none yet, two at a time in the background, and stores the figures in the library.
    func startLoudnessAnalysis() {
        guard let store, !analysingLoudness else { return }
        analysingLoudness = true
        loudnessTask = Task { [weak self] in
            let paths = await Task.detached(priority: .utility) { store.pathsNeedingLoudness() }.value
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func feed(_ g: inout TaskGroup<Void>) {
                    guard next < paths.count, !Task.isCancelled else { return }
                    let p = paths[next]; next += 1
                    g.addTask(priority: .utility) {
                        if let r = LoudnessCache.shared.analysis(path: p) { store.setLoudness(path: p, r) }
                        else if let t = store.track(path: p), t.lufs == nil { _ = t }           // unreadable files are left for the next run
                    }
                }
                for _ in 0..<2 { feed(&group) }
                var finished = 0
                while await group.next() != nil {
                    finished += 1
                    if finished % 5 == 0 { await self?.updateLoudnessProgress(store) }
                    feed(&group)
                }
            }
            await self?.updateLoudnessProgress(store)
            self?.analysingLoudness = false
        }
    }

    func stopLoudnessAnalysis() { loudnessTask?.cancel(); loudnessTask = nil; analysingLoudness = false }

    private func updateLoudnessProgress(_ store: LibraryStore) async {
        let p = await Task.detached { store.loudnessProgress() }.value
        loudnessDone = p.done; loudnessTotal = p.total
    }

    private func scan(_ paths: [String]) {
        guard let store, !importing else { return }
        importing = true; importProgress = "Scanning…"
        // watching starts before the scan, so a change made while it runs is reported afterwards instead of being missed
        let watching = Self.watchingAllowed ? ensureWatcher() : nil
        let starts: [(String, UInt64)] = paths.compactMap { p in folders.contains(p) ? watching.map { (p, $0.beginReconcile(root: p)) } : nil }
        Task.detached {
            var total = ImportReport()
            for p in paths {
                let r = store.importFolder(URL(fileURLWithPath: p)) { n, of in
                    if n % 25 == 0 { Task { @MainActor in self.importProgress = "\(n) of \(of) files in \((p as NSString).lastPathComponent)" } }
                }
                total.added += r.added; total.updated += r.updated; total.removed += r.removed; total.skipped += r.skipped; total.failed += r.failed
            }
            _ = store.normalizeArtists()
            for (p, id) in starts { watching?.markReconciled(root: p, eventID: id) }
            let summary = "\(total.added) added, \(total.updated) updated, \(total.removed) removed" + (total.failed > 0 ? ", \(total.failed) unreadable" : "")
            await MainActor.run {
                self.importing = false; self.importProgress = summary; self.refresh()
                // new files may duplicate something already here: offer a check
                if total.added > 0 { self.scanDuplicates(prompt: true) }
                self.onLibraryChanged?()
            }
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

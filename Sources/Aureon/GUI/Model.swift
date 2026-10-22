import SwiftUI
import Combine
import AppKit
import AVFoundation
import CoreAudio
import CoreAudioKit
import UniformTypeIdentifiers

let audioExtensions: Set<String> = ["flac", "wav", "aif", "aiff", "alac", "m4a", "caf", "dsf", "dff"]

struct QueueItem: Identifiable {
    enum ArtSource: Equatable { case unknown, embedded, fetched, none, remote(String) }
    let id: UUID
    let url: URL
    /// The path the engine and the library know this item by.
    var path: String { remotePath ?? url.path }
    var title: String
    var artist = ""
    var album = ""
    /// The library path of a track that is not a local file (`cloud://…`, `subsonic://…`), which cannot be written as a file URL.
    var remotePath: String? = nil
    var albumArtist = ""
    var composer = ""
    var genre = ""
    var year: Int?
    var trackNumber: Int?, trackTotal: Int?
    var thumb: NSImage?                 // small cover for list rows
    var artSource = ArtSource.unknown   // where the full-size cover comes from; .unknown until tags are read
    var analysis: TrackAnalysis?
    var analyzing = false
    var isStream = false                // internet radio: endless, no tags, no analysis
    var station: RadioStation?
    var locked = false                  // title/artist were set by the app (radio, podcasts): never overwrite them from file tags
    var isDSD: Bool { ["dsf", "dff"].contains(url.pathExtension.lowercased()) }
}

struct HostedPlugin: Identifiable {
    let id = UUID()
    let info: PluginInfo
    let unit: AVAudioUnit
}

enum Tab: String, CaseIterable, Identifiable {
    case home = "Home", player = "Now Playing", search = "Search", radio = "Radio", podcasts = "Podcasts"
    case liked = "Liked Songs", playlists = "Playlists"
    case albums = "Albums", artists = "Artists", songs = "Songs", composers = "Composers", works = "Works", conductors = "Conductors", ensembles = "Ensembles"
    case deepDive = "Deep Dive"
    case audio = "Audio", dsp = "DSP"
    case rip = "Rip CD", convert = "Convert", cloud = "Cloud", intelligence = "Intelligence"
    case folders = "Folders", abx = "ABX Test"
    case settings = "Settings"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "house"; case .player: "play.circle"; case .search: "magnifyingglass"; case .radio: "dot.radiowaves.left.and.right"; case .podcasts: "mic"
        case .albums: "square.stack"; case .artists: "music.mic"; case .songs: "music.note"
        case .liked: "heart"; case .playlists: "music.note.list"
        case .composers: "music.quarternote.3"; case .works: "book"; case .conductors: "wand.and.rays"; case .ensembles: "person.3"
        case .deepDive: "sparkle.magnifyingglass"; case .audio: "waveform"; case .dsp: "slider.vertical.3"; case .rip: "opticaldisc"; case .convert: "arrow.triangle.2.circlepath"; case .cloud: "icloud"; case .intelligence: "brain"; case .folders: "folder"; case .abx: "ear"; case .settings: "gearshape"
        }
    }

    enum Section: String { case listen = "", library = "Library", classical = "Classical", discover = "Discover", sound = "Sound", tools = "Tools", footer = "Settings" }
    var section: Section {
        switch self {
        case .home, .player, .search, .radio, .podcasts: .listen
        case .albums, .artists, .songs, .liked, .playlists, .folders: .library
        case .composers, .works, .conductors, .ensembles: .classical
        case .deepDive: .discover
        case .audio, .dsp: .sound
        case .rip, .convert, .cloud, .intelligence, .abx: .tools
        case .settings: .footer
        }
    }

    var libraryCategory: LibraryModel.Category? {
        switch self {
        case .albums: .albums; case .artists: .artists; case .songs: .songs; case .composers: .composers
        case .works: .works; case .conductors: .conductors; case .ensembles: .ensembles
        default: nil
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", sidebar = "Sidebar", connect = "Connect", midi = "MIDI", system = "System"
    var id: String { rawValue }
    var icon: String { switch self { case .general: "gearshape"; case .sidebar: "sidebar.left"; case .connect: "network"; case .midi: "pianokeys"; case .system: "stethoscope" } }
}

/// The big cover of the current track and the colours derived from it.
struct HeroArt {
    var token = ""
    var image: NSImage?
    var palette = ArtPalette.neutral
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var items: [QueueItem] = []
    /// The engine's latest status. Deliberately not @Published: it changes ten times a second (the playhead), and publishing every tick made every
    /// page redraw continuously. `objectWillChange` fires only when something other than the playhead changed; time lives in `progress`.
    private(set) var status = PlayerStatus()
    let progress = ProgressModel()
    @Published var devices: [OutputDeviceInfo] = []
    @Published var tab: Tab = .home {
        didSet {
            // leaving the DSP page with unsaved changes asks first
            if oldValue == .dsp, tab != .dsp, dspModel.needsPrompt, !djMode {
                pendingTab = tab; tab = .dsp; showDSPPrompt = true
                return
            }
            updateAnalysisActivity()
            // the page's filter belongs to that page: it does not follow you to the next one
            if tab != oldValue, !library.search.isEmpty { library.search = "" }
            if tab == .deepDive { loadDeepDiveForCurrent() }
            if let c = tab.libraryCategory, library.category != c { library.category = c }
            navigator.visit(place)
        }
    }
    /// Normal layout, or the two-deck DJ console.
    @Published var djMode = false {
        didSet {
            defaults.set(djMode, forKey: "aureon.djMode")
            guard djMode != oldValue else { return }
            if djMode { enterDJ() } else { dj.exit(); updateAnalysisActivity() }
        }
    }

    /// The console takes over the output: the normal player stops, and two decks play side by side on the same device.
    private func enterDJ() {
        if started { player.stop(); started = false; resetStatus() }
        player.analysis.setActive(false)
        library.category = .songs
        LibraryModelBridge.shared.model = library
        collections.attach(library.store)
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil {
            repeatMode = RepeatMode(rawValue: defaults.integer(forKey: "aureon.repeat")) ?? .off
            player.repeatMode = repeatMode
        }
        var o = PlayerOptions(); o.hog = false; o.rateSwitch = false; o.deviceID = deviceID == 0 ? nil : deviceID; o.bufferSeconds = 0.4
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil { dj.outputFactory = { core in let p = PullOutput(core: core, speed: 1); p.keep = false; return p } }
        let rate = OutputDevice(id: deviceID == 0 ? nil : deviceID)?.currentRate ?? 48_000
        dj.enter(options: o, rate: rate > 0 ? rate : 48_000)
    }
    @Published var settingsSection: SettingsSection = .general
    /// A page that was hidden from the sidebar and is being used inside Settings instead.
    @Published var settingsPage: Tab?
    @Published var sidebar = SidebarLayout.load() { didSet { if sidebar != oldValue { sidebar.save() } } }
    /// The colour theme. Changing it rebuilds the whole interface (the root view is keyed on the theme's id).
    @Published private(set) var theme: Theme = Theme.current
    /// Which colour theme (its dark and light variants are chosen by `appearance`).
    @Published var themeFamily = "aureon" { didSet { if themeFamily != oldValue { resolveTheme() } } }
    @Published var appearance = AppearanceMode.dark { didSet { if appearance != oldValue { resolveTheme() } } }

    private func resolveTheme(persist: Bool = true) {
        let systemLight = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let light = appearance == .light || (appearance == .system && systemLight)
        theme = themeFamily == "album" ? Theme.album(from: hero.palette, light: light) : Theme.resolve(family: themeFamily, light: light)
        Theme.current = theme
        if persist, ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil { defaults.set(themeFamily, forKey: "aureon.themeFamily"); defaults.set(appearance.rawValue, forKey: "aureon.appearance") }
    }
    let navigator = Navigator(start: Place(tab: .home))
    let radio = RadioModel()
    let podcasts = PodcastModel()
    let artistArt = ArtistArt()
    let dj = DJModel()
    let collections = CollectionsModel()
    let rip = RipModel()
    let convert = ConvertModel()
    let cloud = CloudModel()
    let lms = LMSModel()
    let cast = CastModel()
    let zone = ZoneModel()
    let speakers = SpeakerModel()
    let bridge = BridgeModel()
    let dspModel = DSPModel()
    /// MIDI controllers: mappings, learn and the connection to the DJ, EQ and transport controls.
    let midi = MIDIController()
    @Published var showDSPPrompt = false
    private var pendingTab: Tab?
    private var parameterTokens: [UUID: AUParameterObserverToken] = [:]
    /// The queue panel (slides in over the page, so it can never fall outside the window).
    @Published var showQueue = false
    @Published var showDropToast = false
    @Published var shuffle = ShuffleMode.off { didSet { if shuffle != oldValue { applyShuffle(from: oldValue); defaults.set(shuffle.rawValue, forKey: "aureon.shuffle") } } }
    @Published var repeatMode = RepeatMode.off { didSet { player.repeatMode = repeatMode; defaults.set(repeatMode.rawValue, forKey: "aureon.repeat") } }
    private var originalOrder: [UUID] = []
    private var metaQueue: [UUID] = []
    private var metaSeen = Set<UUID>()
    private var metaRunning = 0
    private var metaFor: UUID?
    private var shuffleNet: TransitionNet?
    private var countedPlay: UUID?
    @Published var viewOptions: [String: ViewOptions] = [:] { didSet { if let d = try? JSONEncoder().encode(viewOptions), ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil { defaults.set(d, forKey: "aureon.viewOptions") } } }

    var place: Place { Place(tab: tab, library: library.selectedID, radio: radio.navKey, podcast: podcasts.navKey) }
    func options(for t: Tab) -> ViewOptions { viewOptions[t.rawValue] ?? ViewOptions.defaults(for: t) }
    func setOptions(_ o: ViewOptions, for t: Tab) { viewOptions[t.rawValue] = o }
    @Published var searchText = "" {
        didSet {
            library.runSearch(searchText.trimmingCharacters(in: .whitespaces))
            if !searchText.isEmpty && tab != .search { withAnimation(.smooth(duration: 0.3)) { tab = .search } }
        }
    }
    let albumArt = AlbumArt()
    @Published var hero = HeroArt() { didSet { if themeFamily == "album", hero.token != oldValue.token { resolveTheme(persist: false) } } }
    @Published var fetchMissingArt = true { didSet { defaults.set(fetchMissingArt, forKey: "aureon.fetchArt"); if fetchMissingArt && !oldValue { lookUpMissingArtwork() } } }
    let artFetcher = ArtworkFetcher()
    private var heroLoading = ""
    @Published var scrub: Double?

    @Published var deviceID: AudioDeviceID = 0 { didSet { if oldValue != deviceID { bindVolumeDevice(); restartInPlace() } } }
    @Published var exclusive = false { didSet { if oldValue != exclusive { restartInPlace(); defaults.set(exclusive, forKey: "aureon.exclusive") } } }
    @Published var followRate = true { didSet { if oldValue != followRate { restartInPlace(); defaults.set(followRate, forKey: "aureon.followRate") } } }

    @Published var settings = PlaybackSettings() {
        didSet {
            guard settings != oldValue else { return }
            // a change that would clash with something that is on is held back until the person says what to do (see SettingRules)
            if !skipRules, let c = SettingRules.check(old: oldValue, new: settings) {
                let proposed = settings
                settings = oldValue
                conflict = ConflictPrompt(message: c.message, fixLabel: c.fixLabel, proposed: proposed, fix: c.fix)
                return
            }
            player.settings = settings; persist()
        }
    }
    private var skipRules = false
    /// A change waiting for an answer: the interface shows it as a question.
    @Published var conflict: ConflictPrompt?

    func resolveConflict(accept: Bool) {
        guard let c = conflict else { return }
        conflict = nil
        guard accept else { return }
        var s = c.proposed
        c.fix(&s)
        skipRules = true; settings = s; skipRules = false
    }

    /// The device volume, only when the device can report it. `volume` is never written from anywhere but `setVolume`, which only the
    /// user's own gestures call: nothing in the app (binding a device, switching tracks, laying out a view) can change the volume.
    @Published private(set) var hasVolume = false
    @Published private(set) var volume: Float = 0
    /// A ceiling for the volume controls (Settings → General). 1 = no limit.
    @Published var volumeLimit: Float = 1 { didSet { defaults.set(volumeLimit, forKey: "aureon.volumeLimit"); if hasVolume, volume > volumeLimit { setVolume(volumeLimit) } } }

    func setVolume(_ v: Float) {
        guard hasVolume, let dev = volumeDevice else { return }
        let c = max(0, min(volumeLimit, v.isFinite ? v : 0))
        if dev.writeVolume(c) { volume = dev.readVolume() ?? c; speakers.matchVolume(volume) } else { volume = dev.readVolume() ?? volume }
    }

    // plugins
    @Published var availableEffects: [PluginInfo] = [] { didSet { effectGroups = Dictionary(grouping: availableEffects, by: \.manufacturer).map { (maker: $0.key, effects: $0.value) }.sorted { $0.maker < $1.maker } } }
    /// Installed effects grouped by manufacturer, computed once instead of on every redraw.
    private(set) var effectGroups: [(maker: String, effects: [PluginInfo])] = []
    @Published var hosted: [HostedPlugin] = []
    @Published var pluginError: String?
    private var pluginWindows: [UUID: NSWindow] = [:]

    // diagnostics
    @Published var diagSteps: [DiagStep] = []
    @Published var diagRunning = false
    @Published var diagHog = false
    @Published var diagInteger = false
    @Published var diagRates = false
    @Published var diagSeconds = 2.0
    private var lastReport: DiagReport?

    let player = Player()
    let library = LibraryModel()
    let deepDive = DeepDiveModel()
    let social = SocialModel()
    let remote = RemoteModel()
    let system = SystemModel()
    let headphones = HeadphoneModel()
    @Published var visualizerEnabled = true { didSet { defaults.set(visualizerEnabled, forKey: "aureon.visualizer"); updateAnalysisActivity() } }
    private var lastQueueRev = -1
    private var cancellables = Set<AnyCancellable>()
    private var trackCache: [UUID: TrackDTO] = [:]
    private var notInLibrary = Set<UUID>()
    private var lastDeepDiveID: UUID?
    private let defaults = UserDefaults.standard
    private var volumeDevice: OutputDevice?
    private var timer: Timer?
    private var persistWork: DispatchWorkItem?
    private var started = false

    init() {
        if let d = defaults.data(forKey: "aureon.settings"), var s = try? JSONDecoder().decode(PlaybackSettings.self, from: d) { s.dsp = DSPSettings(); settings = s; player.settings = s }
        dspModel.apply = { [unowned self] d in self.settings.dsp = d }
        dspModel.captureHosted = { [unowned self] in self.capturePlugins() }
        dspModel.restoreHosted = { [unowned self] saved in await self.restorePlugins(saved); self.dspModel.markPluginsClean() }
        dspModel.pluginCount = { [unowned self] in self.hosted.count }
        cloud.library = library
        lms.library = library
        bridge.library = library
        cast.onRouteChange = { [unowned self] in self.restartInPlace() }
        zone.onRouteChange = { [unowned self] in self.restartInPlace() }
        speakers.onRouteChange = { [unowned self] in self.restartInPlace() }
        zone.cast = cast
        cast.willConnect = { [unowned self] in
            guard self.zone.isActive else { return true }
            guard askToProceed(title: "A multi-room zone is playing", message: "Casting to a single speaker and a zone cannot both use the output. Stop the zone and cast?", proceed: "Stop zone and cast") else { return false }
            self.zone.stop(); return true
        }
        rip.onFinished = { [unowned self] folder in self.library.importOnce(folder) }
        exclusive = defaults.bool(forKey: "aureon.exclusive")
        followRate = defaults.object(forKey: "aureon.followRate") as? Bool ?? true
        // property observers do not run inside init, so the theme is resolved explicitly
        var chosen = Theme.named(ProcessInfo.processInfo.environment["AUREON_THEME"] ?? defaults.string(forKey: "aureon.theme"))
        if let f = defaults.string(forKey: "aureon.themeFamily"), ProcessInfo.processInfo.environment["AUREON_THEME"] == nil {
            chosen = Theme.resolve(family: f, light: AppearanceMode(rawValue: defaults.string(forKey: "aureon.appearance") ?? "dark") == .light)
        }
        themeFamily = chosen.family; appearance = chosen.isLight ? .light : (AppearanceMode(rawValue: defaults.string(forKey: "aureon.appearance") ?? "") ?? .dark)
        resolveTheme()
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.appearance == .system { self?.resolveTheme() } }
        }
        fetchMissingArt = defaults.object(forKey: "aureon.fetchArt") as? Bool ?? true
        volumeLimit = defaults.object(forKey: "aureon.volumeLimit") as? Float ?? 1
        LibraryModelBridge.shared.model = library
        IntelligenceCenter.shared.attach(self)
        if let d = defaults.data(forKey: "aureon.viewOptions"), let v = try? JSONDecoder().decode([String: ViewOptions].self, from: d) { viewOptions = v }
        refreshDevices()
        availableEffects = DSPChain.availableEffects()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [player] _ in
            player.stop()      // restores the device clock and releases exclusive access
        }
        visualizerEnabled = defaults.object(forKey: "aureon.visualizer") as? Bool ?? true
        PerformanceProfile.warmUp()
        library.onAdd = { [weak self] t, p in self?.addTracks(t, play: p) }
        library.onReplace = { [weak self] t in self?.replaceQueue(with: t) }
        albumArt.store = library.store; albumArt.fetcher = artFetcher
        collections.attach(library.store)
        albumArt.fetchOnline = { [weak self] in (self?.fetchMissingArt ?? false) && ProcessInfo.processInfo.environment["AUREON_OFFLINE"] == nil }
        artistArt.store = library.store
        artistArt.fetchOnline = { [weak self] in (self?.fetchMissingArt ?? false) && ProcessInfo.processInfo.environment["AUREON_OFFLINE"] == nil }
        radio.onPlay = { [weak self] st in self?.play(station: st) }
        podcasts.onPlay = { [weak self] ep, show, file in self?.playEpisode(ep, of: show, file: file) }
        // history: every page change, library selection and radio/podcast sub-page is a step that Back and Forward can retrace
        navigator.restore = { [weak self] p in
            guard let self else { return }
            self.tab = p.tab
            if self.library.selectedID != p.library { self.library.selectedID = p.library }
            if let r = p.radio, r != self.radio.navKey { self.radio.restore(r) }
            if let q = p.podcast, q != self.podcasts.navKey { self.podcasts.restore(q) }
        }
        library.$selectedID.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { guard let self else { return }; self.navigator.visit(self.place) } }.store(in: &cancellables)
        radio.$navKey.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { guard let self else { return }; self.navigator.visit(self.place) } }.store(in: &cancellables)
        podcasts.$navKey.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { guard let self else { return }; self.navigator.visit(self.place) } }.store(in: &cancellables)
        remote.makeController = { [unowned self] in self.makeRemoteController() }
        social.$settings.map { ($0.remoteEnabled, $0.remotePort, $0.remoteName) }.removeDuplicates { $0 == $1 }
            .sink { [weak self] enabled, port, name in self?.applyRemote(enabled, port, name) }.store(in: &cancellables)
        system.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.syncRemoteOptions() } }.store(in: &cancellables)
        updateAnalysisActivity()
        midi.resolver = MIDIBinder(dj: dj, dsp: dspModel, transport: self)
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil && ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil { midi.start() }
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil { dspModel.startUp() }
    }

    /// Answer to the "unsaved DSP settings" question.
    func resolveDSPPrompt(save: Bool) {
        if save { saveDSP() }
        else { dspModel.acknowledgeUnsaved() }                  // keep them for this session
        showDSPPrompt = false
        if let t = pendingTab { pendingTab = nil; tab = t }
    }

    func cancelDSPPrompt() { showDSPPrompt = false; pendingTab = nil }

    /// Saves the DSP state into the active profile, asking for a name when there is none yet.
    @discardableResult
    func saveDSP() -> Bool {
        if dspModel.active != nil { dspModel.save(); return true }
        guard let name = promptForText(title: "Save DSP settings", message: "Give this set of EQ and plug-in settings a name.", placeholder: "For example: Headphones", confirm: "Save") else { return false }
        dspModel.saveAs(name)
        return true
    }

    private func persist() {
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil { return }     // snapshots never touch saved settings
        var s = settings; s.dsp = DSPSettings()                  // DSP settings live in profiles and are saved on purpose
        persistWork?.cancel()
        let work = DispatchWorkItem { [defaults] in if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: "aureon.settings") } }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    var current: QueueItem? { started ? items.first { $0.id == status.trackID } : nil }
    /// What the player view shows: the audible track, else the one that will start, else the first in the queue.
    var focusItem: QueueItem? { current ?? items.first { $0.id == status.trackID } ?? items.first }
    var isActive: Bool { started && !status.finished }
    var isDoP: Bool { status.info?.isDoP ?? false }

    // MARK: devices

    func refreshDevices() {
        devices = listOutputDevices()
        if deviceID == 0 || !devices.contains(where: { $0.id == deviceID }) { deviceID = OutputDevice()?.id ?? devices.first?.id ?? 0 }
        bindVolumeDevice()
    }

    private func bindVolumeDevice() {
        volumeDevice = OutputDevice(id: deviceID == 0 ? nil : deviceID)
        let v = volumeDevice?.readVolume()
        hasVolume = v != nil
        volume = v ?? 0
    }

    var selectedDevice: OutputDeviceInfo? { devices.first { $0.id == deviceID } }

    // MARK: queue

    /// Adds files or folders to the queue; `play` starts the first of them at once (used by drag and drop).
    func add(urls: [URL], play start: Bool = false) {
        var found: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                let files = (e?.allObjects as? [URL] ?? []).filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                found += files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if audioExtensions.contains(u.pathExtension.lowercased()) {
                found.append(u)
            }
        }
        guard !found.isEmpty else { return }
        let entries = player.append(found.map(\.path))      // the engine reconciles this live, even while playing
        let new = zip(entries, found).map { QueueItem(id: $0.id, url: $1, title: $1.deletingPathExtension().lastPathComponent) }
        items += new
        for n in new.prefix(3) { requestMetadata(n.id) }
        originalOrder += new.map(\.id)
        if shuffle != .off && !start { reshuffle(keeping: nil) }
        if start, let first = new.first { play(first.id) }
    }

    /// Files or folders dropped on the window: the DJ console loads them on its decks; anywhere else the first one starts playing at once
    /// and the rest join the queue behind it.
    func handleDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if djMode { dj.loadDropped(urls); return }
        let before = items.count
        add(urls: urls, play: true)
        if items.count == before { return }
        withAnimation(.easeOut(duration: 0.2)) { showDropToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.easeOut(duration: 0.3)) { self.showDropToast = false } }
    }

    /// Live radio: the queue becomes this one station.
    func play(station: RadioStation) {
        clear()
        guard let url = URL(string: station.url) else { return }
        let entries = player.append([station.url])
        var item = QueueItem(id: entries[0].id, url: url, title: station.name)
        item.artist = "Internet radio"; item.album = station.country ?? ""; item.genre = station.tags.first ?? ""
        item.isStream = true; item.station = station; item.locked = true
        item.artSource = station.favicon.map { .remote($0) } ?? .none
        items = [item]; lastQueueRev = player.queueRevision
        play(item.id)
        if let f = station.favicon { Task { if let img = await RemoteImages.shared.image(f, maxPixel: 128), let i = items.firstIndex(where: { $0.id == item.id }) { items[i].thumb = img } } }
        Task { await radio.directory.registerClick(station) }
    }

    /// A downloaded podcast episode replaces the queue.
    func playEpisode(_ ep: PodcastEpisode, of show: PodcastShow, file: URL) {
        clear()
        let entries = player.append([file.path])
        var item = QueueItem(id: entries[0].id, url: file, title: ep.title)
        item.artist = show.name; item.album = "Podcast"; item.genre = show.genre ?? ""; item.locked = true
        let art = ep.image ?? show.artwork
        item.artSource = art.map { .remote($0) } ?? .none
        items = [item]; lastQueueRev = player.queueRevision
        play(item.id)
        if let a = art { Task { if let img = await RemoteImages.shared.image(a, maxPixel: 128), let i = items.firstIndex(where: { $0.id == item.id }) { items[i].thumb = img } } }
    }

    /// What to show for the current item: for radio the title comes from the stream's own metadata.
    var focusDisplay: (title: String, artist: String, detail: String)? {
        guard let it = focusItem else { return nil }
        guard it.isStream else { return (it.title, it.artist, [it.album, it.year.map(String.init), it.genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")) }
        let live = status.trackID == it.id ? status.live : nil
        let title = live?.title ?? it.title
        let station = live?.station ?? it.title
        let detail = ["Live radio", it.album.isEmpty ? nil : it.album, live?.bitrate.map { "\($0) kbps" }].compactMap { $0 }.joined(separator: "  ·  ")
        return (title, live?.title != nil ? station : "Internet radio", detail)
    }

    /// "Play": replace the queue with these tracks and start the first.
    func replaceQueue(with tracks: [TrackDTO]) {
        guard !tracks.isEmpty else { return }
        clear()
        addTracks(tracks, play: true)
    }

    func clear() { player.stop(); player.clearQueue(); started = false; items = []; originalOrder = []; metaQueue = []; metaSeen = []; resetStatus() }

    private func resetStatus() { status = PlayerStatus(); progress.update(position: 0, duration: 0); objectWillChange.send() }

    func remove(ids: Set<UUID>) { player.remove(ids: ids); items.removeAll { ids.contains($0.id) } }
    func remove(at offsets: IndexSet) { remove(ids: Set(offsets.map { items[$0].id })) }
    func move(from: IndexSet, to: Int) { player.move(from: from, to: to); items.move(fromOffsets: from, toOffset: to) }

    /// Reads tags and the embedded cover with Aureon's own parsers (AVFoundation fills gaps), then looks for a cover online when the file has none.
    private func loadMetadata(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }), !item.locked, !item.isStream else { return }
        let tags = await MetadataEngine.load(path: item.path)
        let path = item.path
        let thumb = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let pic = tags.picture else { return nil }
            // the cover is in hand now: keep it, so Now Playing and its colours never need to read this file's tags again
            if let s = ArtCache.Source.localFile(path), case .miss = ArtCache.shared.lookup(s) { ArtCache.shared.store(s, data: pic.data) }
            return ImageTools.nsImage(pic.data, maxPixel: 128)
        }.value
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let t = tags.title, !t.isEmpty { items[i].title = t }
        items[i].artist = tags.displayArtist ?? ""; items[i].albumArtist = tags.albumArtist ?? ""
        items[i].album = tags.album ?? ""; items[i].composer = tags.composer ?? ""; items[i].genre = tags.genre ?? ""
        items[i].year = tags.year; items[i].trackNumber = tags.trackNumber; items[i].trackTotal = tags.trackTotal
        if tags.picture != nil, let thumb { items[i].thumb = thumb; items[i].artSource = .embedded }
        else { items[i].artSource = .none }
        if items[i].artSource == .none { await fetchOnlineArt(id) }
    }

    private func fetchOnlineArt(_ id: UUID) async {
        guard fetchMissingArt, let i = items.firstIndex(where: { $0.id == id }), !items[i].album.isEmpty,
              ProcessInfo.processInfo.environment["AUREON_OFFLINE"] == nil else { return }
        let artist = items[i].albumArtist.isEmpty ? items[i].artist : items[i].albumArtist, album = items[i].album
        guard let data = await artFetcher.cover(artist: artist, album: album) else { return }
        let thumb = await Task.detached(priority: .utility) { ImageTools.nsImage(data, maxPixel: 128) }.value
        // every queued track of the same album shares the cover
        for k in items.indices where items[k].artSource == .none && items[k].album == album && (items[k].albumArtist.isEmpty ? items[k].artist : items[k].albumArtist) == artist {
            items[k].thumb = thumb; items[k].artSource = .fetched
        }
    }

    /// Runs the online lookup for tracks that were queued while the setting was off.
    func lookUpMissingArtwork() {
        for id in items.filter({ $0.artSource == .none }).map(\.id) { Task { await fetchOnlineArt(id) } }
    }

    // MARK: hero art

    private func refreshHero() {
        guard let item = focusItem, item.artSource != .unknown else {
            if focusItem == nil, hero.token != "" { hero = HeroArt(); heroLoading = "" }
            return
        }
        let token = "\(item.id.uuidString)|\(item.artSource)"
        guard token != hero.token, token != heroLoading else { return }
        heroLoading = token
        let path = item.path, source = item.artSource
        let artist = item.albumArtist.isEmpty ? item.artist : item.albumArtist, album = item.album
        let seed = album.isEmpty ? item.title : album
        let fetcher = artFetcher
        let cacheSource: ArtCache.Source? = switch source {
        case .embedded: ArtCache.Source.localFile(path)
        case .fetched: ArtCache.Source.fetched(artist: artist, album: album)
        case .remote(let u): ArtCache.Source.url(u)
        default: nil
        }
        let image: @Sendable (CGImage) -> NSImage = { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        Task {
            // From the cache this is one small JPEG and the stored palette (no tag parsing, no colour maths). Otherwise the cover is read, stored for
            // next time and its colours worked out, all off the main thread. Either way the interface keeps showing the previous look until the result
            // is there and then fades the new colours in, so changing track never waits for them.
            var result: (NSImage?, ArtPalette)? = await Task.detached(priority: .userInitiated) { () -> (NSImage?, ArtPalette)? in
                guard let s = cacheSource, let l = ArtCache.shared.loaded(s) else { return nil }
                return (image(l.picture), l.palette)
            }.value
            if result == nil {
                let data: Data? = switch source {
                case .embedded: await MetadataEngine.artwork(path: path)
                case .fetched: await fetcher.cached(artist: artist, album: album)
                case .remote(let u): await RemoteImageStore.shared.data(u)
                default: nil
                }
                result = await Task.detached(priority: .userInitiated) { () -> (NSImage?, ArtPalette) in
                    guard let data else { return (nil, ArtPalette.fallback(seed: seed)) }
                    if let s = cacheSource, let l = ArtCache.shared.ingest(s, data: data) { return (image(l.picture), l.palette) }
                    guard let cg = ImageTools.cgImage(data, maxPixel: ArtCache.largePixels) else { return (nil, ArtPalette.fallback(seed: seed)) }
                    return (image(cg), ArtPalette.extract(from: cg))
                }.value
            }
            guard heroLoading == token, let result else { return }
            withAnimation(.smooth(duration: 0.9)) { hero = HeroArt(token: token, image: result.0, palette: result.1) }
        }
    }

    private func analyzeIfNeeded(_ id: UUID?) {
        guard let id, let i = items.firstIndex(where: { $0.id == id }), items[i].analysis == nil, !items[i].analyzing, !items[i].isDSD, !items[i].isStream else { return }
        items[i].analyzing = true
        let path = items[i].path
        Task.detached(priority: .utility) {
            let a = analyzeTrack(path: path)
            await MainActor.run { [weak self] in
                guard let self, let k = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[k].analysis = a; self.items[k].analyzing = false
            }
        }
    }

    // MARK: transport

    var options: PlayerOptions {
        var o = PlayerOptions(); o.hog = exclusive; o.rateSwitch = followRate; o.deviceID = deviceID == 0 ? nil : deviceID
        o.tuning = system.quietMode ? system.quiet : nil
        if let f = zone.sinkFactory ?? cast.sinkFactory ?? speakers.sinkFactory(primary: deviceID) { o.sinkFactory = f }
        o.promoteEngineThread = system.promoteEngine
        if ProcessInfo.processInfo.environment["AUREON_NULLSINK"] != nil { o.sinkFactory = { _ in NullSink() } }
        o.ioCycleUsage = system.useCycleUsage ? Float(system.cycleUsage) : nil
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil { dj.outputFactory = { core in let p = PullOutput(core: core, speed: 1); p.keep = false; return p } }      // snapshots make no sound
        return o
    }

    func play(_ id: UUID, at seconds: Double = 0) {
        requestMetadata(id, urgent: true)
        if isActive && seconds == 0 { player.send(.jump(id)); return }
        started = true
        resetStatus()
        syncRemoteOptions()
        player.start(startID: id, startSeconds: seconds, options: options)
    }

    func togglePlay() {
        if isActive { player.send(.togglePause) }
        else if let first = (current ?? items.first(where: { $0.id == status.trackID }) ?? items.first) { play(first.id) }
    }

    /// Device / exclusive / rate-follow changes need the device re-negotiated: resume at the same spot.
    func restartInPlace() {
        guard isActive, let id = status.trackID, status.state != .idle else { return }
        let pos = status.position, wasPaused = status.state == .paused
        play(id, at: max(pos, 0.0001))
        if wasPaused { player.send(.setPaused(true)) }
    }

    private func tick() {
        let s = player.status
        // playback can also be started by a remote app: follow the engine, not just our own buttons
        let running = player.isRunning
        if running != started { started = running }
        if started || s.finished {
            let structural = !status.sameStructure(as: s)
            status = s
            progress.update(position: s.position, duration: s.duration)
            if structural { objectWillChange.send() }
        }
        if player.queueRevision != lastQueueRev { reconcileItems() }
        refreshHero()
        countPlay()
        if started, s.trackID != metaFor { metaFor = s.trackID; if let id = s.trackID, let i = items.firstIndex(where: { $0.id == id }) { requestMetadata(id, urgent: true); for k in 1...2 where i + k < items.count { requestMetadata(items[i + k].id) } } }
        if started, s.state == .playing || s.state == .paused { analyzeIfNeeded(s.trackID) }
        if started && s.trackID != lastDeepDiveID && tab == .deepDive { loadDeepDiveForCurrent() }
        let playing = started && s.state == .playing
        social.update(started ? nowPlayingInfo() : nil, position: s.position, playing: playing)
    }

    // MARK: queue sync, now playing

    /// The engine's queue is the truth (a remote app may have edited it): bring the visible list in line.
    private func reconcileItems() {
        lastQueueRev = player.queueRevision
        let q = player.queue
        guard q.map(\.id) != items.map(\.id) else { return }
        var byID: [UUID: QueueItem] = [:]
        for i in items { byID[i.id] = i }
        let known = library.store?.tracks(paths: q.map(\.path)) ?? [:]
        var fresh: [UUID] = []
        items = q.map { e in
            if let i = byID[e.id] { return i }
            fresh.append(e.id)
            let url = URL(fileURLWithPath: e.path, isDirectory: false)
            let remote = RemoteMedia.isRemote(e.path) ? e.path : nil
            if let t = known[e.path] { return QueueItem(id: e.id, url: url, title: t.title, artist: t.artistLine, album: t.releaseTitle ?? "", remotePath: remote) }
            return QueueItem(id: e.id, url: url, title: url.deletingPathExtension().lastPathComponent, remotePath: remote)
        }
        _ = fresh                                   // covers load as their rows appear (see requestMetadata)
    }

    /// Adds library tracks to the queue (and optionally starts the first).
    func addTracks(_ tracks: [TrackDTO], play start: Bool) {
        guard !tracks.isEmpty else { return }
        let entries = player.append(tracks.map(\.path))
        let new = zip(entries, tracks).map { QueueItem(id: $0.id, url: URL(fileURLWithPath: $1.path, isDirectory: false), title: $1.title, artist: $1.artistLine, album: $1.releaseTitle ?? "", remotePath: RemoteMedia.isRemote($1.path) ? $1.path : nil) }
        items += new; lastQueueRev = player.queueRevision
        for n in new.prefix(3) { requestMetadata(n.id) }
        originalOrder += new.map(\.id)
        if shuffle != .off { reshuffle(keeping: start ? new.first?.id : nil) }
        if start, let first = new.first { play(first.id) }
    }

    /// How much of a list goes into the queue when one song is clicked: a little history for Previous, plenty ahead. A whole library is never queued.
    nonisolated static let queueWindow = (before: 30, after: 470)
    nonisolated static func queueRange(count: Int, index: Int) -> Range<Int> {
        max(0, index - queueWindow.before)..<min(count, index + queueWindow.after + 1)
    }

    /// Replaces the queue with songs from `tracks` around `index` and starts the one at `index`. While something is playing the engine just jumps
    /// to the new queue (the output device is not torn down), so changing songs quickly stays instant.
    func play(tracks: [TrackDTO], at index: Int) {
        guard tracks.indices.contains(index) else { return }
        let range = Self.queueRange(count: tracks.count, index: index)
        let slice = Array(tracks[range]), start = index - range.lowerBound
        func item(_ e: QueueEntry, _ t: TrackDTO) -> QueueItem { QueueItem(id: e.id, url: URL(fileURLWithPath: t.path, isDirectory: false), title: t.title, artist: t.artistLine, album: t.releaseTitle ?? "", remotePath: RemoteMedia.isRemote(t.path) ? t.path : nil) }
        if isActive {
            let entries = player.replace(with: slice.map(\.path), startAt: start)
            items = zip(entries, slice).map(item)
            lastQueueRev = player.queueRevision
            originalOrder = items.map(\.id)
            let first = items[start].id
            if shuffle != .off { reshuffle(keeping: first) }
            requestMetadata(first, urgent: true)
            for k in 1...2 where start + k < items.count { requestMetadata(items[start + k].id) }
            return
        }
        clear()
        let entries = player.append(slice.map(\.path))
        items = zip(entries, slice).map(item)
        lastQueueRev = player.queueRevision
        originalOrder = items.map(\.id)
        let first = items[start].id
        if shuffle != .off { reshuffle(keeping: first) }
        play(first)
    }

    // MARK: lazy tags and covers

    /// Reads a queued song's tags and cover when it is about to matter (playing soon, or its row is on screen), at most three at a time.
    func requestMetadata(_ id: UUID, urgent: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].artSource == .unknown, !items[i].locked, !items[i].isStream else { return }
        if metaSeen.contains(id) {
            if urgent, let k = metaQueue.firstIndex(of: id) { metaQueue.remove(at: k); metaQueue.insert(id, at: 0) }
            return
        }
        metaSeen.insert(id)
        if urgent { metaQueue.insert(id, at: 0) } else { metaQueue.append(id) }
        pumpMetadata()
    }

    private func pumpMetadata() {
        while metaRunning < 3, !metaQueue.isEmpty {
            let id = metaQueue.removeFirst()
            metaRunning += 1
            Task { await loadMetadata(id); metaRunning -= 1; pumpMetadata() }
        }
    }

    /// Queues songs right after the one that is playing.
    func playNext(_ tracks: [TrackDTO]) {
        guard !tracks.isEmpty else { return }
        let at = (items.firstIndex { $0.id == status.trackID } ?? -1) + 1
        let entries = player.insert(tracks.map(\.path), at: at)
        let new = zip(entries, tracks).map { QueueItem(id: $0.id, url: URL(fileURLWithPath: $1.path, isDirectory: false), title: $1.title, artist: $1.artistLine, album: $1.releaseTitle ?? "", remotePath: RemoteMedia.isRemote($1.path) ? $1.path : nil) }
        items.insert(contentsOf: new, at: min(at, items.count)); lastQueueRev = player.queueRevision
        originalOrder += new.map(\.id)
        for n in new.prefix(3) { requestMetadata(n.id) }
    }

    // MARK: shuffle

    /// Turns shuffle on, off or switches between normal and smart.
    private func applyShuffle(from old: ShuffleMode) {
        if shuffle == .off {
            let order = Shuffler.restore(current: items.map(\.id), original: originalOrder)
            player.setOrder(order)
            return
        }
        if old == .off { originalOrder = items.map(\.id) }
        reshuffle(keeping: nil)
    }

    /// Shuffles what is still to come; the playing song and everything already played stay where they are. `keeping` forces one song to be first of the rest.
    private func reshuffle(keeping first: UUID?) {
        let ids = items.map(\.id)
        guard ids.count > 1 else { return }
        let curID = first ?? (isActive ? status.trackID : nil)
        let curIndex = curID.flatMap { ids.firstIndex(of: $0) } ?? -1
        let head = first != nil ? [] : Array(ids[0..<max(0, curIndex)])               // played songs
        let cur = first ?? (curIndex >= 0 ? ids[curIndex] : nil)
        let rest = ids.filter { !head.contains($0) && $0 != cur }
        let mode = shuffle
        switch mode {
        case .off: return
        case .normal:
            var rng = SystemRandomNumberGenerator()
            player.setOrder(head + (cur.map { [$0] } ?? []) + Shuffler.normal(rest, using: &rng))
        case .smart:
            let paths = Dictionary(items.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
            // the transition network is an AI feature: with Intelligence (or Smart Shuffle's network) off, the shuffle uses plain rules
            let useNet = IntelligenceGate.shared.isEnabled(.smartShuffle)
            let store = library.store, net: TransitionNet? = useNet ? (shuffleNet ?? TransitionNet.loadOrCreate()) : nil
            shuffleNet = net
            let wanted = Set(ids)
            Task {
                let order: [UUID] = await Task.detached(priority: .userInitiated) {
                    let known = store?.tracks(paths: Array(paths.values)) ?? [:]
                    func cand(_ id: UUID) -> ShuffleCandidate {
                        let path = paths[id] ?? ""
                        let t = known[path]
                        return ShuffleCandidate(id: id, path: path, artist: LibraryStore.fold(t?.primaryArtistLine.split(separator: ",").first.map(String.init) ?? ""), album: t?.releaseID ?? "", genres: t?.genres ?? [], year: t?.year,
                                                liked: t?.isLiked ?? false, playCount: t?.playCount ?? 0, lastPlayedAt: t?.lastPlayedAt, analysis: AnalysisCache.shared.cached(path: path))
                    }
                    var rng = SystemRandomNumberGenerator()
                    return head + (cur.map { [$0] } ?? []) + Shuffler.smart(rest.map(cand), start: cur.map(cand), net: net, using: &rng).filter { $0 != cur }
                }.value
                // apply only if the queue is still the one we shuffled and smart shuffle is still on
                guard shuffle == mode, Set(items.map(\.id)) == wanted else { return }
                player.setOrder(order)
            }
        }
    }

    /// Counts a play once a song has been heard for ten seconds (feeds Smart Shuffle and “most played”).
    private func countPlay() {
        guard started, status.state == .playing, status.position > 10, let id = status.trackID, countedPlay != id, let item = items.first(where: { $0.id == id }), !item.isStream else { return }
        countedPlay = id
        library.store?.recordPlay(path: item.path)
    }

    func nowPlayingInfo() -> NowPlayingInfo? {
        guard started, status.state == .playing || status.state == .paused, let item = items.first(where: { $0.id == status.trackID }), let raw = status.sourceInfo else { return nil }
        var lib = trackCache[item.id]
        if lib == nil && !notInLibrary.contains(item.id) {
            lib = library.store?.track(path: item.path)
            if let l = lib { trackCache[item.id] = l } else { notInLibrary.insert(item.id) }
        }
        var n = NowPlayingInfo(id: item.id.uuidString, title: lib?.title ?? item.title, artist: lib?.artistLine ?? item.artist, album: lib?.releaseTitle ?? item.album)
        n.duration = status.duration; n.codec = raw.codec; n.bitDepth = raw.sourceBits; n.sampleRate = raw.sampleRate
        n.mbRecordingID = lib?.mbRecordingID; n.trackNumber = lib?.trackNumber
        if deepDive.loadedKey == item.id.uuidString { n.coverURL = deepDive.coverURL }
        return n
    }

    func loadDeepDiveForCurrent(force: Bool = false) {
        if ProcessInfo.processInfo.environment["AUREON_DEMO"] != nil { return }          // demo mode keeps its sample data
        guard let item = current else { deepDive.reset(); lastDeepDiveID = nil; return }
        lastDeepDiveID = item.id
        var mbid = library.store?.track(path: item.path)?.mbRecordingID
        if mbid == nil { mbid = TagReader.read(path: item.path).first("MUSICBRAINZ_TRACKID").flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces))?.uuidString.lowercased() } }
        deepDive.load(path: item.path, recordingID: mbid, key: item.id.uuidString, acoustID: social.settings.acoustIDKey, fpcalc: social.settings.fpcalcPath, force: force)
    }

    private func updateAnalysisActivity() { player.analysis.setActive(tab == .player && visualizerEnabled) }

    // MARK: remote control

    private func makeRemoteController() -> RemoteController {
        let name = social.settings.remoteName.isEmpty ? (Host.current().localizedName ?? "Aureon") : social.settings.remoteName
        return RemoteController(player: player, library: library.store ?? (try! LibraryStore()), options: options, name: name, allowedRoots: library.folders)
    }

    private func applyRemote(_ enabled: Bool, _ port: Int, _ name: String) {
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil { return }
        if enabled { remote.start(port: UInt16(clamping: port), name: name) } else { remote.stop() }
    }

    func syncRemoteOptions() { remote.controller?.playerOptions = options }

    // MARK: plugins

    func addPlugin(_ info: PluginInfo) {
        Task {
            do {
                let unit = try await DSPChain.instantiate(info)
                hosted.append(HostedPlugin(info: info, unit: unit))
                observeParameters(of: hosted[hosted.count - 1])
                settings.dsp.enabled = true; dspModel.draft.enabled = true
                dspModel.notePluginsChanged()
                player.setPlugins(hosted.map(\.unit))
                pluginError = nil
            } catch { pluginError = "Could not load \(info.name): \(error.localizedDescription)" }
        }
    }

    func removePlugin(_ id: UUID) {
        pluginWindows[id]?.close(); pluginWindows[id] = nil
        if let h = hosted.first(where: { $0.id == id }), let t = parameterTokens[id] { h.unit.auAudioUnit.parameterTree?.removeParameterObserver(t); parameterTokens[id] = nil }
        hosted.removeAll { $0.id == id }
        dspModel.notePluginsChanged()
        player.setPlugins(hosted.map(\.unit))
    }

    /// Notices when the user turns a knob inside a plug-in's own window, so the profile knows it has unsaved changes.
    func observeParameters(of p: HostedPlugin) {
        guard let tree = p.unit.auAudioUnit.parameterTree else { return }
        parameterTokens[p.id] = tree.token(byAddingParameterObserver: { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dspModel.notePluginsChanged() } }
        })
    }

    func movePlugin(from: IndexSet, to: Int) { hosted.move(fromOffsets: from, toOffset: to); dspModel.notePluginsChanged(); player.setPlugins(hosted.map(\.unit)) }

    /// Opens a plug-in's own window. The window can be resized; a plug-in whose view is bigger than the screen (or than the window) scrolls.
    func openPluginUI(_ p: HostedPlugin) {
        if let w = pluginWindows[p.id] { w.makeKeyAndOrderFront(nil); return }
        let title = "\(p.info.manufacturer) \(p.info.name)"
        p.unit.auAudioUnit.requestViewController { [weak self] vc in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let w: NSWindow
                    if let vc { w = PluginWindowFactory.window(title: title, custom: vc) }
                    else {
                        // No custom UI (typical for AUv2): the system's generic parameter view, which lists every parameter and scrolls
                        let generic = AUGenericView(audioUnit: p.unit.audioUnit)
                        generic.showsExpertParameters = true
                        w = PluginWindowFactory.window(title: title, generic: generic)
                    }
                    w.makeKeyAndOrderFront(nil)
                    self.pluginWindows[p.id] = w
                }
            }
        }
    }

    // MARK: diagnostics

    func runDiagnostics() {
        guard !diagRunning else { return }
        diagRunning = true; diagSteps = []
        var o = DiagOptions()
        o.deviceID = deviceID == 0 ? nil : deviceID
        o.testHog = diagHog || diagInteger; o.testIntegerFormats = diagInteger; o.testRates = diagRates; o.ioSeconds = diagSeconds
        // Playback holds the device; diagnostics that change device state need it idle.
        if isActive && (o.testHog || o.testRates) { player.stop(); started = false }
        Task.detached {
            let report = HardwareDiagnostics.run(o) { step in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.diagSteps.append(step) } }
            }
            await MainActor.run { self.lastReport = report; self.diagRunning = false }
        }
    }

    func exportDiagnostics() {
        guard let r = lastReport else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = "aureon-diagnostics.json"; p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let url = p.url {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            try? enc.encode(r).write(to: url)
        }
    }
}

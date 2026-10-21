import SwiftUI
import Combine
import AppKit
import AVFoundation
import CoreAudio
import CoreAudioKit
import UniformTypeIdentifiers

let audioExtensions: Set<String> = ["flac", "wav", "aif", "aiff", "alac", "m4a", "caf", "dsf", "dff"]

struct QueueItem: Identifiable {
    enum ArtSource: Equatable { case unknown, embedded, fetched, none }
    let id: UUID
    let url: URL
    var title: String
    var artist = ""
    var album = ""
    var albumArtist = ""
    var composer = ""
    var genre = ""
    var year: Int?
    var trackNumber: Int?, trackTotal: Int?
    var thumb: NSImage?                 // small cover for list rows
    var artSource = ArtSource.unknown   // where the full-size cover comes from; .unknown until tags are read
    var analysis: TrackAnalysis?
    var analyzing = false
    var isDSD: Bool { ["dsf", "dff"].contains(url.pathExtension.lowercased()) }
}

struct HostedPlugin: Identifiable {
    let id = UUID()
    let info: PluginInfo
    let unit: AVAudioUnit
}

enum Tab: String, CaseIterable, Identifiable {
    case player = "Player", library = "Library", deepDive = "Deep Dive", audio = "Audio", dsp = "DSP", connect = "Connect", diagnostics = "System"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .player: "play.circle"; case .library: "books.vertical"; case .deepDive: "magnifyingglass.circle"; case .audio: "waveform"
        case .dsp: "slider.vertical.3"; case .connect: "network"; case .diagnostics: "stethoscope"
        }
    }
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
    @Published var status = PlayerStatus()
    @Published var devices: [OutputDeviceInfo] = []
    @Published var tab: Tab = .player { didSet { updateAnalysisActivity(); if tab == .deepDive { loadDeepDiveForCurrent() } } }
    @Published var hero = HeroArt()
    @Published var fetchMissingArt = true { didSet { defaults.set(fetchMissingArt, forKey: "aureon.fetchArt"); if fetchMissingArt && !oldValue { lookUpMissingArtwork() } } }
    let artFetcher = ArtworkFetcher()
    private var heroLoading = ""
    @Published var scrub: Double?

    @Published var deviceID: AudioDeviceID = 0 { didSet { if oldValue != deviceID { bindVolumeDevice(); restartInPlace() } } }
    @Published var exclusive = false { didSet { if oldValue != exclusive { restartInPlace(); defaults.set(exclusive, forKey: "aureon.exclusive") } } }
    @Published var followRate = true { didSet { if oldValue != followRate { restartInPlace(); defaults.set(followRate, forKey: "aureon.followRate") } } }

    @Published var settings = PlaybackSettings() {
        didSet { if settings != oldValue { player.settings = settings; persist() } }
    }

    @Published var hasVolume = false
    @Published var volume: Float = 1 { didSet { if !syncingVolume { volumeDevice?.hardwareVolume = volume } } }

    // plugins
    @Published var availableEffects: [PluginInfo] = []
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
    private var syncingVolume = false
    private var timer: Timer?
    private var started = false

    init() {
        if let d = defaults.data(forKey: "aureon.settings"), let s = try? JSONDecoder().decode(PlaybackSettings.self, from: d) { settings = s; player.settings = s }
        exclusive = defaults.bool(forKey: "aureon.exclusive")
        followRate = defaults.object(forKey: "aureon.followRate") as? Bool ?? true
        fetchMissingArt = defaults.object(forKey: "aureon.fetchArt") as? Bool ?? true
        refreshDevices()
        availableEffects = DSPChain.availableEffects()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [player] _ in
            player.stop()      // restores the device clock and releases exclusive access
        }
        visualizerEnabled = defaults.object(forKey: "aureon.visualizer") as? Bool ?? true
        library.onAdd = { [weak self] t, p in self?.addTracks(t, play: p) }
        remote.makeController = { [unowned self] in self.makeRemoteController() }
        social.$settings.map { ($0.remoteEnabled, $0.remotePort, $0.remoteName) }.removeDuplicates { $0 == $1 }
            .sink { [weak self] enabled, port, name in self?.applyRemote(enabled, port, name) }.store(in: &cancellables)
        system.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.syncRemoteOptions() } }.store(in: &cancellables)
        updateAnalysisActivity()
    }

    private func persist() {
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil { return }     // snapshots never touch saved settings
        if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: "aureon.settings") }
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
        hasVolume = volumeDevice?.hasHardwareVolume ?? false
        syncingVolume = true; volume = volumeDevice?.hardwareVolume ?? 1; syncingVolume = false
    }

    var selectedDevice: OutputDeviceInfo? { devices.first { $0.id == deviceID } }

    // MARK: queue

    func add(urls: [URL]) {
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
        for n in new { Task { await loadMetadata(n.id) } }
    }

    func clear() { player.stop(); player.clearQueue(); started = false; items = []; status = PlayerStatus() }

    func remove(ids: Set<UUID>) { player.remove(ids: ids); items.removeAll { ids.contains($0.id) } }
    func remove(at offsets: IndexSet) { remove(ids: Set(offsets.map { items[$0].id })) }
    func move(from: IndexSet, to: Int) { player.move(from: from, to: to); items.move(fromOffsets: from, toOffset: to) }

    /// Reads tags and the embedded cover with Aureon's own parsers (AVFoundation fills gaps), then looks for a cover online when the file has none.
    private func loadMetadata(_ id: UUID) async {
        guard let url = items.first(where: { $0.id == id })?.url else { return }
        let tags = await MetadataEngine.load(path: url.path)
        let thumb = await Task.detached(priority: .utility) { tags.picture.flatMap { ImageTools.nsImage($0.data, maxPixel: 128) } }.value
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
        let path = item.url.path, source = item.artSource
        let artist = item.albumArtist.isEmpty ? item.artist : item.albumArtist, album = item.album
        let seed = album.isEmpty ? item.title : album
        let fetcher = artFetcher
        Task {
            let data: Data? = switch source {
            case .embedded: await MetadataEngine.artwork(path: path)
            case .fetched: await fetcher.cached(artist: artist, album: album)
            default: nil
            }
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage?, ArtPalette) in
                guard let data, let cg = ImageTools.cgImage(data, maxPixel: 1600) else { return (nil, ArtPalette.fallback(seed: seed)) }
                return (NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), ArtPalette.extract(from: cg))
            }.value
            guard heroLoading == token else { return }
            withAnimation(.smooth(duration: 0.9)) { hero = HeroArt(token: token, image: result.0, palette: result.1) }
        }
    }

    private func analyzeIfNeeded(_ id: UUID?) {
        guard let id, let i = items.firstIndex(where: { $0.id == id }), items[i].analysis == nil, !items[i].analyzing, !items[i].isDSD else { return }
        items[i].analyzing = true
        let path = items[i].url.path
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
        o.promoteEngineThread = system.promoteEngine
        o.ioCycleUsage = system.useCycleUsage ? Float(system.cycleUsage) : nil
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil { o.sinkFactory = { _ in NullSink() } }      // snapshots make no sound
        return o
    }

    func play(_ id: UUID, at seconds: Double = 0) {
        if isActive && seconds == 0 { player.send(.jump(id)); return }
        started = true
        status = PlayerStatus()
        syncRemoteOptions()
        player.start(startID: id, startSeconds: seconds, options: options)
    }

    func togglePlay() {
        if isActive { player.send(.togglePause) }
        else if let first = (current ?? items.first(where: { $0.id == status.trackID }) ?? items.first) { play(first.id) }
    }

    /// Device / exclusive / rate-follow changes need the device re-negotiated: resume at the same spot.
    private func restartInPlace() {
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
        if started || s.finished { status = s }
        if player.queueRevision != lastQueueRev { reconcileItems() }
        refreshHero()
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
            let url = URL(fileURLWithPath: e.path)
            if let t = known[e.path] { return QueueItem(id: e.id, url: url, title: t.title, artist: t.artistLine, album: t.releaseTitle ?? "") }
            return QueueItem(id: e.id, url: url, title: url.deletingPathExtension().lastPathComponent)
        }
        for id in fresh { Task { await loadMetadata(id) } }
    }

    /// Adds library tracks to the queue (and optionally starts the first).
    func addTracks(_ tracks: [TrackDTO], play start: Bool) {
        guard !tracks.isEmpty else { return }
        let entries = player.append(tracks.map(\.path))
        let new = zip(entries, tracks).map { QueueItem(id: $0.id, url: URL(fileURLWithPath: $1.path), title: $1.title, artist: $1.artistLine, album: $1.releaseTitle ?? "") }
        items += new; lastQueueRev = player.queueRevision
        for n in new { Task { await loadMetadata(n.id) } }
        if start, let first = new.first { play(first.id) }
    }

    func nowPlayingInfo() -> NowPlayingInfo? {
        guard started, status.state == .playing || status.state == .paused, let item = items.first(where: { $0.id == status.trackID }), let raw = status.sourceInfo else { return nil }
        var lib = trackCache[item.id]
        if lib == nil && !notInLibrary.contains(item.id) {
            lib = library.store?.track(path: item.url.path)
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
        var mbid = library.store?.track(path: item.url.path)?.mbRecordingID
        if mbid == nil { mbid = TagReader.read(path: item.url.path).first("MUSICBRAINZ_TRACKID") }
        deepDive.load(path: item.url.path, recordingID: mbid, key: item.id.uuidString, acoustID: social.settings.acoustIDKey, fpcalc: social.settings.fpcalcPath, force: force)
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
                player.setPlugins(hosted.map(\.unit))
                pluginError = nil
            } catch { pluginError = "Could not load \(info.name): \(error.localizedDescription)" }
        }
    }

    func removePlugin(_ id: UUID) {
        pluginWindows[id]?.close(); pluginWindows[id] = nil
        hosted.removeAll { $0.id == id }
        player.setPlugins(hosted.map(\.unit))
    }

    func movePlugin(from: IndexSet, to: Int) { hosted.move(fromOffsets: from, toOffset: to); player.setPlugins(hosted.map(\.unit)) }

    func openPluginUI(_ p: HostedPlugin) {
        if let w = pluginWindows[p.id] { w.makeKeyAndOrderFront(nil); return }
        func show(_ vc: NSViewController) {
            let w = NSWindow(contentViewController: vc)
            w.title = "\(p.info.manufacturer) \(p.info.name)"
            w.styleMask.insert([.closable, .miniaturizable])
            w.isReleasedWhenClosed = false
            w.makeKeyAndOrderFront(nil)
            pluginWindows[p.id] = w
        }
        p.unit.auAudioUnit.requestViewController { [weak self] vc in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let vc { show(vc); return }
                    // No custom UI (typical for AUv2): fall back to the system's generic parameter view.
                    let generic = AUGenericView(audioUnit: p.unit.audioUnit)
                    generic.showsExpertParameters = true
                    let host = NSViewController(); host.view = generic
                    host.preferredContentSize = NSSize(width: 520, height: 360)
                    show(host)
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

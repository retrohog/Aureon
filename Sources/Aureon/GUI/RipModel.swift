import SwiftUI
import AppKit

@MainActor
final class RipModel: ObservableObject {
    enum Phase: Equatable { case idle, ripping, finished }

    struct TrackState: Equatable {
        var enabled = true
        var progress = 0.0
        var done = false
        var report: TrackRipReport?
        var fileName: String?
    }

    @Published private(set) var discs: [DiscInfo] = []
    @Published private(set) var toc: CDTOC?
    @Published private(set) var driveName = ""
    @Published private(set) var supportsC2 = false
    @Published private(set) var source: CDSource?
    @Published var meta = RipMetadata()
    @Published private(set) var releases: [MBDiscRelease] = []
    @Published var selectedRelease: String?
    @Published private(set) var lookingUp = false
    @Published private(set) var arPressings: [ARPressing]?
    @Published private(set) var arState = "Not checked"
    @Published var tracks: [Int: TrackState] = [:]
    @Published private(set) var phase = Phase.idle
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var logURL: URL?
    @Published private(set) var outputFolder: URL?

    @Published var options = RipOptions() { didSet { save() } }
    @Published var format = RipFormat.flac { didSet { save() } }
    @Published var destination: URL { didSet { save() } }

    var http: HTTPClient = URLSessionClient()
    var musicBrainz = MusicBrainzClient()
    var accurateRip = AccurateRipClient()
    var onFinished: ((URL) -> Void)?
    private var task: Task<Void, Never>?
    private var cancelFlag = Atomic2()
    private let defaults = UserDefaults.standard

    final class Atomic2: @unchecked Sendable { private let l = NSLock(); private var v = false; var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } } }

    init() {
        destination = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Ripped CDs", isDirectory: true)
        if let d = defaults.data(forKey: "aureon.rip.options"), let o = try? JSONDecoder().decode(RipOptions.self, from: d) { options = o }
        if let f = defaults.string(forKey: "aureon.rip.format"), let fm = RipFormat(rawValue: f) { format = fm }
        if let p = defaults.string(forKey: "aureon.rip.destination") { destination = URL(fileURLWithPath: p) }
    }

    private func save() {
        guard ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil, ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil else { return }
        if let d = try? JSONEncoder().encode(options) { defaults.set(d, forKey: "aureon.rip.options") }
        defaults.set(format.rawValue, forKey: "aureon.rip.format"); defaults.set(destination.path, forKey: "aureon.rip.destination")
    }

    // MARK: finding a disc

    func scan() {
        guard phase != .ripping else { return }
        Task.detached(priority: .userInitiated) {
            let found = DiscScanner.scan().filter(\.isAudio)
            await MainActor.run {
                self.discs = found
                if let t = self.toc, self.source is IOKitDiscSource, !found.contains(where: { $0.toc == t }) { self.reset() }       // the disc was taken out
                if self.toc == nil, let first = found.first { self.use(first) }
            }
        }
    }

    func reset() { toc = nil; source = nil; releases = []; selectedRelease = nil; tracks = [:]; meta = RipMetadata(); arPressings = nil; arState = "Not checked"; phase = .idle; message = nil; error = nil; driveName = "" }

    func use(_ disc: DiscInfo) {
        reset()
        do {
            let s = try IOKitDiscSource(disc: disc)
            if let off = defaults.object(forKey: "aureon.rip.offset.\(disc.driveName)") as? Int { options.readOffset = off }
            attach(s)
        } catch {
            self.toc = disc.toc; self.driveName = disc.driveName
            self.error = "Aureon could not open the disc for raw reading (\(error)). Check that nothing else (a ripping or burning app) is using the drive, then rescan."
        }
    }

    func openImage(_ cue: URL) {
        reset()
        do { attach(try DiscImageSource.image(cue: cue)) } catch { self.error = "Could not read the disc image: \(error)" }
    }

    /// Takes any sector source (a drive, an image, a test disc) as the disc to rip.
    func attach(_ s: CDSource) {
        source = s; toc = s.toc; driveName = s.name; supportsC2 = s.supportsC2
        tracks = Dictionary(uniqueKeysWithValues: s.toc.audioTracks.map { ($0.number, TrackState()) })
        meta = RipMetadata(); meta.albumArtist = "Unknown artist"; meta.album = "Unknown album"; meta.discID = s.toc.musicBrainzDiscID
        for t in s.toc.audioTracks { meta.tracks[t.number] = .init(title: String(format: "Track %02d", t.number), artist: "") }
        lookUp()
    }

    func setOffset(_ n: Int) {
        options.readOffset = n
        defaults.set(n, forKey: "aureon.rip.offset.\(driveName)")
    }

    // MARK: metadata and AccurateRip

    func lookUp() {
        guard let toc else { return }
        lookingUp = true; arState = "Checking AccurateRip…"
        let mb = musicBrainz, ar = accurateRip
        Task {
            let rel = (try? await mb.discReleases(for: toc)) ?? []
            var pressings: [ARPressing]?, reached = true
            do { pressings = try await ar.lookup(toc) } catch { reached = false }
            await MainActor.run {
                self.lookingUp = false
                self.releases = rel
                if let first = rel.first, self.meta.album == "Unknown album" { self.choose(first.id) }
                self.arPressings = pressings
                self.arState = !reached ? "AccurateRip could not be reached" : (pressings == nil ? "This disc is not in the AccurateRip database yet" : "\(pressings!.count) pressing\(pressings!.count == 1 ? "" : "s") in AccurateRip")
            }
        }
    }

    func choose(_ id: String) {
        guard let r = releases.first(where: { $0.id == id }), let toc else { return }
        selectedRelease = id
        meta = r.metadata(discID: toc.musicBrainzDiscID)
        if meta.tracks.isEmpty { for t in toc.audioTracks { meta.tracks[t.number] = .init(title: String(format: "Track %02d", t.number), artist: "") } }
        if r.hasFrontCover { Task { let c = await CoverArt.front(releaseID: id, http: http); await MainActor.run { if self.selectedRelease == id { self.meta.cover = c } } } }
    }

    // MARK: ripping

    var enabledTracks: [CDTrack] { (toc?.audioTracks ?? []).filter { tracks[$0.number]?.enabled ?? false } }

    func start() {
        guard let source, let toc, phase != .ripping, !enabledTracks.isEmpty else { return }
        phase = .ripping; error = nil; message = nil; logURL = nil
        for n in tracks.keys { tracks[n]?.progress = 0; tracks[n]?.done = false; tracks[n]?.report = nil; tracks[n]?.fileName = nil }
        cancelFlag.value = false
        let opts = options, fmt = format, metaSnap = meta, todo = enabledTracks, pressings = arPressings, flag = cancelFlag
        let folder = destination.appendingPathComponent(RipOutput.safeName(metaSnap.albumArtist), isDirectory: true).appendingPathComponent(RipOutput.safeName(metaSnap.album), isDirectory: true)
        let drive = driveName
        outputFolder = folder
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let ripper = DiscRipper(source: source, options: opts)
                var reports: [TrackRipReport] = [], files: [Int: String] = [:]
                for t in todo {
                    if flag.value { throw CancellationError() }
                    var ripped = try ripper.ripTrack(t, progress: { p in Task { @MainActor in self?.tracks[t.number]?.progress = p } }, cancelled: { flag.value })
                    ripped.report.accurateRip = pressings.map { AccurateRip.verify(track: t.number, checksums: ripped.report.checksums, in: $0) }
                    let verdict = ripped.report.accurateRip?.summary
                    let name = RipOutput.fileName(track: t.number, meta: metaSnap, format: fmt)
                    try RipOutput.write(ripped, to: folder.appendingPathComponent(name), format: fmt, meta: metaSnap, trackCount: toc.audioTracks.count, comment: verdict.map { "AccurateRip: \($0)" })
                    reports.append(ripped.report); files[t.number] = name
                    let snapshot = ripped.report
                    await MainActor.run { self?.tracks[t.number]?.done = true; self?.tracks[t.number]?.progress = 1; self?.tracks[t.number]?.report = snapshot; self?.tracks[t.number]?.fileName = name }
                }
                try RipOutput.cueSheet(toc: toc, meta: metaSnap, files: files).write(to: folder.appendingPathComponent(RipOutput.safeName(metaSnap.album) + ".cue"), atomically: true, encoding: .utf8)
                let logText = RipOutput.log(toc: toc, drive: drive, options: opts, meta: metaSnap, reports: reports)
                let logFile = folder.appendingPathComponent(RipOutput.safeName(metaSnap.album) + ".log")
                try logText.write(to: logFile, atomically: true, encoding: .utf8)
                if let c = metaSnap.cover { try? c.write(to: folder.appendingPathComponent("cover.jpg")) }
                let ok = reports.filter { $0.accurateRip?.kind == .accurate }.count, bad = reports.filter { !$0.unresolvedSectors.isEmpty }.count
                await MainActor.run {
                    self?.phase = .finished; self?.logURL = logFile
                    self?.message = "Ripped \(reports.count) track\(reports.count == 1 ? "" : "s"): \(ok) accurate according to AccurateRip" + (bad > 0 ? ", \(bad) with sectors that could not be read reliably (see the log)" : "")
                    self?.onFinished?(folder)
                }
            } catch is CancellationError {
                await MainActor.run { self?.phase = .idle; self?.message = "Cancelled" }
            } catch {
                await MainActor.run { self?.phase = .idle; self?.error = "Ripping stopped: \(error)" }
            }
        }
    }

    func cancel() { cancelFlag.value = true }
}

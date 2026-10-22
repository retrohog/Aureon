import SwiftUI
import AppKit

@MainActor
final class ConvertModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        enum State: Equatable { case waiting, working, done, failed(String), cancelled }
        let id = UUID()
        var job: TranscodeJob
        var progress = 0.0
        var state = State.waiting
        var result: TranscodeResult?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var running = false
    @Published private(set) var summary: String?
    @Published var format = TranscodeFormat.aac { didSet { save(); refreshDestinations() } }
    @Published var levelling = Levelling.off { didSet { save() } }
    @Published var customLUFS = -16.0 { didSet { save() } }
    @Published var ceiling = -1.0 { didSet { save() } }
    @Published var allowBoost = true { didSet { save() } }
    @Published var bitrate = 256_000 { didSet { save() } }
    @Published var keepFolders = true { didSet { save(); refreshDestinations() } }
    @Published var capRate = false { didSet { save() } }
    @Published var destination: URL { didSet { save(); refreshDestinations() } }
    private var base: URL?
    private var cancelFlag = RipModel.Atomic2()

    enum Levelling: String, CaseIterable, Identifiable {
        case off, streaming, apple, broadcast, custom
        var id: String { rawValue }
        var title: String { switch self { case .off: "Off (keep levels)"; case .streaming: "−14 LUFS · streaming"; case .apple: "−16 LUFS · Apple Music"; case .broadcast: "−23 LUFS · EBU R128 broadcast"; case .custom: "Custom" } }
        var lufs: Double? { switch self { case .off: nil; case .streaming: -14; case .apple: -16; case .broadcast: -23; case .custom: nil } }
    }

    init() {
        destination = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Converted", isDirectory: true)
        let d = UserDefaults.standard
        if let f = d.string(forKey: "aureon.convert.format"), let v = TranscodeFormat(rawValue: f) { format = v }
        if let l = d.string(forKey: "aureon.convert.levelling"), let v = Levelling(rawValue: l) { levelling = v }
        if d.object(forKey: "aureon.convert.lufs") != nil { customLUFS = d.double(forKey: "aureon.convert.lufs") }
        if d.object(forKey: "aureon.convert.ceiling") != nil { ceiling = d.double(forKey: "aureon.convert.ceiling") }
        if d.object(forKey: "aureon.convert.boost") != nil { allowBoost = d.bool(forKey: "aureon.convert.boost") }
        if d.object(forKey: "aureon.convert.bitrate") != nil { bitrate = d.integer(forKey: "aureon.convert.bitrate") }
        if d.object(forKey: "aureon.convert.keepFolders") != nil { keepFolders = d.bool(forKey: "aureon.convert.keepFolders") }
        if let p = d.string(forKey: "aureon.convert.destination") { destination = URL(fileURLWithPath: p) }
    }

    private func save() {
        guard ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil else { return }
        let d = UserDefaults.standard
        d.set(format.rawValue, forKey: "aureon.convert.format"); d.set(levelling.rawValue, forKey: "aureon.convert.levelling"); d.set(customLUFS, forKey: "aureon.convert.lufs")
        d.set(ceiling, forKey: "aureon.convert.ceiling"); d.set(allowBoost, forKey: "aureon.convert.boost"); d.set(bitrate, forKey: "aureon.convert.bitrate")
        d.set(keepFolders, forKey: "aureon.convert.keepFolders"); d.set(destination.path, forKey: "aureon.convert.destination")
    }

    var options: TranscodeOptions {
        var o = TranscodeOptions(format: format)
        o.bitrate = bitrate
        if let l = levelling == .custom ? customLUFS : levelling.lufs { o.normalize = LoudnessTarget(lufs: l, truePeakCeilingDB: ceiling, allowBoost: allowBoost) }
        if capRate { o.maxSampleRate = 48_000 }
        return o
    }

    // MARK: the list

    func add(_ urls: [URL]) {
        guard !running else { return }
        let files = Transcoder.expand(urls)
        let known = Set(items.map(\.job.source.path))
        if base == nil, let first = urls.first { base = first.hasDirectoryPath ? first : first.deletingLastPathComponent() }
        for f in files where !known.contains(f.path) { items.append(Item(job: TranscodeJob(source: f, destination: f))) }
        refreshDestinations()
        summary = files.isEmpty ? "Nothing playable was found in what you dropped." : nil
    }

    func clear() { guard !running else { return }; items = []; base = nil; summary = nil }
    func remove(_ id: UUID) { guard !running else { return }; items.removeAll { $0.id == id }; refreshDestinations() }

    private func refreshDestinations() {
        guard !running else { return }
        var taken = Set<String>()
        for i in items.indices {
            let d = Transcoder.destination(for: items[i].job.source, in: destination, format: format, relativeTo: keepFolders ? base : nil, taken: taken)
            items[i].job.destination = d; taken.insert(d.path)
            if items[i].state != .waiting { items[i].state = .waiting; items[i].progress = 0; items[i].result = nil }
        }
    }

    // MARK: running

    func start() {
        guard !running, !items.isEmpty else { return }
        running = true; summary = nil; cancelFlag.value = false
        for i in items.indices { items[i].state = .waiting; items[i].progress = 0; items[i].result = nil }
        let jobs = items.map(\.job), ids = items.map(\.id), opts = options, flag = cancelFlag
        Task.detached(priority: .utility) { [weak self] in
            let t0 = Date()
            let results = Transcoder.run(jobs: jobs, options: opts, progress: { i, p in
                Task { @MainActor in self?.update(ids[i]) { $0.progress = p; if $0.state == .waiting { $0.state = .working } } }
            }, finished: { i, r in
                Task { @MainActor in self?.update(ids[i]) { it in
                    it.result = r; it.progress = r.ok ? 1 : it.progress
                    switch r.outcome { case .done: it.state = .done; case .cancelled: it.state = .cancelled; case .failed(let m): it.state = .failed(m) }
                } }
            }, cancelled: { flag.value })
            let took = Date().timeIntervalSince(t0)
            await MainActor.run {
                guard let self else { return }
                self.running = false
                let ok = results.filter(\.ok).count, bad = results.filter { if case .failed = $0.outcome { return true }; return false }.count
                let bytes = results.reduce(0) { $0 + $1.outputBytes }
                self.summary = flag.value ? "Stopped: \(ok) of \(results.count) converted." : "Converted \(ok) of \(results.count) in \(fmtDuration(took)), \(formatBytes(bytes))" + (bad > 0 ? "; \(bad) failed (hover a row for the reason)." : ".")
            }
        }
    }

    private func update(_ id: UUID, _ f: (inout Item) -> Void) { if let i = items.firstIndex(where: { $0.id == id }) { f(&items[i]) } }
    func cancel() { cancelFlag.value = true }
    func reveal() { if let f = items.first(where: { $0.state == .done }) { NSWorkspace.shared.activateFileViewerSelecting([f.job.destination]) } }
}

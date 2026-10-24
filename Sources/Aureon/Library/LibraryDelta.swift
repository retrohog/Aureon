import Foundation
import CoreServices

// Keeping the library current without scanning it: FSEvents tells us which files and folders changed (also while the app was closed, by
// replaying the history since the last event we handled), and only those are compared with what the library knows.

// MARK: - Reading one file

enum LibraryIngest {
    /// Modification time and size, the pair the library compares to decide whether a file changed.
    static func stamp(of url: URL) -> (mtime: Double, size: Int64) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (v?.contentModificationDate?.timeIntervalSince1970 ?? 0, Int64(v?.fileSize ?? 0))
    }

    /// The stream facts and tags of an audio file (the audio itself is never decoded).
    static func record(url: URL, mtime: Double, size: Int64) throws -> (facts: FileFacts, tags: TrackMetadata) {
        var facts = FileFacts(path: url.path, mtime: mtime, size: size)
        guard let f = try? LosslessFile(path: url.path) else { throw AureonError.message("unreadable audio") }
        facts.duration = f.info.duration; facts.sampleRate = f.info.sampleRate; facts.bitDepth = f.info.sourceBits; facts.channels = f.info.channels; facts.codec = f.info.codec
        return (facts, TagInterpreter.interpret(TagReader.read(path: url.path), fileName: url.lastPathComponent))
    }

    static func isAudio(_ path: String) -> Bool { LibraryStore.audioExtensions.contains((path as NSString).pathExtension.lowercased()) }
}

// MARK: - Applying a batch of changes

/// What happened under one library folder, as the watcher reports it.
struct LibraryChangeBatch: Sendable, Equatable {
    var root: String
    /// Files and folders named by an event.
    var paths = Set<String>()
    /// Folders whose events were merged or dropped: everything below them has to be looked at.
    var rescan = Set<String>()
    /// The history cannot be trusted (event ids wrapped, the folder was moved or its volume unmounted): compare the whole folder.
    var reconcileRoot = false
    /// The newest event id covered by this batch; stored once the batch has been applied.
    var eventID: UInt64 = 0
    var isEmpty: Bool { paths.isEmpty && rescan.isEmpty && !reconcileRoot }
}

enum LibraryDelta {
    /// Brings the library in line with a batch. Cost is proportional to what changed: a changed file is one stat and one lookup, a changed
    /// folder is a walk of that folder only, and nothing else is touched.
    static func apply(_ batch: LibraryChangeBatch, to store: LibraryStore) -> ImportReport {
        var report = ImportReport()
        let fm = FileManager.default
        let root = batch.root
        guard fm.fileExists(atPath: root) else { report.errors.append("\(root) is not available"); return report }       // an unplugged drive loses nothing
        if batch.reconcileRoot { return store.importFolder(URL(fileURLWithPath: root)) }

        var files = Set<String>(), folders: [String] = [], goneFiles: [String] = [], goneFolders: [String] = []
        for p in batch.paths.union(batch.rescan) where inside(p, root) && !hidden(p, root) {
            var st = stat()
            if lstat(p, &st) != 0 {
                if LibraryIngest.isAudio(p) { goneFiles.append(p) } else { goneFolders.append(p) }
            } else if st.st_mode & S_IFMT == S_IFDIR {
                folders.append(p)
            } else if st.st_mode & S_IFMT == S_IFREG, LibraryIngest.isAudio(p) {
                files.insert(p)
            }
        }
        // folders are walked once: drop those inside another one that is walked anyway, and files inside them
        folders = Array(Set(folders)).sorted()
        var walked: [String] = []
        for f in folders where !walked.contains(where: { f == $0 || f.hasPrefix($0 + "/") }) { walked.append(f) }
        files = files.filter { f in !walked.contains { f.hasPrefix($0 + "/") } }

        for f in walked { merge(&report, store.importFolder(URL(fileURLWithPath: f))) }
        for f in goneFolders where !walked.contains(where: { f.hasPrefix($0 + "/") }) { report.removed += store.removeTracks(under: f, keeping: []) }
        if !goneFiles.isEmpty { report.removed += store.removeTracks(paths: goneFiles) }

        let known = store.knownFiles(paths: Array(files))
        var batchRows: [(facts: FileFacts, tags: TrackMetadata)] = []
        for p in files.sorted() {
            report.scanned += 1
            let url = URL(fileURLWithPath: p), (mtime, size) = LibraryIngest.stamp(of: url)
            if let k = known[p], k.mtime == mtime, k.size == size { report.skipped += 1; continue }
            do { batchRows.append(try LibraryIngest.record(url: url, mtime: mtime, size: size)) }
            catch { report.failed += 1; report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            if batchRows.count >= 200 { let r = store.upsert(batchRows); report.added += r.added; report.updated += r.updated; batchRows = [] }
        }
        if !batchRows.isEmpty { let r = store.upsert(batchRows); report.added += r.added; report.updated += r.updated }
        return report
    }

    private static func merge(_ a: inout ImportReport, _ b: ImportReport) {
        a.scanned += b.scanned; a.added += b.added; a.updated += b.updated; a.skipped += b.skipped; a.removed += b.removed; a.failed += b.failed; a.errors += b.errors
    }

    private static func inside(_ p: String, _ root: String) -> Bool { p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/") }

    /// Hidden files and folders are never imported, so their events mean nothing.
    private static func hidden(_ p: String, _ root: String) -> Bool {
        guard p.count > root.count else { return false }
        return p.dropFirst(root.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

// MARK: - FSEvents with a memory

/// Watches library folders with FSEvents and remembers, per folder, the last event it handled. On the next launch the stream resumes from
/// that event, so changes made while Aureon was closed arrive as ordinary events and nothing has to be scanned to find them.
///
/// A folder is compared in full only when the history cannot be trusted: the first time it is watched, when its volume was replaced
/// (the volume UUID changed), or when the last full comparison is old (`reconcileInterval`; the system keeps only a limited history).
final class LibraryWatcher: @unchecked Sendable {
    struct State: Codable, Equatable {
        var eventID: UInt64
        var volume: String?
        var reconciledAt: Double
    }
    enum Start: Equatable {
        /// The stream continues from the stored event id.
        case replaying(from: UInt64)
        /// There is no usable history: compare the folder, then call `markReconciled` with this id (changes made meanwhile arrive as events).
        case needsReconcile(since: UInt64)
    }

    static let reconcileInterval: TimeInterval = 14 * 24 * 3600

    static var defaultStateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/LibraryWatch.json")
    }

    /// Called on the watcher's queue; hand the work to another queue and call `commit` when it is done.
    var onBatch: (@Sendable (LibraryChangeBatch) -> Void)?
    /// The stored history has been replayed (called once per `start`, on the watcher's queue).
    var onCaughtUp: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "aureon.librarywatch", qos: .utility)
    private let stateURL: URL?
    private let settle: TimeInterval
    private var states: [String: State] = [:]
    private var streams: [String: Feed] = [:]

    /// `settle` is how long events are collected before they are reported (a copy of an album is dozens of events).
    init(stateURL: URL? = LibraryWatcher.defaultStateURL, settle: TimeInterval = 1.5) {
        self.stateURL = stateURL; self.settle = settle
        if let u = stateURL, let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode([String: State].self, from: d) { states = s }
    }
    deinit { stopAll() }

    // MARK: control

    func start(root: String) -> Start {
        queue.sync {
            stopLocked(root)
            if let st = states[root], let vol = Self.volumeID(root), st.volume == vol, FileManager.default.fileExists(atPath: root),
               let s = makeStream(root: root, since: FSEventStreamEventId(st.eventID), replaying: true) {
                streams[root] = s
                return .replaying(from: st.eventID)
            }
            return .needsReconcile(since: beginLocked(root))
        }
    }

    /// Starts (or restarts) watching from now and returns the event id to hand to `markReconciled` once the folder has been compared.
    func beginReconcile(root: String) -> UInt64 { queue.sync { stopLocked(root); return beginLocked(root) } }

    func markReconciled(root: String, eventID: UInt64) {
        queue.sync {
            let prior = states[root]
            states[root] = State(eventID: max(prior?.eventID ?? 0, eventID), volume: Self.volumeID(root), reconciledAt: Date().timeIntervalSince1970)
            persistLocked()
        }
    }

    /// Records that everything up to `eventID` has been applied.
    func commit(root: String, eventID: UInt64) { queue.sync { commitLocked(root, eventID) } }

    func state(of root: String) -> State? { queue.sync { states[root] } }

    /// Whether the last full comparison is old enough that the history alone is no longer trusted.
    func needsSweep(root: String, now: Date = Date()) -> Bool {
        guard let st = state(of: root) else { return true }
        return now.timeIntervalSince1970 - st.reconciledAt > Self.reconcileInterval
    }

    /// Stops watching a folder that is no longer part of the library and drops what was remembered about it (adding it again starts from a full comparison).
    func forget(root: String) {
        queue.sync {
            stopLocked(root)
            guard states.removeValue(forKey: root) != nil else { return }
            persistLocked()
        }
    }

    func stop(root: String) { queue.sync { stopLocked(root) } }
    func stopAll() { queue.sync { for r in Array(streams.keys) { stopLocked(r) } } }

    var watchedRoots: [String] { queue.sync { Array(streams.keys).sorted() } }

    // MARK: internals (on `queue`)

    private func beginLocked(_ root: String) -> UInt64 {
        let now = FSEventsGetCurrentEventId()
        if let s = makeStream(root: root, since: now, replaying: false) { streams[root] = s }
        return now
    }

    private func commitLocked(_ root: String, _ id: UInt64) {
        guard id > 0, var st = states[root], id > st.eventID else { return }
        st.eventID = id; states[root] = st; persistLocked()
    }

    private func persistLocked() {
        guard let u = stateURL, let d = try? JSONEncoder().encode(states) else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: u, options: .atomic)
    }

    private func stopLocked(_ root: String) {
        guard let s = streams.removeValue(forKey: root) else { return }
        s.shutdown()
    }

    private static func volumeID(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let u = FSEventsCopyUUIDForDevice(st.st_dev), let s = CFUUIDCreateString(nil, u) else { return nil }
        return s as String
    }

    private func makeStream(root: String, since: FSEventStreamEventId, replaying: Bool) -> Feed? {
        let s = Feed(root: root, owner: self, queue: queue, replaying: replaying)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(s).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, pathsPtr, flagsPtr, idsPtr in
            guard let info else { return }
            let stream = Unmanaged<Feed>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(pathsPtr).takeUnretainedValue()
            var paths: [String] = [], flags: [UInt32] = [], ids: [UInt64] = []
            for i in 0..<count {
                guard let v = CFArrayGetValueAtIndex(array, i) else { continue }
                paths.append(Unmanaged<CFString>.fromOpaque(v).takeUnretainedValue() as String); flags.append(flagsPtr[i]); ids.append(idsPtr[i])
            }
            stream.ingest(paths, flags, ids)
        }
        let create = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let ref = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [root] as CFArray, since, 0.4, create) else { return nil }
        FSEventStreamSetDispatchQueue(ref, queue)
        guard FSEventStreamStart(ref) else { FSEventStreamInvalidate(ref); FSEventStreamRelease(ref); return nil }
        s.ref = ref
        return s
    }

    /// One watched folder: collects events and reports them in batches.
    private final class Feed {
        let root: String
        unowned let owner: LibraryWatcher
        let queue: DispatchQueue
        var ref: FSEventStreamRef?
        var replaying: Bool
        var pending: LibraryChangeBatch
        var work: DispatchWorkItem?
        var firstPending: DispatchTime?
        var closed = false

        init(root: String, owner: LibraryWatcher, queue: DispatchQueue, replaying: Bool) {
            self.root = root; self.owner = owner; self.queue = queue; self.replaying = replaying; pending = LibraryChangeBatch(root: root)
        }

        func shutdown() {
            closed = true; work?.cancel(); work = nil
            if let r = ref { FSEventStreamStop(r); FSEventStreamInvalidate(r); FSEventStreamRelease(r); ref = nil }
        }

        func ingest(_ paths: [String], _ flags: [UInt32], _ ids: [UInt64]) {
            guard !closed else { return }
            var caughtUp = false
            for i in paths.indices {
                let f = flags[i]
                var p = paths[i]
                if p.count > 1, p.hasSuffix("/") { p.removeLast() }
                pending.eventID = max(pending.eventID, ids[i])
                if f & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { caughtUp = true; continue }
                if f & UInt32(kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount) != 0 { pending.reconcileRoot = true; continue }
                if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMount) != 0 { pending.rescan.insert(p); continue }
                if f & UInt32(kFSEventStreamEventFlagItemIsSymlink) != 0 { continue }
                if f & UInt32(kFSEventStreamEventFlagItemIsFile) != 0, !LibraryIngest.isAudio(p) { continue }        // covers, cue sheets, .DS_Store
                pending.paths.insert(p)
            }
            if firstPending == nil { firstPending = .now() }
            if caughtUp, replaying {
                replaying = false
                schedule(after: 0)
                owner.onCaughtUp?(root)
            } else { schedule(after: owner.settle) }
        }

        private func schedule(after delay: TimeInterval) {
            work?.cancel()
            // a long copy keeps producing events: report at least every ten seconds
            let overdue = firstPending.map { DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds > 10_000_000_000 } ?? false
            let item = DispatchWorkItem { [weak self] in self?.flush() }
            work = item
            queue.asyncAfter(deadline: .now() + (overdue ? 0 : delay), execute: item)
        }

        private func flush() {
            guard !closed else { return }
            let batch = pending
            pending = LibraryChangeBatch(root: root); firstPending = nil; work = nil
            if batch.isEmpty { owner.commitLocked(root, batch.eventID); return }          // only events that mean nothing to the library
            owner.onBatch?(batch)
        }
    }
}

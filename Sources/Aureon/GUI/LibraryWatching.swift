import SwiftUI
import CoreServices

// The library stays current without being scanned: see LibraryWatcher (FSEvents, resumed from the last event handled) and LibraryDelta.

extension LibraryModel {
    private static let deltaQueue = DispatchQueue(label: "aureon.librarydelta", qos: .utility)

    /// Watching is off in tests and snapshots (they use throw-away libraries and must not touch the user's folders or saved watch state).
    static var watchingAllowed: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["AUREON_SNAPSHOT"] == nil && e["AUREON_TESTING"] == nil
    }

    /// Creates the watcher on first use.
    @discardableResult
    func ensureWatcher(stateURL: URL? = LibraryWatcher.defaultStateURL, settle: TimeInterval = 1.5) -> LibraryWatcher? {
        if let w = watcher { return w }
        guard let store else { return nil }
        let w = LibraryWatcher(stateURL: stateURL, settle: settle)
        w.onBatch = { [weak self, weak w] batch in
            Self.deltaQueue.async {
                let report = LibraryDelta.apply(batch, to: store)
                w?.commit(root: batch.root, eventID: batch.eventID)
                if batch.reconcileRoot { w?.markReconciled(root: batch.root, eventID: batch.eventID) }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.deltaApplied(report) } }
            }
        }
        watcher = w
        return w
    }

    /// Resumes watching every library folder. A folder whose history is intact costs nothing here: the stream replays what changed while the app was
    /// closed, and only those files are looked at. A folder watched for the first time (or whose history cannot be trusted) is compared once.
    func startWatching() {
        guard Self.watchingAllowed, let w = ensureWatcher(), let store else { return }
        for root in folders.map({ realPath(URL(fileURLWithPath: $0)).path }) {
            Self.deltaQueue.async { [weak self] in
                switch w.start(root: root) {
                case .replaying:
                    guard w.needsSweep(root: root) else { return }
                    let id = FSEventsGetCurrentEventId()
                    let report = store.importFolder(URL(fileURLWithPath: root))
                    w.markReconciled(root: root, eventID: id)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.deltaApplied(report) } }
                case .needsReconcile(let id):
                    let report = store.importFolder(URL(fileURLWithPath: root))
                    w.markReconciled(root: root, eventID: id)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.deltaApplied(report) } }
                }
            }
        }
    }

    func stopWatching() { watcher?.stopAll() }

    /// A background update finished: refresh what is on screen only if something changed.
    func deltaApplied(_ r: ImportReport) {
        guard r.added + r.updated + r.removed > 0 else { return }
        importProgress = "\(r.added) added, \(r.updated) updated, \(r.removed) removed"
        refresh()
        if r.added > 0 { scanDuplicates(prompt: true) }
        onLibraryChanged?()
    }
}

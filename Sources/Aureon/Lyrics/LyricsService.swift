import Foundation
import SwiftUI

/// Finds lyrics for the song that is playing and holds them for the Now Playing page.
///
/// Where it looks, in order, stopping at the first synced result:
///   1. an .lrc file next to the song, then the file's own tags (`LocalLyrics`)
///   2. what was found or made before (`LyricsStore`)
///   3. LRCLIB on the internet, if "Look up lyrics online" is on and Aureon is not offline
///   4. nothing: the page says so
/// Plain (untimed) lyrics found on the way are shown at once while a synced version is looked for.
///
/// All reading, network and audio work runs off the main thread; this object only publishes the outcome.
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    enum Phase: Equatable {
        case idle
        case loading(String)
        case ready
        case instrumental
        case missing
        case failed(String)
    }

    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var phase = Phase.idle {
        didSet { if phase != oldValue { LyricsDebug.log("phase \(oldValue) -> \(phase) for \(request?.title ?? "nil")") } }
    }
    @Published private(set) var request: LyricsRequest?
    /// What happened to the last "save" request, for the page.
    @Published private(set) var saveNote: String?
    /// Plain lyrics are showing while a synced version is looked for.
    @Published private(set) var upgrading = false
    /// The online lookup could not reach the service (as opposed to the song not being in it).
    @Published private(set) var onlineUnreachable = false

    @Published var onlineLookup: Bool {
        didSet {
            defaults.set(onlineLookup, forKey: Self.onlineKey)
            if onlineLookup && !oldValue, case .missing = phase, let r = request { reload(r) }
        }
    }

    static let onlineKey = "aureon.lyrics.online"

    // Everything the outside world provides, replaceable in tests.
    var isOnlineAllowed: () -> Bool = { ProcessInfo.processInfo.environment["AUREON_OFFLINE"] == nil }
    var online = LRCLIBClient()
    var store = LyricsStore.shared
    var writeTags: @Sendable (String, String) throws -> Void = { try TagEditing.write(path: $0, edits: [.lyrics: $1]) }
    var saveRetryDelay: TimeInterval = 3
    var findLocal: @Sendable (LyricsRequest) -> LocalLyricsResult = { LocalLyrics.find($0) }

    private let defaults: UserDefaults
    private var epoch = 0
    private var work: Task<Void, Never>?
    private var pendingTagWrite: (path: String, text: String, tries: Int)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onlineLookup = defaults.object(forKey: Self.onlineKey) as? Bool ?? true
    }


    // MARK: asking

    /// Starts looking for the lyrics of `r` (nil: nothing is playing, or it is a stream). Asking again for the same song does nothing.
    func show(_ r: LyricsRequest?) {
        if let r, let cur = request, cur.path == r.path, cur.title == r.title, cur.artist == r.artist {
            // the same song: a different length (it arrived late) only matters when nothing synced has been found yet
            if abs(cur.duration - r.duration) < 1.5 || (phase == .ready && lyrics?.synced == true) { return }
        }
        if let p = pendingTagWrite, p.path != r?.path { retryTagWrite() }
        cancelWork()
        epoch += 1
        request = r
        saveNote = nil
        lyrics = nil; upgrading = false; onlineUnreachable = false
        guard let r, !r.title.isEmpty || r.isLocalFile else { phase = .idle; return }
        phase = .loading("Looking for lyrics")
        let my = epoch
        work = Task { await self.resolve(r, epoch: my) }
    }

    /// Looks again, past any "not found" that was remembered.
    func reload(_ r: LyricsRequest? = nil) {
        guard let r = r ?? request else { return }
        store.remove(r.cacheKey)
        request = nil
        show(r)
    }

    private func publish(_ l: Lyrics, epoch my: Int) {
        guard epoch == my else { return }
        lyrics = l; phase = .ready
    }

    private func resolve(_ r: LyricsRequest, epoch my: Int) async {
        let key = r.cacheKey
        // 1. files
        let finder = findLocal
        let local = await Task.detached(priority: .userInitiated) { finder(r) }.value
        guard epoch == my else { return }
        if let s = local.synced { publish(s, epoch: my); return }
        if let p = local.plain { publish(p, epoch: my) }

        // 2. what was kept
        var skipOnline = false
        if let e = store.entry(key) {
            switch e.kind {
            case .found:
                if let l = e.lyrics, l.synced || local.plain == nil { publish(l, epoch: my); if l.synced { return } }
            case .instrumental:
                if local.plain == nil { phase = .instrumental; return }
            case .miss: skipOnline = true
            case .declined: break
            }
        }

        // 3. the internet
        if !skipOnline, onlineLookup, isOnlineAllowed(), !r.title.isEmpty {
            upgrading = local.plain != nil || lyrics != nil
            if lyrics == nil { phase = .loading("Looking online") }
            do {
                let found = try await online.lookup(r)
                guard epoch == my else { return }
                upgrading = false
                if let f = found {
                    if let text = f.synced, let l = LRCParser.parse(text, origin: .online, source: "LRCLIB"), l.synced {
                        store.store(l, key: key); publish(l, epoch: my); return
                    }
                    if let text = f.plain, lyrics == nil, let l = LRCParser.parse(text, origin: .online, source: "LRCLIB") {
                        store.store(l, key: key); publish(l, epoch: my)
                    } else if f.instrumental, lyrics == nil {
                        store.storeInstrumental(key: key); phase = .instrumental; return
                    }
                } else if lyrics == nil {
                    store.storeMiss(key: key)
                }
            } catch is CancellationError {
                return
            } catch {
                guard epoch == my else { return }
                upgrading = false; onlineUnreachable = true          // nothing is remembered: the next play tries again
            }
        }
        guard epoch == my else { return }
        if lyrics == nil {
            phase = .missing
        }
    }

    private func cancelWork() { work?.cancel(); work = nil }

    // MARK: keeping the result

    /// Writes the lyrics into the song's tags (FLAC, M4A/ALAC, MP3). While the song is playing the file is in use and cannot be replaced: the write
    /// waits for the song to end, and is tried again a few times.
    func saveToTags() {
        guard let r = request, let l = lyrics, r.isLocalFile else { return }
        guard TagEditing.isEditable(r.path) else { saveNote = "Tags of this file type cannot be changed here. Save an .lrc file next to it instead."; return }
        pendingTagWrite = (r.path, l.lrc(), 0)
        attemptTagWrite()
    }

    private func attemptTagWrite() {
        guard var p = pendingTagWrite else { return }
        let writer = writeTags
        let path = p.path, text = p.text
        Task {
            let outcome: Result<Void, Error> = await Task.detached(priority: .utility) { Result { try writer(path, text) } }.value
            // notes are for the song on the page: a write that finishes after the song changed says nothing
            let current = self.request?.path == path
            switch outcome {
            case .success:
                self.pendingTagWrite = nil
                if current { self.saveNote = "Saved in the file's tags." }
            case .failure(let e):
                if let t = e as? TagEditError, t.isBusy {
                    p.tries += 1
                    if p.tries > 6 {
                        self.pendingTagWrite = nil
                        if current { self.saveNote = "The song stayed in use, so its tags were not changed. Try again when it is not playing." }
                        return
                    }
                    self.pendingTagWrite = p
                    if current { self.saveNote = "The song is playing, so its file cannot change yet. The lyrics will be saved after it." }
                    else {
                        // the song has been left: try again shortly, until the engine lets go of the file
                        let delay = self.saveRetryDelay
                        Task { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); self.retryTagWrite() }
                    }
                } else {
                    self.pendingTagWrite = nil
                    if current { self.saveNote = e.localizedDescription }
                }
            }
        }
    }

    private func retryTagWrite() { if pendingTagWrite != nil { attemptTagWrite() } }

    /// Writes `Song.lrc` next to the song. Never replaces a file that is already there.
    func saveAsLRC() {
        guard let r = request, let l = lyrics, r.isLocalFile else { return }
        let url = URL(fileURLWithPath: r.path).deletingPathExtension().appendingPathExtension("lrc")
        guard !FileManager.default.fileExists(atPath: url.path) else { saveNote = "\(url.lastPathComponent) already exists next to the song."; return }
        do {
            try Data(l.lrc().utf8).write(to: url, options: .atomic)
            saveNote = "Saved as \(url.lastPathComponent)."
        } catch {
            saveNote = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

/// Carries a cancellation into work on another thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}


/// `AUREON_LYRICS_DEBUG=1` appends what the lyrics pipeline does to /tmp/aureon-lyrics.log (the path can be changed with the variable's value
/// when it starts with a slash). Off by default; nothing is written otherwise.
enum LyricsDebug {
    static let path: String? = {
        guard let v = ProcessInfo.processInfo.environment["AUREON_LYRICS_DEBUG"], !v.isEmpty, v != "0" else { return nil }
        return v.hasPrefix("/") ? v : "/tmp/aureon-lyrics.log"
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard let path else { return }
        let line = String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000)) + message() + "\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: URL(fileURLWithPath: path)) }
    }
}

import SwiftUI
import Combine
import Security
import SlskCore

// The Soulseek user-interface layer. The client (SlskCore) lives on its own queues and publishes a snapshot four times a second; this model turns that
// into what the pages draw, off the main thread where it is more than a copy. The player never calls into any of it.

/// One line of the results: the files one user offers from one folder.
struct SlskRow: Identifiable, Equatable {
    var id: String { user + "|" + folder }
    var user: String
    var folder: String
    var files: [SlskFileResult]
    var freeSlot: Bool
    var queueLength: Int
    var speed: Int
    var bytes: UInt64 { files.reduce(0) { $0 + $1.size } }
    /// "FLAC 24-bit 96 kHz" for the most common format in the folder.
    var format: String {
        guard let f = files.first(where: { $0.isLossless }) ?? files.first else { return "" }
        var parts = [f.ext.uppercased()]
        if let b = f.bitDepth { parts.append("\(b)-bit") }
        if let r = f.sampleRate { parts.append(String(format: r % 1000 == 0 ? "%.0f kHz" : "%.1f kHz", Double(r) / 1000)) }
        if f.bitDepth == nil, let br = f.bitrate { parts.append("\(br) kbps") }
        return parts.joined(separator: " ")
    }
}

struct SlskFilters: Equatable {
    var losslessOnly = false
    var minBitrate = 0
    var freeSlotsOnly = false
    var minBitDepth = 0
}

enum SlskRows {
    /// Groups responses by user and folder and applies the filters. Capped, so a huge search stays light; sorted by what helps most (free slot, size of the folder).
    static func build(_ responses: [SlskSearchResponse], filters: SlskFilters, cap: Int = 5000) -> [SlskRow] {
        var rows: [SlskRow] = []
        rows.reserveCapacity(min(cap, 4096))
        for r in responses {
            if filters.freeSlotsOnly && !r.freeSlot { continue }
            var byFolder: [String: [SlskFileResult]] = [:]
            var order: [String] = []
            for f in r.files {
                if filters.losslessOnly && !f.isLossless { continue }
                if filters.minBitrate > 0, !f.isLossless, (f.bitrate ?? 0) < filters.minBitrate { continue }
                if filters.minBitDepth > 0, (f.bitDepth ?? 0) < filters.minBitDepth { continue }
                let key = f.folder
                if byFolder[key] == nil { order.append(key) }
                byFolder[key, default: []].append(f)
            }
            for k in order {
                rows.append(SlskRow(user: r.user, folder: k, files: byFolder[k]!.sorted { $0.path < $1.path }, freeSlot: r.freeSlot, queueLength: Int(r.queueLength), speed: Int(r.speed)))
                if rows.count >= cap { break }
            }
            if rows.count >= cap { break }
        }
        return rows.sorted { a, b in
            if a.freeSlot != b.freeSlot { return a.freeSlot }
            if a.files.count != b.files.count { return a.files.count > b.files.count }
            return a.speed > b.speed
        }
    }
}

/// The password lives in the keychain, never in the preferences.
enum SlskKeychain {
    static let service = "Aureon Soulseek"
    static func password(for user: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: user, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    static func set(_ password: String, for user: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: user]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
final class SoulseekModel: ObservableObject {
    static let shared = SoulseekModel()
    /// Snapshots and tests keep their own throw-away preferences, so a picture never reads or changes the real settings.
    private let d: UserDefaults = ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil ? (UserDefaults(suiteName: "aureon.snapshot.soulseek") ?? .standard) : .standard

    // settings (the switch is off until the listener turns it on)
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "aureon.slsk.enabled"); if !enabled { disconnect() } } }
    @Published var username: String { didSet { d.set(username, forKey: "aureon.slsk.user") } }
    @Published var sharing: Bool { didSet { d.set(sharing, forKey: "aureon.slsk.sharing"); client?.setSharing(sharing); if sharing { scheduleShareRebuild() } } }
    @Published var sharedFolders: [String] { didSet { d.set(sharedFolders, forKey: "aureon.slsk.shared"); scheduleShareRebuild() } }
    @Published var addToLibrary: Bool { didSet { d.set(addToLibrary, forKey: "aureon.slsk.addToLibrary") } }
    @Published var pauseWhileHiRes: Bool { didSet { d.set(pauseWhileHiRes, forKey: "aureon.slsk.pauseHiRes") } }
    @Published var connectAtLaunch: Bool { didSet { d.set(connectAtLaunch, forKey: "aureon.slsk.launch") } }
    @Published var uploadLimitKB: Int { didSet { d.set(uploadLimitKB, forKey: "aureon.slsk.uploadKB"); client?.config.uploadLimit = uploadLimitKB * 1024 } }
    @Published var firstRunDone: Bool { didSet { d.set(firstRunDone, forKey: "aureon.slsk.firstRun") } }

    // what the pages draw
    @Published private(set) var snapshot = SlskSnapshot()
    @Published private(set) var rows: [SlskRow] = []
    @Published var filters = SlskFilters() { didSet { rebuildRows() } }
    @Published var query = ""
    @Published var panelOpen = false
    @Published var page: SoulseekPageID = .search
    @Published var browseUser = ""
    @Published var log: [SlskLogLine] = []
    @Published var lastError: String?
    @Published private(set) var inLibrary: Set<String> = []

    private(set) var client: SlskClient?
    private var store: SlskStore?
    private var rowTask: Task<Void, Never>?
    private var shareTask: Task<Void, Never>?
    private var lastResultCount = -1
    private weak var libraryRef: LibraryModel?
    private var importTimer: Timer?
    private var protectTimer: Timer?
    private weak var playerRef: PlayerModel?

    var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Aureon Soulseek", isDirectory: true) }
    var downloadsFolder: URL { folder.appendingPathComponent("Downloads", isDirectory: true) }
    var incompleteFolder: URL { folder.appendingPathComponent(".incomplete", isDirectory: true) }

    init() {
        enabled = d.bool(forKey: "aureon.slsk.enabled")
        username = d.string(forKey: "aureon.slsk.user") ?? ""
        sharing = d.bool(forKey: "aureon.slsk.sharing")
        sharedFolders = d.stringArray(forKey: "aureon.slsk.shared") ?? []
        addToLibrary = d.object(forKey: "aureon.slsk.addToLibrary") as? Bool ?? true
        pauseWhileHiRes = d.object(forKey: "aureon.slsk.pauseHiRes") as? Bool ?? true
        connectAtLaunch = d.bool(forKey: "aureon.slsk.launch")
        uploadLimitKB = d.object(forKey: "aureon.slsk.uploadKB") as? Int ?? 0
        firstRunDone = d.bool(forKey: "aureon.slsk.firstRun")
    }

    var state: SlskLinkState { snapshot.state }
    var isConnected: Bool { snapshot.state.isOnline }
    var badge: Int { snapshot.activeCount }
    var hasAttention: Bool { (snapshot.downloads + snapshot.uploads).contains { if case .needsAttention = $0.state { return $0.state != .needsAttention("Cancelled") }; return false } }

    /// A made-up state for pictures (`AUREON_SLSK_FIXTURE`): invented users and files, never the network.
    func loadFixture() {
        enabled = true; username = "listener"
        var s = SlskSnapshot()
        s.state = .online("Welcome"); s.listenPort = 2234; s.resultCount = 14
        func f(_ n: String, _ ext: String, bits: Int?, rate: Int?, kbps: Int? = nil, mb: Double) -> SlskFileResult {
            SlskFileResult(path: "Music\\Synth Pop\\Night Drive\\" + n + "." + ext, size: UInt64(mb * 1_048_576), ext: ext, bitrate: kbps, duration: 240, sampleRate: rate, bitDepth: bits, vbr: false)
        }
        s.results = [
            SlskSearchResponse(user: "vinyl_room", token: 1, files: ["01 Neon Coast", "02 Midnight Run", "03 Glass Hours", "04 Afterglow"].map { f($0, "flac", bits: 24, rate: 96000, mb: 78) }, freeSlot: true, speed: 4_200_000, queueLength: 0),
            SlskSearchResponse(user: "quiet_harbor", token: 1, files: ["01 Neon Coast", "02 Midnight Run", "03 Glass Hours"].map { f($0, "flac", bits: 16, rate: 44100, mb: 31) }, freeSlot: true, speed: 2_800_000, queueLength: 0),
            SlskSearchResponse(user: "tape_loop", token: 1, files: ["01 Neon Coast", "02 Midnight Run", "03 Glass Hours", "04 Afterglow", "05 Slow Light"].map { f($0, "mp3", bits: nil, rate: nil, kbps: 320, mb: 9.4) }, freeSlot: false, speed: 900_000, queueLength: 6)
        ]
        func t(_ id: Int, _ n: String, _ p: Double, _ st: SlskTransferState, _ sp: Double) -> SlskTransferInfo {
            SlskTransferInfo(id: id, kind: .download, user: "vinyl_room", path: "Music\\Synth Pop\\Night Drive\\" + n + ".flac", size: 81_788_928, done: UInt64(p * 81_788_928), state: st, speed: sp, attempts: 1)
        }
        s.downloads = [t(1, "01 Neon Coast", 1, .finished, 0), t(2, "02 Midnight Run", 0.62, .transferring, 4_300_000), t(3, "03 Glass Hours", 0.18, .transferring, 3_100_000), t(4, "04 Afterglow", 0, .queued(place: 3), 0)]
        s.downSpeed = 7_400_000
        snapshot = s; rows = SlskRows.build(s.results, filters: SlskFilters()); query = "night drive"; page = .search
    }

    /// Called once with the models the page works with. Connects at launch when the listener asked for it.
    func attach(player: PlayerModel) {
        playerRef = player; libraryRef = player.library
        if ProcessInfo.processInfo.environment["AUREON_SLSK_FIXTURE"] != nil { loadFixture(); return }
        if enabled, connectAtLaunch, !username.isEmpty { connect() }
        protectTimer?.invalidate()
        protectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.protectPlayback() } }
    }

    // MARK: connection

    func connect(password: String? = nil) {
        guard enabled, !username.isEmpty else { lastError = "Enter a username first"; return }
        if let password { SlskKeychain.set(password, for: username) }
        let pw = password ?? SlskKeychain.password(for: username)
        guard !pw.isEmpty else { lastError = "Enter your password"; return }
        lastError = nil
        let c = ensureClient()
        c.config.username = username; c.config.password = pw
        c.connect()
    }

    func disconnect() { client?.disconnect(); client?.pauseAll(false) }

    private func ensureClient() -> SlskClient {
        if let client { return client }
        try? FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: incompleteFolder, withIntermediateDirectories: true)
        // the incomplete folder is hidden from Finder and never inside the library
        var u = incompleteFolder; var rv = URLResourceValues(); rv.isHidden = true; try? u.setResourceValues(rv)
        var cfg = SlskConfig(downloadsDir: downloadsFolder, incompleteDir: incompleteFolder)
        cfg.sharing = sharing; cfg.uploadLimit = uploadLimitKB * 1024
        cfg.verifyFile = { url in
            // the file must be readable as audio before it is moved into place
            let probe = url.deletingPathExtension().lastPathComponent
            _ = probe
            return (try? FileHandle(forReadingFrom: url)).map { h in defer { try? h.close() }; return ((try? h.read(upToCount: 4))?.count ?? 0) == 4 } ?? false
        }
        let s = SlskStore(url: folder.appendingPathComponent("Soulseek.sqlite"))
        store = s
        let c = SlskClient(config: cfg, store: s)
        c.onSnapshot = { [weak self] snap in Task { @MainActor in self?.take(snap) } }
        c.onDownloaded = { [weak self] info, url in Task { @MainActor in self?.downloaded(info, url) } }
        c.startPublishing(); c.restoreQueue()
        client = c
        return c
    }

    private func take(_ snap: SlskSnapshot) {
        let results = snap.resultCount
        snapshot = snap
        if results != lastResultCount { lastResultCount = results; rebuildRows() }
        if panelOpen || page == .log { log = Array((client?.log.all() ?? []).suffix(400)) }
        if snap.state.isOnline, sharing { scheduleShareRebuild(initial: true) }
    }

    private func rebuildRows() {
        rowTask?.cancel()
        let responses = snapshot.results, f = filters
        rowTask = Task.detached(priority: .userInitiated) { [weak self] in
            let r = SlskRows.build(responses, filters: f)
            if Task.isCancelled { return }
            await MainActor.run { self?.rows = r }
        }
    }

    // MARK: actions

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        lastResultCount = -1; rows = []
        client?.search(q)
    }
    func download(_ files: [SlskFileResult], from user: String) {
        for f in files {
            if isInLibrary(f) { continue }
            client?.download(user: user, path: f.path, size: f.size)
        }
    }
    func pauseAll(_ on: Bool) { client?.pauseAll(on) }
    func cancel(_ id: Int) { client?.cancel(id: id) }
    func retry(_ id: Int) { client?.retry(id: id) }
    func clearFinished() { client?.clearFinished() }
    func browse(_ user: String) { browseUser = user; page = .browse; client?.browse(user: user) }
    func message(_ user: String, _ text: String) { client?.sendPrivateMessage(to: user, text) }
    func block(_ user: String, _ on: Bool) { store?.ban(user, on); objectWillChange.send() }
    func isBlocked(_ user: String) -> Bool { store?.isBanned(user) ?? false }
    func addFriend(_ user: String) { store?.friend(user, true) }
    func wish(_ q: String) { store?.wish(q, true); objectWillChange.send() }
    var wishes: [String] { store?.wishes() ?? [] }
    func togglePanel() { panelOpen.toggle(); if panelOpen { log = Array((client?.log.all() ?? []).suffix(400)) } }
    func openTransfers() { panelOpen = false; page = .transfers; playerRef?.go(.tab(.soulseek)) }

    // MARK: library

    /// "Already in your library": a file with the same name and size as a song the library holds (checked against the titles it knows).
    func isInLibrary(_ f: SlskFileResult) -> Bool { inLibrary.contains(Self.key(f.name, f.size)) }
    nonisolated static func key(_ name: String, _ size: UInt64) -> String { name.lowercased() + "|" + String(size) }

    /// Builds the set of names and sizes the library already has, in the background.
    func refreshLibraryIndex() {
        guard let store = libraryRef?.store else { return }
        Task.detached(priority: .utility) {
            var set = Set<String>(); var off = 0
            while true {
                let page = store.allTracks(offset: off, limit: 2000)
                for t in page { if let s = t.fileSize { set.insert(Self.key((t.path as NSString).lastPathComponent, UInt64(s))) } }
                if page.count < 2000 || set.count > 400_000 { break }
                off += 2000
            }
            await MainActor.run { self.inLibrary = set }
        }
    }

    private func downloaded(_ info: SlskTransferInfo, _ url: URL) {
        guard addToLibrary, let lib = libraryRef else { return }
        // an album is imported once, when no other file of its folder is still on its way
        importTimer?.invalidate()
        importTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            let pending = self.snapshot.downloads.contains { $0.state.isActive }
            if pending { self.downloaded(info, url); return }
            let folder = self.downloadsFolder.path
            if !lib.folders.contains(folder) { lib.addFolder(self.downloadsFolder) } else { lib.rescan(folder) }
        } }
    }

    // MARK: sharing

    private func scheduleShareRebuild(initial: Bool = false) {
        guard sharing, let store = libraryRef?.store, client != nil else { return }
        if initial, shareTask != nil { return }
        shareTask?.cancel()
        let folders = sharedFolders
        shareTask = Task.detached(priority: .utility) { [weak self] in
            if !initial { try? await Task.sleep(nanoseconds: 30_000_000_000) }          // a change settles for 30 s before the list is rebuilt
            if Task.isCancelled { return }
            var files: [(String, UInt64)] = []; var off = 0
            while !folders.isEmpty {
                let page = store.allTracks(offset: off, limit: 2000)
                for t in page { files.append((t.path, UInt64(t.fileSize ?? 0))) }
                if page.count < 2000 { break }
                off += 2000
            }
            let shares = SlskShares.build(files: files, folders: folders)
            await MainActor.run { self?.client?.setShares(shares) }
        }
    }

    // MARK: playback protection

    /// While a high-resolution song streams from the network (Settings → Soulseek), transfers wait; uploads drop to one slot.
    private func protectPlayback() {
        guard let c = client, let m = playerRef else { return }
        let rate = m.status.info?.sampleRate ?? 0
        let streaming = m.isActive && m.focusItem?.remotePath != nil && rate > 48_000
        c.setPlaybackGuard(m.isActive)
        if pauseWhileHiRes && streaming { c.pauseTransfers(for: 10) }
    }
}

enum SoulseekPageID: String, CaseIterable, Identifiable {
    case search = "Search", transfers = "Transfers", browse = "Browse", chat = "Chat", shares = "Shares", connection = "Connection", log = "Log"
    var id: String { rawValue }
}

enum SlskFormat {
    static func bytes(_ n: UInt64) -> String {
        let mb = Double(n) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : (mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", Double(n) / 1024))
    }
    static func speed(_ bps: Double) -> String { bps >= 1_048_576 ? String(format: "%.1f MB/s", bps / 1_048_576) : String(format: "%.0f KB/s", bps / 1024) }
    static func state(_ s: SlskTransferState) -> String {
        switch s {
        case .waiting: "Waiting"; case .connecting: "Connecting"; case .queued(let p): p.map { "Queued, #\($0)" } ?? "Queued"
        case .transferring: "Downloading"; case .finished: "Finished"; case .paused: "Paused"
        case .needsAttention(let r): "Needs attention: \(r)"; case .retrying(let r): "Trying again: \(r)"
        }
    }
}

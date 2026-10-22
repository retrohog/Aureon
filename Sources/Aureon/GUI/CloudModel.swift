import SwiftUI

@MainActor
final class CloudModel: ObservableObject {
    @Published private(set) var profiles: [CloudProfile] = []
    @Published var draft: CloudProfile?
    @Published var draftSecret = ""
    @Published var accountID = ""                       // Cloudflare R2 only: part of the endpoint
    @Published private(set) var testing = false
    @Published private(set) var testResult: String?
    @Published private(set) var testOK = false
    @Published private(set) var importing: String?      // the profile being indexed
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var report: String?
    @Published private(set) var reportIsError = false

    // music servers (Subsonic / Navidrome …)
    @Published private(set) var servers: [SubsonicProfile] = []
    @Published var serverDraft: SubsonicProfile?
    @Published var serverPassword = ""

    let registry: CloudRegistry
    let subsonic = SubsonicRegistry.shared
    weak var library: LibraryModel?
    private var cancelFlag = RipModel.Atomic2()

    init(registry: CloudRegistry = .shared) { self.registry = registry; profiles = registry.profiles; servers = SubsonicRegistry.shared.profiles }

    func reload() { profiles = registry.profiles; servers = subsonic.profiles }

    // MARK: editing

    func newProfile() {
        var p = CloudProfile(); p.provider = .backblaze
        draft = p; draftSecret = ""; accountID = ""; testResult = nil
    }

    func edit(_ p: CloudProfile) { draft = p; draftSecret = registry.secrets.get(p.secretAccount) ?? ""; testResult = nil }

    /// Fills the endpoint from the provider and region unless the user chose "other".
    func providerChanged() {
        guard var d = draft else { return }
        if d.provider != .custom { d.endpoint = d.provider.endpoint(region: d.region.isEmpty ? "us-east-1" : d.region, account: accountID) }
        d.pathStyle = d.provider != .aws
        draft = d
    }

    var draftProblem: String? {
        guard let d = draft else { return nil }
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give this library a name." }
        if d.config == nil { return d.bucket.isEmpty ? "Enter the bucket name." : "The endpoint should look like https://s3.us-west-004.backblazeb2.com" }
        if d.accessKey.isEmpty { return "Enter the access key (Backblaze calls it the keyID)." }
        if draftSecret.isEmpty { return "Enter the secret key (Backblaze calls it the applicationKey)." }
        return nil
    }

    func saveDraft() {
        guard var d = draft, draftProblem == nil else { return }
        d.prefix = normalizedPrefix(d.prefix)
        registry.save(d, secret: draftSecret)
        draft = nil; draftSecret = ""; reload()
    }

    func normalizedPrefix(_ s: String) -> String {
        var p = s.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("/") { p.removeFirst() }
        return p.isEmpty || p.hasSuffix("/") ? p : p + "/"
    }

    func cancelEdit() { draft = nil; draftSecret = ""; testResult = nil }

    // MARK: testing the connection

    func test() {
        guard var d = draft, !testing else { return }
        d.prefix = normalizedPrefix(d.prefix)
        let secret = draftSecret
        guard let cfg = d.config else { testOK = false; testResult = draftProblem ?? "The address is incomplete."; return }
        testing = true; testResult = nil
        let client = S3Client(config: cfg, credentials: S3Credentials(accessKey: d.accessKey, secretKey: secret), http: registry.http)
        let prefix = d.prefix
        Task {
            do {
                let page = try await client.list(prefix: prefix, delimiter: nil, maxKeys: 1000)
                let audio = page.objects.filter { LibraryStore.audioExtensions.contains(($0.key as NSString).pathExtension.lowercased()) }.count
                self.testOK = true
                self.testResult = audio > 0 ? "Connected. \(audio)\(page.nextToken != nil ? "+" : "") audio files found." : (page.objects.isEmpty ? "Connected, but nothing is stored under this folder." : "Connected, but no FLAC, ALAC, WAV or AIFF files were found in the first \(page.objects.count) objects.")
            } catch {
                self.testOK = false; self.testResult = error.localizedDescription
            }
            self.testing = false
        }
    }

    // MARK: importing

    func importLibrary(_ p: CloudProfile) {
        guard importing == nil, let store = library?.store else { return }
        importing = p.id; report = nil; progress = (0, 0); cancelFlag.value = false
        let reg = registry, flag = cancelFlag
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try CloudImporter.run(profile: p, registry: reg, store: store, progress: { d, t in Task { @MainActor in self?.progress = (d, t) } }, cancelled: { flag.value })
                _ = store.normalizeArtists()
                await MainActor.run {
                    guard let self else { return }
                    self.importing = nil
                    self.reportIsError = r.failed > 0 && r.added + r.updated + r.skipped == 0
                    self.report = flag.value ? "Stopped after \(r.added + r.updated) tracks." : "\(r.added) added, \(r.updated) updated, \(r.skipped) unchanged, \(r.removed) removed" + (r.failed > 0 ? ", \(r.failed) unreadable (\(r.errors.first ?? ""))" : "") + "."
                    self.library?.refresh(); self.library?.onLibraryChanged?()
                }
            } catch {
                await MainActor.run { self?.importing = nil; self?.reportIsError = true; self?.report = error.localizedDescription }
            }
        }
    }

    func cancelImport() { cancelFlag.value = true }

    func remove(_ p: CloudProfile) {
        guard importing == nil else { return }
        if let store = library?.store { _ = store.removeTracks(under: CloudPath.scheme + p.id, keeping: []) }
        registry.remove(p.id); reload()
        library?.refresh(); library?.onLibraryChanged?()
    }

    // MARK: music servers

    func newServer() { serverDraft = SubsonicProfile(); serverPassword = ""; testResult = nil }
    func editServer(_ p: SubsonicProfile) { serverDraft = p; serverPassword = subsonic.secrets.get(p.secretAccount) ?? ""; testResult = nil }
    func cancelServerEdit() { serverDraft = nil; serverPassword = ""; testResult = nil }

    var serverProblem: String? {
        guard let d = serverDraft else { return nil }
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give this server a name." }
        if SubsonicClient(urlString: d.url, username: d.username, password: serverPassword, http: subsonic.http) == nil { return "Enter the server address, e.g. https://music.example.com" }
        if d.username.isEmpty { return "Enter the user name." }
        if serverPassword.isEmpty { return "Enter the password." }
        return nil
    }

    func saveServer() {
        guard let d = serverDraft, serverProblem == nil else { return }
        subsonic.save(d, password: serverPassword)
        serverDraft = nil; serverPassword = ""; reload()
    }

    func testServer() {
        guard let d = serverDraft, !testing, let client = SubsonicClient(urlString: d.url, username: d.username, password: serverPassword, http: subsonic.http) else { return }
        testing = true; testResult = nil
        Task {
            do {
                let info = try await client.ping()
                self.testOK = true
                self.testResult = "Connected to \(info.type ?? "a Subsonic server")\(info.serverVersion.map { " \($0)" } ?? ""), API \(info.apiVersion)\(info.openSubsonic ? " (OpenSubsonic)" : "")."
            } catch { self.testOK = false; self.testResult = error.localizedDescription }
            self.testing = false
        }
    }

    func importServer(_ p: SubsonicProfile) {
        guard importing == nil, let store = library?.store else { return }
        importing = p.id; report = nil; progress = (0, 0); cancelFlag.value = false
        let reg = subsonic, flag = cancelFlag
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try SubsonicImporter.run(profile: p, registry: reg, store: store, progress: { d, t in Task { @MainActor in self?.progress = (d, t) } }, cancelled: { flag.value })
                _ = store.normalizeArtists()
                await MainActor.run {
                    guard let self else { return }
                    self.importing = nil; self.reportIsError = r.failed > 0
                    self.report = flag.value ? "Stopped after \(r.songs) tracks." : "\(r.songs) tracks in \(r.albums) albums" + (r.removed > 0 ? ", \(r.removed) removed" : "") + (r.failed > 0 ? "; \(r.failed) albums failed (\(r.errors.first ?? ""))" : "") + "."
                    self.library?.refresh(); self.library?.onLibraryChanged?()
                }
            } catch { await MainActor.run { self?.importing = nil; self?.reportIsError = true; self?.report = error.localizedDescription } }
        }
    }

    func removeServer(_ p: SubsonicProfile) {
        guard importing == nil else { return }
        if let store = library?.store { _ = store.removeTracks(under: SubsonicPath.scheme + p.id, keeping: []) }
        subsonic.remove(p.id); reload()
        library?.refresh(); library?.onLibraryChanged?()
    }
}

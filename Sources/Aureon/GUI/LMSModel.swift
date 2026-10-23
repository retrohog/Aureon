import SwiftUI

@MainActor
final class LMSModel: ObservableObject {
    @Published private(set) var servers: [LMSProfile] = []
    @Published var draft: LMSProfile?
    @Published var password = ""
    @Published private(set) var testing = false
    @Published private(set) var testResult: String?
    @Published private(set) var testOK = false
    @Published private(set) var importing: String?
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var report: String?
    @Published private(set) var reportIsError = false
    @Published private(set) var discovering = false
    @Published private(set) var found: [LMSDiscovery.Found] = []

    let registry = LMSRegistry.shared
    weak var library: LibraryModel?
    private var cancelFlag = RipModel.Atomic2()

    init() { servers = registry.profiles }
    func reload() { servers = registry.profiles }

    func new(from f: LMSDiscovery.Found? = nil) {
        var p = LMSProfile()
        if let f { p.name = f.name; p.url = f.url }
        draft = p; password = ""; testResult = nil
    }
    func edit(_ p: LMSProfile) { draft = p; password = registry.secrets.get(p.secretAccount) ?? ""; testResult = nil }
    func cancelEdit() { draft = nil; password = ""; testResult = nil }

    var problem: String? {
        guard let d = draft else { return nil }
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give this server a name." }
        if LMSClient(urlString: d.url) == nil { return "Enter the server address, e.g. http://192.168.1.20:9000" }
        if !d.username.isEmpty && password.isEmpty { return "Enter the password, or clear the user name if the server has none." }
        return nil
    }

    func save() {
        guard let d = draft, problem == nil else { return }
        registry.save(d, password: password)
        draft = nil; password = ""; reload()
    }

    func test() {
        guard let d = draft, !testing, let c = LMSClient(urlString: d.url, username: d.username, password: password, http: registry.http) else { return }
        testing = true; testResult = nil
        Task {
            do {
                let s = try await c.status()
                testOK = true
                testResult = "Connected to Lyrion Music Server \(s.version): \(s.songs) tracks\(s.scanning ? " (scanning now)" : "")."
            } catch { testOK = false; testResult = error.localizedDescription }
            testing = false
        }
    }

    func discover() {
        guard !discovering else { return }
        discovering = true
        Task.detached(priority: .userInitiated) {
            let f = LMSDiscovery.discover()
            await MainActor.run { self.found = f; self.discovering = false; if f.isEmpty { self.report = "No Lyrion server answered on this network. Enter its address by hand."; self.reportIsError = true } }
        }
    }

    func importServer(_ p: LMSProfile) {
        guard importing == nil, let store = library?.store else { return }
        importing = p.id; report = nil; progress = (0, 0); cancelFlag.value = false
        let reg = registry, flag = cancelFlag
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try LMSImporter.run(profile: p, registry: reg, store: store, progress: { d, t in Task { @MainActor in self?.progress = (d, t) } }, cancelled: { flag.value })
                _ = store.normalizeArtists()
                await MainActor.run {
                    guard let self else { return }
                    self.importing = nil; self.reportIsError = r.failed > 0
                    self.report = flag.value ? "Stopped after \(r.songs) tracks." : "\(r.songs) tracks added" + (r.removed > 0 ? ", \(r.removed) removed" : "") + (r.failed > 0 ? "; \(r.failed) skipped (\(r.errors.first ?? ""))" : "") + "."
                    self.library?.refresh(); self.library?.onLibraryChanged?()
                }
            } catch { await MainActor.run { self?.importing = nil; self?.reportIsError = true; self?.report = error.localizedDescription } }
        }
    }

    func cancelImport() { cancelFlag.value = true }

    func remove(_ p: LMSProfile) {
        guard importing == nil else { return }
        if let store = library?.store { _ = store.removeTracks(under: LMSPath.scheme + p.id, keeping: []) }
        registry.remove(p.id); reload()
        library?.refresh(); library?.onLibraryChanged?()
    }
}

struct LMSSection: View {
    @EnvironmentObject var lms: LMSModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let d = lms.draft { editor(d) }
            ForEach(lms.servers) { card($0) }
            Card(title: "Lyrion Music Server", subtitle: "Squeezebox servers on your network") {
                HStack(spacing: 12) {
                    RuleButton(title: lms.discovering ? "Searching…" : "Find on this network", symbol: "dot.radiowaves.left.and.right") { lms.discover() }.disabled(lms.discovering)
                    RuleButton(title: "Add by address…", symbol: "plus") { lms.new() }
                }
                ForEach(lms.found, id: \.url) { f in
                    HStack { Text(f.name).fontWeight(.medium); Text(f.url).foregroundStyle(Brand.inkSecondary); Spacer(); RuleButton(title: "Add", symbol: "plus") { lms.new(from: f) } }
                }
                if let r = lms.report { Note(text: r, color: lms.reportIsError ? .red : .green) }
                Note(text: "Aureon reads your Lyrion library over its web interface and plays the original files (FLAC stays FLAC) into the same buffered engine as local music. Nothing is transcoded by the server.")
            }
        }
        .onAppear { lms.reload() }
    }

    private func card(_ p: LMSProfile) -> some View {
        Card(title: p.name, subtitle: "Lyrion · \(p.url)") {
            HStack(spacing: 12) {
                if lms.importing == p.id {
                    ProgressView(value: Double(lms.progress.done), total: Double(max(1, lms.progress.total))).frame(width: 180)
                    Text("\(lms.progress.done) of \(lms.progress.total) tracks").font(Typo.caption).monospacedDigit().foregroundStyle(Brand.inkSecondary)
                    RuleButton(title: "Stop", symbol: "stop.fill") { lms.cancelImport() }
                } else {
                    RuleButton(title: "Add to library", symbol: "arrow.down.doc", filled: true) { lms.importServer(p) }.disabled(lms.importing != nil)
                    RuleButton(title: "Edit", symbol: "pencil") { lms.edit(p) }.disabled(lms.importing != nil)
                    RuleButton(title: "Remove", symbol: "trash") { lms.remove(p) }.disabled(lms.importing != nil)
                }
            }
        }
    }

    private func editor(_ d: LMSProfile) -> some View {
        let bind = Binding<LMSProfile>(get: { lms.draft ?? d }, set: { lms.draft = $0 })
        return Card(title: "Lyrion server", subtitle: nil) {
            HStack { Text("Name").frame(width: 110, alignment: .leading); TextField("Living room", text: bind.name).textFieldStyle(.plain).ruleField() }
            HStack { Text("Address").frame(width: 110, alignment: .leading); TextField("http://192.168.1.20:9000", text: bind.url).textFieldStyle(.plain).ruleField() }
            HStack { Text("User name").frame(width: 110, alignment: .leading); TextField("leave empty if there is no password", text: bind.username).textFieldStyle(.plain).ruleField() }
            HStack { Text("Password").frame(width: 110, alignment: .leading); SecureField("password", text: $lms.password).textFieldStyle(.plain).ruleField() }
            Note(text: "Lyrion sends credentials as HTTP Basic: keep it on your home network or behind HTTPS. The password is stored in the macOS Keychain.")
            if let p = lms.problem { Note(text: p, color: Brand.caution) }
            HStack(spacing: 12) {
                RuleButton(title: "Save", symbol: "checkmark", filled: true) { lms.save() }.disabled(lms.problem != nil)
                RuleButton(title: "Test connection", symbol: "bolt.horizontal") { lms.test() }.disabled(lms.problem != nil || lms.testing)
                RuleButton(title: "Cancel", symbol: "xmark") { lms.cancelEdit() }
                if lms.testing { ProgressView().controlSize(.small) }
            }
            if let t = lms.testResult { Note(text: t, color: lms.testOK ? .green : .red) }
        }
    }
}

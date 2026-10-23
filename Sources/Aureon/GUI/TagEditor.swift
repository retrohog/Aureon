import SwiftUI
import AppKit

/// The multi-file tag editor: reads every file's tags in the background, shows shared values (or "Multiple values"), and writes only
/// what was changed. Writing happens on a background queue; a file the engine holds is retried until it is free.
@MainActor
final class TagEditorModel: ObservableObject {
    enum Status: Equatable {
        case loading, ready, pending, waiting(String), writing, done, failed(String)
        var label: String {
            switch self {
            case .loading: "Reading…"; case .ready: ""; case .pending: "Queued"; case .waiting(let r): "Waiting: \(r)"; case .writing: "Writing…"
            case .done: "Saved"; case .failed(let e): e
            }
        }
    }
    struct FileState: Identifiable, Equatable {
        let path: String
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var format: String { (path as NSString).pathExtension.uppercased() }
        var original = TagValues()
        var status = Status.loading
        var editable: Bool
    }

    @Published var files: [FileState]
    /// What the form shows for each field (the shared value, or what the person typed).
    @Published var fields: [TagField: String] = [:]
    @Published private(set) var mixed: Set<TagField> = []
    @Published private(set) var edited: Set<TagField> = []
    /// Values that differ per file (track numbers, measured ReplayGain), by path.
    @Published private(set) var perFile: [String: [TagField: String]] = [:]
    @Published var writeBack: Bool { didSet { UserDefaults.standard.set(writeBack, forKey: "aureon.tags.writeBack") } }
    @Published private(set) var measuring = false
    @Published private(set) var measureProgress = 0.0
    @Published private(set) var saving = false
    @Published var message: String?

    let store: LibraryStore?
    private let held: @MainActor () -> Set<String>
    var onSaved: (() -> Void)?
    private let io = DispatchQueue(label: "aureon.tagwrite", qos: .userInitiated)
    private var retry: Timer?
    private var retryUntil = Date.distantFuture

    init(paths: [String], store: LibraryStore?, held: @escaping @MainActor () -> Set<String>) {
        var seen = Set<String>()
        files = paths.filter { seen.insert($0).inserted }.map { FileState(path: $0, editable: TagEditing.isEditable($0)) }
        self.store = store; self.held = held
        writeBack = UserDefaults.standard.object(forKey: "aureon.tags.writeBack") as? Bool ?? true
        load()
    }

    var editableCount: Int { files.filter(\.editable).count }
    var inLibraryOnlyMode: Bool { !writeBack }
    var hasChanges: Bool { !edited.isEmpty || !perFile.isEmpty }
    var finished: Bool { files.allSatisfy { [.done, .ready].contains($0.status) || { if case .failed = $0.status { return true }; return false }($0) } }

    private func load() {
        let paths = files.map(\.path)
        Task.detached(priority: .userInitiated) {
            let read = paths.map { TagEditing.read(path: $0) }
            await MainActor.run {
                for (i, v) in read.enumerated() where i < self.files.count { self.files[i].original = v; self.files[i].status = .ready }
                self.recomputeShared()
            }
        }
    }

    private func recomputeShared() {
        let editable = files.filter(\.editable)
        var shared: [TagField: String] = [:], differ = Set<TagField>()
        for f in TagField.allCases {
            let vals = Set(editable.map { $0.original[f] ?? "" })
            if vals.count > 1 { differ.insert(f) } else if let v = vals.first, !v.isEmpty { shared[f] = v }
        }
        for f in edited { shared[f] = fields[f] }
        fields = shared; mixed = differ.subtracting(edited)
    }

    func binding(_ f: TagField) -> Binding<String> {
        Binding(get: { self.fields[f] ?? "" }, set: { v in
            self.fields[f] = v; self.edited.insert(f); self.mixed.remove(f)
            for k in self.perFile.keys { self.perFile[k]?[f] = nil }               // a typed value overrides measured / numbered ones
        })
    }

    func revert(_ f: TagField) {
        edited.remove(f)
        for k in perFile.keys { perFile[k]?[f] = nil; if perFile[k]?.isEmpty == true { perFile[k] = nil } }
        recomputeShared()
    }

    func isPerFile(_ f: TagField) -> Bool { perFile.values.contains { $0[f] != nil } }

    /// 1…N in the order the files are listed.
    func numberTracks() {
        for (i, f) in files.filter(\.editable).enumerated() { perFile[f.path, default: [:]][.trackNumber] = String(i + 1) }
        let n = String(editableCount)
        fields[.trackTotal] = n; edited.insert(.trackTotal); edited.remove(.trackNumber); mixed.remove(.trackTotal)
        fields[.trackNumber] = nil; mixed.insert(.trackNumber)
        message = "Numbered \(editableCount) tracks in list order."
    }

    func clearReplayGain() {
        for f in TagField.allCases where f.isReplayGain { fields[f] = ""; edited.insert(f); mixed.remove(f); for k in perFile.keys { perFile[k]?[f] = nil } }
        message = "ReplayGain will be removed from the files."
    }

    /// Measures every file (EBU R128, cached) and fills in ReplayGain 2.0 values: gain to −18 LUFS, peak = true peak.
    /// The album gain treats the files as one album: the duration-weighted energy mean of their loudness.
    func measureReplayGain() {
        guard !measuring else { return }
        measuring = true; measureProgress = 0; message = nil
        let paths = files.filter(\.editable).map(\.path)
        Task.detached(priority: .utility) {
            var results: [(String, R128Result)] = []
            for (i, p) in paths.enumerated() {
                if let r = LoudnessCache.shared.analysis(path: p) { results.append((p, r)) }
                let progress = Double(i + 1) / Double(max(1, paths.count))
                await MainActor.run { self.measureProgress = progress }
            }
            let rg = ReplayGainMath.values(results.map { ($0.1.integratedLUFS, $0.1.truePeakLinear, $0.1.duration) })
            let measured = results
            await MainActor.run {
                for (k, (p, _)) in measured.enumerated() {
                    guard let v = rg.tracks[k] else { continue }
                    self.perFile[p, default: [:]][.rgTrackGain] = v.gain
                    self.perFile[p, default: [:]][.rgTrackPeak] = v.peak
                }
                for f in [TagField.rgTrackGain, .rgTrackPeak] { self.edited.remove(f); self.fields[f] = nil; self.mixed.insert(f) }
                if let a = rg.album {
                    self.fields[.rgAlbumGain] = a.gain; self.fields[.rgAlbumPeak] = a.peak
                    self.edited.formUnion([.rgAlbumGain, .rgAlbumPeak]); self.mixed.subtract([.rgAlbumGain, .rgAlbumPeak])
                }
                if measured.count == 1, let v = rg.tracks[0] { self.fields[.rgTrackGain] = v.gain; self.fields[.rgTrackPeak] = v.peak; self.mixed.subtract([.rgTrackGain, .rgTrackPeak]) }
                self.measuring = false
                self.message = measured.count == paths.count ? "Measured \(measured.count) file\(measured.count == 1 ? "" : "s") (EBU R128, reference −18 LUFS)." : "Measured \(measured.count) of \(paths.count) files; the rest could not be decoded."
            }
        }
    }

    /// What will be written to one file.
    func edits(for path: String) -> [TagField: String] {
        var e: [TagField: String] = [:]
        for f in edited { e[f] = fields[f] ?? "" }
        for (f, v) in perFile[path] ?? [:] { e[f] = v }
        return e
    }

    func save() {
        guard !saving else { return }
        message = nil
        var any = false
        for i in files.indices where files[i].editable {
            if edits(for: files[i].path).isEmpty { files[i].status = .done } else { files[i].status = .pending; any = true }
        }
        guard any else { message = "Nothing changed."; return }
        saving = true
        retryUntil = Date().addingTimeInterval(30 * 60)
        attempt()
    }

    /// One pass over the files still to write. Files the engine holds stay waiting and are tried again shortly.
    private func attempt() {
        FileUse.shared.setEngineHeld(held())
        let jobs = files.filter { $0.status == .pending || { if case .waiting = $0.status { return true }; return false }($0) }.map { ($0.path, edits(for: $0.path)) }
        let writeBack = self.writeBack, store = self.store
        for (p, _) in jobs { setStatus(p, .writing) }
        io.async {
            for (path, e) in jobs {
                var status = Status.done
                if writeBack {
                    do { try TagEditing.write(path: path, edits: e) }
                    catch let err as TagEditError { status = err.isBusy ? .waiting(err.errorDescription ?? "in use") : .failed(err.errorDescription ?? "failed") }
                    catch { status = .failed(error.localizedDescription) }
                }
                if status == .done, let store, store.contains(path: path) {
                    let tags = writeBack ? TagReader.read(path: path) : TagEditing.applying(e, to: TagReader.read(path: path))
                    store.update(path: path, tags: tags)
                }
                let s = status
                DispatchQueue.main.async { MainActor.assumeIsolated { self.setStatus(path, s) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.passFinished() } }
        }
    }

    private func setStatus(_ path: String, _ s: Status) { if let i = files.firstIndex(where: { $0.path == path }) { files[i].status = s } }

    private func passFinished() {
        let waiting = files.filter { if case .waiting = $0.status { return true }; return false }.count
        let failed = files.filter { if case .failed = $0.status { return true }; return false }.count
        if waiting > 0 && Date() < retryUntil {
            message = "\(waiting) file\(waiting == 1 ? " is" : "s are") in use by playback and will be written as soon as \(waiting == 1 ? "it is" : "they are") released."
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.attempt() } }
            return
        }
        saving = false
        let done = files.filter { $0.status == .done }.count
        message = failed == 0 && waiting == 0 ? (writeBack ? "Saved to \(done) file\(done == 1 ? "" : "s")." : "Saved to the library (the files were not changed).")
                                              : "\(done) saved, \(failed) failed\(waiting > 0 ? ", \(waiting) still in use" : "")."
        edited = []; perFile = [:]
        for i in files.indices where files[i].status == .done { files[i].original = TagEditing.read(path: files[i].path) }
        recomputeShared()
        onSaved?()
    }

    func cancelRetries() { retry?.invalidate(); retry = nil; saving = false }
}

/// ReplayGain 2.0 figures from loudness measurements.
enum ReplayGainMath {
    static let reference = -18.0
    struct Value: Equatable { var gain: String; var peak: String; var gainDB: Double; var peakLinear: Double }

    static func value(lufs: Double, peak: Double) -> Value {
        let g = reference - lufs
        return Value(gain: String(format: "%+.2f dB", g), peak: String(format: "%.6f", peak), gainDB: g, peakLinear: peak)
    }

    /// Per-track values (nil for silent files) and the album value over all of them.
    static func values(_ m: [(lufs: Double?, peak: Double, duration: Double)]) -> (tracks: [Value?], album: Value?) {
        let tracks = m.map { x in x.lufs.map { value(lufs: $0, peak: x.peak) } }
        let loud = m.filter { $0.lufs != nil && $0.duration > 0 }
        guard !loud.isEmpty else { return (tracks, nil) }
        let energy = loud.reduce(0) { $0 + $1.duration * pow(10, $1.lufs! / 10) } / loud.reduce(0) { $0 + $1.duration }
        return (tracks, value(lufs: 10 * log10(energy), peak: m.map(\.peak).max() ?? 0))
    }
}

// MARK: - Window

@MainActor
enum TagEditorWindow {
    private static var open: [NSWindow] = []
    /// Editors whose window closed while files were still waiting to be written: kept alive until done.
    private static var background: [TagEditorModel] = []

    static func open(paths: [String], model m: PlayerModel) {
        let local = paths.filter { !RemoteMedia.isRemote($0) }
        guard !local.isEmpty else { return }
        let held: @MainActor () -> Set<String> = { [weak m] in
            guard let m, m.isActive, let cur = m.current else { return [] }
            var s: Set<String> = [cur.path]
            if let i = m.items.firstIndex(where: { $0.id == cur.id }), i + 1 < m.items.count { s.insert(m.items[i + 1].path) }      // the next track may already sit decoded in RAM
            return s
        }
        let model = TagEditorModel(paths: local, store: m.library.store, held: held)
        model.onSaved = { [weak m] in m?.library.refresh() }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = local.count == 1 ? "Edit Tags — \((local[0] as NSString).lastPathComponent)" : "Edit Tags — \(local.count) files"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 520)
        w.contentView = NSHostingView(rootView: TagEditorView(model: model, close: { [weak w] in w?.close() })
            .environment(\.colorScheme, Theme.current.isLight ? .light : .dark))
        w.center()
        w.makeKeyAndOrderFront(nil)
        open.append(w)
        WindowClosing.whenClosed(w) { [weak w] in
            open.removeAll { $0 === w }
            if model.saving {
                background.append(model)
                model.onSaved = { [weak m, weak model] in m?.library.refresh(); background.removeAll { $0 === model } }
            }
        }
    }
}

/// Runs `body` once when `w` closes, then forgets it, so neither the window nor what `body` holds stays alive after closing.
@MainActor
enum WindowClosing {
    private final class Token: @unchecked Sendable { var observer: NSObjectProtocol? }

    static func whenClosed(_ w: NSWindow, _ body: @escaping @MainActor () -> Void) {
        let t = Token()
        t.observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let o = t.observer { NotificationCenter.default.removeObserver(o); t.observer = nil }
                body()
            }
        }
    }
}

// MARK: - View

struct TagEditorView: View {
    @ObservedObject var model: TagEditorModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Track") {
                        field(.title)
                        field(.artist, hint: "Several artists: separate with ;")
                        field(.album)
                        field(.albumArtist)
                        field(.composer)
                        HStack(spacing: 12) {
                            field(.year, width: 110)
                            field(.genre, hint: "Hierarchy with /, e.g. Classical/Beethoven")
                        }
                        HStack(spacing: 12) {
                            field(.trackNumber, width: 80)
                            field(.trackTotal, width: 80)
                            field(.discNumber, width: 80)
                            Spacer()
                            if model.editableCount > 1 {
                                Button("Number 1…\(model.editableCount)") { model.numberTracks() }.controlSize(.small)
                            }
                        }
                    }
                    section("ReplayGain") {
                        HStack(spacing: 12) { field(.rgTrackGain); field(.rgTrackPeak) }
                        HStack(spacing: 12) { field(.rgAlbumGain); field(.rgAlbumPeak) }
                        HStack(spacing: 12) {
                            Button { model.measureReplayGain() } label: { Label("Measure loudness", systemImage: "waveform.badge.magnifyingglass") }.disabled(model.measuring)
                            Button("Remove ReplayGain") { model.clearReplayGain() }
                            if model.measuring { ProgressView(value: model.measureProgress).frame(width: 120) }
                            Spacer()
                        }.controlSize(.small)
                        Text("EBU R128 measurement, ReplayGain 2.0 reference −18 LUFS. The album gain treats the selected files as one album.")
                            .font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary)
                    }
                    section("Files") {
                        VStack(spacing: 2) {
                            ForEach(model.files) { f in fileRow(f) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            footer
        }
        .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 16)
        .frame(minWidth: 520, minHeight: 520)
        .background(Brand.canvas)
        .foregroundStyle(Brand.ink)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Edit Tags").font(Typo.serif(22, .regular))
            Text("\(model.files.count) file\(model.files.count == 1 ? "" : "s")").microLabel().foregroundStyle(Brand.inkSecondary)
            Spacer()
            let formats = Set(model.files.map(\.format)).sorted().joined(separator: " · ")
            Text(formats).microLabel().foregroundStyle(Brand.inkSecondary)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).kicker().foregroundStyle(Brand.inkSecondary)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 12)
    }

    private func field(_ f: TagField, width: CGFloat? = nil, hint: String? = nil) -> some View {
        let changed = model.edited.contains(f) || model.isPerFile(f)
        let prompt = model.mixed.contains(f) ? (model.isPerFile(f) ? "Set per file" : "Multiple values") : (hint ?? "")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(f.label).font(Typo.sans(11, .medium)).foregroundStyle(Brand.inkSecondary)
                if changed {
                    Circle().fill(Brand.accent).frame(width: 5, height: 5)
                    Button { model.revert(f) } label: { Image(systemName: "arrow.uturn.backward").font(Typo.sans(9, .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Brand.inkSecondary).help("Undo this change")
                }
            }
            TextField(prompt, text: model.binding(f))
                .textFieldStyle(.plain).ruleField().font(Typo.sans(12.5))
                .disabled(model.saving)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
    }

    private func fileRow(_ f: TagEditorModel.FileState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(f)).foregroundStyle(color(f)).frame(width: 16)
            Text(f.name).font(Typo.sans(12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if !f.editable { Text("not editable").font(Typo.sans(10.5)).foregroundStyle(Brand.inkTertiary) }
            else if let rg = model.perFile[f.path]?[.rgTrackGain] { Text(rg).font(Typo.mono(10.5)).foregroundStyle(Brand.inkSecondary) }
            if let n = model.perFile[f.path]?[.trackNumber] { Text("#\(n)").font(Typo.mono(10.5)).foregroundStyle(Brand.inkSecondary) }
            Text(f.status.label).font(Typo.sans(10.5)).foregroundStyle(color(f)).lineLimit(1)
            Text(f.format).font(Typo.mono(9.5, .semibold)).foregroundStyle(Brand.inkSecondary)
        }
        .padding(.vertical, 3)
        .help(f.path)
    }

    private func icon(_ f: TagEditorModel.FileState) -> String {
        switch f.status {
        case .done: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill"; case .waiting: "lock.fill"; case .writing, .pending: "arrow.down.doc"
        default: f.editable ? "doc.text" : "nosign"
        }
    }
    private func color(_ f: TagEditorModel.FileState) -> Color {
        switch f.status { case .done: .green; case .failed: .orange; case .waiting: Brand.accent; default: .secondary }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let msg = model.message { Text(msg).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary) }
            HStack(spacing: 12) {
                Toggle(isOn: $model.writeBack) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Write to the files").font(Typo.sans(12.5, .medium))
                        Text(model.writeBack ? "Atomic: a new copy is written and swapped in. Files in use wait until playback lets go."
                                             : "Only the library changes; the files stay exactly as they are.")
                            .font(Typo.sans(10.5)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.rule).disabled(model.saving)
                Spacer()
                Button(model.saving ? "Close" : "Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(model.saving ? "Saving…" : "Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChanges || model.saving || model.editableCount == 0)
            }
        }
    }
}

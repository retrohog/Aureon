import SwiftUI
import AVFoundation
import AudioToolbox

/// A hosted plug-in as saved in a profile: which unit it is and its state (every parameter and preset).
struct SavedPlugin: Codable, Equatable {
    var type: UInt32, subtype: UInt32, manufacturer: UInt32
    var name: String, maker: String
    var state: Data?
}

struct DSPProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var dsp: DSPSettings
    var plugins: [SavedPlugin]
}

private struct DSPProfileFile: Codable { var profiles: [DSPProfile]; var activeID: UUID? }

/// The DSP page's state. The page edits a draft; the draft reaches the engine a few times a second at most (so dragging a fader never floods
/// the audio engine or redraws the whole app), and nothing becomes permanent until it is saved into a profile.
@MainActor
final class DSPModel: ObservableObject {
    @Published var draft = DSPSettings() { didSet { if draft != oldValue { acknowledged = false; scheduleApply() } } }
    @Published private(set) var profiles: [DSPProfile] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var pluginsChanged = false
    /// The user chose to keep unsaved changes for this session.
    @Published private(set) var acknowledged = false
    var pluginCount: () -> Int = { 0 }

    var apply: (DSPSettings) -> Void = { _ in }
    var captureHosted: () -> [SavedPlugin] = { [] }
    var restoreHosted: ([SavedPlugin]) async -> Void = { _ in }
    private var applyScheduled = false
    private var lastApplied = DSPSettings()
    private let url: URL?

    init(url: URL? = DSPModel.defaultURL) {
        self.url = url
        load()
    }

    nonisolated static var defaultURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/dsp-profiles.json") }

    var active: DSPProfile? { profiles.first { $0.id == activeID } }

    /// Differs from what is saved (or from a clean start when no profile is active).
    var dirty: Bool {
        let base = active
        if draft != (base?.dsp ?? DSPSettings()) { return true }
        if pluginsChanged { return true }
        return pluginCount() != (base?.plugins.count ?? 0)
    }
    var needsPrompt: Bool { dirty && !acknowledged }
    func acknowledgeUnsaved() { acknowledged = true }
    func markPluginsClean() { pluginsChanged = false; objectWillChange.send() }
    func notePluginsChanged() { pluginsChanged = true; acknowledged = false; objectWillChange.send() }

    // MARK: engine

    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyScheduled = false
                if self.draft != self.lastApplied { self.lastApplied = self.draft; self.apply(self.draft) }
            }
        }
    }

    /// Pushes the draft to the engine immediately (used after loading a profile).
    func applyNow() { lastApplied = draft; apply(draft) }

    // MARK: profiles

    func select(_ id: UUID?) {
        activeID = id
        pluginsChanged = false; acknowledged = false
        let p = active
        draft = p?.dsp ?? DSPSettings()
        applyNow()
        persist()
        let plugins = p?.plugins ?? []
        Task { await restoreHosted(plugins) }
    }

    /// Saves into the active profile.
    func save() {
        guard let i = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        profiles[i].dsp = draft; profiles[i].plugins = captureHosted()
        pluginsChanged = false; acknowledged = false
        persist(); objectWillChange.send()
    }

    @discardableResult
    func saveAs(_ name: String) -> DSPProfile {
        let p = DSPProfile(name: name, dsp: draft, plugins: captureHosted())
        profiles.append(p); activeID = p.id
        pluginsChanged = false; acknowledged = false
        persist()
        return p
    }

    func rename(_ id: UUID, to name: String) { if let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].name = name; persist() } }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        persist()
    }

    /// Throws away unsaved changes: back to the saved profile (or a clean start).
    func revert() { select(activeID) }

    // MARK: storage

    private func persist() {
        guard let url, ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil, ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil || url != DSPModel.defaultURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(DSPProfileFile(profiles: profiles, activeID: activeID)) { try? d.write(to: url, options: .atomic) }
    }

    private func load() {
        guard let url, let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(DSPProfileFile.self, from: d) else { return }
        profiles = f.profiles
        activeID = f.profiles.contains { $0.id == f.activeID } ? f.activeID : nil
        draft = active?.dsp ?? DSPSettings()
        lastApplied = draft
    }

    /// Restores the active profile's plug-ins once the engine and plug-in list are ready (start-up).
    func startUp() {
        applyNow()
        if let p = active, !p.plugins.isEmpty { Task { await restoreHosted(p.plugins) } }
    }
}

extension PlayerModel {
    /// What a hosted plug-in is like right now, for saving into a profile.
    func capturePlugins() -> [SavedPlugin] {
        hosted.map { h in
            var state: Data?
            if let full = h.unit.auAudioUnit.fullState { state = try? NSKeyedArchiver.archivedData(withRootObject: full, requiringSecureCoding: false) }
            let d = h.info.description
            return SavedPlugin(type: d.componentType, subtype: d.componentSubType, manufacturer: d.componentManufacturer, name: h.info.name, maker: h.info.manufacturer, state: state)
        }
    }

    /// Replaces the hosted plug-ins with the ones saved in a profile (those no longer installed are skipped).
    func restorePlugins(_ saved: [SavedPlugin]) async {
        for h in hosted { removePlugin(h.id) }
        for sp in saved {
            guard let info = availableEffects.first(where: { $0.description.componentType == sp.type && $0.description.componentSubType == sp.subtype && $0.description.componentManufacturer == sp.manufacturer }) else {
                pluginError = "“\(sp.name)” from the saved profile is not installed"; continue
            }
            do {
                let unit = try await DSPChain.instantiate(info)
                if let d = sp.state, let obj = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(d) as? [String: Any] { unit.auAudioUnit.fullState = obj }
                hosted.append(HostedPlugin(info: info, unit: unit))
                observeParameters(of: hosted[hosted.count - 1])
            } catch { pluginError = "Could not load \(sp.name): \(error.localizedDescription)" }
        }
        player.setPlugins(hosted.map(\.unit))
    }
}

// MARK: - Plug-in windows

enum PluginWindowFactory {
    private final class Flipped: NSView { override var isFlipped: Bool { true } }

    @MainActor
    private static func newWindow(title: String, size: NSSize) -> NSWindow {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: min(max(size.width, 360), screen.width * 0.92), height: min(max(size.height, 220), screen.height * 0.88))),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false; w.contentMinSize = NSSize(width: 300, height: 160)
        w.center()
        return w
    }

    /// The system's generic view fills a resizable window.
    @MainActor
    static func window(title: String, generic: NSView) -> NSWindow {
        let w = newWindow(title: title, size: NSSize(width: 560, height: 520))
        generic.autoresizingMask = [.width, .height]
        w.contentView = generic
        return w
    }

    /// A plug-in's own view keeps its size inside a scroll view, so whatever does not fit can be reached; the window can be made bigger or smaller.
    @MainActor
    static func window(title: String, custom vc: NSViewController) -> NSWindow {
        let v = vc.view
        v.layoutSubtreeIfNeeded()
        var size = v.frame.size
        if size.width < 10 || size.height < 10 { size = vc.preferredContentSize }
        if size.width < 10 || size.height < 10 { size = v.fittingSize }
        if size.width < 10 || size.height < 10 { size = NSSize(width: 520, height: 400) }
        let w = newWindow(title: title, size: size)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: w.contentLayoutRect.size))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let doc = Flipped(frame: NSRect(origin: .zero, size: size))
        v.frame = NSRect(origin: .zero, size: size)
        v.autoresizingMask = [.width, .height]                  // views that adapt use the room; fixed ones simply stay put
        doc.addSubview(v)
        scroll.documentView = doc
        w.contentView = scroll
        w.contentViewController = nil
        objc_setAssociatedObject(w, &Self.retainKey, vc, .OBJC_ASSOCIATION_RETAIN)
        return w
    }

    nonisolated(unsafe) private static var retainKey = 0
}

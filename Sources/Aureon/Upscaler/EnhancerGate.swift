import SwiftUI
import AppKit

// The switch and the model of the real-time audio enhancer (engine in this folder). `EnhancerGate` is the thread-safe view of the saved
// `EnhancerSettings`; `EnhancerCard` (Audio settings) edits them. The enhancer is off by default: it changes the samples, and Aureon is
// bit-perfect unless asked otherwise.

/// A local model the user loaded, as it was when it passed the size check.
struct LocalModelSelection: Codable, Equatable, Sendable {
    var path: String
    var name: String
    var parameters: Int64
    var bytes: Int64

    init(_ info: LocalModelInfo) { path = info.url.path; name = info.name; parameters = info.parameters; bytes = info.bytes }
}

struct EnhancerSettings: Codable, Equatable, Sendable {
    static let key = "aureon.enhancer.settings"
    var enabled = false
    var model: LocalModelSelection?

    static func load(_ d: UserDefaults = .standard) -> EnhancerSettings {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(EnhancerSettings.self, from: $0) } ?? EnhancerSettings()
    }
    func save(_ d: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) } }
}

extension Notification.Name {
    /// Posted on the main thread after the enhancer settings changed.
    static let enhancerSettingsChanged = Notification.Name("aureon.enhancerSettingsChanged")
}

/// `isEnabled` is one atomic load (acquire ordering): no lock, no allocation, no Objective-C, so it may be called from the render callback.
/// The model location is behind a lock and is for setup code only.
final class EnhancerGate: Sendable {
    static let shared = EnhancerGate(hardware: .current, settings: EnhancerSettings.load())

    let hardware: HostHardware
    private let on: Atomic<Bool>
    private let changes = Atomic<UInt64>(0)
    private let model: Mutex<URL?>

    init(hardware: HostHardware, settings: EnhancerSettings) {
        self.hardware = hardware
        on = Atomic(Self.effective(settings, hardware))
        model = Mutex(settings.model.map { URL(fileURLWithPath: $0.path) })
    }

    @inline(__always) var isEnabled: Bool { on.load(ordering: .acquiring) }
    /// Increases on every published change, so a loop can notice one with a single atomic load.
    var generation: UInt64 { changes.load(ordering: .acquiring) }
    /// The CoreML model the user chose (already checked against `LocalModelCap`), if any. Not for the render thread.
    var modelURL: URL? { model.withLock { $0 } }

    /// Makes `settings` the ones in force. Call on the main thread; observers are told through `.enhancerSettingsChanged`.
    func publish(_ settings: EnhancerSettings) {
        model.withLock { $0 = settings.model.map { URL(fileURLWithPath: $0.path) } }
        on.store(Self.effective(settings, hardware), ordering: .releasing)
        _ = changes.wrappingAdd(1, ordering: .releasing)
        if Thread.isMainThread { NotificationCenter.default.post(name: .enhancerSettingsChanged, object: self) }
        else { DispatchQueue.main.async { NotificationCenter.default.post(name: .enhancerSettingsChanged, object: self) } }
    }

    static func effective(_ s: EnhancerSettings, _ hw: HostHardware) -> Bool { s.enabled && hw.audioEnhancerBlocker == nil }
}

/// What the real-time audio enhancer engine reports, for the settings card.
struct EnhancerStatusSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case off
        case loading
        /// The model is loaded and timed; nothing lossy is playing.
        case ready
        /// The neural model is producing the audio.
        case active
        /// The classic sinc resampler is producing the audio, and why (no model chosen, missed deadline, model failed…).
        case bypassed(String)
    }
    var state: State
    /// Processing windows rendered by the model, and by the classic fallback.
    var windowsNeural: UInt64
    var windowsFallback: UInt64
    /// Inference time ÷ the audio duration of a window: above 1 the model cannot keep up.
    var realTimeFactor: Double
    var lastError: String?
}

/// The engine registers a reader here once; the card polls it twice a second while it is visible.
final class EnhancerStatusBoard: Sendable {
    static let shared = EnhancerStatusBoard()
    private let source = Mutex<(@Sendable () -> EnhancerStatusSnapshot)?>(nil)

    func register(_ reader: @escaping @Sendable () -> EnhancerStatusSnapshot) { source.withLock { $0 = reader } }
    func unregister() { source.withLock { $0 = nil } }
    func snapshot() -> EnhancerStatusSnapshot? { source.withLock { $0 }?() }
}

/// Audio settings: the enhancer's switch, its model and what is producing the audio right now.
struct EnhancerCard: View {
    @State private var settings = EnhancerSettings.load()
    @State private var note: String?
    @State private var busy = false
    private let gate = EnhancerGate.shared

    var body: some View {
        Card(title: "Real-time audio enhancer", subtitle: "Neural upscaling of lossy streams and files (internet radio, podcasts, MP3, AAC), on this Mac only. Changes the samples, so it is off by default") {
            let blocker = gate.hardware.audioEnhancerBlocker
            Toggle("Enhance lossy sources", isOn: Binding(get: { settings.enabled }, set: { settings.enabled = $0; apply() })).disabled(blocker != nil)
            if let blocker { Note(text: blocker) }
            else {
                if settings.enabled { EnhancerStatusLine() }
                HStack(spacing: 10) {
                    Text(settings.model.map { "\($0.name) · \(LocalModelInspector.formatParameters($0.parameters)) parameters · \(formatBytes64($0.bytes))" } ?? "No model chosen. Until then lossy sources use the classic resampler.")
                        .font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Choose CoreML Model…") { choose() }.disabled(busy)
                    if settings.model != nil { Button("Remove") { settings.model = nil; apply() } }
                }
                if let note { Note(text: note) }
                Note(text: "A CoreML .mlpackage or .mlmodelc of at most one billion parameters. Lossless files stay bit-perfect, and the enhancer falls back to the classic sinc resampler the moment it cannot keep up.")
            }
        }
    }

    private func apply() { settings.save(); gate.publish(settings) }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a CoreML model (.mlpackage or .mlmodelc)"; panel.prompt = "Check Model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; note = nil
        Task {
            // reading headers is quick, but a model on a network drive is not: keep it off the main thread
            let result: Result<LocalModelInfo, Error> = await Task.detached(priority: .userInitiated) { Result { try LocalModelInspector.inspect(url) } }.value
            busy = false
            switch result {
            case .failure(let e): note = e.localizedDescription
            case .success(let info):
                if let why = LocalModelInspector.verdict(info).reason { note = why }
                else { settings.model = LocalModelSelection(info); note = "\(info.name) is ready."; apply() }
            }
        }
    }
}

/// One line under the enhancer's switch: what is producing the audio right now.
struct EnhancerStatusLine: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            if let s = EnhancerStatusBoard.shared.snapshot() {
                HStack(spacing: 8) {
                    Circle().fill(color(s)).frame(width: 7, height: 7)
                    Text(text(s)).font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).lineLimit(2)
                    if s.windowsNeural + s.windowsFallback > 0 {
                        Text("\(s.windowsNeural) neural · \(s.windowsFallback) classic").font(Typo.mono(11)).foregroundStyle(Brand.inkTertiary)
                    }
                }
            } else {
                Text("Starting the enhancer…").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary)
            }
        }
    }

    private func color(_ s: EnhancerStatusSnapshot) -> Color {
        switch s.state { case .active: .green; case .loading: .yellow; case .ready: Brand.accent; case .bypassed: .orange; case .off: .gray }
    }

    private func text(_ s: EnhancerStatusSnapshot) -> String {
        let rtf = s.realTimeFactor > 0 ? String(format: " · %.2f× real time", s.realTimeFactor) : ""
        switch s.state {
        case .off: return "Not running"
        case .loading: return "Loading the model…"
        case .ready: return "Ready: starts with the next lossy stream or file (internet radio, podcasts, MP3, AAC)"
        case .active: return "Neural upscaling" + rtf
        case .bypassed(let why): return "Classic resampler (\(why))" + (s.lastError.map { ": \($0)" } ?? "")
        }
    }
}

// MARK: - Local model check

/// The hard limits on a model the user loads to run on this Mac. They keep a model from taking the memory the audio engine needs:
/// a model over the cap is refused before anything is loaded.
enum LocalModelCap {
    /// At most one billion parameters.
    static let maxParameters: Int64 = 1_000_000_000
    /// At most 1.5 GiB of weights on disk.
    static let maxBytes: Int64 = 1_610_612_736
}

struct LocalModelInfo: Equatable, Sendable {
    var url: URL
    var name: String
    var parameters: Int64
    /// CoreML does not publish a count, so it is estimated from the weight file at two bytes per weight (FP16).
    var bytes: Int64
}

enum LocalModelVerdict: Equatable, Sendable {
    case accepted
    case rejected(String)
    var isAccepted: Bool { self == .accepted }
    var reason: String? { if case .rejected(let r) = self { return r }; return nil }
}

enum LocalModelError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupported(String)
    var errorDescription: String? { switch self { case .unreadable(let m), .unsupported(let m): m } }
}

enum LocalModelInspector {
    static func inspect(_ url: URL) throws -> LocalModelInfo {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” could not be found.") }
        switch url.pathExtension.lowercased() {
        case "mlpackage", "mlmodelc": return try inspectCoreML(url)
        case "mlmodel": throw LocalModelError.unsupported("Uncompiled .mlmodel files are not loaded directly: save the model as an .mlpackage (Core ML Tools) and choose that.")
        default: throw LocalModelError.unsupported("“\(url.lastPathComponent)” is not a model Aureon can load. Choose a CoreML .mlpackage or .mlmodelc.")
        }
    }

    /// Whether the model passes the cap.
    static func verdict(_ info: LocalModelInfo) -> LocalModelVerdict {
        if info.parameters > LocalModelCap.maxParameters {
            return .rejected("\(info.name) has \(formatParameters(info.parameters)) parameters. Local models are limited to \(formatParameters(LocalModelCap.maxParameters)), so the audio engine always keeps the memory it needs.")
        }
        if info.bytes > LocalModelCap.maxBytes {
            return .rejected("\(info.name) needs \(formatBytes64(info.bytes)) of memory for its weights; the limit is \(formatBytes64(LocalModelCap.maxBytes)).")
        }
        return .accepted
    }

    static func inspectCoreML(_ url: URL) throws -> LocalModelInfo {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” could not be read.") }
        var total: Int64 = 0, weights: Int64 = 0
        var sawModel = false
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            let s = Int64(v?.fileSize ?? 0)
            total += s
            let n = f.lastPathComponent
            if f.pathExtension == "bin" && f.path.contains("/weights") { weights += s }
            if n == "model.mlmodel" || n == "model.mil" || n == "coremldata.bin" || n == "Manifest.json" { sawModel = true }
        }
        guard sawModel else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” does not look like a CoreML model.") }
        return LocalModelInfo(url: url, name: url.deletingPathExtension().lastPathComponent, parameters: (weights > 0 ? weights : total) / 2, bytes: total)
    }

    static func formatParameters(_ n: Int64) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.0fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }
}

func formatBytes64(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }

import SwiftUI
import Synchronization

/// What the real-time audio enhancer engine (`Upscaler/`) reports, for the Intelligence page.
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

/// The engine registers a reader here once; the page polls it twice a second while the enhancer card is visible. Decoupled this way, the
/// settings side and the engine build and test independently.
final class EnhancerStatusBoard: Sendable {
    static let shared = EnhancerStatusBoard()
    private let source = Mutex<(@Sendable () -> EnhancerStatusSnapshot)?>(nil)

    func register(_ reader: @escaping @Sendable () -> EnhancerStatusSnapshot) { source.withLock { $0 = reader } }
    func unregister() { source.withLock { $0 = nil } }
    func snapshot() -> EnhancerStatusSnapshot? { source.withLock { $0 }?() }
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

import SwiftUI
import AppKit

/// Waveform overviews for the interface. Work happens one file at a time on a background task, newest request first, so skipping through
/// an album never piles up decodes; results are published on the main thread.
@MainActor
final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()

    @Published private(set) var overviews: [String: WaveformOverview] = [:]
    private var order: [String] = []
    private var queued = Set<String>()
    private var unavailable = Set<String>()
    private let gate = ArtLoadGate(limit: 1)
    private let cache: WaveformCache
    let keep: Int

    init(cache: WaveformCache = .shared, keep: Int = 48) { self.cache = cache; self.keep = keep }

    func overview(_ path: String?) -> WaveformOverview? { path.flatMap { overviews[$0] } }
    func isUnavailable(_ path: String?) -> Bool { path.map { unavailable.contains($0) || !WaveformBuilder.supports(path: $0) } ?? true }

    /// Asks for the overview of `path`. Requests made later run first: ask for the next track before the current one.
    func request(_ path: String?) {
        guard let path, overviews[path] == nil, !queued.contains(path), !unavailable.contains(path) else { return }
        guard WaveformBuilder.supports(path: path) else { unavailable.insert(path); return }
        queued.insert(path)
        let cache = cache
        gate.submit { [weak self] done in
            Task { @MainActor in
                let result = await Task.detached(priority: .utility) { cache.overview(path: path) }.value
                guard let self else { done(); return }
                self.queued.remove(path)
                if let result { self.insert(result, for: path) } else { self.unavailable.insert(path) }
                done()
            }
        }
    }

    private func insert(_ o: WaveformOverview, for path: String) {
        withAnimation(.smooth(duration: 0.45)) { overviews[path] = o }
        order.removeAll { $0 == path }; order.append(path)
        while order.count > keep { overviews[order.removeFirst()] = nil }
    }
}

/// How the scrubber maps between the pointer, the playhead and time. Pure, so it can be tested.
enum ScrubMath {
    static func fraction(position: Double, duration: Double) -> Double {
        guard duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }
    static func time(x: Double, width: Double, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return min(duration, max(0, x / width * duration))
    }
    /// Scrolling over the waveform: each wheel click moves `secondsPerNotch`, at most 30 s per event, never past either end.
    static func scrolled(from t: Double, notches: Double, duration: Double, secondsPerNotch: Double = 5) -> Double {
        guard duration > 0, notches.isFinite else { return t }
        return min(duration, max(0, t + max(-30, min(30, notches * secondsPerNotch))))
    }
    /// Number of bars that fit, for a bar `pitch` points apart.
    static func columns(width: Double, pitch: Double) -> Int { pitch > 0 && width > 0 ? max(1, Int(width / pitch)) : 0 }
}

// MARK: - Drawing

/// The static part of the waveform: mirrored bars, a dim outer peak and a solid inner RMS body. It depends only on the data, the size and
/// the colours, never on the playhead, so it is drawn once and then only masked as the song plays.
struct WaveformArt: View, Equatable {
    let overview: WaveformOverview?
    let pitch: CGFloat            // distance between bar centres
    let bar: CGFloat              // bar width
    let peakColor: Color
    let bodyColor: Color
    var glow: Color? = nil

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let n = ScrubMath.columns(width: Double(size.width), pitch: Double(pitch))
            if let o = overview, !o.isEmpty {
                let cols = o.columns(n)
                var outer = Path(), inner = Path()
                for (i, c) in cols.enumerated() {
                    let x = CGFloat(i) * pitch + (pitch - bar) / 2
                    let ph = max(1.2, CGFloat(c.peak) * (size.height - 1)), rh = max(1.2, CGFloat(c.rms) * (size.height - 1))
                    outer.addRoundedRect(in: CGRect(x: x, y: mid - ph / 2, width: bar, height: ph), cornerSize: CGSize(width: bar / 2, height: bar / 2))
                    inner.addRoundedRect(in: CGRect(x: x, y: mid - rh / 2, width: bar, height: rh), cornerSize: CGSize(width: bar / 2, height: bar / 2))
                }
                if let glow { ctx.addFilter(.shadow(color: glow, radius: 3.5)) }
                ctx.fill(outer, with: .color(peakColor))
                ctx.fill(inner, with: .color(bodyColor))
            } else {
                // no overview (radio, DSD, cloud, still measuring): a row of fine dots, like an idle level meter
                var dots = Path()
                for i in 0..<n { dots.addEllipse(in: CGRect(x: CGFloat(i) * pitch + (pitch - 1.6) / 2, y: mid - 0.8, width: 1.6, height: 1.6)) }
                if let glow { ctx.addFilter(.shadow(color: glow, radius: 2)) }
                ctx.fill(dots, with: .color(bodyColor))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Scrubber

/// The waveform seek control: the played part lights up in the cover's accent, a playhead glides along at display rate between the engine's
/// position updates, hovering shows the time under the pointer, dragging scrubs, and scrolling over it seeks (a trackpad gesture that starts on
/// it, or the mouse wheel with ⌥). Any other scrolling is passed on to the page, through `ScrollRouter`.
struct WaveformScrubber: View {
    enum Style { case bar, stage }

    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var progress: ProgressModel
    @ObservedObject private var store = WaveformStore.shared
    var style: Style = .bar
    var tint: Color

    @StateObject private var hoverX = Box<CGFloat?>(nil)
    @StateObject private var dragging = Box(false)
    @StateObject private var commit = Box<DispatchWorkItem?>(nil)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pitch: CGFloat { style == .bar ? 3 : 4 }
    private var barWidth: CGFloat { style == .bar ? 1.8 : 2.4 }

    var body: some View {
        let item = m.focusItem
        let path = item.flatMap { $0.isStream ? nil : $0.path }
        let live = m.status.sourceInfo?.isLive == true && m.isActive
        let enabled = m.isActive && !live && progress.duration > 0
        let dur = max(progress.duration, 0.001)
        let f = CGFloat(ScrubMath.fraction(position: m.scrub ?? progress.position, duration: dur))
        let ov = store.overview(path)

        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .leading) {
                WaveformArt(overview: ov, pitch: pitch, bar: barWidth, peakColor: .white.opacity(0.16), bodyColor: .white.opacity(style == .bar ? 0.34 : 0.4))
                    .equatable()
                WaveformArt(overview: ov, pitch: pitch, bar: barWidth, peakColor: tint.opacity(0.45), bodyColor: tint, glow: tint.opacity(0.55))
                    .equatable()
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * f)) }
                    .opacity(enabled || live ? 1 : 0.35)
                if let x = hoverX.v, enabled, !dragging.v {
                    Rectangle().fill(.white.opacity(0.55)).frame(width: 1, height: h).offset(x: min(max(0, x), w) - 0.5).allowsHitTesting(false)
                }
                if enabled {
                    Capsule().fill(.white).frame(width: style == .bar ? 2 : 2.5, height: h + (style == .bar ? 2 : 6))
                        .shadow(color: tint.opacity(0.9), radius: 4).shadow(color: .black.opacity(0.4), radius: 1)
                        .offset(x: w * f - 1)
                        .allowsHitTesting(false)
                }
                if let x = hoverX.v, enabled {
                    let t = dragging.v ? (m.scrub ?? progress.position) : ScrubMath.time(x: Double(x), width: Double(w), duration: dur)
                    Text(clock(t)).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(Capsule().fill(.black.opacity(0.78))).overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
                        .foregroundStyle(.white).fixedSize()
                        .offset(x: min(max(0, (dragging.v ? w * f : x) - 22), max(0, w - 46)), y: style == .bar ? -(h / 2 + 12) : -(h / 2 + 16))
                        .allowsHitTesting(false).transition(.opacity)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .animation(dragging.v || reduceMotion ? nil : .linear(duration: 0.12), value: f)
            .animation(.easeOut(duration: 0.12), value: hoverX.v == nil)
            .onContinuousHover { phase in
                switch phase { case .active(let p): hoverX.v = p.x; case .ended: hoverX.v = nil }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                guard enabled else { return }
                dragging.v = true
                hoverX.v = d.location.x
                m.scrub = ScrubMath.time(x: Double(d.location.x), width: Double(w), duration: dur)
            }.onEnded { _ in
                dragging.v = false
                if let t = m.scrub { if enabled { m.player.send(.seekTo(t)) }; m.scrub = nil }
            })
            .scrollAdjustable(hovering: hoverX.v != nil && enabled) { notches in
                // seek after the gesture settles, not on every event of a trackpad swipe
                let target = ScrubMath.scrolled(from: m.scrub ?? progress.position, notches: notches, duration: dur)
                let model = m
                model.scrub = target
                commit.v?.cancel()
                let work = DispatchWorkItem { [weak model] in
                    MainActor.assumeIsolated {
                        guard let model, let t = model.scrub else { return }
                        model.player.send(.seekTo(t)); model.scrub = nil
                    }
                }
                commit.v = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
                return true
            }
        }
        .frame(height: style == .bar ? 16 : 46)
        .onAppear { prefetch() }
        .onChange(of: path) { _, _ in prefetch() }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(live ? "Live" : "\(clock(m.scrub ?? progress.position)) of \(clock(dur))"))
        .accessibilityAdjustableAction { dir in
            guard enabled else { return }
            m.player.send(.seekTo(ScrubMath.scrolled(from: progress.position, notches: dir == .increment ? 2 : -2, duration: dur)))
        }
    }

    /// The current track's waveform, and the next one's so a track change shows its waveform at once. The current track is asked for last,
    /// which makes it run first.
    private func prefetch() {
        let items = m.items
        if let at = items.firstIndex(where: { $0.id == m.focusItem?.id }), at + 1 < items.count, !items[at + 1].isStream { store.request(items[at + 1].path) }
        if let item = m.focusItem, !item.isStream { store.request(item.path) }
    }
}

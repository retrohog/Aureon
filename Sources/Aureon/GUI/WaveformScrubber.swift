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

/// The static part of the waveform: fine upright bars, a dim outer peak and a solid inner RMS body. It depends only on the data, the size and
/// the colours, never on the playhead, so it is drawn once and then only masked as the song plays. The played part is filled with the accent
/// gradient (`gradient`), a single linear sweep across the width.
struct WaveformArt: View, Equatable {
    let overview: WaveformOverview?
    let pitch: CGFloat            // distance between bar centres
    let bar: CGFloat              // bar width
    let peakColor: Color
    let bodyColor: Color
    var gradient: [Color]? = nil

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let n = ScrubMath.columns(width: Double(size.width), pitch: Double(pitch))
            func shading(_ base: Color, _ alpha: Double) -> GraphicsContext.Shading {
                if let gradient { return .linearGradient(Gradient(colors: gradient.map { $0.opacity(alpha) }), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)) }
                return .color(base)
            }
            if let o = overview, !o.isEmpty {
                let cols = o.columns(n)
                var outer = Path(), inner = Path()
                for (i, c) in cols.enumerated() {
                    let x = CGFloat(i) * pitch + (pitch - bar) / 2
                    let ph = max(1, CGFloat(c.peak) * (size.height - 1)), rh = max(1, CGFloat(c.rms) * (size.height - 1))
                    outer.addRect(CGRect(x: x, y: mid - ph / 2, width: bar, height: ph))
                    inner.addRect(CGRect(x: x, y: mid - rh / 2, width: bar, height: rh))
                }
                ctx.fill(outer, with: shading(peakColor, 0.45))
                ctx.fill(inner, with: shading(bodyColor, 1))
            } else {
                // no overview (radio, DSD, cloud, still measuring): a row of fine dots, like an idle level meter
                var dots = Path()
                for i in 0..<n { dots.addRect(CGRect(x: CGFloat(i) * pitch + (pitch - 1) / 2, y: mid - 0.5, width: 1, height: 1)) }
                ctx.fill(dots, with: shading(bodyColor, 1))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The waveform as one fine line: the outline of the loudness above and below a quiet centre, two one-point strokes, nothing filled.
struct WaveformLineArt: View, Equatable {
    let overview: WaveformOverview?
    let color: Color
    var gradient: [Color]? = nil

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let n = max(2, Int(size.width / 2))
            var top = Path(), bottom = Path()
            if let o = overview, !o.isEmpty {
                for (i, c) in o.columns(n).enumerated() {
                    let x = CGFloat(i) / CGFloat(n - 1) * size.width
                    let a = max(0.5, CGFloat(c.rms * 0.5 + c.peak * 0.5) * (size.height / 2 - 1))
                    if i == 0 { top.move(to: CGPoint(x: x, y: mid - a)); bottom.move(to: CGPoint(x: x, y: mid + a)) }
                    else { top.addLine(to: CGPoint(x: x, y: mid - a)); bottom.addLine(to: CGPoint(x: x, y: mid + a)) }
                }
            } else {
                top.move(to: CGPoint(x: 0, y: mid)); top.addLine(to: CGPoint(x: size.width, y: mid))
            }
            let shading: GraphicsContext.Shading = gradient.map { .linearGradient(Gradient(colors: $0), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)) } ?? .color(color)
            let stroke = StrokeStyle(lineWidth: 1, lineJoin: .round)
            ctx.stroke(top, with: shading, style: stroke)
            ctx.stroke(bottom, with: shading, style: stroke)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Scrubber

/// The waveform seek control: the played part lights up in the cover's accent, a playhead glides along at display rate between the engine's
/// position updates, hovering shows the time under the pointer, dragging scrubs, and scrolling over it seeks (a trackpad gesture that starts on
/// it, or the mouse wheel with ⌥). Any other scrolling is passed on to the page, through `ScrollRouter`.
struct WaveformScrubber: View {
    enum Style { case bar, stage, line, slim }

    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var progress: ProgressModel
    @ObservedObject private var store = WaveformStore.shared
    var style: Style = .bar
    var tint: Color

    @StateObject private var hoverX = Box<CGFloat?>(nil)
    @StateObject private var dragging = Box(false)
    @StateObject private var commit = Box<DispatchWorkItem?>(nil)
    @StateObject private var pulse = Box(SeekPulse())
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pitch: CGFloat { style == .bar || style == .slim ? 3 : 4 }
    private var barWidth: CGFloat { style == .bar ? 1 : 1.5 }

    var body: some View {
        let item = m.focusItem
        let path = item.flatMap { $0.isStream ? nil : $0.path }
        let live = m.status.sourceInfo?.isLive == true && m.isActive
        let enabled = m.isActive && !live && progress.duration > 0
        let dur = max(progress.duration, 0.001)
        let f = CGFloat(ScrubMath.fraction(position: m.scrub ?? progress.position, duration: dur))
        let ov = store.overview(path)
        let wc = WaveformColors.current

        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .leading) {
                if style == .slim {
                    // the player bar's slider: a 5-point rounded track filled with the progress, and a 13-point thumb while the pointer is near
                    Capsule().fill(Brand.ink.opacity(0.18)).frame(height: 5)
                    Capsule().fill(hoverX.v != nil || dragging.v ? Brand.accent : Brand.ink.opacity(0.9)).frame(width: max(5, w * f), height: 5).opacity(enabled || live ? 1 : 0.35)
                    if enabled { Circle().fill(Brand.ink).frame(width: 13, height: 13).offset(x: min(max(0, w * f - 6.5), w - 13)).opacity(hoverX.v != nil || dragging.v ? 1 : 0).allowsHitTesting(false) }
                } else if style == .line {
                    WaveformLineArt(overview: ov, color: wc.unplayed.color).equatable()
                    WaveformLineArt(overview: ov, color: wc.played.color, gradient: [wc.played.color, wc.played2.color]).equatable()
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * f)) }
                        .opacity(enabled || live ? 1 : 0.35)
                } else {
                    WaveformArt(overview: ov, pitch: pitch, bar: barWidth, peakColor: wc.unplayed.color.opacity(0.4), bodyColor: wc.unplayed.color)
                        .equatable()
                    WaveformArt(overview: ov, pitch: pitch, bar: barWidth, peakColor: wc.played.color, bodyColor: wc.played.color, gradient: [wc.played.color, wc.played2.color])
                        .equatable()
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * f)) }
                        .opacity(enabled || live ? 1 : 0.35)
                }
                if pulse.v.count > 0, style != .slim { SeekPulseMark(x: pulse.v.x, height: h + (style == .line ? 8 : 4)).id(pulse.v.count) }
                if let x = hoverX.v, enabled, !dragging.v, style != .slim {
                    Rectangle().fill(Brand.ink.opacity(0.4)).frame(width: Metrics.hairline, height: h).offset(x: min(max(0, x), w) - 0.25).allowsHitTesting(false)
                }
                if enabled, style != .slim {
                    if style == .line {
                        Circle().fill(Brand.accent).frame(width: 6, height: 6).offset(x: w * f - 3).allowsHitTesting(false)
                    } else {
                        Rectangle().fill(Brand.accent).frame(width: 1, height: h + (style == .bar ? 4 : 8))
                            .offset(x: w * f - 0.5, y: 0)
                            .allowsHitTesting(false)
                    }
                }
                if let x = hoverX.v, enabled {
                    let t = dragging.v ? (m.scrub ?? progress.position) : ScrubMath.time(x: Double(x), width: Double(w), duration: dur)
                    Text(clock(t)).font(Typo.mono(10, .regular))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Metrics.tagRadius, style: .continuous).fill(Brand.panel2))
                        .foregroundStyle(Brand.ink).fixedSize()
                        .offset(x: min(max(0, (dragging.v ? w * f : x) - 22), max(0, w - 46)), y: style == .bar || style == .slim ? -(h / 2 + 16) : -(h / 2 + 20))
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
            }.onEnded { d in
                dragging.v = false
                if let t = m.scrub { if enabled { m.player.send(.seekTo(t)); pulse.v.fire(at: min(max(0, d.location.x), w)) }; m.scrub = nil }
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
                        pulse.v.fire(at: w * CGFloat(ScrubMath.fraction(position: t, duration: dur)))
                    }
                }
                commit.v = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
                return true
            }
        }
        .frame(height: style == .bar || style == .slim ? 16 : (style == .line ? 40 : 46))
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

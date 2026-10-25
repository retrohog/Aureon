import SwiftUI

// The Orbit layout's ring: bars that radiate from the round cover, drawn from the newest frame of the analyser, and a thin arc around them that shows how far the
// song has got and is also the seek bar (a press or a drag on the ring seeks). The sums are plain functions so they can be tested; the view only draws.

enum OrbitRing {
    /// The bars drawn around the cover. Mirrored left to right, so the ring is symmetrical.
    static let barCount = 96
    /// Redrawn at most this often (the analyser's own rate), and not at all while paused, hidden or with Reduce Motion on.
    static let frameInterval = UIRate.analyserInterval
    /// One turn of the cover when it is set to turn.
    static let spinSeconds = 40.0

    /// Whether the ring's clock stands still: nothing plays, the window is hidden, Reduce Motion is on, or the analyser is off.
    static func paused(playing: Bool, visible: Bool, reduceMotion: Bool, analyserOn: Bool) -> Bool { !playing || !visible || reduceMotion || !analyserOn }

    /// The height (0…1) of each of `count` bars, from the analyser's bands in dB (−90 … 0): the loudest band of each group, mirrored so bar `i` and bar `count − 1 − i`
    /// are the same. No bands (the analyser is off, or nothing plays) gives short even bars, a static ring.
    static func heights(bands: [Float], count: Int = barCount) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard !bands.isEmpty else { return Array(repeating: 0.12, count: count) }
        let half = max(1, count / 2)
        let per = max(1, bands.count / half)
        var side: [CGFloat] = []
        for i in 0..<half {
            let lo = min(bands.count - 1, i * per), hi = min(bands.count, lo + per)
            let v = bands[lo..<hi].max() ?? -120
            side.append(CGFloat(max(0, min(1, (Double(v) + 90) / 90))))
        }
        return (0..<count).map { i in i < half ? side[i] : side[max(0, count - 1 - i)] }
    }

    /// The radii of the ring for a square of this side: the round cover, the bars, and the progress arc outside them.
    struct Radii: Equatable { var cover: CGFloat; var barsInner: CGFloat; var barsOuter: CGFloat; var arc: CGFloat }
    static func radii(side: CGFloat) -> Radii {
        let half = side / 2
        let arc = half - 6
        let outer = arc - 12
        let inner = outer * 0.66
        return Radii(cover: inner - 10, barsInner: inner, barsOuter: outer, arc: arc)
    }

    /// Where a point is on the ring, as a share of the way round from the top, clockwise (0 … 1).
    static func fraction(of point: CGPoint, around center: CGPoint) -> Double {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        var a = atan2(dx, -dy)                      // 0 at the top, growing clockwise
        if a < 0 { a += 2 * .pi }
        return min(1, max(0, a / (2 * .pi)))
    }

    /// Whether a press at `point` is on the ring (the band of bars and the arc), not on the cover and not far outside it.
    static func hits(_ point: CGPoint, around center: CGPoint, radii r: Radii) -> Bool {
        let d = hypot(point.x - center.x, point.y - center.y)
        return d >= r.barsInner - 6 && d <= r.arc + 12
    }
}

/// The ring itself: the bars and the arc. It owns the drawing and the seeking; the cover sits inside it.
struct OrbitRingView: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var progress: ProgressModel
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var visible = Box(true)
    @StateObject private var dragging = Box(false)

    var body: some View {
        let r = OrbitRing.radii(side: side)
        let analyserOn = m.visualizerEnabled
        let playing = m.isActive && m.status.state == .playing
        let paused = OrbitRing.paused(playing: playing, visible: visible.v, reduceMotion: reduceMotion, analyserOn: analyserOn)
        TimelineView(.animation(minimumInterval: OrbitRing.frameInterval, paused: paused)) { _ in
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let bands = analyserOn && playing ? m.player.analysis.snapshot().bars : []
                let heights = OrbitRing.heights(bands: bands)
                let reach = r.barsOuter - r.barsInner
                for (i, h) in heights.enumerated() {
                    let a = 2 * Double.pi * (Double(i) + 0.5) / Double(heights.count)
                    let len = max(3, reach * h)
                    let dx = CGFloat(sin(a)), dy = -CGFloat(cos(a))
                    var p = Path()
                    p.move(to: CGPoint(x: center.x + dx * r.barsInner, y: center.y + dy * r.barsInner))
                    p.addLine(to: CGPoint(x: center.x + dx * (r.barsInner + len), y: center.y + dy * (r.barsInner + len)))
                    ctx.stroke(p, with: .color(Brand.accent.opacity(0.35 + 0.6 * Double(h))), style: StrokeStyle(lineWidth: max(2, side * 0.008), lineCap: .round))
                }
                // the arc: the whole way round faintly, the part played in the accent, and a point where the song is
                let dur = max(progress.duration, 0.001)
                let f = CGFloat(ScrubMath.fraction(position: m.scrub ?? progress.position, duration: dur))
                var track = Path(); track.addArc(center: center, radius: r.arc, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
                ctx.stroke(track, with: .color(Brand.ink.opacity(0.16)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                if m.isActive && f > 0 {
                    var played = Path(); played.addArc(center: center, radius: r.arc, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * Double(f)), clockwise: false)
                    ctx.stroke(played, with: .color(Brand.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    let a = 2 * Double.pi * Double(f)
                    let knob = CGPoint(x: center.x + CGFloat(sin(a)) * r.arc, y: center.y - CGFloat(cos(a)) * r.arc)
                    ctx.fill(Path(ellipseIn: CGRect(x: knob.x - 6, y: knob.y - 6, width: 12, height: 12)), with: .color(Brand.accent))
                }
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { d in
            let center = CGPoint(x: side / 2, y: side / 2)
            guard m.isActive, progress.duration > 0, dragging.v || OrbitRing.hits(d.startLocation, around: center, radii: r) else { return }
            dragging.v = true
            m.scrub = OrbitRing.fraction(of: d.location, around: center) * progress.duration
        }.onEnded { d in
            defer { dragging.v = false }
            guard dragging.v, let t = m.scrub else { return }
            m.player.send(.seekTo(t)); m.scrub = nil
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { n in
            visible.v = (n.object as? NSWindow)?.occlusionState.contains(.visible) ?? true
        }
        .layoutProbe("orbit.ring")
        .accessibilityElement().accessibilityLabel("Playback position")
        .accessibilityValue(Text("\(clock(m.scrub ?? progress.position)) of \(clock(progress.duration))"))
        .accessibilityAdjustableAction { dir in
            guard m.isActive, progress.duration > 0 else { return }
            m.player.send(.seekTo(ScrubMath.scrolled(from: progress.position, notches: dir == .increment ? 2 : -2, duration: progress.duration)))
        }
    }
}

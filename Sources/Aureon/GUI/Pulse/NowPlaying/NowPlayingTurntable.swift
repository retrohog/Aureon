import SwiftUI

// Turntable: a fixed square on the left with a record on a platter (the cover is its label) and a tonearm; on the right the song's words and the next songs.
// The record turns while the music plays (never with Reduce Motion, never while paused) and the arm follows the song's position from the outer groove to the inner.
// The turning is a rotation of a flattened layer on a display-rate timeline that stops when it is not needed, so it costs the main thread almost nothing; the
// sums for the angle of the record and of the arm are plain functions so they can be tested.

enum TTSpin {
    /// Seconds for one turn of the record.
    static let secondsPerTurn = 4.0
    /// Whether the record turns: the music plays and the listener has not asked the interface to hold still.
    static func spinning(playing: Bool, reduceMotion: Bool) -> Bool { playing && !reduceMotion }
    /// The record's angle in degrees: where it stopped (`base`), plus the turning since it set off at `since` (nil while it stands still).
    static func angle(base: Double, since: Date?, now: Date) -> Double {
        let run = since.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return (base + 360 * run / secondsPerTurn).truncatingRemainder(dividingBy: 360)
    }
}

/// Where the arm is. Lengths are shares of the square's side, angles are radians measured as `atan2(dy, dx)` with y growing downward.
enum TTArm {
    static let pivot = CGPoint(x: 0.86, y: 0.12)
    static let length = 0.70
    static let centre = CGPoint(x: 0.5, y: 0.5)
    /// The record's radius, its outermost and innermost groove.
    static let record = 0.42, outer = 0.405, inner = 0.19
    /// How far the arm swings out to rest when nothing plays.
    static let lift = 12.0 * Double.pi / 180

    /// The direction from the pivot at which the needle is `r` from the centre of the record (the lower solution, so the arm lies down the right of the record).
    static func angle(radius r: Double) -> Double {
        let dx = Double(centre.x - pivot.x), dy = Double(centre.y - pivot.y)
        let d = (dx * dx + dy * dy).squareRoot()
        let phi = atan2(dy, dx)
        let cosA = max(-1, min(1, (length * length + d * d - r * r) / (2 * length * d)))
        return phi - acos(cosA)
    }
    /// The needle's distance from the centre after `fraction` of the song.
    static func radius(fraction f: Double) -> Double { outer - (outer - inner) * min(1, max(0, f)) }
    /// The arm's direction: on the record at the song's place while it is loaded, swung out beside it when nothing is.
    static func angle(fraction f: Double, engaged: Bool) -> Double { engaged ? angle(radius: radius(fraction: f)) : angle(radius: outer) - lift }
    /// The needle's place in a square of this side.
    static func tip(angle a: Double, side: CGFloat) -> CGPoint {
        CGPoint(x: (pivot.x + CGFloat(length * cos(a))) * side, y: (pivot.y + CGFloat(length * sin(a))) * side)
    }
}

extension TTArm {
    /// The share of the song the needle stands at when it is `r` from the centre of the record (outer groove 0, inner groove 1).
    static func fraction(radius r: Double) -> Double { min(1, max(0, (outer - r) / (outer - inner))) }
    /// How far a point of the square (side `side`) is from the centre of the record, in shares of the side.
    static func radius(of p: CGPoint, side: CGFloat) -> Double { Double(hypot(p.x / side - centre.x, p.y / side - centre.y)) }
}

/// What dropping the needle somewhere means, and what dragging the platter means.
enum TTDrag {
    /// Slack outside the grooves in which a dropped needle still counts as on the record.
    static let slack = 0.03
    /// The time a needle dropped at `p` seeks to, or nil when it lands off the record.
    static func seekTime(at p: CGPoint, side: CGFloat, duration: Double) -> Double? {
        let r = TTArm.radius(of: p, side: side)
        guard duration > 0, r <= TTArm.outer + slack, r >= TTArm.inner - slack else { return nil }
        return TTArm.fraction(radius: r) * duration
    }
    /// How far a scratch of `degrees` (clockwise positive) moves the song: one turn is one `TTSpin.secondsPerTurn`.
    static func scratchSeconds(degrees: Double) -> Double { degrees / 360 * TTSpin.secondsPerTurn }
    /// The smallest scratch that seeks on release (a touch is not a seek).
    static let minimumScratch = 3.0
    /// The angle of `p` around the record's centre, in degrees (clockwise positive on screen).
    static func angle(of p: CGPoint, side: CGFloat) -> Double {
        atan2(Double(p.y / side - TTArm.centre.y), Double(p.x / side - TTArm.centre.x)) * 180 / .pi
    }
    /// The change from angle `a` to `b`, taken the short way round (so crossing 180° is not a jump).
    static func delta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }
    /// Whether a drag that began at `p` takes the arm: the point is near the arm's line from the pivot to the needle.
    static func grabsArm(at p: CGPoint, side: CGFloat, armAngle: Double) -> Bool {
        let a = CGPoint(x: TTArm.pivot.x * side, y: TTArm.pivot.y * side), b = TTArm.tip(angle: armAngle, side: side)
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let len2 = max(1, ab.x * ab.x + ab.y * ab.y)
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2))
        let nearest = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
        return hypot(p.x - nearest.x, p.y - nearest.y) <= side * 0.05
    }
}

/// The motor: the platter's speed moves toward its target at a fixed rate, so it spins up and spools down in about `ramp` seconds.
enum TTMotor {
    static let ramp = 0.3
    /// Degrees per second at the target speed (the 33 setting).
    static let cruise = 360 / TTSpin.secondsPerTurn
    /// One step of `dt` seconds. With Reduce Motion the speed jumps to the target.
    static func step(speed: Double, target: Double, dt: Double, reduceMotion: Bool) -> Double {
        if reduceMotion { return target }
        let maxChange = cruise / ramp * max(0, dt)
        if abs(target - speed) <= maxChange { return target }
        return speed + (target > speed ? maxChange : -maxChange)
    }
}

struct NPTurntable: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo

    var body: some View {
        NPFrame(c, content: { size in
            columns(size).padding(.horizontal, c.margin).padding(.top, 14 * c.s)
        }, dock: {
            NPDock(c, seek: .slim, left: { HStack(spacing: 4) { NPActions(size: 44) } }, right: { NPCluster(showsChip: false) })
        })
    }

    private func columns(_ size: CGSize) -> some View {
        let s = c.s
        let inner = size.width - 2 * c.margin
        let item = m.focusItem
        let tags = m.look.showSignalTags
        let plan = NPTurntablePlan.make(title: m.focusDisplay?.title ?? "Nothing playing", inner: inner, height: size.height - 14 * s, s: s, tags: tags)
        return HStack(alignment: .top, spacing: plan.gutter) {
            VStack(spacing: 12 * s) {
                Spacer(minLength: 0)
                TurntableDeck(side: plan.deckSide).frame(width: plan.deckSide, height: plan.deckSide)
                if plan.showsInfo { deckInfo(plan, item) }
                Spacer(minLength: 0)
            }
            .frame(width: plan.leftWidth).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: plan.gap) {
                Text(PosterMath.label(item: item, items: m.items)).npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                    .frame(height: plan.labelHeight, alignment: .leading)
                Text(m.focusDisplay?.title ?? "Nothing playing").font(Typo.face(plan.titleSize, .bold)).tracking(-plan.titleSize * 0.03).lineSpacing(-plan.titleSize * 0.06)
                    .lineLimit(2).minimumScaleFactor(0.6).foregroundStyle(Brand.ink).frame(width: plan.rightWidth, height: plan.titleHeight, alignment: .topLeading)
                names(item).frame(height: plan.namesHeight, alignment: .topLeading)
                if tags { NPTags().frame(height: plan.tagsHeight, alignment: .topLeading) }
                NPLyricArea(size: 34, height: plan.lyricHeight)
                VStack(alignment: .leading, spacing: 4 * s) {
                    Text("Up next").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary).frame(height: plan.upNextHeader - 4 * s, alignment: .leading)
                    NPUpNext(limit: plan.upNextRows, cover: 44)
                }
                .frame(height: plan.upNextHeight, alignment: .topLeading).clipped()
            }
            .frame(width: plan.rightWidth, alignment: .topLeading)
        }
    }

    /// Under the deck when the column is taller than the deck is wide: the album and the first credits, in a line or two.
    private func deckInfo(_ plan: NPTurntablePlan, _ item: QueueItem?) -> some View {
        var parts: [String] = []
        if let item, !item.album.isEmpty { parts.append(item.album) }
        if let y = item?.year { parts.append(String(y)) }
        let credits = PosterMath.creditRows(info.credits)
        return VStack(spacing: 4) {
            Text(parts.joined(separator: " · ")).npFont(15, .medium).lineLimit(1)
            ForEach(credits) { l in Text("\(l.label): \(l.value)").npFont(13).foregroundStyle(Brand.inkSecondary).lineLimit(1) }
        }
        .frame(width: plan.deckSide, height: plan.infoHeight, alignment: .top)
    }

    private func names(_ item: QueueItem?) -> some View {
        let d = m.focusDisplay
        var tail: [String] = []
        if let item, !item.album.isEmpty { tail.append(item.album) }
        if let y = item?.year { tail.append(String(y)) }
        return (Text(d?.artist ?? "").foregroundColor(Brand.ink) + Text(tail.isEmpty ? "" : ((d?.artist.isEmpty ?? true) ? "" : "  ·  ") + tail.joined(separator: "  ·  ")).foregroundColor(Brand.inkSecondary))
            .npFont(21, .medium).lineLimit(2)
    }
}

/// The platter's angle and speed, stepped on every frame by the motor. Read and written only by the display-rate timeline and by the gestures; not observable, so
/// turning costs the main thread almost nothing.
final class TurntableSpin {
    private(set) var angle = 0.0
    private(set) var speed = 0.0
    private var last: Date?
    /// Whether the platter has come to rest at a target of zero (the timeline can stop).
    var isSettled: Bool { speed == 0 }

    /// Moves to `now`: the speed ramps toward `target`, the angle follows the speed.
    func advance(to now: Date, target: Double, reduceMotion: Bool) {
        defer { last = now }
        guard let last else { return }
        let dt = min(0.1, max(0, now.timeIntervalSince(last)))
        let next = TTMotor.step(speed: speed, target: target, dt: dt, reduceMotion: reduceMotion)
        angle = (angle + (speed + next) / 2 * dt).truncatingRemainder(dividingBy: 360)
        speed = next
    }
    /// The platter held by a hand: it moves with the pointer, and its speed is the pointer's.
    func drag(by degrees: Double, dt: Double) {
        angle = (angle + degrees).truncatingRemainder(dividingBy: 360)
        let v = dt > 0 ? degrees / dt : 0
        speed = max(-1500, min(1500, 0.6 * speed + 0.4 * v))
    }
    func release(reduceMotion: Bool, target: Double) { if reduceMotion { speed = target }; last = nil }
}

private enum TTHover { case none, arm, platter }

/// The part of the deck that answers a hand: the record, and the arm from its pivot to the needle. A click anywhere else on the plinth (the buttons, the
/// empty corners) is not the deck's.
struct TTHitShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = rect.width
        var p = Path()
        let r = side * TTArm.record * 1.04
        p.addEllipse(in: CGRect(x: side * TTArm.centre.x - r, y: side * TTArm.centre.y - r, width: 2 * r, height: 2 * r))
        // the arm sweeps from the outer groove to the inner one (and rests a little outside): its whole sweep is the hand's, however far along the song is
        let a = CGPoint(x: TTArm.pivot.x * side, y: TTArm.pivot.y * side), w = side * 0.05
        for angle in [TTArm.angle(radius: TTArm.outer) - TTArm.lift, TTArm.angle(radius: TTArm.outer), TTArm.angle(radius: (TTArm.outer + TTArm.inner) / 2), TTArm.angle(radius: TTArm.inner)] {
            let b = TTArm.tip(angle: angle, side: side)
            let len = max(1, hypot(b.x - a.x, b.y - a.y))
            // a rectangle along the arm, from the pivot to the needle (the same winding as the ellipse, so overlaps add up and never cancel)
            let angleToTip = atan2(b.y - a.y, b.x - a.x)
            p.addPath(Path(CGRect(x: 0, y: -w, width: len, height: 2 * w)).applying(CGAffineTransform(rotationAngle: angleToTip).concatenating(CGAffineTransform(translationX: a.x, y: a.y))))
        }
        return p
    }
}

/// The plinth, the record on its platter and the tonearm, in a square: a deck that can be played with. Drag the arm and drop it on the record to seek, grab the
/// platter to scratch (the audio follows the platter), press the power button to start or stop the motor. The arrow keys move the needle when the deck has the
/// keyboard focus. The deck does not watch the playhead: the arm view does, so the platter's own view is not redrawn with every tick of the song.
struct TurntableDeck: View {
    let side: CGFloat
    @EnvironmentObject var m: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("aureon.turntable.rpm") private var rpm = 33
    @AppStorage("aureon.turntable.scratchSound") private var scratchSound = true
    @FocusState private var focused: Bool
    @State private var spin = TurntableSpin()
    @State private var running = true
    @State private var hover = TTHover.none
    /// The arm held by the pointer: the radius it is at (shares of the side), and whether playback was running when it was lifted.
    @State private var armRadius: Double?
    @State private var wasPlaying = false
    /// A scratch in progress: the pointer's last angle and time, and the total turned.
    @State private var scratch: (angle: Double, time: Date, total: Double)?
    @State private var coast: Task<Void, Never>?

    private var playing: Bool { m.isActive && m.status.state == .playing }
    private var target: Double { playing && armRadius == nil && scratch == nil ? TTMotor.cruise * (rpm == 45 ? 1.35 : 1) : 0 }
    private var progress: ProgressModel { m.progress }
    private var armAngleNow: Double {
        let frac = progress.duration > 0 ? (m.scrub ?? progress.position) / progress.duration : 0
        return armRadius.map { TTArm.angle(radius: $0) } ?? TTArm.angle(fraction: frac, engaged: m.isActive && m.focusItem?.isStream != true)
    }

    var body: some View {
        let record = side * TTArm.record * 2
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.035, style: .continuous).fill(Brand.panel2)
                .overlay(RoundedRectangle(cornerRadius: side * 0.035, style: .continuous).strokeBorder(Brand.rule, lineWidth: Metrics.hairline))
                .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
            Circle().fill(Brand.ink.opacity(hover == .platter ? 0.12 : 0.07)).frame(width: record + side * 0.05, height: record + side * 0.05)
            TimelineView(.animation(minimumInterval: nil, paused: !running)) { t in
                let _ = spin.advance(to: t.date, target: target, reduceMotion: reduceMotion)
                let a = spin.angle
                ZStack {
                    VinylDisc(diameter: record).rotationEffect(.degrees(a))
                    // the light stays put while the disc turns under it; a reflection turns the other way, a little slower, and brightens as it passes
                    VinylSheen(diameter: record).drawingGroup().rotationEffect(.degrees(-a * 0.35)).opacity(0.75 + 0.25 * cos(a * .pi / 180))
                }
            }
            .frame(width: record, height: record)
            .allowsHitTesting(false)
            TonearmView(side: side, radius: armRadius, lifted: armRadius != nil, highlighted: hover == .arm).allowsHitTesting(false)
            // the hand: only the record and the arm answer it
            Color.clear.frame(width: side, height: side).contentShape(TTHitShape()).gesture(deckGesture())
                .focusable().focused($focused).focusEffectDisabledCompat()
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let next: TTHover = TTDrag.grabsArm(at: p, side: side, armAngle: armAngleNow) ? .arm : (TTArm.radius(of: p, side: side) <= TTArm.record ? .platter : .none)
                        if next != hover { hover = next; (next == .none ? NSCursor.arrow : NSCursor.openHand).set() }
                    case .ended: hover = .none; NSCursor.arrow.set()
                    }
                }
                .onKeyPressCompat(.leftArrow, whileFocused: focused, repeats: true) { seek(by: -5); return .handled }
                .onKeyPressCompat(.rightArrow, whileFocused: focused, repeats: true) { seek(by: 5); return .handled }
                .accessibilityElement().accessibilityLabel("Turntable record and tonearm")
                .accessibilityAdjustableAction { dir in seek(by: dir == .increment ? 10 : -10) }
            controls
        }
        .frame(width: side, height: side)
        .overlay(RoundedRectangle(cornerRadius: side * 0.035, style: .continuous).strokeBorder(Brand.accent, lineWidth: 1.5).opacity(focused ? 1 : 0).allowsHitTesting(false))
        .onAppear { running = true; applyScratchSound() }
        .onDisappear { m.player.varispeed = nil; if m.isActive, scratchSound { m.restartInPlace() } }
        // the platter is stepped only while it has something to do: it keeps going for the length of the spool-down after the music stops
        .onChangeCompat(of: target) { _, t in
            running = true
            coast?.cancel()
            if t == 0 { coast = Task { try? await Task.sleep(nanoseconds: UInt64((TTMotor.ramp + 1.2) * 1_000_000_000)); if !Task.isCancelled, target == 0 { running = false } } }
        }
        .onChangeCompat(of: scratchSound) { _, _ in applyScratchSound() }
        .accessibilityElement(children: .contain).accessibilityLabel("Turntable")
        .layoutProbe("turntable")
    }

    /// The power button, the speed switch and the scratch-sound switch, in the corner of the plinth where the record does not reach.
    private var controls: some View {
        let unit = max(22, side * 0.07)
        return HStack(spacing: unit * 0.3) {
            Button { m.togglePlay() } label: {
                Image(systemName: "power").font(Typo.sans(unit * 0.5, .semibold)).frame(width: unit, height: unit)
                    .background(Circle().fill(playing ? Brand.accent.opacity(0.9) : Brand.ink.opacity(0.1)))
                    .foregroundStyle(playing ? Brand.onAccent : Brand.ink)
            }.buttonStyle(.plain).help(playing ? "Stop" : "Start").accessibilityLabel(playing ? "Stop the turntable" : "Start the turntable")
            HStack(spacing: 0) {
                ForEach([33, 45], id: \.self) { v in
                    Button { rpm = v } label: {
                        Text("\(v)").font(Typo.mono(unit * 0.38, .medium)).frame(width: unit * 0.95, height: unit * 0.7)
                            .background(Capsule().fill(rpm == v ? Brand.ink.opacity(0.2) : Color.clear)).foregroundStyle(rpm == v ? Brand.ink : Brand.inkSecondary)
                    }.buttonStyle(.plain).accessibilityLabel("\(v) revolutions per minute").help("Speed (the look only: the sound is not changed)")
                }
            }.background(Capsule().fill(Brand.ink.opacity(0.07)))
            Button { scratchSound.toggle() } label: {
                Image(systemName: scratchSound ? "speaker.wave.2.fill" : "speaker.slash").font(Typo.sans(unit * 0.42, .semibold)).frame(width: unit, height: unit)
                    .background(Circle().fill(scratchSound ? Brand.ink.opacity(0.18) : Brand.ink.opacity(0.07))).foregroundStyle(Brand.ink)
            }.buttonStyle(.plain).help(scratchSound ? "Scratch sound on: the music follows the record under your hand (the signal path is no longer bit-perfect while this layout is open)" : "Scratch sound off: dragging the record only moves the picture and seeks when you let go")
                .accessibilityLabel(scratchSound ? "Scratch sound on" : "Scratch sound off")
        }
        .position(x: side * 0.03 + unit * 2.1, y: side - side * 0.03 - unit * 0.5)
    }

    // MARK: scratch sound

    /// The scratch needs the pitch control in the signal chain from the start of the song, so the song is restarted at the same place when it is switched on or off.
    private func applyScratchSound() {
        if scratchSound, m.player.varispeed == nil { m.player.varispeed = VarispeedControl(); if m.isActive { m.restartInPlace() } }
        else if !scratchSound, m.player.varispeed != nil { m.player.varispeed = nil; if m.isActive { m.restartInPlace() } }
    }

    // MARK: gestures

    private func deckGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if armRadius == nil && scratch == nil {
                    if TTDrag.grabsArm(at: v.startLocation, side: side, armAngle: armAngleNow) { liftArm() }
                    else if TTArm.radius(of: v.startLocation, side: side) <= TTArm.record {
                        scratch = (TTDrag.angle(of: v.location, side: side), Date(), 0); running = true; coast?.cancel(); NSCursor.closedHand.set()
                        if let ctl = m.player.varispeed { ctl.scratchSpeed = 0; ctl.scratchOn = true; m.player.send(.seekBy(0)) }      // the seconds already buffered are dropped, so the hand is heard at once
                    }
                }
                if armRadius != nil {
                    armRadius = max(TTArm.inner - 0.03, min(TTArm.outer + 0.12, TTArm.radius(of: v.location, side: side)))
                } else if let sc = scratch {
                    let now = Date(), a = TTDrag.angle(of: v.location, side: side)
                    let d = TTDrag.delta(from: sc.angle, to: a)
                    spin.drag(by: d, dt: now.timeIntervalSince(sc.time))
                    scratch = (a, now, sc.total + d)
                    // the audio follows the record: 1 is the speed of the music at 33, negative is backwards
                    m.player.varispeed?.scratchSpeed = spin.speed / TTMotor.cruise
                }
            }
            .onEnded { v in
                if armRadius != nil { dropArm(at: v.location) }
                else if let sc = scratch {
                    scratch = nil
                    let heard = m.player.varispeed != nil
                    m.player.varispeed?.scratchOn = false                    // normal playback again; the platter coasts back to speed
                    spin.release(reduceMotion: reduceMotion, target: target)
                    if !heard, abs(sc.total) >= TTDrag.minimumScratch { seek(by: TTDrag.scratchSeconds(degrees: sc.total)) }
                    NSCursor.openHand.set()
                }
            }
    }

    /// The arm is picked up: playback pauses, and the arm lifts off the groove.
    private func liftArm() {
        wasPlaying = playing
        if playing { m.player.send(.setPaused(true)) }
        let frac = progress.duration > 0 ? progress.position / progress.duration : 0
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7)) { armRadius = TTArm.radius(fraction: frac) }
        NSCursor.closedHand.set()
    }

    /// The needle is dropped: on the record it seeks to that place and plays on; beside it, the arm goes back to rest and playback stays paused.
    private func dropArm(at p: CGPoint) {
        let seekTo = TTDrag.seekTime(at: p, side: side, duration: progress.duration)
        withAnimation(reduceMotion ? nil : .interpolatingSpring(stiffness: 170, damping: 15)) { armRadius = nil }
        if let t = seekTo {
            m.player.send(.seekTo(t))
            if wasPlaying || m.status.state == .paused { m.player.send(.setPaused(false)) }
        }
        wasPlaying = false
        NSCursor.openHand.set()
    }

    private func seek(by seconds: Double) {
        guard progress.duration > 0 else { return }
        m.player.send(.seekTo(max(0, min(progress.duration - 0.1, progress.position + seconds))))
    }
}

/// The black disc: grooves in bands with the gaps between tracks, and the cover as its label. Drawn once and flattened, so turning it is a rotation of a bitmap.
struct VinylDisc: View {
    let diameter: CGFloat
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        let item = m.focusItem
        let label = diameter * 0.36
        ZStack {
            Circle().fill(Color(white: 0.055))
            Canvas { ctx, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let from = label / 2 + diameter * 0.02, to = diameter / 2 - diameter * 0.012
                var r = from
                var i = 0
                while r < to {
                    let gap = i % 23 == 0                                          // a smooth band between the tracks
                    var p = Path(); p.addArc(center: centre, radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                    ctx.stroke(p, with: .color(.white.opacity(gap ? 0.0 : (i % 2 == 0 ? 0.05 : 0.025))), lineWidth: 0.6)
                    r += max(1.1, diameter * 0.0045); i += 1
                }
            }
            CoverView(image: m.hero.image ?? item?.thumb, palette: m.hero.palette, corner: 0, symbol: item?.isStream == true ? "dot.radiowaves.left.and.right" : "music.note")
                .frame(width: label, height: label).clipShape(Circle())
            Circle().fill(Color(white: 0.9)).frame(width: diameter * 0.022, height: diameter * 0.022)
        }
        .frame(width: diameter, height: diameter)
        .drawingGroup()
    }
}

/// The light on the record: two soft highlights that stay where they are while the disc turns under them.
struct VinylSheen: View {
    let diameter: CGFloat
    var body: some View {
        Circle()
            .fill(AngularGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.10), location: 0.06), .init(color: .clear, location: 0.16),
                                          .init(color: .clear, location: 0.5), .init(color: .white.opacity(0.07), location: 0.56), .init(color: .clear, location: 0.66), .init(color: .clear, location: 1)],
                                  center: .center, angle: .degrees(-35)))
            .frame(width: diameter, height: diameter)
    }
}

/// The arm's line and head, in a square of 1: from the pivot along `angle`. Its angle animates.
private struct ArmShape: Shape {
    var angle: Double
    var animatableData: Double { get { angle } set { angle = newValue } }
    func path(in rect: CGRect) -> Path {
        let side = rect.width
        let p = CGPoint(x: TTArm.pivot.x * side, y: TTArm.pivot.y * side)
        let t = TTArm.tip(angle: angle, side: side)
        var path = Path()
        path.move(to: p); path.addLine(to: t)
        // the head: a short stub, turned a little from the arm
        let a = angle + 0.35, h = side * 0.045
        path.move(to: t); path.addLine(to: CGPoint(x: t.x + CGFloat(cos(a)) * h, y: t.y + CGFloat(sin(a)) * h))
        return path
    }
}

/// The tonearm. It reads the song's place itself, so only this view redraws when the position moves; held by the pointer it follows `radius` instead.
struct TonearmView: View {
    let side: CGFloat
    var radius: Double? = nil
    var lifted = false
    var highlighted = false
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var progress: ProgressModel
    var body: some View {
        let frac = progress.duration > 0 ? (m.scrub ?? progress.position) / progress.duration : 0
        let engaged = m.isActive && m.focusItem?.isStream != true
        let angle = radius.map { TTArm.angle(radius: $0) } ?? TTArm.angle(fraction: frac, engaged: engaged)
        ZStack {
            ArmShape(angle: angle).stroke(Brand.ink.opacity(highlighted || lifted ? 1 : 0.78), style: StrokeStyle(lineWidth: max(2, side * (highlighted ? 0.018 : 0.014)), lineCap: .round))
                .shadow(color: .black.opacity(lifted ? 0.42 : 0.3), radius: lifted ? 10 : 4, x: lifted ? -5 : -2, y: lifted ? 9 : 3)
                .animation(Motion.glide, value: m.isActive)
            Circle().fill(Brand.ink.opacity(0.85)).frame(width: side * 0.075, height: side * 0.075)
                .overlay(Circle().fill(Brand.panel2).frame(width: side * 0.03, height: side * 0.03))
                .position(x: TTArm.pivot.x * side, y: TTArm.pivot.y * side)
        }
        .frame(width: side, height: side)
        .scaleEffect(lifted ? 1.012 : 1, anchor: UnitPoint(x: TTArm.pivot.x, y: TTArm.pivot.y))
        .accessibilityElement(children: .ignore).accessibilityLabel("Tonearm").accessibilityValue("\(fmtDuration(progress.position)) of \(fmtDuration(progress.duration))")
    }
}

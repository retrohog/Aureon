import SwiftUI

/// Performs the Smart Remixer on the deck that is on air: every bar it asks `RemixPolicy` what to do next, and carries the chosen move out on the
/// next bar line with the deck's filter, effects, EQ and loops. Whatever the user had set on the deck is put back when a move ends.
@MainActor
final class RemixController: ObservableObject {
    unowned let model: DJModel
    let policy: RemixPolicy

    @Published var enabled = false {
        didSet {
            if enabled && !IntelligenceGate.shared.isEnabled(.remixer) { enabled = false; if oldValue { end() }; return }   // switched off on the Intelligence page
            if enabled != oldValue { enabled ? begin() : end() }
        }
    }
    /// 0 = let it breathe, 1 = busy.
    @Published var intensity = 0.3
    @Published private(set) var status = "Off"
    @Published private(set) var current = RemixAction.none
    @Published private(set) var actionCount = 0
    @Published private(set) var canRate = false
    @Published private(set) var feedbackCount = 0
    @Published private(set) var history: [RemixAction] = []

    var persistence = true
    var rng = SplitMix(seed: UInt64(Date().timeIntervalSince1970 * 1000))

    private var timer: Timer?
    private var deck: DJDeck?
    private var contours: [String: EnergyContour] = [:]
    private var lastBar = Int.min
    private var barsSince = 16
    private var last = RemixAction.none
    private var pending: DispatchWorkItem?
    private var running: (action: RemixAction, start: Date, context: RemixContext, base: Baseline)?
    private var lastContext: (RemixContext, RemixAction)?
    private var appliedLoop: Double?

    private struct Baseline { var filter: Double; var fx: DeckFXKind; var fxOn: Bool; var fxWet: Double; var fxParam: Double; var low: Double }

    init(model: DJModel, policy: RemixPolicy? = nil) {
        self.model = model
        self.policy = policy ?? RemixPolicy.loadOrCreate()
        feedbackCount = self.policy.feedbackCount
    }

    // MARK: on / off

    private func begin() {
        status = "Listening…"; lastBar = Int.min; barsSince = 16; last = .none
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
    }

    private func end() {
        timer?.invalidate(); timer = nil
        pending?.cancel(); pending = nil
        finishRunning()
        status = "Off"; current = .none; canRate = false
    }

    /// The deck the remix plays on: the playing deck that is louder in the mix.
    private func target() -> DJDeck? {
        let playing = model.decks.filter { $0.playing && $0.analysis?.bpm != nil }
        return playing.max { $0.mix.gain.value < $1.mix.gain.value }
    }

    // MARK: moves

    /// Starts a move now (the policy calls this on a bar line; tests and the interface can call it directly).
    func perform(_ action: RemixAction, on d: DJDeck? = nil) {
        guard let d = d ?? target(), action != .none else { return }
        finishRunning()
        deck = d
        var ctx = RemixContext(); ctx.intensity = intensity; ctx.last = last
        if let a = d.analysis, let c = contour(for: d) { ctx = RemixPlanner.context(analysis: a, contour: c, bar: currentBar(d) ?? 0, intensity: intensity, barsSinceAction: barsSince, last: last) ?? ctx }
        running = (action, Date(), ctx, Baseline(filter: d.filter, fx: d.fxKind, fxOn: d.fxOn, fxWet: d.fxWet, fxParam: d.fxParam, low: d.low))
        current = action; status = action.title
        appliedLoop = nil
        apply(action.state(atBeat: 0), to: d, action: action)
    }

    private func finishRunning() {
        guard let r = running, let d = deck else { running = nil; return }
        // put the deck back as the user had it
        d.filter = r.base.filter; d.fxKind = r.base.fx; d.fxOn = r.base.fxOn; d.fxWet = r.base.fxWet; d.fxParam = r.base.fxParam; d.low = r.base.low
        if appliedLoop != nil { d.clearLoop(); appliedLoop = nil }
        lastContext = (r.context, r.action)
        last = r.action; barsSince = 0; actionCount += 1; history.append(r.action); if history.count > 12 { history.removeFirst() }
        canRate = true; current = .none; running = nil
        if enabled { status = "Listening…" }
    }

    private func apply(_ s: RemixDeckState, to d: DJDeck, action: RemixAction) {
        switch action {
        case .filterSweep: d.filter = s.filter
        case .riser: d.filter = s.filter; applyFX(s, d)
        case .echoOut, .reverbWash, .stutter, .flangerSweep: applyFX(s, d)
        case .bassDrop: d.low = s.lowDB
        case .loopRoll:
            if s.loopBeats != appliedLoop {
                if let n = s.loopBeats { d.autoLoop(beats: n, snap: true); appliedLoop = n } else { d.clearLoop(); appliedLoop = nil }
            }
        case .none: break
        }
    }

    private func applyFX(_ s: RemixDeckState, _ d: DJDeck) {
        if d.fxKind != s.fx { d.fxKind = s.fx }
        d.fxWet = s.fxWet; d.fxParam = s.fxParam
        if d.fxOn != s.fxOn { d.fxOn = s.fxOn }
    }

    // MARK: the loop

    private func contour(for d: DJDeck) -> EnergyContour? {
        guard let path = d.track?.path, let a = d.analysis, !a.peaks.isEmpty else { return nil }
        if let c = contours[path] { return c }
        let c = EnergyContour(analysis: a); contours[path] = c
        return c
    }

    private func currentBar(_ d: DJDeck) -> Int? {
        guard let a = d.analysis, let bpm = a.bpm, let fb = a.firstBeat else { return nil }
        return Int(((d.position - fb) / (4 * 60 / bpm)).rounded(.down))
    }

    /// Runs about thirty times a second: steps the move in progress, and on a new bar decides what to do about the next one.
    func step() {
        guard enabled else { return }
        if let r = running, let d = deck {
            let bpm = d.effectiveBPM ?? 120
            let beat = Date().timeIntervalSince(r.start) * bpm / 60
            if beat >= r.action.beats || !d.isLoaded || !d.playing { finishRunning() } else { apply(r.action.state(atBeat: beat), to: d, action: r.action) }
            return
        }
        guard let d = target(), d.playing, let a = d.analysis, let bpm = a.bpm, let fb = a.firstBeat, let bar = currentBar(d) else { if pending == nil { status = "Waiting for a playing track with a tempo" }; return }
        deck = d
        guard bar != lastBar else { return }
        lastBar = bar; barsSince += 1
        guard pending == nil, let contour = contour(for: d) else { return }
        let next = bar + 1
        // Moves are rare and on phrase lines: at most one every few bars, sparser at low settings, and the hard-hitting ones only when asked for
        let minGap = Int(16 - 12 * intensity)
        guard barsSince >= minGap, next % 4 == 0 else { return }
        guard d.duration - (fb + Double(next) * 4 * 60 / bpm) > 4 * 60 / bpm * 2,                // not in the last two bars
              let ctx = RemixPlanner.context(analysis: a, contour: contour, bar: next, intensity: intensity, barsSinceAction: barsSince, last: last) else { return }
        var allowed: Set<RemixAction> = [.none, .filterSweep, .echoOut, .reverbWash, .flangerSweep]
        if intensity >= 0.45 { allowed.insert(.riser) }
        if intensity >= 0.6 { allowed.formUnion([.bassDrop, .loopRoll]) }
        if intensity >= 0.8 { allowed.insert(.stutter) }
        let choice = policy.choose(ctx, using: &rng, sharpness: Float(4 + 4 * intensity), allowed: allowed)
        guard choice != .none else { status = "Listening…"; return }
        // start it exactly on the next bar line
        let speed = max(0.5, d.control.ratio * (1 + d.control.bend))
        let delay = max(0, (fb + Double(next) * 4 * 60 / bpm - d.position) / speed)
        status = "Next bar: \(choice.title)"
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { guard let self, self.enabled else { return }; self.pending = nil; if d.playing { self.perform(choice, on: d) } }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: feedback

    func rate(liked: Bool) {
        guard let (ctx, action) = lastContext else { return }
        policy.feedback(ctx, action: action, liked: liked)
        if persistence { policy.save() }
        feedbackCount = policy.feedbackCount
        lastContext = nil; canRate = false
    }
}

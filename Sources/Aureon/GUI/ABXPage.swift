import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The ABX page: two files, matched in loudness and aligned to the sample, switched with a 10 ms crossfade; then a double-blind run of
// trials scored with a p-value and a confidence interval.

/// Set from the main thread, read by the analysis thread so that it stops when the files change.
private final class ABXCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Moves objects made on the analysis thread to the main thread.
private final class ABXHandoff: @unchecked Sendable {
    var engine: ABXEngine?
    var a: R128Result?, b: R128Result?
    var align: ABXAlign.Result?
    var conversionA: String?, conversionB: String?
    var infoA: StreamInfo?, infoB: StreamInfo?
    var error: String?
}

/// The playhead, apart from the model so that only the scrubber redraws while playing.
@MainActor
final class ABXClock: ObservableObject {
    @Published var position = 0.0
    @Published var duration = 0.0
}

@MainActor
final class ABXModel: ObservableObject {
    static let shared = ABXModel()

    struct Side: Equatable {
        var url: URL?
        var info: StreamInfo?
        var lufs: Double?
        var truePeakDB: Double?
        var conversion: String?
        var name: String { url?.deletingPathExtension().lastPathComponent ?? "" }
    }

    enum Phase: Equatable { case empty, analysing, ready, failed(String) }
    enum Choice: Equatable { case a, b, x }

    @Published private(set) var a = Side()
    @Published private(set) var b = Side()
    @Published private(set) var phase = Phase.empty
    @Published var matchLoudness = true { didSet { applyGains() } }
    @Published private(set) var alignment: ABXAlign.Result?
    @Published private(set) var offsetFrames = 0
    @Published private(set) var playing = false
    @Published private(set) var choice = Choice.a
    @Published private(set) var session: ABXSession?
    @Published var trialCount = 16
    @Published private(set) var loop: ClosedRange<Double>?
    @Published private(set) var rate: Double = 0
    @Published private(set) var message: String?
    @Published private(set) var canResumePlayer = false
    @Published var scrub: Double?

    let clock = ABXClock()

    private var engine: ABXEngine?
    private var deviceRunning = false
    private var timer: Timer?
    private var cancel: ABXCancel?
    private var trialStarted = Date()
    private var resume: (id: UUID, seconds: Double)?
    private var terminateObserver: NSObjectProtocol?

    private init() {
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ABXModel.shared.release() }
        }
    }

    var bothLoaded: Bool { a.url != nil && b.url != nil }
    var ready: Bool { phase == .ready && engine != nil }
    var inTest: Bool { session.map { !$0.finished } ?? false }

    /// The gain each side is played at, in dB (0 for the quieter one).
    var gainsDB: (a: Double, b: Double) {
        guard matchLoudness else { return (0, 0) }
        let g = ABXLoudness.gains(lufsA: a.lufs, lufsB: b.lufs)
        return (20 * log10(g.a), 20 * log10(g.b))
    }

    /// What the two sides measure after the gains, which is what the listener compares.
    var matchedLUFS: (a: Double?, b: Double?) { (a.lufs.map { $0 + gainsDB.a }, b.lufs.map { $0 + gainsDB.b }) }

    // MARK: Files

    func load(_ url: URL, into slot: ABXSlot) {
        guard !inTest else { message = "Finish or stop the test before changing files."; return }
        releaseEngine()
        var s = Side(); s.url = url
        if slot == .a { a = s } else { b = s }
        session = nil
        prepare()
    }

    func choose(_ slot: ABXSlot) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        p.message = "Choose file \(slot.label) for the comparison"
        if p.runModal() == .OK, let u = p.url { load(u, into: slot) }
    }

    func swapSides() {
        guard !inTest, bothLoaded else { return }
        releaseEngine()
        let (oa, ob) = (a.url, b.url)
        a = Side(); b = Side(); a.url = ob; b.url = oa
        prepare()
    }

    /// Opens both files at a common rate, measures their loudness and finds the offset between them, all off the main thread.
    private func prepare() {
        cancel?.cancel()
        guard let ua = a.url, let ub = b.url else { phase = .empty; return }
        let c = ABXCancel(); cancel = c
        phase = .analysing; message = nil; alignment = nil; offsetFrames = 0; loop = nil
        clock.position = 0; clock.duration = 0
        let deviceID = AppDelegate.model.flatMap { $0.deviceID == 0 ? nil : $0.deviceID }
        let h = ABXHandoff()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async { MainActor.assumeIsolated { ABXModel.shared.prepared(h, token: c) } }
            }
            do {
                let ia = try openLossless(path: ua.path).info, ib = try openLossless(path: ub.path).info
                h.infoA = ia; h.infoB = ib
                let rate = ABXEngine.rate(for: ia, ib, device: OutputDevice(id: deviceID))
                let sa = try ABXStream(path: ua.path, rate: rate), sb = try ABXStream(path: ub.path, rate: rate)
                h.conversionA = sa.conversion; h.conversionB = sb.conversion
                // both loudness passes at once; each reads only its own stream
                DispatchQueue.concurrentPerform(iterations: 2) { i in
                    let r = ABXLoudness.measure(i == 0 ? sa : sb) { c.cancelled }
                    if i == 0 { h.a = r } else { h.b = r }
                }
                guard !c.cancelled else { return }
                h.align = ABXAlign.measure(sa, sb)
                guard !c.cancelled else { return }
                h.engine = try ABXEngine(pathA: ua.path, pathB: ub.path, rate: rate)
            } catch {
                h.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func prepared(_ h: ABXHandoff, token: ABXCancel) {
        guard !token.cancelled, token === cancel else { return }
        if let e = h.error { phase = .failed(e); return }
        guard let engine = h.engine else { phase = .failed("The files could not be prepared."); return }
        a.info = h.infoA; b.info = h.infoB
        a.lufs = h.a?.integratedLUFS; b.lufs = h.b?.integratedLUFS
        a.truePeakDB = h.a?.truePeakDB; b.truePeakDB = h.b?.truePeakDB
        a.conversion = h.conversionA; b.conversion = h.conversionB
        self.engine = engine
        rate = engine.rate
        clock.duration = Double(engine.frames) / engine.rate
        alignment = h.align
        if let al = h.align, al.confidence >= ABXAlign.minimumConfidence { setOffset(al.offset) } else { setOffset(0) }
        applyGains()
        engine.core.select(.a); choice = .a
        phase = .ready
        if h.a?.integratedLUFS == nil || h.b?.integratedLUFS == nil { message = "One file is silent or too short to measure, so loudness is not matched." }
    }

    private func applyGains() {
        guard let engine else { return }
        let g = matchLoudness ? ABXLoudness.gains(lufsA: a.lufs, lufsB: b.lufs) : (a: 1.0, b: 1.0)
        engine.core.setGains(a: g.a, b: g.b)
    }

    // MARK: Alignment

    func setOffset(_ frames: Int) {
        offsetFrames = frames
        engine?.setOffset(frames)
    }

    func nudge(by frames: Int) { setOffset(offsetFrames + frames) }

    func resetAlignment() { setOffset(alignment.map { $0.confidence >= ABXAlign.minimumConfidence ? $0.offset : 0 } ?? 0) }

    var offsetDescription: String {
        guard rate > 0 else { return "" }
        let ms = Double(offsetFrames) / rate * 1000
        if offsetFrames == 0 { return "In sync (no offset)" }
        return String(format: "B %@ by %.2f ms (%d samples)", offsetFrames > 0 ? "starts later" : "starts earlier", abs(ms), abs(offsetFrames))
    }

    // MARK: Transport

    func togglePlay() { playing ? pause() : play() }

    func play() {
        guard let engine else { return }
        if !deviceRunning {
            guard let m = AppDelegate.model else { return }
            if m.djMode { message = "Leave DJ mode to run the ABX test."; return }
            if m.isActive, let cur = m.current {
                resume = (cur.id, m.status.position)
                m.player.stop()                    // the comparison needs the output device to itself
                canResumePlayer = true
            }
            engine.seek(toFrame: Int(clock.position * engine.rate))
            do { try engine.start(deviceID: m.deviceID == 0 ? nil : m.deviceID) }
            catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return }
            deviceRunning = true
            startTimer()
        }
        engine.core.playing.store(true, ordering: .releasing)
        playing = true
        message = nil
    }

    func pause() {
        engine?.core.playing.store(false, ordering: .releasing)
        playing = false
    }

    func select(_ c: Choice) {
        guard let engine else { return }
        if c == .x { guard let x = session?.currentX else { return }; engine.core.select(x) }
        else { engine.core.select(c == .a ? .a : .b) }
        if c != choice, inTest { session?.noteSwitch() }
        choice = c
    }

    func seek(_ seconds: Double) {
        guard let engine else { return }
        let f = Int(max(0, seconds) * engine.rate)
        if deviceRunning { engine.seek(toFrame: f) }
        clock.position = Double(f) / engine.rate
    }

    func setLoopStart() { setLoop(clock.position...(loop?.upperBound ?? clock.duration)) }
    func setLoopEnd() { setLoop((loop?.lowerBound ?? 0)...clock.position) }
    func clearLoop() { setLoop(nil) }

    private func setLoop(_ r: ClosedRange<Double>?) {
        guard let engine else { return }
        if let r, r.upperBound - r.lowerBound >= 0.5 {
            loop = r
            engine.setLoop(Int(r.lowerBound * engine.rate)..<Int(r.upperBound * engine.rate))
        } else {
            if r != nil { message = "A loop must be at least half a second long." }
            loop = nil
            engine.setLoop(nil)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                let m = ABXModel.shared
                guard let e = m.engine, m.deviceRunning else { return }
                let p = Double(e.playhead) / e.rate
                if abs(p - m.clock.position) > 0.01 { m.clock.position = p }
            }
        }
    }

    // MARK: Blind test

    func startTest() {
        guard ready else { return }
        session = ABXSession(count: trialCount)
        trialStarted = Date()
        select(.x)
        if !playing { play() }
    }

    func answer(_ s: ABXSlot) {
        guard var sess = session, !sess.finished, let engine else { return }
        sess.answer(s, seconds: Date().timeIntervalSince(trialStarted))
        session = sess
        trialStarted = Date()
        if sess.finished {
            select(.a)
            return
        }
        // A new X may be the other file. Changing it audibly would give the answer away, so the sound dips to silence first and comes
        // back on the new X whichever it is.
        guard choice == .x, let next = sess.currentX else { return }
        let wasPlaying = playing
        engine.core.playing.store(false, ordering: .releasing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated {
                let m = ABXModel.shared
                guard m.engine === engine else { return }
                if m.choice == .x { engine.core.select(next) }
                if wasPlaying && m.playing { engine.core.playing.store(true, ordering: .releasing) }
            }
        }
    }

    func stopTest() { session = nil; if choice == .x { select(.a) } }

    var resultsText: String {
        guard let s = session else { return "" }
        let ci = s.interval
        var lines = ["Aureon ABX test", "A: \(a.url?.path ?? "")", "B: \(b.url?.path ?? "")",
                     String(format: "Loudness matched: %@ (A %+.2f dB, B %+.2f dB)", matchLoudness ? "yes" : "no", gainsDB.a, gainsDB.b),
                     "Offset: \(offsetDescription)",
                     "Score: \(s.correct) of \(s.answered)",
                     "p-value (one-sided binomial): \(ABXSession.format(s.pValue))",
                     String(format: "95%% confidence interval for the hit rate: %.0f%% – %.0f%%", ci.low * 100, ci.high * 100), ""]
        for (i, t) in s.trials.enumerated() {
            lines.append("\(i + 1). X = \(t.x.label), answered \(t.answer?.label ?? "-") \(t.correct == true ? "✓" : "✗")  (\(t.switches) switches, \(Int(t.seconds)) s)")
        }
        return lines.joined(separator: "\n")
    }

    func copyResults() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultsText, forType: .string)
    }

    // MARK: Device

    /// Gives the output device back (leaving the page, quitting). The files stay loaded; Play takes the device again.
    func release() {
        guard deviceRunning, let engine else { return }
        timer?.invalidate(); timer = nil
        engine.stop()
        deviceRunning = false
        playing = false
    }

    private func releaseEngine() {
        cancel?.cancel()
        release()
        engine = nil
        rate = 0
    }

    func resumePlayer() {
        release()
        guard let m = AppDelegate.model, let r = resume, m.items.contains(where: { $0.id == r.id }) else { canResumePlayer = false; resume = nil; return }
        m.play(r.id, at: max(r.seconds, 0.0001))
        resume = nil; canResumePlayer = false
    }
}

// MARK: - Page

struct ABXPage: View {
    @ObservedObject private var x = ABXModel.shared

    var body: some View {
        PageScaffold(title: "ABX Test", subtitle: "Blind comparison", trailing: {
            if x.canResumePlayer { PillButton(title: "Resume Player", symbol: "play.fill") { x.resumePlayer() } }
        }) {
            Note(text: "Load two files, for example two masterings of one album or a lossless file and its MP3. Aureon matches their loudness to the quieter one, lines them up to the sample and switches between them with a 10 ms crossfade, so only the sound differs.")
            HStack(alignment: .top, spacing: 14) {
                ABXFileCard(slot: .a)
                Button { x.swapSides() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(IconButtonStyle()).disabled(!x.bothLoaded || x.inTest).help("Swap A and B").padding(.top, 40)
                ABXFileCard(slot: .b)
            }
            status
            if x.ready {
                ABXPlayerPanel()
                ABXTestPanel()
            }
        }
        .onDisappear { x.release() }
    }

    @ViewBuilder private var status: some View {
        switch x.phase {
        case .analysing:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Measuring loudness and finding the offset between the files…").font(.system(size: 12.5)).foregroundStyle(.secondary) }
        case .failed(let e):
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12.5))
        default:
            EmptyView()
        }
        if let msg = x.message { Label(msg, systemImage: "info.circle").font(.system(size: 12.5)).foregroundStyle(.secondary) }
    }
}

struct ABXFileCard: View {
    @ObservedObject private var x = ABXModel.shared
    let slot: ABXSlot
    @State private var targeted = false

    var body: some View {
        let side = slot == .a ? x.a : x.b
        let gain = slot == .a ? x.gainsDB.a : x.gainsDB.b
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(slot.label).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Brand.accent)
                    .frame(width: 38, height: 38).background(Circle().fill(Brand.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(side.url == nil ? "No file" : side.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    if let i = side.info {
                        Text("\(i.codec) · \(i.sourceBits)-bit · \(formatRate(i.sampleRate)) · \(i.channels == 1 ? "mono" : "\(i.channels) ch") · \(clock(i.duration))")
                            .font(Typo.readout).foregroundStyle(.secondary).lineLimit(1)
                    } else if let u = side.url {
                        Text(u.deletingLastPathComponent().lastPathComponent).font(Typo.readout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button("Choose…") { x.choose(slot) }.controlSize(.small).disabled(x.inTest)
            }
            if x.ready {
                HStack(spacing: 8) {
                    if let l = side.lufs { HWBadge(text: "LUFS", detail: String(format: "%.2f", l), tone: .neutral, lit: false) }
                    if let tp = side.truePeakDB { HWBadge(text: "TP", detail: String(format: "%.1f dBTP", tp), tone: tp > -0.1 ? .orange : .neutral, lit: tp > -0.1) }
                    if x.matchLoudness { HWBadge(text: "GAIN", detail: String(format: "%+.2f dB", gain), tone: gain < -0.005 ? .amber : .neutral, lit: gain < -0.005) }
                }
                if let c = side.conversion { Note(text: "Played \(c).") }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 16, fill: targeted ? 0.1 : 0.045, glow: targeted ? Brand.accent : nil)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: \.isFileURL) else { return false }
            x.load(u, into: slot)
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct ABXPlayerPanel: View {
    @ObservedObject private var x = ABXModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { x.togglePlay() } label: {
                    Image(systemName: x.playing ? "pause.fill" : "play.fill").font(.system(size: 20)).frame(width: 46, height: 46)
                        .background(Circle().fill(Brand.accent)).foregroundStyle(.white)
                }
                .buttonStyle(.plain).help(x.playing ? "Pause" : "Play")
                choiceButton(.a, "A", key: "a")
                if x.session != nil { choiceButton(.x, "X", key: "x").disabled(!x.inTest) }
                choiceButton(.b, "B", key: "b")
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Toggle("Match loudness", isOn: $x.matchLoudness).toggleStyle(.switch).controlSize(.small)
                    if x.matchLoudness, let la = x.matchedLUFS.a, let lb = x.matchedLUFS.b {
                        Text(String(format: "Both at %.2f LUFS (difference %.2f LU)", min(la, lb), abs(la - lb))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            ABXScrubber()
            HStack(spacing: 8) {
                Button("Loop In") { x.setLoopStart() }.help("Start the loop at the playhead")
                Button("Loop Out") { x.setLoopEnd() }.help("End the loop at the playhead")
                if let l = x.loop {
                    Text("\(clock(l.lowerBound)) – \(clock(l.upperBound))").font(Typo.readout).foregroundStyle(.secondary)
                    Button("Clear Loop") { x.clearLoop() }
                }
                Spacer()
                Text(x.offsetDescription).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Menu {
                    Button("B 1 ms earlier") { x.nudge(by: -Int(x.rate / 1000)) }
                    Button("B 1 sample earlier") { x.nudge(by: -1) }
                    Button("B 1 sample later") { x.nudge(by: 1) }
                    Button("B 1 ms later") { x.nudge(by: Int(x.rate / 1000)) }
                    Divider()
                    Button("Measured Offset") { x.resetAlignment() }
                    Button("No Offset") { x.setOffset(0) }
                } label: { Image(systemName: "slider.horizontal.below.rectangle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Adjust the alignment of B").disabled(x.inTest)
            }
            .controlSize(.small)
            if let al = x.alignment, al.confidence < ABXAlign.minimumConfidence {
                Note(text: String(format: "The files could not be lined up automatically (match %.0f%%). If they are the same recording, adjust the offset by ear.", al.confidence * 100), color: .orange)
            }
            Note(text: "Output at \(formatRate(x.rate)), 10 ms crossfade on every switch. Keys: A, B\(x.inTest ? ", X" : "").")
        }
        .padding(16)
        .panel(radius: 18)
    }

    private func choiceButton(_ c: ABXModel.Choice, _ label: String, key: KeyEquivalent) -> some View {
        let on = x.choice == c
        return Button { x.select(c) } label: {
            Text(label).font(.system(size: 18, weight: .bold, design: .rounded)).frame(width: 64, height: 46)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Brand.accent.opacity(0.28) : Brand.ink.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Brand.accent : Brand.ink.opacity(0.12), lineWidth: on ? 1.5 : 0.8))
        }
        .buttonStyle(.plain).keyboardShortcut(key, modifiers: []).help("Listen to \(label)")
    }
}

struct ABXScrubber: View {
    @ObservedObject private var x = ABXModel.shared
    @ObservedObject private var c = ABXModel.shared.clock

    var body: some View {
        let dur = max(c.duration, 0.001), pos = x.scrub ?? c.position
        VStack(spacing: 2) {
            FluidSlider(value: Binding(get: { x.scrub ?? c.position }, set: { x.scrub = $0 }), range: 0...dur, tint: Brand.accent, bubble: { clock($0) }, scrollStep: 2) { editing in
                if !editing, let t = x.scrub { x.seek(t); x.scrub = nil }
            }
            .background {
                if let l = x.loop {
                    GeometryReader { g in
                        Capsule().fill(Brand.accent.opacity(0.25))
                            .frame(width: max(2, g.size.width * (l.upperBound - l.lowerBound) / dur), height: 10)
                            .offset(x: g.size.width * l.lowerBound / dur, y: (g.size.height - 10) / 2)
                    }
                    .allowsHitTesting(false)
                }
            }
            HStack {
                Text(clock(pos)); Spacer(); Text("-" + clock(max(0, dur - pos)))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct ABXTestPanel: View {
    @ObservedObject private var x = ABXModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Blind test").font(.system(size: 17, weight: .semibold))
            if let s = x.session {
                if s.finished { results(s) } else { running(s) }
            } else {
                setup
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 18)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Note(text: "Each trial plays X, which is A or B at random. Listen to A, B and X as often as you like, then say which one X is. Neither you nor the screen knows the answer until the end.")
            HStack(spacing: 12) {
                Stepper("\(x.trialCount) trials", value: $x.trialCount, in: ABXSession.trialRange)
                    .fixedSize()
                Text("\(ABXStats.needed(trials: x.trialCount)) right answers prove a difference (p < 0.05)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                PillButton(title: "Start Test", symbol: "eye.slash", filled: true) { x.startTest() }
            }
        }
    }

    private func running(_ s: ABXSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trial \(s.index + 1) of \(s.total)").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Spacer()
                Button("Stop Test") { x.stopTest() }.controlSize(.small)
            }
            HStack(spacing: 4) {
                ForEach(0..<s.total, id: \.self) { i in
                    Capsule().fill(i < s.index ? Brand.ink.opacity(0.5) : (i == s.index ? Brand.accent : Brand.ink.opacity(0.12))).frame(height: 5)
                }
            }
            HStack(spacing: 12) {
                PillButton(title: "X is A", symbol: "a.square", filled: true) { x.answer(.a) }
                PillButton(title: "X is B", symbol: "b.square", filled: true) { x.answer(.b) }
                Spacer()
                Text("No feedback until the end, so earlier answers cannot steer later ones.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func results(_ s: ABXSession) -> some View {
        let ci = s.interval
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(s.correct) / \(s.answered)").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("correct").microLabel().foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ABXSession.format(s.pValue)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(s.pValue < 0.05 ? Brand.accent : Color.primary)
                    Text("p-value").microLabel().foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f – %.0f %%", ci.low * 100, ci.high * 100)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("95 % interval, hit rate").microLabel().foregroundStyle(.secondary)
                }
                Spacer()
            }
            Note(text: s.verdict)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(s.trials.enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").frame(width: 24, alignment: .trailing).foregroundStyle(.secondary)
                        Image(systemName: t.correct == true ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(t.correct == true ? Color.green : Color.orange)
                        Text("X was \(t.x.label), you said \(t.answer?.label ?? "–")")
                        Spacer()
                        Text("\(t.switches) switches · \(Int(t.seconds.rounded())) s").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12)).monospacedDigit()
                }
            }
            HStack {
                PillButton(title: "Copy Results", symbol: "doc.on.doc") { x.copyResults() }
                PillButton(title: "New Test", symbol: "arrow.counterclockwise") { x.startTest() }
            }
        }
    }
}

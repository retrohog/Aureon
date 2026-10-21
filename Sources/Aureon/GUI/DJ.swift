import SwiftUI
import Combine

struct DJTrack: Equatable {
    var path: String
    var title: String
    var artist: String
    var album: String = ""
}

/// One deck: its own player (so two tracks play at once), a pitch fader, an EQ and an output level.
@MainActor
final class DJDeck: ObservableObject, Identifiable {
    let name: String
    let player = Player()
    let control = VarispeedControl()
    let gain = DeckGain()

    @Published private(set) var track: DJTrack?
    @Published private(set) var analysis: DJTrackAnalysis?
    @Published private(set) var analyzing = false
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var error: String?
    @Published private(set) var peakL: Float = 0
    @Published private(set) var peakR: Float = 0
    @Published var cue = 0.0
    /// The pitch fader as a fraction: +0.04 plays 4 % faster (and higher).
    @Published var pitch = 0.0 { didSet { control.ratio = 1 + pitch } }
    @Published var pitchRange = 0.08
    @Published var channel = 0.8 { didSet { onMix?() } }
    @Published var low = 0.0 { didSet { applyEQ() } }
    @Published var mid = 0.0 { didSet { applyEQ() } }
    @Published var high = 0.0 { didSet { applyEQ() } }

    var onMix: (() -> Void)?
    var options = PlayerOptions()
    var deckRate = 48_000.0
    private var analysisTask: Task<Void, Never>?
    private var lastTick: Date?
    private var trustEngineAfter = Date.distantPast       // just after a seek the engine's figure is still the old one

    init(_ name: String) {
        self.name = name
        player.varispeed = control; player.deckGain = gain
    }

    var bpm: Double? { analysis?.bpm }
    var effectiveBPM: Double? { DJMath.effectiveBPM(bpm, pitch: pitch) }
    var isLoaded: Bool { track != nil }

    private func settings() -> PlaybackSettings {
        var s = PlaybackSettings()
        s.deckRate = deckRate
        let p = DJMath.eqProfile(low: low, mid: mid, high: high)
        s.rt.headphoneEQ = HeadphoneEQSettings(enabled: p != nil, profile: p)
        return s
    }

    private func applyEQ() { player.settings = settings() }

    func load(_ t: DJTrack) {
        analysisTask?.cancel()
        player.stop()
        track = t; analysis = nil; error = nil; position = 0; cue = 0; playing = false; pitch = 0
        guard let f = try? LosslessFile(path: t.path) else { error = "Could not open this file"; track = nil; return }
        if f.info.sourceBits == 1 { error = "DSD files cannot be loaded on a deck"; track = nil; return }
        duration = f.info.duration
        player.settings = settings()
        player.setQueue([t.path])
        var o = options; o.startPaused = true
        player.start(options: o)
        analyzing = true
        let path = t.path
        analysisTask = Task { [weak self] in
            let a = await Task.detached(priority: .utility) { DJAnalysis.analyze(path: path) }.value
            guard !Task.isCancelled, let self, self.track?.path == path else { return }
            self.analysis = a; self.analyzing = false
        }
    }

    func setAnalysisForTests(_ a: DJTrackAnalysis) { analysis = a }

    func unload() { analysisTask?.cancel(); player.stop(); track = nil; analysis = nil; playing = false; position = 0; duration = 0 }

    func play() {
        guard track != nil else { return }
        if player.isRunning { player.send(.setPaused(false)) }
        else { var o = options; o.startPaused = false; player.start(startSeconds: min(cue, max(0, duration - 0.5)), options: o) }
    }

    func pause() { if player.isRunning { player.send(.setPaused(true)) } }
    func togglePlay() { playing ? pause() : play() }

    /// CDJ-style: while playing, jump back to the cue point and wait there; while stopped, set the cue point here.
    func cuePressed() {
        guard track != nil else { return }
        if playing { pause(); seek(to: cue) } else { cue = position }
    }

    func seek(to t: Double) {
        guard track != nil else { return }
        let s = max(0, min(t, max(0, duration - 0.1)))
        if player.isRunning { player.send(.seekTo(s)) }
        else { var o = options; o.startPaused = true; player.start(startSeconds: s, options: o) }
        position = s; lastTick = nil; trustEngineAfter = Date().addingTimeInterval(0.3)
    }

    /// Reads the engine's state (called ten times a second by the model).
    func refresh() {
        guard track != nil else { return }
        let st = player.status, now = Date()
        playing = st.state == .playing
        if st.finished && player.isRunning == false && st.state == .idle { playing = false }
        else if player.isRunning {
            // The engine reads ahead in chunks, so its figure steps; between looks the position is dead-reckoned at the current speed and gently
            // pulled toward the engine's figure, which keeps it smooth and prevents drift.
            let engine = max(0, min(duration, control.sourceFrame / deckRate - st.bufferedSeconds * control.ratio))
            if playing, let last = lastTick, now >= trustEngineAfter || lastTick != nil {
                let dead = position + now.timeIntervalSince(last) * control.ratio
                position = now >= trustEngineAfter ? dead + (engine - dead) * 0.12 : dead
            } else if now >= trustEngineAfter { position = engine }
            position = max(0, min(duration, position))
        }
        lastTick = playing ? now : nil
        if st.finished { playing = false; position = min(duration, position) }
        let m = player.analysis.snapshot().meters
        peakL = m.peakL; peakR = m.peakR
    }

    func shutdown() { analysisTask?.cancel(); player.stop() }
}

@MainActor
final class DJModel: ObservableObject {
    let a = DJDeck("A")
    let b = DJDeck("B")
    @Published var crossfader = 0.0 { didSet { applyMix() } }
    @Published var curve = CrossfaderCurve.smooth { didSet { applyMix() } }
    @Published private(set) var active = false
    private var timer: Timer?

    init() {
        a.onMix = { [weak self] in self?.applyMix() }
        b.onMix = { [weak self] in self?.applyMix() }
        applyMix()
    }

    var decks: [DJDeck] { [a, b] }

    /// Mixes the two decks' output levels: channel fader × crossfader.
    func applyMix() {
        let g = curve.gains(crossfader)
        a.gain.value = Float(DJMath.channelGain(a.channel) * g.a)
        b.gain.value = Float(DJMath.channelGain(b.channel) * g.b)
    }

    func enter(options: PlayerOptions, rate: Double) {
        guard !active else { return }
        active = true
        for d in decks { d.options = options; d.deckRate = rate; d.player.analysis.setActive(true) }
        applyMix()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.decks.forEach { $0.refresh() } }
        }
    }

    func exit() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        for d in decks { d.unload(); d.player.analysis.setActive(false) }
    }

    func other(_ d: DJDeck) -> DJDeck { d === a ? b : a }

    /// Matches this deck's tempo to the other deck's current tempo (half or double time if that is closer).
    func sync(_ d: DJDeck) {
        guard let mine = d.bpm, let target = other(d).effectiveBPM, let p = DJMath.syncPitch(bpm: mine, target: target) else { return }
        d.pitch = max(-d.pitchRange, min(d.pitchRange, p))
        if abs(p) > d.pitchRange { d.pitchRange = 0.16; d.pitch = p }
    }

    /// Loads into the deck that is not playing (deck A if neither is).
    func loadIntoFreeDeck(_ t: DJTrack) { load(t, into: freeDeck()) }

    func freeDeck() -> DJDeck {
        if !a.isLoaded { return a }
        if !b.isLoaded { return b }
        if a.playing && !b.playing { return b }
        if b.playing && !a.playing { return a }
        return a
    }
    func load(_ t: DJTrack, into d: DJDeck) { d.load(t) }
}

// MARK: - Controls

/// A rotary control: drag up/down, double-click to centre.
struct Knob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var tint: Color = Brand.accent
    var size: CGFloat = 38
    @StateObject private var drag = Box<Double?>(nil)

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    private var zero: Double { (0 - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(.black.opacity(0.35))
                Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
                // arc from the centre detent to the value
                Circle().trim(from: 0.125 + 0.75 * min(zero, fraction), to: 0.125 + 0.75 * max(zero, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(90)).padding(3)
                Capsule().fill(.white).frame(width: 2.5, height: size * 0.3).offset(y: -size * 0.27).rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: size, height: size)
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                if drag.v == nil { drag.v = value }
                let span = range.upperBound - range.lowerBound
                value = max(range.lowerBound, min(range.upperBound, (drag.v ?? value) - Double(d.translation.height) / 150 * span))
            }.onEnded { _ in drag.v = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
            Text(label).microLabel().foregroundStyle(.secondary)
        }
        .accessibilityElement().accessibilityLabel(Text(label)).accessibilityValue(Text(String(format: "%+.0f decibels", value)))
        .accessibilityAdjustableAction { dir in value = max(range.lowerBound, min(range.upperBound, value + (dir == .increment ? 1 : -1))) }
    }
}

/// A thin level bar for a deck's output.
struct LevelBar: View {
    let value: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(max(Double(value), 1e-5)), f = max(0, min(1, (db + 48) / 48))
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .bottom, endPoint: .top)).frame(height: g.size.height * CGFloat(f))
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * CGFloat(f)) }
            }
        }.frame(width: 6)
    }
}

// MARK: - Deck

struct DeckPanel: View {
    @ObservedObject var deck: DJDeck
    @EnvironmentObject var model: DJModel
    private var color: Color { deck.name == "A" ? Color(red: 0.36, green: 0.80, blue: 1.0) : Color(red: 1.0, green: 0.45, blue: 0.70) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Waveform(deck: deck, tint: color).frame(height: 64)
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        deckButton("CUE", icon: "arrow.uturn.backward") { deck.cuePressed() }
                        Button { deck.togglePlay() } label: {
                            Image(systemName: deck.playing ? "pause.fill" : "play.fill").font(.system(size: 22, weight: .bold)).frame(width: 74, height: 46)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(deck.playing ? AnyShapeStyle(color) : AnyShapeStyle(Color.white.opacity(0.14))))
                                .foregroundStyle(deck.playing ? Color.black.opacity(0.85) : Color.white)
                        }.buttonStyle(.plain).disabled(!deck.isLoaded).keyboardShortcut(deck.name == "A" ? "a" : "l", modifiers: .command)
                        deckButton("SYNC", icon: "arrow.triangle.2.circlepath") { model.sync(deck) }.disabled(deck.bpm == nil || model.other(deck).bpm == nil)
                    }
                    HStack(spacing: 6) {
                        Text("BPM").microLabel().foregroundStyle(.secondary)
                        Text(deck.effectiveBPM.map { String(format: "%.1f", $0) } ?? (deck.analyzing ? "…" : "—")).font(.system(size: 26, weight: .semibold, design: .monospaced)).foregroundStyle(color)
                        Spacer()
                        Text(String(format: "%+.1f%%", deck.pitch * 100)).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    HStack { LevelBar(value: deck.peakL).frame(height: 26); LevelBar(value: deck.peakR).frame(height: 26); Spacer()
                        Picker("", selection: $deck.pitchRange) { Text("±8%").tag(0.08); Text("±16%").tag(0.16) }.pickerStyle(.segmented).labelsHidden().frame(width: 100) }
                }
                VStack(spacing: 4) {
                    VerticalFader(value: Binding(get: { deck.pitch * 100 }, set: { deck.pitch = max(-deck.pitchRange, min(deck.pitchRange, $0 / 100)) }),
                                  range: -(deck.pitchRange * 100)...(deck.pitchRange * 100), step: 0.1, height: 92, enabled: deck.isLoaded)
                    Text("PITCH").microLabel().foregroundStyle(.secondary)
                }
            }
            if let e = deck.error { Text(e).font(.caption).foregroundStyle(.orange) }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(deck.playing ? color.opacity(0.6) : .white.opacity(0.08), lineWidth: deck.playing ? 1.4 : 0.8))
        .animation(.easeOut(duration: 0.2), value: deck.playing)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(deck.name).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.85)).frame(width: 28, height: 28).background(Circle().fill(color))
            VStack(alignment: .leading, spacing: 1) {
                Text(deck.track?.title ?? "Empty").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(deck.track.map { $0.artist.isEmpty ? $0.album : $0.artist } ?? "Load a track from the list below").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(clock(deck.position)).font(.system(size: 17, weight: .semibold, design: .monospaced)).monospacedDigit()
                Text("-" + clock(max(0, (deck.duration - deck.position) / max(0.5, 1 + deck.pitch)))).font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func deckButton(_ title: String, icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) { Image(systemName: icon).font(.system(size: 12, weight: .semibold)); Text(title).font(.system(size: 9.5, weight: .bold, design: .monospaced)).tracking(0.8) }
                .frame(width: 54, height: 46).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.09)))
        }.buttonStyle(.plain).disabled(!deck.isLoaded)
    }
}

/// The track's waveform overview with the playhead and cue point; click or drag to seek.
struct Waveform: View {
    @ObservedObject var deck: DJDeck
    let tint: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(.black.opacity(0.3)))
                guard let a = deck.analysis, !a.peaks.isEmpty, deck.duration > 0 else {
                    let msg = deck.analyzing ? "Analysing…" : (deck.isLoaded ? "" : "No track")
                    ctx.draw(Text(msg).font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2)); return
                }
                let bars = Int(size.width / 2)
                let playedX = size.width * CGFloat(deck.position / deck.duration)
                for i in 0..<bars {
                    let lo = i * a.peaks.count / bars, hi = max(lo + 1, (i + 1) * a.peaks.count / bars)
                    var p: Float = 0; for k in lo..<min(hi, a.peaks.count) { p = max(p, a.peaks[k]) }
                    let bh = max(2, CGFloat(p) * (size.height - 8))
                    let x = CGFloat(i) * 2
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - bh) / 2, width: 1.4, height: bh), cornerRadius: 0.7), with: .color(x <= playedX ? tint : .white.opacity(0.32)))
                }
                let cueX = size.width * CGFloat(deck.cue / deck.duration)
                ctx.fill(Path(CGRect(x: cueX - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
                ctx.fill(Path(CGRect(x: playedX - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                guard deck.isLoaded, deck.duration > 0 else { return }
                deck.seek(to: Double(max(0, min(1, d.location.x / w))) * deck.duration)
            })
            .frame(width: w, height: h)
        }
    }
}

// MARK: - Mixer

struct MixerPanel: View {
    @EnvironmentObject var model: DJModel
    var body: some View {
        HStack(alignment: .top, spacing: 14) { ChannelStrip(deck: model.a, color: Color(red: 0.36, green: 0.80, blue: 1.0)); ChannelStrip(deck: model.b, color: Color(red: 1.0, green: 0.45, blue: 0.70)) }
            .padding(12).frame(width: 214).frame(maxHeight: .infinity).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
    }
}

/// The crossfader, full width like the one on a hardware mixer, with its curve.
struct CrossfaderBar: View {
    @EnvironmentObject var model: DJModel
    var body: some View {
        HStack(spacing: 14) {
            Text("A").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(Color(red: 0.36, green: 0.80, blue: 1.0))
            VStack(spacing: 2) {
                FluidSlider(value: $model.crossfader, range: -1...1, tint: .white.opacity(0.9), restingHeight: 5, enabled: true, bubble: { $0 == 0 ? "centre" : String(format: "%+.0f%%", $0 * 100) })
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.crossfader = 0 })
                Text("CROSSFADER").microLabel().foregroundStyle(.secondary)
            }
            Text("B").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.70))
            Picker("", selection: $model.curve) { ForEach(CrossfaderCurve.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Button("Centre") { withAnimation(.easeOut(duration: 0.15)) { model.crossfader = 0 } }.buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
    }
}

struct ChannelStrip: View {
    @ObservedObject var deck: DJDeck
    let color: Color
    var body: some View {
        VStack(spacing: 8) {
            Text(deck.name).font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(color)
            Knob(value: $deck.high, range: DJMath.eqRange, label: "HI", tint: color, size: 30)
            Knob(value: $deck.mid, range: DJMath.eqRange, label: "MID", tint: color, size: 30)
            Knob(value: $deck.low, range: DJMath.eqRange, label: "LOW", tint: color, size: 30)
            HStack(spacing: 5) {
                VerticalFader(value: $deck.channel, range: 0...1, step: 0.01, height: 84)
                LevelBar(value: max(deck.peakL, deck.peakR)).frame(height: 84)
            }
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - The console

struct DJView: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var dj: DJModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("DJ").font(.system(size: 22, weight: .heavy, design: .rounded)).tracking(1)
                Text("TWO DECKS · MIXER · CROSSFADER").microLabel().foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: m.hasVolume ? "speaker.wave.2.fill" : "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    FluidSlider(value: Binding(get: { Double(m.volume) }, set: { m.setVolume(Float($0)) }), tint: .white.opacity(0.9), restingHeight: 3, enabled: m.hasVolume, bubble: { "\(Int($0 * 100))%" }, safe: true).frame(width: 110)
                    Text(m.hasVolume ? "MASTER" : "SYSTEM VOLUME").microLabel().foregroundStyle(.secondary)
                }
                Color.clear.frame(width: 110)       // room for the layout switch in the corner
            }
            .padding(.top, 4)
            HStack(alignment: .top, spacing: 12) {
                DeckPanel(deck: dj.a)
                MixerPanel()
                DeckPanel(deck: dj.b)
            }
            .fixedSize(horizontal: false, vertical: true)
            CrossfaderBar()
            DJBrowser()
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { m.library.category = .songs }
    }
}

struct DJBrowser: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var dj: DJModel
    @ObservedObject var lib: LibraryModel

    init() { _lib = ObservedObject(wrappedValue: LibraryModelBridge.shared.model!) }

    var body: some View {
        let songs = LibraryOrdering.songs(lib.songs, ViewOptions.defaults(for: .songs))
        VStack(spacing: 6) {
            HStack {
                Text("LIBRARY").microLabel().foregroundStyle(.secondary)
                Text("\(songs.count) songs").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                SearchPill(prompt: "Filter", text: $lib.search, width: 170)
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(songs) { t in
                        DJSongRow(track: t)
                    }
                    if songs.isEmpty { Text(lib.stats.tracks == 0 ? "Add a music folder in Settings or from Library to see your tracks here." : "No songs match.").foregroundStyle(.secondary).padding(.top, 24) }
                }
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.04)))
        .frame(maxHeight: .infinity)
    }
}

/// Lets `DJBrowser` find the library model without threading it through every initialiser.
@MainActor final class LibraryModelBridge { static let shared = LibraryModelBridge(); var model: LibraryModel? }

struct DJSongRow: View {
    @EnvironmentObject var dj: DJModel
    let track: TrackDTO
    @StateObject private var hover = Box(false)
    var body: some View {
        HStack(spacing: 10) {
            Text(track.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(track.artistLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(trackQuality(track)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            Text(fmtDuration(track.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            loadButton("A", Color(red: 0.36, green: 0.80, blue: 1.0), dj.a)
            loadButton("B", Color(red: 1.0, green: 0.45, blue: 0.70), dj.b)
        }
        .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover.v ? 0.07 : 0)))
        .onHover { hover.v = $0 }
        .onTapGesture(count: 2) { dj.loadIntoFreeDeck(dj.track(track)) }
    }

    private func loadButton(_ title: String, _ color: Color, _ deck: DJDeck) -> some View {
        Button { dj.load(dj.track(track), into: deck) } label: {
            Text(title).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.85)).frame(width: 26, height: 22).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(hover.v ? 1 : 0.7)))
        }.buttonStyle(.plain).help("Load on deck \(title)")
    }
}

extension DJModel {
    func track(_ t: TrackDTO) -> DJTrack { DJTrack(path: t.path, title: t.title, artist: t.artistLine, album: t.releaseTitle ?? "") }
}

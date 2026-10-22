import SwiftUI
import CoreAudio

enum DJColor {
    static let a = Color(red: 0.36, green: 0.80, blue: 1.0)
    static let b = Color(red: 1.0, green: 0.45, blue: 0.70)
    static let pads: [Color] = [Color(red: 1.0, green: 0.38, blue: 0.38), Color(red: 1.0, green: 0.68, blue: 0.25), Color(red: 0.42, green: 0.90, blue: 0.5), Color(red: 0.45, green: 0.62, blue: 1.0)]
    static let loop = Color(red: 0.42, green: 0.90, blue: 0.5)
    static func deck(_ name: String) -> Color { name == "A" ? a : b }
}

/// A small labelled push button. `active` lights it in `color`.
struct PadButton: View {
    let label: String
    var icon: String?
    var color: Color = Brand.accent
    var active = false
    var width: CGFloat = 34
    var height: CGFloat = 26
    var enabled = true
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) } else { Text(label).font(.system(size: 10.5, weight: .bold, design: .monospaced)) }
            }
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? AnyShapeStyle(color) : AnyShapeStyle(Brand.ink.opacity(0.10))))
            .foregroundStyle(active ? Color.black.opacity(0.85) : Brand.ink)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain).disabled(!enabled).help(help ?? label)
    }
}

/// Hold to apply, release to stop: for pitch bend.
struct HoldButton: View {
    let icon: String
    let onChange: (Bool) -> Void
    @StateObject private var down = Box(false)
    var body: some View {
        Image(systemName: icon).font(.system(size: 11, weight: .bold)).frame(width: 30, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(down.v ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Brand.ink.opacity(0.10))))
            .foregroundStyle(down.v ? Color.black.opacity(0.85) : Brand.ink)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if !down.v { down.v = true; onChange(true) } }.onEnded { _ in down.v = false; onChange(false) })
    }
}

struct KeyChip: View {
    let key: MusicalKey?
    let other: MusicalKey?
    var body: some View {
        let ok = key != nil && other != nil && key!.compatible(with: other!)
        Text(key.map { $0.camelot } ?? "—").font(.system(size: 12, weight: .bold, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(ok ? Color.green.opacity(0.28) : Brand.ink.opacity(0.10)))
            .foregroundStyle(ok ? Color.green : Brand.ink)
            .help(key.map { "\($0.name) (\($0.camelot))" + (ok ? " — mixes with the other deck" : "") } ?? "Key not detected")
    }
}

// MARK: - Deck

struct DeckPanel: View {
    @ObservedObject var deck: DJDeck
    @EnvironmentObject var model: DJModel
    private var color: Color { DJColor.deck(deck.name) }
    @StateObject private var dropping = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            Waveform(deck: deck, tint: color).frame(height: 58)
            transport
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    hotCues
                    loops
                    effects
                }
                pitchColumn
            }
            if let e = deck.error { Text(e).font(.caption).foregroundStyle(.orange) }
        }
        .padding(12).frame(maxHeight: .infinity, alignment: .top).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.ink.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(deck.playing ? color.opacity(0.6) : Brand.ink.opacity(0.08), lineWidth: deck.playing ? 1.4 : 0.8))
        .animation(.easeOut(duration: 0.2), value: deck.playing)
        .overlay { if dropping.v { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color, style: StrokeStyle(lineWidth: 2.5, dash: [8, 5])).background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.12))).overlay(Label("Load on deck \(deck.name)", systemImage: "arrow.down.circle.fill").font(.headline)).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { dropping.v }, set: { dropping.v = $0 })) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.loadFile(url, into: deck) } }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text(deck.name).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.85)).frame(width: 28, height: 28).background(Circle().fill(color))
            VStack(alignment: .leading, spacing: 1) {
                Text(deck.track?.title ?? "Empty").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(deck.track.map { $0.artist.isEmpty ? $0.album : $0.artist } ?? "Load a track from the list below").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            KeyChip(key: deck.key, other: model.other(deck).key)
            VStack(alignment: .trailing, spacing: 1) {
                Text(deck.effectiveBPM.map { String(format: "%.1f", $0) } ?? (deck.analyzing ? "…" : "—")).font(.system(size: 19, weight: .semibold, design: .monospaced)).foregroundStyle(color)
                Text("BPM").microLabel().foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(clock(deck.position)).font(.system(size: 15, weight: .semibold, design: .monospaced)).monospacedDigit()
                Text("-" + clock(max(0, (deck.duration - deck.position) / max(0.5, 1 + deck.pitch)))).font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 7) {
            deckButton("CUE", icon: "arrow.uturn.backward", help: "Set the cue point when stopped; return to it when playing") { deck.cuePressed() }
            Button { deck.togglePlay() } label: {
                Image(systemName: deck.playing ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .bold)).frame(width: 64, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(deck.playing ? AnyShapeStyle(color) : AnyShapeStyle(Brand.ink.opacity(0.14))))
                    .foregroundStyle(deck.playing ? Color.black.opacity(0.85) : Brand.ink)
            }.buttonStyle(.plain).disabled(!deck.isLoaded).keyboardShortcut(deck.name == "A" ? "a" : "l", modifiers: .command)
            deckButton("SYNC", icon: "metronome", help: "Match the other deck's tempo") { model.sync(deck) }.disabled(deck.bpm == nil || model.other(deck).bpm == nil)
            deckButton("BEAT", icon: "arrow.triangle.2.circlepath", help: "Match the tempo and line the beats up with the other deck") { model.beatSync(deck) }.disabled(deck.bpm == nil || model.other(deck).bpm == nil)
            Spacer(minLength: 2)
            HoldButton(icon: "minus") { deck.bend($0 ? -1 : 0) }.help("Hold to slow down briefly (pitch bend)")
            HoldButton(icon: "plus") { deck.bend($0 ? 1 : 0) }.help("Hold to speed up briefly (pitch bend)")
        }
    }

    private var hotCues: some View {
        HStack(spacing: 5) {
            Text("CUES").microLabel().foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            ForEach(0..<4, id: \.self) { i in
                let set = deck.hotCues[i] != nil
                Button { deck.hotCue(i) } label: {
                    Text(set ? clock(deck.hotCues[i]!) : "\(i + 1)").font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(set ? AnyShapeStyle(DJColor.pads[i]) : AnyShapeStyle(Brand.ink.opacity(0.10))))
                        .foregroundStyle(set ? Color.black.opacity(0.85) : Brand.ink.opacity(0.7))
                }
                .buttonStyle(.plain).disabled(!deck.isLoaded)
                .help(set ? "Jump to this cue (right-click to clear)" : "Store the current position")
                .contextMenu { Button("Clear cue \(i + 1)") { deck.clearHotCue(i) }.disabled(!set) }
            }
        }
    }

    private var loops: some View {
        HStack(spacing: 4) {
            Text("LOOP").microLabel().foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            PadButton(label: "IN", width: 28, enabled: deck.isLoaded, help: "Loop start") { deck.setLoopIn() }
            PadButton(label: "OUT", width: 32, enabled: deck.isLoaded && deck.loopIn != nil, help: "Loop end — starts the loop") { deck.setLoopOut() }
            ForEach([1.0, 2, 4, 8], id: \.self) { n in
                PadButton(label: "\(Int(n))", color: DJColor.loop, active: deck.loopActive && abs((deck.loopBeats ?? 0) - n) < 0.05, width: 24, enabled: deck.isLoaded, help: "Loop \(Int(n)) beat\(n == 1 ? "" : "s") from here") { deck.autoLoop(beats: n) }
            }
            PadButton(label: "½", width: 24, enabled: deck.loopIn != nil, help: "Halve the loop") { deck.scaleLoop(0.5) }
            PadButton(label: "×2", width: 26, enabled: deck.loopIn != nil, help: "Double the loop") { deck.scaleLoop(2) }
            PadButton(label: "LOOP", icon: nil, color: DJColor.loop, active: deck.loopActive, width: 42, enabled: deck.isLoaded, help: "Loop on / off") { deck.toggleLoop() }
        }
    }

    private var effects: some View {
        HStack(spacing: 8) {
            Text("FX").microLabel().foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            Picker("", selection: $deck.fxKind) { ForEach(DeckFXKind.allCases.filter { $0 != .off }) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 84)
            PadButton(label: "ON", color: color, active: deck.fxOn, width: 34, help: "Effect on / off") { deck.fxOn.toggle() }
            Knob(value: $deck.fxWet, range: 0...1, label: "WET", tint: color, size: 28, reset: 0.35)
            Knob(value: $deck.fxParam, range: 0...1, label: deck.fxKind.paramLabel, tint: color, size: 28, reset: 0.5)
        }
    }

    private var pitchColumn: some View {
        VStack(spacing: 5) {
            Text(String(format: "%+.1f%%", deck.pitch * 100)).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            VerticalFader(value: Binding(get: { deck.pitch * 100 }, set: { deck.pitch = max(-deck.pitchRange, min(deck.pitchRange, $0 / 100)) }),
                          range: -(deck.pitchRange * 100)...(deck.pitchRange * 100), step: 0.1, height: 104, enabled: deck.isLoaded)
            Picker("", selection: $deck.pitchRange) { Text("8").tag(0.08); Text("16").tag(0.16) }.pickerStyle(.segmented).labelsHidden().frame(width: 56)
            Text("PITCH ±%").microLabel().foregroundStyle(.secondary)
        }.frame(width: 70)
    }

    private func deckButton(_ title: String, icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)); Text(title).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.6) }
                .frame(width: 44, height: 40).background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Brand.ink.opacity(0.09)))
        }.buttonStyle(.plain).disabled(!deck.isLoaded).help(help)
    }
}

/// The track's waveform overview with the playhead, cue point, hot cues and loop; click or drag to seek.
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
                let dur = deck.duration
                func x(_ t: Double) -> CGFloat { size.width * CGFloat(t / dur) }
                if let li = deck.loopIn, let lo = deck.loopOut {
                    ctx.fill(Path(CGRect(x: x(li), y: 0, width: max(2, x(lo) - x(li)), height: size.height)), with: .color(DJColor.loop.opacity(deck.loopActive ? 0.30 : 0.12)))
                }
                let bars = Int(size.width / 2)
                let playedX = x(deck.position)
                for i in 0..<bars {
                    let lo = i * a.peaks.count / bars, hi = max(lo + 1, (i + 1) * a.peaks.count / bars)
                    var p: Float = 0; for k in lo..<min(hi, a.peaks.count) { p = max(p, a.peaks[k]) }
                    let bh = max(2, CGFloat(p) * (size.height - 8))
                    let bx = CGFloat(i) * 2
                    ctx.fill(Path(roundedRect: CGRect(x: bx, y: (size.height - bh) / 2, width: 1.4, height: bh), cornerRadius: 0.7), with: .color(bx <= playedX ? tint : .white.opacity(0.32)))
                }
                for (i, c) in deck.hotCues.enumerated() { if let c { ctx.fill(Path(CGRect(x: x(c) - 1, y: 0, width: 2, height: size.height)), with: .color(DJColor.pads[i])) } }
                ctx.fill(Path(CGRect(x: x(deck.cue) - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
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
        HStack(alignment: .top, spacing: 8) { ChannelStrip(deck: model.a); ChannelStrip(deck: model.b) }
            .padding(10).frame(width: 232).frame(maxHeight: .infinity).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.ink.opacity(0.08), lineWidth: 0.8))
    }
}

struct ChannelStrip: View {
    @ObservedObject var deck: DJDeck
    private var color: Color { DJColor.deck(deck.name) }
    var body: some View {
        VStack(spacing: 5) {
            Text(deck.name).font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(color)
            Knob(value: $deck.trim, range: -12...12, label: "TRIM", tint: color, size: 28)
            Knob(value: $deck.high, range: DJMath.eqRange, label: "HI", tint: color, size: 30)
            Knob(value: $deck.mid, range: DJMath.eqRange, label: "MID", tint: color, size: 30)
            Knob(value: $deck.low, range: DJMath.eqRange, label: "LOW", tint: color, size: 30)
            Knob(value: $deck.filter, range: -1...1, label: "FILTER", tint: .orange, size: 30)
            PadButton(label: "PFL", icon: "headphones", color: color, active: deck.pfl, width: 44, help: "Listen to this deck in the headphones, before its fader") { deck.pfl.toggle() }
            HStack(spacing: 5) {
                VerticalFader(value: $deck.channel, range: 0...1, step: 0.01, height: 78)
                LevelBar(value: max(deck.peakL, deck.peakR)).frame(height: 78)
            }
        }.frame(maxWidth: .infinity)
    }
}

/// The bottom bar: master EQ and level, limiter, crossfader, headphones.
struct MasterBar: View {
    @EnvironmentObject var model: DJModel
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        HStack(spacing: 14) {
            master
            Divider().frame(height: 46)
            crossfader
            Divider().frame(height: 46)
            phones
        }
        .padding(.horizontal, 14).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.ink.opacity(0.05)))
    }

    private var master: some View {
        HStack(spacing: 8) {
            VStack(spacing: 1) { Text("MASTER").microLabel().foregroundStyle(.secondary); Text("OUT").microLabel().foregroundStyle(.tertiary) }
            Knob(value: $model.masterHigh, range: DJMath.eqRange, label: "HI", tint: Brand.accent, size: 28)
            Knob(value: $model.masterMid, range: DJMath.eqRange, label: "MID", tint: Brand.accent, size: 28)
            Knob(value: $model.masterLow, range: DJMath.eqRange, label: "LOW", tint: Brand.accent, size: 28)
            Knob(value: $model.masterLevel, range: 0...1.25, label: "LEVEL", tint: Brand.accent, size: 28, reset: 1)
            HStack(spacing: 3) { LevelBar(value: model.meterL).frame(height: 34); LevelBar(value: model.meterR).frame(height: 34) }
            VStack(spacing: 2) {
                PadButton(label: "LIMIT", color: .orange, active: model.limiter, width: 46, help: "Brick-wall limiter at −0.3 dBFS: the mix cannot clip") { model.limiter.toggle() }
                Text(model.limiterReduction > 0.3 ? String(format: "−%.1f dB", model.limiterReduction) : " ").font(.system(size: 9, design: .monospaced)).foregroundStyle(.orange)
            }
        }
    }

    private var crossfader: some View {
        HStack(spacing: 10) {
            Text("A").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(DJColor.a)
            VStack(spacing: 2) {
                FluidSlider(value: $model.crossfader, range: -1...1, tint: Brand.ink.opacity(0.9), restingHeight: 5, enabled: true, bubble: { $0 == 0 ? "centre" : String(format: "%+.0f%%", $0 * 100) })
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.crossfader = 0 })
                Text("CROSSFADER").microLabel().foregroundStyle(.secondary)
            }
            Text("B").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(DJColor.b)
            Picker("", selection: $model.curve) { ForEach(CrossfaderCurve.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
        }
    }

    private var phones: some View {
        HStack(spacing: 8) {
            Menu {
                Button { model.cueRoute = .none } label: { Label("Off", systemImage: model.cueRoute == .none ? "checkmark" : "") }
                Button { model.cueRoute = .channels34 } label: { Label("Outputs 3–4 of the main device", systemImage: model.cueRoute == .channels34 ? "checkmark" : "") }
                Divider()
                ForEach(m.devices.filter { $0.id != m.deviceID }) { d in
                    Button { model.cueRoute = .device(d.id) } label: { Label(d.name, systemImage: model.cueRoute == .device(d.id) ? "checkmark" : "") }
                }
            } label: { Label(routeTitle, systemImage: "headphones") }
                .menuStyle(.borderlessButton).fixedSize().help("Where the headphone (PFL) mix is played. Pick a second audio device, or outputs 3–4 of a multichannel interface.")
            Knob(value: $model.cueMix, range: 0...1, label: "CUE/MST", tint: .teal, size: 28, reset: 0)
            Knob(value: $model.cueLevel, range: 0...1.5, label: "PHONES", tint: .teal, size: 28, reset: 0.8)
        }
    }

    private var routeTitle: String {
        switch model.cueRoute {
        case .none: "Phones: off"
        case .channels34: "Phones: out 3–4"
        case .device(let id): "Phones: " + (m.devices.first { $0.id == id }?.name ?? "device")
        }
    }
}

// MARK: - Smart DJ

struct SmartDJPanel: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var model: DJModel
    @ObservedObject var smart: SmartDJService
    @StateObject private var prompt = Box("")

    private static let examples = ["10 upbeat electronic tracks for a workout", "calm music to study", "8 songs from the 90s", "something slow and sad"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Brand.accent)
                Text("SMART DJ").microLabel()
                statusView
                Spacer()
                if smart.modelActive { Text("on-device model").font(.system(size: 11)).foregroundStyle(.secondary).help("\(SmartDJService.modelID), running in a separate process that quits when Smart DJ is switched off") }
            }
            HStack(spacing: 8) {
                TextField("Ask for a set: “10 upbeat electronic tracks for a workout”", text: Binding(get: { prompt.v }, set: { prompt.v = $0 }), onCommit: ask)
                    .textFieldStyle(.roundedBorder).disabled(!canAsk)
                Button { ask() } label: { Label("Pick", systemImage: "wand.and.stars") }.buttonStyle(.borderedProminent).controlSize(.small).disabled(!canAsk || prompt.v.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if smart.suggestion == nil, canAsk {
                HStack(spacing: 6) {
                    ForEach(Self.examples, id: \.self) { e in Button(e) { prompt.v = e; ask() }.buttonStyle(.bordered).controlSize(.mini) }
                }
            }
            if let p = smart.modelProblem { Text(p).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let s = smart.suggestion { result(s) }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Brand.ink.opacity(0.06)))
        .onReceive(smart.$suggestion.dropFirst()) { s in if let s, !s.tracks.isEmpty { model.loadSet(s.tracks.map { model.track($0) }) } }
    }

    private var canAsk: Bool { if case .ready = smart.state { return true }; return false }

    @ViewBuilder private var statusView: some View {
        switch smart.state {
        case .off: Text("off").font(.system(size: 12.5)).foregroundStyle(.secondary)
        case .loading(let f, let msg): HStack(spacing: 6) { ProgressView(value: f).frame(width: 90).controlSize(.small); Text(msg + (f > 0 && f < 1 ? " \(Int(f * 100))%" : "")).font(.system(size: 12)).foregroundStyle(.secondary) }
        case .ready: Text("ready").font(.system(size: 12.5, weight: .medium))
        case .thinking: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("choosing…").font(.system(size: 12.5)) }
        }
    }

    private func ask() { let q = prompt.v; Task { await smart.suggest(q) } }

    private func result(_ s: SmartDJSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(s.intent.summary).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(s.usedModel ? "\(s.modelPicked) chosen by the model" + (s.filled > 0 ? ", \(s.filled) by ranking" : "") : "chosen by ranking").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(String(format: "%.1f s", s.seconds)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            if let n = s.note { Text(n).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            ForEach(Array(s.tracks.enumerated()), id: \.offset) { i, t in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                    Text(t.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(t.artistLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let b = model.info[t.path]?.bpm { Text("\(Int(b.rounded()))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                    Button("A") { model.a.load(model.track(t)) }.buttonStyle(.bordered).controlSize(.mini).help("Load on deck A")
                    Button("B") { model.b.load(model.track(t)) }.buttonStyle(.bordered).controlSize(.mini).help("Load on deck B")
                }
            }
            if !s.tracks.isEmpty {
                HStack(spacing: 8) {
                    Button { model.startSet() } label: { Label("Start set", systemImage: "play.fill") }
                    Button { model.loadSet(s.tracks.map { model.track($0) }) } label: { Label("Reload decks", systemImage: "arrow.counterclockwise") }
                    Button { m.addTracks(s.tracks, play: false) } label: { Label("Add to player queue", systemImage: "text.badge.plus") }
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

struct RemixPanel: View {
    @ObservedObject var remix: RemixController

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars").foregroundStyle(Brand.accent2)
                Text("AI REMIXER").microLabel()
                Text(remix.status).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                ForEach(Array(remix.history.suffix(6).enumerated()), id: \.offset) { _, a in
                    Text(a.title).font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Brand.accent2.opacity(0.18)))
                }
            }
            HStack(spacing: 12) {
                Text("Subtle").font(.system(size: 11)).foregroundStyle(.secondary)
                FluidSlider(value: $remix.intensity, range: 0...1, tint: Brand.accent2, restingHeight: 4, enabled: true, bubble: { $0 < 0.34 ? "subtle" : ($0 < 0.67 ? "medium" : "wild") }).frame(width: 220)
                Text("Wild").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(remix.actionCount) moves").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                Button { remix.rate(liked: true) } label: { Image(systemName: "hand.thumbsup.fill") }.disabled(!remix.canRate).help("That move worked — do more like it")
                Button { remix.rate(liked: false) } label: { Image(systemName: "hand.thumbsdown.fill") }.disabled(!remix.canRate).help("That move did not work — do less of it")
                Text("\(remix.feedbackCount) opinions learned").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.buttonStyle(.bordered).controlSize(.small)
            Text("It performs the deck's own filter, effects, EQ and loops on the bar line. It does not separate stems or create new sounds.").font(.system(size: 10.5)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.accent2.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent2.opacity(0.35), lineWidth: 0.8))
    }
}

// MARK: - The console

struct DJView: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var dj: DJModel

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                DeckPanel(deck: dj.a)
                MixerPanel()
                DeckPanel(deck: dj.b)
            }
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 10) {
                    MasterBar()
                    if dj.smart.isEnabled { SmartDJPanel(smart: dj.smart) }
                    if dj.remix.enabled { RemixPanel(remix: dj.remix) }
                    DJBrowser().frame(minHeight: 340)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 0).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            m.library.category = .songs
            let lib = m.library
            dj.smart.library = { [weak lib, weak dj] in
                guard let lib, let dj else { return [] }
                let all = lib.store?.allTracks(offset: 0, limit: 200_000) ?? lib.songs
                return SmartDJService.tracks(from: all) { dj.info[$0] ?? AnalysisCache.shared.cached(path: $0) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("DJ").font(.system(size: 22, weight: .heavy, design: .rounded)).tracking(1)
            Button {
                if dj.smart.isEnabled { dj.smart.disable() } else { dj.smart.enable() }
            } label: {
                Label(dj.smart.isEnabled ? "Smart DJ on" : "Smart DJ", systemImage: "sparkles").font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(dj.smart.isEnabled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.ink.opacity(0.10))))
                    .foregroundStyle(dj.smart.isEnabled ? Color.black.opacity(0.85) : Brand.ink)
            }.buttonStyle(.plain).help("Ask for a set in your own words: an on-device language model picks the songs. It is loaded when you switch this on and unloaded when you switch it off.")
            Button { dj.remix.enabled.toggle() } label: {
                Label(dj.remix.enabled ? "Remix on" : "Remix", systemImage: "wand.and.stars").font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(dj.remix.enabled ? AnyShapeStyle(Brand.accent2) : AnyShapeStyle(Brand.ink.opacity(0.10))))
                    .foregroundStyle(dj.remix.enabled ? Color.black.opacity(0.85) : Brand.ink)
            }.buttonStyle(.plain).help("An AI remixer performs filter sweeps, echoes, loop rolls, drops and risers on the playing deck")
            Button { dj.quantize.toggle() } label: {
                Label("Quantize", systemImage: "square.grid.3x1.below.line.grid.1x2").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(dj.quantize ? AnyShapeStyle(Brand.accent.opacity(0.35)) : AnyShapeStyle(Brand.ink.opacity(0.08))))
            }.buttonStyle(.plain).help("Snap cues and loops to the beat grid")
            Spacer()
            if let e = dj.outputError { Text(e).font(.system(size: 11.5)).foregroundStyle(.orange).lineLimit(1) }
            Button {
                if dj.recording { dj.stopRecording() } else { dj.startRecording() }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 9, height: 9).opacity(dj.recording ? 1 : 0.55)
                    Text(dj.recording ? clock(dj.recordedSeconds) : "REC").font(.system(size: 11.5, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 11).padding(.vertical, 5).background(Capsule().fill(dj.recording ? Color.red.opacity(0.25) : Brand.ink.opacity(0.08)))
            }.buttonStyle(.plain).help(dj.recording ? "Stop recording" : "Record the master mix to a WAV file in Music/Aureon Mixes")
            DJSwitch(inSidebar: false)
        }
        .padding(.leading, 78).frame(height: WindowChrome.band - 6)
    }
}

// MARK: - Library browser

struct DJBrowser: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var dj: DJModel
    @ObservedObject var lib: LibraryModel

    init() { _lib = ObservedObject(wrappedValue: LibraryModelBridge.shared.model!) }

    var body: some View {
        let songs = lib.orderedSongs(ViewOptions.defaults(for: .songs))
        VStack(spacing: 6) {
            HStack {
                Text("LIBRARY").microLabel().foregroundStyle(.secondary)
                Text("\(songs.count) songs").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if let p = dj.analysisProgress { ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 90).controlSize(.small); Text("\(p.done)/\(p.total)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                Button { dj.analyzeLibrary(songs.map { $0.path }) } label: { Label(dj.analysisProgress == nil ? "Analyse all" : "Stop", systemImage: dj.analysisProgress == nil ? "waveform.path.ecg" : "stop.fill") }
                    .buttonStyle(.bordered).controlSize(.small).help("Detect tempo and key for every song so they show here and Smart DJ can match tempo")
                SearchPill(prompt: "Filter", text: $lib.search, width: 170)
            }
            HStack(spacing: 10) {
                Text("TITLE").frame(maxWidth: .infinity, alignment: .leading); Text("ARTIST").frame(maxWidth: .infinity, alignment: .leading)
                Text("BPM").frame(width: 44, alignment: .trailing); Text("KEY").frame(width: 38); Text("ENERGY").frame(width: 46); Text("TIME").frame(width: 44, alignment: .trailing)
                Color.clear.frame(width: 62, height: 1)
            }.microLabel().foregroundStyle(.tertiary).padding(.horizontal, 8)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(songs) { t in DJSongRow(track: t) }
                    if songs.isEmpty { Text(lib.stats.tracks == 0 ? "Add a music folder in Settings or from Library to see your tracks here." : "No songs match.").foregroundStyle(.secondary).padding(.top, 24) }
                }
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.ink.opacity(0.04)))
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
        let info = dj.info[track.path]
        let playing = dj.decks.first { $0.playing }
        let keyOK = info?.key != nil && playing?.key != nil && info!.key!.compatible(with: playing!.key!)
        let tempoOK = info?.bpm != nil && playing?.effectiveBPM != nil && abs(info!.bpm! / playing!.effectiveBPM! - 1) < 0.06
        HStack(spacing: 10) {
            Text(track.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(track.artistLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(info?.bpm.map { String(format: "%.0f", $0) } ?? "—").font(.system(size: 11.5, weight: tempoOK ? .bold : .regular, design: .monospaced)).foregroundStyle(tempoOK ? Color.green : .secondary).frame(width: 44, alignment: .trailing)
            Text(info?.key?.camelot ?? "—").font(.system(size: 11.5, weight: keyOK ? .bold : .regular, design: .monospaced)).foregroundStyle(keyOK ? Color.green : .secondary).frame(width: 38)
            EnergyDots(value: info?.energy).frame(width: 46)
            Text(fmtDuration(track.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            loadButton("A", DJColor.a, dj.a)
            loadButton("B", DJColor.b, dj.b)
        }
        .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.07 : 0)))
        .onHover { hover.v = $0 }
        .onAppear { dj.requestInfo(track.path) }
        .onTapGesture(count: 2) { dj.loadIntoFreeDeck(dj.track(track)) }
    }

    private func loadButton(_ title: String, _ color: Color, _ deck: DJDeck) -> some View {
        Button { dj.load(dj.track(track), into: deck) } label: {
            Text(title).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.85)).frame(width: 26, height: 22).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(hover.v ? 1 : 0.7)))
        }.buttonStyle(.plain).help("Load on deck \(title)")
    }
}

struct EnergyDots: View {
    let value: Double?
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Circle().fill(value.map { Double(i) < $0 * 5 - 0.001 ? Brand.accent : Brand.ink.opacity(0.14) } ?? Brand.ink.opacity(0.08)).frame(width: 5, height: 5)
            }
        }.help(value.map { String(format: "Energy %.0f%%", $0 * 100) } ?? "Not analysed yet")
    }
}

extension DJModel {
    func track(_ t: TrackDTO) -> DJTrack { DJTrack(path: t.path, title: t.title, artist: t.artistLine, album: t.releaseTitle ?? "") }
}

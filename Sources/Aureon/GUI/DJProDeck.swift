import SwiftUI
import AppKit

/// One deck of the Pro console: header, modes beside the disc, tempo and pitch, transport, loop block and the pad bank.
struct ProDeck: View {
    @ObservedObject var deck: DJDeck
    @EnvironmentObject var model: DJModel
    let width: CGFloat
    @State private var dropping = false
    @ObservedObject private var covers = DJCovers.shared

    private var color: Color { PC.deck(deck.name) }

    var body: some View {
        PCPanel(accent: color) {
            VStack(spacing: 8) {
                header
                middle
                transport
                loopBlock
                Spacer(minLength: 0)
                padBank
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: width)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10).strokeBorder(color, style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                    .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
                    .overlay(Text("Load on deck \(deck.name)").font(PC.sans(14, .semibold)).foregroundColor(PC.ink)).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.loadFile(url, into: deck) } }
            }
            return true
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 9) {
            cover.frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text(deck.track?.title ?? "Empty").font(PC.sans(14, .semibold)).foregroundColor(PC.ink).lineLimit(1)
                Text(deck.track.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "Load a track from the library").font(PC.sans(11.5)).foregroundColor(PC.ink2).lineLimit(1)
            }
            Spacer(minLength: 4)
            let shifted = DJProMath.shifted(deck.key, semitones: deck.keyShift)
            let other = model.other(deck).key
            let ok = shifted != nil && other != nil && shifted!.compatible(with: other!)
            Text(shifted?.camelot ?? "—").font(PC.mono(12)).foregroundColor(ok ? PC.ok : color).padding(.horizontal, 8).frame(height: 24).background(RoundedRectangle(cornerRadius: 6).fill(PC.s3))
                .help(shifted.map { $0.name + (ok ? " — mixes with the other deck" : "") } ?? "Key not detected")
            Text(shifted.map { ($0.minor ? "m " : "M ") + MusicalKey.names[$0.pitchClass % 12] } ?? "—").font(PC.mono(12)).foregroundColor(PC.ink).padding(.horizontal, 8).frame(height: 24).background(RoundedRectangle(cornerRadius: 6).fill(PC.s3))
            ProRemaining(deck: deck)
        }
        .frame(height: 48)
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(LinearGradient(colors: [color.opacity(0.7), PC.s3], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let p = deck.track?.path, let img = covers.image(for: p) { Image(nsImage: img).resizable().scaledToFill() }
            else { Text(deck.name).font(PC.mono(18)).foregroundColor(Color.white.opacity(0.7)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7)).onAppear { if let p = deck.track?.path { _ = covers.image(for: p) } }
    }

    // MARK: modes, disc, tempo, pitch

    private var middle: some View {
        let jog = DJProMetrics.jog(deckWidth: width)
        return HStack(alignment: .top, spacing: 10) {
            modes.frame(width: DJProMetrics.modesColumn)
            Spacer(minLength: 0)
            ProJog(deck: deck, size: jog)
            Spacer(minLength: 0)
            tempo.frame(width: DJProMetrics.tempoBlock)
            pitch.frame(width: DJProMetrics.pitchBlock)
        }
    }

    private var modes: some View {
        VStack(spacing: 5) {
            PCLabel("MODES")
            PCKey(title: "SLIP", on: deck.slip, color: color, height: 26, help: "While looping, reversing or scratching, the track carries on underneath and comes back to where it would have been") { deck.slip.toggle() }
            PCKey(title: "REVERSE", on: deck.reverse, color: color, height: 26, enabled: deck.isLoaded, size: 9.5, help: "Play the track backwards") { deck.reverse.toggle() }
            PCKey(title: "SCRATCH", on: deck.scratchEnabled, color: color, height: 26, size: 9.5, help: "Dragging the disc scratches the track; off, it only nudges the tempo") { deck.scratchEnabled.toggle() }
            PCKey(title: "KEYLOCK", on: deck.keyLock, color: color, height: 26, size: 9.5, help: "Keep the key when the tempo changes") { deck.keyLock.toggle() }
            PCKey(title: "QUANTIZE", on: model.quantize, color: color, height: 26, size: 9, help: "Snap cues and loops to the beat grid") { model.quantize.toggle() }
            PCKey(title: "GRID ✎", on: deck.gridEdit, color: color, height: 26, enabled: deck.analysis?.firstBeat != nil, size: 10, help: "Edit the beat grid: move it with the buttons or the scroll wheel") { deck.gridEdit.toggle() }
        }
    }

    private var tempo: some View {
        PCCluster {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(deck.effectiveBPM.map { String(format: "%.2f", $0) } ?? (deck.analyzing ? "…" : "—")).font(PC.mono(21)).foregroundColor(color).lineLimit(1).minimumScaleFactor(0.7)
                Text(String(format: "%+.1f%%", deck.pitch * 100)).font(PC.mono(9.5, .medium)).foregroundColor(PC.ink2).lineLimit(1)
            }.frame(height: 24)
            HStack(spacing: 4) {
                PCKey(title: "SYNC", on: deck.syncOn, color: color, height: 24, enabled: deck.bpm != nil, size: 10, help: "Keep this deck's tempo on the master's") { model.setSync(deck, !deck.syncOn) }
                PCKey(title: "MASTER", on: deck.isMaster, color: color, height: 24, size: 9, help: "Make this the deck the others follow") { model.setMaster(deck) }
            }
            HStack(spacing: 4) {
                PCKey(title: "TAP", height: 24, enabled: deck.isLoaded, help: "Tap the beat to set the tempo by hand") { deck.tap() }
                PCKey(title: "RESET", height: 24, enabled: deck.isLoaded, size: 9.5, help: "Back to the detected tempo and zero pitch") { deck.resetBPM(); deck.pitch = 0; deck.syncOn = false }
            }
            PCLabel("KEY SHIFT")
            HStack(spacing: 3) {
                PCKey(title: "−", width: 26, height: 24, enabled: deck.keyShift > -12, help: "A semitone down") { deck.keyShift -= 1 }
                PCKey(title: deck.keyShift == 0 ? "0 st" : String(format: "%+d st", deck.keyShift), on: deck.keyShift != 0, color: color, height: 24, size: 10, help: "Press to return to the original key") { deck.keyShift = 0 }
                PCKey(title: "+", width: 26, height: 24, enabled: deck.keyShift < 12, help: "A semitone up") { deck.keyShift += 1 }
            }
            if deck.gridEdit {
                PCLabel("BEAT GRID")
                HStack(spacing: 3) {
                    PCKey(title: "◂", height: 24, help: "Move the grid 5 ms earlier") { deck.nudgeGrid(by: -0.005) }
                    PCKey(title: "▸", height: 24, help: "Move the grid 5 ms later") { deck.nudgeGrid(by: 0.005) }
                    PCKey(title: "SET", height: 24, size: 9, help: "Put a beat of the grid at the playhead") { deck.setGridHere() }
                }
                Text(String(format: "%+.0f ms", deck.gridOffset * 1000)).font(PC.mono(9.5, .medium)).foregroundColor(PC.ink2).frame(maxWidth: .infinity, alignment: .center)
            } else {
                PCLabel("BEAT JUMP")
                HStack(spacing: 3) {
                    ForEach([(-4.0, "◂4"), (-1, "◂1"), (1, "1▸"), (4, "4▸")], id: \.0) { n, t in
                        PCKey(title: t, height: 24, enabled: deck.isLoaded && deck.bpm != nil, size: 9.5, help: "Jump \(Int(abs(n))) beat\(abs(n) == 1 ? "" : "s") \(n > 0 ? "forward" : "back")") { deck.beatJump(n) }
                    }
                }
            }
        }
    }

    private var pitch: some View {
        HStack(alignment: .top, spacing: 5) {
            PCFader(value: Binding(get: { deck.pitch * 100 }, set: { deck.pitch = max(-deck.pitchRange, min(deck.pitchRange, $0 / 100)) }),
                    range: -(deck.pitchRange * 100)...(deck.pitchRange * 100), height: 168, width: 22, tint: color, reset: 0, step: 0.05, enabled: deck.isLoaded, centerMark: true)
            VStack(spacing: 4) {
                PCLabel("RANGE")
                ForEach([(0.08, "±8"), (0.16, "±16"), (0.5, "±50")], id: \.0) { r, t in
                    PCKey(title: t, on: deck.pitchRange == r, color: color, width: 28, height: 24, size: 9.5, help: "Pitch fader range") {
                        deck.pitchRange = r; deck.pitch = max(-r, min(r, deck.pitch))
                    }
                }
            }
        }
    }

    // MARK: transport and loops

    private var transport: some View {
        HStack(spacing: 6) {
            transportButton("CUE", on: false, width: 74, help: "Set the cue point when stopped; return to it when playing") { deck.cuePressed() }
            transportButton(deck.playing ? "❚❚ PAUSE" : "▶ PLAY", on: deck.playing, width: nil, help: "Play or pause") { deck.togglePlay() }
            transportButton("◂◂ BRAKE", on: false, width: 92, help: "Slow to a stop, like a turntable") { deck.brake() }
            transportButton("SMP", on: deck.padMode == .sampler, width: 56, help: "Show the sampler pads") { deck.padMode = deck.padMode == .sampler ? .cues : .sampler }
        }
    }

    private func transportButton(_ title: String, on: Bool, width: CGFloat?, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(PC.mono(12)).lineLimit(1).minimumScaleFactor(0.75).frame(width: width).frame(maxWidth: width == nil ? .infinity : nil).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? color : PC.s3))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? color : PC.line, lineWidth: 0.8))
                .foregroundColor(on ? Color.black.opacity(0.85) : PC.ink)
        }
        .buttonStyle(.plain).disabled(!deck.isLoaded).opacity(deck.isLoaded ? 1 : 0.45).help(help)
    }

    private var loopBlock: some View {
        PCCluster(title: "LOOP · SIZE") {
            HStack(spacing: 3) {
                ForEach([0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32], id: \.self) { b in
                    PCKey(title: DJPadSets.label(beats: b), on: deck.loopActive ? (deck.loopBeats.map { abs($0 - b) < 0.05 } ?? false) : deck.loopSize == b, color: PC.ok, height: 24, enabled: deck.isLoaded && deck.bpm != nil, size: 10, help: "Loop \(DJPadSets.label(beats: b)) beat\(b == 1 ? "" : "s")") { deck.loopSizePressed(b) }
                }
            }
            HStack(spacing: 3) {
                PCKey(title: "IN", height: 24, enabled: deck.isLoaded, help: "Loop start") { deck.setLoopIn() }
                PCKey(title: "OUT", height: 24, enabled: deck.loopIn != nil, help: "Loop end — starts the loop") { deck.setLoopOut() }
                PCKey(title: "RELOOP", on: deck.loopActive, color: PC.ok, height: 24, enabled: deck.loopIn != nil && deck.loopOut != nil, size: 9, help: "Back into the last loop, from its start") { if deck.loopActive { deck.toggleLoop() } else { deck.reloop() } }
                PCKey(title: "◂ MOVE", height: 24, enabled: deck.loopIn != nil && deck.loopOut != nil, size: 9, help: "Move the loop back by its length") { deck.moveLoop(by: -1) }
                PCKey(title: "MOVE ▸", height: 24, enabled: deck.loopIn != nil && deck.loopOut != nil, size: 9, help: "Move the loop forward by its length") { deck.moveLoop(by: 1) }
                PCHold(title: "ROLL", color: PC.ok, height: 24, enabled: deck.isLoaded && deck.bpm != nil, help: "Hold: loop the selected size; release: carry on where the track would have been") { down in
                    if down { deck.rollBegin(beats: deck.loopSize) } else { deck.rollEnd() }
                }
            }
        }
    }

    // MARK: pads

    private var padBank: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 3) {
                ForEach(PadMode.allCases) { mode in
                    Button { deck.padMode = mode } label: {
                        Text(mode.rawValue).font(PC.mono(9.5)).tracking(0.4).lineLimit(1).minimumScaleFactor(0.7).frame(width: 62, height: 26)
                            .background(RoundedRectangle(cornerRadius: 5).fill(deck.padMode == mode ? color : PC.s2))
                            .foregroundColor(deck.padMode == mode ? Color.black.opacity(0.85) : PC.ink2)
                    }.buttonStyle(.plain)
                }
            }
            VStack(spacing: 5) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                    ForEach(0..<8, id: \.self) { i in pad(i) }
                }
                HStack {
                    PCLabel("BANK \(deck.padBank + 1)/\(deck.padMode.banks)")
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(0..<deck.padMode.banks, id: \.self) { b in
                            Button { deck.padBank = b } label: { Circle().fill(b == deck.padBank ? color : PC.s3).frame(width: 7, height: 7).padding(4).contentShape(Rectangle()) }.buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    PCLabel(deck.padMode == .cues || deck.padMode == .sampler ? "SHIFT-CLICK = DELETE" : "")
                }
            }
        }
    }

    @ViewBuilder private func pad(_ i: Int) -> some View {
        let n = deck.padBank * 8 + i
        switch deck.padMode {
        case .cues:
            let t = deck.hotCues.indices.contains(i) ? deck.hotCues[i] : nil
            ProPad(title: "\(i + 1)", detail: t.map { clock($0) } ?? "empty", color: PC.padColors[i % PC.padColors.count], lit: t != nil && abs(deck.position - t!) < 0.25, empty: t == nil, enabled: deck.isLoaded,
                   down: { if NSEvent.modifierFlags.contains(.shift) { deck.clearHotCue(i) } else { deck.hotCue(i) } }, up: nil,
                   menu: t == nil ? [] : [("Clear cue \(i + 1)", { deck.clearHotCue(i) })])
        case .loop:
            let b = DJPadSets.loopBeats[n]
            ProPad(title: DJPadSets.label(beats: b), detail: "loop", color: PC.ok, lit: deck.loopActive && (deck.loopBeats.map { abs($0 - b) < 0.05 } ?? false), empty: false, enabled: deck.isLoaded && deck.bpm != nil,
                   down: { deck.loopSizePressed(b) }, up: nil, menu: [])
        case .roll:
            let b = DJPadSets.rollBeats[n]
            ProPad(title: DJPadSets.label(beats: b), detail: "roll", color: PC.warn, lit: false, empty: false, enabled: deck.isLoaded && deck.bpm != nil,
                   down: { deck.rollBegin(beats: b) }, up: { deck.rollEnd() }, menu: [])
        case .fx:
            let p = DJPadSets.fx[n]
            ProPad(title: p.title, detail: p.detail, color: PC.padColors[(n / 4) % PC.padColors.count], lit: false, empty: false, enabled: deck.isLoaded,
                   down: { deck.fxPadDown(p) }, up: { deck.fxPadUp() }, menu: [])
        case .slicer:
            let beat = deck.padBank * 8 + i
            let t = deck.sliceTime(bank: deck.padBank, index: i)
            ProPad(title: "\(beat + 1)", detail: t.map { clock($0) } ?? "no grid", color: PC.blue, lit: t.map { deck.position >= $0 && deck.position < $0 + (deck.beatLength ?? 0.5) } ?? false, empty: t == nil, enabled: deck.isLoaded && deck.bpm != nil,
                   down: { deck.sliceDown(bank: deck.padBank, index: i) }, up: { deck.sliceUp() }, menu: [])
        case .sampler:
            SamplerPad(deck: deck, slot: i)
        }
    }
}

/// A pad: pressed and released, with a name and a second line.
struct ProPad: View {
    let title: String
    let detail: String
    let color: Color
    let lit: Bool
    let empty: Bool
    let enabled: Bool
    let down: () -> Void
    let up: (() -> Void)?
    let menu: [(String, () -> Void)]
    @State private var pressed = false

    var body: some View {
        let on = pressed || lit
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(PC.mono(11)).lineLimit(1)
            Spacer(minLength: 0)
            Text(detail).font(PC.mono(9.5, .medium)).lineLimit(1).foregroundColor(on ? Color.black.opacity(0.75) : PC.ink2)
        }
        .foregroundColor(on ? Color.black.opacity(0.9) : (empty ? PC.ink3 : PC.ink))
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity).frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? color : (empty ? PC.s2 : color.opacity(0.18))))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(empty && !on ? PC.line : color.opacity(0.7), lineWidth: 0.9))
        .shadow(color: on ? color.opacity(0.5) : .clear, radius: 8)
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
            guard enabled, !pressed else { return }
            pressed = true; down()
        }.onEnded { _ in
            guard pressed else { return }
            pressed = false; up?()
        })
        .contextMenu { ForEach(Array(menu.enumerated()), id: \.offset) { _, item in Button(item.0) { item.1() } } }
        .onDisappear { if pressed { pressed = false; up?() } }
    }
}

/// A sampler pad: plays the slot; an empty one captures from this deck or loads a file.
struct SamplerPad: View {
    @ObservedObject var deck: DJDeck
    @EnvironmentObject var model: DJModel
    let slot: Int

    var body: some View {
        let info = model.sampleSlots[slot]
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            ProPad(title: "S\(slot + 1)", detail: info.map { String(format: "%.1f s", $0.seconds) } ?? "empty", color: PC.padColors[slot % PC.padColors.count],
                   lit: model.isSampleSounding(slot), empty: info == nil, enabled: true,
                   down: {
                       if NSEvent.modifierFlags.contains(.shift) { model.clearSample(slot) }
                       else if info != nil { model.triggerSample(slot) }
                       else if deck.isLoaded, deck.beatLength != nil { model.captureSample(from: deck, beats: 4, slot: slot) }
                       else { chooseFile() }
                   }, up: nil,
                   menu: [("Load a file…", { chooseFile() })]
                     + [1.0, 2, 4, 8].map { b in ("Capture \(DJPadSets.label(beats: b)) beats from deck \(deck.name)", { if deck.beatLength != nil { model.captureSample(from: deck, beats: b, slot: slot) } }) }
                     + (info == nil ? [] : [("Clear sample", { model.clearSample(slot) })]))
            .help(info?.name ?? "Click to capture four beats from the playing track; right-click for more")
        }
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false; p.canChooseDirectories = false
        if p.runModal() == .OK, let u = p.url { model.loadSample(url: u, slot: slot) }
    }
}

/// Time left on a deck. It follows the playhead on its own, so the header does not redraw ten times a second for it.
struct ProRemaining: View {
    @ObservedObject var deck: DJDeck
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                Text("-" + DJProMath.clock(max(0, (deck.duration - deck.livePosition(at: tl.date)) / max(0.5, abs(1 + deck.pitch))))).font(PC.mono(18)).foregroundColor(PC.ink)
            }
            PCLabel("REMAINING")
        }.frame(width: 72, alignment: .trailing)
    }
}

// MARK: - The disc

/// A vinyl disc that turns with the track. Drag it to scratch (while playing the track follows the hand; while stopped the playhead does); scroll to nudge.
struct ProJog: View {
    @ObservedObject var deck: DJDeck
    let size: CGFloat
    @State private var hover = false
    @State private var lastAngle: Double?
    @State private var lastTime = Date()
    @State private var smoothed = 0.0
    @State private var bendHold: DispatchWorkItem?
    @ObservedObject private var covers = DJCovers.shared

    private var color: Color { PC.deck(deck.name) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                ProDiscArt(color: color, cover: deck.track.flatMap { covers.image(for: $0.path) }, tag: deck.name)
                    .frame(width: size, height: size)
                    .modifier(DiscSpin(deck: deck))
                ProDiscRim(deck: deck, size: size, color: color)
                Circle().fill(AngularGradient(gradient: Gradient(stops: [.init(color: .clear, location: 0), .init(color: Color.white.opacity(0.1), location: 0.07), .init(color: .clear, location: 0.18),
                                                                        .init(color: .clear, location: 0.58), .init(color: Color.white.opacity(0.09), location: 0.62), .init(color: .clear, location: 0.7), .init(color: .clear, location: 1)]), center: .center)).allowsHitTesting(false)
                    .frame(width: size, height: size)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { d in handle(d) }.onEnded { _ in end() })
            .onHover { hover = $0 }
            .scrollAdjustable(hovering: hover) { n in
                if deck.gridEdit { deck.nudgeGrid(by: n * 0.001) }
                else if deck.playing { pulse(n > 0 ? 1 : -1) }
                else { deck.seek(to: deck.position + n * 0.02) }
                return true
            }
            .help("Drag to scratch; scroll to nudge")
            ProReadout(deck: deck).frame(height: 20)
        }
        .frame(width: size)
    }

    private func pulse(_ dir: Double) {
        deck.bend(dir)
        bendHold?.cancel()
        let w = DispatchWorkItem { deck.bend(0) }
        bendHold = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func handle(_ d: DragGesture.Value) {
        guard deck.isLoaded else { return }
        let c = size / 2
        let a = DJProMath.angle(x: Double(d.location.x - c), y: Double(d.location.y - c))
        let now = Date()
        defer { lastAngle = a; lastTime = now }
        guard let prev = lastAngle else {
            if deck.gridEdit == false, deck.scratchEnabled { deck.scratchBegin() }
            return
        }
        let turn = DJProMath.turn(from: prev, to: a), dt = now.timeIntervalSince(lastTime)
        if deck.gridEdit {
            deck.nudgeGrid(by: turn / 360 * DJProMath.secondsPerTurn * 0.05)
        } else if deck.scratchEnabled {
            let raw = DJProMath.scratchSpeed(degrees: turn, seconds: max(0.004, dt))
            smoothed += (raw - smoothed) * 0.55
            deck.scratchMove(speed: smoothed, deltaSeconds: turn / 360 * DJProMath.secondsPerTurn)
        } else if deck.playing {
            deck.bend(max(-1, min(1, turn / 12)))
        }
    }

    private func end() {
        lastAngle = nil; smoothed = 0
        deck.scratchEnd()
        if !deck.scratchEnabled { deck.bend(0) }
    }
}

/// Turns its content with the deck's position, once per display frame, without invalidating anything else.
private struct DiscSpin: ViewModifier {
    @ObservedObject var deck: DJDeck
    func body(content: Content) -> some View {
        TimelineView(.animation) { tl in
            content.rotationEffect(.degrees(DJProMath.discAngle(position: deck.livePosition(at: tl.date))))
        }
    }
}

/// The marker on the rim: how far through the track the deck is.
private struct ProDiscRim: View {
    @ObservedObject var deck: DJDeck
    let size: CGFloat
    let color: Color
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { tl in
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2), r = sz.width / 2 - 1.5
                let f = deck.duration > 0 ? deck.livePosition(at: tl.date) / deck.duration : 0
                var track = Path(); track.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
                ctx.stroke(track, with: .color(Color.white.opacity(0.07)), lineWidth: 2)
                var done = Path(); done.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f), clockwise: false)
                ctx.stroke(done, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                let ang = (-90 + 360 * f) * .pi / 180
                ctx.fill(Path(ellipseIn: CGRect(x: c.x + r * cos(ang) - 3.5, y: c.y + r * sin(ang) - 3.5, width: 7, height: 7)), with: .color(.white))
            }
        }
        .frame(width: size, height: size).allowsHitTesting(false)
    }
}

/// Position and bar under the disc.
struct ProReadout: View {
    @ObservedObject var deck: DJDeck
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let p = deck.livePosition(at: tl.date)
            let bb = deck.bpm.flatMap { b in deck.firstBeat.map { DJProMath.barBeat(at: p, bpm: b, firstBeat: $0) } }
            Text(DJProMath.clock(p) + (bb.map { " · BAR \($0.bar).\($0.beat)" } ?? "")).font(PC.mono(11)).foregroundColor(PC.ink)
                .padding(.horizontal, 8).frame(height: 20).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PC.line, lineWidth: 0.8))
        }
    }
}

/// The static drawing of the disc (rim studs, grooves, label): rendered once into a layer that is then only rotated.
struct ProDiscArt: View {
    let color: Color
    let cover: NSImage?
    let tag: String

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2), R = size.width / 2
                ctx.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: size.width, height: size.height)), with: .color(Color(red: 0.043, green: 0.059, blue: 0.075)))
                ctx.stroke(Path(ellipseIn: CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1)), with: .color(PC.line), lineWidth: 1)
                for i in 0..<48 {
                    let a = Double(i) * 7.5 * .pi / 180, r = R * 0.965
                    let p = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
                    ctx.fill(Path(roundedRect: CGRect(x: p.x - 1, y: p.y - 1.3, width: 2, height: 2.6), cornerRadius: 0.6), with: .color(i % 4 == 0 ? PC.ink2 : Color(red: 0.23, green: 0.27, blue: 0.32)))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - R * 0.9, y: c.y - R * 0.9, width: R * 1.8, height: R * 1.8)), with: .color(Color(red: 0.024, green: 0.031, blue: 0.043)))
                var r = R * 0.88
                var k = 0
                while r > R * 0.36 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(k % 5 == 0 ? Color(red: 0.17, green: 0.21, blue: 0.25) : Color(red: 0.086, green: 0.114, blue: 0.145)), lineWidth: 0.6)
                    r -= R * 0.022; k += 1
                }
            }
            Group {
                if let cover { Image(nsImage: cover).resizable().scaledToFill() }
                else { Circle().fill(LinearGradient(colors: [color.opacity(0.85), PC.s3], startPoint: .topLeading, endPoint: .bottomTrailing)).overlay(Text(tag).font(PC.mono(18)).foregroundColor(Color.white.opacity(0.65))) }
            }
            .aspectRatio(1, contentMode: .fit).scaleEffect(0.34).clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1.5).scaleEffect(0.34))
            Circle().fill(Color(red: 0.024, green: 0.031, blue: 0.043)).scaleEffect(0.09)
            Circle().fill(Color(white: 0.82)).scaleEffect(0.025)
            // a mark on the label that shows the turning
            Capsule().fill(color).frame(width: 3, height: 12).offset(y: -4).scaleEffect(1).modifier(LabelMark())
        }
        .drawingGroup()
    }
}

private struct LabelMark: ViewModifier {
    func body(content: Content) -> some View { GeometryReader { g in content.position(x: g.size.width / 2, y: g.size.height / 2 - g.size.width * 0.22).scaleEffect(g.size.width / 150) } }
}

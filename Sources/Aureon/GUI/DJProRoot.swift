import SwiftUI
import AppKit

/// The Pro console: toolbar, one shared waveform stage, deck | mixer | deck, three effect units, and the library.
/// It never scrolls. The console (stage, decks, mixer and effects) is measured once at its natural size and then scaled down, if the window is
/// short, so every control stays on screen; the stage and the library take whatever height is left over. The library sits under the
/// console when there is room for it, and otherwise opens as a drawer from the toolbar. The window cannot be made smaller than `DJProMetrics.minimumWindow`.
struct DJProView: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var dj: DJModel
    @State private var bodyHeight = DJProMetrics.bodyHeightEstimate
    @State private var libraryOpen = false

    var body: some View {
        GeometryReader { g in
            let fit = DJProMetrics.fit(window: g.size, bodyHeight: bodyHeight)
            let inner = (g.size.width - 2 * DJProMetrics.outer) / fit.scale
            let cols = DJProMetrics.columns(window: inner + 2 * DJProMetrics.outer)
            ZStack(alignment: .bottom) {
                VStack(spacing: DJProMetrics.gap) {
                    ProToolbar(library: fit.libraryInline ? nil : $libraryOpen)
                    VStack(spacing: DJProMetrics.gap) {
                        ProStage().frame(height: fit.stageHeight)
                        VStack(spacing: DJProMetrics.gap) {
                            HStack(alignment: .top, spacing: DJProMetrics.gap) {
                                ProDeck(deck: dj.a, width: cols.deck)
                                ProMixer().frame(width: cols.mixer)
                                ProDeck(deck: dj.b, width: cols.deck)
                            }
                            ProFXRow(width: inner)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { p in Color.clear.preference(key: ProBodyHeightKey.self, value: p.size.height) })
                    }
                    .frame(width: inner)
                    .scaleEffect(fit.scale, anchor: .topLeading)
                    .frame(width: g.size.width - 2 * DJProMetrics.outer, height: fit.consoleHeight * fit.scale, alignment: .topLeading)
                    if fit.libraryInline { ProLibrary().frame(maxHeight: .infinity) }
                }
                .padding(.horizontal, DJProMetrics.outer).padding(.bottom, DJProMetrics.outer)
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
                if !fit.libraryInline && libraryOpen {
                    ProLibrary()
                        .frame(height: min(g.size.height * 0.6, 460))
                        .background(RoundedRectangle(cornerRadius: 12).fill(PC.bg))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PC.line, lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.5), radius: 18, y: -4)
                        .padding(.horizontal, DJProMetrics.outer).padding(.bottom, DJProMetrics.outer)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: libraryOpen)
            .onPreferenceChange(ProBodyHeightKey.self) { h in if h > 100, abs(h - bodyHeight) > 0.5 { bodyHeight = h } }
        }
        .background(PC.bg)
        .background(WindowMinimum(size: DJProMetrics.minimumWindow))
        .onAppear { m.library.category = .songs }
    }
}

private struct ProBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Toolbar

struct ProToolbar: View {
    /// Opens and closes the library drawer; nil when the library is already on the page.
    var library: Binding<Bool>? = nil
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var dj: DJModel
    @State private var settingsOpen = false
    @State private var mixSeconds = 8.0

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(AngularGradient(colors: [PC.a, PC.b, PC.a], center: .center)).frame(width: 15, height: 15)
                Text("Aureon DJ").font(PC.sans(13, .bold)).foregroundColor(PC.ink).fixedSize()
            }
            segmented
            Spacer(minLength: 8)
            if let e = dj.outputError { Text(e).font(PC.sans(11)).foregroundColor(PC.warn).lineLimit(1) }
            autoMix
            Button { if dj.recording { dj.stopRecording() } else { dj.startRecording() } } label: {
                HStack(spacing: 6) {
                    Circle().fill(PC.red).frame(width: 8, height: 8).opacity(dj.recording ? 1 : 0.6)
                    Text(dj.recording ? clock(dj.recordedSeconds) : "REC").font(PC.mono(11)).foregroundColor(dj.recording ? PC.red : PC.ink2)
                }
                .frame(minWidth: 62, minHeight: 26).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 7).fill(dj.recording ? PC.red.opacity(0.2) : PC.s2))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PC.line, lineWidth: 0.8))
            }.buttonStyle(.plain).help(dj.recording ? "Stop recording" : "Record the master mix to a WAV file in Music/Aureon Mixes")
            pill(dj.masterTempo.map { String(format: "MASTER %.1f", $0) } ?? "MASTER —", width: 104)
            masterMeter
            pill("OUT · " + (m.devices.first { $0.id == m.deviceID }?.name ?? "Default"), width: 150)
            if let library {
                PCKey(title: "LIBRARY", on: library.wrappedValue, width: 78, height: 26, help: "Show or hide the track library") { library.wrappedValue.toggle() }
            }
            Button { settingsOpen.toggle() } label: { Image(systemName: "gearshape").font(PC.sans(12, .semibold)).frame(width: 30, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(PC.s2)).foregroundColor(PC.ink2) }
                .buttonStyle(.plain).help("Headphones, booth and live inputs")
                .windowPopover(isPresented: $settingsOpen, edge: .bottom) { ProRoutingPanel().environmentObject(dj).environmentObject(m) }
            DJSwitch(inSidebar: false)
        }
        .padding(.leading, 78).padding(.trailing, 2)
        .frame(height: 44)
    }

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(DJLayoutPreset.allCases) { p in
                Button { withAnimation(.easeOut(duration: 0.15)) { dj.preset = p } } label: {
                    Text(p.title).font(PC.mono(11)).frame(width: 72, height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).fill(dj.preset == p ? PC.s3 : Color.clear))
                        .foregroundColor(dj.preset == p ? PC.ink : PC.ink2)
                }.buttonStyle(.plain).help(p == .pro ? "The full console (needs a window of at least 1180 × 760)" : "The smaller console you can arrange yourself")
            }
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 7).fill(PC.s2))
    }

    private var autoMix: some View {
        HStack(spacing: 4) {
            Button { mixSeconds = mixSeconds >= 32 ? 4 : mixSeconds * 2 } label: {
                Text("\(Int(mixSeconds)) s").font(PC.mono(10.5)).foregroundColor(PC.ink2).frame(width: 34, height: 26)
            }.buttonStyle(.plain).help("How long the automatic mix takes")
            if let p = dj.autoMixProgress {
                ProgressView(value: p).frame(width: 50).controlSize(.small)
                PCKey(title: "STOP", on: true, color: PC.warn, width: 48, height: 26) { dj.cancelAutoMix() }
            } else {
                PCKey(title: "AUTO MIX", width: 84, height: 26, enabled: dj.a.isLoaded && dj.b.isLoaded, help: "Bring in the other deck at this deck's tempo and fade across") { dj.autoMix(seconds: mixSeconds) }
            }
        }
    }

    private func pill(_ text: String, width: CGFloat) -> some View {
        Text(text).font(PC.mono(10.5)).foregroundColor(PC.ink2).lineLimit(1).truncationMode(.tail).frame(width: width, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(PC.s2)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PC.line, lineWidth: 0.8))
    }

    private var masterMeter: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            Canvas { ctx, size in
                let l = PCMeter.fraction(dj.core.meterL.value), r = PCMeter.fraction(dj.core.meterR.value)
                for (row, v) in [l, r].enumerated() {
                    let segs = 14, gap: CGFloat = 2, w = (size.width - gap * CGFloat(segs - 1)) / CGFloat(segs), y = CGFloat(row) * (size.height / 2)
                    let lit = Int((v * Float(segs)).rounded(.up))
                    for i in 0..<segs {
                        let col: Color = i > segs - 3 ? PC.red : i > segs - 6 ? PC.warn : PC.ok
                        ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * (w + gap), y: y, width: w, height: size.height / 2 - 2), cornerRadius: 1), with: .color(i < lit ? col : PC.s3))
                    }
                }
            }
        }
        .frame(width: 84, height: 18)
    }
}

/// Where the headphones and booth monitors play, and which devices the microphone and auxiliary channels listen to.
struct ProRoutingPanel: View {
    @EnvironmentObject var dj: DJModel
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Routing").font(PC.sans(14, .semibold))
            section("Headphones") {
                Picker("", selection: Binding(get: { routeTag(dj.cueRoute) }, set: { dj.cueRoute = route($0) })) {
                    Text("Off").tag("none")
                    Text("Outputs 3–4 of the main device").tag("34")
                    ForEach(m.devices.filter { $0.id != m.deviceID }) { d in Text(d.name).tag("d\(d.id)") }
                }.labelsHidden()
            }
            section("Booth monitors") {
                Picker("", selection: Binding(get: { routeTag(dj.boothRoute) }, set: { dj.boothRoute = route($0) })) {
                    Text("Off").tag("none")
                    ForEach(m.devices.filter { $0.id != m.deviceID }) { d in Text(d.name).tag("d\(d.id)") }
                }.labelsHidden()
            }
            section("Microphone") {
                Picker("", selection: Binding(get: { dj.mic.deviceID.map { "d\($0)" } ?? "default" }, set: { dj.mic.deviceID = $0.hasPrefix("d") ? AudioDeviceIDFromTag($0) : nil })) {
                    Text("System input").tag("default")
                    ForEach(dj.inputDevices) { d in Text(d.name).tag("d\(d.id)") }
                }.labelsHidden()
                if let e = dj.mic.error { Text(e).font(PC.sans(11)).foregroundColor(PC.warn) }
            }
            section("Auxiliary input") {
                Picker("", selection: Binding(get: { dj.aux.deviceID.map { "d\($0)" } ?? "none" }, set: { dj.aux.deviceID = $0.hasPrefix("d") ? AudioDeviceIDFromTag($0) : nil })) {
                    Text("Off").tag("none")
                    ForEach(dj.inputDevices) { d in Text(d.name).tag("d\(d.id)") }
                }.labelsHidden()
                if let e = dj.aux.error { Text(e).font(PC.sans(11)).foregroundColor(PC.warn) }
            }
            Text("The microphone starts when its fader is raised.").font(PC.sans(11)).foregroundColor(PC.ink2)
        }
        .padding(16).frame(width: 300).onAppear { dj.refreshInputDevices() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title.uppercased()).font(PC.mono(9.5)).tracking(1).foregroundColor(PC.ink2); content() }
    }
    private func routeTag(_ r: CueRoute) -> String { switch r { case .none: "none"; case .channels34: "34"; case .device(let id): "d\(id)" } }
    private func route(_ t: String) -> CueRoute { t == "34" ? .channels34 : t.hasPrefix("d") ? .device(AudioDeviceIDFromTag(t)) : .none }
}

func AudioDeviceIDFromTag(_ t: String) -> UInt32 { UInt32(t.dropFirst()) ?? 0 }

// MARK: - The waveform stage

/// Both decks' waveforms in one place: deck A over deck B, scrolling past a fixed playhead with the beat grid and cue flags, and an overview of both tracks below.
struct ProStage: View {
    @EnvironmentObject var dj: DJModel
    @State private var dragStart: (deck: String, position: Double)?
    @State private var lastSeek = Date.distantPast
    private let side: CGFloat = 96

    var body: some View {
        HStack(spacing: 0) {
            ProStageSide(deck: dj.a, right: false).frame(width: side)
            GeometryReader { g in
                let overview: CGFloat = 26, laneH = (g.size.height - overview) / 2
                TimelineView(.animation) { tl in
                    Canvas { ctx, size in
                        drawLane(&ctx, deck: dj.a, rect: CGRect(x: 0, y: 0, width: size.width, height: laneH), color: PC.a, now: tl.date)
                        drawLane(&ctx, deck: dj.b, rect: CGRect(x: 0, y: laneH, width: size.width, height: laneH), color: PC.b, now: tl.date)
                        drawOverview(&ctx, rect: CGRect(x: 0, y: laneH * 2, width: size.width, height: overview), now: tl.date)
                        ctx.fill(Path(CGRect(x: 0, y: laneH - 0.5, width: size.width, height: 1)), with: .color(PC.line))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in drag(d, size: g.size, laneH: laneH, overview: overview) }.onEnded { _ in dragStart = nil })
            }
            ProStageSide(deck: dj.b, right: true).frame(width: side)
        }
        .background(Color(red: 0.02, green: 0.027, blue: 0.039))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PC.line, lineWidth: 0.8))
    }

    private func deck(named n: String) -> DJDeck { n == "A" ? dj.a : dj.b }

    /// A press on the overview jumps there; a drag on a lane moves the track under the playhead.
    private func drag(_ d: DragGesture.Value, size: CGSize, laneH: CGFloat, overview: CGFloat) {
        let y = d.startLocation.y
        if y >= laneH * 2 {
            let dk = d.startLocation.y - laneH * 2 < overview / 2 ? dj.a : dj.b
            guard dk.isLoaded, dk.duration > 0 else { return }
            dk.seek(to: Double(max(0, min(1, d.location.x / size.width))) * dk.duration)
            return
        }
        let dk = y < laneH ? dj.a : dj.b
        guard dk.isLoaded else { return }
        if dragStart == nil { dragStart = (dk.name, dk.position) }
        guard let s = dragStart, s.deck == dk.name, Date().timeIntervalSince(lastSeek) > 0.03 else { return }
        lastSeek = Date()
        dk.seek(to: s.position - Double(d.translation.width) / Double(size.width) * window(dk))
    }

    /// Seconds of track across the lane: about 22 beats, whatever the tempo.
    private func window(_ d: DJDeck) -> Double { max(6, min(40, 22 * (60 / max(60, d.bpm ?? 120)))) }

    private func drawLane(_ ctx: inout GraphicsContext, deck d: DJDeck, rect: CGRect, color: Color, now: Date) {
        guard d.isLoaded else {
            ctx.draw(Text("Load a track on deck \(d.name)").font(PC.sans(11)).foregroundColor(PC.ink3), at: CGPoint(x: rect.midX, y: rect.midY)); return
        }
        let pos = d.livePosition(at: now), win = window(d), t0 = pos - win / 2
        let mid = rect.midY, half = rect.height / 2
        func x(_ t: Double) -> CGFloat { rect.minX + CGFloat((t - t0) / win) * rect.width }
        if let li = d.loopIn, let lo = d.loopOut, lo > li {
            ctx.fill(Path(CGRect(x: x(li), y: rect.minY, width: max(2, x(lo) - x(li)), height: rect.height)), with: .color(PC.ok.opacity(d.loopActive ? 0.22 : 0.08)))
        }
        if let det = d.detail {
            var outer = Path(), inner = Path(), high = Path()
            let step: CGFloat = 3
            var px: CGFloat = 0
            while px < rect.width {
                let ta = t0 + Double(px / rect.width) * win, tb = t0 + Double((px + step) / rect.width) * win
                let a = Int((ta * DJWaveDetail.binsPerSecond).rounded(.down)), b = Int((tb * DJWaveDetail.binsPerSecond).rounded(.up))
                if b > 0, a < det.count {
                    let p = det.peaks(from: a, to: b)
                    let lo = CGFloat(min(1, p.low * 1.25)) * half * 0.95, hi = CGFloat(min(1, p.high)) * half * 0.55
                    outer.addRect(CGRect(x: rect.minX + px, y: mid - lo, width: step - 0.6, height: lo * 2))
                    inner.addRect(CGRect(x: rect.minX + px, y: mid - lo * 0.55, width: step - 0.6, height: lo * 1.1))
                    high.addRect(CGRect(x: rect.minX + px, y: mid - hi * 0.5, width: step - 0.6, height: hi))
                }
                px += step
            }
            ctx.fill(outer, with: .color(color.opacity(0.28))); ctx.fill(inner, with: .color(color)); ctx.fill(high, with: .color(Color.white.opacity(0.78)))
        } else if let a = d.analysis, !a.peaks.isEmpty {
            var p = Path()
            var px: CGFloat = 0
            while px < rect.width {
                let t = t0 + Double(px / rect.width) * win
                if t >= 0, t < d.duration { let v = CGFloat(a.peaks[min(a.peaks.count - 1, Int(t / d.duration * Double(a.peaks.count)))]) * half * 0.9; p.addRect(CGRect(x: rect.minX + px, y: mid - v, width: 2.4, height: v * 2)) }
                px += 3
            }
            ctx.fill(p, with: .color(color.opacity(0.7)))
        }
        // beat grid
        if let bpm = d.bpm, let fb = d.firstBeat {
            var bars = Path(), beats = Path()
            for b in DJProMath.beats(from: t0, to: t0 + win, bpm: bpm, firstBeat: fb) {
                let bx = x(b.time)
                if b.index % 4 == 0 { bars.addRect(CGRect(x: bx - 0.5, y: rect.minY, width: 1.4, height: rect.height)) } else { beats.addRect(CGRect(x: bx - 0.5, y: rect.minY, width: 1, height: rect.height)) }
            }
            ctx.fill(beats, with: .color(Color.white.opacity(0.13))); ctx.fill(bars, with: .color(Color.white.opacity(0.36)))
        }
        // cues
        for (i, c) in d.hotCues.enumerated() {
            guard let c, c >= t0, c <= t0 + win else { continue }
            let cx = x(c), col = PC.padColors[i % PC.padColors.count]
            ctx.fill(Path(CGRect(x: cx, y: rect.minY, width: 2, height: rect.height)), with: .color(col))
            ctx.fill(Path(CGRect(x: cx, y: rect.minY, width: 16, height: 13)), with: .color(col))
            ctx.draw(Text("\(i + 1)").font(PC.mono(9)).foregroundColor(.black), at: CGPoint(x: cx + 8, y: rect.minY + 6.5))
        }
        if d.cue >= t0, d.cue <= t0 + win { ctx.fill(Path(CGRect(x: x(d.cue), y: rect.minY, width: 2, height: rect.height)), with: .color(Color.orange)) }
        // playhead
        ctx.fill(Path(CGRect(x: rect.midX - 1, y: rect.minY, width: 2, height: rect.height)), with: .color(.white))
        var tri = Path(); tri.move(to: CGPoint(x: rect.midX - 6, y: rect.minY)); tri.addLine(to: CGPoint(x: rect.midX + 6, y: rect.minY)); tri.addLine(to: CGPoint(x: rect.midX, y: rect.minY + 7)); tri.closeSubpath()
        ctx.fill(tri, with: .color(.white))
    }

    private func drawOverview(_ ctx: inout GraphicsContext, rect: CGRect, now: Date) {
        ctx.fill(Path(rect), with: .color(Color.black.opacity(0.35)))
        for (i, d) in [dj.a, dj.b].enumerated() {
            let r = CGRect(x: rect.minX, y: rect.minY + CGFloat(i) * rect.height / 2, width: rect.width, height: rect.height / 2)
            guard d.isLoaded, d.duration > 0, let a = d.analysis, !a.peaks.isEmpty else { continue }
            let col = PC.deck(d.name), played = CGFloat(d.livePosition(at: now) / d.duration) * r.width
            var done = Path(), todo = Path()
            var px: CGFloat = 0
            while px < r.width {
                let v = CGFloat(a.peaks[min(a.peaks.count - 1, Int(Double(px / r.width) * Double(a.peaks.count)))]) * r.height * 0.92
                let rc = CGRect(x: r.minX + px, y: r.midY - v / 2, width: 1.6, height: max(1, v))
                if px <= played { done.addRect(rc) } else { todo.addRect(rc) }
                px += 2
            }
            ctx.fill(todo, with: .color(col.opacity(0.35))); ctx.fill(done, with: .color(col.opacity(0.85)))
            for (k, c) in d.hotCues.enumerated() { if let c { ctx.fill(Path(CGRect(x: r.minX + CGFloat(c / d.duration) * r.width, y: r.minY, width: 1.5, height: r.height)), with: .color(PC.padColors[k % PC.padColors.count])) } }
            ctx.fill(Path(CGRect(x: r.minX + played - 1, y: r.minY, width: 2, height: r.height)), with: .color(.white))
        }
    }
}

/// The letter, tempo and time left of a deck, at the side of the stage.
struct ProStageSide: View {
    @ObservedObject var deck: DJDeck
    let right: Bool
    var body: some View {
        let c = PC.deck(deck.name)
        VStack(spacing: 2) {
            Text(deck.name).font(PC.mono(26)).foregroundColor(c)
            Text(deck.effectiveBPM.map { String(format: "%.2f", $0) } ?? "—").font(PC.mono(10)).foregroundColor(PC.ink2)
            Text("-" + DJProMath.clock(deck.remaining)).font(PC.mono(10)).foregroundColor(PC.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [c.opacity(0.2), .clear], startPoint: right ? .trailing : .leading, endPoint: right ? .leading : .trailing))
    }
}

/// The DJ console: the Pro layout or the compact one, as chosen in the toolbar.
struct DJView: View {
    @EnvironmentObject var dj: DJModel
    var body: some View {
        Group {
            if dj.preset == .pro { DJProView() } else { DJCompactView() }
        }
    }
}

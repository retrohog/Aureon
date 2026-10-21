import SwiftUI

// The immersive player: a mesh of the cover's colours behind a large cover, serif title hierarchy, hardware-style badges, a fluid scrubber,
// the node-based signal path and a compact visualiser.

struct NowPlayingView: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    hero(width: geo.size.width - 64)
                    SignalPathView()
                    LiveVisualizerPanel()
                }
                .padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 36)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func hero(width: CGFloat) -> some View {
        let item = m.focusItem
        let side = min(max(width * 0.44, 240), 430)
        if width >= 700 {
            HStack(alignment: .bottom, spacing: 40) {
                CoverView(image: m.hero.image, palette: m.hero.palette, corner: 20).frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.5), radius: 34, y: 18)
                    .id(m.hero.token).transition(.opacity.combined(with: .scale(scale: 0.97)))
                info(item).frame(maxWidth: .infinity, minHeight: side, alignment: .bottomLeading)
            }
        } else {
            VStack(spacing: 24) {
                CoverView(image: m.hero.image, palette: m.hero.palette, corner: 20).frame(width: min(side, 340), height: min(side, 340))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                info(item)
            }
        }
    }

    private func info(_ item: QueueItem?) -> some View {
        let tint = m.hero.palette.accent.color
        return VStack(alignment: .leading, spacing: 0) {
            Text(kickerText(item)).kicker().foregroundStyle(.white.opacity(0.6)).padding(.bottom, 10)
            Text(item?.title ?? "Nothing playing").font(Typo.title(item.map { $0.title.count > 28 ? 32 : 40 } ?? 40)).foregroundStyle(.white)
                .lineLimit(3).minimumScaleFactor(0.75).fixedSize(horizontal: false, vertical: true)
            if let a = item?.artist, !a.isEmpty { Text(a).font(Typo.artist).foregroundStyle(.white.opacity(0.92)).lineLimit(2).padding(.top, 8) }
            if let line = albumLine(item) { Text(line).font(Typo.album).foregroundStyle(.white.opacity(0.62)).lineLimit(2).padding(.top, 3) }
            if let c = item?.composer, !c.isEmpty {
                HStack(spacing: 8) { Text("Composer").kicker().foregroundStyle(.white.opacity(0.45)); Text(c).font(Typo.composer).foregroundStyle(.white.opacity(0.8)) }.padding(.top, 10)
            }
            if let raw = m.status.sourceInfo, m.isActive {
                FormatBadges(source: raw).padding(.top, 16)
                if let a = item?.analysis {
                    HStack(spacing: 8) {
                        HWBadge(text: "PEAK", detail: String(format: "%.1f dBFS", a.peakDB), tone: a.peakDB > -0.1 ? .orange : .neutral, lit: a.peakDB > -0.1)
                        HWBadge(text: "DR", detail: String(format: "%.0f", a.dynamicRange), tone: .neutral, lit: false)
                        if let g = m.status.replayGainDB { HWBadge(text: "RG", detail: String(format: "%+.1f dB", g), tone: .amber) }
                    }.padding(.top, 8)
                }
            }
            if let p = m.status.loadProgress {
                HStack(spacing: 10) { ProgressView(value: p).frame(width: 140).tint(tint); Text("Loading into RAM \(Int(p * 100))%").font(.caption).foregroundStyle(.white.opacity(0.6)) }.padding(.top, 10)
            }
            Spacer(minLength: 22)
            scrubber(tint)
            transport.padding(.top, 6)
            volume.padding(.top, 10)
        }
    }

    private func kickerText(_ item: QueueItem?) -> String {
        guard item != nil else { return "Aureon" }
        var parts = [m.isActive ? (m.status.state == .paused ? "Paused" : "Now playing") : "Up next"]
        if let n = item?.trackNumber { parts.append(item?.trackTotal.map { "Track \(n) of \($0)" } ?? "Track \(n)") }
        return parts.joined(separator: "  ·  ")
    }

    private func albumLine(_ item: QueueItem?) -> String? {
        guard let item else { return nil }
        let parts = [item.album, item.year.map(String.init), item.genre].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func scrubber(_ tint: Color) -> some View {
        let dur = max(m.status.duration, 0.001)
        let pos = m.scrub ?? m.status.position
        return VStack(spacing: 2) {
            FluidSlider(value: Binding(get: { m.scrub ?? m.status.position }, set: { m.scrub = $0 }), range: 0...dur, tint: tint, enabled: m.isActive,
                        bubble: { clock($0) }) { editing in
                if !editing, let t = m.scrub { m.player.send(.seekTo(t)); m.scrub = nil }
            }
            HStack {
                Text(clock(pos)); Spacer(); Text("-" + clock(max(0, dur - pos)))
            }.font(.system(size: 11.5, weight: .medium, design: .monospaced)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
        }
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button { m.player.send(.previous) } label: { Image(systemName: "backward.fill") }.keyboardShortcut(.leftArrow, modifiers: .command).help("Previous")
            Button { m.player.send(.seekBy(-10)) } label: { Image(systemName: "gobackward.10") }.keyboardShortcut(.leftArrow, modifiers: []).help("Back 10 s")
            Button { m.togglePlay() } label: {
                Image(systemName: m.isActive && m.status.state == .playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace)).font(.system(size: 26))
            }
            .buttonStyle(PlayButtonStyle(tint: m.hero.palette.accent.color)).keyboardShortcut(.space, modifiers: []).help("Play / pause")
            Button { m.player.send(.seekBy(10)) } label: { Image(systemName: "goforward.10") }.keyboardShortcut(.rightArrow, modifiers: []).help("Forward 10 s")
            Button { m.player.send(.next) } label: { Image(systemName: "forward.fill") }.keyboardShortcut(.rightArrow, modifiers: .command).help("Next")
        }
        .buttonStyle(TransportButtonStyle(size: 17))
        .disabled(m.items.isEmpty)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.2), value: m.status.state)
    }

    private var volume: some View {
        let v = Double(m.volume)
        return HStack(spacing: 10) {
            Image(systemName: m.hasVolume ? "speaker.wave.3.fill" : "lock.fill", variableValue: m.hasVolume ? v : 1)
                .font(.system(size: 13)).frame(width: 22).foregroundStyle(.white.opacity(0.6)).symbolRenderingMode(.hierarchical)
            FluidSlider(value: Binding(get: { Double(m.volume) }, set: { m.volume = Float($0) }), tint: .white.opacity(0.92), restingHeight: 3, enabled: m.hasVolume,
                        bubble: { "\(Int($0 * 100))%" })
            Text(m.hasVolume ? "\(Int(v * 100))%" : "DAC").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).frame(width: 34, alignment: .trailing)
        }
        .help(m.hasVolume ? (m.volume > 0.9 ? "High device volume: check your amplifier before playing." : "Applied by the device itself, so the samples stay untouched.") : "This device has no software volume. Use your DAC or amplifier: samples are never scaled here.")
    }
}

struct PlayButtonStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, tint: tint) }
    private struct Inner: View {
        let configuration: Configuration
        let tint: Color
        @StateObject private var hover = Box(false)
        var body: some View {
            configuration.label
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 62, height: 62)
                .background(Circle().fill(.white).shadow(color: tint.opacity(hover.v ? 0.7 : 0.4), radius: hover.v ? 18 : 10, y: 3))
                .scaleEffect(configuration.isPressed ? 0.93 : (hover.v ? 1.05 : 1))
                .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
                .animation(.smooth(duration: 0.18), value: hover.v)
                .onHover { hover.v = $0 }
                .padding(.horizontal, 6)
        }
    }
}

// MARK: - Visualiser

struct LiveVisualizerPanel: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var mode = Box(0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Analyser").kicker().foregroundStyle(.white.opacity(0.6))
                Spacer()
                if m.visualizerEnabled {
                    HStack(spacing: 2) {
                        ForEach(Array(["Spectrum", "Spectrogram", "Meters"].enumerated()), id: \.offset) { i, name in
                            Button { withAnimation(.smooth(duration: 0.25)) { mode.v = i } } label: {
                                Text(name).font(.system(size: 11.5, weight: .semibold)).padding(.horizontal, 11).padding(.vertical, 5)
                                    .background(Capsule().fill(.white.opacity(mode.v == i ? 0.18 : 0)))
                                    .foregroundStyle(.white.opacity(mode.v == i ? 1 : 0.55)).contentShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(3).background(Capsule().fill(.black.opacity(0.25)))
                }
            }
            if m.visualizerEnabled {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                    Group {
                        switch mode.v {
                        case 0: SpectrumCanvas(analysis: m.player.analysis).frame(height: 150)
                        case 1: SpectrogramCanvas(analysis: m.player.analysis).frame(height: 170)
                        default:
                            let snap = m.player.analysis.snapshot()
                            VStack(spacing: 10) {
                                HStack(spacing: 12) {
                                    VUMeterView(value: snap.meters.vuL, label: "L").frame(height: 120)
                                    VUMeterView(value: snap.meters.vuR, label: "R").frame(height: 120)
                                }
                                PeakBars(meters: snap.meters).frame(height: 56)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            } else {
                Text("The analyser is off. Turn it on in Audio → Visualiser.").font(.callout).foregroundStyle(.white.opacity(0.5)).padding(.vertical, 14)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassPanel()
    }
}

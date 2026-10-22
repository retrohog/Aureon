import SwiftUI

// The immersive player: a mesh of the cover's colours behind a large cover, serif title hierarchy, hardware-style badges, a fluid scrubber,
// the node-based signal path and a compact visualiser.

struct NowPlayingView: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("aureon.lyrics.show") private var lyricsShow = true

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    header.padding(.bottom, -8)
                    hero(width: geo.size.width - 56)
                    LyricsSection(availableHeight: geo.size.height).id(Self.lyricsID)
                    if geo.size.width >= 940 {
                        // the signal path takes what it needs; the rest of the row is the queue
                        HStack(alignment: .top, spacing: 18) {
                            SignalPathView().frame(maxWidth: .infinity)
                            UpNextPanel().frame(width: 330)
                        }
                    } else {
                        SignalPathView()
                        UpNextPanel()
                    }
                    LiveVisualizerPanel()
                    BookletSection()
                }
                .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 28)
            }
            // the lyrics lookup starts from the scroll view, which is always on screen (the lyrics panel is empty until it has something to show)
            .task(id: LyricsDriver.trigger(for: m, show: lyricsShow)) { await LyricsDriver.ask(m, show: lyricsShow) }
            // the Lyrics buttons ask for the panel; it may still be loading, so scroll once now and once it has laid out
            .onChange(of: stage.lyricsPending) { _, pending in if pending { revealLyrics(proxy) } }
            .task { if stage.lyricsPending { revealLyrics(proxy) } }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private static let lyricsID = "aureon.lyrics.section"

    private func revealLyrics(_ proxy: ScrollViewProxy) {
        stage.lyricsPending = false
        withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(Self.lyricsID, anchor: .top) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(Self.lyricsID, anchor: .top) }
        }
    }

    /// Close (back to the page it was opened from, the cover settling into the bar) and full window ⇄ beside the sidebar.
    private var header: some View {
        HStack(spacing: 6) {
            // with the sidebar tucked away, the window's own buttons sit at the top left
            if stage.immersive { Color.clear.frame(width: 62, height: 1) }
            Button { stage.close(m, reduceMotion: reduceMotion) } label: {
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
            }
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close Now Playing (Esc)")
            .accessibilityLabel("Close Now Playing")
            Spacer(minLength: 0)
            LyricsButton(size: 12, shortcut: false)
            Button { stage.toggleImmersive(reduceMotion: reduceMotion) } label: {
                Image(systemName: stage.immersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help(stage.immersive ? "Show the sidebar (⇧⌘F)" : "Fill the window (⇧⌘F)")
            .accessibilityLabel(stage.immersive ? "Show the sidebar" : "Fill the window")
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.white)
        .frame(height: 32)
    }

    @ViewBuilder private func hero(width: CGFloat) -> some View {
        let item = m.focusItem
        let side = min(max(width * 0.40, 220), 340)
        if width >= 700 {
            HStack(alignment: .bottom, spacing: 34) {
                // the frame is the one that morphs from the bar's cover; the picture inside cross-fades from song to song
                ZStack {
                    CoverView(image: m.hero.image, palette: m.hero.palette, corner: 20, symbol: item?.isStream == true ? "dot.radiowaves.left.and.right" : "music.note")
                        .id(m.hero.token).transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                .stageMatched(.cover)
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.5), radius: 34, y: 18)
                info(item).frame(maxWidth: .infinity, minHeight: side, alignment: .bottomLeading)
            }
        } else {
            VStack(spacing: 24) {
                ZStack {
                    CoverView(image: m.hero.image, palette: m.hero.palette, corner: 20, symbol: item?.isStream == true ? "dot.radiowaves.left.and.right" : "music.note")
                        .id(m.hero.token).transition(.opacity)
                }
                .stageMatched(.cover)
                .frame(width: min(side, 340), height: min(side, 340))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                info(item)
            }
        }
    }

    private func info(_ item: QueueItem?) -> some View {
        let tint = m.hero.palette.accent.color
        let d = m.focusDisplay
        return VStack(alignment: .leading, spacing: 0) {
            Text(kickerText(item)).microLabel().foregroundStyle(.white.opacity(0.55)).padding(.bottom, 10)
            Text(d?.title ?? "Nothing playing").font(Typo.title((d?.title.count ?? 0) > 28 ? 28 : 34)).foregroundStyle(.white)
                .lineLimit(3).minimumScaleFactor(0.75).fixedSize(horizontal: false, vertical: true)
            if let a = d?.artist, !a.isEmpty { Text(a).font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(2).padding(.top, 7) }
            if let line = d?.detail, !line.isEmpty { Text(line).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(2).padding(.top, 3) }
            if let c = item?.composer, !c.isEmpty {
                HStack(spacing: 8) { Text("Composer").kicker().foregroundStyle(.white.opacity(0.45)); Text(c).font(Typo.composer).foregroundStyle(.white.opacity(0.8)) }.padding(.top, 10)
            }
            if let raw = m.status.sourceInfo, m.isActive {
                FormatBadges(source: raw, output: m.status.info, bitrate: m.status.live?.bitrate).padding(.top, 14)
                if let a = item?.analysis {
                    WrapLayout(spacing: 8, lineSpacing: 8) {
                        HWBadge(text: "PEAK", detail: String(format: "%.1f dBFS", a.peakDB), tone: a.peakDB > -0.1 ? .orange : .neutral, lit: a.peakDB > -0.1)
                        HWBadge(text: "DR", detail: String(format: "%.0f", a.dynamicRange), tone: .neutral, lit: false)
                        if let l = a.lufs { HWBadge(text: "LUFS", detail: String(format: "%.1f", l), tone: .neutral, lit: false) }
                        if let tp = a.truePeakDB { HWBadge(text: "TP", detail: String(format: "%.1f dBTP", tp), tone: tp > -0.1 ? .orange : .neutral, lit: tp > -0.1) }
                        if let lra = a.loudnessRange, lra > 0 { HWBadge(text: "LRA", detail: String(format: "%.1f LU", lra), tone: .neutral, lit: false) }
                        if let g = m.status.replayGainDB { HWBadge(text: "RG", detail: String(format: "%+.1f dB", g), tone: .amber) }
                    }.padding(.top, 8)
                }
            }
            if let p = m.status.loadProgress {
                HStack(spacing: 10) { ProgressView(value: p).frame(width: 140).tint(tint); Text("Loading into RAM \(Int(p * 100))%").font(.caption).foregroundStyle(.white.opacity(0.6)) }.padding(.top, 10)
            }
            Spacer(minLength: 18)
            NowPlayingScrubber(tint: tint)
            transport.padding(.top, 4)
            volume.padding(.top, 8)
        }
    }

    private func kickerText(_ item: QueueItem?) -> String {
        guard item != nil else { return "Aureon" }
        var parts = [m.isActive ? (m.status.state == .paused ? "Paused" : (item?.isStream == true ? "On air" : "Now playing")) : "Up next"]
        if item?.isStream != true, let n = item?.trackNumber { parts.append(item?.trackTotal.map { "Track \(n) of \($0)" } ?? "Track \(n)") }
        return parts.joined(separator: "  ·  ")
    }

    private func albumLine(_ item: QueueItem?) -> String? {
        guard let item else { return nil }
        let parts = [item.album, item.year.map(String.init), item.genre].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// The full row when there is room; narrower windows drop the 10-second skips and the divider, then shuffle and repeat, before anything is clipped.
    private var transport: some View {
        ViewThatFits(in: .horizontal) {
            transportRow(skips: true, modes: true)
            transportRow(skips: false, modes: true)
            transportRow(skips: false, modes: false)
        }
        .buttonStyle(TransportButtonStyle(size: 15))
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.2), value: m.status.state)
    }

    private func transportRow(skips: Bool, modes: Bool) -> some View {
        HStack(spacing: 6) {
            Group {
            if modes { ShuffleButton(size: 14, tint: .white) }
            Button { m.player.send(.previous) } label: { Image(systemName: "backward.fill") }.keyboardShortcut(.leftArrow, modifiers: .command).help("Previous")
            if skips {
                Button { m.player.send(.seekBy(-10)) } label: { Image(systemName: "gobackward.10") }.keyboardShortcut(.leftArrow, modifiers: []).help("Back 10 s")
                    .disabled(m.status.sourceInfo?.isLive == true)
            }
            Button { m.togglePlay() } label: {
                Image(systemName: m.isActive && m.status.state == .playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace)).font(.system(size: 22))
            }
            .buttonStyle(PlayButtonStyle(tint: m.hero.palette.accent.color)).keyboardShortcut(.space, modifiers: []).help("Play / pause")
            if skips {
                Button { m.player.send(.seekBy(10)) } label: { Image(systemName: "goforward.10") }.keyboardShortcut(.rightArrow, modifiers: []).help("Forward 10 s")
                    .disabled(m.status.sourceInfo?.isLive == true)
            }
            Button { m.player.send(.next) } label: { Image(systemName: "forward.fill") }.keyboardShortcut(.rightArrow, modifiers: .command).help("Next")
            if modes { RepeatButton(size: 14, tint: .white) }
            }
            .disabled(m.items.isEmpty)
            if skips { Divider().frame(height: 18).overlay(.white.opacity(0.2)) }
            HeartButton(path: m.focusItem.flatMap { $0.isStream ? nil : $0.path }, size: 15, ink: .white)
            AddToPlaylistButton(path: m.focusItem.flatMap { $0.isStream ? nil : $0.path }, size: 15, ink: .white)
            QueueButton(ink: .white)
        }
        .frame(maxWidth: .infinity)
    }

    private var volume: some View {
        let v = Double(m.volume)
        return HStack(spacing: 10) {
            Image(systemName: m.hasVolume ? "speaker.wave.3.fill" : "lock.fill", variableValue: m.hasVolume ? v : 1)
                .font(.system(size: 13)).frame(width: 22).foregroundStyle(.white.opacity(0.6)).symbolRenderingMode(.hierarchical)
            FluidSlider(value: Binding(get: { Double(m.volume) }, set: { m.setVolume(Float($0)) }), tint: .white.opacity(0.92), restingHeight: 3, enabled: m.hasVolume,
                        bubble: { "\(Int($0 * 100))%" }, safe: true)
            Text(m.hasVolume ? "\(Int(v * 100))%" : "—").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).frame(width: 34, alignment: .trailing)
        }
        .help(m.hasVolume ? (m.volume > 0.9 ? "High device volume: check your amplifier before playing." : "Applied by the device itself, so the samples stay untouched.") : "This device has no software volume. Use your DAC or amplifier: samples are never scaled here.")
    }
}

/// The next songs, beside the signal path: tap one to play it.
struct UpNextPanel: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        let items = m.items
        let at = items.firstIndex { $0.id == m.status.trackID } ?? -1
        let upcoming = Array(items.dropFirst(at + 1).prefix(7))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Up next").kicker().foregroundStyle(.white.opacity(0.6))
                Spacer()
                if m.shuffle != .off { Label(m.shuffle.title, systemImage: m.shuffle.icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(m.hero.palette.accent.color) }
                Button { withAnimation(.smooth(duration: 0.28)) { m.showQueue.toggle() } } label: { Text(m.showQueue ? "Hide queue" : "Open queue").font(.system(size: 11.5, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
            }
            if upcoming.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.line.last.and.arrowtriangle.forward").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.5))
                    Text(items.isEmpty ? "The queue is empty" : "Nothing after this song").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.7))
                    Text(m.repeatMode == .off ? "Add songs from your library, or turn on repeat." : "Repeat is on: the queue starts over.").font(.caption).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 2) { ForEach(upcoming) { UpNextRow(item: $0) } }
                if items.count - (at + 1) > upcoming.count { Text("+ \(items.count - (at + 1) - upcoming.count) more").font(.caption).foregroundStyle(.white.opacity(0.45)).padding(.leading, 8) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading).glassPanel()
    }
}

struct UpNextRow: View {
    @EnvironmentObject var m: PlayerModel
    let item: QueueItem
    @StateObject private var hover = Box(false)
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                CoverView(image: item.thumb, palette: ArtPalette.fallback(seed: item.album.isEmpty ? item.title : item.album), corner: 5, symbol: "music.note")
                if hover.v { Color.black.opacity(0.5).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous)); Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
            }.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Text([item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " — ")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3).contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover.v ? 0.1 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover.v = h } }
        .onTapGesture { m.play(item.id) }
        .onAppear { m.requestMetadata(item.id) }
    }
}

/// The big waveform scrubber of the Now Playing page, with elapsed and remaining time. Only this view observes the playhead.
struct NowPlayingScrubber: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var progress: ProgressModel
    let tint: Color

    var body: some View {
        let live = m.status.sourceInfo?.isLive == true && m.isActive
        let dur = max(progress.duration, 0.001), pos = m.scrub ?? progress.position
        VStack(spacing: 6) {
            WaveformScrubber(style: .stage, tint: tint)
                .stageMatched(.waveform)
            HStack {
                Text(live ? "LIVE" : clock(pos)).foregroundStyle(live ? Brand.pink : .white.opacity(0.55)); Spacer(); Text(live ? "" : "-" + clock(max(0, dur - pos))).foregroundStyle(.white.opacity(0.55))
            }.font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
        }
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
                .frame(width: 54, height: 54)
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
                TimelineView(.animation(minimumInterval: UIRate.analyserInterval)) { _ in
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
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassPanel()
    }
}

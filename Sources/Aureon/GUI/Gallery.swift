import SwiftUI

// Now Playing as the whole window, composed for a wide screen and needing no scrolling: the cover hangs on the left like a framed work, the title, the
// artist, the album and the readouts sit to its right, and under them one fine line shows the song's shape and where you are in it, then the transport.
// Lyrics, the queue, the signal path, the analyser and the booklet each open as a panel on the right of the same screen, one at a time; the cover and the
// words give way to it with a slow ease. Nothing lives below the player.

/// The panels that open beside the cover.
enum GalleryPanel: String, CaseIterable, Identifiable {
    case lyrics, queue, signal, analyser, booklet
    var id: String { rawValue }
    var title: String {
        switch self { case .lyrics: "Lyrics"; case .queue: "Queue"; case .signal: "Signal path"; case .analyser: "Analyser"; case .booklet: "Booklet" }
    }
    var icon: String {
        switch self { case .lyrics: "quote.bubble"; case .queue: "list.bullet"; case .signal: "point.topleft.down.curvedto.point.bottomright.up"; case .analyser: "waveform"; case .booklet: "book" }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            GalleryScreen(size: geo.size)
                // the lyrics lookup starts from the screen, which is always there (the panel is empty until it is asked to show)
                .task(id: LyricsDriver.trigger(for: m, show: stage.panel == .lyrics)) { await LyricsDriver.ask(m, show: stage.panel == .lyrics) }
        }
        // Escape closes an open panel, and otherwise leaves for the page Now Playing was opened from
        .background(Button("") { if stage.focus { stage.toggleFocus() } else if stage.panel != nil { stage.panel = nil } else { stage.close(m, reduceMotion: reduceMotion) } }
            .keyboardShortcut(.escape, modifiers: []).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// The screen.
struct GalleryScreen: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    let size: CGSize

    private let footerHeight: CGFloat = 176

    var body: some View {
        let wide = size.width >= 900
        let panel = stage.focus ? nil : stage.panel
        let margin: CGFloat = wide ? 64 : 32, gap: CGFloat = 40
        // the analyser takes more room when the window has it: wide enough, its three graphs become a 2-plus-1 grid
        let panelWidth: CGFloat = panel == nil ? 0 : (panel == .analyser ? min(760, max(340, size.width * 0.46)) : min(480, max(340, size.width * 0.36)))
        let leftWidth = size.width - margin * 2 - (panel == nil ? 0 : panelWidth + gap)
        let room = size.height - WindowChrome.band - footerHeight - 24
        VStack(spacing: 0) {
            Color.clear.frame(height: WindowChrome.band)
            HStack(alignment: .center, spacing: gap) {
                column(width: leftWidth, room: room)
                if let panel {
                    GalleryPanelView(panel: panel).frame(width: panelWidth)
                        .transition(.opacity.animation(TabMotion.animation))
                }
            }
            .padding(.horizontal, margin).padding(.top, 36)
            .frame(maxHeight: .infinity)
            GalleryFooter(wide: wide, margin: margin).frame(height: footerHeight)
        }
        .overlay(alignment: .topTrailing) { PanelTabs().padding(.top, WindowChrome.band - 6).padding(.trailing, margin - 8) }
    }

    // MARK: the cover and the words

    private func column(width w: CGFloat, room: CGFloat) -> some View {
        let item = m.focusItem, d = m.focusDisplay
        let stacked = w < 560
        let focus = stage.focus
        let side = focus ? FocusLayout.coverSide(free: CGSize(width: w, height: room), wide: !stacked)
                         : (stacked ? max(120, min(200, room * 0.38)) : max(150, min(room, (w - 56) * 0.5, 440)))
        let infoWidth = stacked ? w : max(0, w - side - 56 - 32)
        return Group {
            if stacked {
                VStack(alignment: .leading, spacing: 24) { art(side, item); if focus { focusInfo(d, width: infoWidth) } else { info(item, d, width: infoWidth) } }
            } else {
                HStack(alignment: .center, spacing: 56) {
                    art(side, item)
                    Group { if focus { focusInfo(d, width: infoWidth) } else { info(item, d, width: infoWidth) } }.frame(width: infoWidth, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The cover, hung like a work: a mat, a champagne hairline and a second fine rule inside it.
    private func art(_ side: CGFloat, _ item: QueueItem?) -> some View {
        ZStack {
            CoverView(image: m.hero.image, palette: m.hero.palette, corner: 0, symbol: item?.isStream == true ? "dot.radiowaves.left.and.right" : "music.note")
                .id(m.hero.token).transition(.opacity)
        }
        .stageMatched(.cover)
        .frame(width: side, height: side)
        .padding(14)
        .overlay(Rectangle().strokeBorder(Brand.coachline, lineWidth: Metrics.hairline))
        .overlay(Rectangle().strokeBorder(Brand.rule, lineWidth: Metrics.hairline).padding(7))
        .animation(Motion.carpet, value: m.hero.token)
        .accessibilityElement(children: .ignore).accessibilityLabel("Cover")
    }

    /// Focus: the names alone, large and calm.
    private func focusInfo(_ d: (title: String, artist: String, detail: String)?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(d?.title ?? "Nothing playing").font(Typo.title(width >= 420 ? 44 : 30)).tracking(-0.8).foregroundStyle(Brand.ink).lineLimit(2).minimumScaleFactor(0.6)
            if let a = d?.artist, !a.isEmpty { Text(a).font(Typo.serif(22, .regular)).foregroundStyle(Brand.inkSecondary).lineLimit(2) }
        }
    }

    private func info(_ item: QueueItem?, _ d: (title: String, artist: String, detail: String)?, width: CGFloat) -> some View {
        let title = Text(d?.title ?? "Nothing playing").font(Typo.title(width >= 420 ? 40 : 28)).tracking(-0.8).foregroundStyle(Brand.ink)
        return VStack(alignment: .leading, spacing: 0) {
            Text(kicker(item)).microLabel().foregroundStyle(Brand.inkTertiary)
            // the quality hallmark beside the title, or under it when the column is narrow
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 20) { title.lineLimit(1); NowPlayingBadge(size: .large) }
                VStack(alignment: .leading, spacing: 12) { title.lineLimit(2).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true); NowPlayingBadge(size: .large) }
            }
            .padding(.top, 16)
            if let a = d?.artist, !a.isEmpty { Text(a).font(Typo.serif(20, .regular)).foregroundStyle(Brand.ink).lineLimit(2).padding(.top, 12) }
            if let line = d?.detail, !line.isEmpty { Text(line).font(Typo.sans(13)).tracking(0.3).foregroundStyle(Brand.inkSecondary).lineLimit(2).padding(.top, 6) }
            if let c = item?.composer, !c.isEmpty {
                HStack(spacing: 8) { Text("Composer").kicker().foregroundStyle(Brand.inkTertiary); Text(c).font(Typo.composer).foregroundStyle(Brand.inkSecondary) }.padding(.top, 10)
            }
            Rectangle().fill(Brand.coachline).frame(width: 48, height: Metrics.hairline).padding(.vertical, 24)
            OutputLine()
            if let p = m.status.loadProgress {
                HStack(spacing: 12) { ProgressView(value: p).frame(width: 140).tint(Brand.accent); Text("Loading into RAM \(Int(p * 100))%").font(Typo.caption).foregroundStyle(Brand.inkSecondary) }.padding(.top, 12)
            }
        }
    }

    private func kicker(_ item: QueueItem?) -> String {
        guard item != nil else { return "Aureon" }
        var parts = [m.isActive ? (m.status.state == .paused ? "Paused" : (item?.isStream == true ? "On air" : "Now playing")) : "Up next"]
        if item?.isStream != true, let n = item?.trackNumber { parts.append(item?.trackTotal.map { "Track \(n) of \($0)" } ?? "Track \(n)") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - The panels

/// The side panel: lyrics, the queue, or one of the quieter tools, in a hairline frame.
struct GalleryPanelView: View {
    @EnvironmentObject var stage: StageModel
    let panel: GalleryPanel

    var body: some View {
        GeometryReader { g in
            // the panels change through the shared tab container: the one that leaves drifts away as the next one comes in
            TabSwitcher(tag: panel) { p in
                Group {
                    switch p {
                    case .lyrics: LyricsSection(availableHeight: g.size.height, onClose: close)
                    case .queue: QueueView(dropping: false, onClose: close)
                    case .signal: PanelPage(title: "Signal path", close: close) { VStack(alignment: .leading, spacing: 32) { ReadoutBlock(); SignalPathView() } }
                    case .analyser: AnalyserPanelPage(close: close)
                    case .booklet: PanelPage(title: "Booklet", close: close) { BookletSection() }
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
        }
        .glassAccent(flat: Brand.ink.opacity(0.03))
        .accessibilityElement(children: .contain).accessibilityLabel(panel.title)
    }

    private func close() { stage.panel = nil }
}

/// A titled page inside the panel: the header stays put (its scrim appears once the content has scrolled under it) and the content scrolls.
private struct PanelPage<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    @StateObject private var scrolled = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).kicker().foregroundStyle(Brand.inkSecondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("Close").accessibilityLabel("Close \(title)")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .scrim(scrolledUnder: scrolled.v)
            .zIndex(1)
            ScrollView(showsIndicators: false) { content.padding(16) }
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 2 } action: { _, now in if scrolled.v != now { scrolled.v = now } }
        }
    }
}

/// The five panel buttons, as small capitals with the gold line under the one that is open. They rest with the rest of the interface.
struct PanelTabs: View {
    @Namespace private var line
    @EnvironmentObject var stage: StageModel
    @EnvironmentObject var idle: IdleTracker
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(GalleryPanel.allCases) { p in PanelTab(panel: p, on: stage.panel == p && !stage.focus, line: line) { stage.toggle(p) } }
            FocusButton()
        }
        .opacity(idle.awake || stage.panel != nil ? 1 : 0)
        .allowsHitTesting(idle.awake || stage.panel != nil)
        .animation(Motion.carpet, value: idle.awake)
    }
}

private struct PanelTab: View {
    let panel: GalleryPanel
    let on: Bool
    let line: Namespace.ID
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            Text(panel.title).font(Typo.sans(10, on ? .medium : .regular)).tracking(1.6).textCase(.uppercase)
                .foregroundStyle(on ? Brand.ink : (hover.v ? Brand.ink : Brand.inkSecondary))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .overlay(alignment: .bottom) { if on { Rectangle().fill(Brand.gradient).frame(height: 1).padding(.horizontal, 10).matchedGeometryEffect(id: "panel.underline", in: line) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .animation(Motion.touch, value: hover.v).animation(Motion.glide, value: on)
        .help(on ? "Close \(panel.title)" : "Open \(panel.title)")
        .accessibilityLabel(panel.title).accessibilityValue(on ? "open" : "closed").accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - The footer: progress and transport

struct GalleryFooter: View {
    @EnvironmentObject var stage: StageModel
    let wide: Bool
    let margin: CGFloat

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 20) {
                BarTime(remaining: false)
                WaveformScrubber(style: .line, tint: Brand.accent).stageMatched(.waveform)
                BarTime(remaining: true)
            }
            GalleryControls(wide: wide && !stage.focus)          // Focus keeps the transport only
        }
        .padding(.horizontal, margin).padding(.bottom, 24)
    }
}

/// Transport, the heart and the volume. They appear with the pointer and go with it.
struct GalleryControls: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var idle: IdleTracker
    let wide: Bool

    var body: some View {
        HStack(spacing: 24) {
            if wide {
                HStack(spacing: 4) {
                    HeartButton(path: path, size: 15, ink: Brand.ink)
                    AddToPlaylistButton(path: path, size: 15, ink: Brand.ink)
                }
                .frame(width: 200, alignment: .leading)
            }
            transport.frame(maxWidth: .infinity)
            if wide { VolumeControl(width: 110).frame(width: 220, alignment: .trailing) }
        }
        .frame(height: 64)
        .opacity(idle.awake ? 1 : 0)
        .allowsHitTesting(idle.awake)
        .animation(Motion.carpet, value: idle.awake)
    }

    private var path: String? { m.focusItem.flatMap { $0.isStream ? nil : $0.path } }

    /// The full row when there is room; narrower windows drop the 10-second skips, then shuffle and repeat, before anything is clipped.
    private var transport: some View {
        ViewThatFits(in: .horizontal) {
            row(skips: true, modes: true)
            row(skips: false, modes: true)
            row(skips: false, modes: false)
        }
        .buttonStyle(TransportButtonStyle(size: 15))
    }

    private func row(skips: Bool, modes: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if modes { ShuffleButton(size: 14, tint: Brand.ink) }
                Button { m.player.send(.previous) } label: { TransportGlyph(kind: .previous, size: 16) }.keyboardShortcut(.leftArrow, modifiers: .command).help("Previous").accessibilityLabel("Previous")
                if skips {
                    Button { m.player.send(.seekBy(-10)) } label: { Image(systemName: "gobackward.10") }.keyboardShortcut(.leftArrow, modifiers: []).help("Back 10 s")
                        .disabled(m.status.sourceInfo?.isLive == true)
                }
                Button { m.togglePlay() } label: { TransportGlyph(kind: m.isActive && m.status.state == .playing ? .pause : .play, size: 20) }
                    .buttonStyle(PlayKeyStyle(size: 56)).padding(.horizontal, 8).keyboardShortcut(.space, modifiers: []).help("Play / pause")
                    .accessibilityLabel(m.isActive && m.status.state == .playing ? "Pause" : "Play")
                if skips {
                    Button { m.player.send(.seekBy(10)) } label: { Image(systemName: "goforward.10") }.keyboardShortcut(.rightArrow, modifiers: []).help("Forward 10 s")
                        .disabled(m.status.sourceInfo?.isLive == true)
                }
                Button { m.player.send(.next) } label: { TransportGlyph(kind: .next, size: 16) }.keyboardShortcut(.rightArrow, modifiers: .command).help("Next").accessibilityLabel("Next")
                if modes { RepeatButton(size: 14, tint: Brand.ink) }
            }
            .disabled(m.items.isEmpty)
        }
    }
}

/// One quiet line under the words: where the sound goes and whether it arrives untouched. The full detail is behind the hallmark and in the signal path.
struct OutputLine: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        if m.isActive, m.status.sourceInfo != nil {
            HStack(spacing: 10) {
                Text(m.status.deviceName.isEmpty ? "Output" : m.status.deviceName).lineLimit(1)
                Text("·")
                Text(m.status.bitPerfect ? (m.isDoP ? "DoP · bits untouched" : "Bit-perfect") : "Processed").foregroundStyle(m.status.bitPerfect ? Brand.accentText : Brand.caution)
            }
            .font(Typo.mono(10, .regular)).tracking(1.2).textCase(.uppercase).foregroundStyle(Brand.inkTertiary)
        }
    }
}


/// Focus: the cover, the names, the progress and the transport, nothing else. F toggles it.
struct FocusButton: View {
    @EnvironmentObject var stage: StageModel
    @EnvironmentObject var m: PlayerModel
    @StateObject private var hover = Box(false)

    var body: some View {
        Button { stage.toggleFocus() } label: {
            HStack(spacing: 6) {
                Image(systemName: stage.focus ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(Typo.sans(10, .regular))
                Text("Focus").font(Typo.sans(10, stage.focus ? .medium : .regular)).tracking(1.6).textCase(.uppercase)
            }
            .foregroundStyle(stage.focus ? Brand.accentText : (hover.v ? Brand.ink : Brand.inkSecondary))
            .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .keyboardShortcut("f", modifiers: []).disabled(m.showPalette)
        .help(stage.focus ? "Leave Focus (F)" : "Focus: the cover as large as it goes (F)")
        .accessibilityLabel("Focus").accessibilityValue(stage.focus ? "on" : "off").accessibilityAddTraits(stage.focus ? .isSelected : [])
    }
}

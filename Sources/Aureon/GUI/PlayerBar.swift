import SwiftUI

/// The player at the bottom of every page, in three columns: what is playing on the left (cover, title, heart, add to playlist, artist and the format tags),
/// the transport with the position slider in the middle, and lyrics, queue, output and volume on the right. It sits on the window's colour, with no frame.
struct PlayerBar: View {
    static let height: CGFloat = Metrics.playerBarHeight
    static let bottomInset: CGFloat = 0
    /// The space the bar takes at the bottom of the window, for panels that have to stop above it.
    static var reserved: CGFloat { height + bottomInset }

    @EnvironmentObject var m: PlayerModel

    /// The middle column: as wide as the window allows up to 560, leaving the sides at least `sideMinimum` each.
    static let sideMinimum: CGFloat = 170
    static func centreWidth(window w: CGFloat) -> CGFloat { min(560, max(260, w - 48 - 48 - 2 * sideMinimum)) }
    /// The width of each side column.
    static func sideWidth(window w: CGFloat) -> CGFloat { max(sideMinimum, (w - 48 - 48 - centreWidth(window: w)) / 2) }

    var body: some View {
        GeometryReader { g in
            let centre = Self.centreWidth(window: g.size.width), side = Self.sideWidth(window: g.size.width)
            HStack(spacing: 24) {
                NowPlayingSummary().frame(width: side, alignment: .leading)
                VStack(spacing: 6) {
                    transport
                    BarScrubberRow()
                }
                .frame(width: centre)
                BarRightColumn().frame(width: side, alignment: .trailing)
            }
            .padding(.horizontal, 24).frame(width: g.size.width, height: g.size.height)
        }
        .frame(height: Self.height)
        .background(Brand.window)
    }

    private var transport: some View {
        HStack(spacing: 4) {
            ShuffleButton(size: 15, tint: Brand.inkSecondary)
            Button { m.player.send(.previous) } label: { TransportGlyph(kind: .previous, size: TransportMetrics.skip().glyph) }
                .buttonStyle(HairlineKeyStyle(hit: TransportMetrics.skip().hit)).keyboardShortcut(.leftArrow, modifiers: .command).help("Previous").accessibilityLabel("Previous")
            Button { m.togglePlay() } label: {
                TransportGlyph(kind: m.isActive && m.status.state == .playing ? .pause : .play, size: TransportMetrics.play().glyph)
            }
            .buttonStyle(HairlineKeyStyle(hit: TransportMetrics.play().hit))
            .keyboardShortcut(.space, modifiers: []).help("Play / pause").accessibilityLabel(m.isActive && m.status.state == .playing ? "Pause" : "Play")
            Button { m.player.send(.next) } label: { TransportGlyph(kind: .next, size: TransportMetrics.skip().glyph) }
                .buttonStyle(HairlineKeyStyle(hit: TransportMetrics.skip().hit)).keyboardShortcut(.rightArrow, modifiers: .command).help("Next").accessibilityLabel("Next")
            RepeatButton(size: 15, tint: Brand.inkSecondary)
        }
        .disabled(m.items.isEmpty)
    }
}

/// The top edge of the bar: a hairline, and 4 points below it the pinstripe, inset from both sides, that fills with the song's progress.
struct BarPinstripe: View {
    var inset: CGFloat = 16
    var showsRule = true
    @EnvironmentObject var progress: ProgressModel
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        let f = m.isActive && m.status.sourceInfo?.isLive != true ? CGFloat(ScrubMath.fraction(position: m.scrub ?? progress.position, duration: max(progress.duration, 0.001))) : 0
        VStack(spacing: 0) {
            if showsRule { Rule() }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Brand.coachline.opacity(0.35)).frame(height: Metrics.hairline)
                    Rectangle().fill(Brand.gradient).frame(width: max(0, g.size.width * f), height: 1)
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .leading)
                .animation(.linear(duration: 0.12), value: f)
            }
            .frame(height: 1).padding(.horizontal, inset).padding(.top, showsRule ? 3 : 5)
        }
        .allowsHitTesting(false)
    }
}

/// The right of the bar: lyrics, queue and output, then the volume. As the window narrows the volume slider shrinks, then goes; the buttons stay.
struct BarRightColumn: View {
    @EnvironmentObject var m: PlayerModel

    /// What the width allows, in the order things give way.
    static func plan(width w: CGFloat) -> (shortBadge: Bool, volumeWidth: CGFloat?) {
        (w < 232, w >= 232 ? 84 : (w >= 196 ? 56 : nil))
    }

    var body: some View {
        GeometryReader { g in
            let p = Self.plan(width: g.size.width)
            HStack(spacing: 2) {
                LyricsButton(size: 15)
                QueueButton(ink: Brand.ink)
                QuickPanelButton(anchor: .bar)
                if let vw = p.volumeWidth { Color.clear.frame(width: 6); VolumeControl(width: vw + 12, readout: false) }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .trailing)
        }
    }
}

/// The hallmark in the bar, in the full compact form or the short one.
struct BarBadge: View {
    @EnvironmentObject var m: PlayerModel
    let short: Bool
    var body: some View {
        if short { NowPlayingBadge(size: .compact, forceShort: true) } else { NowPlayingBadge(size: .compact) }
    }
}

/// The cover and the names: the cover opens Now Playing; the title in medium with the heart and the playlist button beside it, the artist under it and the
/// format tags under that.
struct NowPlayingSummary: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let item = m.focusItem, d = m.focusDisplay
        HStack(spacing: 16) {
            Button { stage.open(m, reduceMotion: reduceMotion) } label: {
                CoverView(image: m.hero.image ?? item?.thumb, palette: m.hero.palette, corner: 10, symbol: item?.isStream == true ? "dot.radiowaves.left.and.right" : "music.note")
                    .stageMatched(.cover)
                    .frame(width: 68, height: 68)
            }
            .buttonStyle(.plain).disabled(item == nil).help("Open Now Playing")
            .accessibilityLabel("Open Now Playing")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(d?.title ?? "Not playing").font(Typo.serif(16, .medium)).foregroundStyle(HWPanel.readout).lineLimit(1)
                    if let item, !item.isStream {
                        HeartButton(path: item.path, size: 14)
                        AddToPlaylistButton(path: item.path, size: 14)
                    }
                }
                Text(d.map { $0.artist.isEmpty ? (item?.album ?? "") : $0.artist } ?? "Add music or tune a station")
                    .font(Typo.sans(14, .medium)).foregroundStyle(HWPanel.readoutDim).lineLimit(1)
                QualityPill().padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Elapsed time, the waveform, total time.
struct BarScrubberRow: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            BarTime(remaining: false)
            WaveformScrubber(style: .slim, tint: Brand.accent).stageMatched(.waveform)
            BarTime(remaining: true)
        }
    }
}

/// One time readout in SF Mono: the elapsed time on the left of the waveform, the length on the right. For live radio: ON AIR.
struct BarTime: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var progress: ProgressModel
    let remaining: Bool

    var body: some View {
        let live = m.status.sourceInfo?.isLive == true && m.isActive
        let dur = max(progress.duration, 0.001), pos = m.scrub ?? progress.position
        Group {
            if live { Text(remaining ? "" : "ON AIR").foregroundStyle(HWPanel.readoutDim) }
            else { Text(remaining ? clock(dur) : clock(pos)).foregroundStyle(remaining ? HWPanel.readoutDim : HWPanel.readout) }
        }
        .font(Typo.sans(12.5, .medium)).monospacedDigit().fixedSize().frame(minWidth: 36, alignment: remaining ? .leading : .trailing)
        .accessibilityHidden(true)
    }
}

/// The format readout: codec, bit depth and rate in tracked SF Mono, dropping the lesser ones first when space is short.
struct BarFormatStrip: View {
    var alignment: Alignment = .trailing
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        AdaptiveLEDStrip(lamps: lamps).frame(maxWidth: alignment == .leading ? .infinity : nil, minHeight: 16, alignment: alignment)
    }

    /// Lit indicators for the audible stream, plus MIX while a crossfade runs.
    private var lamps: [LEDLamp] {
        guard m.isActive else { return [] }
        let mixing = m.status.mixingInto != nil
        let mixHelp = m.status.pipeline.first(where: { $0.hasPrefix("Crossfade") })
        if let raw = m.status.sourceInfo {
            return LEDLamp.lamps(source: raw, output: m.status.info, bitrate: m.status.live?.bitrate, mixing: mixing, mixHelp: mixHelp)
        }
        return mixing ? [LEDLamp.mix(help: mixHelp)] : []
    }
}

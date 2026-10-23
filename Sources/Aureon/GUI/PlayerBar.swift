import SwiftUI

/// The player at the bottom of every page: what is playing on the left, the transport and the waveform in the middle, the format readout and the
/// volume knob on the right. It is one flat band in the sidebar's colour, edged by a hairline and a single champagne pinstripe inset below it;
/// the pinstripe fills along its length as the song plays, so it is the progress rule too.
struct PlayerBar: View {
    static let height: CGFloat = 96
    static let bottomInset: CGFloat = 0
    /// The space the bar takes at the bottom of the window, for panels that have to stop above it.
    static var reserved: CGFloat { height + bottomInset }

    @EnvironmentObject var m: PlayerModel
    @Environment(\.glassAccents) private var glassOn
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The width of each side column: as much as the window allows up to a comfortable size, leaving the middle at least `centreMinimum`.
    static let centreMinimum: CGFloat = 300
    static func sideWidth(window w: CGFloat) -> CGFloat { min(260, max(150, (w - 96 - centreMinimum) / 2)) }
    /// The gap around the floating glass plate.
    static let plateInset = EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12)

    var body: some View {
        if GlassPolicy.surface(enabled: glassOn, reduceTransparency: reduceTransparency) == .glass {
            // a floating plate of glass over the backdrop; the bar still takes its 96 points, so no page is covered
            content(top: 4)
                .frame(height: Self.height - Self.plateInset.top - Self.plateInset.bottom)
                .glassAccent()
                .overlay(alignment: .top) { BarPinstripe(inset: 24, showsRule: false) }
                .padding(Self.plateInset)
                .frame(height: Self.height)
        } else {
            content(top: 8)
                .frame(height: Self.height)
                .background(Brand.sidebar)
                .overlay(alignment: .top) { BarPinstripe() }
        }
    }

    private func content(top: CGFloat) -> some View {
        GeometryReader { g in
            let side = Self.sideWidth(window: g.size.width)
            HStack(spacing: 24) {
                NowPlayingSummary().frame(width: side, alignment: .leading)
                VStack(spacing: 8) {
                    transport
                    BarScrubberRow()
                }
                .frame(maxWidth: .infinity)
                BarRightColumn().frame(width: side, alignment: .trailing)
            }
            .padding(.horizontal, 24).padding(.top, top).frame(width: g.size.width, height: g.size.height)
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            ShuffleButton(size: 12, tint: Brand.inkSecondary)
            Button { m.player.send(.previous) } label: { TransportGlyph(kind: .previous, size: 14) }
                .keyboardShortcut(.leftArrow, modifiers: .command).help("Previous").accessibilityLabel("Previous")
            Button { m.togglePlay() } label: {
                TransportGlyph(kind: m.isActive && m.status.state == .playing ? .pause : .play, size: 16)
            }
            .buttonStyle(PlayKeyStyle(size: 40)).padding(.horizontal, 8)
            .keyboardShortcut(.space, modifiers: []).help("Play / pause").accessibilityLabel(m.isActive && m.status.state == .playing ? "Pause" : "Play")
            Button { m.player.send(.next) } label: { TransportGlyph(kind: .next, size: 14) }
                .keyboardShortcut(.rightArrow, modifiers: .command).help("Next").accessibilityLabel("Next")
            RepeatButton(size: 12, tint: Brand.inkSecondary)
        }
        .buttonStyle(TransportButtonStyle(size: 12, ink: Brand.ink)).disabled(m.items.isEmpty)
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

/// The right of the bar: the quality hallmark, and under it the volume and the lyrics and queue buttons. As the window narrows, the hallmark takes its
/// short form first, then the volume slider shrinks, then goes; the buttons stay.
struct BarRightColumn: View {
    @EnvironmentObject var m: PlayerModel

    /// What the width allows, in the order things give way.
    static func plan(width w: CGFloat) -> (shortBadge: Bool, volumeWidth: CGFloat?) {
        (w < 232, w >= 232 ? 84 : (w >= 196 ? 56 : nil))
    }

    var body: some View {
        GeometryReader { g in
            let p = Self.plan(width: g.size.width)
            VStack(alignment: .trailing, spacing: 8) {
                BarBadge(short: p.shortBadge).frame(height: 28, alignment: .trailing)
                HStack(spacing: 4) {
                    if let vw = p.volumeWidth { VolumeControl(width: vw, readout: vw >= 84) }
                    QuickPanelButton(anchor: .bar)
                    LyricsButton(size: 12)
                    QueueButton(ink: Brand.ink)
                }
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

/// The cover and the names: the cover opens Now Playing; the title is set in the serif, the artist small beneath it.
struct NowPlayingSummary: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let item = m.focusItem, d = m.focusDisplay
        HStack(spacing: 16) {
            Button { stage.open(m, reduceMotion: reduceMotion) } label: {
                CoverView(image: m.hero.image ?? item?.thumb, palette: m.hero.palette, corner: 2, symbol: item?.isStream == true ? "dot.radiowaves.left.and.right" : "music.note")
                    .stageMatched(.cover)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain).disabled(item == nil).help("Open Now Playing")
            .accessibilityLabel("Open Now Playing")
            VStack(alignment: .leading, spacing: 4) {
                Text(d?.title ?? "Not playing").font(Typo.serif(17, .regular)).foregroundStyle(HWPanel.readout).lineLimit(1)
                Text(d.map { $0.artist.isEmpty ? (item?.album ?? "") : $0.artist } ?? "Add music or tune a station")
                    .font(Typo.sans(11)).tracking(0.2).foregroundStyle(HWPanel.readoutDim).lineLimit(1)
            }
        }
    }
}

/// Elapsed time, the waveform, total time.
struct BarScrubberRow: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            BarTime(remaining: false)
            WaveformScrubber(style: .bar, tint: Brand.accent).stageMatched(.waveform)
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
        .font(Typo.mono(11, .regular)).fixedSize().frame(minWidth: 36, alignment: remaining ? .leading : .trailing)
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

import SwiftUI

/// The player at the bottom of every page, built like the front panel of a receiver: transport keys on the left, a recessed black display window
/// in the middle (cover, title, the lit format indicators, the time readout and the waveform scrubber), volume and the queue on the right.
/// It stays dark in every theme, the way a front panel is not repainted by the room it stands in.
struct PlayerBar: View {
    static let height: CGFloat = 78
    static let bottomInset: CGFloat = 12
    /// The space the bar takes at the bottom of the window, for panels that have to stop above it.
    static var reserved: CGFloat { height + bottomInset }

    @EnvironmentObject var m: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            transport
            BarDisplay().frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Image(systemName: m.hasVolume ? "speaker.wave.2.fill" : "lock.fill", variableValue: m.hasVolume ? Double(m.volume) : 1).font(.system(size: 11))
                    .foregroundStyle(HWPanel.readoutDim.color).frame(width: 16).symbolRenderingMode(.hierarchical)
                FluidSlider(value: Binding(get: { Double(m.volume) }, set: { m.setVolume(Float($0)) }), tint: .white.opacity(0.9), restingHeight: 3, enabled: m.hasVolume, bubble: { "\(Int($0 * 100))%" }, safe: true)
                    .frame(width: 78)
                LyricsButton(size: 12)
                QueueButton(ink: .white)
            }
        }
        .padding(.horizontal, 12).frame(height: Self.height)
        .hardwareChassis(radius: 22)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16).padding(.bottom, Self.bottomInset)
    }

    private var transport: some View {
        HStack(spacing: 1) {
            ShuffleButton(size: 12, tint: .white)
            Button { m.player.send(.previous) } label: { Image(systemName: "backward.fill") }.keyboardShortcut(.leftArrow, modifiers: .command).help("Previous")
            Button { m.togglePlay() } label: { Image(systemName: m.isActive && m.status.state == .playing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace)) }
                .buttonStyle(HardwareKeyStyle(diameter: 36, glow: m.hero.palette.accent.color)).padding(.horizontal, 3)
                .keyboardShortcut(.space, modifiers: []).help("Play / pause")
            Button { m.player.send(.next) } label: { Image(systemName: "forward.fill") }.keyboardShortcut(.rightArrow, modifiers: .command).help("Next")
            RepeatButton(size: 12, tint: .white)
        }
        .buttonStyle(TransportButtonStyle(size: 13, ink: .white)).disabled(m.items.isEmpty)
    }
}

/// The display window: cover, title, lit indicators, time and the waveform. Only the time readout and the scrubber observe the playhead.
struct BarDisplay: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let item = m.focusItem, d = m.focusDisplay
        HStack(spacing: 10) {
            Button { stage.open(m, reduceMotion: reduceMotion) } label: {
                CoverView(image: m.hero.image ?? item?.thumb, palette: m.hero.palette, corner: 7, symbol: item?.isStream == true ? "dot.radiowaves.left.and.right" : "music.note")
                    .stageMatched(.cover)
                    .frame(width: 46, height: 46)
                    .shadow(color: m.hero.palette.accent.color.opacity(0.25), radius: 6)
            }
            .buttonStyle(.plain).disabled(item == nil).help("Open Now Playing")
            .accessibilityLabel("Open Now Playing")
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d?.title ?? "Not playing").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(HWPanel.readout.color).lineLimit(1)
                        Text(d.map { [$0.artist, item?.isStream == true ? nil : item?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ") } ?? "Add music or tune a station")
                            .font(.system(size: 11)).foregroundStyle(HWPanel.readoutDim.color).lineLimit(1)
                    }
                    .frame(minWidth: 96, alignment: .leading)
                    HeartButton(path: item.flatMap { $0.isStream ? nil : $0.path }, size: 12, ink: .white)
                    AddToPlaylistButton(path: item.flatMap { $0.isStream ? nil : $0.path }, size: 12, ink: .white)
                    Spacer(minLength: 6)
                    AdaptiveLEDStrip(lamps: lamps)
                        .layoutPriority(1)
                    BarTimeReadout()
                }
                WaveformScrubber(style: .bar, tint: m.hero.palette.accent.color)
                    .stageMatched(.waveform)
            }
        }
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 6)
        .displayWindow(radius: 14)
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

/// Elapsed and total time, in the display's readout face.
struct BarTimeReadout: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var progress: ProgressModel

    var body: some View {
        let live = m.status.sourceInfo?.isLive == true && m.isActive
        let dur = max(progress.duration, 0.001), pos = m.scrub ?? progress.position
        HStack(spacing: 4) {
            if live {
                Text("ON AIR").foregroundStyle(HWPanel.readoutDim.color)
            } else {
                Text(clock(pos)).foregroundStyle(HWPanel.readout.color)
                Text("/ \(clock(dur))").foregroundStyle(HWPanel.readoutDim.color)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit().fixedSize()
        .accessibilityElement(children: .combine)
    }
}

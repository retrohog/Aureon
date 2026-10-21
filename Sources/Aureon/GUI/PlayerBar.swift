import SwiftUI

/// The floating player at the bottom of every page: transport, a now-playing display (blurred cover, format badges, progress), volume and the queue.
struct PlayerBar: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var showQueue = Box(false)

    var body: some View {
        HStack(spacing: 14) {
            transport
            BarDisplay().frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Image(systemName: m.hasVolume ? "speaker.wave.2.fill" : "lock.fill", variableValue: m.hasVolume ? Double(m.volume) : 1).font(.system(size: 11))
                    .foregroundStyle(.secondary).frame(width: 16).symbolRenderingMode(.hierarchical)
                FluidSlider(value: Binding(get: { Double(m.volume) }, set: { m.setVolume(Float($0)) }), tint: Brand.ink.opacity(0.9), restingHeight: 3, enabled: m.hasVolume, bubble: { "\(Int($0 * 100))%" }, safe: true)
                    .frame(width: 78)
                Button { showQueue.v.toggle() } label: { Image(systemName: "list.bullet").foregroundStyle(showQueue.v ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary)) }
                    .buttonStyle(IconButtonStyle()).help("Queue")
                    .popover(isPresented: $showQueue.v, arrowEdge: .top) { QueuePopover().environmentObject(m) }
            }
        }
        .padding(.horizontal, 14).frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Brand.sidebar.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Button { m.player.send(.previous) } label: { Image(systemName: "backward.fill") }.keyboardShortcut(.leftArrow, modifiers: .command).help("Previous")
            Button { m.togglePlay() } label: { Image(systemName: m.isActive && m.status.state == .playing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace)).font(.system(size: 18)) }
                .keyboardShortcut(.space, modifiers: []).help("Play / pause")
            Button { m.player.send(.next) } label: { Image(systemName: "forward.fill") }.keyboardShortcut(.rightArrow, modifiers: .command).help("Next")
        }
        .buttonStyle(TransportButtonStyle(size: 13, ink: Brand.ink)).disabled(m.items.isEmpty)
    }
}

/// Cover, title, format badges and the progress line. Only this view observes the playhead.
struct BarDisplay: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var progress: ProgressModel

    var body: some View {
        let item = m.focusItem, d = m.focusDisplay
        let live = m.status.sourceInfo?.isLive == true && m.isActive
        let dur = max(progress.duration, 0.001), pos = m.scrub ?? progress.position
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.2)) { m.tab = .player } } label: {
                    CoverView(image: m.hero.image ?? item?.thumb, palette: m.hero.palette, corner: 6).frame(width: 38, height: 38)
                }.buttonStyle(.plain).help("Open Now Playing")
                VStack(alignment: .leading, spacing: 1) {
                    Text(d?.title ?? "Not playing").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(d.map { [$0.artist, item?.isStream == true ? nil : item?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ") } ?? "Add music or tune a station").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 6)
                if let raw = m.status.sourceInfo, m.isActive {
                    ViewThatFits(in: .horizontal) {
                        FormatBadges(source: raw, output: m.status.info, bitrate: m.status.live?.bitrate, compact: true)
                        FormatBadges(source: raw, output: nil, bitrate: m.status.live?.bitrate, compact: true).opacity(1)
                        HWBadge(text: raw.codec.replacingOccurrences(of: " (lossy)", with: "").uppercased(), tone: qualityTier(raw).tone, compact: true)
                    }
                }
                Text(live ? "LIVE" : "\(clock(pos)) / \(clock(dur))").font(.system(size: 10.5, weight: .medium, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(live ? Brand.pink : .white.opacity(0.6)).fixedSize()
            }
            .padding(.horizontal, 9).padding(.top, 5)
            FluidSlider(value: Binding(get: { m.scrub ?? progress.position }, set: { m.scrub = $0 }), range: 0...dur, tint: m.hero.palette.accent.color, restingHeight: 2.5, enabled: m.isActive && !live,
                        bubble: { clock($0) }, scrollStep: 5) { editing in
                if !editing, let t = m.scrub { m.player.send(.seekTo(t)); m.scrub = nil }
            }.padding(.horizontal, 9).frame(height: 14)
        }
        .frame(height: 50)
        .background {
            ZStack {
                if let img = m.hero.image ?? item?.thumb {
                    GeometryReader { g in Image(nsImage: img).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped().blur(radius: 28).saturation(1.4).opacity(0.55) }
                } else { LinearGradient(colors: [m.hero.palette.grid[0].color, m.hero.palette.grid[8].color], startPoint: .leading, endPoint: .trailing).opacity(0.35) }
                Color.black.opacity(0.32)
            }.clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Brand.ink.opacity(0.1), lineWidth: 0.8))
    }
}

/// The queue, opened from the player bar instead of living in a permanent column.
struct QueuePopover: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View { QueueView(dropping: false).frame(width: 360, height: 520).environment(\.colorScheme, .dark) }
}

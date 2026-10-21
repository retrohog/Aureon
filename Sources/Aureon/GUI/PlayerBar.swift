import SwiftUI

/// The floating player at the bottom of every page: transport, a now-playing display with progress, volume and the queue.
struct PlayerBar: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var showQueue = Box(false)

    var body: some View {
        HStack(spacing: 16) {
            transport
            display.frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                Image(systemName: m.hasVolume ? "speaker.wave.2.fill" : "lock.fill", variableValue: m.hasVolume ? Double(m.volume) : 1).font(.system(size: 12))
                    .foregroundStyle(.secondary).frame(width: 18).symbolRenderingMode(.hierarchical)
                FluidSlider(value: Binding(get: { Double(m.volume) }, set: { m.volume = Float($0) }), tint: .white.opacity(0.9), restingHeight: 3, enabled: m.hasVolume, bubble: { "\(Int($0 * 100))%" })
                    .frame(width: 88)
                Button { showQueue.v.toggle() } label: { Image(systemName: "list.bullet").foregroundStyle(showQueue.v ? Brand.accent : .primary) }
                    .buttonStyle(IconButtonStyle()).help("Queue")
                    .popover(isPresented: $showQueue.v, arrowEdge: .top) { QueuePopover().environmentObject(m) }
            }
        }
        .padding(.horizontal, 18).frame(height: 68)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        .padding(.horizontal, 18).padding(.bottom, 14)
    }

    private var transport: some View {
        HStack(spacing: 2) {
            Button { m.player.send(.previous) } label: { Image(systemName: "backward.fill") }.keyboardShortcut(.leftArrow, modifiers: .command).help("Previous")
            Button { m.togglePlay() } label: { Image(systemName: m.isActive && m.status.state == .playing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace)).font(.system(size: 20)) }
                .keyboardShortcut(.space, modifiers: []).help("Play / pause")
            Button { m.player.send(.next) } label: { Image(systemName: "forward.fill") }.keyboardShortcut(.rightArrow, modifiers: .command).help("Next")
        }
        .buttonStyle(TransportButtonStyle(size: 15)).disabled(m.items.isEmpty)
    }

    private var display: some View {
        let item = m.focusItem
        let dur = max(m.status.duration, 0.001), pos = m.scrub ?? m.status.position
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button { withAnimation(.smooth(duration: 0.35)) { m.tab = .player } } label: {
                    CoverView(image: m.hero.image ?? item?.thumb, palette: m.hero.palette, corner: 6).frame(width: 40, height: 40)
                }.buttonStyle(.plain).help("Open Now Playing")
                VStack(alignment: .leading, spacing: 1) {
                    Text(item?.title ?? "Not playing").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle(item)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let raw = m.status.sourceInfo, m.isActive {
                    HWBadge(text: raw.codec.replacingOccurrences(of: " (lossy)", with: "").uppercased(), detail: raw.sourceBits == 1 ? dsdRateName(raw.sourceRate ?? raw.sampleRate) : "\(raw.sourceBits)/\(formatRate(raw.sampleRate).replacingOccurrences(of: " kHz", with: ""))",
                            tone: qualityTier(raw).tone, lit: m.status.bitPerfect)
                        .help(m.status.bitPerfect ? "Bit-perfect to \(m.status.deviceName)" : "Processed or not natively accepted by the device")
                }
                Text("\(clock(pos)) / \(clock(dur))").font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.top, 6)
            FluidSlider(value: Binding(get: { m.scrub ?? m.status.position }, set: { m.scrub = $0 }), range: 0...dur, tint: m.hero.palette.accent.color, restingHeight: 3, enabled: m.isActive,
                        bubble: { clock($0) }) { editing in
                if !editing, let t = m.scrub { m.player.send(.seekTo(t)); m.scrub = nil }
            }.padding(.horizontal, 10).padding(.bottom, 0)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.2)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.8))
    }

    private func subtitle(_ item: QueueItem?) -> String {
        guard let item else { return "Add music to begin" }
        return [item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

/// The queue, opened from the player bar instead of living in a permanent column.
struct QueuePopover: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View { QueueView(dropping: false).frame(width: 360, height: 520).environment(\.colorScheme, .dark) }
}

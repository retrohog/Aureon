import SwiftUI

/// ROOMS: where the sound goes. Each output device is a named room with a single gold mark for the one that is playing; below them, the speaker
/// groups, cast, multi-room zones and remote control that used to be spread over other pages.
struct RoomsPage: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        PageScaffold(title: "Rooms", subtitle: "Where the sound plays") {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 48) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(m.devices) { d in RoomRow(device: d, active: d.id == m.deviceID) { m.deviceID = d.id } }
                        if m.devices.isEmpty {
                            Text("No output devices found.").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).padding(.vertical, 24)
                        }
                    }
                    Masonry(columns: 2, spacing: 40) {
                        SpeakerSetupCard().id("rooms.speakers")
                        CastCard()
                        ZoneCard()
                        RemoteCard(remote: m.remote, social: m.social)
                    }
                }
                // "Level speakers" (from the quick panel or ⌘K) comes here and scrolls to the speaker set-up, where the balance is
                .onAppear { reveal(proxy) }
                .onChange(of: m.roomsFocus) { _, _ in reveal(proxy) }
            }
        }
        .onAppear { m.refreshDevices() }
    }
}

extension RoomsPage {
    @MainActor fileprivate func reveal(_ proxy: ScrollViewProxy) {
        guard m.roomsFocus == .levelSpeakers else { return }
        DispatchQueue.main.async {
            withAnimation(TabMotion.animation) { proxy.scrollTo("rooms.speakers", anchor: .top) }
            m.roomsFocus = nil
        }
    }
}

/// One room: its name in the serif, what it can do in SF Mono, and the gold mark when it is the one playing.
struct RoomRow: View {
    let device: OutputDeviceInfo
    let active: Bool
    let choose: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 24) {
                Circle().fill(active ? Brand.accent : Color.clear).frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(active ? Color.clear : Brand.rule, lineWidth: Metrics.hairline))
                Text(device.name).font(Typo.serif(24, .regular)).tracking(-0.2).foregroundStyle(active ? Brand.ink : Brand.inkSecondary).lineLimit(1)
                Spacer(minLength: 16)
                Text(device.rates.map { formatRate($0) }.joined(separator: " · ")).font(Typo.mono(10, .regular)).foregroundStyle(Brand.inkTertiary).lineLimit(1)
            }
            .padding(.vertical, 20).contentShape(Rectangle())
            .background(Rectangle().fill(Brand.ink.opacity(hover.v ? 0.03 : 0)))
            .overlay(alignment: .bottom) { Rule(strength: 0.6) }
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .accessibilityLabel(device.name).accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Lays its children out in columns, each next to the shortest one so far; one column when the space is narrow. For pages of cards with different heights.
struct Masonry: Layout {
    var columns = 2
    var spacing: CGFloat = 32
    /// Below this width a single column is used.
    var minimumWidth: CGFloat = 900

    private func count(_ width: CGFloat) -> Int { width >= minimumWidth ? max(1, columns) : 1 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], sizes: [CGSize], height: CGFloat) {
        let n = count(width)
        let colW = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        var heights = [CGFloat](repeating: 0, count: n)
        var origins: [CGPoint] = [], sizes: [CGSize] = []
        for sv in subviews {
            let c = heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            let s = sv.sizeThatFits(ProposedViewSize(width: colW, height: nil))
            origins.append(CGPoint(x: CGFloat(c) * (colW + spacing), y: heights[c]))
            sizes.append(CGSize(width: colW, height: s.height))
            heights[c] += s.height + spacing
        }
        return (origins, sizes, max(0, (heights.max() ?? spacing) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 900
        return CGSize(width: w, height: arrange(width: w, subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews)
        for (i, sv) in subviews.enumerated() {
            sv.place(at: CGPoint(x: bounds.minX + r.origins[i].x, y: bounds.minY + r.origins[i].y), anchor: .topLeading, proposal: ProposedViewSize(r.sizes[i]))
        }
    }
}

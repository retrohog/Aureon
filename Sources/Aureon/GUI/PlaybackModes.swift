import SwiftUI

/// What the shuffle list shows: every mode the engine supports, with the current one marked. Pure, so the list is testable.
enum ShuffleChoices {
    struct Row: Equatable, Identifiable { let mode: ShuffleMode; let title: String; let blurb: String; let isCurrent: Bool; var id: String { mode.rawValue } }
    static func rows(current: ShuffleMode) -> [Row] {
        ShuffleMode.allCases.map { Row(mode: $0, title: $0.title, blurb: $0.blurb, isCurrent: $0 == current) }
    }
    @MainActor static func select(_ mode: ShuffleMode, in m: PlayerModel) { m.shuffle = mode }
}

/// Shuffle: off, normal or smart. A click opens a short list of the real modes, each with what it does and a mark on the current one; the icon lights
/// up when shuffle is on. (A drawn list rather than a system menu: the menu's rows took the theme's text colour and could come up blank.)
struct ShuffleButton: View {
    @EnvironmentObject var m: PlayerModel
    var size: CGFloat = 13
    var tint: Color? = nil
    @StateObject private var hover = Box(false)
    @StateObject private var open = Box(false)

    var body: some View {
        Button { open.v.toggle() } label: {
            Image(systemName: m.shuffle.icon).font(Typo.sans(TransportMetrics.modeGlyph, .heavy))
                .foregroundStyle(hover.v || m.shuffle != .off ? Brand.accentText : (tint ?? Brand.ink))
                .frame(width: TransportMetrics.minHit, height: TransportMetrics.minHit)
                .overlay(alignment: .bottom) { if m.shuffle != .off { Circle().fill(Brand.accent).frame(width: 4, height: 4).offset(y: -5) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .help(m.shuffle == .off ? "Shuffle is off" : "Shuffle: \(m.shuffle.title) is on")
        .accessibilityLabel("Shuffle: \(m.shuffle.title)").layoutProbe("shuffle")
        .windowPopover(isPresented: Binding(get: { open.v }, set: { open.v = $0 }), edge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Shuffle").microLabel().foregroundStyle(Brand.inkTertiary).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
                ForEach(ShuffleChoices.rows(current: m.shuffle)) { row in
                    ShuffleRow(row: row) { ShuffleChoices.select(row.mode, in: m); open.v = false }
                }
                Color.clear.frame(height: 8)
            }
            .frame(width: 280).glassPopover().foregroundStyle(Brand.ink)
        }
    }
}

struct ShuffleRow: View {
    let row: ShuffleChoices.Row
    let choose: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark").font(Typo.sans(11, .medium)).foregroundStyle(Brand.accentText).opacity(row.isCurrent ? 1 : 0).frame(width: 14).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(Typo.sans(13, row.isCurrent ? .medium : .regular)).foregroundStyle(Brand.ink)
                    Text(row.blurb).font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
            .background(Rectangle().fill(Brand.ink.opacity(hover.v ? 0.06 : 0)))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .accessibilityLabel(row.title).accessibilityValue(row.isCurrent ? "selected" : "").accessibilityHint(row.blurb)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
    }
}

/// Repeat: off → all → one.
struct RepeatButton: View {
    @EnvironmentObject var m: PlayerModel
    var size: CGFloat = 13
    var tint: Color? = nil
    @StateObject private var hover = Box(false)

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { m.repeatMode = RepeatMode(rawValue: (m.repeatMode.rawValue + 1) % 3) ?? .off }
        } label: {
            Image(systemName: m.repeatMode == .one ? "repeat.1" : "repeat").font(Typo.sans(TransportMetrics.modeGlyph, .heavy))
                .foregroundStyle(hover.v || m.repeatMode != .off ? Brand.accentText : (tint ?? Brand.ink))
                .frame(width: TransportMetrics.minHit, height: TransportMetrics.minHit)
                .overlay(alignment: .bottom) { if m.repeatMode != .off { Circle().fill(Brand.accent).frame(width: 4, height: 4).offset(y: -5) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .help(m.repeatMode == .off ? "Repeat: off" : (m.repeatMode == .all ? "Repeat the queue" : "Repeat this song"))
        .accessibilityLabel("Repeat \(m.repeatMode == .off ? "off" : m.repeatMode == .all ? "all" : "one")")
    }
}

/// Opens or closes the queue panel.
struct QueueButton: View {
    @EnvironmentObject var m: PlayerModel
    var size: CGFloat = 13
    /// Glyph colour when the queue is closed: the theme's ink by default, white on the always-dark player bar and Now Playing.
    var ink: Color? = nil
    var body: some View {
        Button { withAnimation(.smooth(duration: 0.28)) { m.showQueue.toggle() } } label: {
            Image(systemName: "list.bullet").foregroundStyle(m.showQueue ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(ink ?? Brand.ink))
        }
        .buttonStyle(IconButtonStyle()).help(m.showQueue ? "Hide the queue" : "Show the queue")
    }
}

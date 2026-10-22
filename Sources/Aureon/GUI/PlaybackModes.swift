import SwiftUI

/// Shuffle: off, normal or smart. A click opens the three choices; the icon lights up when shuffle is on.
struct ShuffleButton: View {
    @EnvironmentObject var m: PlayerModel
    var size: CGFloat = 13
    var tint: Color? = nil
    @StateObject private var hover = Box(false)

    var body: some View {
        Menu {
            Picker("Shuffle", selection: $m.shuffle) {
                ForEach(ShuffleMode.allCases) { mode in Text(mode == .off ? "Off" : mode.title).tag(mode) }
            }.pickerStyle(.inline)
            Text(m.shuffle.blurb)
        } label: {
            Image(systemName: m.shuffle.icon).font(.system(size: size, weight: .semibold))
                .foregroundStyle(m.shuffle == .off ? AnyShapeStyle(tint ?? Brand.ink) : AnyShapeStyle(Brand.accent))
                .frame(width: 30, height: 28)
                .background(Circle().fill(Brand.ink.opacity(hover.v ? 0.1 : 0)))
                .overlay(alignment: .bottom) { if m.shuffle != .off { Circle().fill(Brand.accent).frame(width: 3.5, height: 3.5).offset(y: 3) } }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().onHover { hover.v = $0 }
        .help(m.shuffle == .off ? "Shuffle" : "\(m.shuffle.title) is on")
        .accessibilityLabel("Shuffle \(m.shuffle.title)")
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
            Image(systemName: m.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: size, weight: .semibold))
                .foregroundStyle(m.repeatMode == .off ? AnyShapeStyle(tint ?? Brand.ink) : AnyShapeStyle(Brand.accent))
                .frame(width: 30, height: 28)
                .background(Circle().fill(Brand.ink.opacity(hover.v ? 0.1 : 0)))
                .overlay(alignment: .bottom) { if m.repeatMode != .off { Circle().fill(Brand.accent).frame(width: 3.5, height: 3.5).offset(y: 3) } }
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

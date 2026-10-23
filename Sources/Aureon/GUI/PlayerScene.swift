import SwiftUI

// The pieces of Now Playing that sit below the Gallery screen: the queue to come and the analyser. (The Gallery itself is in Gallery.swift.)

/// The next songs, beside the signal path: tap one to play it.
struct UpNextPanel: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        let items = m.items
        let at = items.firstIndex { $0.id == m.status.trackID } ?? -1
        let upcoming = Array(items.dropFirst(at + 1).prefix(7))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Up next").kicker().foregroundStyle(Brand.inkSecondary)
                Spacer()
                if m.shuffle != .off { Label(m.shuffle.title, systemImage: m.shuffle.icon).font(Typo.sans(10.5, .semibold)).foregroundStyle(m.hero.palette.accent.color) }
                Button { withAnimation(.smooth(duration: 0.28)) { m.showQueue.toggle() } } label: { Text(m.showQueue ? "Hide queue" : "Open queue").font(Typo.sans(11.5, .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Brand.inkSecondary)
            }
            if upcoming.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.line.last.and.arrowtriangle.forward").font(Typo.sans(22, .light)).foregroundStyle(Brand.inkTertiary)
                    Text(items.isEmpty ? "The queue is empty" : "Nothing after this song").font(Typo.callout.weight(.medium)).foregroundStyle(Brand.inkSecondary)
                    Text(m.repeatMode == .off ? "Add songs from your library, or turn on repeat." : "Repeat is on: the queue starts over.").font(Typo.caption).foregroundStyle(Brand.inkTertiary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 2) { ForEach(upcoming) { UpNextRow(item: $0) } }
                if items.count - (at + 1) > upcoming.count { Text("+ \(items.count - (at + 1) - upcoming.count) more").font(Typo.caption).foregroundStyle(Brand.inkTertiary).padding(.leading, 8) }
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
        HStack(spacing: 12) {
            ZStack {
                CoverView(image: item.thumb, palette: ArtPalette.fallback(seed: item.album.isEmpty ? item.title : item.album), corner: 5, symbol: "music.note")
                if hover.v { Color.black.opacity(0.5).clipShape(RoundedRectangle(cornerRadius: Metrics.radius(5), style: .continuous)); Image(systemName: "play.fill").font(Typo.sans(11, .medium)).foregroundStyle(Color.white) }
            }.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Typo.sans(12.5, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                Text([item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " — ")).font(Typo.sans(11)).foregroundStyle(Brand.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 3).contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: Metrics.radius(8), style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.1 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover.v = h } }
        .onTapGesture { m.play(item.id) }
        .onAppear { m.requestMetadata(item.id) }
    }
}

// MARK: - Visualiser


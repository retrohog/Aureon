import SwiftUI
import SlskCore

// The top bar's Downloads button: a round icon with a count badge, its own speed pill only while something moves, a panel under it (the style of the
// output panel), a menu on right-click, ⌥⌘T for the panel and ⌥⌘P to pause everything. Shown only when Soulseek is turned on in Settings.

struct DownloadsControl: View {
    @ObservedObject private var s = SoulseekModel.shared
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        if s.enabled {
            HStack(spacing: 8) {
                if s.snapshot.movingCount > 0 {
                    Text("↓ \(SlskFormat.speed(s.snapshot.downSpeed))").font(Typo.sans(12.5, .medium)).monospacedDigit().foregroundStyle(Brand.inkSecondary)
                        .padding(.horizontal, 12).frame(height: Metrics.pillHeight).background(Capsule().fill(Brand.panel2))
                        .transition(.opacity)
                }
                Button { withAnimation(Motion.glide) { s.togglePanel() } } label: {
                    Image(systemName: "arrow.down.circle")
                        .overlay(alignment: .topTrailing) {
                            if s.badge > 0 {
                                Text("\(s.badge)").font(Typo.sans(10, .bold)).foregroundStyle(Brand.onAccent).padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                                    .background(Capsule().fill(s.hasAttention ? Brand.caution : Brand.accent)).offset(x: 9, y: -8)
                            }
                        }
                }
                .buttonStyle(RoundIconStyle(on: s.panelOpen, size: 40)).help("Downloads (⌥⌘T)").accessibilityLabel("Downloads").accessibilityValue("\(s.badge) active")
                .layoutProbe("top.downloads")
                .windowPopover(isPresented: Binding(get: { s.panelOpen }, set: { s.panelOpen = $0 }), edge: .bottom) { DownloadsPanel().environmentObject(m) }
                .contextMenu {
                    Button("Pause all") { s.pauseAll(true) }
                    Button("Resume") { s.pauseAll(false) }
                    Button("Open Transfers") { s.openTransfers() }
                    Menu("Speed limit for uploads") {
                        ForEach([0, 256, 1024, 2048, 4096], id: \.self) { kb in Button(kb == 0 ? "No limit" : "\(kb) KB/s") { s.uploadLimitKB = kb } }
                    }
                }
                Button { s.pauseAll(!s.snapshot.protectionPause && s.snapshot.downloads.allSatisfy { $0.state != .waiting }) } label: { Color.clear }
                    .buttonStyle(.plain).keyboardShortcut("p", modifiers: [.option, .command]).frame(width: 0, height: 0).accessibilityHidden(true)
                Button { withAnimation(Motion.glide) { s.togglePanel() } } label: { Color.clear }
                    .buttonStyle(.plain).keyboardShortcut("t", modifiers: [.option, .command]).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            .animation(Motion.touch, value: s.snapshot.movingCount > 0)
        }
    }
}

struct DownloadsPanel: View {
    @ObservedObject private var s = SoulseekModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads").font(Typo.sans(14, .semibold))
                Spacer()
                Text("\(s.snapshot.downloads.filter { $0.state.isActive }.count) active").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
            }
            HStack(spacing: 6) {
                Button("Pause all") { s.pauseAll(true) }.buttonStyle(SlskPrimary())
                Button("Resume") { s.pauseAll(false) }.buttonStyle(SlskSoft())
                Button("Clear finished") { s.clearFinished() }.buttonStyle(SlskSoft())
            }
            if s.snapshot.downloads.isEmpty { Note(text: "No downloads. Choose files on the Soulseek page.") }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(s.snapshot.downloads.filter { $0.state != .finished }.prefix(30)) { TransferLine(t: $0) }
                }
            }.frame(maxHeight: 280)
            Button("Open Transfers") { s.openTransfers() }.buttonStyle(SlskPrimary())
        }
        .padding(16).frame(width: 340)
    }
}

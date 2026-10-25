import SwiftUI

// Settings → Mini player: which layout, how it is dressed, and the menu bar item. The preview is the real layout showing the song that is playing; it is
// part of this page, so it stops when the page is left.

struct MiniPlayerSettings: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) { layouts; look }.frame(maxWidth: .infinity)
                preview.frame(width: previewWidth)
            }
            menuBar
        }
    }

    private var previewWidth: CGFloat { 360 }

    // MARK: layouts

    private var layouts: some View {
        Card(title: "Mini player", subtitle: "Pick how it looks. Aureon remembers it") {
            VStack(spacing: 8) {
                ForEach(MiniLayout.allCases) { l in
                    let on = m.look.mini.layout == l
                    Button { withAnimation(Motion.touch) { m.look.mini.layout = l } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(l)).font(Typo.sans(16)).frame(width: 36, height: 36)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.ink.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.title).font(Typo.sans(14.5, on ? .medium : .regular))
                                Text(l.blurb).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
                            }
                            Spacer(minLength: 8)
                            if on { Image(systemName: "checkmark.circle.fill").font(Typo.sans(18)).foregroundStyle(Brand.accent) }
                        }
                        .padding(10).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Brand.accentText : Brand.rule, lineWidth: on ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(l.title).accessibilityHint(l.blurb).accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private func icon(_ l: MiniLayout) -> String {
        switch l { case .bar: "rectangle.bottomhalf.inset.filled"; case .strip: "minus"; case .card: "rectangle.portrait"; case .popover: "menubar.rectangle" }
    }

    private var look: some View {
        Card(title: "Look", subtitle: "The background, how strong it is, and what the window does") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Background").font(Typo.sans(13, .medium))
                SegmentedChoice(selection: $m.look.mini.background, items: MiniBackground.allCases, label: { $0.title }).frame(maxWidth: 420)
            }
            LookSliderRow(title: "Strength", hint: "How much of the cover's colour reaches the gradient, the blur and the glow.", value: $m.look.mini.strength, defaultValue: MiniSettings().strength)
            LookSliderRow(title: "Opacity", hint: "Of the whole window.", value: Binding(get: { (m.look.mini.opacity - 0.4) / 0.6 }, set: { m.look.mini.opacity = 0.4 + $0 * 0.6 }),
                          defaultValue: (MiniSettings().opacity - 0.4) / 0.6, format: { "\(Int((0.4 + $0 * 0.6) * 100))%" })
            row("Hide the Aureon window while it is open", "Like other players: the mini player takes over, and closing or expanding it brings the app back.", $m.look.mini.hideMainWindow)
            row("Always on top", "Keeps the window above the others.", $m.look.mini.alwaysOnTop)
            row("Format tags", "The codec, rate and quality beside the song.", $m.look.mini.formatTags)
            row("Show on every desktop", "The window follows you from one Space to the next.", $m.look.mini.onEveryDesktop)
            row("Remember its position", "It opens where you left it.", $m.look.mini.rememberPosition)
            HStack(spacing: 8) {
                Button { m.mini.toggle() } label: { Text(m.mini.isFloatingOpen || m.mini.isPopoverOpen ? "Close mini player" : "Open mini player") }.buttonStyle(.solid)
                Button("Reset") { withAnimation(Motion.glide) { m.look.mini = MiniSettings() } }.buttonStyle(.rule).disabled(m.look.mini == MiniSettings())
            }
        }
    }

    // MARK: preview

    private var preview: some View {
        let l = m.look.mini.layout, scale: CGFloat = l == .card ? 0.72 : (previewWidth - 40) / max(l.size.width, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Live preview").font(Typo.sans(15, .medium)); Spacer(); Text("playing now").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary) }
            MiniLayoutView(layout: l)
                .environment(\.miniActions, MiniActions())
                .scaleEffect(min(1, scale), anchor: .topLeading)
                .frame(width: l.size.width * min(1, scale), height: l.size.height * min(1, scale), alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .center)
            Text("The preview follows the song that is playing right now and stops updating the moment you leave this page.")
                .font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Brand.panel2))
    }

    // MARK: menu bar

    private var menuBar: some View {
        Card(title: "Menu bar player", subtitle: "A small bar always there, the popover on demand. The floating player stays when it closes") {
            row("Show in menu bar", "A small item with the logo and, if you like, the title.", $m.look.mini.menuBar.show)
            if m.look.mini.menuBar.show {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shows").font(Typo.sans(13, .medium))
                    SegmentedChoice(selection: $m.look.mini.menuBar.shows, items: MenuBarShows.allCases, label: { $0.title }).frame(maxWidth: 360)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Open the popover on").font(Typo.sans(13, .medium))
                    SegmentedChoice(selection: $m.look.mini.menuBar.openOn, items: MenuBarOpenOn.allCases, label: { $0.title }).frame(maxWidth: 240)
                }
                row("Close when clicking elsewhere", "A click anywhere else puts the popover away.", $m.look.mini.menuBar.closeOnOutsideClick)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Close automatically").font(Typo.sans(13, .medium))
                    SegmentedChoice(selection: $m.look.mini.menuBar.autoCloseSeconds, items: MenuBarSettings.autoCloseChoices, label: { MenuBarSettings.label($0) }).frame(maxWidth: 420)
                }
                row("Keep open while the pointer is over it", "The countdown waits until the pointer leaves.", $m.look.mini.menuBar.keepOpenWhileOver)
                row("Keep the floating player open when the popover closes", "Off: closing the popover closes the floating player too.", $m.look.mini.keepFloating)
            }
        }
    }

    private func row(_ title: String, _ hint: String, _ value: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(Typo.sans(14)); Text(hint).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary) }
            Spacer(minLength: 8)
            Toggle("", isOn: value).accessibilityLabel(title).fixedSize()
        }
    }
}

import SwiftUI

// Settings → Startup & memory, and the card that offers to continue.

struct StartupSettings: View {
    @EnvironmentObject var m: PlayerModel
    @State private var forgotten = false

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "When Aureon opens", subtitle: "What happens to playback") {
                SegmentedChoice(selection: $m.look.memory.resume, items: ResumeMode.allCases, label: { $0.title }).frame(maxWidth: 480)
                Text(m.look.memory.resume.blurb).font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary)
            }
            Card(title: "Remember", subtitle: "Kept on this Mac, and nowhere else") {
                row("The queue and the song", "The queue, the song that was playing and where it was.", $m.look.memory.rememberQueue)
                row("The page", "The page that was open, what was open on it and how far it was scrolled.", $m.look.memory.rememberPage)
                row("The window", "Its size and place, for each display you use.", $m.look.memory.rememberWindow)
                row("The output", "The device the sound went to, when it is connected again.", $m.look.memory.rememberOutput)
                Text("The volume is not remembered. It belongs to your device, and Aureon never sets it on its own.").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
                Text("Also remembered, in their own settings: the theme and the look, the Now Playing layout, the mini player and its place, the filters and sorting of the library.").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
            }
            Card(title: "Forget", subtitle: "Starts the next launch as the first one") {
                HStack(spacing: 12) {
                    Button("Forget what Aureon remembers") {
                        SessionRecord.forget(); WindowMemoryController.shared.forget(); ScrollMemory.shared.all = [:]
                        withAnimation(Motion.touch) { forgotten = true }
                    }.buttonStyle(.rule)
                    if forgotten { Text("Done. The theme and your settings are kept.").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).transition(.opacity) }
                }
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

/// "Continue where you left off?": shown when Aureon opens with Resume set to Ask me.
struct ResumeOfferCard: View {
    @EnvironmentObject var m: PlayerModel
    let offer: PendingResume

    var body: some View {
        HStack(spacing: 14) {
            CoverView(image: m.hero.image ?? m.focusItem?.thumb, palette: m.hero.palette, corner: 8, symbol: "music.note").frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Continue where you left off?").font(Typo.sans(14.5, .medium))
                Text([offer.title, offer.artist].filter { !$0.isEmpty }.joined(separator: " · ") + "  ·  " + clock(offer.position)).font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Start fresh") { withAnimation(Motion.glide) { m.declineResumeOffer() } }.buttonStyle(.rule)
            Button("Continue") { withAnimation(Motion.glide) { m.acceptResumeOffer() } }.buttonStyle(.solid)
        }
        .padding(14).frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.panel2))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .padding(.bottom, PlayerBar.reserved + 16)
        .accessibilityElement(children: .contain).accessibilityLabel("Continue where you left off?")
    }
}

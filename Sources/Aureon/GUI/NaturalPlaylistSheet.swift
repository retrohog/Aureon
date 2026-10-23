import SwiftUI

/// "Describe a Playlist": type what you want to hear, get a playlist built from your library.
struct NaturalPlaylistSheet: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var c: CollectionsModel
    @ObservedObject var ai: IntelligenceCenter
    @ObservedObject var service: NaturalPlaylistService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var text = Box("")
    @StateObject private var name = Box("")
    @StateObject private var savedName = Box<String?>(nil)

    static let examples = [
        "A 2-hour mix of late-night, low-energy acoustic tracks with high dynamic range",
        "45 minutes of upbeat 80s tracks for a run",
        "Rainy Sunday jazz, 20 songs",
        "An hour of calm instrumental music to focus",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !ai.isActive(.naturalPlaylists) { disabled }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        composer
                        status
                        if let plan = service.plan, !service.isBusy { result(plan) }
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560, idealHeight: 740)
        .onChange(of: service.plan) { _, p in name.v = p?.name ?? ""; savedName.v = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.plus").font(Typo.sans(15, .semibold)).foregroundStyle(Brand.accent)
            Text("Describe a Playlist").font(Typo.serif(17, .regular))
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(Typo.sans(16)).foregroundStyle(Brand.inkSecondary) }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var disabled: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain").font(Typo.sans(38, .ultraLight)).foregroundStyle(Brand.inkSecondary)
            Text(ai.isMasterOn ? "Natural-language playlists are off" : "Intelligence features are off").font(Typo.t3.weight(.semibold))
            Text(ai.hardware.isIntel && !ai.isMasterOn
                 ? "AI features are off by default on Intel Macs. You can switch them on in Intelligence, where the trade-offs are explained."
                 : "Turn on \(ai.isMasterOn ? "this feature" : "Intelligence features") in Intelligence to describe playlists in your own words.")
                .multilineTextAlignment(.center).foregroundStyle(Brand.inkSecondary).frame(maxWidth: 420).font(Typo.callout)
            RuleButton(title: "Open Intelligence", symbol: "brain", filled: true) { dismiss(); m.tab = .intelligence }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Describe what you want to hear…", text: $text.v, axis: .vertical)
                .textFieldStyle(.plain).font(Typo.sans(14)).lineLimit(2...4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Metrics.radius(10), style: .continuous).fill(Brand.ink.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radius(10), style: .continuous).strokeBorder(Brand.ink.opacity(0.1), lineWidth: 0.8))
                .onSubmit { go() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.examples, id: \.self) { e in
                        Button { text.v = e } label: {
                            Text(e).font(Typo.sans(11.5)).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Slab().fill(Brand.ink.opacity(0.08))).foregroundStyle(Brand.inkSecondary)
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 12) {
                RuleButton(title: service.isBusy ? "Building…" : "Build Playlist", symbol: "sparkles", filled: true) { go() }
                    .disabled(service.isBusy || text.v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                if service.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                if !service.engineDescription.isEmpty { Text(service.engineDescription).font(Typo.sans(11)).foregroundStyle(Brand.inkTertiary) }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch service.state {
        case .working(let msg): Text(msg).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
        case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").font(Typo.sans(12.5)).foregroundStyle(Brand.caution).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }

    private func result(_ plan: PlaylistPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.brief.summary).font(Typo.sans(13, .semibold))
                Text(plan.tracks.isEmpty ? "No songs matched."
                     : "\(plan.tracks.count) songs · \(PlaylistBrief.formatDuration(plan.seconds)) · built by \(plan.engine) in \(String(format: "%.1f", plan.elapsed)) s"
                       + (plan.modelPicked > 0 ? " · the model chose \(plan.modelPicked)" : ""))
                    .font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
            }
            ForEach(plan.notes, id: \.self) { Note(text: $0) }
            if !plan.tracks.isEmpty {
                HStack(spacing: 8) {
                    TextField("Playlist name", text: $name.v).textFieldStyle(.plain).ruleField().frame(maxWidth: 260)
                    RuleButton(title: savedName.v == nil ? "Save Playlist" : "Saved", symbol: savedName.v == nil ? "plus" : "checkmark", filled: savedName.v == nil) { save(plan) }
                        .disabled(savedName.v != nil)
                    RuleButton(title: "Play", symbol: "play.fill") { m.play(tracks: plan.tracks, at: 0); dismiss() }
                    RuleButton(title: "Add to Queue", symbol: "text.append") { m.library.onAdd?(plan.tracks, false) }
                    Spacer(minLength: 0)
                }
                SongList(tracks: plan.tracks, numbered: true)
            }
        }
    }

    private func go() {
        let request = text.v
        savedName.v = nil
        Task { await service.build(request) }
    }

    private func save(_ plan: PlaylistPlan) {
        if let p = service.save(plan, as: name.v, in: c) { savedName.v = p.name }
    }
}

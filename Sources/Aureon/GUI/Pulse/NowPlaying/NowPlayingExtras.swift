import SwiftUI

// Extra panels: small cards that fill the free room of Now Playing with facts the library really holds about the song. A card with nothing to say is not
// shown, at most two are shown at once, and all of it can be switched off (Settings → Now Playing, or the quick menu on the panel itself).

enum NPExtraKind: String, CaseIterable, Identifiable {
    case genre, plays, loudness, file, work
    var id: String { rawValue }
    var title: String {
        switch self { case .genre: "Genre"; case .plays: "Plays"; case .loudness: "Loudness"; case .file: "File"; case .work: "Work" }
    }
    var blurb: String {
        switch self {
        case .genre: "The genres tagged on the song"
        case .plays: "How often it was played and when last"
        case .loudness: "Integrated loudness, once the library has measured it"
        case .file: "Format, bit depth, sample rate and size on disk"
        case .work: "The work and catalogue number, for classical recordings"
        }
    }
}

struct NPExtraCard: Equatable, Identifiable {
    var kind: NPExtraKind
    var value: String
    var detail: String
    var id: String { kind.rawValue }
}

enum NPExtras {
    /// Most panels shown at once in any layout.
    static let limit = 2

    /// The cards the song can fill, in fixed order; kinds the library has no figures for are left out.
    static func cards(_ t: TrackDTO?, now: Date = Date()) -> [NPExtraCard] {
        guard let t else { return [] }
        var out: [NPExtraCard] = []
        let genres = t.genres.filter { !$0.isEmpty }
        if !genres.isEmpty { out.append(NPExtraCard(kind: .genre, value: genres.prefix(3).joined(separator: ", "), detail: t.year.map { "Released \($0)" } ?? "")) }
        if let n = t.playCount, n > 0 {
            var d = ""
            if let last = t.lastPlayedAt, last > 0 { d = "Last " + relative(Date(timeIntervalSince1970: last), now: now) }
            out.append(NPExtraCard(kind: .plays, value: n == 1 ? "Played once" : "Played \(n) times", detail: d))
        }
        if let l = t.lufs { out.append(NPExtraCard(kind: .loudness, value: String(format: "%.1f LUFS", l), detail: "Integrated")) }
        var f = [t.codec.uppercased()]
        if t.bitDepth > 0 { f.append("\(t.bitDepth)-bit") }
        if t.sampleRate > 0 { f.append("\(NPSignal.rate(t.sampleRate)) kHz") }
        if !t.codec.isEmpty { out.append(NPExtraCard(kind: .file, value: f.joined(separator: " · "), detail: t.fileSize.map { size($0) } ?? "")) }
        if let w = t.workTitle, !w.isEmpty { out.append(NPExtraCard(kind: .work, value: w, detail: t.catalog ?? "")) }
        return out
    }

    /// The cards to show: those the listener has not switched off, the first `limit`.
    static func visible(_ cards: [NPExtraCard], enabled: Set<NPExtraKind>, master: Bool) -> [NPExtraCard] {
        master ? Array(cards.filter { enabled.contains($0.kind) }.prefix(limit)) : []
    }

    static func size(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.1f MB", mb)
    }

    static func relative(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 3600 { return "just now" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        if s < 86_400 * 60 { return "\(Int(s / 86_400)) days ago" }
        return "\(Int(s / (86_400 * 30))) months ago"
    }
}

/// The listener's choices, kept in the user defaults.
@MainActor
final class NPExtraSettings: ObservableObject {
    static let shared = NPExtraSettings()
    private let defaults: UserDefaults
    @Published var master: Bool { didSet { defaults.set(master, forKey: "aureon.np.extras.on") } }
    @Published private(set) var disabled: Set<String> { didSet { defaults.set(Array(disabled).sorted(), forKey: "aureon.np.extras.off") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        master = defaults.object(forKey: "aureon.np.extras.on") as? Bool ?? true
        disabled = Set(defaults.stringArray(forKey: "aureon.np.extras.off") ?? [])
    }
    var enabled: Set<NPExtraKind> { Set(NPExtraKind.allCases.filter { !disabled.contains($0.rawValue) }) }
    func isOn(_ k: NPExtraKind) -> Bool { !disabled.contains(k.rawValue) }
    func set(_ k: NPExtraKind, _ on: Bool) { if on { disabled.remove(k.rawValue) } else { disabled.insert(k.rawValue) } }
}

/// The cards under the credits. Takes no room when there is none to spare, when it is switched off, or when the song has nothing to show.
struct NPExtraStack: View {
    @EnvironmentObject var info: NPTrackInfo
    @ObservedObject private var settings = NPExtraSettings.shared
    @Environment(\.npScale) private var s
    @State private var menu = false

    var body: some View {
        let cards = NPExtras.visible(NPExtras.cards(info.track), enabled: settings.enabled, master: settings.master)
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 8 * s) {
                HStack {
                    Text("More about this song").npFont(12.5).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                    Spacer(minLength: 0)
                    Button { menu.toggle() } label: { Image(systemName: "slider.horizontal.3").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary) }
                        .buttonStyle(.plain).accessibilityLabel("Choose panels")
                        .popover(isPresented: $menu, arrowEdge: .bottom) { NPExtraMenu().padding(14).frame(width: 280) }
                }
                ForEach(cards) { c in NPExtraCardView(card: c) { settings.set(c.kind, false) } }
            }
        }
    }
}

struct NPExtraCardView: View {
    let card: NPExtraCard
    let close: () -> Void
    @State private var hover = false
    @Environment(\.npScale) private var s

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.kind.title).npFont(12).foregroundStyle(Brand.inkSecondary)
                Text(card.value).npFont(14.5).lineLimit(2)
                if !card.detail.isEmpty { Text(card.detail).npFont(12.5).foregroundStyle(Brand.inkSecondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(Typo.sans(10, .medium)).foregroundStyle(Brand.inkSecondary) }
                .buttonStyle(.plain).opacity(hover ? 1 : 0).accessibilityLabel("Hide \(card.kind.title) panel")
        }
        .padding(.horizontal, 12 * s).padding(.vertical, 9 * s)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.ink.opacity(0.06)))
        .onHover { hover = $0 }
    }
}

/// The quick menu: the master switch and one switch per panel.
struct NPExtraMenu: View {
    @ObservedObject private var settings = NPExtraSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show extra panels", isOn: $settings.master).font(Typo.sans(13, .medium))
            Divider()
            ForEach(NPExtraKind.allCases) { k in
                Toggle(isOn: Binding(get: { settings.isOn(k) }, set: { settings.set(k, $0) })) {
                    VStack(alignment: .leading, spacing: 1) { Text(k.title).font(Typo.sans(13)); Text(k.blurb).font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary) }
                }.disabled(!settings.master)
            }
        }
    }
}

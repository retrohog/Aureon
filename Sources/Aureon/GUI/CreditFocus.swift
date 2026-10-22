import SwiftUI
import AppKit

// The credit graph in the interface. Click a name anywhere (the personnel list of an album, a collaborator below, an artist's "Credits" button)
// and the page shows every record in the library that person worked on, by capacity: as the artist, as a session musician with the
// instrument, as producer, as engineer, as writer, conductor or remixer, and the people they were credited alongside, each of them one click
// from the same page. The graph is read on a background queue (`LibraryModel.openPerson`); nothing here queries the library from a view.

struct PersonFocusPage: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var art: ArtistArt
    let graph: CreditGraphDTO
    @ObservedObject var lib: LibraryModel
    /// nil shows every capacity.
    @State private var category: CreditCategory?
    @State private var expanded: Set<String> = []

    private var visible: [CreditSectionDTO] { graph.sections.filter { category == nil || $0.category == category } }
    private var allTrackIDs: [String] {
        var seen = Set<String>(), out: [String] = []
        for s in graph.sections { for r in s.releases { for t in r.tracks where seen.insert(t.id).inserted { out.append(t.id) } } }
        return out
    }

    var body: some View {
        PageScaffold(title: "", back: { lib.closeFocus() }, backTitle: lib.canGoBackFocus ? "Back" : "Library") {
            VStack(alignment: .leading, spacing: 22) {
                header
                if graph.sections.count > 1 {
                    SegmentedChoice(selection: $category, items: [nil] + graph.sections.map { Optional($0.category) }, label: { $0?.title ?? "All" })
                }
                ForEach(visible) { section($0) }
                if graph.sections.isEmpty {
                    EmptyExplainer(icon: "person.text.rectangle", title: "No credits yet", text: "Nothing in the library credits this name. Credits come from the ARTIST, COMPOSER, CONDUCTOR, PERFORMER, PRODUCER, ENGINEER and similar tags; rescan the library after tagging.")
                }
                if !graph.collaborators.isEmpty { collaborators }
            }
        }
        .onAppear { art.load(id: graph.person.id, name: graph.person.name) }
    }

    private var header: some View {
        HStack(spacing: 22) {
            Avatar(name: graph.person.name, image: art.info[graph.person.id]?.image, size: 110, shadow: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("CREDITS").microLabel().foregroundStyle(Brand.cyan)
                Text(graph.person.name).font(.system(size: 30, weight: .bold)).tracking(-0.6).lineLimit(2)
                Text("\(graph.releaseCount) record\(graph.releaseCount == 1 ? "" : "s") · \(graph.trackCount) song\(graph.trackCount == 1 ? "" : "s")" + otherLine)
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    PillButton(title: "Play", symbol: "play.fill", filled: true) { lib.playCredited(trackIDs: allTrackIDs) }
                    PillButton(title: "Shuffle", symbol: "shuffle") { lib.playCredited(trackIDs: allTrackIDs, shuffle: true) }
                    PillButton(title: "Add to Queue", symbol: "text.badge.plus") { lib.playCredited(trackIDs: allTrackIDs, add: true) }
                }.padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }

    private var otherLine: String {
        let n = graph.otherRecords.count
        return n > 0 && !(graph.section(.primary)?.releases.isEmpty ?? true) ? " · \(n) by other artists" : ""
    }

    // MARK: sections

    private func section(_ s: CreditSectionDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: s.category.icon).foregroundStyle(Brand.accent)
                Text(s.category.title).font(.system(size: 17, weight: .semibold))
                Text("\(s.releases.count)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
            }
            LazyVStack(spacing: 1) { ForEach(s.releases) { releaseRow($0, in: s.category) } }
        }
    }

    private func releaseRow(_ r: CreditedReleaseDTO, in cat: CreditCategory) -> some View {
        let key = cat.rawValue + "|" + r.id, open = expanded.contains(key)
        let roles = r.roles.map(\.label).joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { if open { expanded.remove(key) } else { expanded.insert(key) } } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 14)
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title + (r.year.map { " (\($0))" } ?? "")).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(([r.artistNames.isEmpty ? nil : "by " + r.artistNames.joined(separator: ", "), roles.isEmpty ? nil : roles]).compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(r.tracks.count) song\(r.tracks.count == 1 ? "" : "s")").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary)
                Button { lib.playCredited(trackIDs: r.tracks.map(\.id)) } label: { Image(systemName: "play.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("Play the songs they are credited on")
                if r.isRelease {
                    Button { lib.clearFocus(); m.tab = .albums; lib.selectedID = r.id } label: { Image(systemName: "square.stack").font(.system(size: 11)) }
                        .buttonStyle(.plain).help("Open the album")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6).contentShape(Rectangle())
            .onTapGesture { if open { expanded.remove(key) } else { expanded.insert(key) } }
            if open {
                VStack(spacing: 0) {
                    ForEach(r.tracks) { t in
                        HStack(spacing: 8) {
                            Text(t.trackNumber.map(String.init) ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                            Text(t.title).font(.system(size: 12.5)).lineLimit(1)
                            Spacer()
                            Text(t.roles.map(\.label).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 4).contentShape(Rectangle()).onTapGesture { lib.playCredited(trackIDs: [t.id]) }
                    }
                }.padding(.leading, 34).padding(.trailing, 9).padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.ink.opacity(open ? 0.05 : 0)))
        .animation(.smooth(duration: 0.18), value: open)
    }

    // MARK: collaborators

    private var collaborators: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Worked with").font(.system(size: 17, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                ForEach(graph.collaborators) { c in
                    Button { lib.openPerson(c.partyID) } label: {
                        HStack(spacing: 9) {
                            Avatar(name: c.name, image: art.info[c.partyID]?.image, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text("\(c.sharedReleases) record\(c.sharedReleases == 1 ? "" : "s")" + (c.roles.isEmpty ? "" : " · " + c.roles.map(\.label).joined(separator: ", ")))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.ink.opacity(0.06)))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// The people credited on an album, other than its artists: each name opens that person's page.
struct AlbumPersonnel: View {
    @EnvironmentObject var m: PlayerModel
    let tracks: [TrackDTO]
    @State private var all = false

    struct Person: Identifiable, Hashable { var id: String; var name: String; var roles: [String]; var rank: Int }

    /// Pure, so it is tested: every credited person except the artists, with their roles, producers and engineers first.
    static func people(in tracks: [TrackDTO]) -> [Person] {
        var byID: [String: Person] = [:]
        for c in tracks.flatMap(\.credits) {
            guard let role = CreditRole(rawValue: c.role), role != .artist, role != .albumArtist else { continue }
            let label = CreditRoleDTO(role: c.role, instrument: c.instrument).label
            let rank = CreditCategory.allCases.firstIndex(of: CreditCategory(role: role)) ?? 99
            var p = byID[c.partyID] ?? Person(id: c.partyID, name: c.name, roles: [], rank: rank)
            if !p.roles.contains(label) { p.roles.append(label) }
            p.rank = min(p.rank, rank)
            byID[c.partyID] = p
        }
        return byID.values.sorted { ($0.rank, $0.name.lowercased()) < ($1.rank, $1.name.lowercased()) }
    }

    var body: some View {
        let people = Self.people(in: tracks)
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Credits").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("\(people.count) \(people.count == 1 ? "person" : "people")").microLabel().foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                    ForEach(all ? people : Array(people.prefix(24))) { p in
                        Button { m.library.openPerson(p.id) } label: {
                            HStack(spacing: 9) {
                                Avatar(name: p.name, image: nil, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(p.roles.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.ink.opacity(0.06)))
                        }.buttonStyle(.plain)
                    }
                }
                if people.count > 24 { Button(all ? "Show fewer" : "Show all \(people.count)") { all.toggle() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.cyan) }
            }
        }
    }
}

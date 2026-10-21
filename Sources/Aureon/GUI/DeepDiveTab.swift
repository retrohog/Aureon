import SwiftUI
import AppKit

struct DeepDiveTab: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View { DeepDiveContent(dd: m.deepDive, hasTrack: m.current != nil, title: m.current?.title ?? "", reload: { m.loadDeepDiveForCurrent(force: true) }) }
}

struct DeepDiveContent: View {
    @ObservedObject var dd: DeepDiveModel
    let hasTrack: Bool
    let title: String
    let reload: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch dd.state {
            case .idle:
                Card(title: "Deep Dive", subtitle: "Who played on this recording, the artists' stories, every release") {
                    Text(hasTrack ? "Press the button to identify “\(title)” and load its details." : "Play something to explore it here.").foregroundStyle(.secondary)
                    Button { reload() } label: { Label("Identify and load", systemImage: "magnifyingglass") }.disabled(!hasTrack)
                }
            case .loading(let stage):
                Card(title: "Deep Dive") { HStack { ProgressView().controlSize(.small); Text(stage).foregroundStyle(.secondary) } }
            case .failed(let msg):
                Card(title: "Deep Dive", subtitle: "Could not identify this recording") {
                    Text(msg).foregroundStyle(.orange)
                    Text("Files tagged by MusicBrainz Picard are identified straight from their tags. Untagged files need an AcoustID key and Chromaprint (see the Connect tab).").font(.caption).foregroundStyle(.secondary)
                    Button { reload() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                }
            case .loaded(let d): loaded(d)
            }
        }
    }

    @ViewBuilder private func loaded(_ d: DeepDive) -> some View {
        let r = d.recording
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                if let c = dd.cover { Image(nsImage: c).resizable().scaledToFill() }
                else { LinearGradient(colors: [.indigo.opacity(0.4), .purple.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "music.note").font(.system(size: 40)).foregroundStyle(.white.opacity(0.6)) }
            }.frame(width: 170, height: 170).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(r.title).font(.title.bold()).lineLimit(2)
                Text(r.artists.map(\.name).joined(separator: ", ")).font(.title3)
                HStack(spacing: 6) {
                    if let f = r.firstReleaseDate { Badge(text: "First released \(f)", color: .teal) }
                    if let l = r.lengthMs { Badge(text: String(format: "%d:%02d", l / 60000, l / 1000 % 60), color: .gray) }
                    ForEach(r.genres.prefix(3), id: \.self) { Badge(text: $0, color: .indigo) }
                }
                Text("Identified via \(d.identifiedBy)").font(.caption).foregroundStyle(.secondary)
                if let i = r.isrcs.first { Text("ISRC \(i)").font(.caption.monospaced()).foregroundStyle(.tertiary) }
                HStack {
                    Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Link("Open on MusicBrainz", destination: URL(string: "https://musicbrainz.org/recording/\(r.id)")!)
                }.font(.caption)
            }
            Spacer(minLength: 0)
        }

        if !r.works.isEmpty {
            Card(title: "Composition") {
                ForEach(r.works, id: \.id) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).fontWeight(.semibold)
                        if !w.composers.isEmpty { Text("Composed by " + w.composers.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        if !w.lyricists.isEmpty { Text("Lyrics by " + w.lyricists.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        creditCard("Musicians", d.credits(.performance), icon: "music.mic")
        creditCard("Production", d.credits(.production), icon: "slider.horizontal.3")

        ForEach(d.artists, id: \.artist.id) { p in artistCard(p) }

        if !r.releases.isEmpty {
            Card(title: "Appears on", subtitle: "\(r.releases.count) release\(r.releases.count == 1 ? "" : "s")") {
                ForEach(r.releases.prefix(12), id: \.id) { rel in
                    HStack {
                        Text(rel.title).lineLimit(1)
                        Spacer()
                        Text([rel.primaryType, rel.country, rel.date].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if r.releases.count > 12 { Text("and \(r.releases.count - 12) more").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        Text("Data from MusicBrainz (CC0), the Cover Art Archive and Wikipedia.").font(.caption2).foregroundStyle(.tertiary)
    }

    private func creditCard(_ title: String, _ credits: [MBCredit], icon: String) -> some View {
        Group {
            if !credits.isEmpty {
                Card(title: title) {
                    ForEach(credits, id: \.self) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                            Text(c.name).fontWeight(.medium)
                            Spacer()
                            Text((c.instruments + c.roles).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }

    private func artistCard(_ p: ArtistProfile) -> some View {
        let a = p.artist
        return Card(title: a.name, subtitle: [a.type, a.area ?? a.country, [a.begin, a.end].compactMap { $0 }.joined(separator: " – ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")) {
            if let bio = p.bio {
                if let d = bio.description { Text(d).font(.callout.weight(.medium)) }
                Text(bio.extract).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(WikiSummary.license + ".").font(.caption2).foregroundStyle(.tertiary)
                    if let u = URL(string: bio.pageURL) { Link("Read more", destination: u).font(.caption2) }
                }
            } else if let n = a.annotation { Text(n).font(.callout) }
            else { Text("No biography found.").font(.caption).foregroundStyle(.secondary) }
            if !a.genres.isEmpty { HStack(spacing: 6) { ForEach(a.genres.prefix(6), id: \.self) { Badge(text: $0, color: .gray) } } }
            if let h = a.homepage, let u = URL(string: h) { Link(h, destination: u).font(.caption) }
        }
    }
}

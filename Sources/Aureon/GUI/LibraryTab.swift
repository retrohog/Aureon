import SwiftUI
import AppKit

struct LibraryTab: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View { LibraryContent(lib: m.library) }
}

private func fmtDuration(_ s: Double) -> String { let t = Int(s.rounded()); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60) }

struct LibraryContent: View {
    @ObservedObject var lib: LibraryModel

    var body: some View {
        VStack(spacing: 14) {
            header
            if lib.stats.tracks == 0 && !lib.importing { empty } else { browser }
        }
    }

    private var header: some View {
        Card(title: "Library", subtitle: lib.stats.tracks == 0 ? "Point Aureon at your music: tags are read, audio is never modified" :
                "\(lib.stats.tracks) tracks · \(lib.stats.releases) albums · \(lib.stats.works) works · \(lib.stats.composers) composers") {
            HStack {
                Button { chooseFolder() } label: { Label("Add music folder…", systemImage: "folder.badge.plus") }
                Button { lib.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }.disabled(lib.folders.isEmpty || lib.importing)
                if lib.importing { ProgressView().controlSize(.small) }
                Text(lib.importProgress).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if !lib.folders.isEmpty {
                Text(lib.folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "  ·  ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Your library is empty").font(.headline)
            Text("Add a folder of FLAC, ALAC, WAV or AIFF files. Aureon understands multiple artists per track and classical tags: composer, conductor, ensemble, soloists, work, movement and opus.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
        }.padding(.vertical, 30)
    }

    private var browser: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("", selection: $lib.category) { ForEach(LibraryModel.Category.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                TextField("Filter", text: $lib.search).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            HStack(alignment: .top, spacing: 12) {
                list.frame(width: 260, height: 520)
                detail.frame(maxWidth: .infinity, minHeight: 520, alignment: .top)
            }
        }
    }

    private var list: some View {
        List(selection: $lib.selectedID) {
            ForEach(lib.rows) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).lineLimit(1)
                        if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Text("\(r.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }.tag(r.id)
            }
        }
        .listStyle(.inset)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay { if lib.rows.isEmpty { Text("Nothing here").foregroundStyle(.secondary) } }
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lib.canGoBack { Button { lib.goBack() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Color.accentColor) }
            switch lib.detail {
            case .none: Text("Choose an item on the left").foregroundStyle(.secondary).padding(.top, 8)
            case .works(let works): worksView(works)
            case .recordings(let w, let groups): recordingsView(w, groups)
            case .tracks(let title, let tracks): tracksView(title, tracks)
            case .releases: EmptyView()
            }
        }
    }

    private func worksView(_ works: [WorkDTO]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Works").font(.headline)
            ForEach(works) { w in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).fontWeight(.medium)
                        Text([w.catalog, w.key, "\(w.recordingCount) recording" + (w.recordingCount == 1 ? "" : "s")].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Recordings") { lib.open(work: w) }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    private func recordingsView(_ w: WorkDTO, _ groups: [RecordingGroupDTO]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(w.title).font(.title3.bold())
                Text([w.composerName, w.catalog, w.key].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
            }
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.releaseTitle + (g.year.map { " (\($0))" } ?? "")).fontWeight(.semibold)
                            performerLines(g)
                        }
                        Spacer()
                        Button { lib.onAdd?(g.tracks, true) } label: { Label("Play", systemImage: "play.fill") }
                        Button { lib.onAdd?(g.tracks, false) } label: { Image(systemName: "text.badge.plus") }.help("Add to queue")
                    }
                    ForEach(g.tracks) { t in
                        HStack(spacing: 8) {
                            Text(t.movementNumber.map { roman($0) } ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                            Text(t.movementTitle ?? t.title).lineLimit(1)
                            Spacer()
                            Text(fmtDuration(t.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle()).onTapGesture(count: 2) { lib.onAdd?([t], true) }
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    @ViewBuilder private func performerLines(_ g: RecordingGroupDTO) -> some View {
        let cond = g.performers.filter { $0.role == "conductor" }.map(\.name), ens = g.performers.filter { $0.role == "ensemble" }.map(\.name)
        let solo = g.performers.filter { $0.role == "soloist" || $0.role == "performer" }.map { c in c.instrument.map { i in "\(c.name) (\(i))" } ?? c.name }
        if !cond.isEmpty { Text("Conductor: " + cond.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
        if !ens.isEmpty { Text("Ensemble: " + ens.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
        if !solo.isEmpty { Text("Soloists: " + solo.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
    }

    private func tracksView(_ title: String, _ tracks: [TrackDTO]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(title) · \(tracks.count)").font(.headline)
                Spacer()
                Button { lib.onAdd?(tracks, true) } label: { Label("Play all", systemImage: "play.fill") }
                Button { lib.onAdd?(tracks, false) } label: { Label("Add", systemImage: "text.badge.plus") }
            }
            ForEach(tracks) { t in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).lineLimit(1)
                        Text([t.artistLine, t.releaseTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(t.codec) \(t.bitDepth == 1 ? "DSD" : "\(t.bitDepth)/\(Int(t.sampleRate / 1000))")").font(.caption2).foregroundStyle(.tertiary)
                    Text(fmtDuration(t.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle()).onTapGesture(count: 2) { lib.onAdd?([t], true) }
            }
        }
    }

    private func roman(_ n: Int) -> String {
        let t = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var x = n, out = ""
        for (v, s) in t { while x >= v { out += s; x -= v } }
        return n > 0 && n < 40 ? out + "." : "\(n)"
    }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = "Choose the folder(s) that contain your music"
        if p.runModal() == .OK { p.urls.forEach { lib.addFolder($0) } }
    }
}

import SwiftUI

/// Where the browser's list comes from.
enum ProSource: Hashable {
    case all, recent, history, playlist(String)
}

enum ProSort: String, CaseIterable {
    case title = "TITLE", artist = "ARTIST", bpm = "BPM", key = "KEY", energy = "ENERGY", time = "TIME", played = "PLAYED"
}

/// The browser's sorting and filtering, done off the main thread so a library of tens of thousands of tracks never holds up the console.
@MainActor
final class ProBrowserModel: ObservableObject {
    @Published var source = ProSource.all { didSet { schedule() } }
    @Published var sort = ProSort.title { didSet { schedule() } }
    @Published var ascending = true { didSet { schedule() } }
    @Published var tempoMatch = false { didSet { schedule() } }
    @Published var keyMatch = false { didSet { schedule() } }
    @Published private(set) var rows: [TrackDTO] = []
    @Published var selected: TrackDTO?
    private var task: Task<Void, Never>?
    private var lastInputs = ""

    struct Reference { var bpm: Double?; var key: MusicalKey? }
    var reference = Reference()
    var songs: [TrackDTO] = []
    var info: [String: DJTrackAnalysis] = [:]
    var history: [String: Double] = [:]
    var playlistTracks: [String: [TrackDTO]] = [:]

    func toggleSort(_ s: ProSort) { if sort == s { ascending.toggle() } else { sort = s; ascending = s == .title || s == .artist || s == .key } }

    /// Recomputes when anything it depends on changed (cheap check first).
    func update(songs: [TrackDTO], info: [String: DJTrackAnalysis], history: [String: Double], reference: Reference) {
        let stamp = "\(songs.count)|\(songs.first?.id ?? "")|\(songs.last?.id ?? "")|\(info.count)|\(history.count)|\(reference.bpm ?? 0)|\(reference.key?.camelot ?? "")"
        guard stamp != lastInputs else { return }
        lastInputs = stamp
        self.songs = songs; self.info = info; self.history = history; self.reference = reference
        schedule()
    }

    func schedule() {
        task?.cancel()
        let src = source, sort = sort, asc = ascending, tempo = tempoMatch, keyOnly = keyMatch
        let songs = songs, info = info, history = history, ref = reference, lists = playlistTracks
        task = Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) { ProBrowserModel.compute(source: src, sort: sort, ascending: asc, tempoMatch: tempo, keyMatch: keyOnly, songs: songs, info: info, history: history, ref: ref, lists: lists) }.value
            guard !Task.isCancelled, let self else { return }
            self.rows = out
        }
    }

    func loadPlaylist(_ id: String, store: LibraryStore?) {
        guard let store else { return }
        Task { [weak self] in
            let t = await Task.detached(priority: .userInitiated) { store.playlistTracks(id: id) }.value
            guard let self else { return }
            self.playlistTracks[id] = t; self.schedule()
        }
    }

    nonisolated static func compute(source: ProSource, sort: ProSort, ascending: Bool, tempoMatch: Bool, keyMatch: Bool, songs: [TrackDTO], info: [String: DJTrackAnalysis], history: [String: Double],
                                    ref: Reference, lists: [String: [TrackDTO]]) -> [TrackDTO] {
        var base: [TrackDTO]
        switch source {
        case .all: base = songs
        case .recent: base = Array(songs.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(300))
        case .history:
            let byPath = Dictionary(songs.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            base = history.sorted { $0.value > $1.value }.compactMap { byPath[$0.key] }
        case .playlist(let id): base = lists[id] ?? []
        }
        if tempoMatch, let rb = ref.bpm, rb > 0 { base = base.filter { t in info[t.path]?.bpm.map { abs($0 / rb - 1) <= 0.06 } ?? false } }
        if keyMatch, let rk = ref.key { base = base.filter { t in info[t.path]?.key.map { $0.compatible(with: rk) } ?? false } }
        func cmp<T: Comparable>(_ a: T?, _ b: T?) -> Bool? { guard let a, let b else { return a == nil && b != nil ? false : (a != nil && b == nil ? true : nil) }; return a == b ? nil : (ascending ? a < b : a > b) }
        let lower = { (s: String) in s.lowercased() }
        if !(source == .recent && sort == .title) && !(source == .history && sort == .title) {
            base.sort { a, b in
                switch sort {
                case .title: return cmp(lower(a.title), lower(b.title)) ?? false
                case .artist: return cmp(lower(a.artistLine), lower(b.artistLine)) ?? (lower(a.title) < lower(b.title))
                case .bpm: return cmp(info[a.path]?.bpm, info[b.path]?.bpm) ?? (lower(a.title) < lower(b.title))
                case .key: return cmp(info[a.path]?.key.map { $0.camelotNumber * 2 + ($0.minor ? 0 : 1) }, info[b.path]?.key.map { $0.camelotNumber * 2 + ($0.minor ? 0 : 1) }) ?? (lower(a.title) < lower(b.title))
                case .energy: return cmp(info[a.path]?.energy, info[b.path]?.energy) ?? (lower(a.title) < lower(b.title))
                case .time: return cmp(a.duration, b.duration) ?? false
                case .played: return cmp(history[a.path], history[b.path]) ?? (lower(a.title) < lower(b.title))
                }
            }
        }
        return base
    }
}

/// The track browser: sources on the left, a sortable table with tempo, key and energy in the middle, details and suggestions on the right.
struct ProLibrary: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var dj: DJModel
    @ObservedObject private var lib: LibraryModel
    @StateObject private var browser = ProBrowserModel()
    @ObservedObject private var collections: CollectionsModel

    init() { _lib = ObservedObject(wrappedValue: LibraryModelBridge.shared.model!); _collections = ObservedObject(wrappedValue: LibraryModelBridge.shared.collections!) }

    private var onAir: DJDeck? { dj.decks.first { $0.playing } ?? dj.masterDeck ?? (dj.a.isLoaded ? dj.a : dj.b.isLoaded ? dj.b : nil) }
    private var reference: ProBrowserModel.Reference { ProBrowserModel.Reference(bpm: onAir?.effectiveBPM, key: onAir?.key) }

    var body: some View {
        let songs = lib.orderedSongs(ViewOptions.defaults(for: .songs))
        HStack(spacing: 0) {
            tree.frame(width: DJProMetrics.treeWidth)
            Rectangle().fill(PC.line).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                header
                list
                status
            }
            Rectangle().fill(PC.line).frame(width: 1)
            side.frame(width: DJProMetrics.sideWidth)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(PC.s1))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PC.line, lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { browser.update(songs: songs, info: dj.info, history: dj.history, reference: reference) }
        .onChangeCompat(of: songs.count) { browser.update(songs: songs, info: dj.info, history: dj.history, reference: reference) }
        .onChangeCompat(of: dj.info.count) { browser.update(songs: songs, info: dj.info, history: dj.history, reference: reference) }
        .onChangeCompat(of: dj.history.count) { browser.update(songs: songs, info: dj.info, history: dj.history, reference: reference) }
        .onChangeCompat(of: onAir?.name) { browser.update(songs: songs, info: dj.info, history: dj.history, reference: reference) }
        .onChangeCompat(of: onAir?.track?.path) { browser.update(songs: songs, info: dj.info, history: dj.history, reference: reference) }
    }

    // MARK: sources

    private var tree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PCLabel("LIBRARY").padding(.leading, 8).padding(.bottom, 2)
                sourceRow("All tracks", .all, count: lib.stats.tracks)
                sourceRow("Recently added", .recent, count: nil)
                sourceRow("History", .history, count: dj.history.count)
                if !collections.playlists.isEmpty {
                    PCLabel("PLAYLISTS").padding(.leading, 8).padding(.top, 10)
                    ForEach(collections.playlists) { p in sourceRow(p.name, .playlist(p.id), count: p.trackCount) }
                }
            }.padding(8)
        }
    }

    private func sourceRow(_ title: String, _ s: ProSource, count: Int?) -> some View {
        Button {
            browser.source = s
            if case .playlist(let id) = s { browser.loadPlaylist(id, store: lib.store) }
        } label: {
            HStack {
                Text(title).font(PC.sans(12.5)).lineLimit(1)
                Spacer(minLength: 4)
                if let count { Text("\(count)").font(PC.mono(10.5, .medium)).foregroundColor(PC.ink3) }
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(browser.source == s ? PC.s3 : Color.clear))
            .foregroundColor(browser.source == s ? PC.ink : PC.ink2).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: table

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(PC.sans(11)).foregroundColor(PC.ink3)
                TextField("Search title, artist…", text: $lib.search).textFieldStyle(.plain).font(PC.sans(12.5)).foregroundColor(PC.ink)
            }
            .padding(.horizontal, 10).frame(height: 28).background(RoundedRectangle(cornerRadius: 7).fill(PC.s2))
            PCKey(title: "BPM ±6%", on: browser.tempoMatch, width: 78, height: 26, enabled: reference.bpm != nil, help: "Only tracks within 6 % of the tempo on air") { browser.tempoMatch.toggle() }
            PCKey(title: "KEY MATCH", on: browser.keyMatch, width: 88, height: 26, enabled: reference.key != nil, help: "Only tracks that mix with the key on air") { browser.keyMatch.toggle() }
            if let p = dj.analysisProgress { ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 70).controlSize(.small) }
            PCKey(title: dj.analysisProgress == nil ? "ANALYSE ALL" : "STOP", on: dj.analysisProgress != nil, color: PC.warn, width: 96, height: 26, help: "Detect tempo and key for every song so they show here") { dj.analyzeLibrary(browser.songs.map { $0.path }) }
        }.padding(8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 4)
            head(.title).frame(maxWidth: .infinity, alignment: .leading)
            head(.artist).frame(maxWidth: .infinity, alignment: .leading)
            head(.bpm).frame(width: 52, alignment: .trailing)
            head(.key).frame(width: 40)
            head(.energy).frame(width: 56)
            head(.time).frame(width: 46, alignment: .trailing)
            head(.played).frame(width: 84, alignment: .leading)
            PCLabel("LOAD").frame(width: 62)
        }
        .padding(.horizontal, 8).frame(height: 24).background(PC.s1)
        .overlay(alignment: .bottom) { Rectangle().fill(PC.line).frame(height: 1) }
    }

    private func head(_ s: ProSort) -> some View {
        Button { browser.toggleSort(s) } label: {
            HStack(spacing: 3) {
                Text(s.rawValue).font(PC.mono(9.5)).tracking(1).foregroundColor(browser.sort == s ? PC.ink : PC.ink3)
                if browser.sort == s { Image(systemName: browser.ascending ? "chevron.up" : "chevron.down").font(Typo.sans(7, .bold)).foregroundColor(PC.gold) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help("Sort by \(s.rawValue.lowercased())")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(browser.rows) { t in
                    ProTrackRow(track: t, reference: reference, selected: browser.selected?.id == t.id) { browser.selected = t }
                }
                if browser.rows.isEmpty {
                    Text(lib.stats.tracks == 0 ? "Add a music folder in Settings or from Library to see your tracks here." : browser.tempoMatch || browser.keyMatch ? "Nothing matches the tempo or key on air. Analyse the library to fill in tempo and key." : "No songs match.")
                        .font(PC.sans(12)).foregroundColor(PC.ink2).padding(.top, 24)
                }
            }
        }
    }

    private var status: some View {
        HStack(spacing: 14) {
            Text("\(lib.stats.tracks) tracks").font(PC.mono(10.5, .medium)).foregroundColor(PC.ink3)
            Text("\(browser.rows.count) shown").font(PC.mono(10.5, .medium)).foregroundColor(PC.ink3)
            Spacer()
            if let d = onAir { Text("Green = mixes with deck \(d.name)").font(PC.mono(10.5, .medium)).foregroundColor(PC.ink3) }
        }
        .padding(.horizontal, 12).frame(height: 24).overlay(alignment: .top) { Rectangle().fill(PC.line).frame(height: 1) }
    }

    // MARK: side panel

    private var side: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                PCLabel("TRACK INFO")
                if let t = browser.selected {
                    let a = dj.info[t.path]
                    card(t.title, [t.artistLine, [a?.bpm.map { String(format: "%.1f BPM", $0) }, a?.key?.camelot].compactMap { $0 }.joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: "\n"))
                    PCLabel("CUE POINTS")
                    let cues = HotCueStore.load(path: t.path).compactMap { $0 }
                    card(cues.isEmpty ? "None stored" : "\(cues.count) stored", cues.isEmpty ? "Set cues on a deck and they are kept." : cues.map { clock($0) }.joined(separator: " · "))
                } else {
                    card("Select a track", "Click a row to see its details.")
                }
                if let d = onAir {
                    PCLabel("MIXES WELL WITH DECK \(d.name)")
                    let picks = suggestions(for: d)
                    if picks.isEmpty { card("Nothing yet", "Analyse the library to find tracks that suit this one.") }
                    ForEach(picks, id: \.0.id) { t, note in
                        Button { browser.selected = t } label: { card(t.title, note) }.buttonStyle(.plain)
                    }
                }
            }.padding(10)
        }
    }

    private func card(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(PC.sans(12.5, .semibold)).foregroundColor(PC.ink).lineLimit(1)
            Text(detail).font(PC.sans(11.5)).foregroundColor(PC.ink2).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(RoundedRectangle(cornerRadius: 8).fill(PC.s2))
    }

    /// The analysed tracks closest in key and tempo to the deck on air.
    private func suggestions(for d: DJDeck) -> [(TrackDTO, String)] {
        guard let bpm = d.effectiveBPM, let key = d.key else { return [] }
        var scored: [(TrackDTO, Double, String)] = []
        for t in browser.songs where t.path != d.track?.path {
            guard let a = dj.info[t.path], let tb = a.bpm, let tk = a.key, tk.compatible(with: key) else { continue }
            let pct = (bpm / tb - 1) * 100
            guard abs(pct) <= 6 else { continue }
            let steps = tk.distance(to: key)
            scored.append((t, abs(pct) + Double(steps) * 2, String(format: "%+.1f%% tempo · ", pct) + (steps == 0 ? "same key" : "1 key step")))
            if scored.count > 400 { break }
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(3).map { ($0.0, $0.2) }
    }
}

struct ProTrackRow: View {
    @EnvironmentObject var dj: DJModel
    let track: TrackDTO
    let reference: ProBrowserModel.Reference
    let selected: Bool
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        let a = dj.info[track.path]
        let keyOK = a?.key != nil && reference.key != nil && a!.key!.compatible(with: reference.key!)
        let tempoOK = a?.bpm != nil && reference.bpm != nil && abs(a!.bpm! / reference.bpm! - 1) < 0.06
        let onA = dj.a.track?.path == track.path, onB = dj.b.track?.path == track.path
        HStack(spacing: 8) {
            Rectangle().fill(onA ? PC.a : onB ? PC.b : Color.clear).frame(width: 3, height: 16).clipShape(Capsule())
            Text(track.title).font(PC.sans(12.5, .medium)).foregroundColor(PC.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(track.artistLine).font(PC.sans(12)).foregroundColor(PC.ink2).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(a?.bpm.map { String(format: "%.1f", $0) } ?? "—").font(PC.mono(11.5, tempoOK ? .bold : .regular)).foregroundColor(tempoOK ? PC.ok : PC.ink2).frame(width: 52, alignment: .trailing)
            Text(a?.key?.camelot ?? "—").font(PC.mono(11.5, keyOK ? .bold : .regular)).foregroundColor(keyOK ? PC.ok : PC.ink3).frame(width: 40)
            HStack(spacing: 2) { ForEach(0..<5, id: \.self) { i in RoundedRectangle(cornerRadius: 1).fill(a.map { Double(i) < $0.energy * 5 - 0.001 ? PC.gold : PC.s3 } ?? PC.s2).frame(width: 6, height: 10) } }.frame(width: 56)
            Text(clock(track.duration)).font(PC.mono(11.5, .regular)).foregroundColor(PC.ink2).frame(width: 46, alignment: .trailing)
            Text(played).font(PC.mono(10.5, .medium)).foregroundColor(onA || onB ? PC.ink : PC.ink3).lineLimit(1).frame(width: 84, alignment: .leading)
            HStack(spacing: 4) {
                load("A", PC.a, dj.a); load("B", PC.b, dj.b)
            }.frame(width: 62)
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Rectangle().fill(selected ? PC.s3 : (onA || onB) ? PC.s2 : hover ? PC.s2.opacity(0.6) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onAppear { dj.requestInfo(track.path) }
        .onTapGesture(count: 2) { dj.loadIntoFreeDeck(dj.track(track)) }
        .onTapGesture { select() }
    }

    private var played: String {
        if dj.a.track?.path == track.path { return "Now · A" }
        if dj.b.track?.path == track.path { return "Now · B" }
        guard let t = dj.history[track.path] else { return "—" }
        let s = Date().timeIntervalSince1970 - t
        if s < 3600 { return "\(max(1, Int(s / 60))) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        if s < 86_400 * 14 { return "\(Int(s / 86_400)) days ago" }
        return "\(Int(s / 604_800)) weeks ago"
    }

    private func load(_ title: String, _ color: Color, _ deck: DJDeck) -> some View {
        Button { dj.load(dj.track(track), into: deck) } label: {
            Text(title + " ▸").font(PC.mono(10)).foregroundColor(Color.black.opacity(0.85)).frame(width: 28, height: 20).background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(hover ? 1 : 0.75)))
        }.buttonStyle(.plain).help("Load on deck \(title)")
    }
}

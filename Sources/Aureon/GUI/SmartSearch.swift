import SwiftUI
import AppKit

/// Runs library queries (see `LibraryQuery`) in the background and keeps the genre tree.
@MainActor
final class SmartQueryModel: ObservableObject {
    static let shared = SmartQueryModel()

    @Published private(set) var results: [TrackDTO] = []
    @Published private(set) var total = 0
    @Published private(set) var error: QueryError?
    @Published private(set) var parsed: LibraryQuery?
    @Published private(set) var running = false
    @Published private(set) var tree: [TagTreeNode] = []
    @Published private(set) var treeLoading = false
    static let limit = 5000

    private var generation = 0
    private var pending: DispatchWorkItem?
    private var treeRevision: Int64 = -1

    func run(_ text: String, store: LibraryStore?) {
        pending?.cancel()
        let t = text.trimmingCharacters(in: .whitespaces)
        guard LibraryQuery.looksAdvanced(t) else { error = nil; parsed = nil; results = []; total = 0; running = false; return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.execute(t, store: store) } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)          // typing does not start a query per key
    }

    private func execute(_ text: String, store: LibraryStore?) {
        generation += 1
        let gen = generation
        do {
            let q = try LibraryQuery(parsing: text)
            error = nil; parsed = q
            guard let store else { return }
            running = true
            Task.detached(priority: .userInitiated) {
                let rows = store.tracks(matching: q, limit: SmartQueryModel.limit)
                let n = rows.count < SmartQueryModel.limit ? rows.count : store.count(matching: q)
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.results = rows; self.total = n; self.running = false
                }
            }
        } catch let e as QueryError {
            error = e; running = false
        } catch {
            self.error = QueryError(message: "\(error)", position: 0); running = false
        }
    }

    /// Test and snapshot seam: sets the genre tree directly.
    func preload(tree t: [TagTreeNode]) { tree = t; treeLoading = false }

    func loadTree(store: LibraryStore?, force: Bool = false) {
        guard let store, !treeLoading else { return }
        let rev = store.revision
        guard force || rev != treeRevision else { return }
        treeLoading = true
        Task.detached(priority: .utility) {
            let t = TagTreeNode.build(store.genreCounts())
            await MainActor.run {
                self.tree = t; self.treeLoading = false; self.treeRevision = rev
                if store.revision != rev { self.loadTree(store: store) }          // the library changed while the tree was being read
            }
        }
    }
}

// MARK: - Search page with the query language and the tag tree

/// The search page: plain words use the quick search, anything with fields or operators runs the query language. The genre tree on
/// the left turns a click into a `tag:` query.
struct SmartSearchPage: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var q = SmartQueryModel.shared

    var body: some View {
        Group {
            if m.searchText.trimmingCharacters(in: .whitespaces).isEmpty { SearchEmptyState(s: m.search, lib: m.library) }
            else if LibraryQuery.looksAdvanced(m.searchText) { QueryResultsPage() }
            else { SearchResultsPage(s: m.search, lib: m.library) }
        }
        .onAppear { q.loadTree(store: m.library.store); q.run(m.searchText, store: m.library.store) }
        .onChangeCompat(of: m.searchText) { _, t in q.run(t, store: m.library.store) }
    }
}

struct QueryResultsPage: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var q = SmartQueryModel.shared

    var body: some View {
        PageScaffold(title: q.parsed?.root.singleTagName ?? "Search", subtitle: subtitle, trailing: {
            if !q.results.isEmpty {
                RuleButton(title: "Play", symbol: "play.fill", filled: true) { m.library.onReplace?(q.results) }
                RuleButton(title: "Add to Queue", symbol: "text.badge.plus") { m.library.onAdd?(q.results, false) }
                RuleButton(title: "Edit Tags", symbol: "tag") { TagEditorWindow.open(paths: q.results.map(\.path).filter { !RemoteMedia.isRemote($0) }, model: m) }
            }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                if let e = q.error {
                    QueryErrorView(text: m.searchText, error: e)
                } else if let p = q.parsed {
                    QueryChips(node: p.root, onRemove: { i in withAnimation(Motion.touch) { m.searchText = p.root.text(removing: i) } }).padding(.bottom, 2)
                }
                if q.running && q.results.isEmpty { ProgressView().padding(.top, 24) }
                else if q.error == nil && q.results.isEmpty && q.parsed != nil && !q.running { Text("No songs match").foregroundStyle(Brand.inkSecondary).padding(.top, 12) }
                if !q.results.isEmpty {
                    if q.total > q.results.count { Note(text: "Showing the first \(q.results.count) of \(q.total) songs. Narrow the query to see the rest.") }
                    SongList(tracks: q.results, showArtist: true, sortHeader: false)
                }
            }
        }
    }

    private var subtitle: String? {
        if q.error != nil { return "query error" }
        if q.running { return "searching…" }
        return q.parsed == nil ? nil : "\(q.total) song\(q.total == 1 ? "" : "s")"
    }
}

/// Shows where a query went wrong, with a caret under the spot.
struct QueryErrorView: View {
    let text: String
    let error: QueryError
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.message, systemImage: "exclamationmark.triangle.fill").font(Typo.sans(13, .semibold)).foregroundStyle(Brand.caution)
            VStack(alignment: .leading, spacing: 0) {
                Text(text).font(Typo.mono(12.5))
                Text(String(repeating: " ", count: max(0, min(error.position, text.count))) + "^").font(Typo.mono(12.5)).foregroundStyle(Brand.caution)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.radius(8), style: .continuous).fill(Brand.ink.opacity(0.06)))
        }
    }
}

/// The parsed query drawn as chips, so it is clear how it was understood ("NOT" binds to the next term; AND binds tighter than OR).
struct QueryChips: View {
    let node: QueryNode
    /// Called with the index of the chip to take out (see `QueryNode.removableParts`); nil shows plain chips.
    var onRemove: ((Int) -> Void)?
    var body: some View {
        if let onRemove {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(node.removableParts.enumerated()), id: \.offset) { i, p in
                        if i > 0 { op("AND") }
                        HStack(spacing: 2) {
                            chips(p)
                            Button { onRemove(i) } label: { Image(systemName: "xmark.circle.fill").font(Typo.sans(12)) }
                                .buttonStyle(.plain).foregroundStyle(Brand.inkSecondary).help("Remove this filter").accessibilityLabel("Remove filter")
                        }
                    }
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 4) { chips(node, top: true) } }
        }
    }

    private func label(_ t: QueryTerm) -> String {
        let field = t.field == .any ? "Anywhere" : t.field.rawValue.prefix(1).uppercased() + t.field.rawValue.dropFirst()
        switch t.value {
        case .text(let v, let exact, let pattern): return "\(field) \(pattern ? "matches" : (exact ? "is" : "contains")) “\(v)”"
        case .flag(let b): return "\(field): \(b ? "yes" : "no")"
        case .range(let lo, let hi):
            func f(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }
            switch (lo, hi) {
            case let (a?, b?) where a == b: return "\(field) = \(f(a))"
            case let (a?, b?): return "\(field) \(f(a))–\(f(b))"
            case let (a?, nil): return "\(field) ≥ \(f(a))"
            case let (nil, b?): return "\(field) ≤ \(f(b))"
            default: return field
            }
        }
    }

    private func chip(_ s: String, negative: Bool = false) -> some View {
        Text(s).font(Typo.sans(11.5, .medium)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Slab().fill((negative ? Brand.caution : Brand.accent).opacity(0.16)))
            .overlay(Slab().strokeBorder((negative ? Brand.caution : Brand.accent).opacity(0.35), lineWidth: 0.7))
    }

    private func op(_ s: String) -> some View { Text(s).font(Typo.mono(10, .bold)).foregroundStyle(Brand.inkSecondary) }

    private func chips(_ n: QueryNode, top: Bool = false) -> AnyView {
        switch n {
        case .term(let t): return AnyView(chip(label(t)))
        case .not(.term(let t)): return AnyView(chip("not " + label(t), negative: true))
        case .not(let x): return AnyView(HStack(spacing: 4) { op("NOT ("); chips(x); op(")") })
        case .and(let parts):
            return AnyView(HStack(spacing: 4) { ForEach(Array(parts.enumerated()), id: \.offset) { i, p in if i > 0 { op("AND") }; chips(p) } })
        case .or(let parts):
            return AnyView(HStack(spacing: 4) {
                if !top { op("(") }
                ForEach(Array(parts.enumerated()), id: \.offset) { i, p in if i > 0 { op("OR") }; chips(p) }
                if !top { op(")") }
            })
        }
    }
}

/// A short reference of the query language with examples that can be clicked.
struct QueryHelp: View {
    let insert: (String) -> Void
    private let examples = [
        "Genre: Jazz AND Year: 1955..1965 NOT Artist: \"Miles Davis\"",
        "composer:beethoven tag:Classical/Symphonies",
        "(artist:coltrane OR artist:dolphy) year:<1965",
        "rate:>=96k bits:24 -live",
        "liked:yes plays:0",
        "lufs:-20..-12 dr:>=12",
    ]
    var body: some View {
        Card(title: "Query language", subtitle: "Fields with a colon, AND / OR / NOT in capitals, brackets, \"exact text\", ranges with .. and comparisons") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.self) { e in
                    Button { insert(e) } label: { Text(e).font(Typo.mono(12)).foregroundStyle(Brand.accent).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                }
            }
            Note(text: "Fields: title, artist, albumartist, album, composer, conductor, ensemble, performer, person, genre, tag (hierarchical: Classical/Beethoven covers everything under it), year, work, catalog, format, rate, bits, channels, liked, hires, plays, lufs, dr, duration, path. Text matches ignore case and accents; * and ? are wildcards; a word with a minus in front is left out.")
        }
    }
}

// MARK: - Genre tree

struct TagTreePanel: View {
    let tree: [TagTreeNode]
    let loading: Bool
    let current: String
    let open: (TagTreeNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Genres & tags").font(Typo.sans(13, .semibold))
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
                else { Button { SmartQueryModel.shared.loadTree(store: LibraryModelBridge.shared.model?.store, force: true) } label: { Image(systemName: "arrow.clockwise").font(Typo.sans(10.5)) }.buttonStyle(.plain).foregroundStyle(Brand.inkSecondary).help("Read the genres again") }
            }
            .padding(.horizontal, 12).padding(.top, 12)
            if tree.isEmpty && !loading {
                Text("No genres in the library yet. Tags written as Classical/Beethoven/Symphonies appear here as a tree.")
                    .font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).padding(.horizontal, 12)
                Spacer()
            } else {
                List {
                    OutlineGroup(tree, children: \.childrenOrNil) { node in
                        TagTreeRow(node: node, selected: current == node.query) { open(node) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .glassPanel(radius: 14)
    }
}

private struct TagTreeRow: View {
    let node: TagTreeNode
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: node.children.isEmpty ? "tag" : "tag.fill").font(Typo.sans(10.5)).foregroundStyle(Brand.accent)
                Text(node.name).font(Typo.sans(12.5, selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(node.count)").font(Typo.mono(10.5)).foregroundStyle(Brand.inkTertiary)
            }
            .contentShape(Rectangle())
            .foregroundStyle(selected ? Brand.accent : Color.primary)
        }
        .buttonStyle(.plain)
        .help(node.query)
    }
}

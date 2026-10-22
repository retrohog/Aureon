import SwiftUI

extension AlbumQuery {
    /// The query a view's sort and filter options (and the filter box) ask for.
    init(_ o: ViewOptions, search: String) {
        let key: AlbumSortKey
        switch o.sort {
        case .artist: key = .artist; case .year: key = .year; case .added: key = .added; case .count: key = .count; case .genre: key = .genre; case .quality: key = .quality
        default: key = .title
        }
        let tier: AlbumTier?
        switch o.quality { case .all: tier = nil; case .hiRes: tier = .hiRes; case .cd: tier = .cd; case .dsd: tier = .dsd }
        self.init(search: search, sort: key, ascending: o.ascending, tier: tier)
    }
}

/// The albums page, a page at a time. The library may hold tens of thousands of albums; this keeps the count and only the few pages around the part
/// of the list on screen. The database does the sorting and filtering (see `LibraryStore.releasePage`), so showing or re-sorting a huge library costs
/// one small query, and the interface never holds, diffs or lays out more than it displays.
@MainActor
final class AlbumPager: ObservableObject {
    static let pageSize = 48

    /// How many albums match the query.
    @Published private(set) var total = 0
    /// Changes whenever a page arrives, so the views showing it refresh.
    @Published private(set) var revision = 0
    private(set) var query = AlbumQuery()
    private var pages: [Int: [ReleaseDTO]] = [:]
    private var inflight = Set<Int>()
    private var focus = 0                           // the page most recently asked for
    private var epoch = 0                           // bumped when the query changes, so answers to an old question are dropped
    private var configured = false
    /// The pages held at once: the one in view, its neighbours (fetched ahead of the scroll) and a little slack.
    var maxPages = 5
    var store: LibraryStore?

    /// Albums currently held, in list order (everything the pager has loaded; a few dozen to a couple of hundred).
    var resident: [ReleaseDTO] { pages.keys.sorted().flatMap { pages[$0] ?? [] } }
    var residentCount: Int { pages.values.reduce(0) { $0 + $1.count } }

    func peek(_ index: Int) -> ReleaseDTO? {
        guard index >= 0, let page = pages[index / Self.pageSize] else { return nil }
        let i = index % Self.pageSize
        return i < page.count ? page[i] : nil
    }

    /// Switches to another query. The count and the first page are fetched in the background; the list keeps showing the old one until then.
    func configure(_ q: AlbumQuery) {
        guard !configured || q != query else { return }
        configured = true; query = q; epoch += 1; inflight = []; focus = 0
        fetch(pagesToLoad: [0])
    }

    /// The library changed: fetch the count and the pages in view again.
    func reload() {
        guard configured else { return }
        epoch += 1; inflight = []
        fetch(pagesToLoad: Set(pages.keys).union([focus]))
    }

    /// A cell is about to be shown: make sure its page (and the neighbouring ones) are there.
    func ensure(_ index: Int) {
        let p = index / Self.pageSize
        focus = p
        for k in [p, p + 1, p - 1] where k >= 0 && k * Self.pageSize < total { load(k) }
        evict()
    }

    private func fetch(pagesToLoad wanted: Set<Int>) {
        guard let store else { return }
        let q = query, ep = epoch, size = Self.pageSize
        Task.detached(priority: .userInitiated) {
            if store.releasesWithoutFigures() > 0 { store.backfillReleaseFigures() }      // libraries from before the stored figures: once
            let n = store.releaseCount(q)
            var got: [Int: [ReleaseDTO]] = [:]
            for p in wanted where p * size < max(n, 1) { got[p] = store.releasePage(q, offset: p * size, limit: size) }
            await MainActor.run { [got] in
                guard ep == self.epoch else { return }
                self.total = n; self.pages = got; self.revision += 1
            }
        }
    }

    private func load(_ p: Int) {
        guard pages[p] == nil, !inflight.contains(p), let store else { return }
        inflight.insert(p)
        let q = query, ep = epoch, size = Self.pageSize
        Task.detached(priority: .userInitiated) {
            let rows = store.releasePage(q, offset: p * size, limit: size)
            await MainActor.run {
                guard ep == self.epoch else { return }
                self.inflight.remove(p); self.pages[p] = rows; self.evict(); self.revision += 1
            }
        }
    }

    /// Drops the pages farthest from the one in view.
    private func evict() {
        guard pages.count > maxPages else { return }
        for k in pages.keys.sorted(by: { abs($0 - focus) > abs($1 - focus) }).prefix(pages.count - maxPages) { pages[k] = nil }
    }
}

// MARK: - Views

/// What a cell shows until its page has arrived: the card's shape, so nothing shifts when the real one replaces it.
struct AlbumCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.ink.opacity(0.06)).aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 1) {
                Text("Album title").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text("Artist · 2000").font(.system(size: 11.5)).lineLimit(1)
            }.redacted(reason: .placeholder)
        }
    }
}

/// The Albums page: a grid or a list of every album, rendered and held a page at a time.
struct PagedAlbums: View {
    @ObservedObject var pager: AlbumPager
    let query: AlbumQuery
    let list: Bool
    let minimum: CGFloat
    let open: (ReleaseDTO) -> Void

    var body: some View {
        Group {
            if list {
                LazyVStack(spacing: 1) {
                    ForEach(0..<pager.total, id: \.self) { i in
                        Group {
                            if let a = pager.peek(i) { AlbumListRow(album: a) { open(a) } }
                            else { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.ink.opacity(0.04)).frame(height: 40).padding(.vertical, 5).padding(.horizontal, 9) }
                        }
                        .onAppear { pager.ensure(i) }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: minimum + 60), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(0..<pager.total, id: \.self) { i in
                        Group {
                            if let a = pager.peek(i) { AlbumCard(album: a) { open(a) } } else { AlbumCardPlaceholder() }
                        }
                        .onAppear { pager.ensure(i) }
                    }
                }
            }
        }
        .overlay { if pager.total == 0 && pager.revision > 0 { Text("No albums").foregroundStyle(.secondary).padding(.top, 60) } }
        .onAppear { pager.configure(query) }
        .onChange(of: query) { _, q in pager.configure(q) }
    }
}

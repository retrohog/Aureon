import SwiftUI
import AppKit

// The six layouts of Now Playing. Each is its own view and decides only where the shared pieces (NowPlayingParts) go; lyrics on or off changes what the
// middle shows. They are drawn for 1440 × 900 and scaled to the window (`npScale`), with the top bar above and nothing below the dock.

/// What every layout needs to know about the window.
struct NPCanvas {
    let size: CGSize
    var s: CGFloat { NPScale.of(size) }
    var margin: CGFloat { max(28, 64 * s) }
    var top: CGFloat { WindowChrome.band }
}

/// The bar of controls under a layout: the left block, the transport and the cluster. They fade with the rest of the interface.
struct NPDockRow<Left: View, Right: View>: View {
    @EnvironmentObject var idle: IdleTracker
    let left: Left
    let right: Right
    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) { self.left = left(); self.right = right() }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            NPTransport().fixedSize()
            right.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .opacity(idle.awake ? 1 : 0).allowsHitTesting(idle.awake).animation(Motion.carpet, value: idle.awake)
    }
}

// MARK: - Stage

struct NPStage: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo
    @EnvironmentObject var stage: StageModel

    var body: some View {
        let s = c.s
        VStack(spacing: 0) {
            Color.clear.frame(height: c.top)
            if m.look.showLyrics {
                NPTabs(selection: $stage.npTab).padding(.top, 6 * s)
                middle.padding(.top, 8 * s).frame(maxHeight: .infinity)
            } else {
                off.padding(.horizontal, c.margin).padding(.top, 24 * s).frame(maxHeight: .infinity, alignment: .top)
            }
            VStack(spacing: 6 * s) {
                NPSeek().padding(.horizontal, c.margin)
                NPDockRow(left: { dockLeft }, right: { NPCluster() }).padding(.horizontal, c.margin).frame(height: 120 * s)
            }
            .padding(.bottom, 14 * s)
        }
    }

    @ViewBuilder private var middle: some View {
        switch stage.npTab {
        case .lyrics:
            GeometryReader { g in NPLyrics(style: LyricStyle(size: 46, centered: true, gap: 22, rest: 0.42), height: g.size.height).padding(.horizontal, max(c.margin, 160 * c.s)) }
        case .upNext:
            NPUpNext(limit: 8, cover: 52).frame(maxWidth: 560).frame(maxWidth: .infinity, alignment: .top).padding(.top, 16)
        case .credits:
            Group { if info.credits.isEmpty { NPNoCredits() } else { NPCreditsGrid(lines: info.credits, columns: 3, gap: 22) } }
                .frame(maxWidth: 820).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 24).padding(.horizontal, c.margin)
        case .signal:
            NPSignalSteps().frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 24)
        }
    }

    /// Lyrics off: the credits on the left, the cover and its names in the middle, the queue on the right.
    private var off: some View {
        let s = c.s
        return HStack(alignment: .top, spacing: 40 * s) {
            VStack(alignment: .leading, spacing: 16 * s) {
                Text("Credits").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                if info.credits.isEmpty { NPNoCredits() }
                ForEach(info.credits.prefix(7)) { l in
                    VStack(alignment: .leading, spacing: 2) { Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary); Text(l.value).npFont(14.5).lineLimit(2) }
                }
            }
            .frame(width: 340 * s, alignment: .topLeading)
            VStack(spacing: 22 * s) {
                NPCover(side: 420 * s, radius: 16)
                NPTitleBlock(titleSize: 44, artistSize: 20, showsAlbumYear: true, credits: false, tags: false, centered: true)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text("Up next").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                NPUpNext(limit: 6, cover: 44)
            }
            .frame(width: 340 * s, alignment: .topLeading)
        }
    }

    @ViewBuilder private var dockLeft: some View {
        let s = c.s
        if m.look.showLyrics {
            HStack(spacing: 22 * s) {
                NPCover(side: 120 * s, radius: 12)
                NPTitleBlock(titleSize: 30, artistSize: 18, credits: true, tags: true, actions: 36)
            }
        } else {
            VStack(alignment: .leading, spacing: 8 * s) {
                NPActions(size: 40)
                NPTags()
                NPSignalLine()
            }
        }
    }
}

// MARK: - Classic

struct NPClassic: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo
    @EnvironmentObject var stage: StageModel

    var body: some View {
        let s = c.s
        VStack(spacing: 0) {
            Color.clear.frame(height: c.top)
            Group { if m.look.showLyrics { on } else { off } }
                .padding(.horizontal, c.margin).padding(.top, 24 * s).frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 6 * s) {
                NPSeek().padding(.horizontal, c.margin)
                NPDockRow(left: { OutputChip() }, right: { NPCluster(showsChip: false) }).padding(.horizontal, c.margin).frame(height: 84 * s)
            }
            .padding(.bottom, 14 * s)
        }
    }

    private var on: some View {
        let s = c.s
        return HStack(alignment: .top, spacing: 76 * s) {
            VStack(alignment: .leading, spacing: 18 * s) {
                NPCover(side: 500 * s, radius: 16)
                NPCreditsGrid(lines: Array(info.credits.prefix(3)), columns: 3, gap: 12)
                NPTags()
            }
            .frame(width: 500 * s, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 14 * s) {
                NPTitleBlock(titleSize: 54, artistSize: 21, credits: false, tags: false, actions: 44)
                NPTabs(selection: $stage.npTab, centered: false)
                tabContent.frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch stage.npTab {
        case .lyrics:
            GeometryReader { g in NPLyrics(style: LyricStyle(size: 38, centered: false, gap: 16, rest: 0.34), height: g.size.height) }
        case .upNext: ScrollView(showsIndicators: false) { NPUpNext(limit: 12, cover: 48) }
        case .credits: ScrollView(showsIndicators: false) { if info.credits.isEmpty { NPNoCredits() } else { NPCreditsGrid(lines: info.credits, columns: 3, gap: 20) } }
        case .signal: ScrollView(showsIndicators: false) { NPSignalSteps() }
        }
    }

    private var off: some View {
        let s = c.s
        return HStack(alignment: .top, spacing: 68 * s) {
            VStack(alignment: .leading, spacing: 20 * s) {
                NPCover(side: 580 * s, radius: 18)
                NPSignalLine()
            }
            .frame(width: 580 * s, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 20 * s) {
                NPTitleBlock(titleSize: 60, artistSize: 22, showsAlbumYear: true, credits: false, tags: false, actions: 44)
                NPTags()
                NPCreditsGrid(lines: Array(info.credits.prefix(6)), columns: 3, gap: 14)
                HStack { Text("Up next").npFont(19, .medium); Spacer() }.padding(.top, 6)
                NPUpNext(limit: 4, cover: 44)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Full-bleed

struct NPFullBleed: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo

    var body: some View {
        let s = c.s
        ZStack {
            backdrop
            VStack(spacing: 0) {
                Color.clear.frame(height: c.top)
                Group { if m.look.showLyrics { on } else { off } }
                    .padding(.horizontal, c.margin).padding(.top, 20 * s).frame(maxHeight: .infinity, alignment: .top)
                VStack(spacing: 6 * s) {
                    NPSeek().padding(.horizontal, c.margin)
                    NPDockRow(left: { HStack(spacing: 4) { NPActions(size: 44); OutputChip().padding(.leading, 10) } }, right: { NPCluster(showsChip: false) })
                        .padding(.horizontal, c.margin).frame(height: 84 * s)
                }
                .padding(.bottom, 14 * s)
            }
        }
    }

    /// The cover is the picture: laid over the whole window, softened, with a veil so the words keep their contrast.
    private var backdrop: some View {
        ZStack {
            Brand.panel
            if let img = m.hero.image ?? m.focusItem?.thumb {
                Image(nsImage: img).resizable().scaledToFill().blur(radius: 6).clipped()
            }
            LinearGradient(colors: [Brand.panel.opacity(0.35), Brand.panel.opacity(0.78)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea().allowsHitTesting(false)
    }

    private var on: some View {
        let s = c.s
        return HStack(alignment: .top, spacing: 40 * s) {
            VStack(alignment: .leading, spacing: 18 * s) {
                playingFrom
                NPTitleBlock(titleSize: 58, artistSize: 22, credits: false, tags: true)
                GeometryReader { g in NPLyrics(style: LyricStyle(size: 42, centered: false, gap: 14, rest: 0.3), height: g.size.height) }.frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 12 * s) {
                Spacer(minLength: 0)
                ForEach(info.credits.prefix(3)) { l in VStack(alignment: .leading, spacing: 2) { Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary); Text(l.value).npFont(14.5).lineLimit(2) } }
            }
            .frame(width: 260 * s, alignment: .bottomLeading).padding(.bottom, 12 * s)
        }
    }

    private var off: some View {
        let s = c.s
        return HStack(alignment: .bottom, spacing: 40 * s) {
            VStack(alignment: .leading, spacing: 12 * s) {
                Spacer(minLength: 0)
                playingFrom
                NPTitleBlock(titleSize: 108, artistSize: 28, showsAlbumYear: true, credits: false, tags: true)
                HStack(alignment: .top, spacing: 40 * s) {
                    ForEach(info.credits.prefix(4)) { l in VStack(alignment: .leading, spacing: 2) { Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary); Text(l.value).npFont(14.5).lineLimit(2) } }
                }.padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Up next").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                NPUpNext(limit: 6, cover: 44)
                Spacer(minLength: 0)
            }
            .frame(width: 360 * s, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var playingFrom: some View {
        let album = m.focusItem?.album ?? ""
        return Text(album.isEmpty ? "Now playing" : "Playing from \(album)").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary).lineLimit(1)
    }
}

// MARK: - Carousel

struct NPCarousel: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo

    /// The songs two before and two after the current one (nil where the queue ends).
    private var ring: (p2: QueueItem?, p1: QueueItem?, n1: QueueItem?, n2: QueueItem?) {
        let items = m.items
        guard let id = m.current?.id ?? m.focusItem?.id, let i = items.firstIndex(where: { $0.id == id }) else { return (nil, nil, items.first, items.dropFirst().first) }
        func at(_ k: Int) -> QueueItem? { items.indices.contains(k) ? items[k] : nil }
        return (at(i - 2), at(i - 1), at(i + 1), at(i + 2))
    }

    var body: some View {
        let s = c.s
        VStack(spacing: 0) {
            Color.clear.frame(height: c.top)
            Group { if m.look.showLyrics { on } else { off } }
                .padding(.horizontal, c.margin).padding(.top, 16 * s).frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 8 * s) {
                NPSeek(style: .slim).padding(.horizontal, c.margin)
                NPDockRow(left: { HStack(spacing: 4) { NPActions(size: 44); OutputChip().padding(.leading, 10) } }, right: { NPCluster(showsChip: false) })
                    .padding(.horizontal, c.margin).frame(height: 84 * s)
            }
            .padding(.bottom, 14 * s)
        }
    }

    private func cover(_ item: QueueItem?, _ side: CGFloat, _ radius: CGFloat, _ action: @escaping () -> Void) -> some View {
        Group {
            if let item {
                Button(action: action) {
                    CoverView(image: item.thumb, palette: ArtPalette.fallback(seed: item.album.isEmpty ? item.title : item.album), corner: radius, symbol: "music.note")
                        .frame(width: side, height: side).opacity(0.78)
                }.buttonStyle(.plain).accessibilityLabel("Play \(item.title)")
            } else { Color.clear.frame(width: side, height: side) }
        }
    }

    private func row(centre: CGFloat, near: CGFloat, far: CGFloat, radius: CGFloat) -> some View {
        let r = ring
        return HStack(alignment: .center, spacing: 18 * c.s) {
            cover(r.p2, far, radius - 2) { if let it = r.p2 { m.play(it.id) } }
            cover(r.p1, near, radius) { m.player.send(.previous) }
            NPCover(side: centre, radius: radius + 4)
            cover(r.n1, near, radius) { m.player.send(.next) }
            cover(r.n2, far, radius - 2) { if let it = r.n2 { m.play(it.id) } }
        }
        .frame(maxWidth: .infinity)
    }

    private var on: some View {
        let s = c.s
        return VStack(spacing: 14 * s) {
            row(centre: 200 * s, near: 140 * s, far: 100 * s, radius: 12)
            NPTitleBlock(titleSize: 36, artistSize: 19, credits: true, tags: true, centered: true)
            GeometryReader { g in NPLyrics(style: LyricStyle(size: 30, centered: true, gap: 12, rest: 0.4), height: g.size.height).padding(.horizontal, max(0, 200 * s - c.margin)) }.frame(maxHeight: .infinity)
        }
    }

    private var off: some View {
        let s = c.s, r = ring
        return VStack(spacing: 14 * s) {
            row(centre: 400 * s, near: 280 * s, far: 190 * s, radius: 14)
            HStack(alignment: .top) {
                caption("Previous", r.p1).frame(width: 280 * s, alignment: .center)
                Spacer()
                caption("Next", r.n1).frame(width: 280 * s, alignment: .center)
            }.frame(height: 30 * s).padding(.horizontal, 20 * s)
            NPTitleBlock(titleSize: 44, artistSize: 20, showsAlbumYear: true, credits: false, tags: false, centered: true)
            HStack(alignment: .top, spacing: 42 * s) { ForEach(info.credits.prefix(4)) { l in VStack(alignment: .leading, spacing: 2) { Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary); Text(l.value).npFont(14.5).lineLimit(1) } } }
            AddToChips()
            Spacer(minLength: 0)
        }
    }

    private func caption(_ word: String, _ item: QueueItem?) -> some View {
        VStack(spacing: 1) {
            Text(item?.title ?? "").npFont(14).lineLimit(1)
            Text(item == nil ? "" : word).npFont(12.5).foregroundStyle(Brand.inkSecondary)
        }
    }
}

/// "Add to" and a few playlists as chips: a tap adds the song to that playlist.
struct AddToChips: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var c: CollectionsModel
    @StateObject private var added = Box(Set<String>())
    var body: some View {
        let path = m.focusItem.flatMap { $0.isStream ? nil : $0.path }
        HStack(spacing: 8) {
            Text("Add to").npFont(13.5).foregroundStyle(Brand.inkSecondary).padding(.trailing, 4)
            ForEach(c.playlists.prefix(3)) { p in
                PillChip(title: p.name, on: added.v.contains(p.id), height: 30) {
                    guard let path, let t = c.store?.track(path: path) else { return }
                    if c.add([t], to: p.id) >= 0 { added.v.insert(p.id) }
                }
            }
            if let path { NPPlaylistButton(path: path, size: 30).help("More playlists") }
        }
        .disabled(path == nil)
    }
}

// MARK: - Lumen

struct NPLumen: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo
    @EnvironmentObject var idle: IdleTracker

    var body: some View {
        let s = c.s
        VStack(spacing: 0) {
            Color.clear.frame(height: c.top)
            HStack(alignment: .top, spacing: 44 * s) {
                left.frame(width: 420 * s, alignment: .topLeading)
                middle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Up next").npFont(19, .medium); Spacer(); Text(queueNote).npFont(12.5).foregroundStyle(Brand.inkSecondary) }
                    NPUpNext(limit: 7, cover: 44, titleSize: 15)
                    Spacer(minLength: 0)
                }
                .frame(width: 272 * s, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, c.margin).padding(.top, 16 * s)
            dock
        }
    }

    private var queueNote: String {
        let n = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: 999).count
        return n == 0 ? "" : "\(n) queued"
    }

    private var left: some View {
        let s = c.s
        return VStack(alignment: .leading, spacing: 0) {
            NPCover(side: 420 * s, radius: 38)
            NPTitleBlock(titleSize: 42, artistSize: 18, credits: true, tags: true).padding(.top, 20 * s)
            NPActions(size: 44).padding(.top, 8 * s).padding(.leading, -8)
        }
    }

    @ViewBuilder private var middle: some View {
        let s = c.s
        if m.look.showLyrics {
            GeometryReader { g in NPLyrics(style: LyricStyle(size: 40, centered: false, gap: 22, rest: 0.4), height: g.size.height) }.frame(maxWidth: 520 * s + 120)
        } else {
            VStack(alignment: .leading, spacing: 40 * s) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Credits").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                    if info.credits.isEmpty { NPNoCredits() } else { NPCreditsGrid(lines: info.credits, columns: 2, gap: 18) }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Signal path").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                    NPSignalSteps()
                }
            }
            .frame(maxWidth: 520 * s + 120, alignment: .topLeading).padding(.top, 8)
        }
    }

    /// The dock: a rounded plate with the position, the transport and the controls in one row.
    private var dock: some View {
        let s = c.s
        return HStack(spacing: 14 * s) {
            BarTime(remaining: false)
            WaveformScrubber(style: .slim, tint: Brand.accent).stageMatched(.waveform)
            BarTime(remaining: true)
            Color.clear.frame(width: 8)
            NPTransport().fixedSize()
            Color.clear.frame(width: 8)
            NPCluster(showsChip: true, volumeWidth: 84).fixedSize()
        }
        .padding(.horizontal, 26 * s).frame(height: 96 * s)
        .background(RoundedRectangle(cornerRadius: 32 * s, style: .continuous).fill(Brand.panel2))
        .padding(.horizontal, c.margin).padding(.bottom, 24 * s).padding(.top, 8 * s)
        .opacity(idle.awake ? 1 : 0.0001).animation(Motion.carpet, value: idle.awake)
    }
}

// MARK: - Chillax

struct NPChillax: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo

    var body: some View {
        let s = c.s
        VStack(spacing: 0) {
            Color.clear.frame(height: c.top)
            HStack(alignment: .top, spacing: 64 * s) {
                NPCover(side: 540 * s, radius: 30)
                VStack(alignment: .leading, spacing: 18 * s) {
                    NPTitleBlock(titleSize: 76, artistSize: 22, showsAlbumYear: true, credits: true, tags: true, actions: 44)
                    if m.look.showLyrics {
                        GeometryReader { g in NPLyrics(style: LyricStyle(size: 32, centered: false, gap: 12, rest: 0.34), height: g.size.height) }.frame(maxHeight: .infinity)
                    } else {
                        NPCreditsGrid(lines: Array(info.credits.prefix(6)), columns: 3, gap: 16)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Signal path").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                            NPSignalLine()
                        }.padding(.top, 14)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, c.margin).padding(.top, 16 * s).frame(maxHeight: 560 * s + 20)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Up next").npFont(19, .medium); Text(note).npFont(13).foregroundStyle(Brand.inkSecondary).padding(.leading, 8); Spacer() }
                NPShelf(limit: 5)
            }
            .padding(.horizontal, c.margin).padding(.top, 8 * s)
            Spacer(minLength: 0)
            VStack(spacing: 10 * s) {
                NPSeek(style: .slim).padding(.horizontal, c.margin)
                NPDockRow(left: { OutputChip() }, right: { NPCluster(showsChip: false) }).padding(.horizontal, c.margin).frame(height: 70 * s)
            }
            .padding(.bottom, 14 * s)
        }
    }

    private var note: String {
        let n = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: 999).count
        return n == 0 ? "" : "\(min(n, 5)) of \(n) songs"
    }
}

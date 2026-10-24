import SwiftUI
import AppKit

// The six layouts of Now Playing. Each is its own view and decides only where the shared pieces (NowPlayingParts) go; lyrics on or off changes what the
// middle shows. They are drawn for 1440 × 900 and scaled to the window (`npScale`).
//
// Every layout is built the same way (`NPFrame`): the top bar's space, then a body that is given exactly the room left, then the dock (seek, transport,
// the cluster). The dock is never inside the body, so it is always whole and visible; the body sizes its covers from the room it has and is clipped to it,
// so nothing in it can reach the dock or the top bar, and what does not fit (the lyrics, the queue) shrinks instead of overlapping.

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

/// Seek line above the dock row, with the bottom margin.
struct NPDock<Left: View, Right: View>: View {
    let c: NPCanvas
    var seek = NPSeek.Style.waveform
    var rowHeight: CGFloat = 84
    let left: Left
    let right: Right
    init(_ c: NPCanvas, seek: NPSeek.Style = .waveform, rowHeight: CGFloat = 84, @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.c = c; self.seek = seek; self.rowHeight = rowHeight; self.left = left(); self.right = right()
    }
    var body: some View {
        VStack(spacing: 6 * c.s) {
            NPSeek(style: seek).padding(.horizontal, c.margin)
            NPDockRow(left: { left }, right: { right }).padding(.horizontal, c.margin).frame(minHeight: rowHeight * c.s)
        }
        .padding(.bottom, 14 * c.s)
        .accessibilityElement(children: .contain).accessibilityIdentifier("np.dock")
    }
}

/// The frame every layout sits in: the top bar's space, the body (given the room that is left, and clipped to it) and the dock at its natural height.
struct NPFrame<Content: View, Dock: View>: View {
    let c: NPCanvas
    let content: (CGSize) -> Content
    let dock: Dock
    init(_ c: NPCanvas, @ViewBuilder content: @escaping (CGSize) -> Content, @ViewBuilder dock: () -> Dock) { self.c = c; self.content = content; self.dock = dock() }
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: c.top)
            GeometryReader { g in
                content(g.size).frame(width: g.size.width, height: g.size.height, alignment: .top).clipped()
            }
            dock.fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Stage

struct NPStage: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo
    @EnvironmentObject var stage: StageModel

    var body: some View {
        NPFrame(c, content: { size in
            if m.look.showLyrics {
                VStack(spacing: 8 * c.s) {
                    NPTabs(selection: $stage.npTab).padding(.top, 6 * c.s)
                    middle.frame(maxHeight: .infinity)
                }
            } else {
                off(size).padding(.horizontal, c.margin).padding(.top, 20 * c.s)
            }
        }, dock: {
            NPDock(c, rowHeight: m.look.showLyrics ? 120 : 96, left: { dockLeft }, right: { NPCluster() })
        })
    }

    @ViewBuilder private var middle: some View {
        switch stage.npTab {
        case .lyrics:
            GeometryReader { g in NPLyrics(style: LyricStyle(size: 46, centered: true, gap: 22, rest: 0.42), height: g.size.height).padding(.horizontal, max(c.margin, 160 * c.s)) }
        case .upNext:
            ScrollView(showsIndicators: false) { NPUpNext(limit: 10, cover: 52).frame(maxWidth: 560).frame(maxWidth: .infinity) }.padding(.top, 12)
        case .credits:
            ScrollView(showsIndicators: false) {
                Group { if info.credits.isEmpty { NPNoCredits() } else { NPCreditsGrid(lines: info.credits, columns: 3, gap: 22) } }
                    .frame(maxWidth: 820).frame(maxWidth: .infinity).padding(.top, 16).padding(.horizontal, c.margin)
            }
        case .signal:
            ScrollView(showsIndicators: false) { NPSignalSteps().frame(maxWidth: 560).frame(maxWidth: .infinity).padding(.top, 16) }
        }
    }

    /// Lyrics off: the credits on the left, the cover and its names in the middle, the queue on the right (the sides give way in a narrow window).
    private func off(_ size: CGSize) -> some View {
        let s = c.s
        let names: CGFloat = 96 * s                                                  // the title, the artist line and the gaps under the cover
        let side = max(100, min(420 * s, size.height - names - 40 * s, size.width * 0.34))
        let column = min(340 * s, (size.width - 2 * c.margin - side - 80 * s) / 2)
        return HStack(alignment: .top, spacing: 40 * s) {
            if column >= 170 {
                VStack(alignment: .leading, spacing: 14 * s) {
                    Text("Credits").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                    if info.credits.isEmpty { NPNoCredits() }
                    ForEach(info.credits.prefix(6)) { l in
                        VStack(alignment: .leading, spacing: 2) { Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary); Text(l.value).npFont(14.5).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: column, alignment: .topLeading)
            }
            VStack(spacing: 16 * s) {
                NPCover(side: side, radius: 16)
                NPTitleBlock(titleSize: 44, artistSize: 20, showsAlbumYear: true, credits: false, tags: false, centered: true)
            }
            .frame(maxWidth: .infinity)
            if column >= 170 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Up next").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                    NPUpNext(limit: 5, cover: 44)
                    Spacer(minLength: 0)
                }
                .frame(width: column, alignment: .topLeading)
            }
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
        NPFrame(c, content: { size in
            Group { if m.look.showLyrics { on(size) } else { off(size) } }
                .padding(.horizontal, c.margin).padding(.top, 20 * c.s)
        }, dock: {
            NPDock(c, left: { OutputChip(anchor: .stage) }, right: { NPCluster(showsChip: false) })
        })
    }

    private func on(_ size: CGSize) -> some View {
        let s = c.s
        let below: CGFloat = 96 * s                                                  // the credits and the tags under the cover
        let side = max(120, min(500 * s, size.height - below - 20 * s, size.width * 0.38))
        return HStack(alignment: .top, spacing: 60 * s) {
            VStack(alignment: .leading, spacing: 14 * s) {
                NPCover(side: side, radius: 16)
                NPCreditsGrid(lines: Array(info.credits.prefix(3)), columns: 3, gap: 10)
                NPTags()
            }
            .frame(width: side, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 12 * s) {
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

    private func off(_ size: CGSize) -> some View {
        let s = c.s
        let side = max(120, min(580 * s, size.height - 50 * s, size.width * 0.4))
        return HStack(alignment: .top, spacing: 60 * s) {
            VStack(alignment: .leading, spacing: 14 * s) {
                NPCover(side: side, radius: 18)
                NPSignalLine()
            }
            .frame(width: side, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 16 * s) {
                NPTitleBlock(titleSize: 60, artistSize: 22, showsAlbumYear: true, credits: false, tags: false, actions: 44)
                NPTags()
                NPCreditsGrid(lines: Array(info.credits.prefix(6)), columns: 3, gap: 12)
                HStack { Text("Up next").npFont(19, .medium); Spacer() }.padding(.top, 4)
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
        ZStack {
            backdrop
            NPFrame(c, content: { size in
                Group { if m.look.showLyrics { on(size) } else { off(size) } }
                    .padding(.horizontal, c.margin).padding(.top, 16 * c.s)
            }, dock: {
                NPDock(c, left: { HStack(spacing: 4) { NPActions(size: 44); OutputChip(anchor: .stage).padding(.leading, 10) } }, right: { NPCluster(showsChip: false) })
            })
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

    private func on(_ size: CGSize) -> some View {
        let s = c.s
        return HStack(alignment: .top, spacing: 40 * s) {
            VStack(alignment: .leading, spacing: 14 * s) {
                playingFrom
                NPTitleBlock(titleSize: 58, artistSize: 22, credits: false, tags: true)
                GeometryReader { g in NPLyrics(style: LyricStyle(size: 42, centered: false, gap: 14, rest: 0.3), height: g.size.height) }.frame(maxHeight: .infinity)
            }
            if size.width > 900 {
                VStack(alignment: .leading, spacing: 12 * s) {
                    Spacer(minLength: 0)
                    ForEach(info.credits.prefix(3)) { l in VStack(alignment: .leading, spacing: 2) { Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary); Text(l.value).npFont(14.5).lineLimit(2) } }
                }
                .frame(width: 240 * s, alignment: .bottomLeading).padding(.bottom, 12 * s)
            }
        }
    }

    private func off(_ size: CGSize) -> some View {
        let s = c.s
        let title = max(48, min(108, (size.height - 150 * s) * 0.46 / max(s, 0.6)))
        return HStack(alignment: .bottom, spacing: 40 * s) {
            VStack(alignment: .leading, spacing: 10 * s) {
                Spacer(minLength: 0)
                playingFrom
                NPTitleBlock(titleSize: title, artistSize: 28, showsAlbumYear: true, credits: false, tags: true)
                HStack(alignment: .top, spacing: 36 * s) {
                    ForEach(info.credits.prefix(4)) { l in VStack(alignment: .leading, spacing: 2) { Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary); Text(l.value).npFont(14.5).lineLimit(2) } }
                }.padding(.top, 6)
            }
            if size.width > 900 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Up next").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                    NPUpNext(limit: 5, cover: 44)
                    Spacer(minLength: 0)
                }
                .frame(width: 340 * s, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
            }
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
        NPFrame(c, content: { size in
            Group { if m.look.showLyrics { on(size) } else { off(size) } }
                .padding(.horizontal, c.margin).padding(.top, 14 * c.s)
        }, dock: {
            NPDock(c, seek: .slim, left: { HStack(spacing: 4) { NPActions(size: 44); OutputChip(anchor: .stage).padding(.leading, 10) } }, right: { NPCluster(showsChip: false) })
        })
    }

    private func cover(_ item: QueueItem?, _ side: CGFloat, _ radius: CGFloat, _ action: @escaping () -> Void) -> some View {
        Group {
            if let item {
                Button(action: action) {
                    CoverView(image: item.thumb, palette: ArtPalette.fallback(seed: item.album.isEmpty ? item.title : item.album), corner: radius, symbol: "music.note")
                        .frame(width: side, height: side).opacity(0.78)
                }.buttonStyle(.plain).onAppear { m.requestMetadata(item.id) }.accessibilityLabel("Play \(item.title)")
            } else { Color.clear.frame(width: side, height: side) }
        }
    }

    private func row(centre: CGFloat, near: CGFloat, far: CGFloat, radius: CGFloat, width: CGFloat) -> some View {
        let r = ring
        let narrow = width < centre + 2 * near + 2 * far + 80
        return HStack(alignment: .center, spacing: 18 * c.s) {
            if !narrow { cover(r.p2, far, radius - 2) { if let it = r.p2 { m.play(it.id) } } }
            cover(r.p1, near, radius) { m.player.send(.previous) }
            NPCover(side: centre, radius: radius + 4)
            cover(r.n1, near, radius) { m.player.send(.next) }
            if !narrow { cover(r.n2, far, radius - 2) { if let it = r.n2 { m.play(it.id) } } }
        }
        .frame(maxWidth: .infinity)
    }

    private func on(_ size: CGSize) -> some View {
        let s = c.s
        let text: CGFloat = 150 * s                                                  // the names, the credits and the tags under the covers
        let centre = max(80, min(200 * s, size.height - text - 90))
        return VStack(spacing: 12 * s) {
            row(centre: centre, near: centre * 0.7, far: centre * 0.5, radius: 12, width: size.width - 2 * c.margin)
            NPTitleBlock(titleSize: 36, artistSize: 19, credits: true, tags: true, centered: true)
            GeometryReader { g in NPLyrics(style: LyricStyle(size: 30, centered: true, gap: 12, rest: 0.4), height: g.size.height).padding(.horizontal, max(0, 200 * s - c.margin)) }.frame(maxHeight: .infinity)
        }
    }

    private func off(_ size: CGSize) -> some View {
        let s = c.s, r = ring
        let text: CGFloat = 190 * s
        let centre = max(100, min(400 * s, size.height - text - 40))
        return VStack(spacing: 12 * s) {
            row(centre: centre, near: centre * 0.7, far: centre * 0.475, radius: 14, width: size.width - 2 * c.margin)
            HStack(alignment: .top) {
                caption("Previous", r.p1).frame(width: centre * 0.7, alignment: .center)
                Spacer()
                caption("Next", r.n1).frame(width: centre * 0.7, alignment: .center)
            }.frame(height: 30 * s)
            NPTitleBlock(titleSize: 44, artistSize: 20, showsAlbumYear: true, credits: false, tags: false, centered: true)
            HStack(alignment: .top, spacing: 36 * s) { ForEach(info.credits.prefix(4)) { l in VStack(alignment: .leading, spacing: 2) { Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary); Text(l.value).npFont(14.5).lineLimit(1) } } }
            if size.height > 560 { AddToChips() }
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
        NPFrame(c, content: { size in
            body(size).padding(.horizontal, c.margin).padding(.top, 14 * c.s)
        }, dock: { dock })
    }

    private func body(_ size: CGSize) -> some View {
        let s = c.s
        let text: CGFloat = 190 * s                                                  // title, credits, tags and the buttons under the cover
        let side = max(100, min(420 * s, size.height - text - 20, size.width * 0.34))
        let queueWidth: CGFloat = size.width > 980 ? 272 * s : 0
        return HStack(alignment: .top, spacing: 40 * s) {
            left(side).frame(width: side, alignment: .topLeading)
            middle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if queueWidth > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Up next").npFont(19, .medium); Spacer(); Text(queueNote).npFont(12.5).foregroundStyle(Brand.inkSecondary) }
                    NPUpNext(limit: 6, cover: 44, titleSize: 15)
                    Spacer(minLength: 0)
                }
                .frame(width: queueWidth, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var queueNote: String {
        let n = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: 999).count
        return n == 0 ? "" : "\(n) queued"
    }

    private func left(_ side: CGFloat) -> some View {
        let s = c.s
        return VStack(alignment: .leading, spacing: 0) {
            NPCover(side: side, radius: 38)
            NPTitleBlock(titleSize: 42, artistSize: 18, credits: true, tags: true).padding(.top, 16 * s)
            NPActions(size: 44).padding(.top, 6 * s).padding(.leading, -8)
        }
    }

    @ViewBuilder private var middle: some View {
        let s = c.s
        if m.look.showLyrics {
            GeometryReader { g in NPLyrics(style: LyricStyle(size: 40, centered: false, gap: 22, rest: 0.4), height: g.size.height) }
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32 * s) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Credits").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                        if info.credits.isEmpty { NPNoCredits() } else { NPCreditsGrid(lines: info.credits, columns: 2, gap: 18) }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Signal path").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                        NPSignalSteps()
                    }
                }
                .frame(maxWidth: 600, alignment: .topLeading).padding(.top, 6)
            }
        }
    }

    /// The dock: a rounded plate with the position, the transport and the controls in one row.
    private var dock: some View {
        let s = c.s
        return HStack(spacing: 14 * s) {
            BarTime(remaining: false)
            WaveformScrubber(style: .slim, tint: Brand.accent).stageMatched(.waveform).frame(minWidth: 60)
            BarTime(remaining: true)
            NPTransport().fixedSize()
            NPCluster(showsChip: true, volumeWidth: 84).layoutPriority(0)
        }
        .padding(.horizontal, 24 * s).frame(minHeight: 88 * s)
        .background(RoundedRectangle(cornerRadius: 32 * s, style: .continuous).fill(Brand.panel2))
        .padding(.horizontal, c.margin).padding(.bottom, 20 * s).padding(.top, 8 * s)
        .opacity(idle.awake ? 1 : 0.0001).animation(Motion.carpet, value: idle.awake)
        .accessibilityElement(children: .contain).accessibilityIdentifier("np.dock")
    }
}

// MARK: - Chillax

struct NPChillax: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo

    var body: some View {
        NPFrame(c, content: { size in
            body(size).padding(.horizontal, c.margin).padding(.top, 14 * c.s)
        }, dock: {
            NPDock(c, seek: .slim, rowHeight: 70, left: { OutputChip(anchor: .stage) }, right: { NPCluster(showsChip: false) })
        })
    }

    private func body(_ size: CGSize) -> some View {
        let s = c.s
        let shelfHeight: CGFloat = size.height > 470 ? 96 * s : 0                    // the shelf is dropped when the window is too short for it
        let side = max(100, min(540 * s, size.height - shelfHeight - 24, size.width * 0.38))
        return VStack(alignment: .leading, spacing: 12 * s) {
            HStack(alignment: .top, spacing: 56 * s) {
                NPCover(side: side, radius: 30)
                VStack(alignment: .leading, spacing: 14 * s) {
                    NPTitleBlock(titleSize: 76, artistSize: 22, showsAlbumYear: true, credits: true, tags: true, actions: 44)
                    if m.look.showLyrics {
                        GeometryReader { g in NPLyrics(style: LyricStyle(size: 32, centered: false, gap: 12, rest: 0.34), height: g.size.height) }.frame(maxHeight: .infinity)
                    } else {
                        NPCreditsGrid(lines: Array(info.credits.prefix(6)), columns: 3, gap: 14)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Signal path").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary)
                            NPSignalLine()
                        }.padding(.top, 10)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: side)
            if shelfHeight > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Up next").npFont(19, .medium); Text(note).npFont(13).foregroundStyle(Brand.inkSecondary).padding(.leading, 8); Spacer() }
                    NPShelf(limit: size.width > 1100 ? 5 : 3)
                }
            }
        }
    }

    private var note: String {
        let n = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: 999).count
        return n == 0 ? "" : "\(min(n, 5)) of \(n) songs"
    }
}

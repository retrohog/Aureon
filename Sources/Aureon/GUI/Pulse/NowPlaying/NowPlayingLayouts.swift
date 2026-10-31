import SwiftUI
import AppKit

// The seven layouts of Now Playing. Each is its own view and decides only where the shared pieces (NowPlayingParts) go; lyrics on or off changes what the
// middle shows. They are drawn for 1440 × 900 and scaled to the window (`npScale`).
//
// Every layout is built the same way (`NPFrame`): the top bar's space, then a body that is given exactly the room left, then the dock (seek, transport,
// the cluster). The dock is never inside the body, so it is always whole and visible; the body sizes its covers from the room it has and is clipped to it,
// so nothing in it can reach the dock or the top bar, and what does not fit (the lyrics, the queue) shrinks instead of overlapping.

/// What every layout needs to know about the window.
struct NPCanvas {
    let size: CGSize
    /// A layout on a stricter grid than the usual margin (Poster: 40 pt) sets its own, and the dock follows it.
    var inset: CGFloat? = nil
    var s: CGFloat { NPScale.of(size) }
    var margin: CGFloat { inset ?? max(28, 64 * s) }
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
        .accessibilityElement(children: .contain).accessibilityIdentifier("np.dock").layoutProbe("dock")
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
            NPDock(c, left: { Color.clear.frame(width: 1, height: 1) }, right: { NPCluster(showsChip: false) })
        })
    }

    private func on(_ size: CGSize) -> some View {
        let s = c.s
        let inner = size.width - 2 * c.margin
        let height = size.height - 20 * s
        let queued = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: 6).count
        let plan = NPClassicPlan.make(inner: inner, height: height, s: s, tags: m.look.showSignalTags, queued: queued)
        return Group {
            if plan.wide {
                VStack(alignment: .leading, spacing: plan.gap) {
                    HStack(alignment: .top, spacing: plan.gutter) {
                        NPCover(side: plan.coverSide, radius: 16).frame(width: plan.coverSide, alignment: .topLeading)
                        words(plan, width: plan.rightWidth)
                    }
                    .frame(height: plan.topHeight, alignment: .top)
                    if plan.stripCards > 0 { upNextStrip(plan) }
                }
            } else {
                HStack(alignment: .top, spacing: plan.gutter) {
                    NPCover(side: plan.coverSide, radius: 16).frame(width: plan.coverSide, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 0) {
                        words(plan, width: plan.rightWidth)
                        if plan.listRows > 0 {
                            VStack(alignment: .leading, spacing: 4 * s) {
                                Text("Up next").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary).frame(height: 24 * s, alignment: .leading)
                                NPUpNext(limit: plan.listRows, cover: 44)
                            }.frame(height: plan.listHeight, alignment: .topLeading).clipped()
                        }
                    }
                    .frame(width: plan.rightWidth, height: height, alignment: .topLeading)
                }
            }
        }
    }

    /// The title, the quality strip, the tabs and the words, which take whatever height is left.
    private func words(_ plan: NPClassicPlan, width: CGFloat) -> some View {
        let s = c.s
        return VStack(alignment: .leading, spacing: 12 * s) {
            NPTitleBlock(titleSize: 54, artistSize: 21, credits: false, tags: false, actions: 44)
            if m.look.showSignalTags { NPTags().frame(height: plan.tagsHeight - 4 * s, alignment: .topLeading) }
            NPTabs(selection: $stage.npTab, centered: false)
            tabContent.frame(maxHeight: .infinity)
        }
        .frame(width: width, alignment: .topLeading)
    }

    /// The next songs as cards across the foot, directly above the seek bar.
    private func upNextStrip(_ plan: NPClassicPlan) -> some View {
        let s = c.s
        let next = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: plan.stripCards)
        return VStack(alignment: .leading, spacing: 4 * s) {
            Text("Up next").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary).frame(height: 24 * s, alignment: .leading)
            HStack(spacing: 12 * s) {
                ForEach(next) { it in
                    NPQueueRow(item: it, cover: 52 * s, titleSize: 14.5) { m.play(it.id) }
                        .padding(8 * s).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.ink.opacity(0.06)))
                }
            }.frame(height: 64 * s)
        }
        .frame(height: plan.stripHeight, alignment: .topLeading)
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
        // The backdrop is a background, not a sibling: a cover scaled to fill is larger than the window, and as a sibling it would
        // grow the whole layout past the window and push the controls off the bottom.
        NPFrame(c, content: { size in
            Group { if m.look.showLyrics { on(size) } else { off(size) } }
                .padding(.horizontal, c.margin).padding(.top, 16 * c.s)
        }, dock: {
            NPDock(c, left: { HStack(spacing: 4) { NPActions(size: 44) } }, right: { NPCluster(showsChip: false) })
        })
        .background { backdrop }
    }

    /// The cover is the picture: laid over the whole window, softened, with a veil so the words keep their contrast.
    private var backdrop: some View {
        ZStack {
            Brand.panel
            if let img = m.hero.image ?? m.focusItem?.thumb {
                Image(nsImage: img).resizable().scaledToFill().blur(radius: 6).clipped()
            }
            // strong enough that the theme's ink keeps its contrast over any cover, light or dark
            LinearGradient(colors: [Brand.panel.opacity(0.62), Brand.panel.opacity(0.88)], startPoint: .top, endPoint: .bottom)
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

/// The album's colours behind the carousel: the cover blurred far past recognition and tinted, under a veil of the theme's own surface so the words keep their contrast
/// on dark, light and Paper looks. Drawn once into a flat layer (no work per frame) and cross-faded when the song changes.
struct CarouselBackdrop: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        let light = m.theme.isLight
        ZStack {
            Brand.panel
            if let img = m.hero.image ?? m.focusItem?.thumb {
                Image(nsImage: img).resizable().scaledToFill().scaleEffect(1.5).blur(radius: 80).saturation(1.35).opacity(light ? 0.5 : 0.6)
                    .id(m.focusItem?.id).transition(.opacity)
            } else {
                LinearGradient(colors: [m.hero.palette.accent.color.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
            }
            Rectangle().fill(Brand.panel.opacity(light ? 0.45 : 0.4))
            LinearGradient(colors: [.clear, Brand.panel.opacity(0.55)], startPoint: .center, endPoint: .bottom)
        }
        .clipped().drawingGroup()
        .animation(.easeInOut(duration: 0.8), value: m.focusItem?.id)
        .ignoresSafeArea().allowsHitTesting(false)
    }
}

struct NPCarousel: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo
    @ObservedObject private var service = LyricsService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The songs around the current one: `offset` 0 is the current song, negative before it, positive after it (missing at the ends of the queue).
    private func slot(_ offset: Int) -> QueueItem? {
        let items = m.items
        guard let id = m.current?.id ?? m.focusItem?.id, let i = items.firstIndex(where: { $0.id == id }) else { return offset > 0 && items.indices.contains(offset - 1) ? items[offset - 1] : nil }
        return items.indices.contains(i + offset) ? items[i + offset] : nil
    }

    private var hasLyrics: Bool { m.look.showLyrics && service.phase == .ready && service.lyrics?.isEmpty == false }

    var body: some View {
        NPFrame(c, content: { size in
            flow(size).padding(.horizontal, c.margin).padding(.top, 14 * c.s)
        }, dock: {
            NPDock(c, seek: .slim, left: { HStack(spacing: 4) { NPActions(size: 44) } }, right: { NPCluster(showsChip: false) })
        })
        .background { CarouselBackdrop() }
    }

    /// Cover flow: the covers (flexible), the names, the tag row, the words, in fixed zones that cannot overlap. The seek bar and transport are the dock below.
    private func flow(_ size: CGSize) -> some View {
        let s = c.s
        let plan = NPCoverFlowPlan.make(width: size.width - 2 * c.margin, height: size.height - 14 * s, s: s, lyrics: hasLyrics)
        let current = m.current?.id ?? m.focusItem?.id
        return VStack(spacing: plan.gap) {
            // the covers: the current one large, the neighbours smaller and fading on the same baseline
            ZStack {
                ForEach(plan.offsets, id: \.self) { o in
                    if o == 0 { NPCover(side: plan.centre, radius: 18).transition(.opacity) }
                    else if let item = slot(o) {
                        let side = plan.side(o)
                        Button { jump(to: o, item) } label: {
                            CoverView(image: item.thumb, palette: ArtPalette.fallback(seed: item.album.isEmpty ? item.title : item.album), corner: 14, symbol: "music.note").frame(width: side, height: side)
                        }
                        .buttonStyle(.plain).opacity(plan.opacity(o)).onAppear { m.requestMetadata(item.id) }
                        .accessibilityLabel("Play \(item.title)")
                        .offset(x: plan.x(o), y: (plan.centre - side) / 2)
                        .id(item.id).transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity).frame(height: plan.coverRow)
            .animation(reduceMotion ? nil : Motion.carpet, value: current)
            // the names, one line each
            VStack(spacing: 2 * s) {
                Text(m.focusDisplay?.title ?? "Nothing playing").npFont(34, .semibold).lineLimit(1).truncationMode(.tail)
                Text(m.focusDisplay?.artist ?? "").npFont(19).foregroundStyle(Brand.inkSecondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity).frame(height: plan.namesHeight)
            NPTags(alignment: .center).frame(height: plan.tagsHeight)
            // the words: a fixed block, the current line sharp, the others faded, with a soft fade at the edges; or one quiet line
            Group {
                if hasLyrics {
                    GeometryReader { g in NPLyrics(style: LyricStyle(size: 26 * min(1.2, max(0.85, s)), centered: true, gap: 8, rest: 0.5, blurs: false), height: g.size.height) }
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                } else {
                    Text("No lyrics").npFont(14).foregroundStyle(Brand.inkTertiary).frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(height: plan.lyricsHeight)
        }
        .frame(height: size.height - 14 * s, alignment: .top)
    }

    private func jump(to offset: Int, _ item: QueueItem) {
        if offset == 1 { m.player.send(.next) } else if offset == -1 { m.player.send(.previous) } else { m.play(item.id) }
    }
}

/// "Up next" as a column: the heading with how many songs are queued, and the next few songs (Classic, when the window is wide).
struct NPQueueColumn: View {
    @EnvironmentObject var m: PlayerModel
    var limit = 6
    var body: some View {
        let queued = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: 999).count
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Up next").npFont(19, .medium); Spacer(); Text(queued == 0 ? "" : "\(queued) queued").npFont(12.5).foregroundStyle(Brand.inkSecondary) }
            NPUpNext(limit: limit, cover: 44, titleSize: 15)
            Spacer(minLength: 0)
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

// MARK: - Chillax

struct NPChillax: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo

    var body: some View {
        NPFrame(c, content: { size in
            body(size).padding(.horizontal, c.margin).padding(.top, 14 * c.s)
        }, dock: {
            NPDock(c, seek: .slim, rowHeight: 70, left: { Color.clear.frame(width: 1, height: 1) }, right: { NPCluster(showsChip: false) })
        })
    }

    private func body(_ size: CGSize) -> some View {
        let s = c.s
        let queued = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: NPChillaxPlan.maxSongs).count
        let plan = NPChillaxPlan.make(inner: size.width - 2 * c.margin, height: size.height - 14 * s, s: s, queued: queued)
        let shelfHeight = plan.shelfHeight
        let side = plan.coverSide
        return VStack(alignment: .leading, spacing: 12 * s) {
            HStack(alignment: .top, spacing: 56 * s) {
                NPCover(side: side, radius: 30)
                VStack(alignment: .leading, spacing: 14 * s) {
                    NPTitleBlock(titleSize: 76, artistSize: 22, showsAlbumYear: true, credits: true, tags: true, compactTags: size.width - 2 * c.margin - side - 56 * s < 470, actions: 44)
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
                    NPShelf(limit: plan.limit, columns: plan.columns)
                }
                .frame(height: shelfHeight, alignment: .topLeading).clipped()
            }
        }
    }

    private var note: String {
        let n = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: 999).count
        return n == 0 ? "" : "\(n) song\(n == 1 ? "" : "s") queued"
    }
}

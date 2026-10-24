import SwiftUI
import AppKit

// The pieces every layout of Now Playing is made of: the cover, the title block, the heart / add-to-playlist / more buttons, the tags, the credits, the
// queue as a list or a shelf, the signal path, the seek line, the transport and the cluster on the right. A layout only decides where they go.

// MARK: - Scale

private struct NPScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    /// How large the layout is drawn compared with the 1440 × 900 it was designed at (never below 0.62 or above 1.25).
    var npScale: CGFloat {
        get { self[NPScaleKey.self] }
        set { self[NPScaleKey.self] = newValue }
    }
}

enum NPScale {
    static func of(_ size: CGSize) -> CGFloat { min(1.25, max(0.62, min(size.width / 1440, size.height / 900))) }
}

private struct NPFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.npScale) private var s
    func body(content: Content) -> some View { content.font(Typo.face(size * s * CGFloat(Look.current.textScale), weight == .regular ? Typo.sansWeight(.regular) : Typo.sansWeight(.medium))) }
}
extension View {
    /// Text at a designed size (scaled to the window) in the interface face: `.regular` is the weight the listener chose, anything heavier is Medium.
    func npFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View { modifier(NPFontModifier(size: size, weight: weight)) }
}

// MARK: - Cover

struct NPCover: View {
    @EnvironmentObject var m: PlayerModel
    let side: CGFloat
    var radius: CGFloat = 16
    var body: some View {
        let item = m.focusItem
        CoverView(image: m.hero.image ?? item?.thumb, palette: m.hero.palette, corner: radius, symbol: item?.isStream == true ? "dot.radiowaves.left.and.right" : "music.note")
            .id(m.hero.token).transition(.opacity)
            .stageMatched(.cover)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            .animation(Motion.carpet, value: m.hero.token)
            .accessibilityElement(children: .ignore).accessibilityLabel("Cover")
    }
}

// MARK: - Title block

/// The title and the names under it: artist and album on one line, the credits as a sentence and the tags.
struct NPTitleBlock: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo
    var titleSize: CGFloat = 44
    var artistSize: CGFloat = 20
    var showsAlbumYear = false
    var credits = true
    var tags = true
    var centered = false
    /// The heart, add-to-playlist and more buttons at the right of the title (at this size), or none.
    var actions: CGFloat? = nil

    var body: some View {
        let d = m.focusDisplay, item = m.focusItem
        VStack(alignment: centered ? .center : .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(d?.title ?? "Nothing playing").npFont(titleSize, .medium).tracking(-0.6).lineLimit(2).minimumScaleFactor(0.55).foregroundStyle(Brand.ink)
                    .multilineTextAlignment(centered ? .center : .leading)
                if let actions { NPActions(size: actions).padding(.top, max(0, titleSize * 0.12)) }
            }
            if let d, !d.artist.isEmpty || !(item?.album ?? "").isEmpty {
                (Text(d.artist).foregroundStyle(Brand.ink) + Text(albumTail(item)).foregroundStyle(Brand.inkSecondary))
                    .npFont(artistSize, .medium).lineLimit(2).padding(.top, 2).multilineTextAlignment(centered ? .center : .leading)
            }
            if credits, m.look.showCredits {
                let line = NPCredits.line(info.credits)
                if !line.isEmpty { Text(line).npFont(13.5).foregroundStyle(Brand.inkSecondary).lineLimit(2).padding(.top, 6).multilineTextAlignment(centered ? .center : .leading) }
            }
            if tags, m.look.showSignalTags { NPTags(alignment: centered ? .center : .leading).padding(.top, 10) }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func albumTail(_ item: QueueItem?) -> String {
        guard let item, !item.album.isEmpty else { return "" }
        var parts = [item.album]
        if showsAlbumYear, let y = item.year { parts.append(String(y)) }
        return "  ·  " + parts.joined(separator: "  ·  ")
    }
}

struct NPTags: View {
    var alignment: Alignment = .leading
    var body: some View {
        NowPlayingTags(place: .bar, alignment: alignment).frame(maxWidth: .infinity, alignment: alignment)
            .accessibilityElement(children: .contain).accessibilityIdentifier("np.tags")
    }
}

// MARK: - Heart, add to playlist, more

struct NPActions: View {
    @EnvironmentObject var m: PlayerModel
    var size: CGFloat = 44
    @Environment(\.npScale) private var s

    var body: some View {
        let path = m.focusItem.flatMap { $0.isStream ? nil : $0.path }
        HStack(spacing: 2) {
            NPHeart(path: path, size: size * s)
            if m.look.showPlaylistButton { NPPlaylistButton(path: path, size: size * s) }
            NPMoreMenu(size: size * s)
        }
    }
}

struct NPHeart: View {
    @EnvironmentObject var c: CollectionsModel
    let path: String?
    let size: CGFloat
    var body: some View {
        let on = path.map { c.isLiked($0) } ?? false
        Button { if let path { c.toggleLike(path: path) } } label: { Image(systemName: on ? "heart.fill" : "heart") }
            .buttonStyle(RoundIconStyle(on: on, size: size)).disabled(path == nil)
            .help(on ? "Remove from Liked Songs" : "Add to Liked Songs").accessibilityLabel(on ? "Remove from Liked Songs" : "Add to Liked Songs")
    }
}

/// The button that opens the playlist card.
struct NPPlaylistButton: View {
    let path: String?
    let size: CGFloat
    @StateObject private var open = Box(false)
    var body: some View {
        Button { open.v.toggle() } label: { Image(systemName: "text.badge.plus") }
            .buttonStyle(RoundIconStyle(on: open.v, size: size)).disabled(path == nil)
            .help("Add to a playlist").accessibilityLabel("Add to a playlist")
            .popover(isPresented: Binding(get: { open.v }, set: { open.v = $0 }), arrowEdge: .bottom) { if let path { PlaylistPicker(path: path) } }
    }
}

/// "Add to playlist": a card with a search, New playlist and the playlists, each ticked when the song is in it; a tap adds or takes it out.
struct PlaylistPicker: View {
    @EnvironmentObject var c: CollectionsModel
    let path: String
    @StateObject private var query = Box("")
    @StateObject private var track = Box<TrackDTO?>(nil)
    @StateObject private var member = Box(Set<String>())
    @StateObject private var changes = Box(0)

    private var shown: [PlaylistDTO] {
        let q = query.v.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? c.playlists : c.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add to playlist").font(Typo.sans(16, .medium))
                Spacer(minLength: 8)
                Text(track.v?.title ?? "").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary)
                TextField("Find a playlist", text: $query.v).textFieldStyle(.plain).font(Typo.sans(14))
            }
            .padding(.horizontal, 12).frame(height: 36).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.ink.opacity(0.08)))
            Button { newPlaylist() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(Typo.sans(16, .medium)).foregroundStyle(Brand.accentText).frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink.opacity(0.08)))
                    Text("New playlist").font(Typo.sans(15))
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(shown) { p in
                        let on = member.v.contains(p.id)
                        Button { toggle(p, on) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list").font(Typo.sans(15)).foregroundStyle(Brand.inkSecondary).frame(width: 40, height: 40)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink.opacity(0.08)))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).font(Typo.sans(15)).lineLimit(1)
                                    Text("\(p.trackCount) song\(p.trackCount == 1 ? "" : "s")").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(Typo.sans(18)).foregroundStyle(on ? Brand.accent : Brand.ink.opacity(0.3))
                            }
                            .padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(p.name).accessibilityValue(on ? "contains this song" : "does not contain this song")
                    }
                    if shown.isEmpty { Text(c.playlists.isEmpty ? "No playlists yet." : "No playlist matches.").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).padding(.vertical, 12) }
                }
            }
            .frame(maxHeight: 270)
            HStack {
                Text(changes.v == 0 ? "" : "Changed \(changes.v) playlist\(changes.v == 1 ? "" : "s")").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
                Spacer()
            }
        }
        .padding(16).frame(width: 330).foregroundStyle(Brand.ink).background(Brand.panel2)
        .onAppear { load() }
    }

    private func load() {
        guard let store = c.store else { return }
        let p = path
        Task.detached(priority: .userInitiated) {
            let t = store.track(path: p), ids = store.playlistIDs(containing: p)
            await MainActor.run { track.v = t; member.v = ids }
        }
    }

    private func toggle(_ p: PlaylistDTO, _ on: Bool) {
        guard let t = track.v else { return }
        if on { c.remove([t], from: p.id); member.v.remove(p.id) } else { c.add([t], to: p.id); member.v.insert(p.id) }
        changes.v += 1
    }

    private func newPlaylist() {
        guard let t = track.v, let name = promptForText(title: "New Playlist", message: "“\(t.title)” will be added to it.", placeholder: "Playlist name", confirm: "Create"),
              let p = c.create(name: name, with: [t]) else { return }
        member.v.insert(p.id); changes.v += 1
    }
}

/// More: the analyser and the booklet (they open beside the layout), the lyrics switch and the choice of layout.
struct NPMoreMenu: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    let size: CGFloat
    var body: some View {
        Menu {
            Button("Analyser", systemImage: "waveform") { stage.toggle(.analyser) }
            Button("Booklet", systemImage: "book") { stage.toggle(.booklet) }
            Divider()
            Toggle("Show lyrics", isOn: Binding(get: { m.look.showLyrics }, set: { m.look.showLyrics = $0 }))
            Picker("Layout", selection: Binding(get: { NowPlayingLayout.resolve(m.look.nowPlayingLayout) }, set: { m.look.nowPlayingLayout = $0.rawValue })) {
                ForEach(NowPlayingLayout.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Image(systemName: "ellipsis").font(Typo.sans(16)).foregroundStyle(Brand.inkSecondary).frame(width: size, height: size).contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("More").accessibilityLabel("More")
    }
}

// MARK: - Credits

/// The credits as label over value, in `columns` columns.
struct NPCreditsGrid: View {
    let lines: [NPCredit]
    var columns = 3
    var gap: CGFloat = 16
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .topLeading), count: columns), alignment: .leading, spacing: gap) {
            ForEach(lines) { l in
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary)
                    Text(l.value).npFont(14.5).lineLimit(2)
                }
            }
        }
    }
}

struct NPNoCredits: View {
    var body: some View { Text("No credits are tagged on this song.").npFont(14).foregroundStyle(Brand.inkSecondary) }
}

// MARK: - Up next

/// The queue after the song that plays: a list (cover, title, artist) or a shelf of cards. A tap plays it.
struct NPUpNext: View {
    @EnvironmentObject var m: PlayerModel
    var limit = 5
    var cover: CGFloat = 44
    var titleSize: CGFloat = 15.5
    @Environment(\.npScale) private var s

    var body: some View {
        let next = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: limit)
        VStack(alignment: .leading, spacing: 4) {
            if next.isEmpty { Text("Nothing is queued after this song.").npFont(14).foregroundStyle(Brand.inkSecondary).padding(.vertical, 8) }
            ForEach(next) { it in
                NPQueueRow(item: it, cover: cover * s, titleSize: titleSize) { m.play(it.id) }
            }
        }
    }
}

struct NPQueueRow: View {
    @EnvironmentObject var m: PlayerModel
    let item: QueueItem
    let cover: CGFloat
    let titleSize: CGFloat
    let play: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: play) {
            HStack(spacing: 14) {
                CoverView(image: item.thumb, palette: ArtPalette.fallback(seed: item.album.isEmpty ? item.title : item.album), corner: 8, symbol: item.isStream ? "dot.radiowaves.left.and.right" : "music.note")
                    .frame(width: cover, height: cover)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).npFont(titleSize).lineLimit(1)
                    Text(item.artist.isEmpty ? item.album : item.artist).npFont(13).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .onAppear { m.requestMetadata(item.id) }
        .accessibilityLabel("Play \(item.title)")
    }
}

/// The queue as a row of cards along the bottom (Chillax).
struct NPShelf: View {
    @EnvironmentObject var m: PlayerModel
    var limit = 5
    @Environment(\.npScale) private var s
    var body: some View {
        let next = NPQueue.upNext(m.items, current: m.current?.id ?? m.focusItem?.id, limit: limit)
        if next.isEmpty { Text("Nothing is queued after this song.").npFont(14).foregroundStyle(Brand.inkSecondary) }
        else {
            HStack(spacing: 14) {
                ForEach(next) { it in NPShelfCard(item: it, cover: 52 * s) { m.play(it.id) } }
                ForEach(0..<max(0, limit - next.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
            }
        }
    }
}

struct NPShelfCard: View {
    @EnvironmentObject var m: PlayerModel
    let item: QueueItem
    let cover: CGFloat
    let play: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                CoverView(image: item.thumb, palette: ArtPalette.fallback(seed: item.album.isEmpty ? item.title : item.album), corner: 12, symbol: "music.note").frame(width: cover, height: cover)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).npFont(15.5).lineLimit(1)
                    Text(item.artist.isEmpty ? item.album : item.artist).npFont(13).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.animation(Motion.touch, value: hover.v)
        .onAppear { m.requestMetadata(item.id) }
        .accessibilityLabel("Play \(item.title)")
    }
}

// MARK: - Signal path

struct NPSignalSteps: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        let steps = NPSignal.steps(source: m.status.sourceInfo, output: m.status.info, stages: m.status.pipeline, bitPerfect: m.status.bitPerfect, exclusive: m.exclusive, device: m.status.deviceName)
        VStack(alignment: .leading, spacing: 0) {
            if steps.isEmpty { Text("Play a song to see where its sound goes.").npFont(14).foregroundStyle(Brand.inkSecondary) }
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, st in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle().fill(Brand.accent).frame(width: 9, height: 9).padding(.top, 5)
                        if i < steps.count - 1 { Rectangle().fill(Brand.ink.opacity(0.18)).frame(width: 1.5).frame(maxHeight: .infinity) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(st.title).npFont(15, .medium)
                        Text(st.detail).npFont(14).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, i < steps.count - 1 ? 14 : 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct NPSignalLine: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        if m.look.showSignalTags { line }
    }

    @ViewBuilder private var line: some View {
        let line = NPSignal.line(source: m.status.sourceInfo, output: m.status.info, stages: m.status.pipeline, bitPerfect: m.status.bitPerfect, exclusive: m.exclusive, device: m.status.deviceName)
        if !line.isEmpty {
            HStack(spacing: 10) {
                Circle().fill(m.status.bitPerfect ? Brand.accent : Brand.caution).frame(width: 8, height: 8)
                Text(line).npFont(14).foregroundStyle(Brand.inkSecondary).lineLimit(2)
            }
        }
    }
}

// MARK: - Seek, transport, cluster

struct NPSeek: View {
    enum Style { case waveform, slim }
    @EnvironmentObject var m: PlayerModel
    var style = Style.waveform
    var remaining = false

    /// The layout's own bar, unless the listener chose one for all of them.
    private var shown: Style {
        switch m.look.seekChoice { case .layout: style; case .waveform: .waveform; case .line: .slim }
    }

    var body: some View {
        VStack(spacing: 2) {
            if shown == .waveform {
                WaveformScrubber(style: .line, tint: Brand.accent).stageMatched(.waveform)
                HStack { BarTime(remaining: false); Spacer(); BarTime(remaining: true) }
            } else {
                HStack(spacing: 14) {
                    BarTime(remaining: false)
                    WaveformScrubber(style: .slim, tint: Brand.accent).stageMatched(.waveform)
                    BarTime(remaining: true)
                }
            }
        }
    }
}

struct NPTransport: View {
    @EnvironmentObject var m: PlayerModel
    @Environment(\.npScale) private var s
    var body: some View {
        HStack(spacing: 14 * s) {
            ShuffleButton(size: 16, tint: Brand.inkSecondary)
            Button { m.player.send(.previous) } label: { TransportGlyph(kind: .previous, size: 17) }
                .keyboardShortcut(.leftArrow, modifiers: .command).help("Previous").accessibilityLabel("Previous")
            Button { m.togglePlay() } label: { TransportGlyph(kind: m.isActive && m.status.state == .playing ? .pause : .play, size: 22) }
                .buttonStyle(PlayKeyStyle(size: 64 * s)).keyboardShortcut(.space, modifiers: []).help("Play / pause")
                .accessibilityLabel(m.isActive && m.status.state == .playing ? "Pause" : "Play")
            Button { m.player.send(.next) } label: { TransportGlyph(kind: .next, size: 17) }
                .keyboardShortcut(.rightArrow, modifiers: .command).help("Next").accessibilityLabel("Next")
            RepeatButton(size: 16, tint: Brand.inkSecondary)
        }
        .buttonStyle(TransportButtonStyle(size: 13, ink: Brand.ink)).disabled(m.items.isEmpty)
    }
}

/// The output chip, the queue, the mini player and the volume. When there is not room for all of it the chip goes first, then the volume slider shrinks and
/// then goes; the buttons stay.
struct NPCluster: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    var showsChip = true
    var volumeWidth: CGFloat = 96

    private func buttons(volume: CGFloat?, chip: Bool) -> some View {
        HStack(spacing: 4) {
            if chip { OutputChip(anchor: .stage).padding(.trailing, 6) }
            Button { stage.toggle(.queue) } label: { Image(systemName: "list.bullet") }
                .buttonStyle(RoundIconStyle(on: stage.panel == .queue)).help("Queue").accessibilityLabel("Queue")
            Button { m.mini.toggle() } label: { Image(systemName: "pip") }
                .buttonStyle(RoundIconStyle(on: m.mini.isFloatingOpen)).help("Mini player").accessibilityLabel("Mini player")
            if let volume { Color.clear.frame(width: 4); VolumeControl(width: volume, readout: false) }
        }
        .fixedSize()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if showsChip { buttons(volume: volumeWidth, chip: true) }
            buttons(volume: volumeWidth, chip: false)
            buttons(volume: volumeWidth * 0.6, chip: false)
            buttons(volume: nil, chip: false)
        }
    }
}

// MARK: - Tabs and lyrics

struct NPTabs: View {
    @Binding var selection: NowPlayingTab
    var centered = true
    var body: some View {
        HStack(spacing: 6) {
            ForEach(NowPlayingTab.allCases) { t in
                Button { withAnimation(TabMotion.animation) { selection = t } } label: {
                    Text(t.title).npFont(16, selection == t ? .medium : .regular)
                        .foregroundStyle(selection == t ? Brand.ink : Brand.inkSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(selection == t ? Brand.ink.opacity(0.12) : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityAddTraits(selection == t ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

/// The words, without a frame, in the given style, filling the height it is given.
struct NPLyrics: View {
    let style: LyricStyle
    let height: CGFloat
    @Environment(\.npScale) private var s
    var body: some View {
        var scaled = style
        scaled.size = style.size * s * Look.current.lyricSize.scale; scaled.gap = style.gap * s * Look.current.lyricSize.scale
        return LyricsSection(availableHeight: height, chrome: false).environment(\.lyricStyle, scaled).frame(height: height).clipped()
    }
}

// MARK: - Panels

/// The side panel (queue, analyser, booklet) laid over a layout, on a raised card.
struct NPPanelOverlay: View {
    @EnvironmentObject var stage: StageModel
    var body: some View {
        if let panel = stage.panel, panel != .lyrics {
            GalleryPanelView(panel: panel)
                .background(Brand.panel2)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous).strokeBorder(Brand.rule, lineWidth: 1))
                .frame(width: 400).padding(.vertical, 72).padding(.trailing, 20).padding(.bottom, 130)
                .transition(.opacity.animation(TabMotion.animation))
        }
    }
}

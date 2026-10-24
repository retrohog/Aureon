import SwiftUI

// Now Playing as the whole window. Which of the layouts is drawn (Stage, Classic, Full-bleed, Carousel, Lumen, Chillax) is the listener's choice in
// Settings → Now Playing; each is its own view (Pulse/NowPlaying). The queue, the analyser and the booklet open as a card over the layout.

/// The panels that open beside the cover.
enum GalleryPanel: String, CaseIterable, Identifiable {
    case lyrics, queue, signal, analyser, booklet
    var id: String { rawValue }
    var title: String {
        switch self { case .lyrics: "Lyrics"; case .queue: "Queue"; case .signal: "Signal path"; case .analyser: "Analyser"; case .booklet: "Booklet" }
    }
    var icon: String {
        switch self { case .lyrics: "quote.bubble"; case .queue: "list.bullet"; case .signal: "point.topleft.down.curvedto.point.bottomright.up"; case .analyser: "waveform"; case .booklet: "book" }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var info = NPTrackInfo()

    private var layout: NowPlayingLayout { NowPlayingLayout.resolve(m.look.nowPlayingLayout) }
    /// Whether the words are on screen: on in the layout, and (where the layout has tabs) the Lyrics tab is the one open.
    private var wantsLyrics: Bool { m.look.showLyrics && (!layout.hasTabs || stage.npTab == .lyrics) }

    var body: some View {
        GeometryReader { geo in
            let canvas = NPCanvas(size: geo.size)
            ZStack(alignment: .trailing) {
                Group {
                    switch layout {
                    case .stage: NPStage(c: canvas)
                    case .classic: NPClassic(c: canvas)
                    case .fullBleed: NPFullBleed(c: canvas)
                    case .carousel: NPCarousel(c: canvas)
                    case .lumen: NPLumen(c: canvas)
                    case .chillax: NPChillax(c: canvas)
                    }
                }
                .environment(\.npScale, canvas.s)
                NPPanelOverlay()
            }
            // the lyrics lookup starts from the screen, which is always there (the words are empty until they are asked to show)
            .task(id: LyricsDriver.trigger(for: m, show: wantsLyrics)) { await LyricsDriver.ask(m, show: wantsLyrics) }
        }
        .environmentObject(info)
        .onAppear { info.load(path: songPath, store: m.library.store); m.prefetchUpcomingArtwork() }
        .onChange(of: songPath) { _, p in info.load(path: p, store: m.library.store); m.prefetchUpcomingArtwork() }
        .onChange(of: m.items.count) { _, _ in m.prefetchUpcomingArtwork() }
        // Escape closes an open panel, and otherwise leaves for the page Now Playing was opened from
        .background(Button("") { if stage.panel != nil { stage.panel = nil } else { stage.close(m, reduceMotion: reduceMotion) } }
            .keyboardShortcut(.escape, modifiers: []).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
    }

    private var songPath: String? { m.focusItem.flatMap { $0.isStream ? nil : $0.path } }
}

// MARK: - The panels

/// The side panel: lyrics, the queue, or one of the quieter tools, in a hairline frame.
struct GalleryPanelView: View {
    @EnvironmentObject var stage: StageModel
    let panel: GalleryPanel

    var body: some View {
        GeometryReader { g in
            // the panels change through the shared tab container: the one that leaves drifts away as the next one comes in
            TabSwitcher(tag: panel) { p in
                Group {
                    switch p {
                    case .lyrics: LyricsSection(availableHeight: g.size.height, onClose: close)
                    case .queue: QueueView(dropping: false, onClose: close)
                    case .signal: PanelPage(title: "Signal path", close: close) { VStack(alignment: .leading, spacing: 32) { ReadoutBlock(); SignalPathView() } }
                    case .analyser: AnalyserPanelPage(close: close)
                    case .booklet: PanelPage(title: "Booklet", close: close) { BookletSection() }
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
        }
        .glassAccent(flat: Brand.ink.opacity(0.03))
        .accessibilityElement(children: .contain).accessibilityLabel(panel.title)
    }

    private func close() { stage.panel = nil }
}

/// A titled page inside the panel: the header stays put (its scrim appears once the content has scrolled under it) and the content scrolls.
private struct PanelPage<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    @StateObject private var scrolled = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).kicker().foregroundStyle(Brand.inkSecondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("Close").accessibilityLabel("Close \(title)")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .scrim(scrolledUnder: scrolled.v)
            .zIndex(1)
            ScrollView(showsIndicators: false) { content.padding(16) }
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 2 } action: { _, now in if scrolled.v != now { scrolled.v = now } }
        }
    }
}


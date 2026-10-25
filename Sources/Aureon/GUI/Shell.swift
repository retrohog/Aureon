import SwiftUI
import AppKit

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var dropping = Box(false)
    @StateObject private var stage: StageModel
    @StateObject private var idle = IdleTracker()
    @StateObject private var chrome = ChromeState()
    @Namespace private var stageSpace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @MainActor init(stage: StageModel? = nil) { _stage = StateObject(wrappedValue: stage ?? StageModel()) }

    /// The rail and, for a destination with several pages, its quiet sub-header: what the pages below it keep clear of.
    private var chromeHeight: CGFloat { chromeHeight(for: m.tab) }
    private func chromeHeight(for tab: Tab) -> CGFloat { ChromeInset.height(hasSubNav: !RailDestination.of(tab).subNav.isEmpty, hasThirdNav: tab == .audio && !m.djMode) }
    /// Atelier → Sound has its own line of tabs under the sub-header.
    private var showsSoundTabs: Bool { m.tab == .audio && !m.djMode }
    /// Pages that scroll under the chips through `PageScaffold` bring their own inset; the others are kept below it.
    private func pageKeepsOwnInset(_ tab: Tab) -> Bool { true }
    private var barIsGlass: Bool { false }

    var body: some View {
        ZStack {
            Brand.window
            if m.djMode {
                DJView().transition(.opacity)
            } else {
                shell.transition(.opacity)
            }
            if m.showDropToast, let t = m.current ?? m.focusItem {
                VStack {
                    HStack(spacing: 8) {
                        EqualizerBars(active: true, color: Brand.accent).frame(width: 14, height: 12)
                        Text("Playing “\(t.title)”").font(Typo.sans(12.5, .semibold)).lineLimit(1)
                        if m.items.count > 1 { Text("+\(m.items.count - 1) queued").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Slab().fill(.regularMaterial)).overlay(Slab().strokeBorder(Brand.ink.opacity(0.15), lineWidth: 0.8))
                    Spacer()
                }.padding(.top, 16).transition(.move(edge: .top).combined(with: .opacity)).allowsHitTesting(false)
            }
            if let offer = m.resumeOffer, !m.djMode {
                VStack { Spacer(); ResumeOfferCard(offer: offer) }.frame(maxWidth: .infinity, maxHeight: .infinity).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if m.showPalette {
                CommandPaletteView().transition(.opacity)
            }
            if dropping.v {
                RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous).strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
                    .background(RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous).fill(Brand.accent.opacity(0.1)))
                    .overlay(Label(m.djMode ? "Drop to load on a deck" : "Drop to play", systemImage: "play.circle.fill").font(Typo.t3.weight(.semibold)))
                    .padding(12).transition(.opacity).allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.container, edges: .top)           // the sidebar and pages run under the (transparent) title bar, so the window buttons sit inside the app
        .background(WindowChrome().frame(width: 0, height: 0))
        .alert("Save your DSP settings?", isPresented: Binding(get: { m.showDSPPrompt }, set: { _ in })) {
            Button("Save") { m.resolveDSPPrompt(save: true) }
            Button("Don't Save") { m.resolveDSPPrompt(save: false) }
            Button("Stay Here", role: .cancel) { m.cancelDSPPrompt() }
        } message: { Text("You changed the equalizer or plug-ins. Saved settings come back next time; if you don't save them they stay for this session only and are gone when Aureon quits.") }
        .alert("These settings clash", isPresented: Binding(get: { m.conflict != nil }, set: { _ in })) {
            Button(m.conflict?.fixLabel ?? "OK") { m.resolveConflict(accept: true) }
            Button("Cancel", role: .cancel) { m.resolveConflict(accept: false) }
        } message: { Text(m.conflict?.message ?? "") }
        .background(DuplicateSheetHost(lib: m.library))
        .animation(.easeOut(duration: 0.2), value: m.djMode)
        // page changes fade quickly, unless the change comes with its own animation (opening Now Playing from the bar springs)
        .transaction(value: m.tab) { t in if t.animation == nil { t.animation = TabMotion.animation } }
        // leaving Now Playing any other way (the rail, Back, DJ mode) ends its full-window state
        .onChange(of: m.tab) { old, tab in
            chrome.scrolled = false
            if tab == .player, old != .player { stage.returnTab = old }
            if tab != .player, stage.immersive { withAnimation(.easeOut(duration: 0.2)) { stage.immersive = false } }
        }
        .onChange(of: m.djMode) { _, dj in if dj, stage.immersive { stage.immersive = false } }
        .animation(.smooth(duration: 0.22), value: dropping.v)
        // popovers are drawn in a layer over the window so they can never hang outside it (the objects they need are added by the modifiers that follow)
        .overlay { WindowPopoverLayer(center: m.popovers) }
        .coordinateSpace(name: WindowPopovers.space)
        .environment(\.windowPopovers, m.popovers)
        .environmentObject(stage).environmentObject(idle).environmentObject(chrome).environment(\.stageNamespace, stageSpace)
        // pointer movement and keys wake the Gallery's rail and controls; a few quiet seconds put them away again
        .onContinuousHover { phase in if case .active = phase { idle.poke() } }
        .onKeyPress { _ in idle.poke(); return .ignored }
        .onAppear { idle.holdsAwake = { [unowned m] in m.tab != .player || m.djMode || m.status.state != .playing || m.showQueue }; idle.poke(); if ProcessInfo.processInfo.environment["AUREON_IDLE"] != nil { idle.rest() } }
        .environmentObject(m.albumArt).environmentObject(m.artistArt).environmentObject(m.progress).environmentObject(m.navigator)
        .environmentObject(m.radio).environmentObject(m.podcasts).environmentObject(m.dj).environmentObject(m.collections).environmentObject(m.dspModel).environmentObject(m.rip).environmentObject(m.convert).environmentObject(m.cloud).environmentObject(m.lms).environmentObject(m.cast).environmentObject(m.zone).environmentObject(m.speakers).environmentObject(m.bridge)
        .preferredColorScheme(m.theme.isLight ? .light : .dark)
        .foregroundStyle(Brand.ink)
        .tracking(Typo.bodyTracking)
        .toggleStyle(.rule)
        .environment(\.glassAccents, m.glassAccents)
        .environment(\.pageTransitions, m.pageTransitions)
        .environment(\.glassTint, m.backdrop == .album ? GlassPolicy.tint(for: m.hero.palette.accent) : nil)
        .background(Brand.window)
        .id(m.theme.id + "|\(m.lookRevision)")
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { dropping.v }, set: { dropping.v = $0 })) { providers in
            let group = DispatchGroup()
            let urls = DropURLs()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { MainActor.assumeIsolated { m.handleDrop(urls.all) } }
            return true
        }
    }

    /// The window: the top bar across it, the rail down the left, the main panel (rounded) and, beside it, the queue; the player bar underneath.
    /// Now Playing is the whole window: its page fills it, the bar rests and the rail and player bar are away.
    private var shell: some View {
        ZStack(alignment: .top) {
            if m.tab == .player {
                ZStack(alignment: .top) {
                    StageBackdrop(mode: m.backdrop, theme: m.theme, palette: m.hero.palette, image: m.hero.image, token: m.hero.token, stage: true, intensity: m.backdropIntensity)
                    TabSwitcher(tag: m.tab) { tab in page(for: tab).environment(\.chromeInset, 0).frame(maxWidth: .infinity, maxHeight: .infinity).clipped() }
                }
                PulseTopBar()
            } else {
                VStack(spacing: 0) {
                    PulseTopBar()
                    HStack(spacing: 0) {
                        PulseRail()
                        mainPanel
                        if m.showQueue {
                            QueuePanel().padding(.leading, 8).transition(.opacity.animation(TabMotion.animation))
                        }
                    }
                    .padding(.trailing, 8)
                    // opacity only: the cover and waveform fly between the bar and Now Playing, and a sliding bar would drag them along
                    PlayerBar().transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.window)
    }

    /// The rounded panel pages live in: the backdrop, the page (scrolling under the chips of its destination) and the chips with their scrim.
    private var mainPanel: some View {
        ZStack(alignment: .top) {
            StageBackdrop(mode: m.backdrop, theme: m.theme, palette: m.hero.palette, image: m.hero.image, token: m.hero.token, stage: false, intensity: m.backdropIntensity)
            // every change of page goes through the one tab container (see `TabSwitcher`): the old page leaves, is not hit-testable at once and is gone when it ends
            TabSwitcher(tag: m.tab) { tab in
                page(for: tab)
                    .environment(\.scrollKey, "\(tab.rawValue)|\(m.library.selectedID ?? "")|\(tab == .settings ? m.settingsSection.rawValue : "")")
                    .environment(\.chromeInset, pageKeepsOwnInset(tab) ? chromeHeight(for: tab) : 0)
                    .padding(.top, pageKeepsOwnInset(tab) ? 0 : chromeHeight(for: tab))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            if !m.currentDestination.subNav.isEmpty {
                ChromeBar {
                    SubNavBar(destination: m.currentDestination).padding(.top, 8).transition(.opacity)
                    if showsSoundTabs { SoundTabBar().padding(.horizontal, 24).padding(.bottom, 4).transition(.opacity) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Brand.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    }

    @ViewBuilder private func page(for tab: Tab) -> some View {
        switch tab {
        case .home: HomePage()
        case .player: NowPlayingView()
        case .search: SmartSearchPage()
        case .radio: RadioPage()
        case .podcasts: PodcastsPage()
        case .liked: LikedPage()
        case .playlists: PlaylistsPage()
        case .albums, .artists, .songs, .composers, .works, .conductors, .ensembles: LibraryPage(lib: m.library, tab: m.tab)
        case .audio: PageScaffold(title: "Sound", subtitle: m.soundSection.blurb, ruled: false) { AudioTab() }
        case .rip: RipPage()
        case .convert: ConvertPage()
        case .cloud: CloudPage()
        case .folders: LibraryFoldersPage()
        case .abx: ABXPage()
        case .intelligence: PageScaffold(title: "Intelligence", subtitle: "Smart features, models and providers", ruled: false) { IntelligenceTab() }
        case .dsp: PageScaffold(title: "DSP", subtitle: "Parametric EQ and plug-ins", ruled: false) { DSPTab() }
        case .deepDive: PageScaffold(title: "Deep Dive", subtitle: "Credits, biographies and releases", ruled: false) { DeepDiveTab() }
        case .rooms: RoomsPage()
        case .settings: SettingsPage()
        }
    }
}

/// The fade between pages. A page that is on its way out must never answer clicks: when a page change overlaps another animation (closing Now Playing
/// while the sidebar returns), SwiftUI can leave the outgoing page in the hierarchy, invisible, still in its removed state. Its scroll view then covered
/// the whole window and swallowed every click meant for the sidebar. In the removed state it is therefore not hit-testable, so a leftover is harmless.
struct PageHitTesting: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View { content.allowsHitTesting(enabled) }
}
extension AnyTransition {
    static var pageSwap: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .modifier(active: PageHitTesting(enabled: false), identity: PageHitTesting(enabled: true))))
    }
}

/// Collects the dropped file addresses from the item providers' callbacks (which arrive on background threads).
final class DropURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func append(_ u: URL) { lock.lock(); list.append(u); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return list.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }
}

/// The queue as a panel inside the window, sliding in from the right above the player bar.
struct QueuePanel: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        QueueView(dropping: false, onClose: { m.showQueue = false })
            .frame(width: 340).frame(maxHeight: .infinity)
            .background(Brand.canvas)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    }
}

/// Back and Forward through everything visited: pages, albums, genres, shows. Plain chevrons, like a system toolbar.
struct NavButtons: View {
    @EnvironmentObject var nav: Navigator
    var body: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.16)) { nav.goBack() } } label: { Image(systemName: "chevron.left") }
                .disabled(!nav.canGoBack).keyboardShortcut("[", modifiers: .command).help("Back (⌘[)")
            Button { withAnimation(.easeOut(duration: 0.16)) { nav.goForward() } } label: { Image(systemName: "chevron.right") }
                .disabled(!nav.canGoForward).keyboardShortcut("]", modifiers: .command).help("Forward (⌘])")
        }
        .buttonStyle(IconButtonStyle())
    }
}

/// The layout switch: normal ⇄ DJ console. In the sidebar it is a row like the others; in the console it is a button in the header, so there is always a way back.
struct DJSwitch: View {
    @EnvironmentObject var m: PlayerModel
    var inSidebar = true
    @StateObject private var hover = Box(false)
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { m.djMode.toggle() } } label: {
            if inSidebar {
                HStack(spacing: 8) {
                    Image(systemName: "dial.medium").font(Typo.sans(13, .light)).frame(width: 20).foregroundStyle(Brand.inkSecondary)
                    Text("DJ Mode").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                .background(Rectangle().fill(Brand.ink.opacity(hover.v ? 0.04 : 0)))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.grid.2x2").font(Typo.sans(11, .semibold))
                    Text("Normal mode").font(Typo.sans(12, .semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(Brand.onAccent)
                .background(Slab().fill(Brand.accent))
            }
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.help(m.djMode ? "Back to the normal layout" : "Switch to the two-deck DJ console")
    }
}

// MARK: - Queue sidebar

struct QueueView: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var sel = Box(Set<UUID>())
    var dropping = false
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            QueueTabs()
            switch m.queueTab {
            case .queue: if m.items.isEmpty { empty } else { list }
            case .history: QueueHistory()
            case .output: QueueOutput()
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous).strokeBorder(m.hero.palette.accent.color.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous).fill(m.hero.palette.accent.color.opacity(0.12)))
                    .overlay(Label("Drop to add to the queue", systemImage: "plus.circle.fill").font(Typo.headline))
                    .padding(8).transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.smooth(duration: 0.22), value: dropping)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(m.queueTab.rawValue).font(Typo.serif(20, .semibold))
            if m.queueTab == .queue, !m.items.isEmpty { Text("\(m.items.count)").font(Typo.mono(12, .medium)).foregroundStyle(Brand.inkSecondary).contentTransition(.numericText()) }
            Spacer()
            switch m.queueTab {
            case .queue:
                Button { openPanel() } label: { Image(systemName: "plus") }.help("Add music (⌘O)")
                Button { withAnimation(.smooth) { m.clear() } } label: { Image(systemName: "trash") }.disabled(m.items.isEmpty).help("Clear queue")
            case .history:
                Button { withAnimation(.smooth) { m.clearPlayedLog() } } label: { Image(systemName: "trash") }.disabled(m.playedLog.entries.isEmpty).help("Clear the history")
            case .output: EmptyView()
            }
            if let onClose { Button(action: onClose) { Image(systemName: "xmark") }.help("Close") }
        }
        .buttonStyle(IconButtonStyle())
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
        .animation(.smooth, value: m.items.count)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(Typo.sans(38, .ultraLight)).foregroundStyle(Brand.inkSecondary)
            Text("Drop FLAC, ALAC, WAV, AIFF, DSF or DFF files\nor a folder here").multilineTextAlignment(.center).foregroundStyle(Brand.inkSecondary).font(Typo.callout)
            Button("Add Music…") { openPanel() }.buttonStyle(.solid).tint(m.hero.palette.accent.color).foregroundStyle(.black)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $sel.v) {
                ForEach(m.items) { item in
                    QueueRow(item: item, playing: m.isActive && item.id == m.status.trackID, paused: m.status.state == .paused, accent: m.hero.palette.accent.color)
                        .tag(item.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Play") { m.play(item.id) }
                            Button("Remove") { m.remove(ids: sel.v.contains(item.id) ? sel.v : [item.id]) }
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity.combined(with: .move(edge: .leading))))
                }
                .onMove { from, to in withAnimation(.snappy(duration: 0.28)) { m.move(from: from, to: to) } }
                .onDelete { m.remove(at: $0) }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .animation(.snappy(duration: 0.3), value: m.items.map(\.id))
            .onDeleteCommand { withAnimation(.snappy) { m.remove(ids: sel.v); sel.v = [] } }
            Text("Drag to reorder  ·  ⌫ removes  ·  safe while playing").font(Typo.sans(10.5)).foregroundStyle(Brand.inkTertiary).padding(8)
        }
    }

    private func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = true; p.canChooseFiles = true
        p.allowedContentTypes = [.audio, .folder]
        // after the button's action has returned: a modal loop run inside a SwiftUI action can leave the window unresponsive
        DispatchQueue.main.async { if p.runModal() == .OK { m.add(urls: p.urls) } }
    }
}

/// A compact queue cell: mini cover with a play affordance on hover, title and artist, a live equaliser for the playing track.
struct QueueRow: View {
    @EnvironmentObject var m: PlayerModel
    let item: QueueItem
    let playing: Bool
    let paused: Bool
    let accent: Color
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CoverView(image: item.thumb, palette: ArtPalette.fallback(seed: item.album.isEmpty ? item.title : item.album), corner: 6, symbol: item.isDSD ? "dot.radiowaves.left.and.right" : "music.note")
                if playing || hover.v {
                    Color.black.opacity(0.5).clipShape(RoundedRectangle(cornerRadius: Metrics.radius(6), style: .continuous))
                    if playing && !hover.v { EqualizerBars(active: !paused, color: accent).frame(width: 18, height: 16) }
                    else { Image(systemName: playing && !paused ? "pause.fill" : "play.fill").font(Typo.sans(13, .bold)).foregroundStyle(.white) }
                }
            }
            .frame(width: 42, height: 42)
            .onTapGesture { if playing { m.togglePlay() } else { m.play(item.id) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Typo.sans(13, playing ? .semibold : .medium)).foregroundStyle(playing ? accent : .primary).lineLimit(1)
                Text(subtitle).font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let n = item.trackNumber, hover.v || playing { Text("\(n)").font(Typo.mono(10.5)).foregroundStyle(Brand.inkTertiary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Metrics.radius(9), style: .continuous).fill(Brand.ink.opacity(playing ? 0.09 : (hover.v ? 0.06 : 0))))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.smooth(duration: 0.14)) { hover.v = h } }
        .onTapGesture { if playing { m.togglePlay() } else { m.play(item.id) } }
        .onAppear { m.requestMetadata(item.id) }
        .animation(.smooth(duration: 0.2), value: playing)
    }

    private var subtitle: String {
        let parts = [item.artist, item.album].filter { !$0.isEmpty }
        return parts.isEmpty ? item.url.pathExtension.uppercased() : parts.joined(separator: " — ")
    }
}

/// Three bars that bounce while the track plays and settle when paused.
struct EqualizerBars: View {
    let active: Bool
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let w = size.width / 5
                for i in 0..<3 {
                    let f = active ? 0.35 + 0.65 * abs(sin(t * (2.3 + Double(i) * 0.9) + Double(i))) : 0.25
                    let h = size.height * CGFloat(f)
                    ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * w * 2, y: size.height - h, width: w, height: h), cornerRadius: Metrics.radius(1.5)), with: .color(color))
                }
            }
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }
    private struct Inner: View {
        let configuration: Configuration
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.font(Typo.sans(15, .regular)).foregroundStyle(enabled ? (hover.v || configuration.isPressed ? Brand.ink : Brand.inkSecondary) : Brand.inkTertiary.opacity(0.6))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Brand.ink.opacity(configuration.isPressed ? 0.14 : (hover.v && enabled ? 0.08 : 0))))
                .contentShape(Circle())
                .animation(Motion.touch, value: hover.v).animation(Motion.touch, value: configuration.isPressed)
                .onHover { hover.v = $0 }
        }
    }
}

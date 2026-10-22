import SwiftUI
import AppKit

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var dropping = Box(false)
    @StateObject private var stage: StageModel
    @Namespace private var stageSpace

    @MainActor init(stage: StageModel? = nil) { _stage = StateObject(wrappedValue: stage ?? StageModel()) }

    /// Now Playing has taken the whole window: the sidebar is tucked away.
    private var immersive: Bool { stage.immersive && m.tab == .player }

    var body: some View {
        ZStack {
            Brand.canvas
            if m.djMode {
                DJView().transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    // always mounted: inserting and removing it with a transition could leave it drawn but not clickable after Now Playing closed
                    Sidebar()
                        .frame(width: 204, alignment: .leading)
                        .frame(width: immersive ? 0 : 204, alignment: .leading)
                        .clipped()
                        .opacity(immersive ? 0 : 1)
                        .allowsHitTesting(!immersive)
                        .accessibilityHidden(immersive)
                    ZStack(alignment: .bottom) {
                        StageBackdrop(palette: m.hero.palette, image: m.hero.image, token: m.hero.token, stage: m.tab == .player, light: m.theme.isLight)
                        page.id(m.tab).frame(maxWidth: .infinity, maxHeight: .infinity).padding(.trailing, m.showQueue ? 362 : 0)
                        // opacity only: the cover and waveform fly between the bar and Now Playing, and a sliding bar would drag them along
                        if m.tab != .player { PlayerBar().transition(.opacity) }
                    }
                }
                .transition(.opacity)
            }
            if m.showDropToast, let t = m.current ?? m.focusItem {
                VStack {
                    HStack(spacing: 8) {
                        EqualizerBars(active: true, color: Brand.accent).frame(width: 14, height: 12)
                        Text("Playing “\(t.title)”").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if m.items.count > 1 { Text("+\(m.items.count - 1) queued").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial)).overlay(Capsule().strokeBorder(Brand.ink.opacity(0.15), lineWidth: 0.8)).shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                    Spacer()
                }.padding(.top, 14).transition(.move(edge: .top).combined(with: .opacity)).allowsHitTesting(false)
            }
            if m.showQueue && !m.djMode {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    QueuePanel()
                }
                .padding(.top, WindowChrome.band - 8).padding(.trailing, 12).padding(.bottom, m.tab == .player ? 14 : PlayerBar.reserved + 12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if dropping.v {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.accent.opacity(0.1)))
                    .overlay(Label(m.djMode ? "Drop to load on a deck" : "Drop to play", systemImage: "play.circle.fill").font(.title3.weight(.semibold)))
                    .padding(10).transition(.opacity).allowsHitTesting(false)
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
        .animation(.smooth(duration: 0.28), value: m.showQueue)
        // page changes fade quickly, unless the change comes with its own animation (opening Now Playing from the bar springs)
        .transaction(value: m.tab) { t in if t.animation == nil { t.animation = .easeOut(duration: 0.16) } }
        // leaving Now Playing any other way (sidebar shortcut, Back, DJ mode) brings the sidebar back
        .onChange(of: m.tab) { old, tab in
            if tab == .player, old != .player { stage.returnTab = old }
            if tab != .player, stage.immersive { withAnimation(.easeOut(duration: 0.2)) { stage.immersive = false } }
        }
        .onChange(of: m.djMode) { _, dj in if dj, stage.immersive { stage.immersive = false } }
        .animation(.smooth(duration: 0.22), value: dropping.v)
        .environmentObject(stage).environment(\.stageNamespace, stageSpace)
        .environmentObject(m.albumArt).environmentObject(m.artistArt).environmentObject(m.progress).environmentObject(m.navigator)
        .environmentObject(m.radio).environmentObject(m.podcasts).environmentObject(m.dj).environmentObject(m.collections).environmentObject(m.dspModel).environmentObject(m.rip).environmentObject(m.convert).environmentObject(m.cloud).environmentObject(m.lms).environmentObject(m.cast).environmentObject(m.zone).environmentObject(m.speakers).environmentObject(m.bridge)
        .preferredColorScheme(m.theme.isLight ? .light : .dark)
        .foregroundStyle(Brand.ink)
        .background(Brand.canvas)
        .id(m.theme.id)
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

    @ViewBuilder private var page: some View {
        switch m.tab {
        case .home: HomePage()
        case .player: NowPlayingView()
        case .search: SmartSearchPage()
        case .radio: RadioPage()
        case .podcasts: PodcastsPage()
        case .liked: LikedPage()
        case .playlists: PlaylistsPage()
        case .albums, .artists, .songs, .composers, .works, .conductors, .ensembles: LibraryPage(lib: m.library, tab: m.tab)
        case .audio: PageScaffold(title: "Audio", subtitle: "Playback path and processing") { AudioTab() }
        case .rip: RipPage()
        case .convert: ConvertPage()
        case .cloud: CloudPage()
        case .folders: FolderBrowserPage()
        case .abx: ABXPage()
        case .intelligence: PageScaffold(title: "Intelligence", subtitle: "AI features, models and providers") { IntelligenceTab() }
        case .dsp: PageScaffold(title: "DSP", subtitle: "Parametric EQ and plug-ins") { DSPTab() }
        case .deepDive: PageScaffold(title: "Deep Dive", subtitle: "Credits, biographies and releases") { DeepDiveTab() }
        case .settings: SettingsPage()
        }
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
            .frame(width: 350).frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.sidebar.opacity(0.8)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.ink.opacity(0.14), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
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
                HStack(spacing: 9) {
                    Image(systemName: "dial.medium").font(.system(size: 14)).frame(width: 20).foregroundStyle(Brand.accent)
                    Text("DJ Mode").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.06 : 0)))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.grid.2x2").font(.system(size: 11, weight: .semibold))
                    Text("Normal mode").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(Color.white)
                .background(Capsule().fill(Brand.accent))
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
            if m.items.isEmpty { empty } else { list }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(m.hero.palette.accent.color.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(m.hero.palette.accent.color.opacity(0.12)))
                    .overlay(Label("Drop to add to the queue", systemImage: "plus.circle.fill").font(.headline))
                    .padding(8).transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.smooth(duration: 0.22), value: dropping)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Queue").font(.system(size: 20, weight: .semibold, design: .serif))
            if !m.items.isEmpty { Text("\(m.items.count)").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).contentTransition(.numericText()) }
            Spacer()
            Button { openPanel() } label: { Image(systemName: "plus") }.help("Add music (⌘O)")
            Button { withAnimation(.smooth) { m.clear() } } label: { Image(systemName: "trash") }.disabled(m.items.isEmpty).help("Clear queue")
            if let onClose { Button(action: onClose) { Image(systemName: "xmark") }.help("Close") }
        }
        .buttonStyle(IconButtonStyle())
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        .animation(.smooth, value: m.items.count)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("Drop FLAC, ALAC, WAV, AIFF, DSF or DFF files\nor a folder here").multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
            Button("Add Music…") { openPanel() }.buttonStyle(.borderedProminent).tint(m.hero.palette.accent.color).foregroundStyle(.black)
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
            Text("Drag to reorder  ·  ⌫ removes  ·  safe while playing").font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(8)
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
        HStack(spacing: 10) {
            ZStack {
                CoverView(image: item.thumb, palette: ArtPalette.fallback(seed: item.album.isEmpty ? item.title : item.album), corner: 6, symbol: item.isDSD ? "dot.radiowaves.left.and.right" : "music.note")
                if playing || hover.v {
                    Color.black.opacity(0.5).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    if playing && !hover.v { EqualizerBars(active: !paused, color: accent).frame(width: 18, height: 16) }
                    else { Image(systemName: playing && !paused ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
                }
            }
            .frame(width: 42, height: 42)
            .onTapGesture { if playing { m.togglePlay() } else { m.play(item.id) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: playing ? .semibold : .medium)).foregroundStyle(playing ? accent : .primary).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let n = item.trackNumber, hover.v || playing { Text("\(n)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.ink.opacity(playing ? 0.09 : (hover.v ? 0.06 : 0))))
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
                    ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * w * 2, y: size.height - h, width: w, height: h), cornerRadius: 1.5), with: .color(color))
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
            configuration.label.font(.system(size: 13, weight: .semibold)).foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Brand.ink.opacity(configuration.isPressed ? 0.18 : (hover.v && enabled ? 0.1 : 0))))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.smooth(duration: 0.15), value: hover.v).animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { hover.v = $0 }
        }
    }
}

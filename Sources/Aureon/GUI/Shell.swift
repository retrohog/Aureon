import SwiftUI
import AppKit

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var dropping = Box(false)

    var body: some View {
        ZStack {
            AmbientBackground(palette: m.hero.palette, image: m.hero.image, animated: m.tab == .player && ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil,
                              intensity: m.tab == .player ? 1 : 0.3)
            HStack(spacing: 0) {
                Sidebar()
                ZStack(alignment: .bottom) {
                    page.id(m.tab).transition(.tabSwap).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if m.tab != .player { PlayerBar().transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
            }
            if dropping.v {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.accent.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.accent.opacity(0.1)))
                    .overlay(Label("Drop to add to the queue", systemImage: "plus.circle.fill").font(.title3.weight(.semibold)))
                    .padding(10).transition(.opacity.combined(with: .scale(scale: 0.99))).allowsHitTesting(false)
            }
        }
        .animation(.smooth(duration: 0.35), value: m.tab == .player)
        .animation(.smooth(duration: 0.22), value: dropping.v)
        .environmentObject(m.albumArt)
        .preferredColorScheme(.dark)
        .background(Color(white: 0.06))
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { dropping.v }, set: { dropping.v = $0 })) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in m.add(urls: [url]) } }
                }
            }
            return true
        }
    }

    @ViewBuilder private var page: some View {
        switch m.tab {
        case .player: NowPlayingView()
        case .search: SearchPage()
        case .albums, .artists, .songs, .composers, .works, .conductors, .ensembles: LibraryPage(lib: m.library, tab: m.tab)
        case .audio: PageScaffold(title: "Audio", subtitle: "Playback path and processing") { AudioTab() }
        case .dsp: PageScaffold(title: "DSP", subtitle: "Parametric EQ and plug-ins") { DSPTab() }
        case .deepDive: PageScaffold(title: "Deep Dive", subtitle: "Credits, biographies and releases") { DeepDiveTab() }
        case .connect: PageScaffold(title: "Connect", subtitle: "Discord, scrobbling and remote control") { ConnectTab() }
        case .diagnostics: PageScaffold(title: "System", subtitle: "Optimisation and hardware diagnostics") { DiagnosticsTab() }
        }
    }
}

// MARK: - Queue sidebar

struct QueueView: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var sel = Box(Set<UUID>())
    var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if m.items.isEmpty { empty } else { list }
        }
        .background(.ultraThinMaterial)
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
        if p.runModal() == .OK { m.add(urls: p.urls) }
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
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(playing ? 0.09 : (hover.v ? 0.06 : 0))))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.smooth(duration: 0.14)) { hover.v = h } }
        .onTapGesture(count: 2) { m.play(item.id) }
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
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.18 : (hover.v && enabled ? 0.1 : 0))))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.smooth(duration: 0.15), value: hover.v).animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { hover.v = $0 }
        }
    }
}

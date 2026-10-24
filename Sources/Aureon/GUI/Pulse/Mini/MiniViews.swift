import SwiftUI
import AppKit

// The five looks of the mini player. Each is a small SwiftUI view of the song that is playing: the cover, the names, the tags and the controls. They read
// the same published state as the rest of the app and nothing more, so a mini player costs next to nothing; when it is closed, none of this exists.

/// What the chrome of a mini player can do (close, pin on top, open the app). Set by the window that hosts it; empty in the preview.
struct MiniActions {
    var close: () -> Void = {}
    var togglePin: () -> Void = {}
    var openApp: () -> Void = {}
    var isPinned = true
    var interactive = false
}

private struct MiniActionsKey: EnvironmentKey { static let defaultValue = MiniActions() }
extension EnvironmentValues {
    var miniActions: MiniActions {
        get { self[MiniActionsKey.self] }
        set { self[MiniActionsKey.self] = newValue }
    }
}

/// Everything a mini player view needs from the app, added in one place.
struct MiniEnvironment: ViewModifier {
    let m: PlayerModel
    func body(content: Content) -> some View {
        content
            .environmentObject(m).environmentObject(m.progress).environmentObject(m.collections).environmentObject(m.albumArt)
            .preferredColorScheme(m.theme.isLight ? .light : .dark)
            .foregroundStyle(Brand.ink)
            .tracking(Typo.bodyTracking)
            .toggleStyle(.rule)
            .id(m.theme.id + "|\(m.lookRevision)")
    }
}
extension View { func miniEnvironment(_ m: PlayerModel) -> some View { modifier(MiniEnvironment(m: m)) } }

// MARK: - Background

/// The surface of a mini player: the theme's panel colour, a gradient from the cover's colour, or the blurred desktop with a glow of the cover's colour.
struct MiniBackdrop: View {
    @EnvironmentObject var m: PlayerModel
    let layout: MiniLayout

    var body: some View {
        let s = m.look.mini, accent = m.hero.palette.accent.color
        ZStack {
            switch s.background {
            case .solid:
                Brand.panel
            case .gradient:
                Brand.panel
                LinearGradient(colors: [accent.opacity(0.10 + 0.55 * s.strength), accent.opacity(0.02 + 0.18 * s.strength)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .blur:
                VisualEffect(material: .hudWindow, blending: .behindWindow)
                Brand.panel.opacity(0.45)
                RadialGradient(colors: [accent.opacity(0.15 + 0.5 * s.strength), .clear], center: .topLeading, startRadius: 4, endRadius: max(layout.size.width, layout.size.height) * 0.9)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous).strokeBorder(Brand.ink.opacity(0.1), lineWidth: 1))
    }
}

/// The frame of a mini player: its size, its background and the corner.
struct MiniSurface<Content: View>: View {
    let layout: MiniLayout
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(width: layout.size.width, height: layout.size.height)
            .background(MiniBackdrop(layout: layout))
            .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
    }
}

// MARK: - Pieces

struct MiniCover: View {
    @EnvironmentObject var m: PlayerModel
    let side: CGFloat
    var radius: CGFloat = 0
    var body: some View {
        CoverView(image: m.hero.image ?? m.focusItem?.thumb, palette: m.hero.palette, corner: radius, symbol: m.focusItem?.isStream == true ? "dot.radiowaves.left.and.right" : "music.note")
            .frame(width: side, height: side)
    }
}

/// The thin line along the bottom of the bar and the strip: the progress of the song.
struct MiniProgressLine: View {
    @EnvironmentObject var progress: ProgressModel
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        let f = m.isActive && progress.duration > 0 ? CGFloat(min(1, max(0, progress.position / progress.duration))) : 0
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Brand.ink.opacity(0.14))
                Rectangle().fill(Brand.accent).frame(width: g.size.width * f)
            }
        }
        .frame(height: 3).allowsHitTesting(false)
    }
}

struct MiniTransport: View {
    @EnvironmentObject var m: PlayerModel
    var play: CGFloat = 42
    var side: CGFloat = 36
    var modes = false
    var body: some View {
        HStack(spacing: modes ? 6 : 2) {
            if modes { ShuffleButton(size: 15, tint: Brand.inkSecondary) }
            Button { m.player.send(.previous) } label: { TransportGlyph(kind: .previous, size: 14) }.buttonStyle(RoundIconStyle(size: side)).accessibilityLabel("Previous")
            Button { m.togglePlay() } label: { TransportGlyph(kind: m.isActive && m.status.state == .playing ? .pause : .play, size: play * 0.4) }
                .buttonStyle(PlayKeyStyle(size: play)).accessibilityLabel(m.isActive && m.status.state == .playing ? "Pause" : "Play")
            Button { m.player.send(.next) } label: { TransportGlyph(kind: .next, size: 14) }.buttonStyle(RoundIconStyle(size: side)).accessibilityLabel("Next")
            if modes { RepeatButton(size: 15, tint: Brand.inkSecondary) }
        }
        .disabled(m.items.isEmpty)
    }
}

/// Title over artist, as the layouts show them.
struct MiniNames: View {
    @EnvironmentObject var m: PlayerModel
    var titleSize: CGFloat = 15
    var artistSize: CGFloat = 12.5
    var withAlbum = false
    var body: some View {
        let d = m.focusDisplay, item = m.focusItem
        VStack(alignment: .leading, spacing: 2) {
            Text(d?.title ?? "Nothing playing").font(Typo.face(titleSize, Typo.sansWeight(.medium))).lineLimit(1)
            let line = [d?.artist ?? "", withAlbum ? (item?.album ?? "") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            Text(line.isEmpty ? "Add music or tune a station" : line).font(Typo.face(artistSize, Typo.sansWeight(.regular))).foregroundStyle(Brand.inkSecondary).lineLimit(1)
        }
    }
}

struct MiniTags: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View { if m.look.mini.formatTags { NowPlayingTags(place: .bar, alignment: .leading) } }
}

/// The two small buttons at a corner of a window: keep it on top, and open the app.
struct MiniCornerButtons: View {
    @Environment(\.miniActions) private var actions
    var size: CGFloat = 26
    var body: some View {
        HStack(spacing: 0) {
            Button { actions.togglePin() } label: { Image(systemName: actions.isPinned ? "pin.fill" : "pin").font(Typo.sans(11)) }
                .buttonStyle(RoundIconStyle(on: actions.isPinned, size: size)).help(actions.isPinned ? "Stop keeping it on top" : "Keep it on top").accessibilityLabel("Pin on top")
            Button { actions.openApp() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(Typo.sans(11)) }
                .buttonStyle(RoundIconStyle(size: size)).help("Open Aureon").accessibilityLabel("Open Aureon")
        }
    }
}

// MARK: - The layouts

struct MiniBarView: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        MiniSurface(layout: .bar) {
            ZStack(alignment: .bottom) {
                HStack(spacing: 20) {
                    MiniCover(side: 96)
                    VStack(alignment: .leading, spacing: 5) {
                        MiniNames(titleSize: 15, artistSize: 12.5)
                        MiniTags().padding(.top, 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    MiniTransport().padding(.trailing, 14)
                }
                MiniProgressLine().padding(.leading, 96)
            }
            .overlay(alignment: .topTrailing) { MiniCornerButtons().padding(.top, 6).padding(.trailing, 12) }
        }
    }
}

struct MiniStripView: View {
    var body: some View {
        MiniSurface(layout: .strip) {
            ZStack(alignment: .bottom) {
                HStack(spacing: 10) {
                    MiniCover(side: 48)
                    StripNames()
                    Spacer(minLength: 8)
                    MiniTransport(play: 30, side: 34)
                    Color.clear.frame(width: 6)
                }
                MiniProgressLine().padding(.leading, 48)
            }
        }
    }
}

/// "Title  Artist  [hi-res]" on one line.
private struct StripNames: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        let d = m.focusDisplay
        HStack(spacing: 10) {
            Text(d?.title ?? "Nothing playing").font(Typo.face(13.5, Typo.sansWeight(.medium))).lineLimit(1)
            Text(d?.artist ?? "").font(Typo.face(13.5, Typo.sansWeight(.regular))).foregroundStyle(Brand.inkSecondary).lineLimit(1)
            if let input = m.formatTagInput(bitrate: nil), m.look.mini.formatTags {
                let hi = FormatTagBuilder.tags(input).filter { $0.tier == .gold }
                ForEach(hi) { FormatTagView(tag: $0, compact: true) }
            }
        }
    }
}

struct MiniCardView: View {
    @EnvironmentObject var m: PlayerModel
    @Environment(\.miniActions) private var actions
    var body: some View {
        MiniSurface(layout: .card) {
            VStack(spacing: 0) {
                HStack {
                    if actions.interactive { Button { actions.close() } label: { Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 11, height: 11) }.buttonStyle(.plain).help("Close").accessibilityLabel("Close") }
                    Spacer()
                    MiniCornerButtons(size: 30)
                }
                .padding(.horizontal, 12).frame(height: 44)
                MiniCover(side: 332, radius: 14).shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                HStack(alignment: .center) {
                    MiniNames(titleSize: 21, artistSize: 14, withAlbum: true)
                    Spacer(minLength: 8)
                    if let item = m.focusItem, !item.isStream { HeartButton(path: item.path, size: 18) }
                }
                .padding(.top, 20).padding(.horizontal, 24)
                MiniTags().padding(.top, 10).padding(.horizontal, 24).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    BarTime(remaining: false)
                    WaveformScrubber(style: .slim, tint: Brand.accent)
                    BarTime(remaining: true)
                }.padding(.top, 12).padding(.horizontal, 24)
                MiniTransport(play: 54, side: 40, modes: true).padding(.top, 4)
                Spacer(minLength: 0)
                HStack {
                    HStack(spacing: 0) {
                        Button { m.look.mini.layout = .cardLyrics } label: { Image(systemName: "quote.bubble") }.buttonStyle(RoundIconStyle(size: 34)).help("Lyrics").accessibilityLabel("Lyrics")
                        Button { actions.openApp() } label: { Image(systemName: "list.bullet") }.buttonStyle(RoundIconStyle(size: 34)).help("Queue").accessibilityLabel("Queue")
                    }
                    Spacer()
                    VolumeControl(width: 80, readout: false)
                }.padding(.horizontal, 18).frame(height: 36).padding(.bottom, 8)
            }
        }
    }
}

struct MiniCardLyricsView: View {
    @EnvironmentObject var m: PlayerModel
    @Environment(\.miniActions) private var actions
    var body: some View {
        MiniSurface(layout: .cardLyrics) {
            ZStack {
                if let img = m.hero.image ?? m.focusItem?.thumb {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: 460, height: 900).blur(radius: 28).opacity(0.6)
                }
                Brand.panel.opacity(0.55)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        MiniNames(titleSize: 17, artistSize: 13)
                        Spacer(minLength: 8)
                        MiniCornerButtons(size: 28)
                    }
                    .padding(.top, 16)
                    MiniLyricLines().frame(maxHeight: .infinity).padding(.vertical, 8)
                    MiniTransport(play: 48, side: 36).frame(maxWidth: .infinity)
                    HStack {
                        Button { m.look.mini.layout = .card } label: { Image(systemName: "photo") }.buttonStyle(RoundIconStyle(size: 34)).help("Back to the card").accessibilityLabel("Show the cover")
                        Spacer()
                        VolumeControl(width: 70, readout: false)
                    }.padding(.top, 6)
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }
}

/// The lines of the song around the one being sung, small and centred. The lookup is only asked for while this is on screen.
struct MiniLyricLines: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var service = LyricsService.shared
    var body: some View {
        Group {
            if service.phase == .ready, let l = service.lyrics, l.synced {
                GeometryReader { g in
                    LyricsStage(lyrics: l, accent: Brand.accent, height: g.size.height)
                        .environment(\.lyricStyle, LyricStyle(size: 19, centered: true, gap: 12, rest: 0.4))
                }
            } else {
                Text(message).font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LyricsDriver.trigger(for: m, show: true)) { await LyricsDriver.ask(m, show: true) }
    }
    private var message: String {
        if m.focusItem == nil { return "Play a song to see its words." }
        if m.focusItem?.isStream == true { return "Radio has no lyrics." }
        switch service.phase { case .loading: return "Looking for the lyrics…"; case .instrumental: return "Instrumental"; case .ready: return "These lyrics are not timed."; default: return "No lyrics found." }
    }
}

struct MiniPopoverView: View {
    @EnvironmentObject var m: PlayerModel
    @Environment(\.miniActions) private var actions
    var body: some View {
        MiniSurface(layout: .popover) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    MiniCover(side: 56, radius: 9)
                    MiniNames(titleSize: 15, artistSize: 12.5)
                    Spacer(minLength: 4)
                    if let item = m.focusItem, !item.isStream { HeartButton(path: item.path, size: 16) }
                }
                .padding(.horizontal, 16).padding(.top, 16)
                MiniTags().padding(.horizontal, 16).padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    BarTime(remaining: false)
                    WaveformScrubber(style: .slim, tint: Brand.accent)
                    BarTime(remaining: true)
                }.padding(.horizontal, 16).padding(.top, 10)
                MiniTransport(play: 44, side: 36, modes: true).padding(.top, 2)
                Spacer(minLength: 0)
                HStack {
                    Text(outputLine).font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                    Spacer()
                    Button { actions.openApp() } label: { Text("Open Aureon").font(Typo.sans(13, .medium)).foregroundStyle(Brand.accentText) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).frame(height: 42)
            }
        }
    }
    private var outputLine: String {
        let name = m.selectedDevice.map { QuickDevices.shortName($0.name) } ?? "No device"
        guard m.isActive, let r = m.status.info?.sampleRate, r > 0 else { return name }
        return name + " · " + formatRate(r)
    }
}

/// The layout chosen, at its size.
struct MiniLayoutView: View {
    let layout: MiniLayout
    var body: some View {
        switch layout {
        case .bar: MiniBarView()
        case .strip: MiniStripView()
        case .card: MiniCardView()
        case .cardLyrics: MiniCardLyricsView()
        case .popover: MiniPopoverView()
        }
    }
}

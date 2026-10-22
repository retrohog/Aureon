import SwiftUI
import AppKit
import CoreImage

// The stage: the album-colour backdrop behind every page, and the expanding transition from the player bar into the immersive Now Playing view.

// MARK: - Backdrop picture

/// A small, heavily blurred copy of the current cover. Blurring a 96-pixel picture once on a background task and scaling it up costs nothing per
/// frame, where a live blur over the whole window would cost a full-screen filter pass on every redraw.
@MainActor
final class BackdropImageStore: ObservableObject {
    static let shared = BackdropImageStore()
    @Published private(set) var images: [String: CGImage] = [:]
    private var order: [String] = []
    private var pending = Set<String>()
    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    func image(for token: String) -> CGImage? { images[token] }

    func prepare(token: String, image: NSImage?) {
        guard !token.isEmpty, images[token] == nil, !pending.contains(token),
              let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        pending.insert(token)
        Task { @MainActor in
            let out = await Task.detached(priority: .utility) { Self.render(cg) }.value
            pending.remove(token)
            guard let out else { return }
            withAnimation(.smooth(duration: 0.9)) { images[token] = out }
            order.append(token)
            while order.count > 6 { images[order.removeFirst()] = nil }
        }
    }

    /// Downsamples to `side` pixels, blurs with a radius of a sixth of that (edges clamped so the borders do not darken) and lifts the
    /// saturation a little, so the colours survive the material laid over them.
    nonisolated static func render(_ cg: CGImage, side: Int = 96) -> CGImage? {
        let input = CIImage(cgImage: cg)
        let s = CGFloat(side) / max(input.extent.width, input.extent.height, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let rect = CGRect(x: 0, y: 0, width: ceil(small.extent.width), height: ceil(small.extent.height))
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: small.clampedToExtent(), kCIInputRadiusKey: Double(side) / 6]),
              let blurred = blur.outputImage,
              let tone = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: blurred, kCIInputSaturationKey: 1.3, kCIInputBrightnessKey: 0.0, kCIInputContrastKey: 1.0]),
              let toned = tone.outputImage else { return nil }
        return context.createCGImage(toned.cropped(to: rect), from: rect)
    }
}

// MARK: - Backdrop

/// Behind every page: the cover's colours as a mesh gradient, its blurred picture, and a system material on top so text stays legible
/// (the HIG's "under window" material on ordinary pages; Now Playing gets the colours almost unfiltered).
struct StageBackdrop: View {
    let palette: ArtPalette
    let image: NSImage?
    let token: String
    var stage: Bool
    var light: Bool
    @ObservedObject private var blurred = BackdropImageStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let snapshot = ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil

    var body: some View {
        ZStack {
            Brand.canvas
            MeshLayer(palette: palette, drifting: stage && !reduceMotion && !snapshot)
                .opacity(stage ? 1 : (light ? 0.5 : 0.85))
            if let cg = blurred.image(for: token) {
                GeometryReader { g in
                    Image(decorative: cg, scale: 1).resizable().interpolation(.high).scaledToFill()
                        .frame(width: g.size.width, height: g.size.height).clipped()
                }
                .opacity(stage ? 0.32 : (light ? 0.22 : 0.3))
                .blendMode(light ? .normal : .plusLighter)
                .id(token).transition(.opacity)
            }
            if stage {
                // the immersive view keeps its colours; legibility comes from darkening towards the bottom and the corners
                LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 200, endRadius: 900)
            } else {
                if snapshot { Brand.canvas.opacity(0.62) } else { VisualEffect(material: .underWindowBackground, blending: .withinWindow) }
                // the theme's own surface, faintly, so every theme keeps its character over the cover's colours
                Brand.canvas.opacity(light ? 0.28 : 0.34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .onAppear { blurred.prepare(token: token, image: image) }
        .onChange(of: token) { _, t in blurred.prepare(token: t, image: image) }
        .animation(.smooth(duration: 0.9), value: token)
    }
}

/// The mesh gradient. Still on ordinary pages (no per-frame work at all); on Now Playing its inner points drift slowly.
struct MeshLayer: View {
    let palette: ArtPalette
    var drifting: Bool

    private static let base: [SIMD2<Float>] = [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.5, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]]

    static func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        base.enumerated().map { i, p in
            // corners stay put; edge midpoints slide along their edge; the centre wanders
            let a = Float(t * 0.11) + Float(i) * 1.7, b = Float(t * 0.09) + Float(i) * 2.3
            switch i {
            case 1, 7: return [p.x + 0.12 * sin(a), p.y]
            case 3, 5: return [p.x, p.y + 0.12 * sin(b)]
            case 4: return [p.x + 0.1 * sin(a), p.y + 0.1 * cos(b)]
            default: return p
            }
        }
    }

    var body: some View {
        if drifting {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                MeshGradient(width: 3, height: 3, points: Self.points(tl.date.timeIntervalSinceReferenceDate), colors: palette.grid.map(\.color), smoothsColors: true)
            }
        } else {
            MeshGradient(width: 3, height: 3, points: Self.base, colors: palette.grid.map(\.color), smoothsColors: true)
        }
    }
}

// MARK: - Expanding Now Playing

/// What the stage needs from the app model: the page shown and the layout. `PlayerModel` is one; tests use a small stand-in.
@MainActor
protocol StageHost: AnyObject {
    var tab: Tab { get set }
    var djMode: Bool { get set }
}
extension PlayerModel: StageHost {}

/// Whether Now Playing fills the window (sidebar tucked away), and where to go back to.
@MainActor
final class StageModel: ObservableObject {
    @Published var immersive = false
    /// Set by the Lyrics buttons; Now Playing scrolls its lyrics panel into view and clears it.
    @Published var lyricsPending = false
    var returnTab: Tab = .home

    /// From the player bar (or any "open Now Playing" button): the cover and waveform fly up into the full view.
    func open(_ m: some StageHost, reduceMotion: Bool) {
        if m.tab != .player { returnTab = m.tab }
        withAnimation(StageMotion.expand(reduceMotion)) {
            m.djMode = false
            immersive = true
            m.tab = .player
        }
    }

    /// Back to the page Now Playing was opened from; the cover settles back into the bar.
    func close(_ m: some StageHost, reduceMotion: Bool) {
        withAnimation(StageMotion.collapse(reduceMotion)) {
            immersive = false
            if m.tab == .player { m.tab = returnTab == .player ? .home : returnTab }
        }
    }

    /// The Lyrics buttons: lyrics switched back on and expanded, Now Playing opened (when it is not already), and scrolled to the lyrics.
    func showLyrics(_ m: some StageHost, reduceMotion: Bool) {
        UserDefaults.standard.set(true, forKey: "aureon.lyrics.show")
        UserDefaults.standard.set(true, forKey: "aureon.lyrics.expanded")
        if m.tab != .player { open(m, reduceMotion: reduceMotion) }
        lyricsPending = true
        // the lookup is not left to the page appearing: start it for the song in focus now
        if let focus = m as? LyricsFocus { LyricsDriver.start(focus) }
    }

    /// Full window ⇄ beside the sidebar, staying on Now Playing.
    func toggleImmersive(reduceMotion: Bool) {
        withAnimation(StageMotion.expand(reduceMotion)) { immersive.toggle() }
    }
}

enum StageMotion {
    static func expand(_ reduce: Bool) -> Animation { reduce ? .easeOut(duration: 0.18) : .spring(response: 0.52, dampingFraction: 0.86) }
    static func collapse(_ reduce: Bool) -> Animation { reduce ? .easeOut(duration: 0.16) : .spring(response: 0.44, dampingFraction: 0.9) }
}

private struct StageNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    /// Shared by the player bar and Now Playing so their cover and waveform can morph into each other.
    var stageNamespace: Namespace.ID? {
        get { self[StageNamespaceKey.self] }
        set { self[StageNamespaceKey.self] = newValue }
    }
}

/// Identifiers of the elements that travel between the bar and the stage.
enum StageElement: String { case cover = "stage.cover", waveform = "stage.waveform" }

private struct StageMatched: ViewModifier {
    let element: StageElement
    @Environment(\.stageNamespace) private var ns
    func body(content: Content) -> some View {
        if let ns { content.matchedGeometryEffect(id: element.rawValue, in: ns) } else { content }
    }
}

extension View {
    /// Marks this view as the bar's or the stage's copy of `element`; whichever is on screen is the source of the morph.
    func stageMatched(_ element: StageElement) -> some View { modifier(StageMatched(element: element)) }
}

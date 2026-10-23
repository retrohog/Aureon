import SwiftUI
import AppKit
import CoreImage

// The stage: the album-colour backdrop behind every page, and the expanding transition from the player bar into the immersive Now Playing view.

// MARK: - Backdrop

/// Renders the page backdrops. Everything here is a pure function of its inputs and runs on a background task; the result is one small bitmap that
/// is scaled up by the compositor, so nothing is blurred, mixed or recomputed per frame.
enum BackdropRenderer {
    static let size = CGSize(width: 320, height: 200)

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// `c` mixed back towards `base` until its luminance is no further from `base`'s than `limit`'s is (lighter on dark pages, darker on light ones).
    nonisolated static func held(_ c: RGB, base: RGB, limit: RGB) -> RGB {
        let reach = abs(WCAG.luminance(limit) - WCAG.luminance(base))
        var t = 0.0, out = c
        while abs(WCAG.luminance(out) - WCAG.luminance(base)) > reach, t < 1 { t += 0.04; out = c.mixed(with: base, t) }
        return out
    }

    /// The soft wash: `base` with the accent as a lift in the top-left corner, easing back to `base` and then to a slightly deeper (dark) or
    /// warmer (light) tone in the bottom-right. `strength` is how much of the accent the corner takes; no colour in it goes past `limit`.
    nonisolated static func soft(base: RGB, accent: RGB, accent2: RGB, strength: Double, light: Bool, limit: RGB) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = context(w, h) else { return nil }
        let c0 = base.mixed(with: accent, strength)
        let c1 = base
        let c2 = light ? base.mixed(with: accent2, strength * 0.5) : base.mixed(with: RGB(0, 0, 0), 0.35)
        let stops = [held(c0, base: base, limit: limit), c1, held(c2, base: base, limit: limit)]
        let colors = stops.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1]) else { return nil }
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return ctx.makeImage()
    }

    /// A sparse field of fine stars on a transparent ground: mostly single points, a few brighter, seeded so it is the same every time. Drawn once,
    /// off the main thread; the view that shows it only moves the finished bitmap.
    nonisolated static func stars(width: Int = 1920, height: Int = 1200, count: Int = 150, seed: UInt64 = 7, ink: RGB, accent: RGB) -> CGImage? {
        guard let ctx = context(width, height) else { return nil }
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
        for _ in 0..<count {
            let x = next() * Double(width), y = next() * Double(height)
            let bright = next()
            let size = bright > 0.93 ? 3.0 : (bright > 0.7 ? 2.0 : 1.0)
            let alpha = 0.14 + 0.42 * pow(next(), 1.5)
            let c = next() > 0.82 ? accent : ink
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha))
            ctx.fill(CGRect(x: x.rounded(), y: y.rounded(), width: size, height: size))
        }
        return ctx.makeImage()
    }

    /// The cover's own colours as soft washes over `base`: up to three dominant hues taken from the (already blurred) cover, laid as broad overlapping
    /// pools of colour, one anchored behind where the cover hangs, one drifting to the opposite corner and one high on the other side. No shape of the
    /// cover survives, only its colours. Every pixel is then held to `maxShift` × the intensity's reach of luminance away from `base` (up on dark surfaces,
    /// down on light ones), so text keeps its contrast whatever the cover; where a wash would go past that it is mixed back towards `base` pixel by pixel.
    nonisolated static func album(base: RGB, blurred: CGImage, maxShift: Double, light: Bool, intensity: BackdropIntensity = .rich) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = context(w, h), let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let hues = dominantHues(of: blurred, light: light, saturation: intensity.saturation)
        let washes: [(x: Double, y: Double, rx: Double, ry: Double, colour: RGB, strength: Double)] = [
            (0.90, 0.96, 0.78, 1.00, hues[1], 0.92),
            (0.80, 0.06, 0.52, 0.70, hues[2], 0.78),
            (0.27, 0.46, 0.66, 0.90, hues[0], 1.00),
        ]
        let budget = max(0, maxShift * intensity.reach - 0.003)
        let baseL = WCAG.luminance(base)
        func shift(_ c: RGB) -> Double { let d = WCAG.luminance(c) - baseL; return light ? -d : d }
        for y in 0..<h {
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w), v = (Double(y) + 0.5) / Double(h)
                var c = base
                for k in washes {
                    let dx = (u - k.x) / k.rx, dy = (v - k.y) / k.ry
                    c = c.mixed(with: k.colour, k.strength * exp(-2.4 * (dx * dx + dy * dy)))
                }
                if shift(c) > budget {
                    var lo = 0.0, hi = 1.0
                    for _ in 0..<12 { let mid = (lo + hi) / 2; if shift(base.mixed(with: c, mid)) <= budget { lo = mid } else { hi = mid } }
                    c = base.mixed(with: c, lo)
                }
                // a fixed fine noise under one level of 8 bits, so the slow gradients do not band
                var n = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663); n = n &* 2654435761; n ^= n >> 15
                let dither = (Double(n & 255) / 255 - 0.5) / 255
                let o = (y * w + x) * 4
                // (bitmap contexts store the top row first)
                data[o] = UInt8(max(0, min(255, ((c.r + dither) * 255).rounded())))
                data[o + 1] = UInt8(max(0, min(255, ((c.g + dither) * 255).rounded())))
                data[o + 2] = UInt8(max(0, min(255, ((c.b + dither) * 255).rounded())))
                data[o + 3] = 255
            }
        }
        return ctx.makeImage()
    }

    /// Three colours that stand for a cover: the strongest hues in it (twelve hue bins weighted by saturation and brightness, no two neighbours),
    /// each set to a clean saturation and a brightness that suits the page. A cover with fewer hues lends shifted relatives of its first; a grey one
    /// lends its own average at three brightnesses.
    nonisolated static func dominantHues(of image: CGImage, light: Bool, saturation k: Double) -> [RGB] {
        let n = 48
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let p = { ctx -> UnsafeMutablePointer<UInt8>? in ctx.interpolationQuality = .medium; ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n)); return ctx.data?.assumingMemoryBound(to: UInt8.self) }(ctx)
        else { return [AccentPair.fallback.accent, AccentPair.fallback.accent2, AccentPair.fallback.accent] }
        let bins = 12
        var weight = [Double](repeating: 0, count: bins), sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var mr = 0.0, mg = 0.0, mb = 0.0
        for i in 0..<(n * n) {
            let c = RGB(Double(p[i * 4]) / 255, Double(p[i * 4 + 1]) / 255, Double(p[i * 4 + 2]) / 255)
            mr += c.r; mg += c.g; mb += c.b
            let hsb = c.hsb
            guard hsb.s >= 0.15, hsb.v >= 0.12 else { continue }
            let b = min(bins - 1, Int(hsb.h * Double(bins))), wt = hsb.s * hsb.s * (0.3 + hsb.v)
            weight[b] += wt; sum[b] = (sum[b].0 + c.r * wt, sum[b].1 + c.g * wt, sum[b].2 + c.b * wt)
        }
        func tuned(_ c: RGB, v: Double) -> RGB { let h = c.hsb; return RGB(h: h.h, s: min(0.85, max(0.4, h.s * k)), v: v) }
        let v0 = light ? 0.86 : 0.92
        var chosen: [Int] = []
        for b in weight.indices.sorted(by: { weight[$0] > weight[$1] }) where weight[b] > 0.2 && chosen.count < 3 {
            if chosen.allSatisfy({ let d = abs($0 - b); return min(d, bins - d) >= 2 }) { chosen.append(b) }
        }
        var out = chosen.map { b -> RGB in tuned(RGB(sum[b].0 / weight[b], sum[b].1 / weight[b], sum[b].2 / weight[b]), v: v0) }
        if out.isEmpty {
            let a = RGB(mr / Double(n * n), mg / Double(n * n), mb / Double(n * n))
            return [a, a.mixed(with: RGB(1, 1, 1), 0.3), a.mixed(with: RGB(0, 0, 0), 0.3)]
        }
        if out.count < 2 { out.append(out[0].hueShifted(0.07).with(saturation: min(0.85, out[0].hsb.s), brightness: v0 - 0.06)) }
        if out.count < 3 { out.append(out[0].hueShifted(-0.06).with(saturation: min(0.8, out[0].hsb.s), brightness: v0 - 0.1)) }
        return out
    }
}

/// How much of the Album backdrop's allowance a page takes: Subtle is a hint of colour, Rich the everyday setting, Vivid the most that still
/// keeps every line of text at its contrast.
enum BackdropIntensity: String, CaseIterable, Identifiable {
    case subtle, rich, vivid
    var id: String { rawValue }
    var title: String { switch self { case .subtle: "Subtle"; case .rich: "Rich"; case .vivid: "Vivid" } }
    /// The share of the theme's allowed luminance shift the washes may use.
    var reach: Double { switch self { case .subtle: 0.30; case .rich: 0.62; case .vivid: 0.95 } }
    /// How far the cover's saturation is pushed before it is held to the allowance.
    var saturation: Double { switch self { case .subtle: 0.85; case .rich: 1.0; case .vivid: 1.12 } }
    var hint: String { switch self { case .subtle: "A hint of the cover's colour"; case .rich: "Soft pools of the cover's colours"; case .vivid: "The strongest colour that keeps text clear" } }
}

/// Backdrop bitmaps, rendered once on a background task and kept (the last few). Asking again for a key that is rendering or rendered costs nothing.
@MainActor
final class BackdropStore: ObservableObject {
    static let shared = BackdropStore()
    @Published private(set) var images: [String: CGImage] = [:]
    private var order: [String] = []
    private var pending = Set<String>()

    func image(for key: String) -> CGImage? { images[key] }
    /// Rendered, or being rendered.
    func isKnown(_ key: String) -> Bool { images[key] != nil || pending.contains(key) }

    func prepare(key: String, render: @escaping @Sendable () -> CGImage?) {
        guard images[key] == nil, !pending.contains(key) else { return }
        pending.insert(key)
        Task { @MainActor in
            let out = await Task.detached(priority: .utility) { render() }.value
            pending.remove(key)
            guard let out else { return }
            images[key] = out
            order.append(key)
            while order.count > 10 { images[order.removeFirst()] = nil }
        }
    }
}

/// The star layer: a finished bitmap on a Core Animation layer that drifts a few points over several minutes, back and forth. The motion belongs to the
/// render server, so it costs the main thread nothing; it stops while the window is hidden or covered, and under Reduce Motion (and in snapshots) it stays still.
struct StarfieldView: NSViewRepresentable {
    let image: CGImage

    final class Host: NSView {
        let layerStars = CALayer()
        private var observers: [NSObjectProtocol] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            layerStars.contentsGravity = .resizeAspectFill
            layerStars.magnificationFilter = .linear
            layer?.addSublayer(layerStars)
        }
        required init?(coder: NSCoder) { nil }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            // a little larger than the window, so the drift never shows an edge
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layerStars.frame = bounds.insetBy(dx: -24, dy: -24)
            CATransaction.commit()
            drift()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let w = window else { return }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.syncRunning() } })
            drift()
        }

        private var reduce: Bool { HWPanel.snapshot || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        func drift() {
            guard layerStars.animation(forKey: "drift") == nil, !reduce, bounds.width > 0 else { return }
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = -14; a.toValue = 14; a.duration = 160; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let b = CABasicAnimation(keyPath: "transform.translation.y")
            b.fromValue = 6; b.toValue = -6; b.duration = 110; b.autoreverses = true; b.repeatCount = .infinity
            b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layerStars.add(a, forKey: "drift"); layerStars.add(b, forKey: "driftY")
            syncRunning()
        }

        /// Paused while the window cannot be seen.
        func syncRunning() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            let layer = layerStars
            if visible, layer.speed == 0 {
                let paused = layer.timeOffset
                layer.speed = 1; layer.timeOffset = 0; layer.beginTime = 0
                layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
            } else if !visible, layer.speed != 0 {
                layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
            }
        }
    }

    func makeNSView(context: Context) -> Host { let h = Host(frame: .zero); h.layerStars.contents = image; return h }
    func updateNSView(_ v: Host, context: Context) { v.layerStars.contents = image }
}

/// Downsampling and blurring of a cover for the Album backdrop. Blurring a 96-pixel picture once on a background task and scaling it up costs
/// nothing per frame, where a live blur over the whole window would cost a full-screen filter pass on every redraw.
enum BackdropImageStore {
    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Downsamples to `side` pixels, blurs with a radius of a sixth of that (edges clamped so the borders do not darken) and lifts the
    /// saturation a little, so the colours survive the veil laid over them.
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

/// Behind every page. Each theme chooses how it is painted (`BackdropMode`): flat, a soft two-tone wash of the theme's colours, or the blurred cover.
/// The stage (Now Playing) takes the same choice at a stronger setting. The bitmaps come from `BackdropStore`; this view only
/// places one.
struct StageBackdrop: View {
    let mode: BackdropMode
    let theme: Theme
    let palette: ArtPalette
    let image: NSImage?
    let token: String
    var stage: Bool
    var intensity: BackdropIntensity = .rich
    @ObservedObject private var store = BackdropStore.shared
    /// The last bitmap that was drawn, kept on screen while the next one is still rendering, so a new track cross-fades from colours to colours.
    @State private var shownKey: String?

    /// The bitmap is asked for as soon as the view is made (not only when it appears), so it is already on its way when the page is first drawn.
    init(mode: BackdropMode, theme: Theme, palette: ArtPalette, image: NSImage?, token: String, stage: Bool, intensity: BackdropIntensity = .rich) {
        self.mode = mode; self.theme = theme; self.palette = palette; self.image = image; self.token = token; self.stage = stage; self.intensity = intensity
        prepare()
    }

    private var base: RGB { theme.canvasRGB }
    private var effective: BackdropMode {
        if mode == .album && image == nil { return .soft }
        if mode == .starlight { return .soft }          // the wash under the stars is the soft one
        return mode
    }
    private var starry: Bool { mode == .starlight && !theme.isLight }
    private var starsKey: String { "stars|\(theme.id)" }
    private var key: String { "\(effective.rawValue)|\(theme.id)|\(stage ? "stage" : "page")|\(effective == .album ? token + "|" + intensity.rawValue : "")" }
    /// Soft pages hold their backdrop to half of the allowed shift, the stage to all of it. The Album backdrop takes its share through its intensity
    /// (a little less on pages, which are busier than the stage).
    private var limit: RGB { stage ? theme.backdropLimitRGB : theme.canvasRGB.mixed(with: theme.backdropLimitRGB, 0.5) }
    private var albumShift: Double { abs(WCAG.luminance(theme.backdropLimitRGB) - WCAG.luminance(base)) * (stage ? 1 : 0.85) }

    /// The bitmap to draw now: this key's when it is ready, otherwise the previous one.
    private var drawKey: String? { store.image(for: key) != nil ? key : shownKey.flatMap { store.image(for: $0) != nil ? $0 : nil } }

    var body: some View {
        ZStack {
            base.color
            if mode != .off, let dk = drawKey, let cg = store.image(for: dk) {
                GeometryReader { g in
                    Image(decorative: cg, scale: 1).resizable().interpolation(.high).frame(width: g.size.width, height: g.size.height)
                }
                .id(dk).transition(HWPanel.snapshot ? .identity : .opacity)
            }
            if starry, let stars = store.image(for: starsKey) { StarfieldView(image: stars).allowsHitTesting(false).transition(.opacity) }
        }
        .animation(HWPanel.snapshot ? nil : Motion.backdrop, value: drawKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .onAppear { prepare(); shownKey = drawKey }
        .onChange(of: key) { _, _ in prepare() }
        .onChange(of: drawKey) { _, k in if let k { shownKey = k } }
        .onChange(of: image == nil) { _, _ in prepare() }
    }

    private func prepare() {
        guard mode != .off else { return }
        if starry, !BackdropStore.shared.isKnown(starsKey) {
            let ink = theme.inkRGB, accent = theme.accentRGB
            store.prepare(key: starsKey) { BackdropRenderer.stars(ink: ink, accent: accent) }
        }
        guard !BackdropStore.shared.isKnown(key) else { return }
        let base = self.base, light = theme.isLight, limit = self.limit
        switch effective {
        case .album:
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let shift = albumShift, level = intensity
            store.prepare(key: key) { BackdropImageStore.render(cg).flatMap { BackdropRenderer.album(base: base, blurred: $0, maxShift: shift, light: light, intensity: level) } }
        default:
            let accent = theme.accentRGB, accent2 = theme.accent2RGB
            let strength = stage ? 0.24 : 0.12
            store.prepare(key: key) { BackdropRenderer.soft(base: base, accent: accent, accent2: accent2, strength: strength, light: light, limit: limit) }
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
    /// Set by the Lyrics buttons (kept for the page that wants to react); the panel itself is `panel`.
    @Published var lyricsPending = false
    /// The side panel open on Now Playing: lyrics, the queue, the signal path, the analyser or the booklet. One at a time; nil for none.
    @Published var panel: GalleryPanel?

    /// Focus: only the cover, the title and artist, the progress and the transport, with the cover as large as the window allows. Remembered.
    @Published private(set) var focus = StageModel.savedFocus
    /// The panel that was open when Focus began, brought back when it ends.
    private var panelBeforeFocus: GalleryPanel?
    static let focusKey = "aureon.stageFocus"
    static var savedFocus: Bool {
        if ProcessInfo.processInfo.environment["AUREON_FOCUS"] != nil { return true }
        return ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil && UserDefaults.standard.bool(forKey: focusKey)
    }

    /// F: into Focus (any side panel closes), and out of it again (the panel that was open comes back).
    func toggleFocus() {
        if focus { setFocus(false); panel = panelBeforeFocus; panelBeforeFocus = nil }
        else { panelBeforeFocus = panel; panel = nil; setFocus(true) }
    }
    private func setFocus(_ on: Bool) {
        focus = on
        if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil { UserDefaults.standard.set(on, forKey: Self.focusKey) }
    }

    /// Opens the panel, or closes it if it is the one open. Opening another replaces it (and ends Focus, which has no room for a panel).
    func toggle(_ p: GalleryPanel) {
        if focus { setFocus(false); panelBeforeFocus = nil; panel = p; return }
        panel = panel == p ? nil : p
    }
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
        if focus { setFocus(false); panelBeforeFocus = nil }
        panel = .lyrics
        // the lookup is not left to the page appearing: start it for the song in focus now
        if let focus = m as? LyricsFocus { LyricsDriver.start(focus) }
    }

    /// Full window ⇄ beside the sidebar, staying on Now Playing.
    func toggleImmersive(reduceMotion: Bool) {
        withAnimation(StageMotion.expand(reduceMotion)) { immersive.toggle() }
    }
}

enum StageMotion {
    /// Opening and closing Now Playing is a quick fade like any other page change: nothing flies between the bar and the stage.
    static func expand(_ reduce: Bool) -> Animation { TabMotion.animation }
    static func collapse(_ reduce: Bool) -> Animation { TabMotion.animation }
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
        content          // the cover and waveform no longer travel between the bar and the stage; the pages cross-fade instead
    }
}

extension View {
    /// Marks this view as the bar's or the stage's copy of `element`; whichever is on screen is the source of the morph.
    func stageMatched(_ element: StageElement) -> some View { modifier(StageMatched(element: element)) }
}


/// The size of the cover in Focus: as large as the free space allows, the picture inside its mat.
enum FocusLayout {
    static let mat: CGFloat = 14
    /// Room the title and artist need under the cover when the window is too narrow to put them beside it.
    static let infoBelow: CGFloat = 110
    static let infoBeside: CGFloat = 300

    /// `free` is the space between the rail and the progress line, inside the page margins. Wide: the cover on the left, the names beside it. Narrow: the names under.
    static func coverSide(free: CGSize, wide: Bool) -> CGFloat {
        let room = wide ? min(free.height, free.width - infoBeside - 56) : min(free.width, free.height - infoBelow)
        return max(120, room - 2 * mat)
    }
}

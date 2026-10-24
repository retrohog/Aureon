import SwiftUI
import AppKit
import Metal
import MetalKit
import QuartzCore

// Starlight, the sky behind the pages: four layers of stars drifting at different speeds (parallax), each with its own size, colour temperature and
// twinkle; the big ones carry a soft bloom. Behind them a slow nebula of domain-warped noise, tinted by the cover that is playing, and a deep vignette.
// Now and then, rarely and never while you type, a shooting star. In a light theme the same sky is a restrained dusk: the page's own paper tone,
// warmed towards the cover's colours, with brass specks for stars.
//
// It is drawn by the GPU in one full-screen pass (no per-star work on the CPU), at 30 frames a second, and not at all while the window is hidden or
// covered, the app is in the background, or Reduce Motion is on (then it is one still frame). In Low Power Mode it drops to 15. The music can move it a
// little: the low bands of the analysis the interface already runs are read (never the audio thread) and ease the nebula's glow.

/// Everything the shader reads, in four-float rows so the Swift and Metal layouts cannot disagree.
struct StarlightUniforms {
    var a = SIMD4<Float>(0, 0.65, 0.5, 1.6)        // time, intensity (0…1.4), speed, aspect
    var b = SIMD4<Float>(0, 0, 0.3, 0.2)           // music energy (0…1), light theme (0/1), veil (0…1), luminance cap
    var c = SIMD4<Float>(4, -1, 0.6, 0.5)          // layers (1…4), shooting-star progress (< 0: none), its angle, its length
    var d = SIMD4<Float>(0.3, 0.2, 1440, 900)      // shooting-star start (0…1), resolution in pixels
    var base = SIMD4<Float>(0.05, 0.05, 0.06, 1)
    var pal0 = SIMD4<Float>(0.8, 0.66, 0.43, 1)
    var pal1 = SIMD4<Float>(0.35, 0.40, 0.75, 1)
    var pal2 = SIMD4<Float>(0.62, 0.34, 0.60, 1)
    var e = SIMD4<Float>(1, 1, 1, 1)               // twinkle on (0/1), star tint (rgb, brightest component 1)
}

/// The settings, the theme and the cover turned into uniforms. Pure, so the mapping can be tested.
enum StarlightModel {
    static func speed(_ s: StarlightSettings) -> Float { Float(Look.lerp(0.12, 1.8, s.motion)) }
    static func intensity(_ s: StarlightSettings) -> Float { Float(Look.lerp(0.25, 1.3, s.intensity)) }
    /// The nebula's share of music energy: 0 when the reaction is off.
    static func reaction(_ s: StarlightSettings, energy: Float) -> Float { s.reacts ? min(1, max(0, energy)) * Float(s.reaction) * 1.6 : 0 }

    /// Low-band energy (0…1) from the analyser's bars (dB, low frequencies first): the loudest of the lowest bands, eased into 0…1 between −60 and −18 dB.
    static func energy(bars: [Float]) -> Float {
        guard !bars.isEmpty else { return 0 }
        let low = bars.prefix(max(1, bars.count / 8))
        let db = low.max() ?? -120
        return min(1, max(0, (db + 60) / 42))
    }

    /// Three colours for the nebula from a cover: its accent and two corners of its grid, lifted to a lively but not harsh level; or the theme's
    /// own accents with a deep violet when there is no cover.
    static func nebula(palette: ArtPalette?, theme: Theme) -> [SIMD4<Float>] {
        func v(_ c: RGB) -> SIMD4<Float> { SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1) }
        func tune(_ c: RGB) -> RGB { let h = c.hsb; return RGB(h: h.h, s: min(0.85, max(0.35, h.s * 1.1)), v: theme.isLight ? 0.82 : 0.95) }
        guard let p = palette, p != .neutral, p.grid.count == 9 else {
            return [v(theme.accentRGB.mixed(with: RGB(1, 1, 1), theme.isLight ? 0.3 : 0.0)), v(RGB(0.34, 0.38, 0.78)), v(RGB(0.62, 0.30, 0.58))]
        }
        return [v(tune(p.accent)), v(tune(p.grid[2])), v(tune(p.grid[6]))]
    }

    /// The colour the stars are multiplied by: white (none), the accent, or the cover's accent; scaled so its brightest part is 1 and the sky is no dimmer.
    static func starTint(_ t: StarTint, theme: Theme, palette: ArtPalette?) -> SIMD3<Float> {
        let c: RGB
        switch t {
        case .white: return SIMD3(1, 1, 1)
        case .accent: c = theme.accentRGB
        case .cover: c = (palette.map { $0 != .neutral } ?? false) ? palette!.accent : theme.accentRGB
        }
        let m = max(c.r, c.g, c.b, 0.001)
        // a hint of white is kept, so a deep accent still reads as stars
        func f(_ v: Double) -> Float { Float(0.25 + 0.75 * v / m) }
        return SIMD3(f(c.r), f(c.g), f(c.b))
    }

    static func uniforms(time: Double, settings s: StarlightSettings, theme: Theme, palette: ArtPalette?, energy: Float, veil: Float, size: CGSize,
                         shoot: StarlightSky.Shot?, layers: Int = 4) -> StarlightUniforms {
        var u = StarlightUniforms()
        let aspect = Float(max(0.5, size.width / max(1, size.height)))
        u.a = SIMD4(Float(time), intensity(s), speed(s), aspect)
        let base = theme.canvasRGB
        // the most the sky may lift the page above its own colour (dark) or sink it below (light): the theme's backdrop allowance, so text keeps its contrast
        let cap = Float(WCAG.luminance(theme.backdropLimitRGB))
        u.b = SIMD4(reaction(s, energy: energy), theme.isLight ? 1 : 0, veil, cap)
        u.c = SIMD4(Float(max(1, min(4, layers))), shoot.map { Float($0.progress) } ?? -1, Float(shoot?.angle ?? 0.6), Float(shoot?.length ?? 0.5))
        u.d = SIMD4(Float(shoot?.start.x ?? 0.3), Float(shoot?.start.y ?? 0.2), Float(size.width), Float(size.height))
        u.base = SIMD4(Float(base.r), Float(base.g), Float(base.b), 1)
        let n = nebula(palette: palette, theme: theme)
        u.pal0 = n[0]; u.pal1 = n[1]; u.pal2 = n[2]
        let tint = starTint(s.tint, theme: theme, palette: palette)
        u.e = SIMD4(s.twinkle ? 1 : 0, tint.x, tint.y, tint.z)
        return u
    }
}

/// When the sky moves, and at what rate. Pure.
enum StarlightPolicy {
    enum Mode: Equatable { case live30, live15, still }
    static func mode(visible: Bool, appActive: Bool, lowPower: Bool, reduceMotion: Bool, snapshot: Bool) -> Mode {
        if snapshot || reduceMotion { return .still }
        if !visible || !appActive { return .still }
        return lowPower ? .live15 : .live30
    }
    /// Whether the clock may run at all (a still sky draws once).
    static func animates(_ m: Mode) -> Bool { m != .still }
    /// Layers of stars and the share of the screen's pixels drawn: a low-power GPU gets two layers at 70 %.
    static func quality(lowPowerGPU: Bool) -> (layers: Int, scale: CGFloat) { lowPowerGPU ? (2, 0.7) : (4, 1.0) }
}

/// The shooting stars: one every 25 to 70 seconds, a second long, at a random place and angle in the upper half; none while someone is typing.
struct StarlightSky {
    struct Shot: Equatable { var progress: Double; var start: CGPoint; var angle: Double; var length: Double }
    private(set) var next: Double
    private var current: (begin: Double, start: CGPoint, angle: Double, length: Double)?
    static let duration = 1.15
    var rng: () -> Double
    /// How long to wait between two stars (nil: none at all).
    var interval: (min: Double, max: Double)? = ShootingStars.rare.interval

    init(now: Double = 0, interval: (min: Double, max: Double)? = ShootingStars.rare.interval, rng: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.rng = rng
        self.interval = interval
        next = now + (interval.map { 6 + rng() * ($0.min - 6 > 0 ? $0.min - 6 : 4) } ?? .infinity)
    }

    /// Changes the pace (the setting was changed): the next star is scheduled afresh from `time`.
    mutating func setInterval(_ i: (min: Double, max: Double)?, at time: Double) {
        guard i?.min != interval?.min || i?.max != interval?.max else { return }
        interval = i
        next = i.map { time + $0.min * 0.4 + rng() * ($0.max - $0.min) * 0.6 } ?? .infinity
    }

    /// The shot to draw at `time`, if any. `quiet`: a text field has focus, the app is in the background or the sky is still.
    mutating func shot(at time: Double, quiet: Bool) -> Shot? {
        if let c = current {
            let p = (time - c.begin) / Self.duration
            if p >= 1 { current = nil; next = interval.map { time + $0.min + rng() * ($0.max - $0.min) } ?? .infinity } else { return Shot(progress: p, start: c.start, angle: c.angle, length: c.length) }
        }
        guard interval != nil, !quiet, time >= next else { return nil }
        let start = CGPoint(x: 0.1 + rng() * 0.7, y: 0.05 + rng() * 0.4)
        let angle = 0.35 + rng() * 0.5            // down and to the right
        current = (time, start, angle, 0.30 + rng() * 0.2)
        return Shot(progress: 0, start: start, angle: angle, length: current!.length)
    }
}

// MARK: - The GPU

final class StarlightRenderer: @unchecked Sendable {
    nonisolated(unsafe) static let shared: StarlightRenderer? = StarlightRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// A small GPU (integrated, low power) gets the lighter sky.
    var isLowPowerGPU: Bool { device.isLowPower }

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        guard let lib = try? d.makeLibrary(source: Self.source, options: nil),
              let vf = lib.makeFunction(name: "sl_vertex"), let ff = lib.makeFunction(name: "sl_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vf; desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? d.makeRenderPipelineState(descriptor: desc) else { return nil }
        device = d; queue = q; pipeline = p
    }

    func encode(_ pass: MTLRenderPassDescriptor, in cb: MTLCommandBuffer, uniforms: StarlightUniforms) {
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<StarlightUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// One frame as an image (snapshots, tests and the still sky): rendered offscreen and read back. Also reports the GPU time of the pass.
    func image(width: Int, height: Int, uniforms: StarlightUniforms) -> (image: CGImage, gpuSeconds: Double)? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex; pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        var u = uniforms; u.d.z = Float(width); u.d.w = Float(height)
        encode(pass, in: cb, uniforms: u)
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // BGRA → RGBA
        var i = 0
        while i < bytes.count { let b = bytes[i]; bytes[i] = bytes[i + 2]; bytes[i + 2] = b; i += 4 }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return (img, max(0, cb.gpuEndTime - cb.gpuStartTime))
    }

    // MARK: the shader

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct U { float4 a, b, c, d, base, pal0, pal1, pal2, e; };
    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut sl_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;
    }

    static float hash11(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    static float2 hash22(float2 p) { return float2(hash11(p), hash11(p + 19.19)); }
    static float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
        float a = hash11(i), b = hash11(i + float2(1, 0)), c = hash11(i + float2(0, 1)), d = hash11(i + float2(1, 1));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }
    static float fbm(float2 p) { float v = 0.0, amp = 0.5; for (int i = 0; i < 3; i++) { v += amp * vnoise(p); p = p * 2.03 + 7.1; amp *= 0.5; } return v; }
    static float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    // one layer of stars: a star in some of the cells, its neighbours' glow included when `reach` is 1
    static float3 stars(float2 uv, float scale, float2 drift, float t, float density, float twinkle, float bloom, float seed, float sizeMul, int reach) {
        float2 g = uv * scale + drift * t;
        float2 id = floor(g), f = fract(g);
        float3 acc = float3(0.0);
        for (int j = -reach; j <= reach; j++) {
            for (int i = -reach; i <= reach; i++) {
                float2 cell = id + float2(float(i), float(j));
                float h = hash11(cell + seed);
                if (h > density) continue;
                float2 o = 0.2 + 0.6 * hash22(cell + seed * 3.7);
                float2 d = f - float2(float(i), float(j)) - o;
                float s = (0.016 + 0.05 * pow(hash11(cell * 1.37 + seed), 3.0)) * sizeMul;
                float r = length(d);
                float core = smoothstep(s, s * 0.12, r);
                float glow = exp(-r * r / (s * s * 9.0)) * bloom * smoothstep(0.02, 0.05, s) * 0.5;
                float ph = hash11(cell + 91.7) * 6.2831;
                float rate = 0.5 + 2.0 * hash11(cell + 12.3);
                float tw = 1.0 - twinkle * (0.5 + 0.5 * sin(t * rate + ph));
                float3 col = mix(float3(1.0, 0.80, 0.60), float3(0.70, 0.83, 1.0), hash11(cell + 5.5));
                col = mix(col, float3(1.0), 0.35);
                acc += col * (core + glow) * tw;
            }
        }
        return acc;
    }

    fragment float4 sl_fragment(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
        float t = u.a.x, I = u.a.y, S = u.a.z, aspect = u.a.w;
        float react = u.b.x, light = u.b.y, veil = u.b.z, cap = u.b.w;
        int layers = int(u.c.x);
        float2 uv = float2(in.uv.x * aspect, in.uv.y);
        float3 base = u.base.rgb;

        // nebula: noise warped by noise, drifting slowly
        float tt = t * 0.03 * S;
        float2 q = float2(fbm(uv * 1.2 + tt), fbm(uv * 1.2 + float2(5.2, 1.3) - tt));
        float2 r = float2(fbm(uv * 1.5 + 2.0 * q + float2(1.7, 9.2) + tt * 0.7), fbm(uv * 1.5 + 2.0 * q + float2(8.3, 2.8) - tt * 0.6));
        float n = fbm(uv * 1.3 + 2.2 * r);
        float band = smoothstep(0.30, 0.78, n) * (0.45 + 0.55 * (1.0 - in.uv.y * 0.75));
        float3 neb = mix(u.pal0.rgb, u.pal1.rgb, clamp(q.x * 1.5, 0.0, 1.0));
        neb = mix(neb, u.pal2.rgb, clamp(r.y * 1.3 - 0.15, 0.0, 1.0) * 0.7);
        float amount = I * (0.60 + 0.40 * react);
        float vig = smoothstep(1.2, 0.2, length((in.uv - 0.5) * float2(aspect, 1.0) * 1.1));

        // stars: four depths, nearer ones larger, brighter and faster
        float3 st = float3(0.0);
        float tw = 0.5 * S, tk = u.e.x;
        if (layers >= 4) st += 0.30 * stars(uv, 38.0, float2(0.010, 0.002), t * S, 0.40, 0.30 * tk, 0.0, 3.0, 1.0, 0);
        if (layers >= 3) st += 0.45 * stars(uv, 22.0, float2(0.006, 0.0015), t * S, 0.34, 0.45 * tk, 0.0, 7.0, 1.0, 0);
        st += 0.75 * stars(uv, 12.0, float2(0.0035, 0.001), t * S, 0.30, 0.55 * tk, 0.6, 11.0, 1.1, 1);
        st += 1.00 * stars(uv, 6.0, float2(0.002, 0.0006), t * S, 0.26, 0.60 * tk, 1.0, 19.0, 1.3, 1);
        st *= (0.35 + 0.65 * I) * (0.7 + 0.3 * tw + 0.3 * react);
        st *= u.e.yzw;

        float3 col;
        if (light < 0.5) {
            float3 add = neb * band * (0.42 * amount) * (0.35 + 0.65 * vig);
            float lb = lum(base), la = lum(add), allowed = max(0.0, cap - lb);
            if (la > allowed) add *= allowed / max(la, 1e-4);
            col = base + add * (1.0 - veil);
            col *= mix(0.80, 1.0, vig);                                    // the deep vignette
            col += st * (1.0 - veil * 0.7) * mix(0.55, 1.0, vig);
        } else {
            // dusk: the paper tone, warmed towards the cover's colours; stars are fine brass specks
            float3 dusk = mix(float3(1.0, 0.88, 0.76), neb, 0.45);
            col = mix(base, base * dusk, band * 0.60 * amount * (1.0 - veil * 0.6));
            col = mix(col, base * float3(0.96, 0.89, 0.83), smoothstep(0.35, 1.0, in.uv.y) * 0.35 * amount);
            col *= mix(0.94, 1.0, vig);
            float s = clamp(lum(st) * 0.9, 0.0, 1.0) * (1.0 - veil * 0.6) * min(1.0, I);
            col = mix(col, float3(0.50, 0.37, 0.17), s * 0.5);
            float lc = lum(col), lb = lum(base);
            if (lc < cap) col = mix(col, base, clamp((cap - lc) / max(lb - lc, 1e-4), 0.0, 1.0));
        }

        // a shooting star: a bright head and a fading trail, while one is in flight
        if (u.c.y >= 0.0 && light < 0.5) {
            float p = u.c.y;
            float2 s0 = float2(u.d.x * aspect, u.d.y);
            float2 dir = float2(cos(u.c.z), sin(u.c.z));
            float len = u.c.w;
            float2 head = s0 + dir * len * p * 2.2;
            float2 pp = uv - head;
            float along = dot(pp, -dir), perp = abs(dot(pp, float2(-dir.y, dir.x)));
            float fade = sin(3.14159 * p);
            float trail = (along > 0.0 && along < len * 0.6) ? exp(-along / (len * 0.16)) : 0.0;
            float line = trail * exp(-perp * perp / 0.0000030);
            float headGlow = exp(-dot(pp, pp) / 0.00006);
            col += float3(1.0, 0.95, 0.86) * (line * 0.9 + headGlow * 0.9) * fade * (1.0 - veil * 0.8);
        }

        col += (hash11(in.pos.xy + fract(t)) - 0.5) / 255.0;                // dither, so the slow gradients do not band
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }
    """
}

// MARK: - The view

/// A Metal view that draws the sky. It owns the clock, the shooting-star schedule and the pause rules (see `StarlightPolicy`).
final class StarlightMTKView: MTKView, MTKViewDelegate {
    var settings = StarlightSettings()
    var theme = Theme.aureon
    var palette: ArtPalette?
    var veil: Float = 0.3
    /// Low-band energy from the analysis, read on every frame (set by the owner; it only reads published values).
    var energy: () -> Float = { 0 }
    var reduceMotionOverride: Bool?

    private let renderer: StarlightRenderer
    private let started = CACurrentMediaTime()
    private var sky = StarlightSky()
    private var observers: [NSObjectProtocol] = []
    private(set) var mode = StarlightPolicy.Mode.live30
    private var smoothedEnergy: Float = 0
    private let quality: (layers: Int, scale: CGFloat)

    init(renderer: StarlightRenderer) {
        self.renderer = renderer
        quality = StarlightPolicy.quality(lowPowerGPU: renderer.isLowPowerGPU)
        super.init(frame: .zero, device: renderer.device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        autoResizeDrawable = true
        layer?.isOpaque = true
        sky = StarlightSky(now: 0, interval: settings.shooting.interval)
        syncRunning()
    }
    required init(coder: NSCoder) { fatalError("not used") }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        let nc = NotificationCenter.default
        let sync: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.syncRunning() } }
        if let w = window { observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main, using: sync)) }
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: sync))
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: sync))
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: sync))
        observers.append(nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main, using: sync))
        syncRunning()
    }

    override func layout() {
        super.layout()
        // fewer pixels on a small GPU: the sky is soft, so nobody sees it
        let s = (window?.backingScaleFactor ?? 2) * min(1, quality.scale)
        drawableSize = CGSize(width: max(2, bounds.width * s), height: max(2, bounds.height * s))
        if !StarlightPolicy.animates(mode) { needsDisplay = true }
    }

    /// Applies the pause rules: live, slow, or one still frame.
    func syncRunning() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let m = StarlightPolicy.mode(visible: visible || window == nil, appActive: NSApp?.isActive ?? true, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                     reduceMotion: reduceMotion, snapshot: HWPanel.snapshot)
        mode = m
        switch m {
        case .live30: preferredFramesPerSecond = 30; enableSetNeedsDisplay = false; isPaused = false
        case .live15: preferredFramesPerSecond = 15; enableSetNeedsDisplay = false; isPaused = false
        case .still: isPaused = true; enableSetNeedsDisplay = true; needsDisplay = true
        }
    }

    /// The settings or the cover changed: a still sky is drawn again.
    func refresh() { if !StarlightPolicy.animates(mode) { needsDisplay = true } }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { refresh() }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let rp = currentRenderPassDescriptor, let cb = renderer.queue.makeCommandBuffer() else { return }
        let animating = StarlightPolicy.animates(mode)
        let t = animating ? CACurrentMediaTime() - started + 30 : 30
        let typing = NSApp?.keyWindow?.firstResponder is NSText
        sky.setInterval(settings.shooting.interval, at: t)
        let shot = animating ? sky.shot(at: t, quiet: typing || !(NSApp?.isActive ?? true)) : nil
        let e = animating ? energy() : 0
        smoothedEnergy += (e - smoothedEnergy) * (e > smoothedEnergy ? 0.35 : 0.08)
        let u = StarlightModel.uniforms(time: t, settings: settings, theme: theme, palette: palette, energy: smoothedEnergy, veil: veil,
                                        size: CGSize(width: drawableSize.width, height: drawableSize.height), shoot: shot, layers: quality.layers)
        renderer.encode(rp, in: cb, uniforms: u)
        cb.present(drawable)
        cb.commit()
    }
}

/// The sky as a SwiftUI view. `still` draws it once (snapshots, Reduce Motion), as an image.
struct StarlightLayer: NSViewRepresentable {
    let renderer: StarlightRenderer
    let settings: StarlightSettings
    let theme: Theme
    let palette: ArtPalette?
    let veil: Float
    let energy: () -> Float

    func makeNSView(context: Context) -> StarlightMTKView {
        let v = StarlightMTKView(renderer: renderer)
        apply(v); return v
    }
    func updateNSView(_ v: StarlightMTKView, context: Context) { apply(v); v.refresh() }
    private func apply(_ v: StarlightMTKView) { v.settings = settings; v.theme = theme; v.palette = palette; v.veil = veil; v.energy = energy }
}

/// What sits behind the pages when the backdrop is Starlight: the live sky where Metal is available; otherwise (and in snapshots) one frame of it as an
/// image, or nothing, leaving the soft wash under it.
struct StarlightBackdrop: View {
    @EnvironmentObject var m: PlayerModel
    let theme: Theme
    let palette: ArtPalette
    let stage: Bool

    var body: some View {
        if let r = StarlightRenderer.shared {
            if HWPanel.snapshot { still(r) }
            else {
                StarlightLayer(renderer: r, settings: m.look.starlight, theme: theme, palette: palette, veil: veil, energy: { [weak player = m.player] in
                    guard let player else { return 0 }
                    return StarlightModel.energy(bars: player.analysis.frame().bars)
                })
            }
        }
    }

    /// Pages under text take more of a veil than the stage, where the sky is the whole picture.
    private var veil: Float { stage ? 0.0 : 0.30 }

    private func still(_ r: StarlightRenderer) -> some View {
        let t = Double(ProcessInfo.processInfo.environment["AUREON_STARTIME"] ?? "") ?? 40
        let size = CGSize(width: 1440, height: 900)
        let u = StarlightModel.uniforms(time: t, settings: m.look.starlight, theme: theme, palette: palette, energy: 0.3, veil: veil, size: size, shoot: nil)
        return Group {
            if let img = r.image(width: 1440, height: 900, uniforms: u)?.image {
                GeometryReader { g in Image(decorative: img, scale: 1).resizable().interpolation(.high).frame(width: g.size.width, height: g.size.height) }
            }
        }
    }
}

/// Settings → Appearance → Starlight: how dense the sky is, how often a star shoots across it, whether the stars twinkle, their colour, the speed and how
/// much the music moves it.
struct StarlightGroup: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        Card(title: "Starlight", subtitle: "A sky of stars and a slow nebula in the cover's colours") {
            LookSliderRow(title: "Density", hint: "How many stars, and how bright the sky is.", value: $m.look.starlight.intensity, defaultValue: StarlightSettings().intensity)
            VStack(alignment: .leading, spacing: 8) {
                Text("Shooting stars").font(Typo.sans(13, .medium))
                HStack(spacing: 16) {
                    SegmentedChoice(selection: $m.look.starlight.shooting, items: ShootingStars.allCases, label: { $0.title }).frame(width: 360)
                    Text(m.look.starlight.shooting == .off ? "None" : "Never while you are typing").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
            }
            HStack(spacing: 12) {
                Text("Twinkle: the stars brighten and dim a little.").font(Typo.sans(13))
                Spacer(minLength: 8)
                Toggle("", isOn: $m.look.starlight.twinkle).accessibilityLabel("Twinkle").fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Star colour").font(Typo.sans(13, .medium))
                SegmentedChoice(selection: $m.look.starlight.tint, items: StarTint.allCases, label: { $0.title }).frame(width: 280)
            }
            LookSliderRow(title: "Motion speed", hint: "How fast the sky drifts. It stands still under Reduce Motion.", value: $m.look.starlight.motion, defaultValue: StarlightSettings().motion)
            HStack(spacing: 12) {
                Text("Music reaction: the low notes brighten the nebula a little.").font(Typo.sans(13))
                Spacer(minLength: 8)
                Toggle("", isOn: $m.look.starlight.reacts).accessibilityLabel("Music reaction").fixedSize()
            }
            if m.look.starlight.reacts {
                LookSliderRow(title: "Reaction amount", value: $m.look.starlight.reaction, defaultValue: StarlightSettings().reaction)
            }
            Text("It rests while the window is hidden or the app is in the background, and runs at half rate in Low Power Mode.").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
        }
    }
}

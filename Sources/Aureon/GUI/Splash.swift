import AppKit
import QuartzCore
import CoreImage

// The launch animation: the Aureon mark appears, its ring turns, a star leaves the ring and shoots out to the right, and the name comes out of the star's
// trail. A small borderless window shows it while the real start-up work goes on in parallel; the main window then fades in as the splash fades out.
// Everything is drawn once into bitmaps and moved by Core Animation (opacity, scale, rotation, position, mask), so the main thread draws nothing per frame.

enum SplashPolicy {
    /// The animation itself, then the dissolve into the main window.
    static let duration = 2.6
    static let dissolve = 0.45
    /// The splash never keeps the app waiting longer than this, whatever the start-up does.
    static let hardCap = 4.0
    /// With Reduce Motion: the finished mark and name, held this long, then a plain fade.
    static let reducedHold = 0.6
    static let reducedDissolve = 0.2
    static let size = CGSize(width: 520, height: 320)
    static let settingKey = "aureon.launchAnimation"

    /// Whether the animation is shown at all: never in snapshots, tests or with AUREON_NO_SPLASH, and not when the setting is off.
    static func enabled(environment: [String: String], setting: Bool) -> Bool {
        if environment["AUREON_NO_SPLASH"] != nil || environment["AUREON_SNAPSHOT"] != nil || environment["AUREON_TESTING"] != nil { return false }
        return setting
    }
    static var setting: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
}

/// When the splash is over: the animation is done and so is the start-up, or the cap is reached, or the person skipped it.
struct SplashFinish {
    var animationDone = false
    var startupDone = false
    var skipped = false
    func shouldFinish(elapsed: Double, hardCap: Double = SplashPolicy.hardCap) -> Bool { skipped || (animationDone && startupDone) || elapsed >= hardCap }
}

// MARK: - The scene

/// The layers of the animation and what each one does over time. A track is a pure function of time, so the same scene can be played by Core Animation
/// (sampled into keyframes) or frozen at any moment for a picture.
@MainActor
final class SplashScene {
    struct Track {
        let layer: CALayer
        let keyPath: String
        let value: (Double) -> Any
    }

    let root = CALayer()
    private(set) var tracks: [Track] = []
    let size: CGSize
    static let units = 1024.0
    /// Points per unit of the mark's own 1024-unit drawing.
    static let unit = 0.235

    // the moments of the choreography, in seconds
    static let planetIn = (0.0, 0.5), ringDraw = (0.4, 1.3), ringSettle = (1.3, 1.4), starFlight = (1.4, 1.9), wordReveal = (1.6, 2.3), trailFade = (1.9, 2.5)
    /// Where the planet sits (it never moves) and where the name starts.
    static let planetX = 158.0, wordX = 280.0

    private static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }
    private static func easeInOut(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    init(size: CGSize = SplashPolicy.size, scale: CGFloat = 2) {
        self.size = size
        let s = Self.unit
        let H = size.height
        root.bounds = CGRect(origin: .zero, size: size)
        root.position = CGPoint(x: size.width / 2, y: size.height / 2)
        root.cornerRadius = 12
        root.masksToBounds = true
        root.contentsScale = scale
        root.backgroundColor = Theme.named("obsidian").canvasRGB.cg

        // the faint starlight behind everything
        let stars = CALayer()
        stars.frame = root.bounds
        stars.contents = BackdropRenderer.stars(width: 1040, height: 640, count: 70, seed: 11, ink: Theme.named("obsidian").inkRGB, accent: Theme.named("obsidian").accentRGB)
        stars.contentsGravity = .resizeAspectFill
        stars.opacity = 0.5
        root.addSublayer(stars)
        let wash = CAGradientLayer()
        wash.frame = root.bounds
        wash.type = .radial
        wash.colors = [Theme.named("obsidian").canvasRGB.mixed(with: Theme.named("obsidian").accentRGB, 0.10).cg, Theme.named("obsidian").canvasRGB.cg]
        wash.startPoint = CGPoint(x: 0.4, y: 0.5); wash.endPoint = CGPoint(x: 1.05, y: 1.1)
        wash.opacity = 0.9
        root.insertSublayer(wash, below: stars)

        // the mark, in its own square (1024 units): the ring's glow, the back of the ring (drawn behind the planet), the planet (opaque), the front of the ring
        // (drawn over it), and a glowing head that runs along the ring as it draws itself. The planet never moves.
        let logoSide = Self.units * s
        let group = CALayer()
        group.name = "mark"
        group.bounds = CGRect(x: 0, y: 0, width: logoSide, height: logoSide)
        group.anchorPoint = CGPoint(x: 0.5, y: 1 - 566 / Self.units)
        let centreY = H / 2
        group.position = CGPoint(x: Self.planetX, y: centreY)
        root.addSublayer(group)
        func bitmapLayer(_ name: String, _ image: CGImage?) -> CALayer {
            let l = CALayer()
            l.name = name
            l.frame = group.bounds
            l.contents = image
            l.contentsScale = scale
            l.contentsGravity = .resize
            group.addSublayer(l)
            return l
        }
        /// A stroke along part of the ring, in the ring's gold, as a gradient seen through a stroked path.
        func strokeLayer(_ name: String, from p0: Double, to p1: Double, rx: Double, ry: Double, cy: Double, width: Double, color: CGColor? = nil, opacity: Float = 1) -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.name = name
            shape.frame = group.bounds
            shape.path = Self.arc(from: p0, to: p1, rx: rx, ry: ry, cy: cy)
            shape.fillColor = nil
            shape.strokeColor = color ?? NSColor.white.cgColor
            shape.lineWidth = CGFloat(width * s)
            shape.lineCap = .round
            shape.strokeStart = 0; shape.strokeEnd = 0
            if color != nil { shape.opacity = opacity; group.addSublayer(shape); return shape }
            let gradient = CAGradientLayer()
            gradient.name = name + ".gold"
            gradient.frame = group.bounds
            gradient.colors = [0xE7A947, 0xFBE3B0, 0xFFFAF0, 0xF6D593, 0xD9913A].map { NSColor(srgbRed: CGFloat(($0 >> 16) & 255) / 255, green: CGFloat(($0 >> 8) & 255) / 255, blue: CGFloat($0 & 255) / 255, alpha: 1).cgColor }
            gradient.locations = [0, 0.3, 0.55, 0.85, 1]
            gradient.startPoint = CGPoint(x: (512 - 432) / Self.units, y: 0.5); gradient.endPoint = CGPoint(x: (512 + 432) / Self.units, y: 0.5)
            gradient.mask = shape
            group.addSublayer(gradient)
            return shape
        }
        let art = SplashArt(unit: s, scale: scale)
        let glow = bitmapLayer("ring.glow", art.ringGlow)
        let bandWidth = 30.0, cyBand = 0.0, rxBand = 418.0, ryBand = 103.0
        let pi = Double.pi
        // the stroke is one closed loop, split at the ring's left and right ends: from the top (hidden behind the planet) to the right end; across the front to the
        // left end; and from the left end back to the top. The two back pieces sit under the planet, the front piece over it.
        let backA = strokeLayer("ring.back.A", from: 0, to: pi / 2, rx: rxBand, ry: ryBand, cy: cyBand, width: bandWidth)
        let backC = strokeLayer("ring.back.C", from: 3 * pi / 2, to: 2 * pi, rx: rxBand, ry: ryBand, cy: cyBand, width: bandWidth)
        let ringBackBitmap = bitmapLayer("ring.bitmap.back", art.ringBack)
        let headBack = bitmapLayer("head.back", art.head)
        let planet = bitmapLayer("planet", art.planet)
        let frontB = strokeLayer("ring.front.B", from: pi / 2, to: 3 * pi / 2, rx: rxBand, ry: ryBand, cy: cyBand, width: bandWidth)
        // the fine lines of the front of the ring, drawn after it by a short stagger
        let lines: [(CAShapeLayer, Double)] = [
            (strokeLayer("ring.front.line.1", from: pi / 2, to: 3 * pi / 2, rx: 404, ry: 87, cy: -15, width: 5, color: NSColor(srgbRed: 0.94, green: 0.64, blue: 0.24, alpha: 1).cgColor), 1),
            (strokeLayer("ring.front.line.2", from: pi / 2, to: 3 * pi / 2, rx: 414, ry: 100, cy: -5, width: 2, color: NSColor(srgbRed: 0.73, green: 0.51, blue: 0.18, alpha: 1).cgColor, opacity: 0.38), 2),
            (strokeLayer("ring.front.line.3", from: pi / 2, to: 3 * pi / 2, rx: 409, ry: 94, cy: -10, width: 2, color: NSColor(srgbRed: 0.73, green: 0.51, blue: 0.18, alpha: 1).cgColor, opacity: 0.38), 3),
        ]
        let ringFrontBitmap = bitmapLayer("ring.bitmap.front", art.ringFront)
        let headFront = bitmapLayer("head.front", art.head)
        for l in [ringBackBitmap, ringFrontBitmap] { l.opacity = 0 }
        for h in [headBack, headFront] { h.bounds = CGRect(x: 0, y: 0, width: 140 * s, height: 140 * s); h.opacity = 0 }
        // the strokes' gradient parents (for opacity), found by name
        func gold(_ name: String) -> CALayer { group.sublayers!.first { $0.name == name + ".gold" }! }

        // the star that leaves the ring, and its trail
        let a = Self.scenePoint(Self.ringPoint(phi: .pi / 2, rx: rxBand, ry: ryBand, cy: cyBand)), b = CGPoint(x: 490, y: centreY + 24)
        let trail = CAShapeLayer()
        let trailPath = CGMutablePath(); trailPath.move(to: a); trailPath.addLine(to: b)
        trail.path = trailPath
        trail.fillColor = nil
        trail.strokeColor = NSColor.white.cgColor
        trail.lineWidth = 1.6; trail.lineCap = .round
        trail.strokeStart = 0; trail.strokeEnd = 0
        let trailGradient = CAGradientLayer()
        trailGradient.frame = root.bounds
        trailGradient.colors = [NSColor(srgbRed: 0.91, green: 0.58, blue: 0.18, alpha: 0).cgColor, NSColor(srgbRed: 0.97, green: 0.85, blue: 0.55, alpha: 0.9).cgColor, NSColor(srgbRed: 1, green: 0.98, blue: 0.9, alpha: 1).cgColor]
        trailGradient.locations = [0, 0.7, 1]
        trailGradient.startPoint = CGPoint(x: a.x / size.width, y: a.y / size.height)
        trailGradient.endPoint = CGPoint(x: b.x / size.width, y: b.y / size.height)
        trail.frame = root.bounds
        trailGradient.mask = trail
        root.addSublayer(trailGradient)
        let starSide = 256 * s
        let star = CALayer()
        star.bounds = CGRect(x: 0, y: 0, width: starSide, height: starSide)
        star.contents = art.star; star.contentsScale = scale
        star.position = a
        root.addSublayer(star)

        // the name, revealed along the trail
        let word = CATextLayer()
        let font = Self.wordFont(30)
        let para = NSMutableParagraphStyle(); para.alignment = .left
        word.string = NSAttributedString(string: "AUREON", attributes: [.font: font, .kern: 11, .foregroundColor: NSColor(srgbRed: 0.97, green: 0.90, blue: 0.74, alpha: 1), .paragraphStyle: para])
        word.alignmentMode = .left
        word.bounds = CGRect(x: 0, y: 0, width: 230, height: 48)
        word.anchorPoint = CGPoint(x: 0, y: 0.5)
        word.position = CGPoint(x: Self.wordX, y: centreY)
        word.contentsScale = scale
        word.shadowColor = NSColor(srgbRed: 0.95, green: 0.7, blue: 0.3, alpha: 1).cgColor
        word.shadowOpacity = 0.35; word.shadowRadius = 8; word.shadowOffset = .zero
        let wipe = CAGradientLayer()
        wipe.bounds = CGRect(x: 0, y: 0, width: 260, height: 60)
        wipe.anchorPoint = CGPoint(x: 0, y: 0.5)
        wipe.position = CGPoint(x: 0, y: 24)
        wipe.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        wipe.locations = [0, 0.86, 1]
        wipe.startPoint = CGPoint(x: 0, y: 0.5); wipe.endPoint = CGPoint(x: 1, y: 0.5)
        word.mask = wipe
        root.addSublayer(word)

        // MARK: the tracks
        let pIn = Self.planetIn, draw = Self.ringDraw, settle = Self.ringSettle, fly = Self.starFlight, rev = Self.wordReveal, fade = Self.trailFade
        func num(_ v: Double) -> Any { NSNumber(value: v) }
        /// How far round the loop the ring has drawn itself, 0 to 1, eased.
        func loop(_ t: Double, stagger: Double = 0) -> Double { Self.easeInOut(Self.seg(t, draw.0 + stagger, draw.1)) }
        func part(_ p: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (p - a) / (b - a))) }
        tracks = [
            // the planet only fades in, and stays exactly where it is
            Track(layer: group, keyPath: "opacity") { t in num(Self.easeInOut(Self.seg(t, pIn.0, pIn.1))) },
            Track(layer: backA, keyPath: "strokeEnd") { t in num(part(loop(t), 0, 0.25)) },
            Track(layer: frontB, keyPath: "strokeEnd") { t in num(part(loop(t), 0.25, 0.75)) },
            Track(layer: backC, keyPath: "strokeEnd") { t in num(part(loop(t), 0.75, 1)) },
        ] + lines.map { (l, i) in
            Track(layer: l, keyPath: "strokeEnd") { t in num(part(loop(t, stagger: 0.12 * i), 0.25, 0.75)) }
        } + [
            // the loop is closed: the drawn strokes hand over to the exact artwork of the ring
            Track(layer: gold("ring.back.A"), keyPath: "opacity") { t in num(1 - Self.seg(t, settle.0, settle.1)) },
            Track(layer: gold("ring.back.C"), keyPath: "opacity") { t in num(1 - Self.seg(t, settle.0, settle.1)) },
            Track(layer: gold("ring.front.B"), keyPath: "opacity") { t in num(1 - Self.seg(t, settle.0, settle.1)) },
            Track(layer: ringBackBitmap, keyPath: "opacity") { t in num(Self.seg(t, settle.0, settle.1)) },
            Track(layer: ringFrontBitmap, keyPath: "opacity") { t in num(Self.seg(t, settle.0, settle.1)) },
        ] + lines.map { (l, _) in
            Track(layer: l, keyPath: "opacity") { t in num(1 - Self.seg(t, settle.0 + 0.1, settle.1 + 0.1)) }
        } + [
            // a soft glow pulse as the loop closes
            Track(layer: glow, keyPath: "opacity") { t in num(0.85 * Self.seg(t, settle.0, settle.0 + 0.15) * (1 - 0.5 * Self.seg(t, settle.0 + 0.15, 1.9))) },
            // the bright head that leads the stroke round: behind the planet on the back arcs, over it on the front arc
            Track(layer: headBack, keyPath: "position") { t in NSValue(point: NSPoint(x: Self.headPosition(loop(t)).x, y: Self.headPosition(loop(t)).y)) },
            Track(layer: headFront, keyPath: "position") { t in NSValue(point: NSPoint(x: Self.headPosition(loop(t)).x, y: Self.headPosition(loop(t)).y)) },
            Track(layer: headBack, keyPath: "opacity") { t in let p = loop(t); return num((p < 0.25 || p > 0.75 ? 1 : 0) * Self.seg(p, 0, 0.02) * (1 - Self.seg(p, 0.985, 1))) },
            Track(layer: headFront, keyPath: "opacity") { t in let p = loop(t); return num((p >= 0.25 && p <= 0.75 ? 1 : 0) * Self.seg(p, 0, 0.02) * (1 - Self.seg(p, 0.985, 1))) },
            Track(layer: star, keyPath: "opacity") { t in num(Self.seg(t, fly.0 - 0.05, fly.0 + 0.05) * (1 - Self.seg(t, 2.25, 2.55))) },
            Track(layer: star, keyPath: "position") { t in
                let p = Self.easeOut(Self.seg(t, fly.0, fly.1))
                return NSValue(point: NSPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p))
            },
            Track(layer: star, keyPath: "transform.scale") { t in num(0.30 + 0.34 * sin(.pi * min(1, Self.seg(t, fly.0, fly.1 + 0.3))) + 0.04) },
            Track(layer: trail, keyPath: "strokeEnd") { t in num(Self.easeOut(Self.seg(t, fly.0, fly.1))) },
            Track(layer: trail, keyPath: "strokeStart") { t in num(0.9 * Self.easeInOut(Self.seg(t, fade.0, fade.1))) },
            Track(layer: trailGradient, keyPath: "opacity") { t in num(1 - Self.seg(t, 2.2, 2.55)) },
            // the name: a soft pop out of the trail (fade, a mask wipe along the trail, and a small settle of its spacing; no bounce)
            Track(layer: word, keyPath: "opacity") { t in num(Self.seg(t, rev.0, rev.0 + 0.25)) },
            Track(layer: word, keyPath: "transform.scale.x") { t in num(1.07 - 0.07 * Self.easeOut(Self.seg(t, rev.0, rev.1))) },
            Track(layer: wipe, keyPath: "transform.scale.x") { t in num(Self.easeInOut(Self.seg(t, rev.0, rev.1)) * 1.02) },
        ]
        apply(at: 0)
        _ = (planet, trail)
    }

    // MARK: the ring's geometry (from the logo: an ellipse of 432 by 120 units about the planet's centre, tilted 15 degrees)

    /// A point on an ellipse about the planet's centre, in the mark's 1024-unit drawing: `phi` runs clockwise from the top (0 = top, pi/2 = the right end),
    /// `cy` moves the ellipse's centre along its own vertical axis before the tilt.
    static func ringPoint(phi: Double, rx: Double, ry: Double, cy: Double, tilt: Double = 15 * .pi / 180) -> CGPoint {
        let lx = rx * sin(phi), ly = cy - ry * cos(phi)
        let x = lx * cos(tilt) - ly * sin(tilt), y = lx * sin(tilt) + ly * cos(tilt)
        return CGPoint(x: 512 + x, y: 566 + y)              // y runs down, as in the SVG
    }
    /// A point of the mark's drawing, in the mark layer's own points (y up).
    static func layerPoint(_ unitsPoint: CGPoint) -> CGPoint { CGPoint(x: unitsPoint.x * unit, y: (units - unitsPoint.y) * unit) }
    /// A point of the mark layer, in the scene's points.
    static func scenePoint(_ unitsPoint: CGPoint, planetCentre: CGPoint = CGPoint(x: planetX, y: SplashPolicy.size.height / 2)) -> CGPoint {
        CGPoint(x: planetCentre.x + (unitsPoint.x - 512) * unit, y: planetCentre.y - (unitsPoint.y - 566) * unit)
    }
    /// The path of part of such an ellipse, in the mark layer's points.
    static func arc(from p0: Double, to p1: Double, rx: Double, ry: Double, cy: Double) -> CGPath {
        let path = CGMutablePath()
        let n = max(2, Int((abs(p1 - p0) / (.pi / 120)).rounded(.up)))
        for i in 0...n {
            let p = layerPoint(ringPoint(phi: p0 + (p1 - p0) * Double(i) / Double(n), rx: rx, ry: ry, cy: cy))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
    /// Where the bright head of the stroke is, in the mark layer's points, when the loop has drawn `progress` of itself.
    static func headPosition(_ progress: Double) -> CGPoint { layerPoint(ringPoint(phi: 2 * .pi * progress, rx: 418, ry: 103, cy: 0)) }

    /// The serif the interface uses for names: New York, light.
    static func wordFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .light)
        if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    /// Sets every layer to how it looks at `t` seconds (no animation).
    func apply(at t: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for tr in tracks { tr.layer.setValue(tr.value(t), forKeyPath: tr.keyPath) }
        CATransaction.commit()
    }

    /// Plays the whole scene on the compositor: each track sampled into keyframes, so nothing is computed per frame.
    func play(from now: CFTimeInterval = CACurrentMediaTime(), duration: Double = SplashPolicy.duration) {
        let rate = 60.0
        let n = Int(duration * rate)
        let times = (0...n).map { Double($0) / rate }
        for tr in tracks {
            let a = CAKeyframeAnimation(keyPath: tr.keyPath)
            a.values = times.map { tr.value($0) }
            a.keyTimes = times.map { NSNumber(value: $0 / duration) }
            a.calculationMode = .linear
            a.duration = duration
            a.beginTime = now
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            tr.layer.add(a, forKey: "splash." + tr.keyPath)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for tr in tracks { tr.layer.setValue(tr.value(duration), forKeyPath: tr.keyPath) }
        CATransaction.commit()
    }

    /// A picture of the scene at `t`, for the keyframe snapshots.
    func image(at t: Double, scale: CGFloat = 2) -> CGImage? {
        apply(at: t)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
        return ctx.makeImage()
    }

    /// Takes the animations off and lets go of everything.
    func tearDown() {
        func strip(_ l: CALayer) { l.removeAllAnimations(); l.mask = nil; l.sublayers?.forEach(strip); l.contents = nil }
        strip(root)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        tracks = []
    }
}

private extension RGB {
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

// MARK: - The artwork, from the logo's vector

/// The mark drawn once into bitmaps, from the same shapes and colours as Packaging/LogoMark.svg (1024 units): the ring (back and front halves, and a soft glow of
/// it), the planet with its lit rim, and the four-pointed star.
struct SplashArt {
    let ringBack: CGImage?
    let ringFront: CGImage?
    let ringGlow: CGImage?
    let planet: CGImage?
    let star: CGImage?
    /// The bright head that leads the ring as it draws itself: a small white-gold point in a soft glow.
    let head: CGImage?

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }
    private static func gradient(_ stops: [(CGFloat, UInt32)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { rgb($0.1) } as CFArray, locations: stops.map { $0.0 })!
    }

    /// A context in the mark's 1024-unit space with y running down, as in the SVG.
    private static func canvas(side: Double, unit: Double, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let px = Int((side * unit * Double(scale)).rounded(.up))
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let k = CGFloat(Double(px) / side)
        ctx.scaleBy(x: k, y: -k)
        ctx.translateBy(x: 0, y: -CGFloat(side))
        draw(ctx)
        return ctx.makeImage()
    }

    private static func ringPath() -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: -432, y: -120, width: 864, height: 240))
        p.addEllipse(in: CGRect(x: -404, y: -15 - 87, width: 808, height: 174))
        return p
    }
    private static func ringFill() -> CGGradient { gradient([(0, 0xE7A947), (0.3, 0xFBE3B0), (0.55, 0xFFFAF0), (0.85, 0xF6D593), (1, 0xD9913A)]) }

    private static func blurred(_ image: CGImage?, radius: Double) -> CGImage? {
        guard let image else { return nil }
        let input = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: radius]), let out = f.outputImage else { return image }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(out.cropped(to: input.extent), from: input.extent)
    }

    init(unit: Double, scale: CGFloat) {
        let U = SplashScene.units
        func inRing(_ ctx: CGContext, _ body: () -> Void) {
            ctx.saveGState()
            ctx.translateBy(x: 512, y: 566); ctx.rotate(by: 15 * .pi / 180)
            body()
            ctx.restoreGState()
        }
        ringBack = Self.canvas(side: U, unit: unit, scale: scale) { ctx in
            inRing(ctx) {
                ctx.setAlpha(0.92)
                ctx.addPath(Self.ringPath()); ctx.clip(using: .evenOdd)
                ctx.drawLinearGradient(Self.ringFill(), start: CGPoint(x: -432, y: 0), end: CGPoint(x: 432, y: 0), options: [])
            }
        }
        ringFront = Self.canvas(side: U, unit: unit, scale: scale) { ctx in
            inRing(ctx) {
                ctx.clip(to: CGRect(x: -520, y: -2, width: 1040, height: 220))
                ctx.saveGState()
                ctx.addPath(Self.ringPath()); ctx.setLineWidth(9); ctx.setStrokeColor(Self.rgb(0x060914)); ctx.strokePath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.addPath(Self.ringPath()); ctx.clip(using: .evenOdd)
                ctx.drawLinearGradient(Self.ringFill(), start: CGPoint(x: -432, y: 0), end: CGPoint(x: 432, y: 0), options: [])
                ctx.restoreGState()
                ctx.setStrokeColor(Self.rgb(0xF0A23C)); ctx.setLineWidth(5)
                ctx.strokeEllipse(in: CGRect(x: -404, y: -15 - 87, width: 808, height: 174))
                ctx.setStrokeColor(Self.rgb(0xB9822F, 0.38)); ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: -414, y: -5 - 100, width: 828, height: 200))
                ctx.strokeEllipse(in: CGRect(x: -409, y: -10 - 94, width: 818, height: 188))
            }
        }
        let glowFlat = Self.canvas(side: U, unit: unit, scale: scale) { ctx in
            inRing(ctx) {
                ctx.addPath(Self.ringPath()); ctx.clip(using: .evenOdd)
                ctx.setFillColor(Self.rgb(0xFFCF78)); ctx.fill(CGRect(x: -440, y: -130, width: 880, height: 260))
            }
        }
        ringGlow = Self.blurred(glowFlat, radius: 16 * unit * Double(scale) / 0.235 * 0.235)
        let bandFlat = Self.canvas(side: U, unit: unit, scale: scale) { ctx in
            ctx.addRect(CGRect(x: 0, y: 0, width: U, height: U))
            ctx.addEllipse(in: CGRect(x: 560 - 232, y: 622 - 232, width: 464, height: 464))
            ctx.clip(using: .evenOdd)
            ctx.addEllipse(in: CGRect(x: 512 - 238, y: 566 - 238, width: 476, height: 476)); ctx.clip()
            ctx.setFillColor(Self.rgb(0xF29A36)); ctx.fill(CGRect(x: 0, y: 0, width: U, height: U))
        }
        let band = Self.blurred(bandFlat, radius: 22 * unit * Double(scale))
        planet = Self.canvas(side: U, unit: unit, scale: scale) { ctx in
            let disc = CGRect(x: 512 - 238, y: 566 - 238, width: 476, height: 476)
            ctx.saveGState()
            ctx.addEllipse(in: disc); ctx.clip()
            let body = Self.gradient([(0, 0x4A64A6), (0.35, 0x22336A), (0.7, 0x0C1434), (1, 0x03050E)])
            ctx.drawRadialGradient(body, startCenter: CGPoint(x: 407, y: 433), startRadius: 0, endCenter: CGPoint(x: 436, y: 471), endRadius: 405, options: [.drawsAfterEndLocation])
            if let band {
                ctx.saveGState()
                ctx.setAlpha(0.95)
                ctx.translateBy(x: 0, y: U); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(band, in: CGRect(x: 0, y: 0, width: U, height: U))
                ctx.restoreGState()
            }
            ctx.restoreGState()
            ctx.setStrokeColor(Self.rgb(0x3A4F8C, 0.45)); ctx.setLineWidth(3); ctx.strokeEllipse(in: disc)
            // the lit rim: the planet's disc less a slightly shifted disc
            ctx.saveGState()
            ctx.addRect(CGRect(x: 0, y: 0, width: U, height: U))
            ctx.addEllipse(in: CGRect(x: 526 - 237, y: 582 - 237, width: 474, height: 474))
            ctx.clip(using: .evenOdd)
            ctx.addEllipse(in: disc); ctx.clip()
            ctx.drawLinearGradient(Self.gradient([(0, 0xFFF8E8), (0.45, 0xF8D99A), (1, 0xE9952F)]), start: CGPoint(x: 0.15 * U, y: 0.1 * U), end: CGPoint(x: 0.75 * U, y: 0.8 * U), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        head = Self.canvas(side: 140, unit: unit, scale: scale) { ctx in
            ctx.translateBy(x: 70, y: 70)
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Self.rgb(0xFFFDF2, 1), Self.rgb(0xFBE3B0, 0.75), Self.rgb(0xE9952F, 0.25), Self.rgb(0xE9952F, 0)] as CFArray, locations: [0, 0.18, 0.55, 1])!
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 70, options: [])
        }
        // the star: four points, a soft glow and a haze, on its own 256-unit square
        star = Self.canvas(side: 256, unit: unit, scale: scale) { ctx in
            ctx.translateBy(x: 128, y: 128)
            let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Self.rgb(0xFFD98A, 0.55), Self.rgb(0xFFD98A, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 120, options: [])
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: -118))
            p.addQuadCurve(to: CGPoint(x: 118, y: 0), control: CGPoint(x: 9, y: -9))
            p.addQuadCurve(to: CGPoint(x: 0, y: 118), control: CGPoint(x: 9, y: 9))
            p.addQuadCurve(to: CGPoint(x: -118, y: 0), control: CGPoint(x: -9, y: 9))
            p.addQuadCurve(to: CGPoint(x: 0, y: -118), control: CGPoint(x: -9, y: -9))
            p.closeSubpath()
            ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 10, color: Self.rgb(0xFFE2A0, 0.8)); ctx.setFillColor(Self.rgb(0xFFE2A0, 0.6)); ctx.addPath(p); ctx.fillPath(); ctx.restoreGState()
            ctx.addPath(p); ctx.clip()
            ctx.drawLinearGradient(Self.gradient([(0, 0xFFFBEF), (1, 0xF3CF86)]), start: CGPoint(x: -118, y: -118), end: CGPoint(x: 118, y: 118), options: [])
        }
    }
}

// MARK: - The window and its run

final class SplashWindow: NSWindow {
    override var canBecomeKey: Bool { false }       // it never takes the keyboard from the app's window
    override var canBecomeMain: Bool { false }
}

private final class SplashHost: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
}

@MainActor
final class SplashController {
    static let shared = SplashController()
    struct Config {
        var duration = SplashPolicy.duration
        var dissolve = SplashPolicy.dissolve
        var hardCap = SplashPolicy.hardCap
        var reducedHold = SplashPolicy.reducedHold
        var reducedDissolve = SplashPolicy.reducedDissolve
        var reduceMotion = false
        static let fast = Config(duration: 0.3, dissolve: 0.1, hardCap: 1.5, reducedHold: 0.1, reducedDissolve: 0.05, reduceMotion: false)
    }

    private(set) var window: SplashWindow?
    private(set) var isRunning = false
    private var scene: SplashScene?
    private var config = Config()
    private var finish = SplashFinish()
    private var started = Date()
    private var timer: Timer?
    private var monitor: Any?
    private var findMain: () -> NSWindow? = { nil }
    private var startupReady: () -> Bool = { true }
    private var main: NSWindow?
    private var appearObserver: NSObjectProtocol?
    private var completion: (() -> Void)?
    private(set) var concluding = false
    /// Which run a delayed clean-up belongs to, so a late one from an earlier run cannot cut a newer one short.
    private var generation = 0

    /// Shows the splash. `findMain` finds the app's main window (it may not exist yet); `startupReady` says whether the start-up work is done.
    func begin(config: Config = Config(), findMain: @escaping () -> NSWindow?, startupReady: @escaping () -> Bool, completion: (() -> Void)? = nil) {
        guard !isRunning else { return }
        isRunning = true; concluding = false; generation += 1
        self.config = config; self.findMain = findMain; self.startupReady = startupReady; self.completion = completion
        finish = SplashFinish(); started = Date()

        let scene = SplashScene()
        self.scene = scene
        let size = SplashPolicy.size
        let host = SplashHost(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer = CALayer()
        host.layer?.addSublayer(scene.root)
        scene.root.position = CGPoint(x: size.width / 2, y: size.height / 2)
        let w = SplashWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.level = .floating
        w.center()
        window = w
        hideMain()
        // the app's window appears while the splash runs: keep it clear until the dissolve
        appearObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.concluding, let win = n.object as? NSWindow, !(win is SplashWindow), win.canBecomeMain else { return }
                if win.alphaValue != 0 { win.alphaValue = 0; win.ignoresMouseEvents = true }
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] e in
            guard let self, self.isRunning, !self.concluding else { return e }
            MainActor.assumeIsolated { self.skip() }
            return nil          // the click or key that skips the splash does nothing else
        }
        w.alphaValue = 0
        w.orderFrontRegardless()
        // a short fade-in of the window itself, so the first frame is not a rectangle
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.12; w.animator().alphaValue = 1 }
        if config.reduceMotion { scene.apply(at: config.duration) } else { scene.play(duration: config.duration) }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func hideMain() {
        main = findMain()
        if let m = main { m.alphaValue = 0; m.ignoresMouseEvents = true }
    }

    private func tick() {
        guard isRunning, !concluding else { return }
        let elapsed = Date().timeIntervalSince(started)
        if main == nil { hideMain() }
        let animationLength = config.reduceMotion ? config.reducedHold : config.duration
        if elapsed >= animationLength { finish.animationDone = true }
        if main != nil && startupReady() { finish.startupDone = true }
        if finish.shouldFinish(elapsed: elapsed, hardCap: config.hardCap) { conclude() }
    }

    /// A click or a key: the splash ends at once (with a brief dissolve).
    func skip() { finish.skipped = true; if isRunning, !concluding { conclude(quick: true) } }

    private func conclude(quick: Bool = false) {
        guard isRunning, !concluding, let w = window else { return }
        concluding = true
        timer?.invalidate(); timer = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let o = appearObserver { NotificationCenter.default.removeObserver(o); appearObserver = nil }
        let main = self.main ?? findMain()
        let length = quick ? 0.15 : (config.reduceMotion ? config.reducedDissolve : config.dissolve)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = length
            c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().alphaValue = 0
            main?.animator().alphaValue = 1
        }, completionHandler: { [weak self, run = generation] in
            MainActor.assumeIsolated { if let self, self.generation == run { self.tearDown(main: main) } }
        })
        // never left behind if the animation context does not call back
        let run = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.6) { [weak self] in MainActor.assumeIsolated { if let self, self.generation == run { self.tearDown(main: main) } } }
    }

    /// The splash window is ordered out, closed and released, not just hidden; the app's window is whole again and is key.
    private func tearDown(main: NSWindow?) {
        guard isRunning else { return }
        isRunning = false
        scene?.tearDown(); scene = nil
        if let w = window {
            w.orderOut(nil)
            w.contentView = nil
            w.close()
        }
        window = nil
        if let m = main ?? findMain() {
            m.alphaValue = 1; m.ignoresMouseEvents = false
            m.makeKeyAndOrderFront(nil)
        }
        self.main = nil
        let done = completion; completion = nil
        done?()
    }
}

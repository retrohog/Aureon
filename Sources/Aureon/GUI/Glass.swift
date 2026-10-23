import SwiftUI

// Liquid glass, used sparingly: the floating player bar, the Now Playing side panels, the ⌘K palette and the hover pop-ups. Everything else stays flat,
// so the glass reads as a deliberate accent. Glass sits over the static, pre-rendered backdrop (never over the waveform or the analyser traces, whose plots
// carry their own opaque inset), so it costs no more than any other layer.

private struct GlassAccentsKey: EnvironmentKey { static let defaultValue = true }
private struct GlassTintKey: EnvironmentKey { static let defaultValue: Color? = nil }
extension EnvironmentValues {
    /// The Settings switch "Glass accents".
    var glassAccents: Bool {
        get { self[GlassAccentsKey.self] }
        set { self[GlassAccentsKey.self] = newValue }
    }
    /// A very slight tint of the cover's colour for the glass, set while the Album backdrop is on.
    var glassTint: Color? {
        get { self[GlassTintKey.self] }
        set { self[GlassTintKey.self] = newValue }
    }
}

/// What a glass surface is made of, and when it gives way to a flat one.
enum GlassPolicy {
    enum Surface: Equatable { case glass, flat }

    /// Glass only while the setting is on and the system is not asked to reduce transparency.
    static func surface(enabled: Bool, reduceTransparency: Bool) -> Surface { enabled && !reduceTransparency ? .glass : .flat }

    /// The corner of a glass surface: gentler than the 2 to 4 point corners of the rest of the chrome. Flat surfaces keep the chrome corner.
    static let radius: CGFloat = 14
    static let popoverRadius: CGFloat = 12
    static let flatRadius: CGFloat = Metrics.controlRadius

    /// The share of the theme's background laid over the glass, so text keeps its contrast over whatever the glass lets through.
    static let scrim = 0.50
    /// Pop-ups sit over whatever page is behind them, so they take more of the theme's background.
    static let popoverScrim = 0.6
    /// How far the glass's own highlight can lift a dark surface towards white (a light surface only gets lighter, which helps dark text).
    static let highlightLift = 0.04

    /// The darkest/lightest the surface under text can get on `theme`: the theme background over the strongest backdrop allowed, at the scrim,
    /// plus the glass highlight. For the contrast checks.
    static func worstCaseSurface(_ theme: Theme, scrim: Double = GlassPolicy.scrim) -> RGB {
        let behind = theme.backdropLimitRGB
        let over = behind.mixed(with: theme.canvasRGB, scrim)
        return theme.isLight ? over : over.mixed(with: RGB(1, 1, 1), highlightLift)
    }

    /// The tint over the glass for a cover's accent: a fifth, enough to colour the pane without costing the text its contrast.
    static func tint(for accent: RGB) -> Color { accent.color.opacity(0.22) }
}

/// A glass surface (or, when glass is off, the flat theme surface in its place).
struct GlassAccent: ViewModifier {
    var radius: CGFloat = GlassPolicy.radius
    /// The flat surface's fill (the bar's sidebar colour, or the page canvas).
    var flat: Color = Brand.canvas
    @Environment(\.glassAccents) private var enabled
    @Environment(\.glassTint) private var tint
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch GlassPolicy.surface(enabled: enabled, reduceTransparency: reduceTransparency) {
        case .flat:
            let shape = RoundedRectangle(cornerRadius: GlassPolicy.flatRadius, style: .continuous)
            content
                .background(shape.fill(flat))
                .overlay(shape.strokeBorder(Brand.rule, lineWidth: Metrics.hairline))
                .clipShape(shape)
        case .glass:
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content
                .background { GlassBase(shape: shape, tint: tint) }
                .overlay { GlassRim(shape: shape) }
                .clipShape(shape)
        }
    }
}

/// The glass itself: the system's Liquid Glass where there is one (macOS 26), a blurred material elsewhere, then the theme's background at the scrim.
private struct GlassBase<S: InsettableShape>: View {
    let shape: S
    let tint: Color?
    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(tint.map { Glass.regular.tint($0) } ?? Glass.regular, in: shape)
            } else {
                shape.fill(.thinMaterial)
                if let tint { shape.fill(tint) }
            }
            shape.fill(Brand.canvas.opacity(GlassPolicy.scrim))
            if !Theme.current.isLight { shape.fill(Color.white.opacity(GlassPolicy.highlightLift)) }
            // a faint sheen from the top left, as light catches the pane
            shape.fill(LinearGradient(colors: [Color.white.opacity(Theme.current.isLight ? 0.35 : 0.07), Color.clear], startPoint: .topLeading, endPoint: .center))
        }
    }
}

/// The edge: a hairline of light that is brightest at the top left, and a soft highlight just inside it.
private struct GlassRim<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        let light = Theme.current.isLight
        ZStack {
            shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(light ? 0.9 : 0.38), Color.white.opacity(light ? 0.35 : 0.06), Color.white.opacity(light ? 0.6 : 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: Metrics.hairline * 1.5)
            if light { shape.strokeBorder(Brand.ink.opacity(0.10), lineWidth: Metrics.hairline) }
            shape.inset(by: 1.5).strokeBorder(
                LinearGradient(colors: [Color.white.opacity(light ? 0.55 : 0.12), Color.clear], startPoint: .top, endPoint: .center),
                lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// The background of a pop-up: translucent over the system's own pop-up material (which is Liquid Glass on macOS 26), or the opaque theme surface.
struct GlassPopoverBackground: ViewModifier {
    @Environment(\.glassAccents) private var enabled
    @Environment(\.glassTint) private var tint
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch GlassPolicy.surface(enabled: enabled, reduceTransparency: reduceTransparency) {
        case .flat: content.background(Brand.canvas)
        case .glass:
            content.background {
                ZStack {
                    if let tint { Rectangle().fill(tint) }
                    Rectangle().fill(Brand.canvas.opacity(GlassPolicy.popoverScrim))
                }
            }
        }
    }
}

/// Under a live plot (the analyser's traces) on glass: an opaque inset of the theme's background, so nothing that animates is ever blurred behind it.
struct PlotInset: ViewModifier {
    @Environment(\.glassAccents) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if GlassPolicy.surface(enabled: enabled, reduceTransparency: reduceTransparency) == .glass { content.background(Brand.canvas) } else { content }
    }
}

extension View {
    /// An opaque inset behind a live plot while it sits on glass.
    func plotInset() -> some View { modifier(PlotInset()) }
    /// A floating surface of glass (flat when glass is off). `flat` is the colour it takes then.
    func glassAccent(radius: CGFloat = GlassPolicy.radius, flat: Color = Brand.canvas) -> some View { modifier(GlassAccent(radius: radius, flat: flat)) }
    /// The background for the content of a pop-up.
    func glassPopover() -> some View { modifier(GlassPopoverBackground()) }
}

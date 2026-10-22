import SwiftUI
import AppKit

// The "hardware" look: a dark-glass chassis, a recessed black display window, and LED indicators whose legends keep at least 4.5:1 contrast
// (WCAG AA for small text) against that window whatever is behind the translucent chassis.

/// WCAG 2 relative luminance and contrast ratio, on sRGB colours.
enum WCAG {
    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func luminance(_ c: RGB) -> Double { 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b) }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    /// `top` at `alpha` over an opaque `bottom`, blended the way the window server blends (in sRGB values).
    static func over(_ top: RGB, alpha: Double, _ bottom: RGB) -> RGB {
        RGB(top.r * alpha + bottom.r * (1 - alpha), top.g * alpha + bottom.g * (1 - alpha), top.b * alpha + bottom.b * (1 - alpha))
    }
}

/// The colours of the player bar's chassis and display window. Every alpha here is part of the contrast guarantee checked by the self-test.
enum HWPanel {
    static let chassisTop = RGB(0.085, 0.09, 0.105), chassisBottom = RGB(0.045, 0.048, 0.058)
    static let chassisAlpha = 0.86
    static let display = RGB(0.012, 0.013, 0.017)
    static let displayAlpha = 0.84
    /// Legend colour of text that is not an LED (title, time readout).
    static let readout = RGB(0.93, 0.94, 0.96)
    static let readoutDim = RGB(0.66, 0.68, 0.72)
    /// Rendering an offscreen snapshot (development aid), where window-server effects are unavailable.
    static let snapshot = ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil
    /// How strongly the Liquid Glass chassis is smoked (macOS 26). The display window inside stays near-black, so LED contrast does not depend on it.
    static let glassTintAlpha = 0.62

    /// The brightest the display window can ever be: its tint over the chassis over a pure white page, with nothing else in between.
    static var worstCaseDisplay: RGB {
        let chassis = WCAG.over(chassisTop, alpha: chassisAlpha, RGB(1, 1, 1))
        return WCAG.over(display, alpha: displayAlpha, chassis)
    }
    /// The display window directly over a white page (where the chassis is a system glass whose tint the system decides).
    static var worstCaseDisplayAlone: RGB { WCAG.over(display, alpha: displayAlpha, RGB(1, 1, 1)) }
}

/// One front-panel indicator: what it says, its colour, and how essential it is when space is short (0 = always shown).
struct LEDLamp: Identifiable, Equatable {
    enum Tone: CaseIterable {
        case gold, blue, amber, green, purple, orange, red, white
        var rgb: RGB {
            switch self {
            case .gold: RGB(1.0, 0.82, 0.38)
            case .blue: RGB(0.47, 0.74, 1.0)
            case .amber: RGB(1.0, 0.74, 0.30)
            case .green: RGB(0.40, 0.92, 0.58)
            case .purple: RGB(0.78, 0.64, 1.0)
            case .orange: RGB(1.0, 0.60, 0.30)
            case .red: RGB(1.0, 0.42, 0.42)
            case .white: RGB(0.90, 0.92, 0.95)
            }
        }
        var color: Color { rgb.color }
    }
    var id: String
    var text: String
    var tone: Tone
    var priority: Int
    var help: String

    /// The lamps for what is playing, in front-panel order. Only lit lamps are listed, so the strip never shows dead legends.
    static func lamps(source: StreamInfo, output: StreamInfo?, bitrate: Int?, mixing: Bool, mixHelp: String? = nil) -> [LEDLamp] {
        var out: [LEDLamp] = []
        let tier = qualityTier(source)
        let codec = source.codec.replacingOccurrences(of: " (lossy)", with: "").uppercased()
        if source.isLive { out.append(LEDLamp(id: "live", text: "LIVE", tone: .red, priority: 0, help: "Live radio stream")) }
        if tier.hiRes, !source.isLive, source.sourceBits != 1 { out.append(LEDLamp(id: "hires", text: "HI-RES", tone: .gold, priority: 1, help: "High-resolution audio: more than 16 bits or 48 kHz")) }
        out.append(LEDLamp(id: "codec", text: codec, tone: source.codec.contains("lossy") ? .orange : .blue, priority: 0,
                           help: source.codec.contains("lossy") ? "Lossy source" : "Lossless source"))
        if source.isLive {
            if let b = bitrate, b > 0 { out.append(LEDLamp(id: "bitrate", text: "\(b) kbps", tone: .white, priority: 2, help: "Stream bit rate")) }
        } else if source.sourceBits == 1 {
            out.append(LEDLamp(id: "dsd", text: dsdRateName(source.sourceRate ?? source.sampleRate), tone: .purple, priority: 0, help: "Direct Stream Digital"))
        } else {
            out.append(LEDLamp(id: "bits", text: "\(source.sourceBits)-BIT", tone: .amber, priority: 1, help: "Bit depth of the file"))
        }
        if source.sourceBits != 1 {
            out.append(LEDLamp(id: "rate", text: formatRate(source.sourceRate ?? source.sampleRate), tone: .amber, priority: 0, help: "Sample rate of the source"))
        }
        if let o = output, !o.isDoP, o.sampleRate != (source.sourceRate ?? source.sampleRate), source.sourceBits != 1 {
            out.append(LEDLamp(id: "upscaled", text: "UPSCALED " + formatRate(o.sampleRate), tone: .green, priority: 2, help: "Resampled to \(formatRate(o.sampleRate)) for the output device"))
        }
        if mixing { out.append(mix(help: mixHelp)) }
        return out
    }

    /// Lit while the player crossfades into the next song.
    static func mix(help: String?) -> LEDLamp { LEDLamp(id: "mix", text: "MIX", tone: .orange, priority: 0, help: help ?? "Crossfading into the next song") }

    /// The lamps that remain when only those up to `maxPriority` fit.
    static func fitting(_ lamps: [LEDLamp], maxPriority: Int) -> [LEDLamp] { lamps.filter { $0.priority <= maxPriority } }
}

/// An LED and its legend, without a plate: a set of these sits together in one recessed display window.
struct LEDIndicator: View {
    let lamp: LEDLamp
    var size: CGFloat = 9.5

    var body: some View {
        let c = lamp.tone.color
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(c).frame(width: 4.5, height: 4.5).shadow(color: c.opacity(0.95), radius: 3)
                Circle().fill(.white.opacity(0.75)).frame(width: 1.6, height: 1.6).offset(x: -0.6, y: -0.6)        // the specular point of a domed LED
            }
            Text(lamp.text).font(.system(size: size, weight: .bold, design: .monospaced)).tracking(0.9).foregroundStyle(c)
                .shadow(color: c.opacity(0.55), radius: 3.5)
                .lineLimit(1).fixedSize()
        }
        .help(lamp.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lamp.text)
    }
}

/// A row of lit indicators separated by fine engraved dividers.
struct LEDStrip: View {
    let lamps: [LEDLamp]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(lamps.enumerated()), id: \.element.id) { i, l in
                if i > 0 { Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 10) }
                LEDIndicator(lamp: l).transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .fixedSize()
        .animation(.smooth(duration: 0.3), value: lamps.map(\.id))
    }
}

/// The strip that fits the space available: lower-priority lamps go first.
struct AdaptiveLEDStrip: View {
    let lamps: [LEDLamp]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            LEDStrip(lamps: lamps)
            LEDStrip(lamps: LEDLamp.fitting(lamps, maxPriority: 1))
            LEDStrip(lamps: LEDLamp.fitting(lamps, maxPriority: 0))
            EmptyView()
        }
    }
}

// MARK: - Surfaces

extension View {
    /// A system glass surface: Liquid Glass where the system has it (macOS 26), the HIG material elsewhere, with a light-catching edge.
    @ViewBuilder func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, material: Material = .regularMaterial) -> some View {
        #if compiler(>=6.2)
        if HWPanel.snapshot {
            // offscreen snapshots cannot draw Liquid Glass (it is composited by the window server), so they show the material version
            materialSurface(shape, tint: tint, material: material)
        } else if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            materialSurface(shape, tint: tint, material: material)
        }
        #else
        materialSurface(shape, tint: tint, material: material)
        #endif
    }

    func materialSurface<S: InsettableShape>(_ shape: S, tint: Color?, material: Material) -> some View {
        background {
            ZStack {
                shape.fill(material)
                if let tint { shape.fill(tint) }
            }
        }
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05), .white.opacity(0.09)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
    }

    /// The bar's dark-glass chassis: a system glass, smoked to near-black, with a soft top reflection and a hairline bevel.
    func hardwareChassis(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return chassisGlass(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.05), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }

    @ViewBuilder private func chassisGlass(_ shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if HWPanel.snapshot {
            chassisMaterial(shape)
        } else if #available(macOS 26.0, *) {
            // the system glass, smoked: the album colours behind the bar still show through its edges and refraction
            self.background { shape.fill(LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5))) }
                .glassEffect(Glass.regular.tint(HWPanel.chassisTop.color.opacity(HWPanel.glassTintAlpha)), in: shape)
        } else {
            chassisMaterial(shape)
        }
        #else
        chassisMaterial(shape)
        #endif
    }

    private func chassisMaterial(_ shape: RoundedRectangle) -> some View {
        background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(LinearGradient(colors: [HWPanel.chassisTop.color.opacity(HWPanel.chassisAlpha), HWPanel.chassisBottom.color.opacity(min(1, HWPanel.chassisAlpha + 0.06))],
                                          startPoint: .top, endPoint: .bottom))
                shape.fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5)))
            }
        }
    }

    /// The recessed display window: smoked black glass sunk into the chassis (shadowed top edge, lit bottom edge).
    func displayWindow(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(HWPanel.display.color.opacity(HWPanel.displayAlpha)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.black.opacity(0.75), .white.opacity(0.03), .white.opacity(0.13)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .overlay(alignment: .top) {
                shape.fill(LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)).frame(height: 6).clipShape(shape).allowsHitTesting(false)
            }
    }
}

/// The bar's play button: a machined, slightly domed key.
struct HardwareKeyStyle: ButtonStyle {
    var diameter: CGFloat = 34
    var glow: Color
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, diameter: diameter, glow: glow) }
    private struct Inner: View {
        let configuration: Configuration
        let diameter: CGFloat
        let glow: Color
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: diameter * 0.38, weight: .bold))
                .foregroundStyle(Color(white: 0.08))
                .frame(width: diameter, height: diameter)
                .background {
                    Circle().fill(LinearGradient(colors: [Color(white: configuration.isPressed ? 0.80 : 0.97), Color(white: configuration.isPressed ? 0.70 : 0.78)], startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
                        .shadow(color: glow.opacity(hover.v && enabled ? 0.65 : 0.3), radius: hover.v ? 12 : 7)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                }
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.smooth(duration: 0.15), value: hover.v)
                .onHover { hover.v = $0 }
        }
    }
}

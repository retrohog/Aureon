import SwiftUI
import AppKit

// The instrument-panel vocabulary of the player bar: technical readouts set in SF Mono, framed by hairlines and a single champagne pinstripe.
// Every legend is fitted to the surface it is drawn on (WCAG AA, 4.5:1) whichever theme is active.

/// The player bar's surface and readout colours. They follow the theme; contrast is guaranteed by `Theme` and `WCAG.fit`.
enum HWPanel {
    /// The surface of the bar: the sidebar's colour, so the two read as one piece of furniture.
    static var surface: RGB { Theme.current.sidebarRGB }
    /// The title and the elapsed time.
    static var readout: Color { Brand.ink }
    /// The artist line and the total time.
    static var readoutDim: Color { Brand.inkSecondary }
    /// Rendering an offscreen snapshot (development aid), where window-server effects are unavailable.
    static let snapshot = ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil
}

/// One front-panel indicator: what it says, its tone, and how essential it is when space is short (0 = always shown).
struct LEDLamp: Identifiable, Equatable {
    enum Tone: CaseIterable {
        case gold, blue, amber, green, purple, orange, red, white
        /// The hue before it is fitted to a surface: restrained, light enough to read on the dark bar.
        var rgb: RGB {
            switch self {
            case .gold: RGB(0.85, 0.72, 0.46)
            case .blue: RGB(0.78, 0.82, 0.86)
            case .amber: RGB(0.84, 0.70, 0.45)
            case .green: RGB(0.60, 0.80, 0.64)
            case .purple: RGB(0.78, 0.70, 0.84)
            case .orange: RGB(0.90, 0.60, 0.44)
            case .red: RGB(0.92, 0.50, 0.48)
            case .white: RGB(0.88, 0.87, 0.85)
            }
        }
        /// The tone as drawn on `surface`: darkened on a light bar until it reads at 4.5:1.
        func rgb(on surface: RGB) -> RGB { WCAG.fit(rgb, against: surface, minimum: 4.5) }
        var color: Color { rgb(on: HWPanel.surface).color }
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

/// A readout and its legend: tracked SF Mono in the tone's colour. The Hi-Res lamp carries a hairline frame, like a hallmark.
struct LEDIndicator: View {
    let lamp: LEDLamp
    var size: CGFloat = 10

    var body: some View {
        let c = lamp.tone.color
        Text(lamp.text).font(Typo.mono(size, .regular)).tracking(1.2).foregroundStyle(c)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, lamp.id == "hires" ? 6 : 0).padding(.vertical, lamp.id == "hires" ? 2 : 0)
            .overlay { if lamp.id == "hires" { RoundedRectangle(cornerRadius: Metrics.tagRadius, style: .continuous).strokeBorder(c.opacity(0.8), lineWidth: Metrics.hairline) } }
            .help(lamp.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lamp.text)
    }
}

/// A row of readouts separated by hairlines.
struct LEDStrip: View {
    let lamps: [LEDLamp]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(lamps.enumerated()), id: \.element.id) { i, l in
                if i > 0 { Rule(vertical: true).frame(height: 8) }
                LEDIndicator(lamp: l).transition(.opacity)
            }
        }
        .fixedSize()
        .animation(Motion.glide, value: lamps.map(\.id))
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
    /// A framed surface: a hairline and the faintest lift, with a barely softened corner. (`tint` and `material` are accepted for old call sites.)
    func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, material: Material = .regularMaterial) -> some View {
        background(shape.fill(Brand.ink.opacity(0.03)))
            .overlay(shape.strokeBorder(Brand.rule, lineWidth: Metrics.hairline))
    }
}

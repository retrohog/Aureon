import SwiftUI
import AppKit

enum Brand {
    /// Everything here follows the selected theme (see `Theme`); views are rebuilt when the theme changes.
    static var accent: Color { Theme.current.accent }
    static var accent2: Color { Theme.current.accent2 }
    /// The accent as small text (nudged to AA on both surfaces), and the label colour on a solid accent fill.
    static var accentText: Color { Theme.current.accentText }
    static var onAccent: Color { Theme.current.onAccent }
    /// Text and hairlines: ivory on dark themes, warm black on light ones. Hierarchy is by opacity, never by colour.
    static var ink: Color { Theme.current.ink }
    /// Secondary (7:1) and tertiary (4.5:1) text: the ink at the lowest opacity that still meets those ratios on both surfaces.
    static var inkSecondary: Color { Theme.current.inkSecondary }
    static var inkTertiary: Color { Theme.current.inkTertiary }
    /// A hairline: the ink at 14 % (18 % on light themes), scaled by the edge setting.
    static var rule: Color { Theme.current.ink.opacity(Look.ruleOpacity(light: Theme.current.isLight)) }
    /// The coachline: the accent as a fine pinstripe (the player bar's edge, the playhead, active marks).
    static var coachline: Color { Theme.current.accent.opacity(0.7) }
    /// A warm copper for cautions and altered signal (instead of orange), fitted to read on the page in every theme.
    static var caution: Color { WCAG.fit(RGB(0.86, 0.52, 0.36), against: Theme.current.backdropLimitRGB, minimum: 4.5).color }
    // legacy names, kept so every use follows the same palette
    static var cyan: Color { accentText }
    static var violet: Color { accent2 }
    static var pink: Color { accent }
    /// A two-tone wash of neighbouring hues (champagne into brass): only for the progress rule, the waveform fill and active marks.
    static var gradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing) }
    static var gradientDiagonal: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var gradientVertical: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .top, endPoint: .bottom) }
    /// Flat surfaces
    static var canvas: Color { Theme.current.canvas }
    static var sidebar: Color { Theme.current.sidebar }
    /// The window behind the panels (top bar, rail), the main panel, and the raised surface (cards, chips, the selected rail item).
    static var window: Color { Theme.current.sidebar }
    static var panel: Color { Theme.current.canvas }
    static var panel2: Color { Theme.current.panel2 }
}

/// The system's translucent material, e.g. the sidebar showing the desktop through the window.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// For `.selection`: false gives the quiet vibrant highlight of an unfocused source list, true the accent-coloured one.
    var emphasized = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = blending; v.state = .active; v.isEmphasized = emphasized; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending; v.isEmphasized = emphasized }
}

extension View {
    /// A framed region: a hairline and the faintest lift, in place of a card. (`glow` is accepted for old call sites and ignored.)
    func panel(radius: CGFloat = 4, fill: Double = 0.03, glow: Color? = nil) -> some View {
        background(RoundedRectangle(cornerRadius: Metrics.radius(radius), style: .continuous).fill(Brand.ink.opacity(fill * 0.7)))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius(radius), style: .continuous).strokeBorder(Brand.rule, lineWidth: Metrics.hairline))
    }

    /// A region on the Now Playing backdrop: the same hairline frame as `panel`.
    func glassPanel(radius: CGFloat = 4) -> some View { panel(radius: radius, fill: 0.04) }
}

// MARK: - Readout tags

/// A technical readout in a hairline frame: a legend in the tone's colour, an optional value beside it. The tones are fitted to the page
/// (the backdrop's lightest or darkest allowed point, `Theme.backdropLimitRGB`) so every legend keeps 4.5:1.
struct HWBadge: View {
    enum Tone: CaseIterable {
        case neutral, blue, green, amber, purple, orange
        /// Restrained hues, light enough for the dark stage; on a light page they are darkened until they read.
        var rgb: RGB {
            switch self {
            case .neutral: RGB(0.84, 0.82, 0.78); case .blue: RGB(0.78, 0.82, 0.86); case .green: RGB(0.60, 0.80, 0.64)
            case .amber: RGB(0.84, 0.70, 0.45); case .purple: RGB(0.78, 0.70, 0.84); case .orange: RGB(0.90, 0.60, 0.44)
            }
        }
        var color: Color { rgb.color }
    }
    let text: String
    var detail: String? = nil
    var tone: Tone = .neutral
    var lit = true
    var compact = false

    var body: some View {
        let surface = Theme.current.backdropLimitRGB
        let c = lit ? WCAG.fit(tone.rgb, against: surface, minimum: 4.5).color : Brand.inkTertiary
        HStack(spacing: compact ? 4 : 8) {
            Text(text).font(Typo.mono(compact ? 9 : 10, .regular)).tracking(compact ? 1.0 : 1.4).foregroundStyle(c)
            if let detail {
                Rectangle().fill(Brand.rule).frame(width: Metrics.hairline, height: compact ? 8 : 10)
                Text(detail).font(Typo.mono(compact ? 9 : 10, .regular)).foregroundStyle(Brand.inkSecondary)
            }
        }
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 3 : 4)
        .overlay(RoundedRectangle(cornerRadius: Metrics.tagRadius, style: .continuous).strokeBorder(Brand.rule, lineWidth: Metrics.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(text), \($0)" } ?? text)
    }
}

/// The "Hi-Res Audio" mark: a fine champagne frame around two small words.
struct HiResMark: View {
    var compact = false
    var body: some View {
        let c = Theme.current.accentTextRGB.color
        VStack(spacing: 2) {
            Text("HI-RES").font(Typo.sans(compact ? 9 : 10, .medium)).tracking(compact ? 1.4 : 2).foregroundStyle(c)
            if !compact { Text("AUDIO").font(Typo.sans(9, .regular)).tracking(2.8).foregroundStyle(c.opacity(0.8)) }
        }
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 3 : 4)
        .overlay(RoundedRectangle(cornerRadius: Metrics.tagRadius, style: .continuous).strokeBorder(c.opacity(0.8), lineWidth: Metrics.hairline))
        .accessibilityLabel("High resolution audio")
    }
}

/// The badges describing the audible stream: Hi-Res mark, codec, bit depth and rate, channel layout; for radio, LIVE and the upscaled rate.
struct FormatBadges: View {
    let source: StreamInfo
    var output: StreamInfo? = nil
    var bitrate: Int? = nil
    var compact = false

    var body: some View {
        let q = qualityTier(source)
        let upscaled = output.map { $0.sampleRate != source.sampleRate && !$0.isDoP } ?? false
        WrapLayout(spacing: compact ? 4 : 8, lineSpacing: compact ? 4 : 8) {
            if source.isLive { HWBadge(text: "LIVE", tone: .orange, compact: compact) }
            if q.hiRes && !source.isLive { HiResMark(compact: compact) }
            HWBadge(text: source.codec.replacingOccurrences(of: " (lossy)", with: "").uppercased(), detail: source.isLive ? bitrate.map { "\($0) kbps" } : nil,
                    tone: source.codec.contains("lossy") ? .orange : .blue, compact: compact)
            if !source.isLive {
                if source.sourceBits == 1 { HWBadge(text: dsdRateName(source.sourceRate ?? source.sampleRate), detail: formatRate(source.sampleRate), tone: .purple, compact: compact) }
                else { HWBadge(text: "\(source.sourceBits)-BIT", detail: formatRate(source.sampleRate), tone: .amber, compact: compact) }
            } else { HWBadge(text: formatRate(source.sampleRate).uppercased(), tone: .neutral, compact: compact) }
            if upscaled, let o = output { HWBadge(text: "UPSCALED", detail: formatRate(o.sampleRate), tone: .green, compact: compact) }
            HWBadge(text: source.channels == 2 ? "STEREO" : source.channels == 1 ? "MONO" : "\(source.channels) CH", tone: .neutral, compact: compact)
        }
    }
}

/// Lays its children out left to right and starts a new line when the next one would not fit, so a row of badges wraps instead of clipping.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += rowHeight + lineSpacing; x = 0; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += s.width; widest = max(widest, x); x += spacing
            rowHeight = max(rowHeight, s.height)
        }
        return (origins, CGSize(width: widest, height: origins.isEmpty ? 0 : y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews)
        for (sv, o) in zip(subviews, r.origins) { sv.place(at: CGPoint(x: bounds.minX + o.x, y: bounds.minY + o.y), proposal: .unspecified) }
    }
}

struct QualityTier { var name: String; var hiRes: Bool; var tone: HWBadge.Tone }
func qualityTier(_ i: StreamInfo) -> QualityTier {
    if i.sourceBits == 1 { return QualityTier(name: dsdRateName(i.sourceRate ?? i.sampleRate), hiRes: true, tone: .purple) }
    if i.sampleRate > 48_000 || i.sourceBits > 16 { return QualityTier(name: "Hi-Res", hiRes: true, tone: .amber) }
    if i.sampleRate == 44_100 && i.sourceBits == 16 { return QualityTier(name: "CD quality", hiRes: false, tone: .green) }
    return QualityTier(name: "Lossless", hiRes: false, tone: .green)
}

// MARK: - Artwork

/// Cover art with a quiet placeholder: a flat tone from the album's own colours and a fine note. Its corner is as asked for (10 on cards, 6 in lists).
struct CoverView: View {
    let image: NSImage?
    let palette: ArtPalette
    var corner: CGFloat = 2
    var symbol = "music.note"

    var body: some View {
        let r = corner < 2.5 ? corner : Metrics.radius(corner)
        GeometryReader { g in
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill).frame(width: g.size.width, height: g.size.height).clipped().transition(.opacity)
                } else {
                    palette.grid[4].mixed(with: RGB(0.05, 0.05, 0.06), 0.45).color
                    Image(systemName: symbol).font(Typo.sans(g.size.width * 0.3, .ultraLight)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Brand.ink.opacity(0.14), lineWidth: Metrics.hairline))
    }
}

// MARK: - Fluid slider

/// A slim slider: a one-point rule with the filled part in champagne, a fine vertical mark for the knob that appears under the pointer, a value tag,
/// and an ease between playback updates. No springs, no glow.
struct FluidSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = Brand.accent
    var restingHeight: CGFloat = 4
    var enabled = true
    var bubble: ((Double) -> String)? = nil
    /// Volume-like sliders: dragging is relative and a click only nudges (see `SliderDrag`); scrolling moves by small steps.
    var safe = false
    var safeStep = 0.04
    /// One wheel click moves the value by this much (default 2 % of the range, 1 % for guarded sliders).
    var scrollStep: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    @StateObject private var hover = Box(false)
    @StateObject private var dragging = Box(false)
    @StateObject private var pointerX = Box<CGFloat?>(nil)
    @StateObject private var dragStart = Box<Double?>(nil)

    private func fraction(_ v: Double) -> CGFloat { range.upperBound > range.lowerBound ? CGFloat(min(1, max(0, (v - range.lowerBound) / (range.upperBound - range.lowerBound)))) : 0 }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, active = enabled && (hover.v || dragging.v)
            let h: CGFloat = 5
            let f = fraction(value)
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.ink.opacity(enabled ? 0.18 : 0.1)).frame(height: h)
                Capsule().fill((active ? tint : Brand.ink.opacity(0.9)).opacity(enabled ? 1 : 0.35)).frame(width: max(h, w * f), height: h)
                Circle().fill(Brand.ink).frame(width: 13, height: 13)
                    .opacity(active ? 1 : 0)
                    .offset(x: min(max(0, w * f - 6.5), w - 13))
                if let bubble, enabled, active {
                    let shown = dragging.v ? value : (pointerX.v.map { range.lowerBound + Double(min(1, max(0, $0 / w))) * (range.upperBound - range.lowerBound) } ?? value)
                    Text(bubble(shown)).font(Typo.mono(11, .regular))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Metrics.tagRadius, style: .continuous).fill(Brand.panel2))
                        .foregroundStyle(Brand.ink).fixedSize()
                        .offset(x: min(max(0, (dragging.v ? w * f : (pointerX.v ?? w * f)) - 22), max(0, w - 44)), y: -24)
                        .allowsHitTesting(false).transition(.opacity)
                }
            }
            .frame(width: w, height: g.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .animation(Motion.touch, value: active)
            .animation(dragging.v ? nil : .linear(duration: 0.12), value: f)
            .onContinuousHover { phase in
                switch phase { case .active(let p): hover.v = true; pointerX.v = p.x; case .ended: hover.v = false; pointerX.v = nil }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                guard enabled else { return }
                let span = range.upperBound - range.lowerBound
                if !dragging.v { dragging.v = true; dragStart.v = Double(f); onEditingChanged(true) }
                if safe {
                    // relative: pressing changes nothing, dragging moves by the distance dragged
                    value = range.lowerBound + SliderDrag.relative(start: dragStart.v ?? Double(f), dx: Double(d.translation.width / max(w, 1))) * span
                } else {
                    value = range.lowerBound + Double(min(1, max(0, d.location.x / w))) * span
                }
            }.onEnded { d in
                guard enabled else { return }
                if safe, abs(Double(d.translation.width)) < SliderDrag.clickSlop {
                    let span = range.upperBound - range.lowerBound
                    value = range.lowerBound + SliderDrag.clickNudge(current: dragStart.v ?? Double(f), press: Double(min(1, max(0, d.startLocation.x / max(w, 1)))), step: safeStep) * span
                }
                dragStart.v = nil
                dragging.v = false; onEditingChanged(false)
            })
            .scrollAdjustable(hovering: hover.v && enabled) { notches in
                let per = scrollStep.map { $0 / max(range.upperBound - range.lowerBound, 1e-9) } ?? (safe ? 0.01 : 0.02)
                value = ScrollStep.apply(value: value, notches: notches, range: range, perNotch: per, maxMove: safe ? 0.03 : 0.1)
                onEditingChanged(true); onEditingChanged(false)
                return true
            }
        }
        .frame(height: 24)
        .opacity(enabled ? 1 : 0.7)
        .accessibilityElement()
        .accessibilityValue(Text(bubble?(value) ?? "\(Int(fraction(value) * 100)) percent"))
        .accessibilityAdjustableAction { dir in
            guard enabled else { return }
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? step : -step)))
            onEditingChanged(false)
        }
    }
}

// MARK: - Buttons

/// Transport glyphs: no plate, no scale; the glyph brightens under the pointer and dims when pressed.
struct TransportButtonStyle: ButtonStyle {
    var size: CGFloat = 22
    /// Colour of the glyphs: the theme's ink on the player bar, ivory on Now Playing.
    var ink: Color = Brand.ink
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, size: size, ink: ink) }

    private struct Inner: View {
        let configuration: Configuration
        let size: CGFloat
        let ink: Color
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(Typo.sans(size, .light))
                .foregroundStyle(ink.opacity(enabled ? (configuration.isPressed ? 0.55 : (hover.v ? 1 : 0.78)) : 0.3))
                .frame(width: size * 2, height: size * 2)
                .contentShape(Rectangle())
                .animation(Motion.touch, value: hover.v)
                .animation(Motion.touch, value: configuration.isPressed)
                .onHover { hover.v = $0 }
        }
    }
}

/// An outlined button: a hairline frame and a small tracked label. The default for every un-styled button.
struct RuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }
    private struct Inner: View {
        let configuration: Configuration
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlSize) private var size
        var body: some View {
            let pad: CGFloat = size == .mini ? 10 : (size == .small ? 12 : 16)
            configuration.label
                .font(Typo.sans(size == .mini || size == .small ? 12 : 13, .regular))
                .foregroundStyle(Brand.ink.opacity(enabled ? 1 : 0.4))
                .padding(.horizontal, pad).frame(minHeight: size == .mini ? 24 : (size == .small ? 28 : Metrics.pillHeight))
                .background(Capsule().fill(configuration.isPressed ? Brand.ink.opacity(0.16) : (hover.v && enabled ? Brand.ink.opacity(0.1) : Brand.panel2)))
                .contentShape(Capsule())
                .animation(Motion.touch, value: hover.v)
                .onHover { hover.v = $0 }
        }
    }
}

/// The one filled button: champagne with a dark label.
struct SolidButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }
    private struct Inner: View {
        let configuration: Configuration
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlSize) private var size
        var body: some View {
            let pad: CGFloat = size == .mini ? 10 : (size == .small ? 12 : 18)
            configuration.label
                .font(Typo.sans(size == .mini || size == .small ? 12 : 13, .medium))
                .foregroundStyle(Brand.onAccent)
                .padding(.horizontal, pad).frame(minHeight: size == .mini ? 24 : (size == .small ? 28 : Metrics.pillHeight))
                .background(Capsule().fill(Brand.accent))
                .brightness(configuration.isPressed ? -0.08 : (hover.v && enabled ? 0.05 : 0))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .animation(Motion.touch, value: hover.v)
                .onHover { hover.v = $0 }
        }
    }
}

extension ButtonStyle where Self == RuleButtonStyle { static var rule: RuleButtonStyle { RuleButtonStyle() } }
extension ButtonStyle where Self == SolidButtonStyle { static var solid: SolidButtonStyle { SolidButtonStyle() } }

/// The on/off control: two printed segments, OFF | ON. The state is unmistakable: ON is a champagne-gold block with dark type and a lit mark, OFF is
/// recessed and dim. The whole row is the button; VoiceOver reads the label and "on" or "off".
struct RuleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 16) {
                configuration.label
                Spacer(minLength: 8)
                OnOffSwitch(on: configuration.isOn).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The switch itself: a 44 × 26 capsule, the accent when on, with a round knob.
struct OnOffSwitch: View {
    let on: Bool
    @StateObject private var hover = Box(false)
    @Environment(\.isEnabled) private var enabled

    static let width: CGFloat = 44, height: CGFloat = 26

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Brand.accent : Brand.ink.opacity(hover.v ? 0.26 : 0.2))
            Circle().fill(on ? Brand.onAccent : Brand.ink).frame(width: 20, height: 20).padding(3)
        }
        .frame(width: Self.width, height: Self.height)
        .opacity(enabled ? 1 : 0.45)
        .animation(Motion.glide, value: on)
        .onHover { hover.v = $0 }
        .animation(Motion.touch, value: hover.v)
    }
}

extension ToggleStyle where Self == RuleToggleStyle { static var rule: RuleToggleStyle { RuleToggleStyle() } }

extension View {
    /// A text field framed by a hairline (use with `.textFieldStyle(.plain)`).
    func ruleField() -> some View {
        padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Brand.panel2))
    }
}

// MARK: - Vertical fader (EQ bands)

/// A lightweight vertical fader drawn with plain shapes: cheap to create (an EQ has ten of them), centred on zero, double-click to reset.
struct VerticalFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -12...12
    var step = 0.5
    var height: CGFloat = 120
    var enabled = true
    @StateObject private var hover = Box(false)
    @StateObject private var dragging = Box(false)

    private func fraction(_ v: Double) -> CGFloat { CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound)) }

    var body: some View {
        let f = fraction(value), mid = fraction(0), active = hover.v || dragging.v
        ZStack {
            Rectangle().fill(Brand.ink.opacity(0.18)).frame(width: 1, height: height)
            // gain fill: from the zero line to the knob
            Rectangle().fill(Brand.gradientVertical).frame(width: 2, height: max(1, abs(f - mid) * height))
                .position(x: 15, y: height * (1 - (f + mid) / 2)).opacity(enabled ? 1 : 0.3)
            Rectangle().fill(Brand.ink.opacity(0.3)).frame(width: 12, height: Metrics.hairline).position(x: 15, y: height * (1 - mid))
            Rectangle().fill(active ? Brand.accent : Brand.ink.opacity(0.85)).frame(width: 14, height: 3)
                .position(x: 15, y: height * (1 - f))
        }
        .frame(width: 30, height: height)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover.v = $0 }
        .scrollAdjustable(hovering: hover.v && enabled) { n in value = ScrollStep.apply(value: value, notches: n, range: range); return true }
        .animation(Motion.touch, value: active)
        .gesture(DragGesture(minimumDistance: 0).onChanged { d in
            dragging.v = true
            let p = 1 - min(1, max(0, d.location.y / height))
            let raw = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
            value = (raw / step).rounded() * step
        }.onEnded { _ in dragging.v = false })
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
        .accessibilityElement().accessibilityValue(Text(String(format: "%+.1f decibels", value)))
        .accessibilityAdjustableAction { dir in value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? step : -step))) }
    }
}


/// The slider used for settings: made of Aureon's own control (the system slider did not reliably react inside this window), with optional steps.
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    @Environment(\.isEnabled) private var isEnabled

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil) { _value = value; self.range = range; self.step = step }

    private func snapped(_ v: Double) -> Double {
        let c = min(range.upperBound, max(range.lowerBound, v))
        guard let step, step > 0 else { return c }
        return min(range.upperBound, max(range.lowerBound, range.lowerBound + ((c - range.lowerBound) / step).rounded() * step))
    }

    var body: some View {
        FluidSlider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: { value = snapped($0) }), range: range, tint: Brand.accent, restingHeight: 4, enabled: isEnabled,
                    scrollStep: step ?? (range.upperBound - range.lowerBound) * 0.02)
    }
}

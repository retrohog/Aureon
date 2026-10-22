import SwiftUI
import AppKit

enum Brand {
    /// Everything here follows the selected theme (see `Theme`); views are rebuilt when the theme changes.
    static var accent: Color { Theme.current.accent }
    static var accent2: Color { Theme.current.accent2 }
    /// Colour of text and hairlines: white-ish on dark themes, black-ish on light ones. Use `ink.opacity(x)` for faint surfaces and lines.
    static var ink: Color { Theme.current.ink }
    // legacy names, kept so every use follows the same palette
    static var cyan: Color { accent }
    static var violet: Color { accent2 }
    static var pink: Color { accent }
    static var gradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing) }
    static var gradientDiagonal: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing) }
    /// Flat surfaces
    static var canvas: Color { Theme.current.canvas }
    static var sidebar: Color { Theme.current.sidebar }
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
    /// A floating glass panel: a faint fill, a hairline that catches light at the top edge, optional coloured glow.
    func panel(radius: CGFloat = 18, fill: Double = 0.045, glow: Color? = nil) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Brand.ink.opacity(fill)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.03), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
            .shadow(color: glow?.opacity(0.25) ?? .clear, radius: 20)
    }

    /// Small mono-spaced label, the "instrument panel" voice of the interface.
    func microLabel() -> some View { font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.4).textCase(.uppercase) }
}

// MARK: - Typography

enum Typo {
    static func title(_ size: CGFloat = 40) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static let artist = Font.system(size: 21, weight: .medium, design: .default)
    static let album = Font.system(size: 15, weight: .regular, design: .default)
    static let kicker = Font.system(size: 10.5, weight: .semibold, design: .default)
    static let composer = Font.system(size: 14, weight: .regular, design: .serif).italic()
    static let readout = Font.system(size: 11, weight: .medium, design: .monospaced)
}

extension View {
    /// Small upper-case label with wide tracking.
    func kicker() -> some View { font(Typo.kicker).tracking(2.2).textCase(.uppercase) }

    /// A frosted panel that sits on the immersive background.
    func glassPanel(radius: CGFloat = 18) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
    }
}

// MARK: - Hardware-style badges

/// A recessed indicator plate with an LED, like the format lights on a DAC's front panel.
struct HWBadge: View {
    enum Tone: CaseIterable {
        case neutral, blue, green, amber, purple, orange
        var rgb: RGB {
            switch self {
            case .neutral: RGB(0.82, 0.82, 0.82); case .blue: RGB(0.45, 0.72, 1); case .green: RGB(0.36, 0.9, 0.55)
            case .amber: RGB(1, 0.78, 0.3); case .purple: RGB(0.75, 0.6, 1); case .orange: RGB(1, 0.58, 0.28)
            }
        }
        var color: Color { rgb.color }
        /// Opacity of the plate's black at its lightest (bottom) edge. With it, every legend keeps 4.5:1 even on a white page (see the self-test).
        static let plateAlpha = 0.78
    }
    let text: String
    var detail: String? = nil
    var tone: Tone = .neutral
    var lit = true
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            ZStack {
                Circle().fill(lit ? tone.color : Color.white.opacity(0.15)).frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
                    .shadow(color: lit ? tone.color.opacity(0.95) : .clear, radius: 3)
                if lit { Circle().fill(.white.opacity(0.75)).frame(width: 1.6, height: 1.6).offset(x: -0.6, y: -0.6) }     // a domed LED's specular point
            }
            Text(text).font(.system(size: compact ? 9.5 : 11, weight: .bold, design: .monospaced)).tracking(compact ? 0.8 : 1.1).foregroundStyle(tone.color)
                .shadow(color: lit ? tone.color.opacity(0.5) : .clear, radius: 3.5)
            if let detail {
                Rectangle().fill(Brand.ink.opacity(0.18)).frame(width: 1, height: compact ? 9 : 11)
                Text(detail).font(.system(size: compact ? 9.5 : 11, weight: .semibold, design: .monospaced)).monospacedDigit().foregroundStyle(.white.opacity(0.88))
            }
        }
        .padding(.horizontal, compact ? 6 : 9).padding(.vertical, compact ? 3 : 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [.black.opacity(0.85), .black.opacity(Tone.plateAlpha)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(LinearGradient(colors: [.black.opacity(0.5), .white.opacity(0.22)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(text), \($0)" } ?? text)
    }
}

/// The gold "Hi-Res Audio" style mark.
struct HiResMark: View {
    var compact = false
    private let gold = LinearGradient(colors: [Color(red: 1, green: 0.88, blue: 0.5), Color(red: 0.86, green: 0.62, blue: 0.2), Color(red: 1, green: 0.84, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
    var body: some View {
        VStack(spacing: 1) {
            Text("Hi-Res").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(gold)
            Text("AUDIO").font(.system(size: 6, weight: .bold)).tracking(3).foregroundStyle(gold).opacity(0.85)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(gold, lineWidth: 1))
        .shadow(color: Color(red: 1, green: 0.78, blue: 0.3).opacity(0.35), radius: 6)
        .scaleEffect(compact ? 0.8 : 1).frame(width: compact ? 62 : nil, height: compact ? 28 : nil)
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
        WrapLayout(spacing: compact ? 5 : 8, lineSpacing: compact ? 5 : 8) {
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

/// Cover art with a generated placeholder: a soft gradient in the album's own colours.
struct CoverView: View {
    let image: NSImage?
    let palette: ArtPalette
    var corner: CGFloat = 16
    var symbol = "music.note"

    var body: some View {
        GeometryReader { g in
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill).frame(width: g.size.width, height: g.size.height).clipped().transition(.opacity)
                } else {
                    LinearGradient(colors: [palette.grid[0].color, palette.grid[4].color, palette.grid[8].color], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: symbol).font(.system(size: g.size.width * 0.3, weight: .ultraLight)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Brand.ink.opacity(0.12), lineWidth: 0.8))
    }
}

// MARK: - Fluid slider

/// A slim slider that swells under the pointer, shows a knob and a value bubble, and animates between playback updates.
struct FluidSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = Brand.ink
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
            let h = active ? restingHeight * 1.9 : restingHeight
            let f = fraction(value)
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.ink.opacity(enabled ? 0.2 : 0.1)).frame(height: h)
                Capsule().fill(tint.opacity(enabled ? 1 : 0.35)).frame(width: max(h, w * f), height: h)
                    .shadow(color: tint.opacity(active ? 0.55 : 0), radius: 6)
                Circle().fill(.white).frame(width: 15, height: 15).shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .scaleEffect(active ? 1 : 0.01).opacity(active ? 1 : 0)
                    .offset(x: min(max(0, w * f - 7.5), w - 15))
                if let bubble, enabled, active {
                    let shown = dragging.v ? value : (pointerX.v.map { range.lowerBound + Double(min(1, max(0, $0 / w))) * (range.upperBound - range.lowerBound) } ?? value)
                    Text(bubble(shown)).font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(.black.opacity(0.65)))
                        .foregroundStyle(.white).fixedSize()
                        .offset(x: min(max(0, (dragging.v ? w * f : (pointerX.v ?? w * f)) - 22), max(0, w - 44)), y: -24)
                        .allowsHitTesting(false).transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: w, height: g.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .animation(.smooth(duration: 0.18), value: active)
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

struct TransportButtonStyle: ButtonStyle {
    var size: CGFloat = 22
    /// Colour of the glyphs: white on the immersive Now Playing page, the theme's ink on the player bar.
    var ink: Color = .white
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, size: size, ink: ink) }

    private struct Inner: View {
        let configuration: Configuration
        let size: CGFloat
        let ink: Color
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(ink.opacity(enabled ? 1 : 0.35))
                .frame(width: size * 2, height: size * 2)
                .background(Circle().fill(ink.opacity(configuration.isPressed ? 0.2 : (hover.v && enabled ? 0.12 : 0))))
                .scaleEffect(configuration.isPressed ? 0.9 : (hover.v && enabled ? 1.06 : 1))
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
                .animation(.smooth(duration: 0.15), value: hover.v)
                .onHover { hover.v = $0 }
        }
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
            Capsule().fill(Brand.ink.opacity(0.12)).frame(width: 4, height: height)
            // gain fill: from the zero line to the knob
            Capsule().fill(Brand.gradient).frame(width: 4, height: max(2, abs(f - mid) * height))
                .position(x: 15, y: height * (1 - (f + mid) / 2)).opacity(enabled ? 1 : 0.3)
            Rectangle().fill(Brand.ink.opacity(0.3)).frame(width: 12, height: 1).position(x: 15, y: height * (1 - mid))
            Circle().fill(.white).frame(width: active ? 14 : 11, height: active ? 14 : 11).shadow(color: Brand.violet.opacity(active ? 0.8 : 0.3), radius: active ? 6 : 2)
                .position(x: 15, y: height * (1 - f))
        }
        .frame(width: 30, height: height)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover.v = $0 }
        .scrollAdjustable(hovering: hover.v && enabled) { n in value = ScrollStep.apply(value: value, notches: n, range: range); return true }
        .animation(.easeOut(duration: 0.12), value: active)
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

import SwiftUI
import AppKit

enum Brand {
    /// The colour of primary actions and selected navigation, outside the cover-tinted player.
    static let accent = Color(red: 0.50, green: 0.55, blue: 1.0)
    static let cyan = Color(red: 0.36, green: 0.87, blue: 1.0)
    static let violet = Color(red: 0.58, green: 0.45, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.42, blue: 0.76)
    /// The signature gradient: used sparingly, on the selected item, primary buttons and progress.
    static let gradient = LinearGradient(colors: [cyan, violet, pink], startPoint: .leading, endPoint: .trailing)
    static let gradientDiagonal = LinearGradient(colors: [cyan, violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension View {
    /// A floating glass panel: a faint fill, a hairline that catches light at the top edge, optional coloured glow.
    func panel(radius: CGFloat = 18, fill: Double = 0.045, glow: Color? = nil) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(fill)))
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
    enum Tone {
        case neutral, blue, green, amber, purple, orange
        var color: Color {
            switch self {
            case .neutral: Color(white: 0.82); case .blue: Color(red: 0.45, green: 0.72, blue: 1); case .green: Color(red: 0.36, green: 0.9, blue: 0.55)
            case .amber: Color(red: 1, green: 0.78, blue: 0.3); case .purple: Color(red: 0.75, green: 0.6, blue: 1); case .orange: Color(red: 1, green: 0.58, blue: 0.28)
            }
        }
    }
    let text: String
    var detail: String? = nil
    var tone: Tone = .neutral
    var lit = true
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            Circle().fill(lit ? tone.color : Color.white.opacity(0.15)).frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
                .shadow(color: lit ? tone.color.opacity(0.9) : .clear, radius: 3)
            Text(text).font(.system(size: compact ? 9.5 : 11, weight: .bold, design: .monospaced)).tracking(compact ? 0.8 : 1.1).foregroundStyle(tone.color)
            if let detail {
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: compact ? 9 : 11)
                Text(detail).font(.system(size: compact ? 9.5 : 11, weight: .semibold, design: .monospaced)).monospacedDigit().foregroundStyle(.white.opacity(0.88))
            }
        }
        .padding(.horizontal, compact ? 6 : 9).padding(.vertical, compact ? 3 : 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [.black.opacity(0.42), .black.opacity(0.22)], startPoint: .top, endPoint: .bottom))
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
        HStack(spacing: compact ? 5 : 8) {
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
        .fixedSize()
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
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.8))
    }
}

// MARK: - Fluid slider

/// A slim slider that swells under the pointer, shows a knob and a value bubble, and animates between playback updates.
struct FluidSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .white
    var restingHeight: CGFloat = 4
    var enabled = true
    var bubble: ((Double) -> String)? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    @StateObject private var hover = Box(false)
    @StateObject private var dragging = Box(false)
    @StateObject private var pointerX = Box<CGFloat?>(nil)

    private func fraction(_ v: Double) -> CGFloat { range.upperBound > range.lowerBound ? CGFloat(min(1, max(0, (v - range.lowerBound) / (range.upperBound - range.lowerBound)))) : 0 }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, active = enabled && (hover.v || dragging.v)
            let h = active ? restingHeight * 1.9 : restingHeight
            let f = fraction(value)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(enabled ? 0.2 : 0.1)).frame(height: h)
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
                if !dragging.v { dragging.v = true; onEditingChanged(true) }
                value = range.lowerBound + Double(min(1, max(0, d.location.x / w))) * (range.upperBound - range.lowerBound)
            }.onEnded { _ in
                guard enabled else { return }
                dragging.v = false; onEditingChanged(false)
            })
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
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, size: size) }

    private struct Inner: View {
        let configuration: Configuration
        let size: CGFloat
        @StateObject private var hover = Box(false)
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                .frame(width: size * 2, height: size * 2)
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.2 : (hover.v && enabled ? 0.12 : 0))))
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
            Capsule().fill(.white.opacity(0.12)).frame(width: 4, height: height)
            // gain fill: from the zero line to the knob
            Capsule().fill(Brand.gradient).frame(width: 4, height: max(2, abs(f - mid) * height))
                .position(x: 15, y: height * (1 - (f + mid) / 2)).opacity(enabled ? 1 : 0.3)
            Rectangle().fill(.white.opacity(0.3)).frame(width: 12, height: 1).position(x: 15, y: height * (1 - mid))
            Circle().fill(.white).frame(width: active ? 14 : 11, height: active ? 14 : 11).shadow(color: Brand.violet.opacity(active ? 0.8 : 0.3), radius: active ? 6 : 2)
                .position(x: 15, y: height * (1 - f))
        }
        .frame(width: 30, height: height)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover.v = $0 }
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

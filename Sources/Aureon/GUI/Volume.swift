import SwiftUI

// The volume: a wide, thin gold line with a mark you can always see, a mute button and a number. It sets the output device's own volume (the samples
// are never scaled), so it stays bit-perfect. Nothing here touches the audio path.

/// The level a mute came from.
struct MuteMemory: Equatable {
    var before: Float?
    /// Mutes (remembering the level) or, when already silent, restores it (a middle level if there is nothing to restore).
    mutating func toggle(current: Float, set: (Float) -> Void) {
        if current > 0.001 { before = current; set(0) }
        else { set(before ?? 0.3); before = nil }
    }
    func isMuted(_ level: Float) -> Bool { level <= 0.001 }
}

/// How pointer, keys and the wheel turn into a level. Pure, so the rules are testable.
enum VolumeMath {
    /// A press at `fraction` of the width goes there at once, but never more than `jumpUp` above the current level in one go (an accidental click
    /// at the loud end cannot slam the volume); dragging on from there follows the pointer.
    static func press(at fraction: Double, current: Double, jumpUp: Double = 0.15) -> Double {
        let f = min(1, max(0, fraction))
        return min(f, min(1, current + jumpUp))
    }
    static func drag(to fraction: Double) -> Double { min(1, max(0, fraction)) }
    /// A key press moves by `step`; with ⌥ by a fifth of it.
    static func key(_ direction: Int, current: Double, step: Double = 0.02, fine: Bool = false) -> Double { min(1, max(0, current + Double(direction) * (fine ? step / 5 : step))) }
    static let resetLevel = 0.5
}

/// When scrolling changes the volume. A wheel or trackpad passing over a wide bar must never move it by accident, so by default it takes ⌥ held; the other
/// choices are off, or a plain wheel only over the handle itself. Pure, so the rules are testable.
enum ScrollVolumeMode: String, CaseIterable, Identifiable {
    case off, optionOnly, handle
    var id: String { rawValue }
    var title: String { switch self { case .off: "Off"; case .optionOnly: "⌥ + scroll"; case .handle: "Over the handle" } }
    var hint: String {
        switch self {
        case .off: "Scrolling never changes the volume. Use the slider, the keys or the buttons."
        case .optionOnly: "Hold ⌥ and scroll over the volume bar. A plain scroll over it scrolls the page."
        case .handle: "A plain scroll changes the volume only with the pointer on the handle; elsewhere on the bar it scrolls the page."
        }
    }
    static let storageKey = "aureon.scrollVolume"
    static var saved: ScrollVolumeMode { UserDefaults.standard.string(forKey: storageKey).flatMap(ScrollVolumeMode.init(rawValue:)) ?? .optionOnly }

    /// How far from the handle's centre a plain wheel still counts as on it (points).
    static let handleRadius: CGFloat = 14
    /// Gentle: one notch is a percent, and no single event moves it more than three.
    static let perNotch = 0.01, maxPerEvent = 0.03

    /// Whether the slider listens to the wheel while the pointer is at `pointerX` of a bar whose handle is at `handleX`.
    func listens(pointerX: CGFloat, handleX: CGFloat) -> Bool {
        switch self {
        case .off: false
        case .optionOnly: true                      // the router asks for ⌥ itself
        case .handle: abs(pointerX - handleX) <= Self.handleRadius
        }
    }
    /// Whether the router should take a plain wheel (without ⌥) for this slider.
    var takesPlainWheel: Bool { self == .handle }

    static func apply(value: Double, notches: Double) -> Double { ScrollStep.apply(value: value, notches: notches, range: 0...1, perNotch: perNotch, maxMove: maxPerEvent) }
}

struct VolumeSlider: View {
    @Binding var value: Double
    var enabled = true
    var limit: Double = 1
    var height: CGFloat = 28

    @StateObject private var hover = Box(false)
    @StateObject private var dragging = Box(false)
    @StateObject private var pointerX = Box(CGFloat(0))
    @FocusState private var focused: Bool
    @AppStorage(ScrollVolumeMode.storageKey) private var scrollMode = ScrollVolumeMode.optionOnly.rawValue
    private var mode: ScrollVolumeMode { ScrollVolumeMode(rawValue: scrollMode) ?? .optionOnly }

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width), active = enabled && (hover.v || dragging.v || focused)
            let f = CGFloat(min(1, max(0, value)))
            ZStack(alignment: .leading) {
                Rectangle().fill(Brand.ink.opacity(enabled ? 0.24 : 0.12)).frame(height: active ? 2 : 1)
                if limit < 1 { Rectangle().fill(Brand.ink.opacity(0.5)).frame(width: 1, height: 8).offset(x: CGFloat(limit) * w - 1) }   // the safety limit
                Rectangle().fill(enabled ? Brand.accent : Brand.ink.opacity(0.3)).frame(width: max(1, w * f), height: active ? 2 : 1.5)
                Rectangle().fill(enabled ? Brand.accent : Brand.ink.opacity(0.3)).frame(width: 3, height: 16)
                    .offset(x: min(max(0, w * f - 1.5), w - 3))
            }
            .frame(width: w, height: g.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .animation(Motion.touch, value: active)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover.v = true; pointerX.v = p.x
                case .ended: hover.v = false
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                guard enabled else { return }
                if !dragging.v {
                    dragging.v = true; focused = true
                    value = VolumeMath.press(at: Double(d.startLocation.x / w), current: value)
                } else {
                    value = VolumeMath.drag(to: Double(d.location.x / w))
                }
            }.onEnded { _ in dragging.v = false })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { value = VolumeMath.resetLevel } })
            .scrollAdjustable(hovering: hover.v && enabled && mode.listens(pointerX: pointerX.v, handleX: w * f), plainWheel: mode.takesPlainWheel) { notches in
                value = ScrollVolumeMode.apply(value: value, notches: notches)
                return true
            }
        }
        .frame(height: height)
        .focusable(enabled).focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { k in value = VolumeMath.key(-1, current: value, fine: k.modifiers.contains(.option)); return .handled }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { k in value = VolumeMath.key(1, current: value, fine: k.modifiers.contains(.option)); return .handled }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { k in value = VolumeMath.key(-1, current: value, fine: k.modifiers.contains(.option)); return .handled }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { k in value = VolumeMath.key(1, current: value, fine: k.modifiers.contains(.option)); return .handled }
        .opacity(enabled ? 1 : 0.6)
        .accessibilityElement().accessibilityLabel("Volume").accessibilityValue(Text("\(Int((value * 100).rounded())) percent"))
        .accessibilityAdjustableAction { dir in value = VolumeMath.key(dir == .increment ? 1 : -1, current: value, step: 0.05) }
        .help("Drag, hold ⌥ and scroll, or use the arrow keys. Double-click for half.")
    }
}

/// Mute, the slider and the number.
struct VolumeControl: View {
    @EnvironmentObject var m: PlayerModel
    var width: CGFloat? = 120
    var readout = true

    var body: some View {
        let v = Double(m.volume), muted = m.muteMemory.isMuted(m.volume)
        HStack(spacing: 8) {
            Button { m.toggleMute() } label: {
                Image(systemName: !m.hasVolume ? "lock" : (muted ? "speaker.slash" : (v < 0.34 ? "speaker.wave.1" : (v < 0.67 ? "speaker.wave.2" : "speaker.wave.3"))))
                    .font(Typo.sans(13, .light)).frame(width: 20).foregroundStyle(muted ? Brand.caution : Brand.inkSecondary)
            }
            .buttonStyle(IconButtonStyle()).disabled(!m.hasVolume)
            .help(muted ? "Unmute" : "Mute").accessibilityLabel(muted ? "Unmute" : "Mute")
            VolumeSlider(value: Binding(get: { Double(m.volume) }, set: { m.setVolume(Float($0)) }), enabled: m.hasVolume, limit: Double(m.volumeLimit))
                .frame(width: width)
            if readout {
                Text(m.hasVolume ? "\(Int((v * 100).rounded()))%" : "—").font(Typo.mono(11, .regular)).foregroundStyle(v > 0.85 ? Brand.caution : Brand.inkSecondary)
                    .frame(width: 36, alignment: .trailing).accessibilityHidden(true)
            }
        }
        .help(m.hasVolume ? (v > 0.9 ? "High device volume: check your amplifier before playing." : "Applied by the device itself, so the samples stay untouched.")
              : "This device has no software volume. Use your DAC or amplifier: samples are never scaled here.")
    }
}

import SwiftUI

// Atelier → Sound is split into five focused tabs, so no tab is a wall of controls. Every setting that was on the old single page is on exactly one of them
// (`SoundGroup` lists them; the reachability test checks the split against it).

/// One group of settings on the Sound page: a titled section with its own controls.
enum SoundGroup: String, CaseIterable, Identifiable {
    case output, multichannel, extremeResolution, upsampling, dsdFiles, pcmToDSD, dither, levelling, headphones, room, transitions, memory, radio, visualiser
    var id: String { rawValue }
}

enum SoundSection: String, CaseIterable, Identifiable {
    case output, conversion, levels, space, playback
    var id: String { rawValue }

    var title: String {
        switch self { case .output: "Output"; case .conversion: "Conversion"; case .levels: "Levels"; case .space: "Headphones & room"; case .playback: "Playback" }
    }
    /// What the tab is for, in a line (for the palette and the tooltip).
    var blurb: String {
        switch self {
        case .output: "The device, its rate and volume, exclusive access, surround and the highest resolutions"
        case .conversion: "Upsampling, PCM to DSD and DSD playback: everything that changes the samples' format"
        case .levels: "Volume levelling and dither: how loud, and how the last bits are rounded"
        case .space: "Headphone correction, crossfeed and room correction"
        case .playback: "Gapless and crossfade, memory playback, internet radio and the visualiser"
        }
    }
    var icon: String {
        switch self { case .output: "hifispeaker"; case .conversion: "waveform.path"; case .levels: "speaker.wave.2"; case .space: "headphones"; case .playback: "forward.end" }
    }
    var groups: [SoundGroup] {
        switch self {
        case .output: [.output, .multichannel, .extremeResolution]
        case .conversion: [.upsampling, .pcmToDSD, .dsdFiles]
        case .levels: [.levelling, .dither]
        case .space: [.headphones, .room]
        case .playback: [.transitions, .memory, .radio, .visualiser]
        }
    }
    /// The tab a group is on.
    static func holding(_ g: SoundGroup) -> SoundSection? { allCases.first { $0.groups.contains(g) } }

    /// The tab before or after, for the direction of a change.
    static func saved(_ raw: String?) -> SoundSection { raw.flatMap(SoundSection.init(rawValue:)) ?? .output }
}

extension PlayerModel {
    func showSound(_ s: SoundSection) { soundSection = s; djMode = false; settingsPage = nil; tab = .audio }
}

/// The thin strip at the top of Sound: the chain as it stands, and whether it is still bit-perfect.
struct SoundVerdictStrip: View {
    @EnvironmentObject var m: PlayerModel

    /// The stages the signal passes through with the current settings; the ones that change the samples are marked.
    static func stages(_ st: PlaybackSettings) -> [(name: String, alters: Bool)] {
        var out: [(String, Bool)] = [("Decode", false)]
        if st.ram.enabled { out.append(("RAM", false)) }
        if st.upsampling.mode != .off || st.dsdOutput.enabled { out.append(("Resample", true)) }
        if st.dsdOutput.enabled { out.append(("DSD", true)) }
        if st.replayGain.mode != .off { out.append(("Gain", true)) }
        if st.transition.mode != .off { out.append((st.transition.mode == .smart ? "Smart fade" : "Crossfade", true)) }
        out.append(("Ring", false))
        if st.rt.convolution.enabled { out.append(("Room", true)) }
        if st.rt.crossfeed.enabled { out.append(("Crossfeed", true)) }
        if st.rt.headphoneEQ.enabled { out.append(("AutoEQ", true)) }
        out.append(st.dsp.enabled ? ("DSP", true) : ("Direct", false))
        out.append(("DAC", false))
        return out
    }

    var body: some View {
        let stages = Self.stages(m.settings)
        let altered = stages.filter(\.alters).map(\.name)
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 6) {
                Rectangle().fill(altered.isEmpty ? Brand.accent : Brand.caution).frame(width: 6, height: 6)
                Text(altered.isEmpty ? "Bit-perfect" : "Processing").font(Typo.sans(10, .medium)).tracking(1.6).textCase(.uppercase)
                    .foregroundStyle(altered.isEmpty ? Brand.accentText : Brand.caution)
            }
            .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                        Text(s.name).font(Typo.mono(10, .regular)).tracking(0.8).textCase(.uppercase)
                            .foregroundStyle(s.alters ? Brand.caution : Brand.inkSecondary)
                        if i < stages.count - 1 { Text("›").font(Typo.mono(10, .regular)).foregroundStyle(Brand.inkTertiary) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rule() }.overlay(alignment: .bottom) { Rule() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(altered.isEmpty ? "Signal path is bit-perfect: \(stages.map(\.name).joined(separator: ", "))" : "Signal path is processing: \(altered.joined(separator: ", "))")
    }
}

/// The tab line under the Atelier line when Sound is open: the five tabs in small capitals, the gold line gliding to the chosen one.
struct SoundTabBar: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        TabLine(items: SoundSection.allCases.map { TabLineItem(id: $0, title: $0.title) }, selection: Binding(get: { m.soundSection }, set: { s in withAnimation(TabMotion.animation) { m.soundSection = s } }), tracking: 1.6, spacing: 24, height: 28, labelPrefix: "Sound")
            .frame(maxWidth: .infinity)
    }
}

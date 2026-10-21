import SwiftUI

struct AudioTab: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var confirm = Box(false)

    var body: some View {
        VStack(spacing: 18) {
            Card(title: "Playback pipeline", subtitle: "Dual path: with everything below off, audio goes untouched from the file to the DAC") {
                HStack(spacing: 6) {
                    let stages = pipelineStages
                    ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                        Badge(text: s.0, color: s.1)
                        if i < stages.count - 1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
            OutputCard()
            radioCard
            artworkCard
            visualiserCard
            HeadphoneCard(hp: m.headphones)
            RoomCard()
            upsampling
            dsd
            memory
            replayGain
        }
        .confirmationDialog("Enable DoP?", isPresented: $confirm.v, titleVisibility: .visible) {
            Button("My DAC supports DoP — enable", role: .destructive) { m.settings.dsd.mode = .dop }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DoP sends DSD data inside a PCM stream. A DAC that does not understand DoP will play it as very loud noise. Lower the volume first.")
        }
    }

    private var radioCard: some View {
        Card(title: "Internet radio", subtitle: "Free stations on the Radio page: MP3, AAC and FLAC streams") {
            Toggle("Upscale streams to the DAC's best rate", isOn: $m.settings.radio.upscale)
            if m.settings.radio.upscale {
                Picker("Highest rate", selection: $m.settings.radio.maxRate) {
                    ForEach([96_000.0, 176_400, 192_000, 384_000], id: \.self) { Text(formatRate($0)).tag($0) }
                }
            }
            Note(text: "Radio is lossy, so this cannot bring back detail the broadcaster removed. What it does: one high-quality resampling step (long sinc filter) instead of the system mixer's, and the filter's images fall far above the audible band. Lossless FLAC stations are marked and play bit-perfect when upscaling is off.")
        }
    }

    private var artworkCard: some View {
        Card(title: "Artwork", subtitle: "Covers come from the file's own tags first (FLAC pictures, ID3, ALAC covr)") {
            Toggle("Look up missing covers online", isOn: $m.fetchMissingArt)
            Note(text: "Only the artist and album names are sent, to the iTunes Search API and, failing that, MusicBrainz / Cover Art Archive. Results are cached on this Mac.")
        }
    }

    private var visualiserCard: some View {
        Card(title: "Visualiser", subtitle: "Spectrum, spectrogram and VU meters on the Player tab. Computed from a copy of the audio on its own thread") {
            Toggle("Show the analyser", isOn: $m.visualizerEnabled)
            HStack {
                Text("0 VU =").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { m.player.analysis.vuReferenceDBFS }, set: { m.player.analysis.vuReferenceDBFS = $0; m.objectWillChange.send() })) {
                    Text("−18 dBFS (EBU)").tag(Float(-18)); Text("−20 dBFS (SMPTE)").tag(Float(-20)); Text("−14 dBFS").tag(Float(-14))
                }.labelsHidden().fixedSize()
            }
        }
    }

    private var pipelineStages: [(String, Color)] {
        let st = m.settings
        var out: [(String, Color)] = [("Decode", .blue)]
        if st.ram.enabled { out.append(("RAM", .blue)) }
        if st.upsampling.mode != .off { out.append(("Resample", .orange)) }
        if st.replayGain.mode != .off { out.append(("Gain", .orange)) }
        out.append(("Ring", .blue))
        if st.rt.convolution.enabled { out.append(("Room", .orange)) }
        if st.rt.crossfeed.enabled { out.append(("Crossfeed", .orange)) }
        if st.rt.headphoneEQ.enabled { out.append(("AutoEQ", .orange)) }
        out.append(st.dsp.enabled ? ("DSP", .orange) : ("Direct", .green))
        out.append(("DAC", .blue))
        return out
    }

    private var upsampling: some View {
        Card(title: "Upsampling", subtitle: "Native polyphase sinc resampler, any rational ratio. Changes the samples, so it is off by default") {
            Picker("Target", selection: $m.settings.upsampling.mode) { ForEach(UpsamplingMode.allCases) { Text($0.title).tag($0) } }
            if m.settings.upsampling.mode != .off {
                Picker("Filter", selection: $m.settings.upsampling.filter.phase) { ForEach(ResamplerConfig.Phase.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Note(text: m.settings.upsampling.filter.phase == .linear ? "Constant delay, symmetric ringing before and after transients." : "No pre-ringing; slight frequency-dependent delay.")
                HStack {
                    Text("Pass-band")
                    Slider(value: $m.settings.upsampling.filter.passband, in: 0.90...0.99, step: 0.005)
                    Text(String(format: "%.1f%%", m.settings.upsampling.filter.passband * 100)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                Picker("Stop-band", selection: $m.settings.upsampling.filter.stopbandDB) {
                    ForEach([96.0, 120, 144], id: \.self) { Text("\(Int($0)) dB").tag($0) }
                }.pickerStyle(.segmented)
                Picker("Highest rate", selection: $m.settings.upsampling.maxRate) {
                    Text("Device maximum").tag(0.0)
                    ForEach([96_000.0, 192_000, 384_000], id: \.self) { Text(formatRate($0)).tag($0) }
                }
                Note(text: "Steeper filters use more CPU. Changes apply within a moment, at the current position.")
            }
            Toggle("Resample material the device cannot play natively", isOn: $m.settings.upsampling.downsampleToFit)
        }
    }

    private var dsd: some View {
        Card(title: "DSD", subtitle: "DSF and DFF files (DST-compressed DFF is not supported)") {
            Picker("Output", selection: Binding(get: { m.settings.dsd.mode }, set: { newValue in
                if newValue == .dop { confirm.v = true } else { m.settings.dsd.mode = newValue }
            })) { ForEach(DSDMode.allCases) { Text($0.title).tag($0) } }
            if m.settings.dsd.mode == .pcm {
                Picker("PCM rate", selection: $m.settings.dsd.pcmRate) { ForEach([88_200.0, 176_400, 352_800], id: \.self) { Text(formatRate($0)).tag($0) } }.pickerStyle(.segmented)
                HStack {
                    Text("Level")
                    Slider(value: $m.settings.dsd.gainDB, in: -12...12, step: 0.5)
                    Text(String(format: "%+.1f dB", m.settings.dsd.gainDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                Note(text: "DSD's nominal 0 dB sits 6 dB below PCM full scale; add gain here if it sounds low.")
            } else {
                Note(text: "DSD bits are passed untouched (16 per PCM sample, alternating 0x05/0xFA markers that continue across tracks). Upsampling, ReplayGain, polarity and DSP are bypassed. Needs a device rate of 176.4 kHz or higher; otherwise Aureon converts to PCM.", color: .orange)
            }
        }
    }

    private var memory: some View {
        Card(title: "Memory playback", subtitle: "Decode whole tracks into RAM before playing: no disk reads or decoding while you listen") {
            Toggle("Load tracks into RAM", isOn: $m.settings.ram.enabled)
            if m.settings.ram.enabled {
                Stepper("Budget: \(m.settings.ram.budgetMB) MB", value: $m.settings.ram.budgetMB, in: 256...16_384, step: 256)
                let used = m.status.ramBytes
                ProgressView(value: min(1, Double(used) / Double(m.settings.ram.budgetMB << 20))) { Text("In use: \(formatBytes(used))").font(.caption) }
                Note(text: "The playing track and the next two are kept resident; a track larger than the budget streams from disk. 24-bit/96 kHz stereo needs about 1.4 MB per second.")
            }
        }
    }

    private var replayGain: some View {
        Card(title: "ReplayGain", subtitle: "Reads ReplayGain tags (FLAC Vorbis, ID3, iTunes); measures EBU R128 loudness when a file has none") {
            Picker("Mode", selection: $m.settings.replayGain.mode) { ForEach(ReplayGainMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            if m.settings.replayGain.mode != .off {
                HStack {
                    Text("Pre-amp")
                    Slider(value: $m.settings.replayGain.preampDB, in: -12...12, step: 0.5)
                    Text(String(format: "%+.1f dB", m.settings.replayGain.preampDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                Toggle("Prevent clipping using the track's peak", isOn: $m.settings.replayGain.preventClipping)
                Toggle("Measure loudness for untagged files (−18 LUFS)", isOn: $m.settings.replayGain.analyzeUntagged)
                if let g = m.status.replayGainDB { Note(text: String(format: "Applying %+.2f dB to the current track.", g)) }
                Note(text: "Leveling scales the samples, so playback is no longer bit-perfect while it is on.", color: .orange)
            }
        }
    }
}

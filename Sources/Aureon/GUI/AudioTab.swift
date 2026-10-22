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
            SpeakerSetupCard()
            CastCard()
            ZoneCard()
            radioCard
            visualiserCard
            HeadphoneCard(hp: m.headphones)
            DitherCard()
            RoomCard()
            upsampling
            dsd
            memory
            replayGain
            multichannel
            extreme
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
                SegmentedChoice(selection: $m.settings.upsampling.filter.phase, items: Array(ResamplerConfig.Phase.allCases)) { $0.title }
                Note(text: m.settings.upsampling.filter.phase == .linear ? "Constant delay, symmetric ringing before and after transients." : "No pre-ringing; slight frequency-dependent delay.")
                HStack {
                    Text("Pass-band")
                    Slider(value: $m.settings.upsampling.filter.passband, in: 0.90...0.99, step: 0.005)
                    Text(String(format: "%.1f%%", m.settings.upsampling.filter.passband * 100)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                HStack { Text("Stop-band"); SegmentedChoice(selection: $m.settings.upsampling.filter.stopbandDB, items: [96.0, 120, 144]) { "\(Int($0)) dB" } }
                Picker("Highest rate", selection: $m.settings.upsampling.maxRate) {
                    Text("Device maximum").tag(0.0)
                    ForEach([96_000.0, 192_000, 384_000, 768_000, 1_536_000], id: \.self) { Text(formatRate($0)).tag($0) }
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
                SegmentedChoice(selection: $m.settings.dsd.pcmRate, items: [88_200.0, 176_400, 352_800, 705_600, 1_411_200]) { formatRate($0) }
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

    private var extreme: some View {
        let p = PerformanceProfile.ready
        return Card(title: "Extreme resolution", subtitle: "DSD512 / DSD1024 and PCM up to 1536 kHz") {
            Note(text: p.summary, color: p.tier == .low ? .orange : .green)
            Note(text: "DSD1024 runs \(String(format: "%.0f", p.dsdFactor(dsdRate: 45_158_400, channels: 2)))× real time here and PCM at 1536 kHz \(String(format: "%.0f", p.resampleFactor(rate: 1_536_000, channels: 2)))×. " + (p.tier == .high ? "Nothing to tune: buffers are generous and the output callback is kept infrequent." : p.tier == .medium ? "Buffers are enlarged at megahertz rates to stay clear of dropouts." : "This Mac is at its limit at megahertz rates: Aureon lowers the output rate when a stream would not keep up, and says so in the signal path."))
        }
    }

    private var multichannel: some View {
        Card(title: "Multichannel (5.1 / 7.1)", subtitle: "Surround FLAC, ALAC, WAV, AIFF and DSD files") {
            SegmentedChoice(selection: $m.settings.multichannel.mode, items: Array(MultichannelMode.allCases)) { $0.title }
            Note(text: m.settings.multichannel.mode.blurb)
            Toggle("Include the LFE (subwoofer) channel when mixing down", isOn: $m.settings.multichannel.includeLFE)
            Note(text: "A surround file on a device with enough outputs is sent to every speaker unchanged. Mixing down is the only processing, so it is the only thing that makes a stream not bit-perfect.")
        }
    }

    private var replayGain: some View {
        Card(title: "Volume leveling", subtitle: "ReplayGain tags (FLAC Vorbis, ID3, iTunes), or EBU R128 loudness measured from the audio itself") {
            SegmentedChoice(selection: $m.settings.replayGain.mode, items: Array(ReplayGainMode.allCases)) { $0.title }
            if m.settings.replayGain.mode != .off {
                HStack {
                    Text("Pre-amp")
                    Slider(value: $m.settings.replayGain.preampDB, in: -12...12, step: 0.5)
                    Text(String(format: "%+.1f dB", m.settings.replayGain.preampDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                Toggle("Prevent clipping using the track's peak", isOn: $m.settings.replayGain.preventClipping)
                Toggle("Measure loudness for untagged files (−18 LUFS)", isOn: $m.settings.replayGain.analyzeUntagged)
                HStack {
                    Text("Target").frame(width: 80, alignment: .leading)
                    Picker("", selection: $m.settings.replayGain.referenceLUFS) {
                        Text("−23 LUFS  EBU R128 broadcast").tag(-23.0); Text("−18 LUFS  ReplayGain 2").tag(-18.0); Text("−16 LUFS  Podcasts, Apple Sound Check").tag(-16.0); Text("−14 LUFS  Streaming").tag(-14.0)
                    }.labelsHidden().frame(width: 290)
                }
                if m.settings.replayGain.mode == .loudness {
                    HStack(spacing: 10) {
                        if m.library.analysingLoudness {
                            ProgressView(value: Double(m.library.loudnessDone), total: Double(max(1, m.library.loudnessTotal))).frame(width: 160)
                            Text("\(m.library.loudnessDone) / \(m.library.loudnessTotal) songs measured").font(.caption).foregroundStyle(.secondary)
                            Button("Stop") { m.library.stopLoudnessAnalysis() }
                        } else {
                            Button("Measure the whole library") { m.library.startLoudnessAnalysis() }.disabled(m.library.loudnessTotal > 0 && m.library.loudnessDone >= m.library.loudnessTotal)
                            Text(m.library.loudnessTotal == 0 ? "No songs in the library yet" : "\(m.library.loudnessDone) of \(m.library.loudnessTotal) songs measured").font(.caption).foregroundStyle(.secondary)
                        }
                    }.onAppear { m.library.refreshLoudnessProgress() }
                    Note(text: "Every song is levelled by its own measured loudness (integrated LUFS, true-peak limited), so a quiet 1970s master and a loud modern one play at the same volume. Measuring happens once per file and is stored in your library.")
                }
                if let g = m.status.replayGainDB { Note(text: String(format: "Applying %+.2f dB to the current track.", g)) }
                Note(text: "Leveling scales the samples, so playback is no longer bit-perfect while it is on.", color: .orange)
            }
        }
    }
}

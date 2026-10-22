import SwiftUI
import AppKit

struct HeadphoneCard: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject var hp: HeadphoneModel

    var body: some View {
        Card(title: "Headphones", subtitle: "Crossfeed and measurement-based correction. These change the samples, so they are off by default") {
            Toggle("Crossfeed (Bauer BS2B)", isOn: $m.settings.rt.crossfeed.enabled)
            if m.settings.rt.crossfeed.enabled {
                Menu("Preset") {
                    ForEach(CrossfeedSettings.presets, id: \.name) { p in Button(p.name) { m.settings.rt.crossfeed.cutoffHz = p.cutoff; m.settings.rt.crossfeed.feedDB = p.feed } }
                }.fixedSize()
                HStack {
                    Text("Cut frequency").frame(width: 110, alignment: .leading)
                    ValueSlider(value: $m.settings.rt.crossfeed.cutoffHz, in: 300...2000, step: 10)
                    Text("\(Int(m.settings.rt.crossfeed.cutoffHz)) Hz").monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                HStack {
                    Text("Feed level").frame(width: 110, alignment: .leading)
                    ValueSlider(value: $m.settings.rt.crossfeed.feedDB, in: 1...15, step: 0.5)
                    Text(String(format: "%.1f dB", m.settings.rt.crossfeed.feedDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                Note(text: "Feeds a low-passed copy of each channel to the other ear, like loudspeakers in a room. Stereo only.")
            }
            Divider()
            Toggle("Headphone correction (AutoEQ)", isOn: $m.settings.rt.headphoneEQ.enabled)
            if let p = m.settings.rt.headphoneEQ.profile {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).fontWeight(.medium)
                        Text("\(p.source) · \(p.filters.count) filters · pre-amp \(String(format: "%+.1f", p.preampDB)) dB").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { m.settings.rt.headphoneEQ = HeadphoneEQSettings() }
                }
                ResponseGraph(profile: p).frame(height: 70)
            } else { Note(text: "No profile selected.") }
            HStack {
                TextField("Search your headphones, e.g. HD 650", text: $hp.query).textFieldStyle(.roundedBorder).onSubmit { hp.loadIndex() }
                    .onChange(of: hp.query) { _, _ in if !hp.indexLoaded { hp.loadIndex() } }
                if hp.loading { ProgressView().controlSize(.small) }
            }
            if !hp.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hp.results.prefix(8)) { e in
                        Button { hp.fetch(e) { prof in m.settings.rt.headphoneEQ = HeadphoneEQSettings(enabled: true, profile: prof); hp.query = "" } } label: {
                            HStack { Text(e.name); Spacer(); Text(e.source + (e.rig.isEmpty ? "" : " · " + e.rig)).font(.caption).foregroundStyle(.secondary) }.contentShape(Rectangle()).padding(.vertical, 4)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            if let e = hp.error { Note(text: e, color: .red) }
            Note(text: "Profiles come from the open AutoEQ database (github.com/jaakkopasanen/AutoEq) and are downloaded only when you search; they are cached on this Mac.")
        }
    }
}

struct ResponseGraph: View {
    let profile: HeadphoneProfile
    var body: some View {
        Canvas { ctx, size in
            let n = 160, rate = 48_000.0
            func y(_ db: Double) -> CGFloat { size.height * (0.5 - CGFloat(db / 24)) }
            for g in [-12.0, 0, 12] { var p = Path(); p.move(to: CGPoint(x: 0, y: y(g))); p.addLine(to: CGPoint(x: size.width, y: y(g))); ctx.stroke(p, with: .color(Brand.ink.opacity(g == 0 ? 0.25 : 0.08)), lineWidth: 0.6) }
            var line = Path()
            for i in 0..<n {
                let f = 20 * pow(1000, Double(i) / Double(n - 1))
                let db = profile.responseDB(atHz: f, sampleRate: rate, includePreamp: false) + profile.effectivePreampDB(sampleRate: rate)
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1), y: y(max(-12, min(12, db))))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            ctx.stroke(line, with: .color(.accentColor), lineWidth: 1.6)
            for (hz, t) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] { ctx.draw(Text(t).font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: size.width * CGFloat(logX(hz)), y: size.height - 6)) }
            ctx.draw(Text("+12 dB").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: 22, y: 6))
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.2)))
    }
}

struct RoomCard: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        Card(title: "Room correction", subtitle: "Convolution with an impulse response (for example exported from Room EQ Wizard)") {
            Toggle("Apply room correction", isOn: $m.settings.rt.convolution.enabled)
            HStack {
                Button { chooseIR() } label: { Label("Choose impulse response…", systemImage: "waveform.path") }
                Text(m.settings.rt.convolution.irPath.map { ($0 as NSString).lastPathComponent } ?? "none selected").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if m.settings.rt.convolution.irPath != nil { Button("Clear") { m.settings.rt.convolution.irPath = nil } }
            }
            HStack {
                Text("Trim").frame(width: 110, alignment: .leading)
                ValueSlider(value: $m.settings.rt.convolution.gainDB, in: -18...6, step: 0.5)
                Text(String(format: "%+.1f dB", m.settings.rt.convolution.gainDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            Toggle("Lower the level if the correction would boost anywhere (prevents clipping)", isOn: $m.settings.rt.convolution.normalize)
            if let s = m.status.rtStages.first(where: { $0.hasPrefix("Room correction") }) { Note(text: s) }
            Note(text: "WAV impulse responses (16/24/32-bit integer or 32/64-bit float, mono or stereo, any sample rate) are resampled to the stream. The filter runs as partitioned FFT convolution on Accelerate with one block (≈ 11 ms) of latency.")
        }
    }

    private func chooseIR() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowedContentTypes = [.wav, .audio]
        p.message = "Choose an impulse response (.wav)"
        if p.runModal() == .OK, let u = p.url { m.settings.rt.convolution.irPath = u.path; m.settings.rt.convolution.enabled = true }
    }
}

struct SystemCard: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject var sys: SystemModel

    var body: some View {
        Card(title: "System optimisation", subtitle: "Scheduling and background-activity tweaks for uninterrupted playback") {
            Toggle("Raise the priority of Aureon's decoding thread (time-constraint scheduling)", isOn: $sys.promoteEngine)
            Toggle("Allow the audio callback more of each IO cycle", isOn: $sys.useCycleUsage)
            if sys.useCycleUsage {
                HStack {
                    ValueSlider(value: $sys.cycleUsage, in: 0.2...0.95, step: 0.05)
                    Text("\(Int(sys.cycleUsage * 100)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                Note(text: "Helps with heavy processing such as long convolution. The system default is 50 %.")
            }
            Divider()
            Toggle("Quiet mode: pause Spotlight indexing, Time Machine and media analysis while playing", isOn: $sys.quietMode)
            if sys.quietMode {
                HStack {
                    Text("Priority").frame(width: 70, alignment: .leading)
                    ValueSlider(value: $sys.nice, in: -20...(-1), step: 1)
                    Text("nice \(Int(sys.nice))").monospacedDigit().frame(width: 60, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(sys.helperStatus.hasPrefix("Helper ready") || sys.helperStatus.hasPrefix("Paused") ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(sys.helperStatus).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Install helper…") { sys.register() }
                Button("Remove helper") { sys.unregister() }
                Button { sys.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
            if let e = sys.helperError { Note(text: e, color: .red) }
            Note(text: "Quiet mode uses a small privileged helper that only ever sends “pause” and “continue” to an allow-list of background daemons, and resumes them if Aureon quits, crashes or stops responding. It needs a signed build: see Docs/SYSTEM-OPTIMIZATION.md. Changes apply when playback next starts.")
        }
    }
}

struct DitherCard: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        Card(title: "Dither", subtitle: "For DACs and outputs that take 16 or 20 bits. Off by default; leave it off for 24-bit DACs") {
            Picker("Type", selection: $m.settings.rt.dither.mode) {
                ForEach(DitherMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).fixedSize()
            if m.settings.rt.dither.enabled {
                HStack { Text("Output word length"); SegmentedChoice(selection: $m.settings.rt.dither.bits, items: [16, 20, 24]) { "\($0)-bit" }.frame(maxWidth: 260) }
            }
            Note(text: "Rounding to fewer bits without dither makes distortion that follows the music and is most audible in quiet passages and fades. TPDF dither (±1 LSB) turns it into steady, signal-independent noise. High-pass TPDF and noise-shaped TPDF move that noise toward high frequencies, where hearing is least sensitive. It runs last in the chain, on the real-time thread, in integer arithmetic.")
        }
    }
}

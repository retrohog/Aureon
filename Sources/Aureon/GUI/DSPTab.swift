import SwiftUI

struct DSPTab: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var sel = Box(5)
    @StateObject private var picking = Box(false)

    var body: some View {
        VStack(spacing: 18) {
            Card(title: "DSP path", subtitle: "AVAudioEngine in manual rendering mode, pulled by the DAC callback — never connected to the hardware by macOS") {
                Toggle("Process audio through EQ and plugins", isOn: $m.settings.dsp.enabled)
                Note(text: m.settings.dsp.enabled ? "DSP is on: audio is processed in 32-bit float and is not bit-perfect." : "DSP is off: audio takes the direct path from the ring buffer to the DAC.",
                     color: m.settings.dsp.enabled ? .orange : .green)
            }
            eqCard
            pluginCard
        }
    }

    // MARK: EQ

    private func band(_ i: Int) -> Binding<EQBand> { $m.settings.dsp.eq.bands[i] }

    private var eqCard: some View {
        Card(title: "Parametric equalizer", subtitle: "10 bands · peak, shelves and cuts") {
            HStack {
                Toggle("Enabled", isOn: $m.settings.dsp.eq.enabled)
                Spacer()
                Menu("Presets") {
                    ForEach(EQPreset.all, id: \.name) { p in Button(p.name) { m.settings.dsp.eq.bands = p.apply(to: m.settings.dsp.eq.bands) } }
                }.fixedSize()
            }
            HStack(spacing: 4) {
                ForEach(m.settings.dsp.eq.bands.indices, id: \.self) { i in
                    VStack(spacing: 6) {
                        Text(String(format: "%+.1f", m.settings.dsp.eq.bands[i].gainDB)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        VerticalFader(value: band(i).gainDB, enabled: m.settings.dsp.eq.bands[i].enabled)
                        Text(freqLabel(m.settings.dsp.eq.bands[i].frequency)).font(.caption2.weight(sel.v == i ? .bold : .regular))
                            .foregroundStyle(sel.v == i ? Color.accentColor : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { sel.v = i }
                }
            }
            .disabled(!m.settings.dsp.eq.enabled)

            if m.settings.dsp.eq.bands.indices.contains(sel.v) {
                Divider()
                let b = band(sel.v)
                HStack(spacing: 14) {
                    Picker("Type", selection: b.kind) { ForEach(EQBand.Kind.allCases) { Text($0.title).tag($0) } }.frame(width: 190)
                    Toggle("Band on", isOn: b.enabled)
                }
                HStack {
                    Text("Frequency").frame(width: 80, alignment: .leading)
                    Slider(value: Binding(get: { log10(b.wrappedValue.frequency) }, set: { b.wrappedValue.frequency = (pow(10, $0) * 10).rounded() / 10 }), in: log10(20)...log10(20_000))
                    Text(b.wrappedValue.frequency >= 1000 ? String(format: "%g kHz", b.wrappedValue.frequency / 1000) : String(format: "%g Hz", b.wrappedValue.frequency)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                HStack {
                    Text("Q").frame(width: 80, alignment: .leading)
                    Slider(value: b.q, in: 0.2...10)
                    Text(String(format: "%.2f", b.wrappedValue.q)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
            }
            Divider()
            HStack {
                Text("Pre-amp").frame(width: 80, alignment: .leading)
                Slider(value: $m.settings.dsp.eq.preampDB, in: -24...12, step: 0.5).disabled(m.settings.dsp.eq.autoPreamp)
                Text(String(format: "%+.1f dB", m.settings.dsp.eq.effectivePreampDB)).monospacedDigit().frame(width: 80, alignment: .trailing)
            }
            Toggle("Automatic headroom: lower the pre-amp by the largest boost", isOn: $m.settings.dsp.eq.autoPreamp)
        }
    }

    private func freqLabel(_ f: Double) -> String { f >= 1000 ? (f.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(f / 1000))k" : String(format: "%.1fk", f / 1000)) : (f.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(f))" : String(format: "%.1f", f)) }

    // MARK: plugins

    private var pluginCard: some View {
        Card(title: "Audio Unit plugins", subtitle: "Host third-party effects such as room correction (Dirac, Sonarworks), in signal order after the EQ") {
            Button { picking.v = true } label: { Label("Add plugin…", systemImage: "plus") }
                .popover(isPresented: $picking.v, arrowEdge: .bottom) { PluginPicker(done: { picking.v = false }).environmentObject(m) }

            if m.hosted.isEmpty {
                Note(text: "No plugins loaded. \(m.availableEffects.count) effect(s) are installed on this Mac.")
            } else {
                List {
                    ForEach(m.hosted) { p in
                        HStack {
                            Image(systemName: "puzzlepiece.extension")
                            VStack(alignment: .leading) { Text(p.info.name); Text(p.info.manufacturer).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Open") { m.openPluginUI(p) }
                            Button { m.removePlugin(p.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }.onMove { m.movePlugin(from: $0, to: $1) }
                }
                .frame(height: CGFloat(min(m.hosted.count, 5)) * 44 + 8).listStyle(.plain)
                Note(text: "Drag to reorder. Plugin settings are kept for this session.")
            }
            if let e = m.pluginError { Note(text: e, color: .red) }
        }
    }
}

struct EQPreset {
    let name: String
    let gains: [Double]
    func apply(to bands: [EQBand]) -> [EQBand] {
        var b = bands
        for i in b.indices where i < gains.count { b[i].gainDB = gains[i]; b[i].kind = .peak; b[i].enabled = true }
        return b
    }
    static let all = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass boost", gains: [5, 4, 3, 1, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble boost", gains: [0, 0, 0, 0, 0, 0, 1, 3, 4, 5]),
        EQPreset(name: "Vocal presence", gains: [-2, -1, 0, 0, 1, 2, 3, 2, 0, -1]),
        EQPreset(name: "Loudness", gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
        EQPreset(name: "Warm", gains: [2, 2, 1, 0, 0, 0, -1, -2, -3, -4]),
    ]
}


/// A searchable list of the installed Audio Unit effects. Built only when opened, so a Mac with hundreds of units does not slow the page down.
struct PluginPicker: View {
    @EnvironmentObject var m: PlayerModel
    let done: () -> Void
    @StateObject private var query = Box("")

    var body: some View {
        let q = query.v.trimmingCharacters(in: .whitespaces).lowercased()
        VStack(alignment: .leading, spacing: 8) {
            SearchPill(prompt: "Search \(m.availableEffects.count) effects", text: $query.v, width: 240)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if m.availableEffects.isEmpty { Text("No Audio Unit effects found").foregroundStyle(.secondary).padding(8) }
                    ForEach(m.effectGroups, id: \.maker) { g in
                        let hits = q.isEmpty ? g.effects : g.effects.filter { ($0.name + " " + $0.manufacturer).lowercased().contains(q) }
                        if !hits.isEmpty {
                            Text(g.maker).microLabel().foregroundStyle(.tertiary).padding(.top, 6).padding(.leading, 6)
                            ForEach(hits) { info in
                                Button { m.addPlugin(info); done() } label: { Text(info.name).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle()) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }.frame(height: 320)
        }
        .padding(12).frame(width: 290)
    }
}

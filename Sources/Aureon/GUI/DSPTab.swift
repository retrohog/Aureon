import SwiftUI

struct DSPTab: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var dsp: DSPModel
    @StateObject private var sel = Box(5)
    @StateObject private var picking = Box(false)

    var body: some View {
        VStack(spacing: 16) {
            profileCard
            Card(title: "DSP path", subtitle: "AVAudioEngine in manual rendering mode, pulled by the DAC callback — never connected to the hardware by macOS") {
                Toggle("Process audio through EQ and plugins", isOn: $dsp.draft.enabled)
                Note(text: dsp.draft.enabled ? "DSP is on: audio is processed in 32-bit float and is not bit-perfect." : "DSP is off: audio takes the direct path from the ring buffer to the DAC. Turning on the equalizer or adding a plug-in switches this on for you.",
                     color: dsp.draft.enabled ? .orange : .green)
            }
            eqCard
            pluginCard
        }
    }

    // MARK: profiles

    private var profileCard: some View {
        Card(title: "Profile", subtitle: "Settings are kept only when you save them into a profile") {
            HStack(spacing: 12) {
                Menu {
                    Button { dsp.select(nil) } label: { Label("Clean start (nothing applied)", systemImage: dsp.activeID == nil ? "checkmark" : "") }
                    if !dsp.profiles.isEmpty { Divider() }
                    ForEach(dsp.profiles) { p in Button { dsp.select(p.id) } label: { Label(p.name, systemImage: dsp.activeID == p.id ? "checkmark" : "") } }
                } label: {
                    Label(dsp.active?.name ?? "No profile", systemImage: "slider.horizontal.below.square.filled.and.square")
                }.fixedSize()
                if dsp.dirty { Circle().fill(Brand.caution).frame(width: 8, height: 8).help("Unsaved changes") }
                Spacer()
                Button("Revert") { dsp.revert() }.disabled(!dsp.dirty)
                Button("Save as…") {
                    if let n = promptForText(title: "Save as a new profile", placeholder: "Profile name", confirm: "Save") { dsp.saveAs(n) }
                }
                Button { m.saveDSP() } label: { Text(dsp.active == nil ? "Save…" : "Save") }.buttonStyle(.solid).tint(Brand.accent).disabled(!dsp.dirty)
                if let a = dsp.active {
                    Menu { Button("Rename…") { if let n = promptForText(title: "Rename profile", initial: a.name, confirm: "Rename") { dsp.rename(a.id, to: n) } }
                           Button("Delete “\(a.name)”", role: .destructive) { dsp.delete(a.id) } } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            Note(text: dsp.dirty ? (dsp.acknowledged ? "Unsaved changes are kept for this session only." : "You have unsaved changes. They are lost when you quit Aureon unless you save them.")
                                  : (dsp.active == nil ? "Nothing is saved yet. Make a setting, then Save to keep it." : "Everything is saved in “\(dsp.active!.name)”."),
                 color: dsp.dirty ? .orange : .green)
        }
    }

    // MARK: EQ

    private func band(_ i: Int) -> Binding<EQBand> { $dsp.draft.eq.bands[i] }

    private var eqEnabled: Binding<Bool> {
        Binding(get: { dsp.draft.eq.enabled }, set: { on in dsp.draft.eq.enabled = on; if on { dsp.draft.enabled = true } })
    }

    private var eqCard: some View {
        Card(title: "Parametric equalizer", subtitle: "10 bands · peak, shelves and cuts") {
            HStack {
                Toggle("Enabled", isOn: eqEnabled)
                Spacer()
                Menu("Presets") {
                    ForEach(EQPreset.all, id: \.name) { p in Button(p.name) { dsp.draft.eq.bands = p.apply(to: dsp.draft.eq.bands); if dsp.draft.eq.enabled { dsp.draft.enabled = true } } }
                }.fixedSize()
            }
            HStack(spacing: 4) {
                ForEach(dsp.draft.eq.bands.indices, id: \.self) { i in
                    let b = dsp.draft.eq.bands[i]
                    let isCut = b.kind == .lowCut || b.kind == .highCut
                    VStack(spacing: 8) {
                        Text(isCut ? "cut" : String(format: "%+.1f", b.gainDB)).font(Typo.caption2.monospacedDigit()).foregroundStyle(Brand.inkSecondary)
                        VerticalFader(value: band(i).gainDB, enabled: b.enabled && !isCut)
                        Text(freqLabel(b.frequency)).font(Typo.caption2.weight(sel.v == i ? .bold : .regular))
                            .foregroundStyle(sel.v == i ? Brand.accent : .secondary)
                        Circle().fill(b.enabled ? Brand.accent : Brand.ink.opacity(0.2)).frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Metrics.radius(8), style: .continuous).fill(Brand.ink.opacity(sel.v == i ? 0.08 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture { sel.v = i }
                }
            }
            .opacity(dsp.draft.eq.enabled ? 1 : 0.55)

            if dsp.draft.eq.bands.indices.contains(sel.v) {
                Divider()
                let b = band(sel.v)
                let kind = b.wrappedValue.kind
                HStack(spacing: 16) {
                    Text("Band \(sel.v + 1)").font(Typo.sans(12, .semibold))
                    Picker("Type", selection: b.kind) { ForEach(EQBand.Kind.allCases) { Text($0.title).tag($0) } }.frame(width: 190)
                    Toggle("Band on", isOn: b.enabled)
                    Spacer()
                    Button("Reset band") { b.wrappedValue.gainDB = 0; b.wrappedValue.q = 1; b.wrappedValue.kind = .peak; b.wrappedValue.frequency = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000][sel.v] }
                }
                HStack {
                    Text("Frequency").frame(width: 80, alignment: .leading)
                    ValueSlider(value: Binding(get: { log10(b.wrappedValue.frequency) }, set: { b.wrappedValue.frequency = (pow(10, $0) * 10).rounded() / 10 }), in: log10(20)...log10(20_000))
                    Text(b.wrappedValue.frequency >= 1000 ? String(format: "%g kHz", b.wrappedValue.frequency / 1000) : String(format: "%g Hz", b.wrappedValue.frequency)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                HStack {
                    Text("Gain").frame(width: 80, alignment: .leading)
                    ValueSlider(value: b.gainDB, in: -12...12, step: 0.5)
                    Text(String(format: "%+.1f dB", b.wrappedValue.gainDB)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }.disabled(kind == .lowCut || kind == .highCut).opacity(kind == .lowCut || kind == .highCut ? 0.4 : 1)
                HStack {
                    Text("Q").frame(width: 80, alignment: .leading)
                    ValueSlider(value: b.q, in: 0.2...10)
                    Text(String(format: "%.2f", b.wrappedValue.q)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }.disabled(kind != .peak).opacity(kind != .peak ? 0.4 : 1)
                if kind != .peak { Note(text: kind == .lowCut || kind == .highCut ? "A cut filter only needs a frequency." : "A shelf only needs a frequency and a gain; Q applies to peak bands.") }
            }
            Divider()
            HStack {
                Text("Pre-amp").frame(width: 80, alignment: .leading)
                ValueSlider(value: $dsp.draft.eq.preampDB, in: -24...12, step: 0.5).disabled(dsp.draft.eq.autoPreamp)
                Text(String(format: "%+.1f dB", dsp.draft.eq.effectivePreampDB)).monospacedDigit().frame(width: 80, alignment: .trailing)
            }
            Toggle("Automatic headroom: lower the pre-amp by the largest boost", isOn: $dsp.draft.eq.autoPreamp)
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
                            VStack(alignment: .leading) { Text(p.info.name); Text(p.info.manufacturer).font(Typo.caption).foregroundStyle(Brand.inkSecondary) }
                            Spacer()
                            Button("Open") { m.openPluginUI(p) }
                            Button { m.removePlugin(p.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }.onMove { m.movePlugin(from: $0, to: $1) }
                }
                .frame(height: CGFloat(min(m.hosted.count, 5)) * 44 + 8).listStyle(.plain)
                Note(text: "Drag to reorder. A plug-in's own window can be resized and scrolled. Its settings are saved into the profile with the rest.")
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
            SearchField(prompt: "Search \(m.availableEffects.count) effects", text: $query.v, width: 240)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if m.availableEffects.isEmpty { Text("No Audio Unit effects found").foregroundStyle(Brand.inkSecondary).padding(8) }
                    ForEach(m.effectGroups, id: \.maker) { g in
                        let hits = q.isEmpty ? g.effects : g.effects.filter { ($0.name + " " + $0.manufacturer).lowercased().contains(q) }
                        if !hits.isEmpty {
                            Text(g.maker).microLabel().foregroundStyle(Brand.inkTertiary).padding(.top, 8).padding(.leading, 8)
                            ForEach(hits) { info in
                                Button { m.addPlugin(info); done() } label: { Text(info.name).font(Typo.sans(12.5)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle()) }
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

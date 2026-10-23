import SwiftUI

struct DiagnosticsTab: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(spacing: 16) {
            SystemCard(sys: m.system)
            Card(title: "Freeze recorder", subtitle: "If the interface ever stops responding for about half a second, Aureon saves what it was doing") {
                let n = StallMonitor.shared.files.count
                Note(text: n == 0 ? "Nothing recorded so far." : "\(n) freeze\(n == 1 ? "" : "s") recorded. Send the newest file if one happens often.")
                Button("Show the recordings") { try? FileManager.default.createDirectory(at: StallMonitor.folder, withIntermediateDirectories: true); NSWorkspace.shared.open(StallMonitor.folder) }
            }
            Card(title: "Hardware path diagnostics", subtitle: "Verify exclusive access, integer-format negotiation and callback health on \(m.selectedDevice?.name ?? "the output device")") {
                Note(text: "Always runs: device identification, formats and a silent timing test. The checks below change device state briefly and restore it. Playback is stopped first.")
                Toggle("Exclusive access: acquire, refuse a competing process, release", isOn: $m.diagHog)
                Toggle("Integer mode: negotiate every integer physical format (also takes exclusive access)", isOn: $m.diagInteger)
                Toggle("Sample rates: switch through 44.1 – 384 kHz", isOn: $m.diagRates)
                Stepper("Timing test: \(String(format: "%.0f", m.diagSeconds)) s of silence", value: $m.diagSeconds, in: 0...30, step: 1)
                HStack {
                    Button { m.runDiagnostics() } label: { Label(m.diagRunning ? "Running…" : "Run diagnostics", systemImage: "stethoscope") }
                        .disabled(m.diagRunning).buttonStyle(.solid)
                    Button { m.exportDiagnostics() } label: { Label("Export JSON", systemImage: "square.and.arrow.up") }
                        .disabled(m.diagSteps.isEmpty || m.diagRunning)
                    if m.diagRunning { ProgressView().controlSize(.small) }
                }
            }
            if !m.diagSteps.isEmpty {
                Card(title: "Results") {
                    ForEach(m.diagSteps) { s in
                        HStack(alignment: .top, spacing: 8) {
                            Text(s.symbol).foregroundStyle(color(s.status)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(Typo.callout.weight(.medium))
                                Text(s.detail).font(Typo.caption).foregroundStyle(Brand.inkSecondary).textSelection(.enabled)
                            }
                            Spacer()
                        }
                    }
                    let f = m.diagSteps.filter { $0.status == .fail }.count, w = m.diagSteps.filter { $0.status == .warn }.count
                    if !m.diagRunning { Divider(); Text("\(f) failure(s), \(w) warning(s)").font(Typo.callout.weight(.semibold)).foregroundStyle(f > 0 ? .red : (w > 0 ? .orange : .green)) }
                }
            }
        }
    }

    private func color(_ s: DiagStep.Status) -> Color {
        switch s { case .pass: .green; case .warn: .orange; case .fail: .red; case .info: .secondary; case .skip: .gray }
    }
}

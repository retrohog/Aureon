import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConvertPage: View {
    @EnvironmentObject var cv: ConvertModel
    @StateObject private var hover = Box(false)

    var body: some View {
        PageScaffold(title: "Convert", subtitle: cv.items.isEmpty ? nil : "\(cv.items.count) file\(cv.items.count == 1 ? "" : "s")", trailing: {
            PillButton(title: "Add files…", symbol: "plus") { pick() }
            if !cv.items.isEmpty && !cv.running { PillButton(title: "Clear", symbol: "xmark") { cv.clear() } }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                if cv.items.isEmpty { drop } else { list }
                settings
                actions
            }
        }
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { hover.v }, set: { hover.v = $0 })) { providers in
            for p in providers { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in cv.add([u]) } } } }
            return true
        }
    }

    private var drop: some View {
        EmptyExplainer(icon: "arrow.triangle.2.circlepath", title: "Drop music here",
                       text: "Drop files or whole folders to make copies in AAC, Apple Lossless or FLAC. Tracks can be levelled to a common loudness (EBU R128) without clipping; tags and cover art come along. Several files are converted at the same time.")
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover.v ? Color.accentColor : .clear, lineWidth: 2))
    }

    private var list: some View {
        Card(title: "Files", subtitle: nil) {
            VStack(spacing: 2) {
                ForEach(cv.items) { it in
                    HStack(spacing: 10) {
                        icon(it.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.job.source.deletingPathExtension().lastPathComponent).lineLimit(1)
                            Text(it.job.source.deletingLastPathComponent().path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        if it.state == .working { ProgressView(value: it.progress).frame(width: 120) }
                        else if let r = it.result, r.ok { Text(detail(r)).font(.caption).foregroundStyle(.secondary) }
                        else if case .failed(let m) = it.state { Text("Failed").font(.caption).foregroundStyle(.red).help(m) }
                        if !cv.running { Button { cv.remove(it.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 3)
                    .help(it.job.destination.path)
                }
            }
        }
    }

    private func detail(_ r: TranscodeResult) -> String {
        var s = formatBytes(r.outputBytes)
        if let m = r.measured, let i = m.integratedLUFS { s += String(format: " · %.1f → %.1f LUFS", i, i + r.appliedGainDB) + (r.gainLimitedByPeak ? " (peak-limited)" : "") }
        return s
    }

    @ViewBuilder private func icon(_ s: ConvertModel.Item.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .working: Image(systemName: "circle.dotted").foregroundStyle(Color.accentColor)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        Card(title: "Settings", subtitle: nil) {
            SegmentedChoice(selection: $cv.format, items: Array(TranscodeFormat.allCases)) { $0.title }.disabled(cv.running)
            if cv.format == .aac {
                Picker("AAC bit rate", selection: $cv.bitrate) { ForEach([128_000, 192_000, 256_000, 320_000], id: \.self) { Text("\($0 / 1000) kbps").tag($0) } }.disabled(cv.running)
                Toggle("Never go above 48 kHz (always on for AAC; this also applies to lossless copies)", isOn: .constant(true)).disabled(true).font(.caption)
            } else {
                Toggle("Limit lossless copies to 48 kHz (for players that cannot do more)", isOn: $cv.capRate).disabled(cv.running)
            }
            Picker("Loudness", selection: $cv.levelling) { ForEach(ConvertModel.Levelling.allCases) { Text($0.title).tag($0) } }.disabled(cv.running)
            if cv.levelling != .off {
                if cv.levelling == .custom { HStack { Text("Target"); Stepper(value: $cv.customLUFS, in: -35 ... -6, step: 0.5) { Text(String(format: "%.1f LUFS", cv.customLUFS)).monospacedDigit() } } }
                HStack { Text("True-peak ceiling"); Stepper(value: $cv.ceiling, in: -6 ... 0, step: 0.5) { Text(String(format: "%.1f dBTP", cv.ceiling)).monospacedDigit() } }
                Toggle("Raise quiet tracks to the target", isOn: $cv.allowBoost)
                Note(text: "Every file is measured first (ITU-R BS.1770-4, gated, 4× oversampled peaks). The gain is a plain volume change: it is reduced if it would push a peak past the ceiling, so nothing is clipped and no limiter is used.")
            }
            Toggle("Keep the folder structure of what I dropped", isOn: $cv.keepFolders).disabled(cv.running)
            HStack {
                Text("Save in"); Text(cv.destination.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(); Button("Choose…") { chooseFolder() }.disabled(cv.running)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if cv.running { PillButton(title: "Stop", symbol: "stop.fill") { cv.cancel() }; ProgressView().controlSize(.small) }
                else { PillButton(title: "Convert \(cv.items.count) file\(cv.items.count == 1 ? "" : "s")", symbol: "arrow.triangle.2.circlepath", filled: true) { cv.start() }.disabled(cv.items.isEmpty) }
                if !cv.running, cv.items.contains(where: { $0.state == .done }) { PillButton(title: "Show in Finder", symbol: "folder") { cv.reveal() } }
            }
            if let s = cv.summary { Note(text: s, color: s.contains("failed") ? .orange : .green) }
        }
    }

    private func pick() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true; p.message = "Choose music files or folders"
        if p.runModal() == .OK { cv.add(p.urls) }
    }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.message = "Where should the copies be saved?"
        if p.runModal() == .OK, let u = p.url { cv.destination = u }
    }
}

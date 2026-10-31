import SwiftUI
import AppKit

// The detail keys of Now Playing: a ribbon across the corner of the cover that names the quality class, a heavy format key under the title ("FLAC 24/88")
// and chunky buttons for Signal path, Processing and Song info. Each one opens a panel in place with what it means, built from the real stream and file.
// Only one is open at a time; Esc, a click outside or the same key again closes it.

enum NPDetailKind: String, CaseIterable, Identifiable {
    case quality, format, signal, processing, info
    var id: String { rawValue }
    var title: String { switch self { case .quality: "What the label means"; case .format: "File"; case .signal: "Signal path"; case .processing: "Processing"; case .info: "Song info" } }
    var symbol: String { switch self { case .quality: "seal"; case .format: "doc"; case .signal: "arrow.triangle.branch"; case .processing: "slider.horizontal.3"; case .info: "info.circle" } }
}

/// The corner ribbon: shown for what the file really is, never more.
struct NPRibbon: Equatable {
    enum Tint: Equatable { case gold, silver, grey, teal }
    var text: String
    var tint: Tint
    static func make(_ m: QualityStripModel) -> NPRibbon {
        switch m.tone {
        case .hiRes: NPRibbon(text: "HI-RES", tint: .gold)
        case .lossless: NPRibbon(text: "LOSSLESS", tint: .silver)
        case .lossy: NPRibbon(text: "LOSSY", tint: .grey)
        case .dsd: NPRibbon(text: "DSD", tint: .gold)
        case .live: NPRibbon(text: "LIVE", tint: .teal)
        }
    }
}

/// The text of every panel, as plain rows made from real values.
enum NPDetailContent {
    static func format(_ input: FormatTagInput, track: TrackDTO?) -> [NPCredit] {
        let s = input.source
        var rows = [NPCredit(label: "Format", value: s.codec)]
        if s.sourceBits > 1 { rows.append(NPCredit(label: "Bit depth", value: "\(s.sourceBits)-bit")) }
        rows.append(NPCredit(label: "Sample rate", value: s.sourceBits == 1 ? "\(NPSignal.rate(s.sourceRate ?? s.sampleRate)) kHz (DSD)" : "\(NPSignal.rate(s.sourceRate ?? s.sampleRate)) kHz"))
        rows.append(NPCredit(label: "Channels", value: s.channels == 1 ? "Mono" : (s.channels == 2 ? "Stereo" : "\(s.channels) channels")))
        if let b = input.bitrate { rows.append(NPCredit(label: "Bitrate", value: "\(b) kbps")) }
        else if let t = track, let size = t.fileSize, t.duration > 1 { rows.append(NPCredit(label: "Average bitrate", value: "\(Int(Double(size) * 8 / t.duration / 1000)) kbps")) }
        if let size = track?.fileSize { rows.append(NPCredit(label: "File size", value: NPExtras.size(size))) }
        if let g = input.replayGainDB { rows.append(NPCredit(label: "ReplayGain", value: String(format: "%+.1f dB applied", g))) }
        else { rows.append(NPCredit(label: "ReplayGain", value: "None applied")) }
        if let p = track?.path { rows.append(NPCredit(label: "Path", value: p)) }
        return rows
    }

    static func quality(_ m: QualityStripModel, _ input: FormatTagInput) -> String {
        let s = input.source
        let spec = "\(s.sourceBits)-bit / \(NPSignal.rate(s.sourceRate ?? s.sampleRate)) kHz"
        switch m.tone {
        case .hiRes: return "\(spec) is above CD quality (16-bit / 44.1 kHz). The file is lossless, so nothing was discarded when it was made."
        case .lossless: return "Lossless: every sample of the original is kept (\(spec)). At CD quality or below, so it is not labelled Hi-Res."
        case .lossy: return "Lossy: some of the original detail was discarded when this file was made. It is never labelled Hi-Res, whatever its sample rate."
        case .dsd: return "DSD: one-bit audio at a very high rate. It is passed to the DAC as it is, or converted without touching the stream when needed."
        case .live: return "A live stream: its quality is whatever the station sends."
        }
    }

    static func signal(_ input: FormatTagInput) -> [NPSignalStep] {
        var steps = NPSignal.steps(source: input.source, output: input.output, stages: input.stages, bitPerfect: input.bitPerfect, exclusive: input.exclusive, device: input.deviceName)
        steps.append(NPSignalStep(title: "Result", detail: input.bitPerfect ? "Bit-perfect: the samples reach the device unchanged" : "Processed: at least one stage changes the samples"))
        return steps
    }

    static func info(item: QueueItem?, track: TrackDTO?, credits: [NPCredit]) -> [NPCredit] {
        var rows: [NPCredit] = []
        if let a = item?.album, !a.isEmpty { rows.append(NPCredit(label: "Album", value: a)) }
        if let y = item?.year ?? track?.year { rows.append(NPCredit(label: "Year", value: String(y))) }
        if let n = item?.trackNumber ?? track?.trackNumber { rows.append(NPCredit(label: "Track", value: (item?.trackTotal).map { $0 > 0 ? "\(n) of \($0)" : "\(n)" } ?? "\(n)")) }
        rows += credits.prefix(8)
        return rows
    }
}

/// Which panel is open (one at a time). The card itself is drawn by the window's popover layer, above every other view.
@MainActor
final class NPDetailModel: ObservableObject {
    static let shared = NPDetailModel()
    @Published private(set) var open: NPDetailKind?
    func toggle(_ k: NPDetailKind) { set(open == k ? nil : k) }
    func set(_ k: NPDetailKind?) { open = k }
    /// Closes `k` only if it is the one showing (a popover that was replaced must not close its successor).
    func close(_ k: NPDetailKind) { if open == k { open = nil } }
}

// MARK: - Views

/// The quality chip in the cover's top-left corner: gold for Hi-Res and DSD, silver for lossless, grey for lossy. It opens the explanation.
struct NPCoverChip: View {
    let ribbon: NPRibbon
    var side: CGFloat
    @ObservedObject private var d = NPDetailModel.shared
    @EnvironmentObject var m: PlayerModel

    static func fill(_ t: NPRibbon.Tint, theme: Theme) -> RGB {
        switch t {
        case .gold: theme.goldRGB
        case .silver: theme.isLight ? RGB(0.42, 0.44, 0.48) : RGB(0.84, 0.86, 0.9)
        case .grey: theme.isLight ? RGB(0.38, 0.38, 0.4) : RGB(0.62, 0.62, 0.65)
        case .teal: QualityPalette.colors(light: theme.isLight).teal
        }
    }

    var body: some View {
        let theme = m.theme
        let fill = Self.fill(ribbon.tint, theme: theme)
        let ink = WCAG.onColor(fill)
        let size = max(10, min(13, side * 0.034))
        Button { d.toggle(.quality) } label: {
            Text(ribbon.text).font(Typo.sans(size, .heavy)).tracking(0.8).foregroundStyle(ink.color)
                .padding(.horizontal, 9).frame(height: max(22, size * 2))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill.color))
        }
        .buttonStyle(.plain).padding(10)
        .accessibilityLabel("\(ribbon.text.capitalized) quality").accessibilityHint("Explains the label")
    }
}

/// Under the artist: the format as a gold boxed stamp, then a quiet line of the other detail keys. The panels hang under the row without moving anything.
struct NPDetailKeys: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo
    @ObservedObject private var d = NPDetailModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var alignment: Alignment = .leading

    var body: some View {
        if let input = m.formatTagInput(bitrate: nil, track: info.track) {
            let model = QualityStripModel.make(input)
            let s = input.source
            let key = model.tone == .dsd ? "DSD" : "\(s.codec.uppercased()) \(s.sourceBits)/\(QualityMark.rateShort(s.sourceRate ?? s.sampleRate))"
            let gold = m.theme.goldRGB.color
            let items: [(NPDetailKind, String)] = [(.signal, "Signal path ›"), (.processing, "Processing"), (.info, "Info")]
            let line = HStack(spacing: 0) {
                if input.exclusive { HStack(spacing: 4) { Image(systemName: "lock.fill").font(Typo.sans(10, .semibold)); Text("Exclusive") }.foregroundStyle(Brand.inkSecondary); dot }
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    QuietKey(title: it.1, on: d.open == it.0, gold: gold) { d.toggle(it.0) }
                    if i < items.count - 1 { dot }
                }
            }
            let stamp = Button { d.toggle(.format) } label: {
                Text(model.tone == .live ? s.codec.uppercased() : key).font(Typo.mono(14, .semibold)).foregroundStyle(gold)
                    .padding(.horizontal, 10).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(gold, lineWidth: 1.5))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(gold.opacity(d.open == .format ? 0.16 : 0)))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("File details").accessibilityValue(key)
            let row = ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { stamp; line }.fixedSize()
                VStack(alignment: alignment == .center ? .center : .leading, spacing: 6) { stamp; line }.fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .animation(reduceMotion ? nil : Motion.touch, value: d.open)
            .onKeyMonitor(.escape, active: d.open != nil) { d.set(nil); return .handled }
            .accessibilityElement(children: .contain)
            // each panel is a card in the window's popover layer: opaque, above the seek bar and controls, placed under the row or over it, clamped into the window
            row
                .windowPopover(isPresented: shown(.quality), edge: .bottom) { card(.quality, input, model) }
                .windowPopover(isPresented: shown(.format), edge: .bottom) { card(.format, input, model) }
                .windowPopover(isPresented: shown(.signal), edge: .bottom) { card(.signal, input, model) }
                .windowPopover(isPresented: shown(.processing), edge: .bottom) { card(.processing, input, model) }
                .windowPopover(isPresented: shown(.info), edge: .bottom) { card(.info, input, model) }
        }
    }

    private func shown(_ k: NPDetailKind) -> Binding<Bool> {
        Binding(get: { d.open == k }, set: { if !$0 { d.close(k) } })
    }
    private func card(_ k: NPDetailKind, _ input: FormatTagInput, _ model: QualityStripModel) -> some View {
        NPDetailPanel(kind: k, input: input, model: model).environmentObject(m).environmentObject(info)
    }

    private var dot: some View { Text("·").foregroundStyle(Brand.inkTertiary).padding(.horizontal, 7) }
}

/// One word of the quiet line: muted, the foreground colour with a thin gold underline under the pointer or the keyboard focus.
struct QuietKey: View {
    let title: String
    let on: Bool
    let gold: Color
    let action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.sans(13.5, on ? .semibold : .regular)).foregroundStyle(hover || on || focused ? Brand.ink : Brand.inkSecondary)
                .padding(.vertical, 6).overlay(alignment: .bottom) { Rectangle().fill(gold).frame(height: 1).opacity(hover || on || focused ? 1 : 0) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focused).onHover { hover = $0 }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(gold, lineWidth: 1.5).padding(-3).opacity(focused ? 1 : 0))
        .accessibilityLabel(title.replacingOccurrences(of: " ›", with: ""))
    }
}

struct NPDetailPanel: View {
    let kind: NPDetailKind
    let input: FormatTagInput
    let model: QualityStripModel
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo
    @ObservedObject private var d = NPDetailModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind.title).font(Typo.sans(14, .semibold))
                Spacer()
                Button { d.set(nil) } label: { Image(systemName: "xmark").font(Typo.sans(11, .bold)) }.buttonStyle(.plain).frame(width: 28, height: 28).accessibilityLabel("Close")
            }
            content
        }
        .foregroundStyle(Brand.ink)
        .padding(16).frame(width: 400, alignment: .leading)
        .background(ZStack { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.canvas); RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.panel2) }.shadow(color: .black.opacity(0.4), radius: 20, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.rule, lineWidth: Metrics.hairline))
        .accessibilityElement(children: .contain).accessibilityLabel(kind.title)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .quality: Text(NPDetailContent.quality(model, input)).font(Typo.sans(13.5)).fixedSize(horizontal: false, vertical: true)
        case .format:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(NPDetailContent.format(input, track: info.track)) { r in row(r.label, r.value) }
                if let p = info.track?.path {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }.buttonStyle(SlskSoft()).padding(.top, 4)
                }
            }
        case .signal:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(NPDetailContent.signal(input).enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(i == NPDetailContent.signal(input).count - 1 ? (input.bitPerfect ? Brand.accent : Brand.caution) : Brand.inkSecondary).frame(width: 8, height: 8).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) { Text(s.title).font(Typo.sans(12, .medium)).foregroundStyle(Brand.inkSecondary); Text(s.detail).font(Typo.sans(13.5)).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        case .processing: ProcessingControls()
        case .info:
            VStack(alignment: .leading, spacing: 6) {
                let rows = NPDetailContent.info(item: m.focusItem, track: info.track, credits: info.credits)
                if rows.isEmpty { Text("Nothing more is tagged on this song.").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary) }
                ForEach(rows) { r in row(r.label, r.value) }
            }
        }
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack(alignment: .top) { Text(a).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).frame(width: 110, alignment: .leading); Text(b).font(Typo.sans(13.5)).lineLimit(3).truncationMode(.middle).textSelection(.enabled) }
    }
}

/// Gain and upsampling, live: the same settings as the Sound page.
struct ProcessingControls: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Volume leveling").font(Typo.sans(12, .medium)).foregroundStyle(Brand.inkSecondary)
                SegmentedChoice(selection: $m.settings.replayGain.mode, items: Array(ReplayGainMode.allCases)) { $0.title }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Upsampling").font(Typo.sans(12, .medium)).foregroundStyle(Brand.inkSecondary)
                Picker("", selection: $m.settings.upsampling.mode) { ForEach(UpsamplingMode.allCases) { Text($0.title).tag($0) } }.labelsHidden()
            }
            Text(m.status.bitPerfect ? "Both are off or inactive: the samples are unchanged." : "These change the samples on their way to the device. Turn them off for a bit-perfect path.").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

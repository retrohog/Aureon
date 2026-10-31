import SwiftUI

// The quality strip: what the song is and what happens to it on the way to the device, in one tidy readout under the title of every Now Playing layout (and as
// a small pill in the player bar). A gold badge on the left names the class (Hi-Res Lossless, Lossless, Lossy, DSD, Live) over the file format; then cells with a
// small tracked label over a figure: depth, rate, gain, upsampled, output; then Exclusive (with a lock) and the chain (Processed or Bit-perfect). Every tag the
// older tag row had is still here, as a cell, the badge or its subtitle. A cell that does not apply is not shown. All of it is a pure function of the stream.

struct QualityStripModel: Equatable {
    enum Tone: Equatable { case hiRes, lossless, lossy, dsd, live }
    enum Tint: Equatable { case ink, teal, gold, quiet }
    struct Cell: Identifiable, Equatable {
        var id: String
        var label: String
        var value: String
        var tint: Tint = .ink
        /// What it means, in plain language (the tooltip).
        var help: String
    }

    var tone: Tone
    var title: String
    var subtitle: String
    var cells: [Cell]
    /// The gold lock cell: Aureon has the device to itself.
    var exclusive: Cell?
    /// The chain: Processed, or Bit-perfect when nothing touches the samples.
    var chain: Cell
    /// The compact form for the player bar: "Hi-Res · 24/88.2 → 96".
    var pill: String
    /// Every tag id of the older row that this model carries (so none is lost).
    var carried: Set<String>

    var spoken: String {
        ([title + ", " + subtitle] + cells.map { "\($0.label.lowercased()) \($0.value)" } + (exclusive.map { [$0.help] } ?? []) + ["\(chain.label.lowercased()) \(chain.value)"]).joined(separator: ", ")
    }

    static func make(_ input: FormatTagInput) -> QualityStripModel {
        let tags = FormatTagBuilder.tags(input)
        func tag(_ id: String) -> FormatTag? { tags.first { $0.id == id } }
        var cells: [Cell] = [], carried = Set<String>()
        func take(_ id: String) -> FormatTag? { if let t = tag(id) { carried.insert(id); return t }; return nil }
        func strip(_ t: String, _ prefix: String) -> String { t.hasPrefix(prefix) ? String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : t }

        // the badge: the class, over the format and the channels
        var tone = Tone.lossless, title = "Lossless"
        if let c = take("class") {
            switch c.tier { case .gold: tone = .hiRes; title = "Hi-Res Lossless"; case .lossy: tone = .lossy; title = "Lossy"; default: tone = .lossless; title = "Lossless" }
        }
        if take("live") != nil { tone = .live; title = "Live" }
        if tag("dsd") != nil { tone = .dsd; title = "DSD" }
        var sub: [String] = []
        if let codec = take("codec") { sub.append(codec.text) }
        if let mqa = take("mqa") { sub.append(mqa.text) }
        if let ch = take("channels") { sub.append(ch.text.count <= 3 ? ch.text : ch.text.prefix(1) + ch.text.dropFirst().lowercased()) }

        // the cells
        if let d = take("dsd") { cells.append(Cell(id: "rate", label: "RATE", value: d.text, help: d.help)) }
        if let p = take("dop") { cells.append(Cell(id: "dop", label: "MODE", value: "DoP", help: p.help)) }
        if let b = take("bits") { cells.append(Cell(id: "depth", label: "DEPTH", value: b.text.lowercased(), help: b.help)) }
        if let r = take("rate") { cells.append(Cell(id: "rate", label: "RATE", value: r.text, help: r.help)) }
        if let k = take("bitrate") { cells.append(Cell(id: "bitrate", label: "BITRATE", value: k.text, help: k.help)) }
        if let g = take("gain") { cells.append(Cell(id: "gain", label: "GAIN", value: strip(g.text, "RG"), tint: .teal, help: g.help + ": ReplayGain brings every song to the same loudness")) }
        if let u = take("upsample") {
            let up = u.text.hasPrefix("UPSAMPLED")
            cells.append(Cell(id: "upsample", label: up ? "UPSAMPLED" : "RESAMPLED", value: strip(strip(u.text, "UPSAMPLED"), "RESAMPLED"), tint: .teal, help: u.help))
        }
        if let d = take("dsp") { cells.append(Cell(id: "dsp", label: "DSP", value: "On", tint: .teal, help: d.help)) }
        if let m = take("mix") { cells.append(Cell(id: "mix", label: "CROSSFADE", value: "On", tint: .teal, help: m.help)) }
        if let o = take("outrate") { cells.append(Cell(id: "output", label: "OUTPUT", value: strip(o.text, "OUT"), help: o.help)) }

        // the mode and the chain
        var exclusive: Cell?
        if let mode = take("mode") {
            if mode.text == "EXCLUSIVE" { exclusive = Cell(id: "exclusive", label: "MODE", value: "Exclusive", tint: .gold, help: "Exclusive mode: bit-perfect output; other apps cannot use this device") }
            else { cells.append(Cell(id: "mode", label: "MODE", value: "Shared", tint: .quiet, help: mode.help)) }
        }
        let bp = take("bitperfect")
        let chain = Cell(id: "chain", label: "CHAIN", value: bp?.text == "BIT-PERFECT" ? "Bit-perfect" : "Processed", tint: bp?.text == "BIT-PERFECT" ? .teal : .quiet, help: bp?.help ?? "")

        // the pill
        let s = input.source
        let srcRate = s.sourceRate ?? s.sampleRate
        let short = { (t: Tone) -> String in switch t { case .hiRes: "Hi-Res"; case .lossless: "Lossless"; case .lossy: "Lossy"; case .dsd: "DSD"; case .live: "Live" } }(tone)
        var spec = ""
        switch tone {
        case .hiRes, .lossless: spec = "\(s.sourceBits)/\(QualityMark.rateShort(srcRate))"
        case .lossy, .live: spec = (sub.first ?? "")
        case .dsd: spec = tag("dsd")?.text ?? ""
        }
        if let o = input.output, tone != .dsd, abs(o.sampleRate - srcRate) > 1 { spec += " → \(QualityMark.rateShort(o.sampleRate))" }
        let pill = spec.isEmpty ? short : "\(short) · \(spec)"

        return QualityStripModel(tone: tone, title: title, subtitle: sub.joined(separator: " · "), cells: cells, exclusive: exclusive, chain: chain, pill: pill, carried: carried)
    }
}

/// The colours of the strip on a dark and on a light theme. The text colours are held to 4.5:1 on the strip's own backing over every theme's canvas.
enum QualityPalette {
    struct Set {
        var badgeFill: [RGB], badgeInk: RGB, label: RGB, ink: RGB, teal: RGB, gold: RGB, quiet: RGB
        /// The backing laid over the canvas: its colour and opacity.
        var backing: RGB, backingAlpha: Double
    }
    static let dark = Set(badgeFill: [RGB(0.965, 0.78, 0.396), RGB(0.851, 0.588, 0.169)], badgeInk: RGB(0.114, 0.078, 0.02), label: RGB(0.69, 0.66, 0.60), ink: RGB(0.953, 0.937, 0.902),
                          teal: RGB(0.498, 0.878, 0.776), gold: RGB(0.949, 0.722, 0.294), quiet: RGB(0.85, 0.82, 0.77), backing: RGB(0, 0, 0), backingAlpha: 0.28)
    static let light = Set(badgeFill: [RGB(0.165, 0.141, 0.094), RGB(0.165, 0.141, 0.094)], badgeInk: RGB(0.965, 0.78, 0.396), label: RGB(0.33, 0.30, 0.24), ink: RGB(0.165, 0.141, 0.094),
                           teal: RGB(0.114, 0.42, 0.341), gold: RGB(0.478, 0.322, 0.039), quiet: RGB(0.25, 0.22, 0.17), backing: RGB(1, 1, 1), backingAlpha: 0.55)
    static func colors(light isLight: Bool) -> Set { isLight ? light : dark }
}

// MARK: - The views

/// The strip under the title. Wide: one row. Narrower: the badge row, then the cells in a row, then the Exclusive / chain line.
struct QualityStrip: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @ObservedObject private var lossy = LossyBitrates.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var alignment: Alignment = .leading

    var body: some View {
        if let input = m.formatTagInput(bitrate: bitrate(m.status.sourceInfo)) {
            let model = QualityStripModel.make(input)
            let pal = QualityPalette.colors(light: m.theme.isLight)
            ViewThatFits(in: .horizontal) {
                wide(model, pal)
                stacked(model, pal)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
            .onTapGesture { openSignalPath(m, stage) }
            .accessibilityElement(children: .ignore).accessibilityLabel("Signal quality").accessibilityValue(model.spoken).accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the signal path")
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model)
            .layoutProbe("tags")
        }
    }

    private func wide(_ model: QualityStripModel, _ pal: QualityPalette.Set) -> some View {
        HStack(spacing: 0) {
            badge(model, pal, compact: false)
            ForEach(model.cells) { c in QualityCell(cell: c, pal: pal, size: 17, labelSize: 10.5).overlay(alignment: .leading) { divider(pal) } }
            if let e = model.exclusive { exclusiveCell(e, pal, size: 17).overlay(alignment: .leading) { divider(pal) } }
            QualityCell(cell: model.chain, pal: pal, size: 17, labelSize: 10.5).overlay(alignment: .leading) { divider(pal) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(backing(pal))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(pal.ink).opacity(0.16), lineWidth: 1))
        .frame(height: 58)
    }

    private func stacked(_ model: QualityStripModel, _ pal: QualityPalette.Set) -> some View {
        VStack(spacing: 0) {
            badge(model, pal, compact: true)
            HStack(spacing: 0) {
                ForEach(model.cells) { c in QualityCell(cell: c, pal: pal, size: 15, labelSize: 10, fill: true).overlay(alignment: .leading) { divider(pal) } }
            }
            HStack(spacing: 8) {
                if let e = model.exclusive { Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(pal.gold.color); Text("Exclusive output").font(Typo.sans(13, .semibold)).foregroundColor(pal.gold.color).help(e.help) }
                if model.exclusive != nil { Text("·").foregroundColor(pal.label.color) }
                Text(model.chain.value).font(Typo.sans(13, .semibold)).foregroundColor(pal.quiet.color).help(model.chain.help)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 32)
            .overlay(alignment: .top) { Rectangle().fill(Color(pal.ink).opacity(0.1)).frame(height: 1) }
        }
        .frame(maxWidth: 560)
        .background(backing(pal))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(pal.ink).opacity(0.16), lineWidth: 1))
    }

    private func backing(_ pal: QualityPalette.Set) -> some View {
        // a translucent material under a tint: it stays readable over a cover-art backdrop and over any theme
        ZStack { Rectangle().fill(.ultraThinMaterial); Rectangle().fill(Color(pal.backing).opacity(pal.backingAlpha)) }
    }

    private func divider(_ pal: QualityPalette.Set) -> some View { Rectangle().fill(Color(pal.ink).opacity(0.12)).frame(width: 1).padding(.vertical, 0) }

    private func badge(_ model: QualityStripModel, _ pal: QualityPalette.Set, compact: Bool) -> some View {
        let fill = LinearGradient(colors: pal.badgeFill.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
        let tone: (fill: AnyShapeStyle, ink: Color) = {
            switch model.tone {
            case .hiRes, .dsd, .live: return (AnyShapeStyle(fill), pal.badgeInk.color)
            case .lossless: return (AnyShapeStyle(LinearGradient(colors: [Color(white: 0.84), Color(white: 0.66)], startPoint: .topLeading, endPoint: .bottomTrailing)), Color(white: 0.1))
            case .lossy: return (AnyShapeStyle(Color(pal.label).opacity(0.28)), pal.ink.color)
            }
        }()
        return HStack(spacing: compact ? 10 : 12) {
            Image(systemName: model.tone == .lossy ? "waveform.slash" : "waveform").font(.system(size: compact ? 20 : 24, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(Typo.sans(compact ? 15 : 16, .bold))
                if !model.subtitle.isEmpty { Text(model.subtitle).font(Typo.sans(12, .semibold)).opacity(0.78) }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(tone.ink)
        .padding(.leading, 16).padding(.trailing, 20).frame(maxWidth: compact ? .infinity : nil, minHeight: 58, maxHeight: compact ? 46 : .infinity, alignment: .leading)
        .background(tone.fill)
        .help(model.tone == .hiRes ? "High-resolution audio: more than 16 bits or more than 48 kHz, and nothing discarded" : model.tone == .lossless ? "Lossless: every sample of the original is kept" : model.tone == .lossy ? "Lossy: some of the original detail was discarded when the file was made" : model.tone == .dsd ? "Direct Stream Digital: one-bit audio" : "A live radio stream")
    }

    private func exclusiveCell(_ c: QualityStripModel.Cell, _ pal: QualityPalette.Set, size: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(c.label).font(Typo.sans(10.5, .semibold)).tracking(1.4).opacity(0.85)
                Text(c.value).font(Typo.sans(size, .bold))
            }
        }
        .foregroundColor(pal.gold.color).padding(.horizontal, 18).frame(maxHeight: .infinity)
        .background(Color(pal.gold).opacity(0.14)).help(c.help)
    }

    private func bitrate(_ raw: StreamInfo?) -> Int? {
        guard let raw else { return nil }
        if raw.isLive { return m.status.live?.bitrate.flatMap { $0 > 0 ? $0 : nil } }
        guard raw.codec.lowercased().contains("lossy"), let item = m.focusItem else { return nil }
        DispatchQueue.main.async { lossy.request(path: item.path, duration: m.progress.duration) }
        return lossy.values[item.path]
    }
}

private extension Color { init(_ rgb: RGB) { self = rgb.color } }

struct QualityCell: View {
    let cell: QualityStripModel.Cell
    let pal: QualityPalette.Set
    var size: CGFloat = 17
    var labelSize: CGFloat = 10.5
    var fill = false

    var body: some View {
        let tint: RGB = { switch cell.tint { case .ink: pal.ink; case .teal: pal.teal; case .gold: pal.gold; case .quiet: pal.quiet } }()
        VStack(alignment: .leading, spacing: 1) {
            Text(cell.label).font(Typo.sans(labelSize, .semibold)).tracking(1.4).foregroundColor(pal.label.color).lineLimit(1)
            Text(cell.value).font(Typo.sans(size, .semibold)).monospacedDigit().foregroundColor(tint.color).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, fill ? 12 : 18).padding(.vertical, 10)
        .frame(maxWidth: fill ? .infinity : nil, maxHeight: fill ? nil : .infinity, alignment: .leading)
        .help(cell.help)
    }
}

/// The player bar's version: one pill, gold for Hi-Res.
struct QualityPill: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    var body: some View {
        if let input = m.formatTagInput(bitrate: nil) {
            let model = QualityStripModel.make(input)
            let pal = QualityPalette.colors(light: m.theme.isLight)
            let gold = model.tone == .hiRes || model.tone == .dsd
            // a small stamp (HI-RES); under the pointer it grows to the format and the rates
            HStack(spacing: 7) {
                Text(hover ? Self.full(input) : NPRibbon.make(model).text).font(Typo.sans(12.5, .bold)).monospacedDigit().lineLimit(1)
                if model.exclusive != nil { Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)) }
            }
            .foregroundColor(gold ? pal.gold.color : pal.quiet.color)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(gold ? Color(pal.gold).opacity(m.theme.isLight ? 0.2 : 0.16) : Color(pal.ink).opacity(0.08)))
            .contentShape(Capsule())
            .onTapGesture { openSignalPath(m, stage) }
            .onHover { hover = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hover)
            .help(model.title + " · " + model.subtitle + (model.exclusive != nil ? " · Exclusive" : ""))
            .accessibilityElement(children: .ignore).accessibilityLabel("Signal quality").accessibilityValue(model.spoken).accessibilityAddTraits(.isButton)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model)
            .layoutProbe("qualityPill")
        }
    }
}

extension QualityPill {
    /// "FLAC 24/96 → 96": the format and the rates, with the output's when it differs.
    static func full(_ input: FormatTagInput) -> String {
        let s = input.source
        let src: Double = s.sourceRate ?? s.sampleRate
        var text: String = s.codec.uppercased() + " " + String(s.sourceBits) + "/" + QualityMark.rateShort(src)
        if let o = input.output, abs(o.sampleRate - src) > 1 { text += " → " + QualityMark.rateShort(o.sampleRate) }
        return text
    }
}

@MainActor private func openSignalPath(_ m: PlayerModel, _ stage: StageModel) {
    if m.tab != .player { stage.open(m, reduceMotion: false) }
    stage.panel = .signal
    NPDetailModel.shared.set(.signal)
}

import SwiftUI

/// One station on the way from the file to the DAC.
struct PathNode: Identifiable, Equatable {
    enum Kind { case source, decode, stage, buffer, dsp, output }
    let id: String
    var kind: Kind
    var symbol: String
    var title: String
    var subtitle: String
    var detail: String
    /// Whether this station changes sample values (so everything after it is no longer bit-perfect).
    var alters = false
}

/// Turns the engine's status into an ordered list of stations. Pure, so the rules are testable.
enum SignalPath {
    static func nodes(_ s: PlayerStatus) -> [PathNode] {
        guard let raw = s.sourceInfo, let out = s.info else { return [] }
        var n: [PathNode] = []
        let isDSD = raw.sourceBits == 1
        let spec = raw.isLive ? "Live · \(formatRate(raw.sampleRate))" : isDSD ? "\(dsdRateName(raw.sampleRate)) · \(formatRate(raw.sampleRate))" : "\(raw.sourceBits)-bit · \(formatRate(raw.sampleRate))"
        n.append(PathNode(id: "source", kind: .source, symbol: raw.isLive ? "dot.radiowaves.left.and.right" : "opticaldisc", title: raw.codec.replacingOccurrences(of: " (lossy)", with: ""), subtitle: spec,
                          detail: (raw.isLive ? "Live stream: " : "Source file: ") + "\(raw.codec), \(spec), \(raw.channels) channel\(raw.channels == 1 ? "" : "s")", alters: !raw.transparent))
        n.append(PathNode(id: "decode", kind: .decode, symbol: "cpu", title: isDSD ? "DSD reader" : raw.isLive ? "Stream decoder" : "Decoder", subtitle: isDSD ? "DSF / DFF" : raw.isLive ? "AudioToolbox → 32-bit" : "CoreAudio → 32-bit",
                          detail: isDSD ? "The DSD bit stream is read straight from the container." : raw.isLive ? "The stream is demultiplexed (ICY metadata removed), parsed and decoded by AudioToolbox to 32-bit integers." : "CoreAudio decodes to 32-bit integers, left-justified: a lossless bit shift for 16 and 24-bit files."))
        for (i, line) in s.pipeline.enumerated() {
            let l = line.lowercased()
            let node: PathNode
            if l.contains("bypassed") || (l.contains("lossy") && !l.contains("internet radio")) { continue }
            if l.contains("internet radio") { continue }           // already shown by the source and decoder stations
            if l.hasPrefix("pcm → dsd") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "waveform.path", title: "PCM → DSD", subtitle: dsdRateName(out.sampleRate * 16), detail: line, alters: true) }
            else if l.contains("ram") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "memorychip", title: "RAM", subtitle: l.contains("exceeds") || l.contains("streaming") ? "Streaming" : "Preloaded", detail: line) }
            else if l.contains("dop") && !l.contains("bypassed") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "dot.radiowaves.left.and.right", title: "DoP", subtitle: "DSD bits intact", detail: line) }
            else if l.contains("fir decimation") || l.contains("converting to pcm") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "waveform.path", title: "DSD → PCM", subtitle: formatRate(out.sampleRate), detail: line, alters: true) }
            else if l.contains("downmix") || l.contains("mixed down") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "arrow.down.right.and.arrow.up.left", title: "Downmix", subtitle: String(line.prefix(26)), detail: line, alters: true) }
            else if l.contains("played directly") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "hifispeaker.2", title: "Multichannel", subtitle: "Direct", detail: line) }
            else if l.contains("upsampl") || l.contains("resampl") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "arrow.triangle.2.circlepath", title: "Resampler", subtitle: "→ " + formatRate(out.sampleRate), detail: line, alters: true) }
            else if l.contains("replaygain") || l.contains("gain") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "dial.medium", title: "Level", subtitle: s.replayGainDB.map { String(format: "%+.1f dB", $0) } ?? "Gain", detail: line, alters: true) }
            else if l.contains("polarity") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "plusminus.circle", title: "Polarity", subtitle: "Inverted", detail: line, alters: true) }
            else { node = PathNode(id: "p\(i)", kind: .stage, symbol: "gearshape", title: "Stage", subtitle: String(line.prefix(18)), detail: line) }
            n.append(node)
        }
        n.append(PathNode(id: "buffer", kind: .buffer, symbol: "square.stack.3d.down.right", title: "Ring buffer", subtitle: String(format: "%.1f s ahead", s.bufferedSeconds),
                          detail: String(format: "Lock-free queue between the decoder and the audio thread: %.1f s decoded ahead, %d underruns.", s.bufferedSeconds, s.underruns)))
        for (i, line) in s.rtStages.enumerated() {
            let l = line.lowercased()
            let (sym, title) = l.contains("room") || l.contains("convol") ? ("building.columns", "Room") : l.contains("dither") ? ("waveform.badge.minus", "Dither") : l.contains("crossfeed") ? ("headphones", "Crossfeed") : l.contains("eq") ? ("slider.horizontal.3", "AutoEQ") : ("slider.horizontal.3", "Real-time")
            n.append(PathNode(id: "rt\(i)", kind: .stage, symbol: sym, title: title, subtitle: "Real-time", detail: line, alters: true))
        }
        if let d = s.dspSummary { n.append(PathNode(id: "dsp", kind: .dsp, symbol: "slider.vertical.3", title: "DSP", subtitle: "Float", detail: d + " — processed in floating point.", alters: true)) }
        let sub = out.isDoP ? formatRate(out.sampleRate) + " DoP" : "\(formatRate(out.sampleRate))"
        n.append(PathNode(id: "output", kind: .output, symbol: "hifispeaker", title: s.deviceName.isEmpty ? "Output" : s.deviceName, subtitle: sub,
                          detail: s.pathLines.isEmpty ? "Output device" : s.pathLines.joined(separator: "\n")))
        return n
    }
}

extension SignalPath {
    /// One line that says it: "Bit-perfect", or which stages change the signal.
    static func verdict(_ nodes: [PathNode], bitPerfect: Bool) -> String {
        if bitPerfect { return "Bit-perfect: the device receives exactly the samples in the file." }
        let altering = nodes.filter(\.alters).map(\.title)
        if altering.isEmpty { return "Not bit-perfect: the device cannot take the stream as it is." }
        return "Altered by " + (altering.count == 1 ? altering[0] : altering.dropLast().joined(separator: ", ") + " and " + altering.last!) + "."
    }

    /// The stages that are switched off or skipped, as short names.
    static func bypassed(_ s: PlayerStatus) -> [String] {
        s.pipeline.filter { $0.lowercased().contains("bypassed") }.map { line in
            let cut = line.firstIndex(where: { $0 == ":" || $0 == "—" || $0 == "(" }) ?? line.endIndex
            return String(line[..<cut]).trimmingCharacters(in: .whitespaces).prefix(40).description
        }
    }
}

/// The signal path as a vertical line of stages: a ring on the line for each, gold where the stage transforms the signal, plain where it passes it on,
/// and what is switched off dim below. Each stage names its format; above them, the verdict in one line.
struct SignalPathView: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        let nodes = SignalPath.nodes(m.status)
        let off = SignalPath.bypassed(m.status)
        VStack(alignment: .leading, spacing: 16) {
            if nodes.isEmpty {
                Text("Start playback to trace the audio from the file to your DAC.").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).padding(.vertical, 16)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    BitPerfectRow(perfect: m.status.bitPerfect, dop: m.isDoP)
                    Text(SignalPath.verdict(nodes, bitPerfect: m.status.bitPerfect)).font(Typo.sans(12)).foregroundStyle(m.status.bitPerfect ? Brand.inkSecondary : Brand.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Rule()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { i, node in
                        StageRow(node: node, first: i == 0, last: i == nodes.count - 1 && off.isEmpty, tint: tone(nodes, i), lineAbove: i > 0 ? tone(nodes, i - 1) : nil)
                    }
                    ForEach(Array(off.enumerated()), id: \.offset) { i, name in BypassedRow(name: name, last: i == off.count - 1) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(Motion.glide, value: nodes.map(\.id))
    }

    /// The colour of the signal as it leaves station `i`: gold while untouched, copper once anything has altered it.
    private func tone(_ nodes: [PathNode], _ i: Int) -> Color { nodes[0...i].contains { $0.alters } ? Brand.caution : Brand.accentText }
}

/// One stage: the line passing through, a ring on it, the name in the serif, the format in SF Mono and a line about it.
private struct StageRow: View {
    let node: PathNode
    let first: Bool
    let last: Bool
    let tint: Color
    let lineAbove: Color?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: 14)
                if !first { var p = Path(); p.move(to: CGPoint(x: c.x, y: 0)); p.addLine(to: c); ctx.stroke(p, with: .color((lineAbove ?? tint).opacity(0.7)), lineWidth: 1) }
                if !last { var p = Path(); p.move(to: c); p.addLine(to: CGPoint(x: c.x, y: size.height)); ctx.stroke(p, with: .color(tint.opacity(0.7)), lineWidth: 1) }
                let r: CGFloat = node.alters ? 5 : 4
                let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.fill(ring, with: .color(node.alters ? Brand.accent : Brand.canvas))
                ctx.stroke(ring, with: .color(node.alters ? Brand.accent : Brand.ink.opacity(0.8)), lineWidth: 1.25)
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(node.title).font(Typo.serif(17, .regular)).foregroundStyle(Brand.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(node.alters ? "Transforms" : "Passes through").font(Typo.sans(9, .regular)).tracking(1.4).textCase(.uppercase)
                        .foregroundStyle(node.alters ? Brand.accentText : Brand.inkTertiary)
                }
                Text(node.subtitle).font(Typo.mono(11, .regular)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                Text(node.detail).font(Typo.sans(11)).foregroundStyle(Brand.inkTertiary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.title), \(node.subtitle), \(node.alters ? "transforms the signal" : "passes it through")")
        .accessibilityHint(node.detail)
    }
}

/// A stage that is switched off: a hollow, dim mark.
private struct BypassedRow: View {
    let name: String
    let last: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Circle().strokeBorder(Brand.ink.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 8, height: 8).frame(width: 16)
            Text(name).font(Typo.sans(12)).foregroundStyle(Brand.inkTertiary).lineLimit(1)
            Spacer(minLength: 8)
            Text("Bypassed").font(Typo.sans(9, .regular)).tracking(1.4).textCase(.uppercase).foregroundStyle(Brand.inkTertiary)
        }
        .padding(.vertical, 6)
        .accessibilityLabel("\(name), bypassed")
    }
}

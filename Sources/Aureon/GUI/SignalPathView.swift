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
        let spec = isDSD ? "\(dsdRateName(raw.sampleRate)) · \(formatRate(raw.sampleRate))" : "\(raw.sourceBits)-bit · \(formatRate(raw.sampleRate))"
        n.append(PathNode(id: "source", kind: .source, symbol: "opticaldisc", title: raw.codec.replacingOccurrences(of: " (lossy)", with: ""), subtitle: spec,
                          detail: "Source file: \(raw.codec), \(spec), \(raw.channels) channel\(raw.channels == 1 ? "" : "s")", alters: !raw.transparent))
        n.append(PathNode(id: "decode", kind: .decode, symbol: "cpu", title: isDSD ? "DSD reader" : "Decoder", subtitle: isDSD ? "DSF / DFF" : "CoreAudio → 32-bit",
                          detail: isDSD ? "The DSD bit stream is read straight from the container." : "CoreAudio decodes to 32-bit integers, left-justified: a lossless bit shift for 16 and 24-bit files."))
        for (i, line) in s.pipeline.enumerated() {
            let l = line.lowercased()
            let node: PathNode
            if l.contains("bypassed") || l.contains("lossy") { continue }
            if l.contains("ram") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "memorychip", title: "RAM", subtitle: l.contains("exceeds") || l.contains("streaming") ? "Streaming" : "Preloaded", detail: line) }
            else if l.contains("dop") && !l.contains("bypassed") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "dot.radiowaves.left.and.right", title: "DoP", subtitle: "DSD bits intact", detail: line) }
            else if l.contains("fir decimation") || l.contains("converting to pcm") { node = PathNode(id: "p\(i)", kind: .stage, symbol: "waveform.path", title: "DSD → PCM", subtitle: formatRate(out.sampleRate), detail: line, alters: true) }
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
            let (sym, title) = l.contains("room") || l.contains("convol") ? ("building.columns", "Room") : l.contains("crossfeed") ? ("headphones", "Crossfeed") : l.contains("eq") ? ("slider.horizontal.3", "AutoEQ") : ("slider.horizontal.3", "Real-time")
            n.append(PathNode(id: "rt\(i)", kind: .stage, symbol: sym, title: title, subtitle: "Real-time", detail: line, alters: true))
        }
        if let d = s.dspSummary { n.append(PathNode(id: "dsp", kind: .dsp, symbol: "slider.vertical.3", title: "DSP", subtitle: "Float", detail: d + " — processed in floating point.", alters: true)) }
        let sub = isDSD && out.isDoP ? formatRate(out.sampleRate) + " DoP" : "\(formatRate(out.sampleRate))"
        n.append(PathNode(id: "output", kind: .output, symbol: "hifispeaker", title: s.deviceName.isEmpty ? "Output" : s.deviceName, subtitle: sub,
                          detail: s.pathLines.isEmpty ? "Output device" : s.pathLines.joined(separator: "\n")))
        return n
    }
}

struct SignalPathView: View {
    @EnvironmentObject var m: PlayerModel
    @StateObject private var hovered = Box<String?>(nil)

    var body: some View {
        let nodes = SignalPath.nodes(m.status)
        let playing = m.isActive && m.status.state == .playing
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Signal path").kicker().foregroundStyle(.white.opacity(0.6))
                Spacer()
                if !nodes.isEmpty { verdict }
            }
            if nodes.isEmpty {
                Text("Start playback to trace the audio from the file to your DAC.").font(.callout).foregroundStyle(.white.opacity(0.55)).padding(.vertical, 18)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(nodes.enumerated()), id: \.element.id) { i, node in
                            NodeView(node: node, hot: hovered.v == node.id, tint: tone(nodes, i), last: i == nodes.count - 1)
                                .onHover { inside in withAnimation(.smooth(duration: 0.18)) { hovered.v = inside ? node.id : (hovered.v == node.id ? nil : hovered.v) } }
                            if i < nodes.count - 1 { Connector(color: tone(nodes, i), flowing: playing).frame(width: 34, height: 54) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                readout(nodes)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassPanel()
        .animation(.smooth(duration: 0.3), value: nodes.map(\.id))
    }

    /// Colour of the signal as it leaves station `i`: green while untouched, orange once anything has altered it.
    private func tone(_ nodes: [PathNode], _ i: Int) -> Color {
        nodes[0...i].contains { $0.alters } ? Color(red: 1, green: 0.62, blue: 0.3) : Color(red: 0.4, green: 0.92, blue: 0.6)
    }

    private var verdict: some View {
        let perfect = m.status.bitPerfect
        return HStack(spacing: 6) {
            Image(systemName: perfect ? "checkmark.seal.fill" : "waveform.badge.magnifyingglass")
            Text(perfect ? (m.isDoP ? "DoP · DSD bits untouched" : "Bit-perfect") : "Processed").font(.system(size: 11.5, weight: .semibold)).tracking(0.5)
        }
        .foregroundStyle(perfect ? Color(red: 0.4, green: 0.92, blue: 0.6) : Color(red: 1, green: 0.62, blue: 0.3))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill((perfect ? Color.green : Color.orange).opacity(0.14)))
        .help(perfect ? "The device receives exactly the samples in the file." : "At least one stage changes the samples, or the device cannot take the stream natively.")
    }

    private func readout(_ nodes: [PathNode]) -> some View {
        let n = nodes.first { $0.id == hovered.v }
        return Text(n?.detail ?? "Hover a stage for details.")
            .font(Typo.readout).foregroundStyle(.white.opacity(n == nil ? 0.4 : 0.85)).lineLimit(4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .animation(nil, value: hovered.v)
    }
}

private struct NodeView: View {
    let node: PathNode
    let hot: Bool
    let tint: Color
    let last: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.28))
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(node.alters ? Color(red: 1, green: 0.62, blue: 0.3).opacity(hot ? 1 : 0.7) : tint.opacity(hot ? 1 : 0.55), lineWidth: hot ? 1.6 : 1)
                Image(systemName: node.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(node.alters ? Color(red: 1, green: 0.72, blue: 0.45) : .white)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 54, height: 54)
            .shadow(color: (node.alters ? Color.orange : tint).opacity(hot ? 0.55 : 0.0), radius: 10)
            .scaleEffect(hot ? 1.08 : 1)
            VStack(spacing: 2) {
                Text(node.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(node.subtitle).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            .frame(width: 104)
        }
        .foregroundStyle(.white)
        .frame(width: 104)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.title), \(node.subtitle)")
        .accessibilityHint(node.detail)
    }
}

/// A line between two stations with small pulses travelling along it while audio plays.
private struct Connector: View {
    let color: Color
    let flowing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !flowing)) { tl in
            Canvas { ctx, size in
                let y: CGFloat = 27, x0: CGFloat = 2, x1 = size.width - 2
                var line = Path(); line.move(to: CGPoint(x: x0, y: y)); line.addLine(to: CGPoint(x: x1, y: y))
                ctx.stroke(line, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                var head = Path(); head.move(to: CGPoint(x: x1 - 5, y: y - 4)); head.addLine(to: CGPoint(x: x1, y: y)); head.addLine(to: CGPoint(x: x1 - 5, y: y + 4))
                ctx.stroke(head, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                guard flowing else { return }
                let t = tl.date.timeIntervalSinceReferenceDate
                for k in 0..<3 {
                    let f = (t * 0.9 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let x = x0 + (x1 - x0 - 6) * CGFloat(f)
                    let a = sin(f * .pi)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)), with: .color(color.opacity(0.9 * a)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

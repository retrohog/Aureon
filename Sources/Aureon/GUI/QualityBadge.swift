import SwiftUI

// The quality hallmark: a small plate, drawn like a coachbuilder's plaque, that says what the song is. HI-RES (gold, with the bit depth and rate beneath
// in SF Mono; DSD says its multiple), LOSSLESS (ivory), and for lossy formats nothing but a quiet line of text ("AAC 256"). A small gold dot on the plate
// says the stream is bit-perfect. One view serves the player bar, Now Playing and the song rows; hovering it opens the full detail.

/// What a stream is, in the hallmark's terms. Pure, so the classification is testable.
struct QualityMark: Equatable {
    enum Kind: Equatable { case hiRes, lossless, lossy }
    var kind: Kind
    var dsd = false
    /// "HI-RES" or "LOSSLESS"; empty for lossy.
    var title: String
    /// "24/96", "16/44.1", "DSD 64"; for lossy sources "AAC 256".
    var spec: String
    var bitPerfect = false

    /// Above CD quality (more than 16 bits, or more than 48 kHz) is Hi-Res; any other lossless stream is Lossless; lossy formats are lossy.
    static func classify(bits: Int, rate: Double, lossy: Bool) -> Kind {
        if lossy { return .lossy }
        return bits == 1 || bits > 16 || rate > 48_000 ? .hiRes : .lossless
    }

    /// 44.1, 48, 88.2, 96, 176.4, 192 …
    static func rateShort(_ hz: Double) -> String {
        let k = hz / 1000
        return abs(k - k.rounded()) < 0.05 ? "\(Int(k.rounded()))" : String(format: "%.1f", k)
    }

    static func dsdSpec(_ rate: Double) -> String {
        let n = dsdRateName(rate)
        return n.hasPrefix("DSD") && n.count > 3 ? "DSD " + n.dropFirst(3) : "DSD"
    }

    /// The mark of a stream the player is playing. `bitrate` is the live stream's, or the estimated one of a lossy file.
    static func make(source: StreamInfo, bitrate: Int?, bitPerfect: Bool) -> QualityMark {
        let lossy = source.codec.lowercased().contains("lossy")
        let rate = source.sourceRate ?? source.sampleRate
        let kind = classify(bits: source.sourceBits, rate: rate, lossy: lossy)
        let name = source.codec.replacingOccurrences(of: " (lossy)", with: "").uppercased()
        switch kind {
        case .lossy: return QualityMark(kind: .lossy, title: "", spec: bitrate.map { "\(name) \($0)" } ?? name, bitPerfect: false)
        case .hiRes where source.sourceBits == 1: return QualityMark(kind: .hiRes, dsd: true, title: "HI-RES", spec: dsdSpec(rate), bitPerfect: bitPerfect)
        case .hiRes: return QualityMark(kind: .hiRes, title: "HI-RES", spec: "\(source.sourceBits)/\(rateShort(rate))", bitPerfect: bitPerfect)
        case .lossless: return QualityMark(kind: .lossless, title: "LOSSLESS", spec: "\(source.sourceBits)/\(rateShort(rate))", bitPerfect: bitPerfect)
        }
    }

    static let lossyCodecs: Set<String> = ["mp3", "aac", "m4a", "ogg", "opus", "vorbis", "wma", "mp2", "ac3", "mpeg"]

    /// The mark of a song in the library (for rows): only Hi-Res and Lossless have one.
    static func make(track t: TrackDTO) -> QualityMark? {
        let codec = t.codec.lowercased()
        let lossy = codec.contains("lossy") || lossyCodecs.contains(codec)
        let kind = classify(bits: t.bitDepth, rate: t.sampleRate, lossy: lossy)
        switch kind {
        case .lossy: return nil
        case .hiRes where t.bitDepth == 1: return QualityMark(kind: .hiRes, dsd: true, title: "HI-RES", spec: dsdSpec(t.sampleRate))
        case .hiRes: return QualityMark(kind: .hiRes, title: "HI-RES", spec: "\(t.bitDepth)/\(rateShort(t.sampleRate))")
        case .lossless: return QualityMark(kind: .lossless, title: "LOSSLESS", spec: "\(t.bitDepth)/\(rateShort(t.sampleRate))")
        }
    }

    var spoken: String {
        switch kind {
        case .lossy: return spec.replacingOccurrences(of: " ", with: ", ") + ", lossy"
        default:
            let parts = spec.split(separator: "/")
            let detail = dsd ? spec : (parts.count == 2 ? "\(parts[0]) bit, \(parts[1]) kilohertz" : spec)
            return (kind == .hiRes ? "Hi-Res" : "Lossless") + ", " + detail + (bitPerfect ? ", bit-perfect" : "")
        }
    }
}

/// Estimated bitrates of lossy files (size over duration), measured once off the main thread, since the files carry no bitrate of their own.
@MainActor
final class LossyBitrates: ObservableObject {
    static let shared = LossyBitrates()
    @Published private(set) var values: [String: Int] = [:]
    private var pending = Set<String>()

    nonisolated static let standard = [64, 96, 112, 128, 160, 192, 224, 256, 320]
    /// The usual rate nearest to a measured one (within 12 %), else the measure rounded to ten.
    nonisolated static func snap(_ kbps: Double) -> Int {
        guard let n = standard.min(by: { abs(Double($0) - kbps) < abs(Double($1) - kbps) }) else { return Int(kbps) }
        return abs(Double(n) - kbps) / Double(n) <= 0.12 ? n : Int((kbps / 10).rounded()) * 10
    }

    func request(path: String, duration: Double) {
        guard values[path] == nil, !pending.contains(path), duration > 1, path.hasPrefix("/") else { return }
        pending.insert(path)
        Task.detached(priority: .utility) {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            let kbps = size.map { Double($0) * 8 / duration / 1000 }
            await MainActor.run {
                LossyBitrates.shared.pending.remove(path)
                if let kbps, kbps > 8 { LossyBitrates.shared.values[path] = Self.snap(kbps) }
            }
        }
    }
}

/// The plate itself.
struct QualityBadge: View {
    enum Size { case large, regular, compact, tiny }
    let mark: QualityMark
    var size: Size = .regular
    /// The short form: the title alone on one line (what a narrow bar shows).
    var short = false

    private var gold: Bool { mark.kind == .hiRes }
    private var ink: Color { gold ? Brand.accentText : Brand.ink }

    var body: some View {
        Group {
            if mark.kind == .lossy {
                Text(mark.spec).font(Typo.mono(size == .large ? 12 : 10, .regular)).tracking(0.6).foregroundStyle(Brand.inkTertiary).lineLimit(1)
            } else {
                plate
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(mark.spoken)
    }

    private var oneLine: Bool { short || size == .tiny }

    private var plate: some View {
        let titleSize: CGFloat = size == .large ? 12 : (size == .regular ? 11 : (size == .compact ? 10 : 10))
        let specSize: CGFloat = size == .large ? 12 : (size == .regular ? 11 : 10)
        let h: CGFloat = size == .large ? 14 : (size == .regular ? 10 : (size == .compact ? 8 : 5))
        let v: CGFloat = size == .large ? 8 : (size == .regular ? 5 : (size == .compact ? 4 : 3))
        return VStack(spacing: size == .large ? 4 : 2) {
            Text(mark.title).font(Typo.sans(titleSize, .medium)).tracking(size == .tiny ? 0.6 : 1.2).foregroundStyle(ink).lineLimit(1)
            if !oneLine { Text(mark.spec).font(Typo.mono(specSize, .regular)).foregroundStyle(gold ? ink : Brand.inkSecondary).lineLimit(1) }
        }
        .padding(.horizontal, h).padding(.vertical, v)
        .background(RoundedRectangle(cornerRadius: Metrics.tagRadius, style: .continuous).fill(gold ? ink.opacity(0.16) : Brand.ink.opacity(0.08)))
        // bit-perfect: a small gold dot at the corner
        .overlay(alignment: .topTrailing) { if mark.bitPerfect && size != .tiny { Circle().fill(Brand.accent).frame(width: size == .large ? 5 : 4, height: size == .large ? 5 : 4).padding(size == .large ? 5 : 4) } }
    }
}

/// The badge of what is playing, with the full detail on hover. Narrow spaces get the short form before anything else is hidden.
struct NowPlayingBadge: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var lossy = LossyBitrates.shared
    var size: QualityBadge.Size = .regular
    /// Always the short form (the bar decides when it is narrow).
    var forceShort = false
    @StateObject private var open = Box(false)
    @StateObject private var hoverTask = Box<Task<Void, Never>?>(nil)

    var body: some View {
        if m.isActive, let raw = m.status.sourceInfo {
            let mark = QualityMark.make(source: raw, bitrate: bitrate(raw), bitPerfect: m.status.bitPerfect)
            Group {
                if forceShort { QualityBadge(mark: mark, size: size, short: true) }
                else { QualityBadge(mark: mark, size: size) }
            }
            .fixedSize()
            .contentShape(Rectangle())
            .onHover { inside in
                hoverTask.v?.cancel()
                hoverTask.v = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: inside ? 450_000_000 : 250_000_000)
                    if !Task.isCancelled { open.v = inside }
                }
            }
            .onTapGesture { open.v.toggle() }
            .popover(isPresented: Binding(get: { open.v }, set: { open.v = $0 }), arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(mark.kind == .lossy ? "Lossy source" : (mark.kind == .hiRes ? "Hi-Res" : "Lossless")).microLabel().foregroundStyle(Brand.inkTertiary)
                    ReadoutBlock()
                }
                .padding(20).frame(width: 420).glassPopover().foregroundStyle(Brand.ink)
            }
            .onAppear { requestBitrate(raw) }
            .onChange(of: m.status.trackID) { _, _ in if let r = m.status.sourceInfo { requestBitrate(r) } }
            .help("Quality of the song. Hover for the detail.")
        }
    }

    private func bitrate(_ raw: StreamInfo) -> Int? {
        if raw.isLive { return m.status.live?.bitrate.flatMap { $0 > 0 ? $0 : nil } }
        return m.focusItem.flatMap { lossy.values[$0.path] }
    }

    private func requestBitrate(_ raw: StreamInfo) {
        guard !raw.isLive, raw.codec.lowercased().contains("lossy"), let item = m.focusItem else { return }
        lossy.request(path: item.path, duration: m.progress.duration)
    }
}

/// A song row's mark: tiny, only for Hi-Res and Lossless, drawn from the library's own fields with no work to speak of.
struct TinyQualityMark: View {
    let track: TrackDTO
    var body: some View {
        if let mark = QualityMark.make(track: track) { QualityBadge(mark: mark, size: .tiny) }
    }
}

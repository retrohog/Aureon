import SwiftUI
import AppKit

// The details of a song, set as tags beside it: what the file is (source), what Aureon does to it (processing) and what the device receives
// (output). Each tag is one fact at one height, in tracked small capitals or tabular figures; the quality class is tinted (champagne for Hi-Res, a calm ink
// for lossless, a muted one for lossy), DSD and MQA have their own restrained hues. When space is short the least essential tags go first, by priority,
// and a tag is never cut in half. Everything is derived from the published player state: nothing here touches the audio thread.

struct FormatTag: Identifiable, Equatable {
    enum Group: Int, CaseIterable, Comparable {
        case source, processing, output
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
        var title: String { switch self { case .source: "Source"; case .processing: "Processing"; case .output: "Output" } }
    }
    enum Tier: Equatable { case gold, lossless, lossy, dsd, mqa, live, process, ok, caution, plain }

    var id: String
    var group: Group
    /// 0 is always shown; higher numbers give way first.
    var priority: Int
    var text: String
    /// Figures (rates, depths, levels) are set in SF Mono so columns of them line up; words in the text face.
    var numeric = false
    var tier: Tier = .plain
    /// What the tag means, in plain language (the tooltip).
    var help: String
}

/// The playing stream, in plain values: everything a tag needs, so the tags are a pure function of it.
struct FormatTagInput: Equatable {
    var source: StreamInfo
    var output: StreamInfo?
    var bitrate: Int?
    var bitPerfect = false
    var exclusive = false
    var replayGainDB: Double?
    var stages: [String] = []
    var dspActive = false
    var dspSummary: String?
    var rtStages: [String] = []
    var mixing = false
    var mixHelp: String?
    var deviceName = ""
}

enum FormatTagBuilder {
    /// Hi-Res / Lossless / Lossy, from the stored bits and rate.
    static func tagClass(bits: Int, rate: Double, lossy: Bool) -> (text: String, tier: FormatTag.Tier, help: String) {
        switch QualityMark.classify(bits: bits, rate: rate, lossy: lossy) {
        case .hiRes: return ("HI-RES", .gold, "High-resolution audio: more than 16 bits or more than 48 kHz")
        case .lossless: return ("LOSSLESS", .lossless, "Lossless: every sample of the original is kept")
        case .lossy: return ("LOSSY", .lossy, "Lossy: some of the original detail was discarded when the file was made")
        }
    }

    static func channelText(_ n: Int) -> String {
        switch n { case 1: "MONO"; case 2: "STEREO"; case 6: "5.1"; case 8: "7.1"; default: "\(n) CH" }
    }

    /// The tags of the stream that is playing, in front-panel order (source, processing, output).
    static func tags(_ i: FormatTagInput) -> [FormatTag] {
        var out: [FormatTag] = []
        let s = i.source
        let lossy = s.codec.lowercased().contains("lossy")
        let codecName = s.codec.replacingOccurrences(of: " (lossy)", with: "").uppercased()
        let mqa = codecName.contains("MQA")
        let dsd = s.sourceBits == 1
        let srcRate = s.sourceRate ?? s.sampleRate

        // source
        if s.isLive { out.append(FormatTag(id: "live", group: .source, priority: 0, text: "LIVE", tier: .live, help: "A live radio stream")) }
        else {
            let c = tagClass(bits: s.sourceBits, rate: srcRate, lossy: lossy)
            out.append(FormatTag(id: "class", group: .source, priority: c.tier == .lossy ? 1 : 0, text: c.text, tier: c.tier, help: c.help))
        }
        out.append(FormatTag(id: "codec", group: .source, priority: 0, text: mqa ? codecName.replacingOccurrences(of: "MQA", with: "").trimmingCharacters(in: .whitespaces) : codecName,
                             tier: lossy ? .lossy : .plain, help: lossy ? "The file's format (lossy)" : "The file's format (lossless)"))
        if mqa { out.append(FormatTag(id: "mqa", group: .source, priority: 1, text: "MQA", tier: .mqa, help: "The file says it carries MQA: Aureon plays the stream as stored and does not unfold it")) }
        if dsd {
            out.append(FormatTag(id: "dsd", group: .source, priority: 0, text: dsdRateName(srcRate), numeric: true, tier: .dsd, help: "Direct Stream Digital: one-bit audio at \(formatRate(srcRate))"))
            if i.output?.isDoP == true { out.append(FormatTag(id: "dop", group: .source, priority: 1, text: "DOP", tier: .dsd, help: "DSD over PCM: the one-bit stream is carried inside PCM frames and reaches the DAC untouched")) }
        } else if !lossy, !s.isLive {
            out.append(FormatTag(id: "bits", group: .source, priority: 1, text: "\(s.sourceBits)-BIT", numeric: true, help: "Bit depth stored in the file"))
        }
        if !dsd { out.append(FormatTag(id: "rate", group: .source, priority: 0, text: formatRate(srcRate), numeric: true, help: "Sample rate of the file")) }
        if let b = i.bitrate, b > 0, lossy || s.isLive { out.append(FormatTag(id: "bitrate", group: .source, priority: 1, text: "\(b) kbps", numeric: true, help: "Bit rate of the stream")) }
        out.append(FormatTag(id: "channels", group: .source, priority: s.channels == 2 ? 3 : 2, text: channelText(s.channels), help: "Channels in the file"))

        // processing
        if let g = i.replayGainDB { out.append(FormatTag(id: "gain", group: .processing, priority: 2, text: "RG " + String(format: "%+.1f dB", g).replacingOccurrences(of: "-", with: "−"), numeric: true, tier: .process, help: "Loudness normalisation (ReplayGain / loudness tags) is on: this song is played \(String(format: "%+.1f", g)) dB")) }
        if let o = i.output, !o.isDoP, !dsd, abs(o.sampleRate - srcRate) > 1 {
            let filter = i.stages.first { $0.lowercased().contains("resampl") || $0.lowercased().contains("upsampl") || $0.lowercased().contains("oversampl") }
            out.append(FormatTag(id: "upsample", group: .processing, priority: 2, text: (o.sampleRate > srcRate ? "UPSAMPLED " : "RESAMPLED ") + formatRate(o.sampleRate), numeric: true, tier: .process,
                                 help: filter ?? "Converted from \(formatRate(srcRate)) to \(formatRate(o.sampleRate)) for the output device"))
        }
        if i.dspActive || !i.rtStages.isEmpty {
            out.append(FormatTag(id: "dsp", group: .processing, priority: 2, text: "DSP", tier: .process, help: ([i.dspSummary].compactMap { $0 } + i.rtStages).joined(separator: " · ").nonEmpty ?? "Equalizer or plug-ins are changing the sound"))
        }
        if i.mixing { out.append(FormatTag(id: "mix", group: .processing, priority: 0, text: "MIX", tier: .process, help: i.mixHelp ?? "Crossfading into the next song")) }

        // output
        if let o = i.output {
            out.append(FormatTag(id: "outrate", group: .output, priority: 1, text: "OUT " + formatRate(o.sampleRate), numeric: true,
                                 help: "The rate the device receives" + (i.deviceName.isEmpty ? "" : " (\(i.deviceName))")))
        }
        out.append(FormatTag(id: "mode", group: .output, priority: 2, text: i.exclusive ? "EXCLUSIVE" : "SHARED", tier: i.exclusive ? .ok : .plain,
                             help: i.exclusive ? "Exclusive access: Aureon has the device to itself and sets its rate" : "Shared: the system mixer sits between Aureon and the device"))
        out.append(FormatTag(id: "bitperfect", group: .output, priority: i.bitPerfect ? 0 : 1, text: i.bitPerfect ? "BIT-PERFECT" : "PROCESSED", tier: i.bitPerfect ? .ok : .caution,
                             help: i.bitPerfect ? "The device receives exactly the samples in the file" : "Something between the file and the device changes the samples"))
        return out
    }

    /// The tags of a library row: the class, the codec and the depth and rate in one.
    static func rowTags(codec: String, bits: Int, rate: Double) -> [FormatTag] {
        let c = codec.uppercased().replacingOccurrences(of: " (LOSSY)", with: "")
        let lossy = codec.lowercased().contains("lossy") || QualityMark.lossyCodecs.contains(codec.lowercased())
        var out: [FormatTag] = []
        if !lossy { let k = tagClass(bits: bits, rate: rate, lossy: false); out.append(FormatTag(id: "class", group: .source, priority: 0, text: k.text, tier: k.tier, help: k.help)) }
        out.append(FormatTag(id: "codec", group: .source, priority: 0, text: c, tier: lossy ? .lossy : .plain, help: lossy ? "Lossy format" : "Lossless format"))
        if bits == 1 { out.append(FormatTag(id: "dsd", group: .source, priority: 0, text: dsdRateName(rate), numeric: true, tier: .dsd, help: "Direct Stream Digital")) }
        else if bits > 0 { out.append(FormatTag(id: "spec", group: .source, priority: 1, text: "\(bits)/\(QualityMark.rateShort(rate))", numeric: true, help: "Bit depth / sample rate in kHz")) }
        return out
    }

    /// The tags that remain when only those up to `maxPriority` are wanted.
    static func fitting(_ tags: [FormatTag], maxPriority: Int) -> [FormatTag] { tags.filter { $0.priority <= maxPriority } }

    /// The compact set: the class, the codec and the rate; the detailed set is all of them.
    static func forMode(_ tags: [FormatTag], _ mode: FormatTagMode) -> [FormatTag] {
        mode == .detailed ? tags : tags.filter { ["live", "class", "codec", "dsd", "rate", "bitperfect"].contains($0.id) }
    }

    /// Which tags to show in `width` points: all of them if they fit, otherwise the most essential ones that do, dropping the least essential first
    /// (and, within a priority, the later ones). Never cuts a tag. `widthOf` is the width of one tag; `gap` the space between two.
    static func plan(_ tags: [FormatTag], width: CGFloat, gap: CGFloat = 6, groupGap: CGFloat = 14, widthOf: (FormatTag) -> CGFloat) -> [FormatTag] {
        func total(_ t: [FormatTag]) -> CGFloat {
            var w: CGFloat = 0
            for (i, x) in t.enumerated() { w += widthOf(x); if i > 0 { w += t[i - 1].group == x.group ? gap : groupGap } }
            return w
        }
        var kept = tags
        if total(kept) <= width { return kept }
        // drop from the least essential priority down, latest first
        for p in stride(from: (tags.map(\.priority).max() ?? 0), through: 0, by: -1) {
            while let last = kept.lastIndex(where: { $0.priority == p }), total(kept) > width { kept.remove(at: last) }
            if total(kept) <= width { return kept }
        }
        return kept     // not even the essentials fit: nothing left to drop but the whole strip
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

// MARK: - Drawing

enum FormatTagStyle {
    static let height: CGFloat = Metrics.tagHeight

    /// The tone of a tier on the page: fitted to the surface so the legend keeps its contrast on every theme.
    static func ink(_ t: FormatTag.Tier) -> Color {
        let theme = Theme.current
        let surface = theme.panel2RGB.mixed(with: theme.backdropLimitRGB, 0.5)
        switch t {
        case .gold: return theme.accentTextRGB.color
        case .lossless: return Brand.ink
        case .lossy: return Brand.inkTertiary
        case .plain: return Brand.inkSecondary
        case .dsd: return WCAG.fit(RGB(0.74, 0.62, 0.86), against: surface, minimum: 4.5).color
        case .mqa: return WCAG.fit(RGB(0.46, 0.76, 0.76), against: surface, minimum: 4.5).color
        case .live: return WCAG.fit(RGB(0.92, 0.46, 0.44), against: surface, minimum: 4.5).color
        case .process: return WCAG.fit(RGB(0.56, 0.76, 0.58), against: surface, minimum: 4.5).color
        case .ok: return theme.accentTextRGB.color
        case .caution: return Brand.caution
        }
    }
    static func font(_ t: FormatTag, compact: Bool) -> Font { t.numeric ? Typo.mono(compact ? 9 : 10, .regular) : Typo.sans(compact ? 9 : 10, .medium) }
    static func nsFont(_ t: FormatTag, compact: Bool) -> NSFont {
        let s: CGFloat = compact ? 9 : 10
        if t.numeric { return NSFont.monospacedSystemFont(ofSize: s, weight: .regular) }
        return NSFont(name: "AvenirNext-Medium", size: s) ?? NSFont.systemFont(ofSize: s, weight: .medium)
    }
    static func tracking(_ t: FormatTag) -> CGFloat { t.numeric ? 0.3 : 1.3 }
    /// The width of a tag as drawn: its text plus the padding.
    static func width(_ t: FormatTag, compact: Bool) -> CGFloat {
        let w = (t.text as NSString).size(withAttributes: [.font: nsFont(t, compact: compact), .kern: tracking(t)]).width
        return ceil(w) + (compact ? 14 : 18)
    }
}

/// One tag: tracked capitals or figures in the tier's tone on a faint tinted plate with a fine edge; the Hi-Res tag also carries a second line inside.
struct FormatTagView: View {
    let tag: FormatTag
    var compact = false
    var body: some View {
        let c = FormatTagStyle.ink(tag.tier)
        let shape = RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous)
        let strong = tag.tier == .gold || tag.tier == .ok
        Text(tag.text)
            .font(FormatTagStyle.font(tag, compact: compact)).tracking(FormatTagStyle.tracking(tag))
            .foregroundStyle(c).lineLimit(1).fixedSize()
            .padding(.horizontal, compact ? 7 : 9)
            .frame(height: compact ? 18 : FormatTagStyle.height)
            .background(shape.fill(strong ? c.opacity(0.14) : Brand.ink.opacity(Theme.current.isLight ? 0.045 : 0.06)))
            .overlay(shape.strokeBorder(c.opacity(strong ? 0.65 : 0.28), lineWidth: Metrics.hairline))
            .overlay { if tag.tier == .gold { shape.strokeBorder(c.opacity(0.28), lineWidth: Metrics.hairline).padding(2) } }
            .help(tag.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tag.help.isEmpty ? tag.text : "\(tag.text): \(tag.help)")
    }
}

/// The tags in one line that fits the space it is given: groups are separated by a hairline, the least essential tags drop out first.
struct FormatTagStrip: View {
    let tags: [FormatTag]
    var compact = false
    var alignment: Alignment = .leading
    /// Whether the groups get a hairline between them.
    var separators = true

    var body: some View {
        GeometryReader { g in
            let kept = FormatTagBuilder.plan(tags, width: g.size.width, gap: compact ? 4 : 6, groupGap: separators ? 14 : 10, widthOf: { FormatTagStyle.width($0, compact: compact) })
            HStack(spacing: compact ? 4 : 6) {
                ForEach(Array(kept.enumerated()), id: \.element.id) { i, t in
                    if i > 0, kept[i - 1].group != t.group {
                        if separators { Rule(vertical: true).frame(height: 12).padding(.horizontal, 4) } else { Color.clear.frame(width: 4) }
                    }
                    FormatTagView(tag: t, compact: compact).transition(.opacity)
                }
            }
            .fixedSize()
            .frame(width: g.size.width, height: g.size.height, alignment: alignment)
            .animation(Motion.touch, value: kept.map(\.id))
        }
        .frame(height: compact ? 18 : FormatTagStyle.height)
    }
}

/// The detailed block for Now Playing: the three groups side by side under their small captions, each wrapping if the column is narrow.
struct FormatTagBlock: View {
    let tags: [FormatTag]
    var body: some View {
        let groups = FormatTag.Group.allCases.map { g in (g, tags.filter { $0.group == g }) }.filter { !$0.1.isEmpty }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) { ForEach(groups, id: \.0) { cluster($0.0, $0.1) } }.fixedSize()
            VStack(alignment: .leading, spacing: 10) { ForEach(groups, id: \.0) { cluster($0.0, $0.1) } }
        }
    }
    private func cluster(_ g: FormatTag.Group, _ ts: [FormatTag]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(g.title).font(Typo.sans(9, .medium)).tracking(1.6).textCase(.uppercase).foregroundStyle(Brand.inkTertiary)
            WrapLayout(spacing: 5, lineSpacing: 5) { ForEach(ts) { FormatTagView(tag: $0) } }
        }
    }
}

// MARK: - Placed in the interface

extension PlayerModel {
    /// The stream that is audible, as plain values (nil while nothing plays).
    func formatTagInput(bitrate: Int?) -> FormatTagInput? {
        guard isActive, let raw = status.sourceInfo else { return nil }
        return FormatTagInput(source: raw, output: status.info, bitrate: bitrate, bitPerfect: status.bitPerfect, exclusive: exclusive, replayGainDB: status.replayGainDB,
                              stages: status.pipeline, dspActive: status.dspActive, dspSummary: status.dspSummary, rtStages: status.rtStages,
                              mixing: status.mixingInto != nil, mixHelp: status.pipeline.first { $0.hasPrefix("Crossfade") }, deviceName: status.deviceName)
    }
}

/// The tags of what is playing, for the bar and for Now Playing.
struct NowPlayingTags: View {
    enum Place { case bar, header }
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var lossy = LossyBitrates.shared
    var place: Place = .bar
    var alignment: Alignment = .leading

    var body: some View {
        let mode = m.look.formatTags
        if let input = m.formatTagInput(bitrate: bitrate(m.status.sourceInfo)) {
            let all = FormatTagBuilder.tags(input)
            let tags = FormatTagBuilder.forMode(all, mode)
            switch place {
            case .bar: FormatTagStrip(tags: tags, compact: true, alignment: alignment, separators: mode == .detailed)
            case .header:
                if mode == .detailed { FormatTagBlock(tags: all) } else { FormatTagStrip(tags: tags, compact: false, alignment: alignment) }
            }
        }
    }

    private func bitrate(_ raw: StreamInfo?) -> Int? {
        guard let raw else { return nil }
        if raw.isLive { return m.status.live?.bitrate.flatMap { $0 > 0 ? $0 : nil } }
        guard raw.codec.lowercased().contains("lossy"), let item = m.focusItem else { return nil }
        DispatchQueue.main.async { lossy.request(path: item.path, duration: m.progress.duration) }
        return lossy.values[item.path]
    }
}

/// A library row's tags (compact), or the plain mono line when the setting is off.
struct RowTags: View {
    let track: TrackDTO
    var body: some View {
        FormatTagStrip(tags: FormatTagBuilder.rowTags(codec: track.codec, bits: track.bitDepth, rate: track.sampleRate), compact: true, alignment: .trailing, separators: false)
    }
}

/// What the Settings page shows for the format tags: a sample stream in the chosen mode.
struct FormatTagsPreview: View {
    let mode: FormatTagMode
    private var sample: [FormatTag] {
        let src = StreamInfo(sampleRate: 96_000, channels: 2, sourceBits: 24, totalFrames: 96_000 * 200, codec: "FLAC")
        let out = StreamInfo(sampleRate: 192_000, channels: 2, sourceBits: 24, totalFrames: 192_000 * 200, codec: "FLAC")
        return FormatTagBuilder.tags(FormatTagInput(source: src, output: out, bitPerfect: false, exclusive: true, replayGainDB: -6.2, stages: ["Upsampling 96 kHz → 192 kHz"], dspActive: false, mixing: false, deviceName: "USB DAC"))
    }
    var body: some View {
        let tags = FormatTagBuilder.forMode(sample, mode)
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample").microLabel().foregroundStyle(Brand.inkTertiary)
            if mode == .detailed { FormatTagBlock(tags: tags) } else { FormatTagStrip(tags: tags, alignment: .leading) }
        }
    }
}

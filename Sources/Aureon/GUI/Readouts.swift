import SwiftUI

// The technical readouts: a refined, aligned block in two groups, SOURCE and OUTPUT. Labels in tracked small capitals, values in SF Mono with
// tabular figures, hairline between the rows, and the bit-perfect state in the same OFF | ON language as every other switch.

struct ReadoutRow: Equatable, Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

/// What the readouts say, worked out from the player's status. Pure, so it is testable.
enum ReadoutModel {
    static func channelsName(_ n: Int) -> String { n == 1 ? "Mono" : n == 2 ? "Stereo" : n == 6 ? "5.1" : n == 8 ? "7.1" : "\(n) ch" }

    static func source(_ s: PlayerStatus, analysis: TrackAnalysis?) -> [ReadoutRow] {
        guard let raw = s.sourceInfo else { return [] }
        var rows = [ReadoutRow(label: "Format", value: raw.codec.replacingOccurrences(of: " (lossy)", with: "").uppercased() + (raw.codec.contains("lossy") ? " · lossy" : ""))]
        if raw.sourceBits == 1 { rows.append(ReadoutRow(label: "Rate", value: dsdRateName(raw.sourceRate ?? raw.sampleRate))) }
        else {
            rows.append(ReadoutRow(label: "Rate", value: formatRate(raw.sourceRate ?? raw.sampleRate)))
            if !raw.isLive { rows.append(ReadoutRow(label: "Depth", value: "\(raw.sourceBits)-bit")) }
        }
        rows.append(ReadoutRow(label: "Channels", value: channelsName(raw.channels)))
        if raw.isLive, let b = s.live?.bitrate, b > 0 { rows.append(ReadoutRow(label: "Bitrate", value: "\(b) kbps")) }
        if let a = analysis {
            if let l = a.lufs { rows.append(ReadoutRow(label: "Loudness", value: String(format: "%.1f LUFS", l))) }
            rows.append(ReadoutRow(label: "Peak", value: String(format: "%.1f dBFS", a.peakDB)))
        }
        return rows
    }

    static func output(_ s: PlayerStatus) -> [ReadoutRow] {
        guard let out = s.info else { return [] }
        var rows = [ReadoutRow(label: "Device", value: s.deviceName.isEmpty ? "—" : s.deviceName)]
        rows.append(ReadoutRow(label: "Rate", value: out.isDoP ? formatRate(out.sampleRate) + " DoP" : formatRate(out.sampleRate)))
        rows.append(ReadoutRow(label: "DSP", value: s.dspSummary == nil && s.rtStages.isEmpty ? "Off" : (s.dspSummary ?? s.rtStages.joined(separator: ", "))))
        rows.append(ReadoutRow(label: "Gain", value: s.replayGainDB.map { String(format: "%+.1f dB", $0) } ?? "None"))
        return rows
    }
}

struct ReadoutBlock: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        let s = m.status
        let src = ReadoutModel.source(s, analysis: m.focusItem?.analysis), out = ReadoutModel.output(s)
        if m.isActive, !src.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 32) { group("Source", src); group("Output", out, bitPerfect: true) }
                VStack(alignment: .leading, spacing: 20) { group("Source", src); group("Output", out, bitPerfect: true) }
            }
        }
    }

    private func group(_ title: String, _ rows: [ReadoutRow], bitPerfect: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Typo.sans(10, .regular)).tracking(Typo.microTracking).textCase(.uppercase).foregroundStyle(Brand.inkTertiary).padding(.bottom, 8)
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(r.label).font(Typo.sans(9, .regular)).tracking(1.6).textCase(.uppercase).foregroundStyle(Brand.inkTertiary)
                    Spacer(minLength: 8)
                    Text(r.value).font(Typo.mono(11, .regular)).foregroundStyle(Brand.ink).lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 6).overlay(alignment: .bottom) { Rule(strength: 0.5) }
            }
            if bitPerfect { BitPerfectRow(perfect: m.status.bitPerfect, dop: m.isDoP).padding(.top, 8) }
        }
        .frame(minWidth: 168, maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The verdict in the same language as the switches: BIT-PERFECT, then ON or OFF.
struct BitPerfectRow: View {
    let perfect: Bool
    var dop = false
    var body: some View {
        HStack(spacing: 12) {
            Text(dop && perfect ? "DoP · bits untouched" : "Bit-perfect").font(Typo.sans(10, .medium)).tracking(1.6).textCase(.uppercase).foregroundStyle(perfect ? Brand.ink : Brand.caution)
            Spacer(minLength: 8)
            OnOffSwitch(on: perfect)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bit-perfect").accessibilityValue(perfect ? "on" : "off")
    }
}

import SwiftUI

/// Audio → Transitions: gapless, crossfade or smart, with the overlap length, curve and the loudness handover.
struct TransitionsCard: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        Card(title: "Transitions", subtitle: "What happens between songs: no gap, a crossfade, or a smart blend that listens to how each song ends") {
            SegmentedChoice(selection: $m.settings.transition.mode, items: Array(TransitionMode.allCases)) { $0.title }
            Note(text: m.settings.transition.mode.blurb)
            if m.settings.transition.mode != .off {
                HStack {
                    Text("Length").frame(width: 80, alignment: .leading)
                    ValueSlider(value: $m.settings.transition.seconds, in: TransitionSettings.secondsRange, step: 0.5)
                    Text(String(format: "%.1f s", m.settings.transition.seconds)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Curve").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                        SegmentedChoice(selection: $m.settings.transition.curve, items: Array(TransitionCurve.allCases)) { $0.title }
                    }
                    TransitionCurvePreview(curve: m.settings.transition.curve, levelDB: m.settings.transition.matchLevels ? -m.settings.transition.maxMatchDB / 2 : 0)
                        .frame(width: 150, height: 54)
                        .help("How the two songs' levels move across the overlap: the current song (grey) and the next one (accent)")
                }
                Toggle("Keep albums gapless (songs from the same folder follow without a crossfade)", isOn: $m.settings.transition.skipSameAlbum)
                Toggle("Skip silence at the end of a song and the start of the next", isOn: $m.settings.transition.trimSilence)
                Toggle("Match loudness at the handover", isOn: $m.settings.transition.matchLevels)
                if m.settings.transition.matchLevels {
                    HStack {
                        Text("Up to").frame(width: 80, alignment: .leading)
                        ValueSlider(value: $m.settings.transition.maxMatchDB, in: TransitionSettings.matchRange, step: 0.5)
                        Text(String(format: "%.1f dB", m.settings.transition.maxMatchDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    Note(text: "The next song starts at the level the current one ends at (measured with EBU R128 on its first and last seconds) and eases to its own level by the end of the overlap. It is turned down by up to this much, or up by half of it.")
                }
                if let note = m.status.pipeline.first(where: { $0.hasPrefix("Crossfade") }) { Note(text: "Now: \(note).") }
                Note(text: "Songs are blended before the output buffer, so the audio callback is never involved. DSD sent as DoP, internet radio and songs at a different sample rate always stay gapless.")
                Note(text: "While two songs overlap the stream is not bit-perfect; before and after the overlap it is.")
            }
        }
    }
}

/// A small static drawing of the overlap: the outgoing gain falling, the incoming gain rising (with the level handover).
/// Drawn once per settings change, nothing animates.
struct TransitionCurvePreview: View {
    let curve: TransitionCurve
    var levelDB: Double = 0

    var body: some View {
        Canvas { ctx, size in
            let steps = 48
            func line(_ y: (Double) -> Double) -> Path {
                var p = Path()
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    let pt = CGPoint(x: size.width * t, y: size.height * (1 - min(1, max(0, y(t)))))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            let base = Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5))
            ctx.fill(base, with: .color(.secondary.opacity(0.4)))
            ctx.stroke(line { curve.gains($0).outgoing }, with: .color(.secondary), lineWidth: 1.5)
            ctx.stroke(line { t in
                let ease = t * t * (3 - 2 * t)
                return curve.gains(t).incoming * pow(10, levelDB * (1 - ease) / 20)
            }, with: .color(Brand.accent), lineWidth: 1.8)
        }
        .accessibilityLabel("\(curve.title) crossfade curve")
    }
}

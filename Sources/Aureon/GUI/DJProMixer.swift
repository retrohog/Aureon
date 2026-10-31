import SwiftUI

/// Four channel strips (A, B, microphone, auxiliary), master, booth and headphone levels, and the crossfader.
struct ProMixer: View {
    @EnvironmentObject var dj: DJModel
    @State private var mixSeconds = 8.0

    var body: some View {
        PCPanel {
            VStack(spacing: 10) {
                HStack { PCLabel("MIXER"); Spacer(); PCLabel("4 CHANNELS") }
                HStack(alignment: .top, spacing: 4) {
                    DeckStrip(deck: dj.a)
                    DeckStrip(deck: dj.b)
                    LineStrip(channel: dj.mic, color: PC.gold)
                    LineStrip(channel: dj.aux, color: PC.aux)
                }
                Spacer(minLength: 0)
                outputs
                masterEQ
                crossfader
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var outputs: some View {
        PCCluster(title: "MASTER · BOOTH · HEADPHONES") {
            HStack(spacing: 0) {
                PCKnob(value: $dj.masterLevel, range: 0...1.25, label: "MASTER", tint: PC.ink, size: 30, reset: 1, kind: .level)
                Spacer(minLength: 0)
                PCKnob(value: $dj.boothLevel, range: 0...1, label: "BOOTH", tint: PC.ink, size: 30, reset: 0.7, kind: .percent)
                Spacer(minLength: 0)
                PCKnob(value: $dj.cueLevel, range: 0...1.5, label: "PHONES", tint: PC.gold, size: 30, reset: 0.8, kind: .level)
                Spacer(minLength: 0)
                PCKnob(value: $dj.cueMix, range: 0...1, label: "CUE MIX", tint: PC.gold, size: 30, reset: 0, kind: .blend)
            }
        }
    }

    private var masterEQ: some View {
        PCCluster(title: "MASTER EQ") {
            HStack(spacing: 0) {
                PCKnob(value: $dj.masterHigh, range: DJMath.eqRange, label: "HI", tint: PC.ink, size: 26, kind: .eq)
                Spacer(minLength: 0)
                PCKnob(value: $dj.masterMid, range: DJMath.eqRange, label: "MID", tint: PC.ink, size: 26, kind: .eq)
                Spacer(minLength: 0)
                PCKnob(value: $dj.masterLow, range: DJMath.eqRange, label: "LOW", tint: PC.ink, size: 26, kind: .eq)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    PCKey(title: "LIMIT", on: dj.limiter, color: PC.warn, width: 46, height: 24, size: 9.5, help: "Brick-wall limiter at −0.3 dBFS: the mix cannot clip") { dj.limiter.toggle() }
                    Text(dj.limiterReduction > 0.3 ? String(format: "−%.1f dB", dj.limiterReduction) : " ").font(PC.mono(8.5, .medium)).foregroundColor(PC.warn).frame(height: 10)
                }
            }
        }
    }

    private var crossfader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("A").font(PC.mono(13)).foregroundColor(PC.a)
                PCCrossfader(value: $dj.crossfader)
                Text("B").font(PC.mono(13)).foregroundColor(PC.b)
            }
            HStack(spacing: 3) {
                ForEach(CrossfaderCurve.allCases) { c in
                    PCKey(title: c == .smooth ? "SMOOTH" : c == .linear ? "BLEND" : "CUT", on: dj.curve == c, height: 24, size: 9, help: c == .smooth ? "Equal power: steady loudness through the middle" : c == .linear ? "Both at full in the middle" : "Each deck at full until the very end") { dj.curve = c }
                }
                PCKey(title: "REV", on: dj.crossfaderReverse, color: PC.warn, width: 34, height: 24, size: 9, help: "Reverse the crossfader's direction") { dj.crossfaderReverse.toggle() }
            }
            HStack(spacing: 3) {
                PCKey(title: "\(Int(mixSeconds)) s", width: 38, height: 24, size: 9.5, help: "How long the automatic fade takes") { mixSeconds = mixSeconds >= 32 ? 4 : mixSeconds * 2 }
                if dj.autoMixProgress != nil {
                    PCKey(title: "STOP", on: true, color: PC.warn, height: 24, help: "Stop the fade where it is") { dj.cancelAutoMix() }
                } else {
                    PCKey(title: "AUTO FADE ▸", height: 24, enabled: dj.a.isLoaded && dj.b.isLoaded, size: 9.5, help: "Bring in the other deck at this deck's tempo and fade across") { dj.autoMix(seconds: mixSeconds) }
                }
            }
        }
    }
}

/// The strip of a deck.
struct DeckStrip: View {
    @ObservedObject var deck: DJDeck
    var body: some View {
        ProStrip(b: DJStripBindings(name: deck.name, color: PC.deck(deck.name),
                                    trim: $deck.trim, high: $deck.high, mid: $deck.mid, low: $deck.low, filter: $deck.filter, fader: $deck.channel, pfl: $deck.pfl, fxUnit: $deck.fxUnit,
                                    isKilled: { deck.isKilled($0) }, toggleKill: { deck.toggleKill($0) }, peak: { (deck.mix.peakL.value, deck.mix.peakR.value) }),
                 assign: $deck.assign)
    }
}

/// The strip of the microphone or auxiliary input.
struct LineStrip: View {
    @ObservedObject var channel: DJLineChannel
    let color: Color
    var body: some View {
        ProStrip(b: DJStripBindings(name: channel.name, color: color,
                                    trim: $channel.trim, high: $channel.high, mid: $channel.mid, low: $channel.low, filter: $channel.filter, fader: $channel.channel, pfl: $channel.pfl, fxUnit: $channel.fxUnit,
                                    isKilled: { channel.isKilled($0) }, toggleKill: { channel.toggleKill($0) }, peak: { channel.peak }),
                 assign: nil)
    }
}

/// One channel strip: trim, three-band equaliser, filter, effect assignment, headphone cue, kill switches, meters and fader.
struct ProStrip: View {
    let b: DJStripBindings
    let assign: Binding<CrossAssign>?

    var body: some View {
        VStack(spacing: 4) {
            Text(b.name).font(PC.mono(11)).foregroundColor(b.color).frame(height: 14)
            PCKnob(value: b.trim, range: -12...12, label: "TRIM", tint: b.color, size: 28)
            PCKnob(value: b.high, range: DJMath.eqRange, label: "HI", tint: b.color, size: 28, kind: .eq)
            PCKnob(value: b.mid, range: DJMath.eqRange, label: "MID", tint: b.color, size: 28, kind: .eq)
            PCKnob(value: b.low, range: DJMath.eqRange, label: "LOW", tint: b.color, size: 28, kind: .eq)
            PCKnob(value: b.filter, range: -1...1, label: "FILTER", tint: PC.warn, size: 28, kind: .filter)
            HStack(spacing: 2) {
                ForEach(1...3, id: \.self) { u in
                    PCKey(title: "\(u)", on: b.fxUnit.wrappedValue == u, color: PC.gold, width: 15, height: 20, size: 9, help: "Send this channel through effect unit \(u)") { b.fxUnit.wrappedValue = b.fxUnit.wrappedValue == u ? 0 : u }
                }
            }
            if let assign {
                HStack(spacing: 2) {
                    ForEach(Array(CrossAssign.allCases), id: \.self) { a in
                        PCKey(title: a == .thru ? "–" : a.title, on: assign.wrappedValue == a, color: b.color, width: 15, height: 20, size: 9, help: a == .thru ? "Not affected by the crossfader" : "Crossfader side \(a.title)") { assign.wrappedValue = a }
                    }
                }
            } else { Color.clear.frame(height: 20) }
            PCKey(title: "PFL", on: b.pfl.wrappedValue, color: b.color, width: 48, height: 22, size: 9.5, help: "Listen to this channel in the headphones, before its fader") { b.pfl.wrappedValue.toggle() }
            HStack(spacing: 2) {
                ForEach([("high", "H"), ("mid", "M"), ("low", "L")], id: \.0) { band, t in
                    PCKey(title: t, on: b.isKilled(band), color: PC.red, width: 15, height: 20, size: 9, help: "Kill the \(band) band (press again to restore)") { b.toggleKill(band) }
                }
            }
            HStack(spacing: 3) {
                PCMeter(read: { b.peak().0 }, height: 100, width: 6)
                PCFader(value: b.fader, range: 0...1, height: 100, width: 18, tint: b.color, reset: 0.8, step: 0.005)
                PCMeter(read: { b.peak().1 }, height: 100, width: 6)
            }
        }
        .padding(.vertical, 6).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(PC.s2))
        .overlay(alignment: .top) { Rectangle().fill(b.color).frame(height: 2).clipShape(Capsule()).padding(.horizontal, 4) }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PC.line, lineWidth: 0.8))
    }
}

// MARK: - Effects

/// Three effect units. Each channel is sent through one of them with the 1 2 3 keys on its strip.
struct ProFXRow: View {
    @EnvironmentObject var dj: DJModel
    let width: CGFloat
    var body: some View {
        HStack(spacing: DJProMetrics.gap) {
            ForEach(dj.fxUnits) { u in ProFXUnit(unit: u).frame(width: (width - 2 * DJProMetrics.gap) / 3) }
        }
    }
}

struct ProFXUnit: View {
    @ObservedObject var unit: DJFXUnit
    @EnvironmentObject var dj: DJModel
    var body: some View {
        let assigned = ([dj.a, dj.b].filter { $0.fxUnit == unit.index }.map(\.name) + [dj.mic, dj.aux].filter { $0.fxUnit == unit.index }.map(\.name)).joined(separator: " ")
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                PCLabel("FX \(unit.index)")
                Menu {
                    ForEach(DeckFXKind.allCases.filter { $0 != .off }) { k in Button(k.title) { unit.kind = k } }
                } label: {
                    Text(unit.kind.title).font(PC.sans(12.5, .semibold)).foregroundColor(PC.ink).frame(width: 74, alignment: .leading)
                }
                .menuStyle(.borderlessButton).fixedSize()
                Text(assigned.isEmpty ? "no channel" : assigned).font(PC.mono(9.5, .medium)).foregroundColor(assigned.isEmpty ? PC.ink3 : PC.ink2).lineLimit(1)
            }.frame(width: 84, alignment: .leading)
            PCKey(title: unit.on ? "ON" : "OFF", on: unit.on, color: PC.gold, width: 44, height: 26, help: "Effect unit on or off") { unit.on.toggle() }
            Spacer(minLength: 0)
            PCKnob(value: $unit.wet, range: 0...1, label: "WET", tint: PC.gold, size: 32, reset: 0.4, kind: .percent)
            PCKnob(value: $unit.param, range: 0...1, label: unit.kind.paramLabel, tint: PC.gold, size: 32, reset: 0.5, kind: .percent)
        }
        .padding(.horizontal, 10).padding(.vertical, 6).frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 10).fill(PC.s1))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PC.line, lineWidth: 0.8))
    }
}

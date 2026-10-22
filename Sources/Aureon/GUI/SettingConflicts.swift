import SwiftUI

// Some settings do not work together. Rather than letting one silently cancel the other, a change that would create such a clash is held back
// and the person is asked: turn the other thing off and go ahead, or leave everything as it was. The rules live here, in one place, and run on
// every change to `PlaybackSettings` whichever control made it.

struct SettingConflict {
    var message: String
    var fixLabel: String
    /// Brings a settings value to a state without the clash.
    var fix: (inout PlaybackSettings) -> Void
}

struct ConflictPrompt: Identifiable {
    let id = UUID()
    var message: String
    var fixLabel: String
    var proposed: PlaybackSettings
    var fix: (inout PlaybackSettings) -> Void
}

enum SettingRules {
    /// The features that only apply to PCM, and which a DoP stream (DSD inside PCM) must never pass through.
    static func pcmOnly(_ s: PlaybackSettings) -> [String] {
        var out: [String] = []
        if s.upsampling.mode != .off { out.append("Upsampling") }
        if s.replayGain.mode != .off { out.append("Volume leveling") }
        if s.polarityInverted { out.append("Invert polarity") }
        if s.rt.dither.enabled { out.append("Dither") }
        if s.rt.convolution.enabled { out.append("Room correction") }
        if s.rt.crossfeed.enabled { out.append("Crossfeed") }
        if s.rt.headphoneEQ.enabled { out.append("Headphone correction") }
        return out
    }

    static func turnOffPCMOnly(_ s: inout PlaybackSettings) {
        s.upsampling.mode = .off; s.replayGain.mode = .off; s.polarityInverted = false
        s.rt.dither.mode = .off; s.rt.convolution.enabled = false; s.rt.crossfeed.enabled = false; s.rt.headphoneEQ.enabled = false
    }

    static func list(_ names: [String]) -> String { names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + names.last! }

    /// The clash a change from `old` to `new` would create, if any. Only clashes the change itself introduces count, so a combination that was
    /// already there (saved by an older version) is never re-announced.
    static func check(old: PlaybackSettings, new: PlaybackSettings) -> SettingConflict? {
        // PCM → DSD sends the music as DoP, which nothing may process after the modulator
        func dsdOutputBlockers(_ s: PlaybackSettings) -> [String] {
            var out: [String] = []
            if s.rt.dither.enabled { out.append("Dither") }
            if s.rt.convolution.enabled { out.append("Room correction") }
            if s.rt.crossfeed.enabled { out.append("Crossfeed") }
            if s.rt.headphoneEQ.enabled { out.append("Headphone correction") }
            if s.dsp.enabled { out.append("The equalizer and plug-ins") }
            return out
        }
        func clearDSDBlockers(_ s: inout PlaybackSettings) {
            s.rt.dither.mode = .off; s.rt.convolution.enabled = false; s.rt.crossfeed.enabled = false; s.rt.headphoneEQ.enabled = false; s.dsp.enabled = false
        }
        if new.dsdOutput.enabled {
            let blockers = dsdOutputBlockers(new)
            let added = old.dsdOutput.enabled ? blockers.filter { !dsdOutputBlockers(old).contains($0) } : blockers
            if !added.isEmpty {
                return SettingConflict(message: "Converting music to DSD sends it to the DAC as DoP, after all processing, so \(list(added)) cannot apply to it. Turn \(added.count == 1 ? "it" : "them") off and convert to DSD?",
                                       fixLabel: "Turn off and convert", fix: { clearDSDBlockers(&$0) })
            }
            if !old.dsdOutput.enabled, new.dsd.mode != .dop {
                return SettingConflict(message: "Converting music to DSD needs DoP, which sends data inside a PCM stream: a DAC that does not understand DoP plays it as loud noise. Enable DoP as well?",
                                       fixLabel: "Enable DoP", fix: { $0.dsd.mode = .dop; clearDSDBlockers(&$0) })
            }
        }
        // DoP vs everything that processes PCM
        let before = Set(pcmOnly(old)), now = pcmOnly(new)
        if new.dsd.mode == .dop, !new.dsdOutput.enabled {
            if old.dsd.mode != .dop, !now.isEmpty {
                return SettingConflict(message: "DoP sends DSD music as untouched bits inside a PCM stream, so any processing would turn it into noise, and these are on: \(list(now)). Turn them off and enable DoP?",
                                       fixLabel: "Turn off and enable DoP", fix: { turnOffPCMOnly(&$0) })
            }
            let added = now.filter { !before.contains($0) }
            if old.dsd.mode == .dop, !added.isEmpty {
                return SettingConflict(message: "DSD output is set to DoP, which must pass the stream untouched, so \(list(added)) would not apply to DSD music. Switch DSD output to PCM conversion so that it works with everything?",
                                       fixLabel: "Switch DSD to PCM", fix: { $0.dsd.mode = .pcm })
            }
        }
        // room correction is for loudspeakers; crossfeed and headphone correction are for headphones
        func headphoneSide(_ s: PlaybackSettings) -> [String] { (s.rt.crossfeed.enabled ? ["Crossfeed"] : []) + (s.rt.headphoneEQ.enabled ? ["Headphone correction"] : []) }
        if new.rt.convolution.enabled, !headphoneSide(new).isEmpty {
            if !old.rt.convolution.enabled {
                let hp = headphoneSide(new)
                return SettingConflict(message: "Room correction is made for loudspeakers, and \(list(hp)) for headphones; together they correct for a room you are not hearing. Turn off \(list(hp)) and enable room correction?",
                                       fixLabel: "Turn off and enable", fix: { $0.rt.crossfeed.enabled = false; $0.rt.headphoneEQ.enabled = false })
            }
            let added = headphoneSide(new).filter { !headphoneSide(old).contains($0) }
            if !added.isEmpty {
                return SettingConflict(message: "Room correction (for loudspeakers) is on. \(list(added)) is for headphones and the two do not belong together. Turn off room correction and enable \(list(added))?",
                                       fixLabel: "Turn off room correction", fix: { $0.rt.convolution.enabled = false })
            }
        }
        return nil
    }
}

/// Wraps a system alert so a view model (not a view) can ask a question and act on the answer.
@MainActor
func askToProceed(title: String, message: String, proceed: String, cancel: String = "Cancel") -> Bool {
    let a = NSAlert()
    a.messageText = title; a.informativeText = message
    a.addButton(withTitle: proceed); a.addButton(withTitle: cancel)
    return a.runModal() == .alertFirstButtonReturn
}

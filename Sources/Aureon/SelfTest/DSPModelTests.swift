import Foundation

nonisolated(unsafe) private var keepAlive: [AnyObject] = []

struct DSPModelTests {
    private func spin(_ s: TimeInterval) { let end = Date().addingTimeInterval(s); while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) } }

    func profilesSaveAndComeBack() {
        MainActor.assumeIsolated {
            let url = tempDir("dspm").appendingPathComponent("profiles.json")
            try? FileManager.default.removeItem(at: url)
            let a = DSPModel(url: url)
            expect(!a.dirty && a.profiles.isEmpty && a.active == nil, "starts clean")
            a.draft.eq.enabled = true; a.draft.eq.bands[5].gainDB = 6
            expect(a.dirty && a.needsPrompt, "an edit is unsaved")
            a.acknowledgeUnsaved()
            expect(a.dirty && !a.needsPrompt, "kept for the session: still dirty, no more prompts")
            a.draft.eq.bands[5].gainDB = 7
            expect(a.needsPrompt, "a new edit asks again")
            let p = a.saveAs("Headphones")
            expect(!a.dirty && a.activeID == p.id && a.profiles.count == 1, "saved")
            a.draft.eq.bands[2].gainDB = -3
            expect(a.dirty)
            a.save()
            expect(!a.dirty && a.active?.dsp.eq.bands[2].gainDB == -3, "saving writes into the active profile")
            a.draft.eq.bands[0].gainDB = 5
            a.revert()
            expect(!a.dirty && a.draft.eq.bands[0].gainDB == 0 && a.draft.eq.bands[2].gainDB == -3, "revert returns to the saved state")
            // a second launch
            let b = DSPModel(url: url)
            expect(b.profiles.count == 1 && b.active?.name == "Headphones" && b.draft == a.draft && !b.dirty, "the profile and its settings survive a restart")
            b.saveAs("Speakers")
            b.select(nil)
            expect(b.active == nil && b.draft == DSPSettings() && !b.dirty, "a clean start")
            b.select(b.profiles[0].id)
            expect(b.draft.eq.bands[2].gainDB == -3, "choosing a profile loads it")
            b.delete(b.profiles[0].id)
            expect(b.profiles.map(\.name) == ["Speakers"] && b.active == nil, "deleting the active profile leaves a clean state")
            let c = DSPModel(url: url)
            expect(c.profiles.map(\.name) == ["Speakers"])
            // unsaved settings are never written
            c.draft.eq.enabled = true; c.draft.eq.bands[1].gainDB = 9
            let d = DSPModel(url: url)
            expect(d.draft == DSPSettings(), "unsaved changes do not survive a restart")
        }
    }

    func appliesAreThrottled() {
        MainActor.assumeIsolated {
            let m = DSPModel(url: nil)
            var applied: [DSPSettings] = []
            m.apply = { applied.append($0) }
            for i in 0..<60 { m.draft.eq.bands[3].gainDB = Double(i % 12) - 6; m.draft.eq.bands[3].gainDB = Double(i % 12) - 5.5 }
            spin(0.3)
            expect(applied.count >= 1 && applied.count <= 3, "120 edits in a burst reach the engine \(applied.count) times")
            expect(applied.last == m.draft, "and the last one is what the user left")
            let n = applied.count
            spin(0.2)
            expect(applied.count == n, "nothing more is sent once it settles")
            m.draft.eq.bands[3].gainDB = 12
            spin(0.2)
            expect(applied.last?.eq.bands[3].gainDB == 12)
        }
    }

    func leavingTheDSPPageAsksFirst() {
        MainActor.assumeIsolated {
            let m = PlayerModel()
            keepAlive.append(m)                      // its timers and closures outlive this function
            m.dspModel.select(nil)
            m.tab = .dsp
            m.tab = .songs
            expect(m.tab == .songs && !m.showDSPPrompt, "nothing to save: leaves freely")
            m.tab = .dsp
            m.dspModel.draft.eq.enabled = true
            m.tab = .albums
            expect(m.tab == .dsp && m.showDSPPrompt, "unsaved changes: stays and asks")
            m.cancelDSPPrompt()
            expect(m.tab == .dsp && !m.showDSPPrompt)
            m.tab = .albums
            expect(m.showDSPPrompt)
            m.resolveDSPPrompt(save: false)
            expect(m.tab == .albums && m.dspModel.dirty && !m.dspModel.needsPrompt, "“don't save” keeps them for the session and goes on")
            m.tab = .dsp; m.tab = .artists
            expect(m.tab == .artists && !m.showDSPPrompt, "and does not ask again until something changes")
            m.dspModel.select(nil)
        }
    }

    func turningOnTheEqualizerSwitchesTheDSPPathOn() {
        MainActor.assumeIsolated {
            let m = DSPModel(url: nil)
            var last = DSPSettings()
            m.apply = { last = $0 }
            // what the page's toggle does
            m.draft.eq.enabled = true; m.draft.enabled = true
            let t0 = Date()
            while !last.enabled && Date().timeIntervalSince(t0) < 3 { spin(0.05) }
            expect(last.enabled && last.eq.enabled, "the engine is told (waited \(Date().timeIntervalSince(t0)) s)")
        }
    }
}

import SwiftUI
import CoreAudio

/// The parts of the Pro console that reach beyond one deck: the master deck and tempo follow, shared effect units, the sampler, the booth and the live inputs.
extension DJModel {

    // MARK: master and sync

    var masterDeck: DJDeck? { decks.first { $0.name == masterName } }

    /// Makes `d` the deck the others follow (press again to clear).
    func setMaster(_ d: DJDeck?) {
        masterName = (d == nil || masterName == d?.name) ? nil : d?.name
        for x in decks { x.isMaster = x.name == masterName }
    }

    /// The tempo the others follow: the master deck's, else the deck that is playing.
    var masterTempo: Double? {
        if let m = masterDeck, let t = m.effectiveBPM { return t }
        return decks.first { $0.playing }?.effectiveBPM
    }

    /// The deck that sync follows from `d`'s point of view.
    func syncSource(for d: DJDeck) -> DJDeck {
        if let m = masterDeck, m !== d { return m }
        return other(d)
    }

    /// Switches continuous sync on or off. Turning it on matches the tempo and lines the beats up once.
    func setSync(_ d: DJDeck, _ on: Bool) {
        d.syncOn = on
        if on, masterName == nil, !other(d).syncOn { setMaster(other(d)) }
        if on { syncOnce(d) }
    }

    private func syncOnce(_ d: DJDeck) {
        let src = syncSource(for: d)
        guard d.bpm != nil, src.effectiveBPM != nil else { return }
        let o = other(d)
        if src === o { beatSync(d) } else {
            guard let target = src.effectiveBPM, let mine = d.bpm, let p = DJMath.syncPitch(bpm: mine, target: target) else { return }
            d.pitch = max(-d.pitchRange, min(d.pitchRange, p)); if abs(p) > d.pitchRange { d.pitchRange = 0.16; d.pitch = p }
        }
    }

    /// Every tick: a deck with sync on keeps its tempo on the master's.
    func followMaster() {
        for d in decks where d.syncOn && d.isLoaded {
            let src = syncSource(for: d)
            guard src !== d, let target = src.effectiveBPM, let mine = d.bpm, let p = DJMath.syncPitch(bpm: mine, target: target) else { continue }
            let limited = max(-0.16, min(0.16, p))
            if abs(limited - d.pitch) > 0.0002 {
                if abs(limited) > d.pitchRange { d.pitchRange = 0.16 }
                d.pitch = limited
            }
        }
    }

    // MARK: effect units

    /// Pushes each unit's settings to the channels assigned to it.
    func applyFX() {
        func apply(_ unit: Int, kind: (DeckFXKind) -> Void, on: (Bool) -> Void, wet: (Double) -> Void, param: (Double) -> Void) {
            guard (1...fxUnits.count).contains(unit) else { on(false); return }
            let u = fxUnits[unit - 1]
            kind(u.kind); wet(u.wet); param(u.param); on(u.on)
        }
        for d in decks where d.fxUnit > 0 { apply(d.fxUnit, kind: { d.fxKind = $0 }, on: { d.fxOn = $0 }, wet: { d.fxWet = $0 }, param: { d.fxParam = $0 }) }
        for l in [mic, aux] {
            let m = l.mix
            apply(l.fxUnit, kind: { m.params.fxKind.value = $0.rawValue }, on: { m.params.fxOn.value = $0 ? 1 : 0 }, wet: { m.params.fxWet.value = Float($0) }, param: { m.params.fxParam.value = Float($0) })
        }
    }

    // MARK: live inputs and booth

    func refreshInputDevices() { inputDevices = InputDeviceInfo.all() }

    /// Starts the microphone and auxiliary captures that have a device (the microphone defaults to the system input; the auxiliary channel waits for a choice).
    func startLineInputs() {
        refreshInputDevices()
        mic.stop(); aux.stop()
        guard active else { return }
        let m = mic.deviceID.flatMap { InputDeviceInfo.info($0) } ?? InputDeviceInfo.defaultInput()
        if mic.channel > 0 || mic.deviceID != nil { mic.start(rate: rate, device: m) }
        if let id = aux.deviceID, let a = InputDeviceInfo.info(id) { aux.start(rate: rate, device: a) }
    }

    /// Starts the second device for the booth monitors, when one is chosen.
    func startBooth() {
        core.booth.publish(nil); boothRing = nil
        guard case .device(let id) = boothRoute else { return }
        let r = FloatRing(frames: Int(rate))
        guard let o = CoreAudioCueOutput(deviceID: id, ring: r, srcRate: rate) else { outputError = "The booth device is not available"; return }
        do { try o.start(); outputs.append(o); boothRing = r; core.booth.publish(r) } catch { outputError = "Booth: \(error)" }
    }

    // MARK: sampler

    func triggerSample(_ slot: Int) { core.sampler.trigger(slot) }
    func stopSamples() { core.sampler.stopAll() }
    func isSampleSounding(_ slot: Int) -> Bool { (0..<DJSampler.slots).contains(slot) && core.sampler.sounding[slot].value != 0 }

    /// Decodes a file (or part of one) into a sampler slot at the mixer's rate. Runs off the main thread.
    func loadSample(url: URL, slot: Int, from start: Double = 0, seconds: Double = 30) {
        guard (0..<DJSampler.slots).contains(slot) else { return }
        let rate = self.rate, name = url.deletingPathExtension().lastPathComponent
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { DJSampleLoader.load(path: url.path, rate: rate, start: start, seconds: seconds) }.value
            guard let self else { return }
            if let data { self.setSample(data, slot: slot, name: name) } else { self.outputError = "Could not read \(url.lastPathComponent)" }
        }
    }

    /// Takes `beats` beats of the track on a deck, starting at the playhead (or its loop), as a sample.
    func captureSample(from d: DJDeck, beats: Double, slot: Int) {
        guard let t = d.track, let bl = d.beatLength else { return }
        let start = d.loopActive ? (d.loopIn ?? d.position) : d.position
        loadSample(url: URL(fileURLWithPath: t.path), slot: slot, from: start, seconds: min(30, max(0.1, beats * bl)))
        sampleNames[slot] = "\(t.title) · \(DJPadSets.label(beats: beats))"
    }

    func clearSample(_ slot: Int) { setSample(nil, slot: slot, name: "") }

    func setSample(_ data: SampleData?, slot: Int, name: String) {
        guard sampleData.indices.contains(slot) else { return }
        sampleData[slot] = data
        core.sampler.load(data, slot: slot)
        let label = sampleNames[slot] ?? name
        sampleNames[slot] = nil
        sampleSlots[slot] = data.map { (label, Double($0.frames) / rate) }
    }
}

/// Decodes a stretch of a file to stereo Float at the mixer's rate.
enum DJSampleLoader {
    static func load(path: String, rate: Double, start: Double, seconds: Double) -> SampleData? {
        guard let f = try? openLossless(path: path), f.info.totalFrames > 0 else { return nil }
        let info = f.info, ch = info.channels
        let first = Int64(max(0, start) * info.sampleRate)
        f.seek(to: min(first, info.totalFrames - 1))
        let want = Int(min(seconds, 30) * info.sampleRate)
        var l = [Float](), r = [Float]()
        l.reserveCapacity(want); r.reserveCapacity(want)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 8192 * ch); defer { buf.deallocate() }
        let k: Float = 1.0 / 2_147_483_648
        while l.count < want {
            let n = f.read(into: buf, frames: min(8192, want - l.count))
            if n == 0 { break }
            for i in 0..<n { let a = Float(buf[i * ch]) * k; l.append(a); r.append(ch > 1 ? Float(buf[i * ch + 1]) * k : a) }
        }
        guard !l.isEmpty else { return nil }
        if abs(info.sampleRate - rate) > 1 {
            let ratio = info.sampleRate / rate, n = Int(Double(l.count) / ratio)
            var ol = [Float](repeating: 0, count: n), or = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let p = Double(i) * ratio, i0 = Int(p), t = Float(p - Double(i0)), i1 = min(l.count - 1, i0 + 1)
                ol[i] = l[i0] * (1 - t) + l[i1] * t; or[i] = r[i0] * (1 - t) + r[i1] * t
            }
            l = ol; r = or
        }
        // a short fade at both ends so a sample never clicks
        let fade = min(l.count / 2, Int(rate * 0.004))
        for i in 0..<fade { let g = Float(i) / Float(max(1, fade)); l[i] *= g; r[i] *= g; l[l.count - 1 - i] *= g; r[r.count - 1 - i] *= g }
        return SampleData(left: l, right: r)
    }
}

// MARK: - Play history

/// What was loaded on the decks and when, remembered between runs (the library's History source).
extension DJModel {
    private static let historyKey = "aureon.dj.history"
    static var historyDefaults: UserDefaults?

    static func loadHistory() -> [String: Double] {
        guard ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil, ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil || historyDefaults != nil else { return [:] }
        return ((historyDefaults ?? .standard).dictionary(forKey: historyKey) as? [String: Double]) ?? [:]
    }

    func noteLoaded(_ t: DJTrack) {
        history[t.path] = Date().timeIntervalSince1970
        if history.count > 600 { for k in history.sorted(by: { $0.value < $1.value }).prefix(history.count - 500).map(\.key) { history[k] = nil } }
        guard ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] == nil, ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil || Self.historyDefaults != nil else { return }
        (Self.historyDefaults ?? .standard).set(history, forKey: Self.historyKey)
    }
}

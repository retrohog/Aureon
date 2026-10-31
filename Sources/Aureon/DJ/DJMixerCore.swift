import Foundation
import AudioToolbox
import CoreAudio

/// A lock-free single-producer / single-consumer ring of interleaved stereo Float frames.
final class FloatRing: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let buf: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)           // frames written
    private let tail = Atomic<Int>(0)           // frames read

    init(frames: Int) {
        var c = 1; while c < max(64, frames) { c <<= 1 }
        capacity = c; mask = c - 1
        buf = .allocate(capacity: c * 2); buf.initialize(repeating: 0, count: c * 2)
    }
    deinit { buf.deallocate() }

    var available: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }

    /// Writes as many frames as fit; returns how many.
    @discardableResult
    func write(_ p: UnsafePointer<Float>, frames: Int) -> Int {
        let h = head.load(ordering: .relaxed), t = tail.load(ordering: .acquiring)
        let n = min(frames, capacity - (h - t))
        if n <= 0 { return 0 }
        for i in 0..<n { let o = ((h + i) & mask) * 2; buf[o] = p[i * 2]; buf[o + 1] = p[i * 2 + 1] }
        head.store(h + n, ordering: .releasing)
        return n
    }

    func read(into p: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let t = tail.load(ordering: .relaxed), h = head.load(ordering: .acquiring)
        let n = min(frames, h - t)
        if n <= 0 { return 0 }
        for i in 0..<n { let o = ((t + i) & mask) * 2; p[i * 2] = buf[o]; p[i * 2 + 1] = buf[o + 1] }
        tail.store(t + n, ordering: .releasing)
        return n
    }

    /// Consumer side: drop everything buffered.
    func clear() { tail.store(head.load(ordering: .acquiring), ordering: .releasing) }
}

/// Mixes two decks into a master bus and a headphone (cue) bus. Everything the interface changes is an atomic; `process` allocates nothing and takes no locks,
/// so it can run inside a Core Audio output callback.
///
///  deck renderer → Int32 → Float → filter → 3-band EQ → effect ─┬─ (pre-fader) → cue bus
///                                                               └─ fader × crossfader → master sum → master EQ → trim → limiter → output
final class DJMixerCore: @unchecked Sendable {
    static let block = 2048
    let sampleRate: Double

    final class Deck: @unchecked Sendable {
        let renderer = RCUBox<Renderer>()
        let params = DeckParams()
        /// Post-fader level (channel fader × crossfader), ramped across each block.
        let gain = ParamF(0)
        let cue = ParamI(0)
        let peakL = ParamF(0), peakR = ParamF(0)
        /// A live input (microphone, line-in) instead of a player: the feed fills the channel.
        let feed = RCUBox<LineFeed>()
        let isLine: Bool
        fileprivate let proc: DeckProcessor
        fileprivate let fin: UnsafeMutablePointer<Float>
        fileprivate var lastGain: Float = 0
        fileprivate let ints: UnsafeMutablePointer<Int32>
        fileprivate let l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>

        init(sampleRate: Double, line: Bool = false) {
            isLine = line
            fin = .allocate(capacity: DJMixerCore.block * 2); fin.initialize(repeating: 0, count: DJMixerCore.block * 2)
            proc = DeckProcessor(params: params, sampleRate: sampleRate)
            ints = .allocate(capacity: DJMixerCore.block * 8); ints.initialize(repeating: 0, count: DJMixerCore.block * 8)
            l = .allocate(capacity: DJMixerCore.block); r = .allocate(capacity: DJMixerCore.block)
            l.initialize(repeating: 0, count: DJMixerCore.block); r.initialize(repeating: 0, count: DJMixerCore.block)
        }
        deinit { ints.deallocate(); l.deallocate(); r.deallocate(); fin.deallocate() }
    }

    let a: Deck, b: Deck
    /// Microphone and auxiliary (line) inputs: channels of their own, with the same trim, equalizer, filter and effect as a deck.
    let mic: Deck, aux: Deck
    let sampler = DJSampler()
    // booth: the master mix, at its own level, on a second device
    let booth = RCUBox<FloatRing>()
    let boothLevel = ParamF(1)
    private let boothTmp: UnsafeMutablePointer<Float>
    // master
    let masterLow = ParamF(0), masterMid = ParamF(0), masterHigh = ParamF(0)
    let trim = ParamF(1)
    let limiterOn = ParamI(1)
    let meterL = ParamF(0), meterR = ParamF(0)
    let limiterReduction = ParamF(0)
    // headphones
    let cueMix = ParamF(0)              // 0 = cue only … 1 = master only
    let cueLevel = ParamF(1)
    // recording
    let recorder = RCUBox<RecorderTap>()

    private var eqLow = StereoBiquad(), eqMid = StereoBiquad(), eqHigh = StereoBiquad()
    private var lastLow: Float = .nan, lastMid: Float = .nan, lastHigh: Float = .nan
    private var limiter = MasterLimiter()
    private let mL: UnsafeMutablePointer<Float>, mR: UnsafeMutablePointer<Float>, cL: UnsafeMutablePointer<Float>, cR: UnsafeMutablePointer<Float>
    private let mixed: UnsafeMutablePointer<Float>       // interleaved master block, for the recorder

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        a = Deck(sampleRate: sampleRate); b = Deck(sampleRate: sampleRate)
        mic = Deck(sampleRate: sampleRate, line: true); aux = Deck(sampleRate: sampleRate, line: true)
        boothTmp = .allocate(capacity: DJMixerCore.block * 2); boothTmp.initialize(repeating: 0, count: DJMixerCore.block * 2)
        func buf() -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: DJMixerCore.block); p.initialize(repeating: 0, count: DJMixerCore.block); return p }
        mL = buf(); mR = buf(); cL = buf(); cR = buf()
        mixed = .allocate(capacity: DJMixerCore.block * 2); mixed.initialize(repeating: 0, count: DJMixerCore.block * 2)
    }
    deinit { mL.deallocate(); mR.deallocate(); cL.deallocate(); cR.deallocate(); mixed.deallocate(); boothTmp.deallocate() }

    private func refreshMasterEQ() {
        let lo = masterLow.value, mi = masterMid.value, hi = masterHigh.value
        let sr = sampleRate
        if lo != lastLow { lastLow = lo; eqLow.c = abs(lo) < 0.05 ? BiquadSection() : (BiquadSection.coefficients(EQFilter(kind: .lowShelf, fc: 100, gainDB: Double(lo), q: 0.707), sampleRate: sr) ?? BiquadSection()) }
        if mi != lastMid { lastMid = mi; eqMid.c = abs(mi) < 0.05 ? BiquadSection() : (BiquadSection.coefficients(EQFilter(kind: .peak, fc: 1_000, gainDB: Double(mi), q: 0.6), sampleRate: sr) ?? BiquadSection()) }
        if hi != lastHigh { lastHigh = hi; eqHigh.c = abs(hi) < 0.05 ? BiquadSection() : (BiquadSection.coefficients(EQFilter(kind: .highShelf, fc: 8_000, gainDB: Double(hi), q: 0.707), sampleRate: sr) ?? BiquadSection()) }
    }

    private func pull(_ d: Deck, frames n: Int) {
        if d.isLine {
            let live: Bool? = d.feed.read { f in f.render(into: d.fin, frames: n); return true }
            if live != nil { for i in 0..<n { d.l[i] = d.fin[i * 2]; d.r[i] = d.fin[i * 2 + 1] } }
            else { for i in 0..<n { d.l[i] = 0; d.r[i] = 0 } }
        } else {
            let (got, ch) = d.renderer.read { r in (r.render(into: d.ints, frames: n), r.channels) } ?? (0, 2)
            let k: Float = 1.0 / 2_147_483_648
            let c = max(1, min(8, ch))
            for i in 0..<min(got, n) { d.l[i] = Float(d.ints[i * c]) * k; d.r[i] = c > 1 ? Float(d.ints[i * c + 1]) * k : d.l[i] }
            if got < n { for i in max(0, got)..<n { d.l[i] = 0; d.r[i] = 0 } }
        }
        d.proc.process(d.l, d.r, frames: n)         // runs on silence too, so echo and reverb tails ring out when a deck stops
        var pl: Float = 0, pr: Float = 0
        for i in 0..<n { pl = max(pl, abs(d.l[i])); pr = max(pr, abs(d.r[i])) }
        d.peakL.value = max(pl, d.peakL.value * 0.9); d.peakR.value = max(pr, d.peakR.value * 0.9)
    }

    /// One deck into the master and cue sums (a method of its own: no array is built on the audio thread).
    private func mixIn(_ d: Deck, frames n: Int) {
        pull(d, frames: n)
        if d.cue.value != 0 { for i in 0..<n { cL[i] += d.l[i]; cR[i] += d.r[i] } }
        let g0 = d.lastGain, g1 = d.gain.value
        let step = (g1 - g0) / Float(n)
        var g = g0
        for i in 0..<n { g += step; mL[i] += d.l[i] * g; mR[i] += d.r[i] * g }
        d.lastGain = g1
    }

    /// Fills `master` (interleaved stereo Float) and, if given, `cue` (the headphone mix) with `frames` frames.
    func process(master out: UnsafeMutablePointer<Float>, cue cueOut: UnsafeMutablePointer<Float>?, frames: Int) {
        var done = 0
        while done < frames {
            let n = min(DJMixerCore.block, frames - done)
            for i in 0..<n { mL[i] = 0; mR[i] = 0; cL[i] = 0; cR[i] = 0 }
            mixIn(a, frames: n); mixIn(b, frames: n); mixIn(mic, frames: n); mixIn(aux, frames: n)
            sampler.mix(intoLeft: mL, right: mR, frames: n)
            refreshMasterEQ()
            eqLow.process(mL, mR, frames: n); eqMid.process(mL, mR, frames: n); eqHigh.process(mL, mR, frames: n)
            let t = trim.value
            if t != 1 { for i in 0..<n { mL[i] *= t; mR[i] *= t } }
            if limiterOn.value != 0 { limiter.process(mL, mR, frames: n); limiterReduction.value = limiter.reduction }
            var pl: Float = 0, pr: Float = 0
            for i in 0..<n { pl = max(pl, abs(mL[i])); pr = max(pr, abs(mR[i])); mixed[i * 2] = mL[i]; mixed[i * 2 + 1] = mR[i] }
            meterL.value = max(pl, meterL.value * 0.9); meterR.value = max(pr, meterR.value * 0.9)
            for i in 0..<(n * 2) { out[done * 2 + i] = mixed[i] }
            if let cueOut {
                let mix = max(0, min(1, cueMix.value)), lv = cueLevel.value
                for i in 0..<n { cueOut[(done + i) * 2] = (cL[i] * (1 - mix) + mL[i] * mix) * lv; cueOut[(done + i) * 2 + 1] = (cR[i] * (1 - mix) + mR[i] * mix) * lv }
            }
            _ = recorder.read { $0.write(mixed, frames: n) }
            _ = booth.read { ring in
                let lv = boothLevel.value
                for i in 0..<(n * 2) { boothTmp[i] = mixed[i] * lv }
                ring.write(boothTmp, frames: n)
            }
            done += n
        }
    }
}

/// A live input as it reaches the mixer: frames written by the capture callback at the device's rate, resampled to the mixer's.
final class LineFeed: @unchecked Sendable {
    let ring: FloatRing
    private let resampler: CueResampler
    init(ring: FloatRing, srcRate: Double, dstRate: Double) {
        self.ring = ring
        resampler = CueResampler(ring: ring, srcRate: srcRate, dstRate: dstRate, targetFill: Int(srcRate * 0.03))
        resampler.silentOnUnderrun = true
    }
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) { resampler.render(into: out, frames: frames) }
}

/// Resamples the cue ring to a second device's clock: linear interpolation whose ratio is nudged to keep the buffer near its target fill,
/// so two free-running clocks never drift apart into underruns or growing latency.
final class CueResampler {
    private let ring: FloatRing
    private let baseRatio: Double          // source frames consumed per output frame
    private let target: Int
    private var blk = [Float](repeating: 0, count: 1024)
    private var blkN = 0, blkI = 0
    private var s0: (Float, Float) = (0, 0), s1: (Float, Float) = (0, 0)
    private var frac = 1.0
    private(set) var underruns = 0
    /// A live input should fall silent when it runs dry; a headphone feed holds its last value.
    var silentOnUnderrun = false
    private(set) var ratio: Double

    init(ring: FloatRing, srcRate: Double, dstRate: Double, targetFill: Int) { self.ring = ring; baseRatio = srcRate / dstRate; ratio = baseRatio; target = max(256, targetFill) }

    private func nextFrame() -> (Float, Float) {
        if blkI >= blkN {
            blkN = blk.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 512) }; blkI = 0
            if blkN == 0 { underruns += 1; return silentOnUnderrun ? (0, 0) : s1 }               // nothing there: hold the last sample
        }
        let o = blkI * 2; blkI += 1
        return (blk[o], blk[o + 1])
    }

    func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let fill = ring.available + (blkN - blkI)
        let err = Double(fill - target) / Double(target)
        ratio = baseRatio * (1 + max(-0.005, min(0.005, 0.02 * err)))
        for i in 0..<frames {
            while frac >= 1 { s0 = s1; s1 = nextFrame(); frac -= 1 }
            let f = Float(frac)
            out[i * 2] = s0.0 * (1 - f) + s1.0 * f; out[i * 2 + 1] = s0.1 * (1 - f) + s1.1 * f
            frac += ratio
        }
    }
}

/// Writes the master mix to a 32-bit float WAV file from a background thread (the audio thread only copies into a ring).
final class RecorderTap: @unchecked Sendable {
    private let ring = FloatRing(frames: 1 << 17)
    let url: URL
    private let sampleRate: Int
    private var handle: FileHandle?
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let done = DispatchSemaphore(value: 0)
    private(set) var frames = 0
    private(set) var dropped = 0

    init?(url: URL, sampleRate: Double) {
        self.url = url; self.sampleRate = Int(sampleRate)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        try? h.write(contentsOf: Self.header(sampleRate: self.sampleRate, frames: 0))
    }

    static func header(sampleRate: Int, frames: Int) -> Data {
        func le32(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
        func le16(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255)]) }
        let dataBytes = frames * 8
        var h = Data("RIFF".utf8); h += le32(4 + 24 + 12 + 8 + dataBytes) + Data("WAVE".utf8)
        h += Data("fmt ".utf8) + le32(16) + le16(3) + le16(2) + le32(sampleRate) + le32(sampleRate * 8) + le16(8) + le16(32)
        h += Data("fact".utf8) + le32(4) + le32(frames)
        h += Data("data".utf8) + le32(dataBytes)
        return h
    }

    func start() {
        running.store(true, ordering: .relaxed)
        let t = Thread { [self] in
            let tmp = UnsafeMutablePointer<Float>.allocate(capacity: 8192 * 2); defer { tmp.deallocate() }
            func drain() {
                while true {
                    let n = ring.read(into: tmp, frames: 8192)
                    if n == 0 { break }
                    try? handle?.write(contentsOf: Data(bytes: tmp, count: n * 8)); frames += n
                }
            }
            while running.load(ordering: .relaxed) { drain(); usleep(15_000) }
            drain()
            done.signal()
        }
        t.name = "aureon.recorder"; thread = t; t.start()
    }

    /// Audio thread: copies a block of interleaved stereo frames. If the writer cannot keep up, frames are dropped (and counted) rather than blocking.
    func write(_ p: UnsafePointer<Float>, frames n: Int) { let w = ring.write(p, frames: n); if w < n { dropped += n - w } }

    /// Finishes the file (patching the header with the final length) and returns its address.
    @discardableResult
    func stop() -> URL {
        running.store(false, ordering: .relaxed)
        if thread != nil { done.wait() }
        thread = nil
        if let h = handle {
            try? h.seek(toOffset: 0)
            try? h.write(contentsOf: Self.header(sampleRate: sampleRate, frames: frames))
            try? h.close()
        }
        handle = nil
        return url
    }
}

/// One recorded or loaded sound for the sampler: stereo Float, allocated off the audio thread and read by it.
final class SampleData: @unchecked Sendable {
    let frames: Int
    let l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>
    init(left: [Float], right: [Float]) {
        frames = min(left.count, right.count)
        l = .allocate(capacity: max(1, frames)); r = .allocate(capacity: max(1, frames))
        for i in 0..<frames { l[i] = left[i]; r[i] = right[i] }
    }
    deinit { l.deallocate(); r.deallocate() }
}

/// Eight one-shot sample slots played into the master mix. The interface publishes a sample and bumps a counter to trigger it; the audio thread
/// compares counters, so nothing is allocated, locked or messaged while it plays. Triggering a playing slot restarts it.
final class DJSampler: @unchecked Sendable {
    static let slots = 8
    let level = ParamF(0.9)
    private let samples: [RCUBox<SampleData>]
    private let triggers: [ParamI]
    private let stopCount = ParamI(0)
    /// 1 while a slot is sounding, for the pads' lights.
    let sounding: [ParamI]
    private let seen: UnsafeMutablePointer<Int>
    private var seenStop = 0
    private let position: UnsafeMutablePointer<Int>      // next frame of each slot, -1 when idle

    init() {
        samples = (0..<Self.slots).map { _ in RCUBox<SampleData>() }
        triggers = (0..<Self.slots).map { _ in ParamI(0) }
        sounding = (0..<Self.slots).map { _ in ParamI(0) }
        seen = .allocate(capacity: Self.slots); seen.initialize(repeating: 0, count: Self.slots)
        position = .allocate(capacity: Self.slots); position.initialize(repeating: -1, count: Self.slots)
    }
    deinit { seen.deallocate(); position.deallocate() }

    func load(_ s: SampleData?, slot i: Int) { guard (0..<Self.slots).contains(i) else { return }; samples[i].publish(s) }
    func hasSample(_ i: Int) -> Bool { (0..<Self.slots).contains(i) && !samples[i].isEmpty }
    func length(_ i: Int) -> Int { (0..<Self.slots).contains(i) ? (samples[i].read { $0.frames } ?? 0) : 0 }
    func trigger(_ i: Int) { guard (0..<Self.slots).contains(i) else { return }; triggers[i].value &+= 1 }
    func stopAll() { stopCount.value &+= 1 }

    /// Audio thread: adds whatever is sounding to the master sum.
    func mix(intoLeft mL: UnsafeMutablePointer<Float>, right mR: UnsafeMutablePointer<Float>, frames n: Int) {
        let stopNow = stopCount.value
        let stopped = stopNow != seenStop
        seenStop = stopNow
        let lv = level.value
        for s in 0..<Self.slots {
            if stopped { position[s] = -1; sounding[s].value = 0 }
            let t = triggers[s].value
            if t != seen[s] { seen[s] = t; position[s] = 0 }
            let p = position[s]
            if p < 0 { continue }
            let played: Int? = samples[s].read { d in
                let k = min(n, d.frames - p)
                if k > 0 { for i in 0..<k { mL[i] += d.l[p + i] * lv; mR[i] += d.r[p + i] * lv } }
                return max(0, k)
            }
            if let played, p + played < (samples[s].read { $0.frames } ?? 0) { position[s] = p + played; sounding[s].value = 1 }
            else { position[s] = -1; sounding[s].value = 0 }
        }
    }
}

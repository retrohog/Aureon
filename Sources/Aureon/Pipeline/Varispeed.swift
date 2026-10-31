import Foundation

/// Shared between the decode thread and the interface: the playback-speed ratio (pitch fader) and how far into the source the stream has been read.
final class VarispeedControl: @unchecked Sendable {
    private let ratioBits = Atomic<UInt64>(Double(1).bitPattern)
    private let posBits = Atomic<UInt64>(Double(0).bitPattern)

    /// 1 = original speed; 1.08 = 8 % faster (and higher). Limited to 0.5…2.
    var ratio: Double {
        get { Double(bitPattern: ratioBits.load(ordering: .relaxed)) }
        set { ratioBits.store(max(0.5, min(2, newValue.isFinite ? newValue : 1)).bitPattern, ordering: .relaxed) }
    }
    private let bendBits = Atomic<UInt64>(Double(0).bitPattern)
    private let loopOnFlag = Atomic<Bool>(false)
    private let loopInBits = Atomic<Int64>(0), loopOutBits = Atomic<Int64>(0)
    private let wrapCount = Atomic<Int>(0)
    private let reverseFlag = Atomic<Bool>(false)
    private let scratchFlag = Atomic<Bool>(false)
    private let scratchBits = Atomic<UInt64>(Double(0).bitPattern)
    private let keyLockFlag = Atomic<Bool>(false)
    private let shiftBits = Atomic<UInt64>(Double(0).bitPattern)

    /// Plays the track backwards at the pitch fader's speed.
    var reverse: Bool { get { reverseFlag.load(ordering: .relaxed) } set { reverseFlag.store(newValue, ordering: .relaxed) } }
    /// While on, the track plays at `scratchSpeed` (signed, 1 = normal, negative = backwards, 0 = held still) whatever the fader says: a hand on the platter.
    var scratchOn: Bool { get { scratchFlag.load(ordering: .relaxed) } set { scratchFlag.store(newValue, ordering: .relaxed) } }
    var scratchSpeed: Double {
        get { Double(bitPattern: scratchBits.load(ordering: .relaxed)) }
        set { scratchBits.store(max(-8, min(8, newValue.isFinite ? newValue : 0)).bitPattern, ordering: .relaxed) }
    }
    /// Keeps the key when the tempo changes (the speed changes, the pitch does not).
    var keyLock: Bool { get { keyLockFlag.load(ordering: .relaxed) } set { keyLockFlag.store(newValue, ordering: .relaxed) } }
    /// Shifts the key by this many semitones without changing the tempo. Limited to ±12.
    var keyShift: Double {
        get { Double(bitPattern: shiftBits.load(ordering: .relaxed)) }
        set { shiftBits.store(max(-12, min(12, newValue.isFinite ? newValue : 0)).bitPattern, ordering: .relaxed) }
    }
    /// How fast the track is moving through its own timeline right now: signed, 1 = normal speed forwards.
    var effectiveSpeed: Double {
        if scratchOn { return scratchSpeed }
        return (reverse ? -1 : 1) * ratio * (1 + bend)
    }

    /// A momentary nudge on top of the pitch fader (the jog wheel's pitch bend): +0.04 plays 4 % faster while held. Limited to ±50 %.
    var bend: Double {
        get { Double(bitPattern: bendBits.load(ordering: .relaxed)) }
        set { bendBits.store(max(-0.5, min(0.5, newValue.isFinite ? newValue : 0)).bitPattern, ordering: .relaxed) }
    }

    /// A loop over `[loopIn, loopOut)` in source frames. While it is on, reaching `loopOut` jumps back to `loopIn` with the fractional phase kept.
    var loopOn: Bool { loopOnFlag.load(ordering: .relaxed) }
    var loopIn: Int64 { loopInBits.load(ordering: .relaxed) }
    var loopOut: Int64 { loopOutBits.load(ordering: .relaxed) }
    /// Number of times a loop has wrapped (lets the interface notice that the position jumped).
    var wraps: Int { wrapCount.load(ordering: .relaxed) }
    func setLoop(from a: Int64, to b: Int64, on: Bool) {
        loopInBits.store(max(0, a), ordering: .relaxed); loopOutBits.store(max(a + 1, b), ordering: .relaxed)
        loopOnFlag.store(on && b > a, ordering: .relaxed)
    }
    func clearLoop() { loopOnFlag.store(false, ordering: .relaxed) }
    fileprivate func noteWrap() { wrapCount.add(1, ordering: .relaxed) }

    /// Frames of the source consumed so far, fractional.
    var sourceFrame: Double { Double(bitPattern: posBits.load(ordering: .relaxed)) }
    fileprivate func setSourceFrame(_ p: Double) { posBits.store(p.bitPattern, ordering: .relaxed) }
}

/// Plays its source faster or slower by reading it at a fractional step with 4-point (Catmull-Rom) interpolation: a DJ's pitch fader.
/// At exactly 1.0 it hands the samples through unchanged. The ratio can change at any time; `seek` addresses the *source* timeline.
/// It can also run backwards, hold still under a scratching hand, and — through a time stretcher — keep the key while the tempo moves or shift the key alone.
final class VarispeedSource: FrameSource {
    private let base: FrameSource
    let control: VarispeedControl
    let info: StreamInfo
    private let ch: Int
    private var window = ContiguousArray<Int32>()       // interleaved base frames [winStart, winStart + count)
    private var winStart: Int64 = 0
    private var baseNext: Int64 = 0                     // the frame the base will hand over next
    private var count: Int { window.count / ch }
    private var pos = 0.0                               // fractional base frame of the next output sample
    private var eof = false
    private let tmp: UnsafeMutablePointer<Int32>
    private let chunk = 4096
    private let stretcher: TimeStretcher
    private var stretchActive = false
    private let mid: UnsafeMutablePointer<Int32>        // resampled frames on their way into the stretcher
    private let outF: UnsafeMutablePointer<Float>
    private let scratchCap = 16_384

    init(_ base: FrameSource, control: VarispeedControl) {
        self.base = base; self.control = control; ch = base.info.channels
        var i = base.info; i.transparent = false; info = i
        tmp = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * base.info.channels)
        stretcher = TimeStretcher(channels: base.info.channels)
        mid = .allocate(capacity: scratchCap * base.info.channels); outF = .allocate(capacity: scratchCap * base.info.channels)
    }
    deinit { tmp.deallocate(); mid.deallocate(); outF.deallocate() }

    func seek(to frame: Int64) {
        base.seek(to: frame)
        window.removeAll(keepingCapacity: true); winStart = frame; baseNext = frame; pos = Double(frame); eof = false
        stretcher.reset(); stretchActive = false
        control.setSourceFrame(pos)
    }

    /// Reads on from the end of the window until frame `idx` is in it. False at the end of the source.
    private func ensureForward(_ idx: Int64) -> Bool {
        while winStart + Int64(count) <= idx {
            if eof { return false }
            if baseNext != winStart + Int64(count) { base.seek(to: winStart + Int64(count)); baseNext = winStart + Int64(count) }
            let n = base.read(into: tmp, frames: chunk)
            if n == 0 { eof = true; return false }
            window.append(contentsOf: UnsafeBufferPointer(start: tmp, count: n * ch)); baseNext += Int64(n)
        }
        return true
    }

    /// Reads the stretch of the source before the window until frame `idx` is in it (for playing backwards).
    private func ensureBackward(_ idx: Int64) {
        while winStart > max(0, idx) {
            let from = max(0, winStart - Int64(chunk)), want = Int(winStart - from)
            base.seek(to: from)
            var got = 0
            var block = ContiguousArray<Int32>(); block.reserveCapacity(want * ch)
            while got < want {
                let n = base.read(into: tmp, frames: min(chunk, want - got))
                if n == 0 { break }
                block.append(contentsOf: UnsafeBufferPointer(start: tmp, count: n * ch)); got += n
            }
            baseNext = from + Int64(got)
            if got < want { block.append(contentsOf: repeatElement(0, count: (want - got) * ch)) }
            window.insert(contentsOf: block, at: 0); winStart = from
            eof = false
        }
    }

    /// Fills `frames` frames at `speed` source frames per output frame (negative = backwards). A speed of zero gives silence and does not move.
    private func resample(into buf: UnsafeMutablePointer<Int32>, frames: Int, speed: Double) -> Int {
        if abs(speed) < 1e-4 { buf.update(repeating: 0, count: frames * ch); return frames }
        var produced = 0
        while produced < frames {
            let i0 = Int64(pos.rounded(.down))
            if speed < 0 {
                if i0 < 0 { break }
                if count == 0 || i0 + 2 >= winStart + Int64(count) { _ = ensureForward(i0 + 2) }
                ensureBackward(i0 - 1)
            } else if !ensureForward(i0 + 2) {
                // the tail: when the source ends, interpolate against its last frame instead of dropping up to two frames
                if i0 >= winStart + Int64(count) { break }
            }
            let last = winStart + Int64(count) - 1
            let t = pos - Double(i0)
            for c in 0..<ch {
                @inline(__always) func at(_ i: Int64) -> Double { Double(window[Int(min(max(i, winStart), last) - winStart) * ch + c]) }
                let p0 = at(i0 - 1), p1 = at(i0), p2 = at(i0 + 1), p3 = at(i0 + 2)
                let v = p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
                buf[produced * ch + c] = Int32(clamping: Int64(v.rounded()))
            }
            produced += 1
            pos += speed
            if control.loopOn {
                let a = control.loopIn, b = control.loopOut, len = Double(max(1, b - a))
                if speed > 0, pos >= Double(b) {
                    // jump back; reload the window a little before the loop start so the interpolation has its neighbours
                    pos = Double(a) + (pos - Double(b)).truncatingRemainder(dividingBy: len)
                    rewindWindow(to: max(0, a - 2))
                } else if speed < 0, pos < Double(a) {
                    pos = Double(b) - (Double(a) - pos).truncatingRemainder(dividingBy: len)
                    rewindWindow(to: max(0, Int64(pos) - 2))
                }
            }
        }
        // keep the window small: drop what is far behind the playhead (or, backwards, far ahead of it)
        if speed >= 0 {
            let drop = Int(Int64(pos.rounded(.down)) - 2 - winStart)
            if drop > 8192 { window.removeFirst(drop * ch); winStart += Int64(drop) }
        } else {
            let keep = Int(Int64(pos.rounded(.down)) + 8192 - winStart)
            if keep > 0, keep < count - 8192 { window.removeLast((count - keep) * ch) }
        }
        control.setSourceFrame(pos)
        return produced
    }

    private func rewindWindow(to from: Int64) {
        base.seek(to: from); window.removeAll(keepingCapacity: true); winStart = from; baseNext = from; eof = false
        control.noteWrap()
    }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let c = control
        if c.scratchOn { stretchActive = false; return resample(into: buf, frames: frames, speed: c.scratchSpeed) }
        let t = max(0.05, c.ratio * (1 + c.bend)), dir: Double = c.reverse ? -1 : 1
        let shift = c.keyShift, lock = c.keyLock
        let p = shift == 0 ? 1.0 : pow(2, shift / 12)
        let rr = (lock ? 1.0 : t) * p                    // how fast the source moves through the resampler: this sets the pitch
        let s = t / rr                                   // how many resampled frames the stretcher uses per output frame: this restores the tempo
        if abs(s - 1) < 1e-9 || frames > scratchCap { stretchActive = false; return resample(into: buf, frames: frames, speed: dir * rr) }
        if !stretchActive { stretcher.reset(); stretchActive = true }
        let got = stretcher.render(into: outF, frames: frames, stretch: s) { dst, n in
            let m = self.resample(into: self.mid, frames: n, speed: dir * rr)
            let k = Float(1.0 / 2_147_483_648.0)
            for i in 0..<(m * self.ch) { dst[i] = Float(self.mid[i]) * k }
            return m
        }
        let k = Float(2_147_483_648.0)
        for i in 0..<(got * ch) { buf[i] = Int32(clamping: Int64((max(-1, min(1, outF[i])) * k).rounded())) }
        return got
    }
}

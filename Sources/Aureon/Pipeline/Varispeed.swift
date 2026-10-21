import Foundation
import Synchronization

/// Shared between the decode thread and the interface: the playback-speed ratio (pitch fader) and how far into the source the stream has been read.
final class VarispeedControl: @unchecked Sendable {
    private let ratioBits = Atomic<UInt64>(Double(1).bitPattern)
    private let posBits = Atomic<UInt64>(Double(0).bitPattern)

    /// 1 = original speed; 1.08 = 8 % faster (and higher). Limited to 0.5…2.
    var ratio: Double {
        get { Double(bitPattern: ratioBits.load(ordering: .relaxed)) }
        set { ratioBits.store(max(0.5, min(2, newValue.isFinite ? newValue : 1)).bitPattern, ordering: .relaxed) }
    }
    /// Frames of the source consumed so far, fractional.
    var sourceFrame: Double { Double(bitPattern: posBits.load(ordering: .relaxed)) }
    fileprivate func setSourceFrame(_ p: Double) { posBits.store(p.bitPattern, ordering: .relaxed) }
}

/// Plays its source faster or slower by reading it at a fractional step with 4-point (Catmull-Rom) interpolation: a DJ's pitch fader.
/// At exactly 1.0 it hands the samples through unchanged. The ratio can change at any time; `seek` addresses the *source* timeline.
final class VarispeedSource: FrameSource {
    private let base: FrameSource
    let control: VarispeedControl
    let info: StreamInfo
    private let ch: Int
    private var window = ContiguousArray<Int32>()       // interleaved base frames [winStart, winStart + count)
    private var winStart: Int64 = 0
    private var count: Int { window.count / ch }
    private var pos = 0.0                               // fractional base frame of the next output sample
    private var eof = false
    private let tmp: UnsafeMutablePointer<Int32>
    private let chunk = 4096

    init(_ base: FrameSource, control: VarispeedControl) {
        self.base = base; self.control = control; ch = base.info.channels
        var i = base.info; i.transparent = false; info = i
        tmp = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * base.info.channels)
    }
    deinit { tmp.deallocate() }

    func seek(to frame: Int64) {
        base.seek(to: frame)
        window.removeAll(keepingCapacity: true); winStart = frame; pos = Double(frame); eof = false
        control.setSourceFrame(pos)
    }

    /// Makes frame `idx` available in the window. False at the end of the source.
    private func ensure(_ idx: Int64) -> Bool {
        while winStart + Int64(count) <= idx {
            if eof { return false }
            let n = base.read(into: tmp, frames: chunk)
            if n == 0 { eof = true; return false }
            window.append(contentsOf: UnsafeBufferPointer(start: tmp, count: n * ch))
        }
        return true
    }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var produced = 0
        let ratio = control.ratio
        while produced < frames {
            let i0 = Int64(pos.rounded(.down))
            if !ensure(i0 + 2) {
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
            pos += ratio
        }
        // keep the window small: drop what is behind the interpolation neighbourhood
        let drop = Int(Int64(pos.rounded(.down)) - 2 - winStart)
        if drop > 8192 { window.removeFirst(drop * ch); winStart += Int64(drop) }
        control.setSourceFrame(pos)
        return produced
    }
}

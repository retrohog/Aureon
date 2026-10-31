import Foundation

// MARK: - Memory playback

/// A whole decoded track held in RAM. Reading from it never touches the disk.
final class MemoryTrack: @unchecked Sendable {
    let info: StreamInfo
    let frames: Int
    private let data: UnsafeMutablePointer<Int32>
    var bytes: Int { frames * info.channels * 4 }

    fileprivate init(info: StreamInfo, frames: Int, data: UnsafeMutablePointer<Int32>) {
        self.info = info; self.frames = frames; self.data = data
    }
    deinit { data.deallocate() }

    static func estimatedBytes(of info: StreamInfo) -> Int { Int(info.totalFrames) * info.channels * 4 }

    /// Decodes `source` to the end. Returns nil when it would exceed `budgetBytes` or `cancelled()` turns true.
    static func load(from source: FrameSource, budgetBytes: Int, progress: ((Double) -> Void)? = nil,
                     cancelled: () -> Bool = { false }) -> MemoryTrack? {
        let info = source.info
        guard info.totalFrames > 0, estimatedBytes(of: info) <= budgetBytes else { return nil }
        let ch = info.channels, cap = Int(info.totalFrames)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: cap * ch)
        var got = 0
        source.seek(to: 0)
        while got < cap {
            if cancelled() { buf.deallocate(); return nil }
            let n = source.read(into: buf + got * ch, frames: min(16_384, cap - got))
            if n == 0 { break }
            got += n
            progress?(Double(got) / Double(cap))
        }
        var out = info; out.totalFrames = Int64(got)
        return MemoryTrack(info: out, frames: got, data: buf)
    }

    fileprivate func copy(from frame: Int, to dst: UnsafeMutablePointer<Int32>, frames n: Int) {
        dst.update(from: data + frame * info.channels, count: n * info.channels)
    }
}

final class MemorySource: FrameSource {
    let track: MemoryTrack
    var info: StreamInfo { track.info }
    private var pos = 0
    init(_ t: MemoryTrack) { track = t }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let n = max(0, min(frames, track.frames - pos))
        if n > 0 { track.copy(from: pos, to: buf, frames: n); pos += n }
        return n
    }
    func seek(to frame: Int64) { pos = max(0, min(Int(frame), track.frames)) }
}

/// Byte-budgeted store of decoded tracks. Holds the playing track plus whatever was prefetched.
final class TrackCache: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(key: String, track: MemoryTrack)] = []
    private var inFlight = Set<String>()
    var budgetBytes: Int

    init(budgetBytes: Int) { self.budgetBytes = budgetBytes }

    var usedBytes: Int { lock.lock(); defer { lock.unlock() }; return items.reduce(0) { $0 + $1.track.bytes } }

    func get(_ key: String) -> MemoryTrack? {
        lock.lock(); defer { lock.unlock() }
        return items.first { $0.key == key }?.track
    }

    func put(_ key: String, _ track: MemoryTrack) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.key == key }
        items.append((key, track))
        while items.count > 1 && items.reduce(0, { $0 + $1.track.bytes }) > budgetBytes { items.removeFirst() }
    }

    /// Keep only tracks whose file path is in `paths` (keys look like "path|variant"); everything else is released.
    func retain(onlyPaths paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { !paths.contains(String($0.key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")) }
    }

    func clear() { lock.lock(); items = []; lock.unlock() }

    /// Marks `key` as being decoded so it is only prefetched once. Returns false if it already is.
    func beginPrefetch(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inFlight.contains(key) || items.contains(where: { $0.key == key }) { return false }
        inFlight.insert(key); return true
    }
    func endPrefetch(_ key: String) { lock.lock(); inFlight.remove(key); lock.unlock() }
}

// MARK: - Sample-value stages (each one marks the stream as no longer bit-transparent)

/// Linear gain on Int32 samples with rounding and clipping. A gain of exactly 1 is a byte-exact passthrough.
final class GainSource: FrameSource {
    private let upstream: FrameSource
    let gain: Double
    let info: StreamInfo

    init(_ upstream: FrameSource, gain: Double) {
        self.upstream = upstream; self.gain = gain
        var i = upstream.info
        if gain != 1.0 { i.transparent = false }
        info = i
    }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let n = upstream.read(into: buf, frames: frames)
        guard gain != 1.0, n > 0 else { return n }
        let count = n * info.channels
        for k in 0..<count {
            let v = (Double(buf[k]) * gain).rounded()
            buf[k] = v >= 2_147_483_647 ? .max : (v <= -2_147_483_648 ? .min : Int32(v))
        }
        return n
    }
    func seek(to frame: Int64) { upstream.seek(to: frame) }
}

final class InvertSource: FrameSource {
    private let upstream: FrameSource
    let info: StreamInfo
    init(_ upstream: FrameSource) { self.upstream = upstream; var i = upstream.info; i.transparent = false; info = i }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let n = upstream.read(into: buf, frames: frames)
        for k in 0..<(n * info.channels) { buf[k] = buf[k] == .min ? .max : -buf[k] }
        return n
    }
    func seek(to frame: Int64) { upstream.seek(to: frame) }
}

// MARK: - DoP

/// Running frame counter shared by every DoP track of a playback group, so the 0x05/0xFA marker keeps
/// alternating across gapless track boundaries. A DAC that sees the marker pattern break drops DSD lock.
final class DoPClock: @unchecked Sendable { var phase = 0 }

/// Writes the DoP marker byte into the top byte of each (otherwise unstamped) DoP frame.
final class DoPStampSource: FrameSource {
    private let upstream: FrameSource
    private let clock: DoPClock
    let info: StreamInfo
    init(_ upstream: FrameSource, clock: DoPClock) { self.upstream = upstream; self.clock = clock; info = upstream.info }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let n = upstream.read(into: buf, frames: frames)
        let ch = info.channels
        for f in 0..<n {
            let marker: Int32 = (clock.phase & 1) == 0 ? 0x05 : 0xFA
            clock.phase &+= 1
            for c in 0..<ch { buf[f * ch + c] = (marker << 24) | (buf[f * ch + c] & 0x00FF_FF00) }
        }
        return n
    }
    func seek(to frame: Int64) { upstream.seek(to: frame) }
}

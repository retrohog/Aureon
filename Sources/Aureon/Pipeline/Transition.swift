import Foundation
import Accelerate

// Transitions between queued tracks: gapless (off), a fixed crossfade, or a smart one that reads how each track starts and ends.
//
// The mix is made on the engine (producer) thread, before the ring buffer:
//
//   outgoing chain ─┐
//                   ├─► TransitionMixer (gain curves, level handover, peak guard) ─► ring ─► Renderer (unchanged) ─► DAC
//   incoming chain ─┘
//
// The real-time callback never knows a transition is happening. With transitions off, or between songs of one album, the delivered
// stream is bit-for-bit the gapless one. Both chains are complete (ReplayGain, resampling, downmix), so they are mixed at the same rate.

// MARK: - Settings

enum TransitionMode: String, Codable, CaseIterable, Identifiable {
    case off, crossfade, smart
    var id: String { rawValue }
    var title: String { switch self { case .off: "Gapless"; case .crossfade: "Crossfade"; case .smart: "Smart" } }
    var blurb: String {
        switch self {
        case .off: "Songs follow each other with no gap and no overlap. Bit-perfect."
        case .crossfade: "The next song fades in while the current one fades out, for the length set below."
        case .smart: "Like crossfade, but each pair is looked at first: a song that already fades out keeps its own fade and the next one comes in underneath, and the overlap never runs longer than the fade."
        }
    }
}

enum TransitionCurve: String, Codable, CaseIterable, Identifiable {
    case equalPower, linear, sCurve
    var id: String { rawValue }
    var title: String { switch self { case .equalPower: "Equal power"; case .linear: "Linear"; case .sCurve: "S-curve" } }

    /// Gains of the outgoing and the incoming track at `t` (0 = start of the overlap, 1 = end).
    @inline(__always)
    func gains(_ t: Double) -> (outgoing: Double, incoming: Double) {
        let x = max(0, min(1, t))
        switch self {
        case .equalPower: return (cos(x * .pi / 2), sin(x * .pi / 2))
        case .linear: return (1 - x, x)
        case .sCurve: let s = x * x * (3 - 2 * x); return (cos(s * .pi / 2), sin(s * .pi / 2))
        }
    }
}

struct TransitionSettings: Equatable, Codable {
    static let secondsRange: ClosedRange<Double> = 1...12
    static let matchRange: ClosedRange<Double> = 1...9

    var mode: TransitionMode = .off
    /// The longest overlap, in seconds.
    var seconds: Double = 6
    var curve: TransitionCurve = .equalPower
    /// Songs from the same album (folder) stay gapless: live recordings and albums that run on from track to track.
    var skipSameAlbum = true
    /// Ease the next song in from the level the current one ends at, instead of jumping to its own level.
    var matchLevels = true
    /// How far the handover may move the next song's level (it is lowered by up to this much, raised by up to half of it).
    var maxMatchDB: Double = 6
    /// Leave out digital silence at the end of the current song and the start of the next one.
    var trimSilence = true

    init() {}

    /// Tolerant decoding: settings saved by an older version (missing keys) still load.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(TransitionMode.self, forKey: .mode) ?? mode
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? seconds
        curve = try c.decodeIfPresent(TransitionCurve.self, forKey: .curve) ?? curve
        skipSameAlbum = try c.decodeIfPresent(Bool.self, forKey: .skipSameAlbum) ?? skipSameAlbum
        matchLevels = try c.decodeIfPresent(Bool.self, forKey: .matchLevels) ?? matchLevels
        maxMatchDB = try c.decodeIfPresent(Double.self, forKey: .maxMatchDB) ?? maxMatchDB
        trimSilence = try c.decodeIfPresent(Bool.self, forKey: .trimSilence) ?? trimSilence
    }
}

/// Which album a file belongs to, for "keep albums gapless". A local file's album is its folder; a streamed one has none.
enum AlbumKey {
    static func folder(_ path: String) -> String? {
        guard !Player.isStreamURL(path), !RemoteMedia.isRemote(path) else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }
}

// MARK: - Edge analysis: how a track starts and ends

/// What the transition planner needs to know about the two ends of a track. Times in seconds of the file.
struct EdgeProfile: Codable, Equatable {
    static let currentVersion = 2
    var duration: Double
    /// Digital silence (below `EdgeAnalyzer.silenceDBFS`) before the music starts and after it ends.
    var leadSilence: Double
    var trailSilence: Double
    /// Integrated loudness (BS.1770, gated) of the first `EdgeAnalyzer.loudnessSeconds` and the last `EdgeAnalyzer.tailLoudnessSeconds`
    /// of music. nil when silent.
    var headLUFS: Double?
    var tailLUFS: Double?
    /// Length of the song's own fade-out, when it has one.
    var tailFadeSeconds: Double?
    var version = EdgeProfile.currentVersion
}

enum EdgeAnalyzer {
    /// How much of each end is decoded.
    static let windowSeconds = 20.0
    static let silenceDBFS = -60.0
    static let loudnessSeconds = 10.0
    /// The tail is measured over the stretch a crossfade covers (the default overlap). Gating drops blocks 10 LU under the mean, so over
    /// a longer window the body of the ending outweighs a fade-out and the handover would be matched to a level that is no longer playing.
    static let tailLoudnessSeconds = TransitionSettings().seconds
    /// Each end is held as Float while it is analysed; this caps that at about 32 MB for stereo, even at extreme rates.
    static let maxWindowFrames = 4_000_000

    static func analyze(path: String, cancelled: () -> Bool = { false }) -> EdgeProfile? {
        guard !Player.isStreamURL(path) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext != "dsf", ext != "dff", let f = try? openLossless(path: path) else { return nil }
        return analyze(source: f, cancelled: cancelled)
    }

    /// Decodes the first and last `windowSeconds` of `source` (in its own rate) and describes them. Never runs on the audio thread.
    static func analyze(source: FrameSource, cancelled: () -> Bool = { false }) -> EdgeProfile? {
        let info = source.info
        let total = Int(info.totalFrames), ch = info.channels, rate = info.sampleRate
        guard total > 0, ch > 0, rate > 0, info.sourceBits != 1, !info.isLive, !info.isDoP else { return nil }
        let w = max(1, min(Int(windowSeconds * rate), total, maxWindowFrames))
        guard let head = read(source, from: 0, frames: w, cancelled: cancelled),
              let tail = read(source, from: total - w, frames: w, cancelled: cancelled) else { return nil }

        // 10 ms blocks, level = the loudest channel's RMS
        let blk = max(1, Int(rate / 100))
        func levels(_ x: [Float], frames n: Int) -> [Double] {
            var out: [Double] = []; out.reserveCapacity(n / blk + 1)
            var f = 0
            while f < n {
                let m = min(blk, n - f)
                var best = 0.0
                for c in 0..<ch {
                    var s: Float = 0
                    x.withUnsafeBufferPointer { p in vDSP_svesq(p.baseAddress! + f * ch + c, vDSP_Stride(ch), &s, vDSP_Length(m)) }
                    best = max(best, Double(s) / Double(m))
                }
                out.append(best > 0 ? 10 * log10(best) : -200)
                f += m
            }
            return out
        }
        let hl = levels(head, frames: w), tl = levels(tail, frames: w)
        let blockSec = Double(blk) / rate
        guard let firstLoud = hl.firstIndex(where: { $0 > silenceDBFS }), let lastLoud = tl.lastIndex(where: { $0 > silenceDBFS }) else {
            // no music inside the windows: either a silent file or a very quiet one; report it without loudness
            return EdgeProfile(duration: info.duration, leadSilence: 0, trailSilence: 0, headLUFS: nil, tailLUFS: nil, tailFadeSeconds: nil)
        }
        let leadFrames = min(w, firstLoud * blk)
        let audibleEndInTail = min(w, (lastLoud + 1) * blk)              // frames into the tail window
        let trailFrames = w - audibleEndInTail

        let lf = min(Int(loudnessSeconds * rate), w - leadFrames)
        let headLUFS = loudness(head, from: leadFrames, frames: lf, channels: ch, rate: rate)
        let tf = min(Int(tailLoudnessSeconds * rate), audibleEndInTail)
        let tailLUFS = loudness(tail, from: audibleEndInTail - tf, frames: tf, channels: ch, rate: rate)

        let fade = fadeOut(Array(tl[0..<(lastLoud + 1)]), blockSeconds: blockSec)
        return EdgeProfile(duration: info.duration, leadSilence: Double(leadFrames) / rate, trailSilence: Double(trailFrames) / rate,
                           headLUFS: headLUFS, tailLUFS: tailLUFS, tailFadeSeconds: fade)
    }

    /// Length of a fade-out at the end of `levels` (10 ms block levels in dB, ending on the last audible block), or nil.
    /// A fade-out: the last second sits at least 12 dB below the body of the ending, the drop takes 2 s or more,
    /// and the level does not climb back on the way down.
    static func fadeOut(_ levels: [Double], blockSeconds: Double) -> Double? {
        // 0.5 s envelope
        let per = max(1, Int((0.5 / blockSeconds).rounded()))
        var env: [Double] = []
        var i = 0
        while i + per <= levels.count {
            let p = levels[i..<(i + per)].map { pow(10, $0 / 10) }.reduce(0, +) / Double(per)
            env.append(p > 0 ? 10 * log10(p) : -200)
            i += per
        }
        guard env.count >= 8 else { return nil }
        let body = env[0..<max(1, env.count * 2 / 5)].max()!
        let end = (env[env.count - 1] + env[env.count - 2]) / 2
        guard body - end >= 12 else { return nil }
        guard let top = env.lastIndex(where: { $0 >= body - 3 }) else { return nil }
        let falling = env[top...]
        var climbs = 0
        var prev = falling.first!
        for v in falling.dropFirst() { if v > prev + 3 { climbs += 1 }; prev = v }
        let seconds = Double(env.count - 1 - top) * 0.5
        return climbs <= 1 && seconds >= 2 ? seconds : nil
    }

    private static func loudness(_ x: [Float], from: Int, frames n: Int, channels: Int, rate: Double) -> Double? {
        guard n >= Int(0.4 * rate) else { return nil }
        let meter = R128Meter(sampleRate: rate, channels: channels)
        x.withUnsafeBufferPointer { p in
            var i = 0
            while i < n { let k = min(16_384, n - i); meter.feed(p.baseAddress! + (from + i) * channels, frames: k); i += k }
        }
        return meter.integrated()
    }

    private static func read(_ s: FrameSource, from: Int, frames n: Int, cancelled: () -> Bool) -> [Float]? {
        let ch = s.info.channels, chunk = 16_384
        var out = [Float](repeating: 0, count: n * ch)
        let ints = UnsafeMutablePointer<Int32>.allocate(capacity: chunk * ch)
        defer { ints.deallocate() }
        s.seek(to: Int64(from))
        var got = 0
        while got < n {
            if cancelled() { return nil }
            let k = s.read(into: ints, frames: min(chunk, n - got))
            if k == 0 { break }
            out.withUnsafeMutableBufferPointer { p in
                let dst = p.baseAddress! + got * ch
                vDSP_vflt32(ints, 1, dst, 1, vDSP_Length(k * ch))
                var scale: Float = 1 / 2_147_483_648
                vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(k * ch))
            }
            got += k
        }
        return out
    }
}

/// Keeps edge analyses on disk, keyed by path, modification time and size, and computes missing ones in the background.
final class EdgeCache: @unchecked Sendable {
    static let shared = EdgeCache(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Transitions", isDirectory: true))

    private struct Entry: Codable { var path: String; var mtime: Double; var size: Int; var profile: EdgeProfile }
    private let dir: URL
    private let lock = NSLock()
    private var memory: [String: EdgeProfile] = [:]
    private var inFlight = Set<String>()
    private let queue = DispatchQueue(label: "aureon.edges", qos: .utility)

    init(directory: URL) { dir = directory; try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    private func stamp(_ path: String) -> (mtime: Double, size: Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return ((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, (a[.size] as? Int) ?? 0)
    }

    private func file(for path: String) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return dir.appendingPathComponent(String(h, radix: 16) + ".json")
    }

    /// Streamed files have no stamp: they are remembered for this session only.
    private func key(_ path: String) -> String { stamp(path).map { "\(path)|\($0.mtime)|\($0.size)" } ?? "\(path)|remote" }

    func cached(path: String) -> EdgeProfile? {
        let k = key(path)
        lock.lock(); defer { lock.unlock() }
        if let m = memory[k] { return m }
        guard let st = stamp(path), let d = try? Data(contentsOf: file(for: path)), let e = try? JSONDecoder().decode(Entry.self, from: d),
              e.path == path, e.mtime == st.mtime, e.size == st.size, e.profile.version == EdgeProfile.currentVersion else { return nil }
        memory[k] = e.profile
        return e.profile
    }

    func store(_ p: EdgeProfile, path: String) {
        let k = key(path)
        lock.lock(); defer { lock.unlock() }
        memory[k] = p
        if let st = stamp(path), let d = try? JSONEncoder().encode(Entry(path: path, mtime: st.mtime, size: st.size, profile: p)) { try? d.write(to: file(for: path), options: .atomic) }
    }

    /// The profile of a file, from the cache when it is current, else computed now (blocking: background threads only).
    func profile(path: String, cancelled: () -> Bool = { false }) -> EdgeProfile? {
        if let c = cached(path: path) { return c }
        guard let p = EdgeAnalyzer.analyze(path: path, cancelled: cancelled) else { return nil }
        store(p, path: path)
        return p
    }

    /// Analyses the files that are not cached yet, one at a time at utility priority.
    func prefetch(paths: [String]) {
        for path in paths where !Player.isStreamURL(path) {
            lock.lock()
            let start = memory[key(path)] == nil && !inFlight.contains(path)
            if start { inFlight.insert(path) }
            lock.unlock()
            guard start else { continue }
            queue.async { [self] in
                _ = profile(path: path)
                lock.lock(); inFlight.remove(path); lock.unlock()
            }
        }
    }

    /// Blocks until every analysis started so far has finished (tests).
    func waitForPending() { queue.sync {} }
}

// MARK: - Planning one transition

struct TransitionInput {
    var rate: Double
    var outgoingFrames: Int
    var incomingFrames: Int
    var outgoing: EdgeProfile?
    var incoming: EdgeProfile?
    /// Gain already applied to each chain (ReplayGain), so the handover compares what is actually heard.
    var outgoingGainDB: Double = 0
    var incomingGainDB: Double = 0
}

/// One transition, in frames of the group's rate.
struct TransitionPlan: Equatable {
    var rate: Double
    var overlapFrames: Int
    /// Frame of the outgoing track where the overlap ends; anything after it (trailing silence) is left out.
    var outgoingEnd: Int
    /// First frame of the incoming track that is played (leading silence skipped).
    var incomingStart: Int
    var curve: TransitionCurve
    /// The outgoing track already fades out by itself: it is left at full level and the next one comes in underneath.
    var holdOutgoing: Bool
    /// The incoming track's level at the start of the overlap, relative to its own; eases to 0 dB by the end.
    var incomingLevelDB: Double

    var mixStart: Int { outgoingEnd - overlapFrames }
    var seconds: Double { Double(overlapFrames) / rate }

    var description: String {
        var s = String(format: "Crossfade %.1f s, %@", seconds, curve.title.lowercased())
        if holdOutgoing { s = String(format: "Crossfade %.1f s under the song's own fade-out", seconds) }
        if incomingLevelDB != 0 { s += String(format: ", next song eased in from %+.1f dB", incomingLevelDB) }
        let trimmed = Double(incomingStart) / rate
        if trimmed >= 0.05 { s += String(format: ", %.1f s of leading silence skipped", trimmed) }
        return s
    }
}

enum TransitionPlanner {
    static let minimumSeconds = 0.5
    /// An overlap never takes more than this share of either track.
    static let maxShare = 0.45

    static func plan(_ s: TransitionSettings, _ x: TransitionInput) -> TransitionPlan? {
        guard s.mode != .off, x.rate > 0, x.outgoingFrames > 0, x.incomingFrames > 0 else { return nil }
        let rate = x.rate
        var aEnd = x.outgoingFrames, bStart = 0
        if s.trimSilence, let a = x.outgoing { aEnd = max(1, x.outgoingFrames - Int(a.trailSilence * rate)) }
        if s.trimSilence, let b = x.incoming { bStart = max(0, min(x.incomingFrames - 1, Int(b.leadSilence * rate))) }
        let seconds = min(TransitionSettings.secondsRange.upperBound, max(TransitionSettings.secondsRange.lowerBound, s.seconds))
        var n = Int(seconds * rate)
        n = min(n, Int(maxShare * Double(min(aEnd, x.incomingFrames - bStart))))
        var hold = false
        if s.mode == .smart, let fade = x.outgoing?.tailFadeSeconds {
            hold = true
            n = min(n, Int(fade * rate))
        }
        guard n >= Int(minimumSeconds * rate) else { return nil }
        var level = 0.0
        if s.matchLevels, let ta = x.outgoing?.tailLUFS, let hb = x.incoming?.headLUFS {
            let diff = (ta + x.outgoingGainDB) - (hb + x.incomingGainDB)
            let m = max(0, s.maxMatchDB)
            level = max(-m, min(m / 2, diff))
            if abs(level) < 0.5 { level = 0 }
            level = (level * 10).rounded() / 10
        }
        return TransitionPlan(rate: rate, overlapFrames: n, outgoingEnd: aEnd, incomingStart: bStart, curve: s.curve, holdOutgoing: hold, incomingLevelDB: level)
    }
}

// MARK: - The mixer

/// Produces exactly `plan.overlapFrames` frames: the outgoing source from its current position, the incoming one from its current
/// position, each under its gain curve, summed in Double. Producer thread only; every buffer is allocated once, in `init`.
///
/// Peak guard: two loud songs can sum above full scale (equal power gives +3 dB on identical material). Each block's needed gain is
/// known before it is handed out because the mixer works one block ahead; the gain ramps linearly between block boundaries and each
/// boundary takes the smaller of the two neighbouring blocks' needs, so no sample exceeds full scale and the gain never steps.
final class TransitionMixer: FrameSource {
    let info: StreamInfo
    let plan: TransitionPlan
    private let a: FrameSource, b: FrameSource
    private let ch: Int
    static let block = 4096
    private var mixed = 0
    private var cur: UnsafeMutablePointer<Double>, nxt: UnsafeMutablePointer<Double>
    private let ia: UnsafeMutablePointer<Int32>, ib: UnsafeMutablePointer<Int32>
    private var curN = 0, curPos = 0, nxtN = 0, nxtNeed = 1.0
    private var gStart = 1.0, gEnd = 1.0, primed = false, first = true
    /// Number of blocks the peak guard had to turn down (tests, diagnostics).
    private(set) var guardedBlocks = 0

    init(outgoing: FrameSource, incoming: FrameSource, plan: TransitionPlan, info outInfo: StreamInfo) {
        a = outgoing; b = incoming; self.plan = plan
        ch = outInfo.channels
        var i = outInfo; i.transparent = false; i.totalFrames = Int64(plan.overlapFrames)
        info = i
        cur = .allocate(capacity: Self.block * ch); nxt = .allocate(capacity: Self.block * ch)
        ia = .allocate(capacity: Self.block * ch); ib = .allocate(capacity: Self.block * ch)
    }
    deinit { cur.deallocate(); nxt.deallocate(); ia.deallocate(); ib.deallocate() }

    /// Not seekable: the player rebuilds the chain instead of seeking inside an overlap.
    func seek(to frame: Int64) {}

    func read(into dst: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var out = 0
        while out < frames {
            if curPos >= curN { if !nextBlock() { break } }
            let take = min(frames - out, curN - curPos)
            let span = gEnd - gStart, n = Double(curN)
            for f in 0..<take {
                let i = curPos + f
                let g = gStart + span * Double(i + 1) / n
                for c in 0..<ch {
                    let v = (cur[i * ch + c] * g * 2_147_483_648).rounded()
                    dst[(out + f) * ch + c] = v >= 2_147_483_647 ? .max : (v <= -2_147_483_648 ? .min : Int32(v))
                }
            }
            curPos += take; out += take
        }
        return out
    }

    private func nextBlock() -> Bool {
        if !primed { primed = true; nxtN = render(into: nxt); nxtNeed = need(nxt, nxtN) }
        guard nxtN > 0 else { return false }
        let t = cur; cur = nxt; nxt = t
        curN = nxtN; curPos = 0
        let curNeed = nxtNeed
        nxtN = render(into: nxt)
        nxtNeed = nxtN > 0 ? need(nxt, nxtN) : 1
        let end = min(curNeed, nxtNeed)
        gStart = first ? end : gEnd
        gEnd = end
        first = false
        if curNeed < 1 { guardedBlocks += 1 }
        return true
    }

    /// Gain that keeps this block at or below full scale.
    private func need(_ x: UnsafeMutablePointer<Double>, _ n: Int) -> Double {
        guard n > 0 else { return 1 }
        var m = 0.0
        vDSP_maxmgvD(x, 1, &m, vDSP_Length(n * ch))
        return m > 1 ? 1 / m : 1
    }

    private func fill(_ s: FrameSource, _ buf: UnsafeMutablePointer<Int32>, _ n: Int) {
        var got = 0
        while got < n {
            let k = s.read(into: buf + got * ch, frames: n - got)
            if k == 0 { break }
            got += k
        }
        if got < n { (buf + got * ch).update(repeating: 0, count: (n - got) * ch) }
    }

    private func render(into dst: UnsafeMutablePointer<Double>) -> Int {
        let n = min(Self.block, plan.overlapFrames - mixed)
        guard n > 0 else { return 0 }
        fill(a, ia, n); fill(b, ib, n)
        let total = Double(plan.overlapFrames), scale = 1 / 2_147_483_648.0
        for f in 0..<n {
            let t = (Double(mixed + f) + 0.5) / total
            var (ga, gb) = plan.curve.gains(t)
            if plan.holdOutgoing { ga = 1 }
            if plan.incomingLevelDB != 0 {
                let ease = t * t * (3 - 2 * t)
                gb *= pow(10, plan.incomingLevelDB * (1 - ease) / 20)
            }
            ga *= scale; gb *= scale
            for c in 0..<ch {
                let k = f * ch + c
                dst[k] = Double(ia[k]) * ga + Double(ib[k]) * gb
            }
        }
        mixed += n
        return n
    }
}

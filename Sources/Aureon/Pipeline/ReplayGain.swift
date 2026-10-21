import Foundation
import AVFoundation

// ReplayGain: tag reading, loudness measurement (ITU-R BS.1770-4 / EBU R128) and gain resolution.
// Leveling changes sample values, so a stream with gain applied is no longer marked bit-transparent.

enum ReplayGainMode: String, Codable, CaseIterable, Identifiable {
    case off, track, album
    var id: String { rawValue }
    var title: String { switch self { case .off: "Off (bit-perfect)"; case .track: "Track gain"; case .album: "Album gain" } }
}

struct ReplayGainSettings: Equatable, Codable {
    var mode: ReplayGainMode = .off
    var preampDB: Double = 0
    /// Lower the gain so that the tagged (or measured) peak never exceeds full scale.
    var preventClipping = true
    /// Measure loudness for files that carry no ReplayGain tags.
    var analyzeUntagged = true
    /// Target loudness for measured files. ReplayGain 2.0 uses −18 LUFS.
    var referenceLUFS: Double = -18
}

struct ReplayGainTags: Equatable, Codable {
    var trackGain: Double?, trackPeak: Double?, albumGain: Double?, albumPeak: Double?
    var isEmpty: Bool { trackGain == nil && albumGain == nil }
}

struct ReplayGainResult: Equatable {
    var linear: Double
    var appliedDB: Double
    var origin: String            // "tag", "measured", "none"
    var limitedByPeak: Bool
}

enum ReplayGainReader {
    /// "-7.12 dB", "+3.4dB", "0.98" …
    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let scanner = Scanner(string: t); scanner.charactersToBeSkipped = nil
        return scanner.scanDouble()
    }

    static func apply(key: String, value: String, to tags: inout ReplayGainTags) {
        switch key.uppercased() {
        case "REPLAYGAIN_TRACK_GAIN": tags.trackGain = number(value)
        case "REPLAYGAIN_TRACK_PEAK": tags.trackPeak = number(value)
        case "REPLAYGAIN_ALBUM_GAIN": tags.albumGain = number(value)
        case "REPLAYGAIN_ALBUM_PEAK": tags.albumPeak = number(value)
        default: break
        }
    }

    /// FLAC: parse the Vorbis-comment metadata block directly (synchronous, no AVFoundation).
    static func readFLAC(path: String) -> ReplayGainTags? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        var tags = ReplayGainTags()
        while let h = try? fh.read(upToCount: 4), h.count == 4 {
            let last = h[0] & 0x80 != 0, type = h[0] & 0x7f
            let len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            if type == 4, let block = try? fh.read(upToCount: len), block.count == len {
                var p = 0
                func u32() -> Int? { guard p + 4 <= block.count else { return nil }; defer { p += 4 }
                    return Int(block[p]) | Int(block[p + 1]) << 8 | Int(block[p + 2]) << 16 | Int(block[p + 3]) << 24 }
                guard let vlen = u32() else { break }
                p += vlen
                guard let count = u32() else { break }
                for _ in 0..<count {
                    guard let l = u32(), p + l <= block.count else { break }
                    if let s = String(data: block[p..<(p + l)], encoding: .utf8), let eq = s.firstIndex(of: "=") {
                        apply(key: String(s[..<eq]), value: String(s[s.index(after: eq)...]), to: &tags)
                    }
                    p += l
                }
            } else {
                if let off = try? fh.offset() { try? fh.seek(toOffset: off + UInt64(len)) }
            }
            if last { break }
        }
        return tags
    }

    /// Everything else (ALAC/M4A iTunes freeform atoms, ID3 TXXX, …) through AVFoundation.
    static func readAVFoundation(url: URL) -> ReplayGainTags {
        final class Box: @unchecked Sendable { var tags = ReplayGainTags() }
        let box = Box(), sem = DispatchSemaphore(value: 0)
        Task.detached {
            let asset = AVURLAsset(url: url)
            var items = (try? await asset.load(.metadata)) ?? []
            for f in (try? await asset.load(.availableMetadataFormats)) ?? [] {
                items += (try? await asset.loadMetadata(for: f)) ?? []
            }
            for it in items {
                guard let value = try? await it.load(.stringValue) else { continue }
                let ident: String = (it.identifier?.rawValue ?? "").uppercased()
                var info = ""
                if let v = it.extraAttributes?[AVMetadataExtraAttributeKey(rawValue: "info")] as? String { info = v.uppercased() }
                let keys: [String] = ["REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_ALBUM_PEAK"]
                for key in keys where ident.contains(key) || info == key { apply(key: key, value: value, to: &box.tags) }
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return box.tags
    }

    static func read(path: String) -> ReplayGainTags {
        if path.lowercased().hasSuffix(".flac"), let t = readFLAC(path: path) { return t }
        return readAVFoundation(url: URL(fileURLWithPath: path))
    }
}

// MARK: - Loudness (ITU-R BS.1770-4)

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0
    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) { self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2 }
    mutating func process(_ x: Double) -> Double {      // transposed direct form II
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

enum Loudness {
    /// K-weighting (pre-filter shelf + RLB high-pass), derived for any sample rate.
    static func kWeighting(sampleRate fs: Double) -> (Biquad, Biquad) {
        let f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
        var K = tan(Double.pi * f0 / fs)
        let Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        let shelf = Biquad(b0: (Vh + Vb * K / Q + K * K) / a0, b1: 2 * (K * K - Vh) / a0, b2: (Vh - Vb * K / Q + K * K) / a0,
                           a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0)
        let f1 = 38.13547087602444, Q1 = 0.5003270373238773
        K = tan(Double.pi * f1 / fs)
        a0 = 1 + K / Q1 + K * K
        let rlb = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q1 + K * K) / a0)
        return (shelf, rlb)
    }

    /// Integrated loudness from per-100 ms sub-block weighted energies (4 sub-blocks = one 400 ms gating block).
    static func integrated(subBlocks e: [Double]) -> Double? {
        guard e.count >= 4 else { return nil }
        var blocks: [Double] = []
        for i in 0...(e.count - 4) { blocks.append((e[i] + e[i + 1] + e[i + 2] + e[i + 3]) / 4) }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        let abs = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !abs.isEmpty else { return nil }
        let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lufs($0) > rel }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Integrated loudness (LUFS) and sample peak (linear) of a file.
    static func analyze(path: String, cancelled: () -> Bool = { false }) -> (lufs: Double, peak: Double)? {
        guard let f = try? LosslessFile(path: path), f.info.totalFrames > 0 else { return nil }
        let ch = f.info.channels, fs = f.info.sampleRate, hop = Int(fs / 10)
        var filters = (0..<ch).map { _ in kWeighting(sampleRate: fs) }
        let weights: [Double] = (0..<ch).map { c in ch == 6 ? (c == 3 ? 0 : (c >= 4 ? 1.41 : 1)) : 1 }   // 5.1: skip LFE, surround +1.5 dB
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: hop * ch)
        defer { buf.deallocate() }
        var energies: [Double] = [], peak = 0.0
        while true {
            if cancelled() { return nil }
            let n = f.read(into: buf, frames: hop)
            if n == 0 { break }
            var sums = [Double](repeating: 0, count: ch)
            for i in 0..<n { for c in 0..<ch {
                let x = Double(buf[i * ch + c]) / 2_147_483_648.0
                peak = max(peak, Swift.abs(x))
                let y = filters[c].1.process(filters[c].0.process(x))
                sums[c] += y * y
            } }
            if n == hop { energies.append((0..<ch).reduce(0.0) { $0 + weights[$1] * sums[$1] / Double(n) }) }
        }
        guard let l = integrated(subBlocks: energies) else { return nil }
        return (l, peak)
    }
}

// MARK: - Resolution

/// Caches tags and measurements per file and resolves the gain to apply.
final class ReplayGainStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tags: [String: ReplayGainTags] = [:]
    private var measured: [String: (lufs: Double, peak: Double)] = [:]
    private var inFlight = Set<String>()

    func tags(for path: String) -> ReplayGainTags {
        lock.lock(); let c = tags[path]; lock.unlock()
        if let c { return c }
        let t = ReplayGainReader.read(path: path)
        lock.lock(); tags[path] = t; lock.unlock()
        return t
    }

    func measurement(for path: String, computeIfMissing: Bool) -> (lufs: Double, peak: Double)? {
        lock.lock(); let c = measured[path]; lock.unlock()
        if let c { return c }
        guard computeIfMissing, let m = Loudness.analyze(path: path) else { return nil }
        lock.lock(); measured[path] = m; lock.unlock()
        return m
    }

    /// Warms the cache on a background queue so opening the track later does not stall the producer.
    func prefetch(paths: [String], settings: ReplayGainSettings) {
        guard settings.mode != .off else { return }
        for p in paths {
            lock.lock(); let busy = inFlight.contains(p) || measured[p] != nil; if !busy { inFlight.insert(p) }; lock.unlock()
            if busy { continue }
            DispatchQueue.global(qos: .utility).async { [self] in
                let t = tags(for: p)
                if t.isEmpty && settings.analyzeUntagged { _ = measurement(for: p, computeIfMissing: true) }
                lock.lock(); inFlight.remove(p); lock.unlock()
            }
        }
    }

    func resolve(path: String, settings s: ReplayGainSettings, allowMeasuring: Bool) -> ReplayGainResult {
        guard s.mode != .off else { return ReplayGainResult(linear: 1, appliedDB: 0, origin: "none", limitedByPeak: false) }
        let t = tags(for: path)
        var gain: Double?, peak: Double?, origin = "none"
        if s.mode == .album { gain = t.albumGain ?? t.trackGain; peak = t.albumGain != nil ? t.albumPeak : t.trackPeak }
        else { gain = t.trackGain ?? t.albumGain; peak = t.trackGain != nil ? t.trackPeak : t.albumPeak }
        if gain != nil { origin = "tag" }
        else if s.analyzeUntagged, let m = measurement(for: path, computeIfMissing: allowMeasuring) {
            gain = s.referenceLUFS - m.lufs; peak = m.peak; origin = "measured"
        }
        guard let g = gain else { return ReplayGainResult(linear: 1, appliedDB: 0, origin: "none", limitedByPeak: false) }
        var lin = pow(10, (g + s.preampDB) / 20), limited = false
        if s.preventClipping, let p = peak, p > 0, lin * p > 1 { lin = 1 / p; limited = true }
        return ReplayGainResult(linear: lin, appliedDB: 20 * log10(lin), origin: origin, limitedByPeak: limited)
    }
}

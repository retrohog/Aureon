import Foundation

/// A compact picture of a whole track's loudness over time, for the waveform scrubber: per column, the sample peak and the RMS level.
/// Values are linear (full scale = 1) and stored as bytes, so an overview is about a kilobyte and cheap to keep and draw.
struct WaveformOverview: Equatable, Sendable {
    static let defaultBuckets = 480

    /// 0…255 = 0…full scale, left to right across the whole track.
    var peak: [UInt8]
    /// 0…255 = 0…full scale. Empty when only peaks are known (an overview borrowed from the DJ analysis).
    var rms: [UInt8]
    var duration: Double

    var count: Int { peak.count }
    var isEmpty: Bool { peak.isEmpty }

    /// One drawable column: heights 0…1, already normalised to the loudest moment of the track and lifted a little so quiet passages stay visible.
    struct Column: Equatable { var peak: Float; var rms: Float }

    /// Resamples to `n` columns: the loudest peak in each span (so no transient disappears) and the power average of the RMS values.
    func columns(_ n: Int) -> [Column] {
        guard n > 0, !peak.isEmpty else { return [] }
        let top = Float(max(peak.max() ?? 1, 1))
        let hasRMS = rms.count == peak.count
        var out = [Column](); out.reserveCapacity(n)
        for i in 0..<n {
            let lo = i * peak.count / n, hi = max(lo + 1, (i + 1) * peak.count / n)
            var p: UInt8 = 0, power: Float = 0
            for k in lo..<min(hi, peak.count) {
                p = max(p, peak[k])
                if hasRMS { let r = Float(rms[k]); power += r * r }
            }
            let span = Float(min(hi, peak.count) - lo)
            let pk = Self.lift(Float(p) / top)
            let r = hasRMS ? Self.lift((power / max(span, 1)).squareRoot() / top) : pk * 0.62
            out.append(Column(peak: pk, rms: min(pk, r)))
        }
        return out
    }

    /// A gentle curve (x^0.75) so a quiet intro is still a visible shape, without flattening the loud parts.
    static func lift(_ x: Float) -> Float { x <= 0 ? 0 : min(1, Float(pow(Double(x), 0.75))) }

    // MARK: storage

    private static let magic = Data("AWF1".utf8)

    func encoded() -> Data {
        var d = Self.magic
        var n = UInt32(peak.count).littleEndian, flags = UInt32(rms.count == peak.count ? 1 : 0).littleEndian, dur = duration.bitPattern.littleEndian
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &dur) { d.append(contentsOf: $0) }
        d.append(contentsOf: peak)
        if rms.count == peak.count { d.append(contentsOf: rms) }
        return d
    }

    init(peak: [UInt8], rms: [UInt8], duration: Double) { self.peak = peak; self.rms = rms; self.duration = duration }

    init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 20, Data(b[0..<4]) == Self.magic else { return nil }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        let n = Int(u32(4)), hasRMS = u32(8) == 1
        var bits: UInt64 = 0
        for k in 0..<8 { bits |= UInt64(b[12 + k]) << (8 * UInt64(k)) }
        let body = 20, need = body + n * (hasRMS ? 2 : 1)
        guard n > 0, n <= 100_000, b.count == need else { return nil }
        peak = Array(b[body..<(body + n)])
        rms = hasRMS ? Array(b[(body + n)..<need]) : []
        duration = Double(bitPattern: bits)
        guard duration.isFinite, duration >= 0 else { return nil }
    }
}

enum WaveformBuilder {
    /// Whether a path can have a waveform: a local file that the lossless decoder opens. Streams, cloud tracks (which would have to be
    /// downloaded whole) and DSD files are left out; the scrubber then draws a plain line.
    static func supports(path: String) -> Bool {
        guard !path.isEmpty, !RemoteMedia.isRemote(path), !path.contains("://") else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !["dsf", "dff"].contains(ext) else { return false }
        return FileManager.default.isReadableFile(atPath: path)
    }

    /// Decodes the file once, start to end, and measures each column. Runs on a background task; never on the main or audio threads.
    static func build(path: String, buckets: Int = WaveformOverview.defaultBuckets, cancelled: () -> Bool = { false }) -> WaveformOverview? {
        guard supports(path: path), buckets > 0, let f = try? LosslessFile(path: path) else { return nil }
        let ch = max(1, f.info.channels), total = Int(f.info.totalFrames)
        guard total > 0 else { return nil }
        var peaks = [UInt32](repeating: 0, count: buckets)
        var power = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        let block = 16_384
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: block * ch); defer { buf.deallocate() }
        let scale = 1.0 / 2_147_483_648.0
        var frame = 0
        while true {
            if cancelled() { return nil }
            let n = f.read(into: buf, frames: block)
            if n == 0 { break }
            var i = 0
            while i < n {
                // the reported length can be a little short for some encoders: anything past it lands in the last column
                let b = min(buckets - 1, (frame + i) * buckets / total)
                let end = min(n, ((b + 1) * total + buckets - 1) / buckets - frame)
                let stop = b == buckets - 1 ? n : max(i + 1, end)
                var pk = peaks[b], sq = 0.0
                for k in i..<stop {
                    var frameSq = 0.0
                    for c in 0..<ch {
                        let v = buf[k * ch + c]
                        pk = max(pk, v.magnitude)
                        let x = Double(v) * scale
                        frameSq += x * x
                    }
                    sq += frameSq / Double(ch)
                }
                peaks[b] = pk; power[b] += sq; counts[b] += stop - i
                i = stop
            }
            frame += n
        }
        guard frame > 0 else { return nil }
        let p = peaks.map { UInt8(min(255, (Double($0) / 2_147_483_648.0 * 255).rounded())) }
        let r = (0..<buckets).map { k -> UInt8 in
            counts[k] > 0 ? UInt8(min(255, ((power[k] / Double(counts[k])).squareRoot() * 255).rounded())) : 0
        }
        let rate = f.info.sampleRate
        return WaveformOverview(peak: p, rms: r, duration: rate > 0 ? Double(frame) / rate : f.info.duration)
    }

    /// The DJ console's analysis already holds a peak overview; borrowing it saves decoding the file a second time.
    static func borrow(_ a: DJTrackAnalysis, buckets: Int = WaveformOverview.defaultBuckets) -> WaveformOverview? {
        guard !a.peaks.isEmpty else { return nil }
        let n = min(buckets, a.peaks.count)
        var out = [UInt8](); out.reserveCapacity(n)
        for i in 0..<n {
            let lo = i * a.peaks.count / n, hi = max(lo + 1, (i + 1) * a.peaks.count / n)
            var p: Float = 0
            for k in lo..<min(hi, a.peaks.count) { p = max(p, a.peaks[k]) }
            out.append(UInt8(min(255, max(0, (p * 255).rounded()))))
        }
        return WaveformOverview(peak: out, rms: [], duration: a.duration)
    }
}

/// Finished overviews on disk and in memory, keyed by path, modification time and size, so a track is decoded for its waveform only once.
final class WaveformCache: @unchecked Sendable {
    static let shared = WaveformCache(directory: WaveformCache.defaultDirectory)
    static var defaultDirectory: URL {
        if ProcessInfo.processInfo.environment["AUREON_TESTING"] != nil { return tempDirectory("aureon-waveforms") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Waveforms", isDirectory: true)
    }
    private static func tempDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    let directory: URL
    let memoryLimit: Int
    private let lock = NSLock()
    private var memory: [String: WaveformOverview] = [:]
    private var order: [String] = []

    init(directory: URL, memoryLimit: Int = 96) {
        self.directory = directory; self.memoryLimit = memoryLimit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func key(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, size = (a[.size] as? Int) ?? 0
        return "\(path)|\(mtime)|\(size)"
    }

    private func file(_ key: String) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return directory.appendingPathComponent(String(h, radix: 16) + ".awf")
    }

    private func remember(_ k: String, _ o: WaveformOverview) {
        if memory.updateValue(o, forKey: k) == nil { order.append(k) }
        while order.count > memoryLimit { memory[order.removeFirst()] = nil }
    }

    /// The stored overview if the file has not changed since it was made. The file on disk carries its own key, so a hash collision can never
    /// hand back another track's waveform.
    func cached(path: String) -> WaveformOverview? {
        guard let k = key(path) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let o = memory[k] { return o }
        guard let d = try? Data(contentsOf: file(k)), let nl = d.firstIndex(of: 0x0A),
              String(decoding: d[d.startIndex..<nl], as: UTF8.self) == k, let o = WaveformOverview(data: d[(nl + 1)...]) else { return nil }
        remember(k, o)
        return o
    }

    func store(_ o: WaveformOverview, path: String) {
        guard let k = key(path) else { return }
        lock.lock(); defer { lock.unlock() }
        remember(k, o)
        var d = Data(k.utf8); d.append(0x0A); d.append(o.encoded())
        try? d.write(to: file(k), options: .atomic)
    }

    /// The overview for a file: from memory, from disk, borrowed from a finished DJ analysis, or decoded now.
    func overview(path: String, cancelled: () -> Bool = { false }) -> WaveformOverview? {
        if let c = cached(path: path) { return c }
        guard WaveformBuilder.supports(path: path) else { return nil }
        if let dj = AnalysisCache.shared.cached(path: path), let o = WaveformBuilder.borrow(dj) { return o }
        guard let o = WaveformBuilder.build(path: path, cancelled: cancelled) else { return nil }
        store(o, path: path)
        return o
    }
}

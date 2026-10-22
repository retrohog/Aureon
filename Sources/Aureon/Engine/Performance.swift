import Foundation
import Darwin

/// What this Mac can sustain. The heaviest things the engine does are resampling up to hundreds of kHz and converting DSD512 / DSD1024 to PCM: both
/// produce or consume tens of millions of samples a second. The profile measures how fast this machine does them (a fraction of a second, once, in the
/// background), and the player uses the result to size its buffers, to keep a request inside what the CPU can deliver, and to say so when it does.
struct PerformanceProfile: Codable, Equatable {
    var architecture: String
    var model: String
    var cores: Int
    var memoryBytes: UInt64
    /// Output frames per second of the polyphase resampler (stereo).
    var outFramesPerSecond: Double
    /// DSD input bits per second (all channels) through the multi-stage converter.
    var dsdBitsPerSecond: Double

    enum Tier: String, Codable { case high, medium, low }

    /// How many times faster than real time the machine runs the resampler at `rate`.
    func resampleFactor(rate: Double, channels: Int) -> Double { outFramesPerSecond / max(1, rate * Double(max(1, channels)) / 2) }
    func dsdFactor(dsdRate: Double, channels: Int) -> Double { dsdBitsPerSecond / max(1, dsdRate * Double(max(1, channels))) }

    /// Keep this much headroom: a stream that decodes at 2× real time never runs dry, even while the system is busy elsewhere.
    static let safetyFactor = 2.0

    var tier: Tier {
        let f = resampleFactor(rate: 1_536_000, channels: 2)
        return f >= 4 ? .high : (f >= 2 ? .medium : .low)
    }

    func canResample(to rate: Double, channels: Int) -> Bool { resampleFactor(rate: rate, channels: channels) >= Self.safetyFactor }
    func canDecodeDSD(rate: Double, channels: Int) -> Bool { dsdFactor(dsdRate: rate, channels: channels) >= Self.safetyFactor }

    /// `rate`, or the highest rate below it (halving) that this machine can resample to with headroom.
    func capped(_ rate: Double, channels: Int, floor: Double) -> Double {
        var r = rate
        while r > floor + 0.5 && !canResample(to: r, channels: channels) { r /= 2 }
        return max(r, floor)
    }

    /// Seconds of audio the ring holds: more at extreme rates on machines with less to spare.
    func bufferSeconds(base: Double, rate: Double, channels: Int) -> Double {
        var s = base
        switch tier {
        case .high: break
        case .medium: if rate >= 700_000 { s = base * 1.5 }
        case .low: if rate >= 350_000 { s = base * 2 } else if rate >= 190_000 { s = base * 1.4 }
        }
        return min(s, max(base, 12))
    }

    /// How much must be decoded ahead before the output starts.
    func prefillSeconds(rate: Double) -> Double {
        if rate <= 192_000 { return 0.05 }
        switch tier { case .high: return 0.25; case .medium: return 0.5; case .low: return 1.0 }
    }

    /// The ring's size in frames, kept inside a share of the memory (an 8-channel 1.5 MHz stream is a lot of bytes).
    func ringFrames(rate: Double, channels: Int, seconds: Double) -> Int {
        let wanted = Int(rate * seconds)
        let budget = Int(min(UInt64(1) << 30, memoryBytes / 6))
        return max(8192, min(wanted, budget / (max(1, channels) * 4)))
    }

    var summary: String {
        let f = resampleFactor(rate: 1_536_000, channels: 2)
        return "\(model) · \(cores) cores · \(String(format: "%.0f", Double(memoryBytes) / 1_073_741_824)) GB · resampling to 1536 kHz at \(String(format: "%.1f", f))× real time"
    }

    // MARK: measuring

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Runs the two benchmarks (about a third of a second).
    static func measure() -> PerformanceProfile {
        let brand = sysctlString("machdep.cpu.brand_string")
        // 1. resampler: 0.3 s of stereo 44.1 kHz → 352.8 kHz
        let n = 13_230
        let tone = (0..<2).map { c in (0..<n).map { Float(0.5 * sin(2 * Double.pi * (1000 + Double(c) * 300) * Double($0) / 44_100)) } }
        var framesPerSecond = 0.0
        if let r = ResamplingSource(BenchmarkSource(tone, rate: 44_100), outRate: 352_800, config: .standard) {
            let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 8192 * 2); defer { buf.deallocate() }
            let t0 = CFAbsoluteTimeGetCurrent(); var frames = 0
            while true { let k = r.read(into: buf, frames: 8192); if k == 0 { break }; frames += k }
            framesPerSecond = Double(frames) / max(1e-6, CFAbsoluteTimeGetCurrent() - t0)
        }
        // 2. DSD: 0.15 s of DSD256, two channels, to 176.4 kHz
        var bitsPerSecond = 0.0
        let bytes = 11_289_600 * 15 / 100 / 8 / 4096 * 4096
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aureon-perf-\(getpid()).dsf")
        var x: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> UInt8 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return UInt8(truncatingIfNeeded: x) }
        writeDSFFile(url, rate: 11_289_600, channelBytes: (0..<2).map { _ in (0..<bytes).map { _ in rnd() } })
        if let c = try? DsdContainer(path: url.path), let s = FastDsdToPcmSource(c, codec: "DSD256", pcmRate: 176_400, gainDB: 0) {
            let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * 2); defer { buf.deallocate() }
            let t0 = CFAbsoluteTimeGetCurrent()
            while s.read(into: buf, frames: 4096) > 0 {}
            bitsPerSecond = Double(bytes * 8 * 2) / max(1e-6, CFAbsoluteTimeGetCurrent() - t0)
        }
        try? FileManager.default.removeItem(at: url)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return PerformanceProfile(architecture: arch, model: brand.isEmpty ? arch : brand, cores: ProcessInfo.processInfo.activeProcessorCount,
                                  memoryBytes: ProcessInfo.processInfo.physicalMemory, outFramesPerSecond: framesPerSecond, dsdBitsPerSecond: bitsPerSecond)
    }

    /// What to assume before the measurement has finished (or when it failed): a cautious figure for each architecture.
    static var fallback: PerformanceProfile {
        #if arch(arm64)
        return PerformanceProfile(architecture: "arm64", model: "Apple Silicon", cores: ProcessInfo.processInfo.activeProcessorCount, memoryBytes: ProcessInfo.processInfo.physicalMemory, outFramesPerSecond: 6_000_000, dsdBitsPerSecond: 400_000_000)
        #else
        return PerformanceProfile(architecture: "x86_64", model: "Intel", cores: ProcessInfo.processInfo.activeProcessorCount, memoryBytes: ProcessInfo.processInfo.physicalMemory, outFramesPerSecond: 1_800_000, dsdBitsPerSecond: 120_000_000)
        #endif
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: PerformanceProfile?

    /// Tests substitute a machine of their own.
    nonisolated(unsafe) static var testOverride: PerformanceProfile?

    /// The measured profile if it is ready, else the cautious fallback. Never blocks.
    static var ready: PerformanceProfile { lock.lock(); defer { lock.unlock() }; return testOverride ?? stored ?? fallback }

    /// The measured profile, measuring now if needed (once per machine and macOS version; the result is kept in the user defaults).
    static var current: PerformanceProfile {
        lock.lock()
        if let o = testOverride { lock.unlock(); return o }
        if let s = stored { lock.unlock(); return s }
        lock.unlock()
        let key = "aureon.perf.\(sysctlString("machdep.cpu.brand_string")).\(ProcessInfo.processInfo.operatingSystemVersionString)"
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil, let d = defaults.data(forKey: key), let p = try? JSONDecoder().decode(PerformanceProfile.self, from: d), p.outFramesPerSecond > 0 {
            lock.lock(); stored = p; lock.unlock(); return p
        }
        let p = measure()
        if p.outFramesPerSecond > 0 {
            lock.lock(); stored = p; lock.unlock()
            if ProcessInfo.processInfo.environment["AUREON_TESTING"] == nil, let d = try? JSONEncoder().encode(p) { defaults.set(d, forKey: key) }
            return p
        }
        return fallback
    }

    /// Starts the measurement in the background so the player never waits for it.
    static func warmUp() { DispatchQueue.global(qos: .utility).async { _ = current } }
}

/// A minimal DSF writer for the benchmark (the test-support writer is not part of the app).
func writeDSFFile(_ url: URL, rate: Int, channelBytes: [[UInt8]]) {
    let ch = channelBytes.count, per = channelBytes[0].count, block = 4096
    func le(_ v: Int, _ n: Int) -> Data { Data((0..<n).map { UInt8((v >> (8 * $0)) & 255) }) }
    var data = Data(); data.reserveCapacity(per * ch)
    var pos = 0
    while pos < per {
        for c in 0..<ch {
            var blk = [UInt8](repeating: 0, count: block)
            let n = min(block, per - pos)
            for i in 0..<n { blk[i] = channelBytes[c][pos + i] }
            data += Data(blk)
        }
        pos += block
    }
    var h = Data("DSD ".utf8); h += le(28, 8); h += le(92 + data.count, 8); h += le(0, 8)
    h += Data("fmt ".utf8); h += le(52, 8); h += le(1, 4); h += le(0, 4); h += le(ch == 2 ? 2 : 1, 4); h += le(ch, 4)
    h += le(rate, 4); h += le(1, 4); h += le(per * 8, 8); h += le(block, 4); h += le(0, 4)
    h += Data("data".utf8); h += le(12 + data.count, 8)
    try? (h + data).write(to: url)
}

/// A short stereo test tone as a pipeline source, for the benchmark.
private final class BenchmarkSource: FrameSource {
    let samples: [[Float]]
    let info: StreamInfo
    private var pos = 0
    init(_ s: [[Float]], rate: Double) { samples = s; info = StreamInfo(sampleRate: rate, channels: s.count, sourceBits: 24, totalFrames: Int64(s[0].count), codec: "benchmark") }
    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let n = max(0, min(frames, samples[0].count - pos))
        for f in 0..<n { for c in 0..<samples.count { buf[f * samples.count + c] = Int32(max(-1, min(0.999999, samples[c][pos + f])) * 2_147_483_647) } }
        pos += n; return n
    }
    func seek(to frame: Int64) { pos = Int(frame) }
}

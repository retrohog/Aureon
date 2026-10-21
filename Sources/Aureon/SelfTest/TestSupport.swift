import Foundation

/// Temp directory per test run.
func tempDir(_ name: String = "aureon-tests") -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Writes an integer PCM WAV. `gen(frame, channel)` returns a sample in the range of `bits` (signed).
@discardableResult
func writeWAV(_ url: URL, rate: Int, bits: Int, channels: Int = 2, frames: Int, gen: (Int, Int) -> Int) -> URL {
    let bps = bits / 8
    var data = Data(capacity: frames * channels * bps)
    for f in 0..<frames { for c in 0..<channels {
        var v = gen(f, c)
        let lim = 1 << (bits - 1)
        v = max(-lim, min(lim - 1, v))
        for b in 0..<bps { data.append(UInt8(truncatingIfNeeded: v >> (8 * b))) }
    } }
    func le32(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
    func le16(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255)]) }
    var h = Data("RIFF".utf8); h += le32(36 + data.count); h += Data("WAVEfmt ".utf8); h += le32(16)
    h += le16(1) + le16(channels) + le32(rate) + le32(rate * channels * bps) + le16(channels * bps) + le16(bits)
    h += Data("data".utf8) + le32(data.count)
    try! (h + data).write(to: url)
    return url
}

func sineWAV(_ url: URL, rate: Int, bits: Int = 24, freq: Double, amp: Double, seconds: Double, channels: Int = 2) -> URL {
    let full = Double((1 << (bits - 1)) - 1)
    return writeWAV(url, rate: rate, bits: bits, channels: channels, frames: Int(Double(rate) * seconds)) { f, _ in
        Int((amp * full * sin(2 * Double.pi * freq * Double(f) / Double(rate))).rounded())
    }
}

/// Reads a whole source into Int32 interleaved.
func readAll(_ s: FrameSource) -> [Int32] {
    var out: [Int32] = []
    let ch = s.info.channels
    let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * ch)
    defer { buf.deallocate() }
    while true {
        let n = s.read(into: buf, frames: 4096)
        if n == 0 { break }
        out.append(contentsOf: UnsafeBufferPointer(start: buf, count: n * ch))
    }
    return out
}

/// Amplitude (linear, full scale = 1) of `freq` in one channel, measured with a Hann window evaluated exactly at `freq`
/// (no scalloping, and far-off tones leak below −100 dB so image/alias measurements are meaningful).
func amplitude(_ x: [Int32], channels: Int, channel: Int = 0, rate: Double, freq: Double, skip: Int = 0, count: Int? = nil) -> Double {
    let n = (x.count / channels) - skip
    let m = min(count ?? n, n)
    var re = 0.0, im = 0.0, wsum = 0.0
    for i in 0..<m {
        let w = 0.5 - 0.5 * cos(2 * Double.pi * (Double(i) + 0.5) / Double(m))
        let v = Double(x[(skip + i) * channels + channel]) / 2_147_483_648.0 * w
        let ph = 2 * Double.pi * freq * Double(skip + i) / rate
        re += v * cos(ph); im += v * sin(ph); wsum += w
    }
    return 2 * (re * re + im * im).squareRoot() / wsum
}

func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-300)) }

// MARK: - DSD writers

/// Second-order sigma-delta modulation of a sine. Returns packed bytes, MSB-first.
func dsdBytes(rate: Double, freq: Double, amp: Double, seconds: Double, seed: Int = 0) -> [UInt8] {
    let bits = Int(rate * seconds) / 8 * 8
    var out = [UInt8](repeating: 0, count: bits / 8)
    var i1 = 0.0, i2 = 0.0, y = 1.0
    for n in 0..<bits {
        let x = amp * sin(2 * Double.pi * freq * Double(n) / rate + Double(seed))
        i1 += x - y
        i2 += i1 - y
        y = i2 >= 0 ? 1.0 : -1.0
        if y > 0 { out[n / 8] |= 1 << UInt8(7 - n % 8) }
    }
    return out
}

func writeDSF(_ url: URL, rate: Int, channelBytes: [[UInt8]]) {
    let ch = channelBytes.count, per = channelBytes[0].count, block = 4096
    func le(_ v: Int, _ n: Int) -> Data { Data((0..<n).map { UInt8((v >> (8 * $0)) & 255) }) }
    var data = Data()
    var pos = 0
    while pos < per {
        for c in 0..<ch {
            var blk = [UInt8](repeating: 0, count: block)
            let n = min(block, per - pos)
            for i in 0..<n {                       // DSF stores bits LSB-first: reverse each byte
                var b = channelBytes[c][pos + i], r: UInt8 = 0
                for k in 0..<8 where (b >> k) & 1 == 1 { r |= 1 << UInt8(7 - k) }
                b = r; blk[i] = b
            }
            data += Data(blk)
        }
        pos += block
    }
    var h = Data("DSD ".utf8); h += le(28, 8); h += le(92 + data.count, 8); h += le(0, 8)
    h += Data("fmt ".utf8); h += le(52, 8); h += le(1, 4); h += le(0, 4); h += le(ch == 2 ? 2 : 1, 4); h += le(ch, 4)
    h += le(rate, 4); h += le(1, 4); h += le(per * 8, 8); h += le(block, 4); h += le(0, 4)
    h += Data("data".utf8); h += le(12 + data.count, 8)
    try! (h + data).write(to: url)
}

func writeDFF(_ url: URL, rate: Int, channelBytes: [[UInt8]]) {
    let ch = channelBytes.count, per = channelBytes[0].count
    func be(_ v: Int, _ n: Int) -> Data { Data((0..<n).map { UInt8((v >> (8 * (n - 1 - $0))) & 255) }) }
    var data = Data(capacity: per * ch)
    for i in 0..<per { for c in 0..<ch { data.append(channelBytes[c][i]) } }
    var prop = Data("SND ".utf8)
    prop += Data("FS  ".utf8) + be(4, 8) + be(rate, 4)
    prop += Data("CHNL".utf8) + be(2 + 4 * ch, 8) + be(ch, 2) + Data((0..<ch).flatMap { _ in Array("SLFT".utf8) })
    prop += Data("CMPR".utf8) + be(4 + 1 + 14, 8) + Data("DSD ".utf8) + Data([14]) + Data("not compressed".utf8)
    if prop.count % 2 == 1 { prop.append(0) }
    var body = Data("DSD ".utf8)
    body += Data("FVER".utf8) + be(4, 8) + be(0x01050000, 4)
    body += Data("PROP".utf8) + be(prop.count, 8) + prop
    body += Data("DSD ".utf8) + be(data.count, 8) + data
    try! (Data("FRM8".utf8) + be(body.count, 8) + body).write(to: url)
}

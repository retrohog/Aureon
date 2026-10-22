import Foundation

/// A FLAC encoder for live streams: blocks of PCM in, self-contained frames out. A client can join at any frame, because every frame
/// carries its own header and the stream header (`fLaC` + STREAMINFO, with the length marked unknown) is handed out per connection.
///
/// Subframes are CONSTANT, FIXED (orders 0–4, the polynomial predictors) or VERBATIM, with partitioned Rice (RICE2) residual coding:
/// not the very last percent of compression, but lossless, fast enough to run next to the audio engine on an old Intel Mac, and
/// simple enough to verify bit for bit against CoreAudio's decoder.
final class LiveFLACEncoder {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let blockSize: Int
    private var frameNumber = 0
    private var pending: [Int32] = []                  // interleaved, already reduced to `bitsPerSample`
    private(set) var framesEncoded = 0

    init(sampleRate: Int, channels: Int, bitsPerSample: Int, blockSize: Int = 4096) {
        precondition((1...8).contains(channels) && [16, 24].contains(bitsPerSample))
        self.sampleRate = sampleRate; self.channels = channels; self.bitsPerSample = bitsPerSample; self.blockSize = blockSize
        pending.reserveCapacity(blockSize * channels * 2)
    }

    // MARK: stream header

    var streamHeader: Data {
        var w = BitWriter()
        w.write(0x664C6143, 32)                        // "fLaC"
        w.write(1, 1); w.write(0, 7); w.write(34, 24)  // last metadata block, STREAMINFO, 34 bytes
        w.write(UInt64(blockSize), 16); w.write(UInt64(blockSize), 16)
        w.write(0, 24); w.write(0, 24)                 // frame sizes unknown
        w.write(UInt64(sampleRate), 20); w.write(UInt64(channels - 1), 3); w.write(UInt64(bitsPerSample - 1), 5)
        w.write(0, 36)                                 // total samples unknown
        w.write(0, 64); w.write(0, 64)                 // MD5 unknown
        return w.data
    }

    // MARK: feeding

    /// Adds interleaved 32-bit left-justified samples (as the audio engine delivers them) and returns every complete frame.
    func encode(_ samples: UnsafePointer<Int32>, frames n: Int) -> [Data] {
        let shift = Int32(32 - bitsPerSample)
        pending.reserveCapacity(pending.count + n * channels)
        for i in 0..<(n * channels) { pending.append(samples[i] >> shift) }
        var out: [Data] = []
        let per = blockSize * channels
        var start = 0
        while pending.count - start >= per {
            out.append(frame(pending, start: start, frames: blockSize))
            start += per
        }
        if start > 0 { pending.removeFirst(start) }
        return out
    }

    /// Emits what is left as a shorter final frame (end of the stream).
    func flush() -> Data? {
        let n = pending.count / channels
        guard n > 0 else { return nil }
        defer { pending.removeAll() }
        return frame(pending, start: 0, frames: n)
    }

    // MARK: one frame

    private static let rateCodes: [Int: UInt64] = [88_200: 1, 176_400: 2, 192_000: 3, 8_000: 4, 16_000: 5, 22_050: 6, 24_000: 7, 32_000: 8, 44_100: 9, 48_000: 10, 96_000: 11]

    private func frame(_ all: [Int32], start: Int, frames n: Int) -> Data {
        var w = BitWriter()
        // header
        w.write(0xFFF8, 16)
        let bsCode: UInt64 = n == 4096 ? 12 : (n == 4608 ? 5 : (n <= 256 ? 6 : 7))
        w.write(bsCode, 4)
        w.write(Self.rateCodes[sampleRate] ?? 0, 4)
        w.write(UInt64(channels - 1), 4)
        w.write(bitsPerSample == 16 ? 4 : 6, 3); w.write(0, 1)
        w.writeUTF8(frameNumber)
        if bsCode == 6 { w.write(UInt64(n - 1), 8) } else if bsCode == 7 { w.write(UInt64(n - 1), 16) }
        w.write(UInt64(Self.crc8(w.bytes)), 8)
        // subframes
        var chan = [Int32](repeating: 0, count: n)
        for c in 0..<channels {
            for i in 0..<n { chan[i] = all[start + i * channels + c] }
            subframe(chan, into: &w)
        }
        w.alignToByte()
        let crc = Self.crc16(w.bytes)
        w.write(UInt64(crc), 16)
        frameNumber += 1; framesEncoded += n
        return w.data
    }

    private func subframe(_ x: [Int32], into w: inout BitWriter) {
        let n = x.count, bits = bitsPerSample
        if x.allSatisfy({ $0 == x[0] }) {
            w.write(0, 8); w.writeSigned(Int64(x[0]), bits); return
        }
        var best: (cost: Int, order: Int, partOrder: Int, params: [Int])?
        var residual = [Int64](repeating: 0, count: n)
        for order in 0...min(4, n - 1) {
            computeResidual(x, order: order, into: &residual)
            let r = Self.bestPartitioning(residual, order: order, n: n)
            let cost = 8 + order * bits + 2 + 4 + r.cost
            if best == nil || cost < best!.cost { best = (cost, order, r.partOrder, r.params) }
        }
        guard let b = best, b.cost < 8 + n * bits else {
            w.write(1 << 1, 8)                                   // VERBATIM
            for s in x { w.writeSigned(Int64(s), bits) }
            return
        }
        w.write(UInt64(0x10 | b.order << 1), 8)                  // 0, type = 001ooo, no wasted bits
        for i in 0..<b.order { w.writeSigned(Int64(x[i]), bits) }
        computeResidual(x, order: b.order, into: &residual)
        w.write(1, 2)                                            // RICE2
        w.write(UInt64(b.partOrder), 4)
        let parts = 1 << b.partOrder, per = n >> b.partOrder
        var pos = b.order
        for p in 0..<parts {
            let count = p == 0 ? per - b.order : per, k = b.params[p]
            w.write(UInt64(k), 5)
            for i in pos..<(pos + count) {
                let e = residual[i], u = UInt64(bitPattern: (e << 1) ^ (e >> 63))
                w.writeUnary(Int(u >> UInt64(k)))
                if k > 0 { w.write(u & ((1 << UInt64(k)) - 1), k) }
            }
            pos += count
        }
    }

    private func computeResidual(_ x: [Int32], order: Int, into r: inout [Int64]) {
        let n = x.count
        switch order {
        case 0: for i in 0..<n { r[i] = Int64(x[i]) }
        case 1: for i in 1..<n { r[i] = Int64(x[i]) - Int64(x[i - 1]) }
        case 2: for i in 2..<n { r[i] = Int64(x[i]) - 2 * Int64(x[i - 1]) + Int64(x[i - 2]) }
        case 3: for i in 3..<n { r[i] = Int64(x[i]) - 3 * Int64(x[i - 1]) + 3 * Int64(x[i - 2]) - Int64(x[i - 3]) }
        default: for i in 4..<n { r[i] = Int64(x[i]) - 4 * Int64(x[i - 1]) + 6 * Int64(x[i - 2]) - 4 * Int64(x[i - 3]) + Int64(x[i - 4]) }
        }
    }

    /// The cheapest Rice partitioning of the residual (order ≤ 6 where the block size allows).
    private static func bestPartitioning(_ r: [Int64], order: Int, n: Int) -> (cost: Int, partOrder: Int, params: [Int]) {
        var best: (Int, Int, [Int]) = (Int.max, 0, [0])
        var po = 0
        while po <= 6, n % (1 << po) == 0, (n >> po) > order {
            let parts = 1 << po, per = n >> po
            var total = 0, params: [Int] = []
            var pos = order
            for p in 0..<parts {
                let count = p == 0 ? per - order : per
                var sum: UInt64 = 0
                for i in pos..<(pos + count) { let e = r[i]; sum &+= UInt64(bitPattern: (e << 1) ^ (e >> 63)) }
                // k near log2(mean): try the neighbours
                let mean = count > 0 ? sum / UInt64(count) : 0
                let k0 = mean > 0 ? 63 - mean.leadingZeroBitCount : 0
                var bestK = 0, bestBits = Int.max
                for k in max(0, k0 - 1)...min(30, k0 + 1) {
                    var bits = count * (1 + k)
                    for i in pos..<(pos + count) { let e = r[i]; bits += Int((UInt64(bitPattern: (e << 1) ^ (e >> 63)) >> UInt64(k))) }
                    if bits < bestBits { bestBits = bits; bestK = k }
                }
                total += 5 + bestBits; params.append(bestK)
                pos += count
            }
            if total < best.0 { best = (total, po, params) }
            po += 1
        }
        return best
    }

    // MARK: checksums

    private static let table8: [UInt8] = (0..<256).map { i in var c = UInt8(i); for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }; return c }
    static func crc8(_ d: [UInt8]) -> UInt8 { var c: UInt8 = 0; for b in d { c = table8[Int(c ^ b)] }; return c }
    private static let table16: [UInt16] = (0..<256).map { i in var c = UInt16(i) << 8; for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 }; return c }
    static func crc16(_ d: [UInt8]) -> UInt16 { var c: UInt16 = 0; for b in d { c = (c << 8) ^ table16[Int((c >> 8) ^ UInt16(b))] }; return c }
}

struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var acc: UInt64 = 0
    private var nbits = 0
    var data: Data { var b = bytes; if nbits > 0 { b.append(UInt8(truncatingIfNeeded: acc << UInt64(8 - nbits))) }; return Data(b) }

    mutating func write(_ value: UInt64, _ n: Int) {
        guard n > 0 else { return }
        var remaining = n
        while remaining > 0 {
            let take = min(remaining, 8 - nbits)
            let part = (value >> UInt64(remaining - take)) & ((1 << UInt64(take)) - 1)
            acc = (acc << UInt64(take)) | part
            nbits += take; remaining -= take
            if nbits == 8 { bytes.append(UInt8(truncatingIfNeeded: acc)); acc = 0; nbits = 0 }
        }
    }
    mutating func writeSigned(_ v: Int64, _ n: Int) { write(UInt64(bitPattern: v) & (n == 64 ? ~0 : (1 << UInt64(n)) - 1), n) }
    mutating func writeUnary(_ q: Int) { var left = q; while left >= 32 { write(0, 32); left -= 32 }; write(1, left + 1) }
    mutating func alignToByte() { if nbits > 0 { write(0, 8 - nbits) } }
    /// UTF-8 style coding of the frame number.
    mutating func writeUTF8(_ v: Int) {
        if v < 0x80 { write(UInt64(v), 8); return }
        var n = 2
        while n < 7 && v >= 1 << (5 * n + 1) { n += 1 }
        write(UInt64((0xFF00 >> n) & 0xFF) | UInt64(v >> (6 * (n - 1))), 8)
        for i in stride(from: n - 2, through: 0, by: -1) { write(0x80 | UInt64((v >> (6 * i)) & 0x3F), 8) }
    }
}

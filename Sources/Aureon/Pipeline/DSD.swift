import Foundation
import Accelerate

// DSD support: DSF and DFF (uncompressed DSDIFF) containers, DoP packing, and DSD → PCM conversion.
// DST-compressed DFF is detected and reported as unsupported.

enum DSDMode: String, Codable, CaseIterable, Identifiable {
    case pcm, dop
    var id: String { rawValue }
    var title: String { self == .pcm ? "Convert to PCM" : "DoP (DSD over PCM) — DAC must support DoP" }
}

struct DSDSettings: Equatable, Codable {
    var mode: DSDMode = .pcm
    /// PCM rate used when converting. Must divide the DSD rate by a multiple of 8 (176.4 / 88.2 kHz for DSD64).
    var pcmRate: Double = 176_400
    /// Level applied during DSD → PCM conversion. DSD's nominal 0 dB sits 6 dB below PCM full scale.
    var gainDB: Double = 0
}

func dsdRateName(_ rate: Double) -> String {
    // the 44.1 kHz family (DSD64 = 2.8224 MHz) or the 48 kHz family (3.072 MHz)
    let k44 = Int((rate / 44_100).rounded()), k48 = Int((rate / 48_000).rounded())
    let k = abs(rate - Double(k48) * 48_000) < abs(rate - Double(k44) * 44_100) ? k48 : k44
    return k >= 64 ? "DSD\(k)" : "DSD"
}

/// Reads raw DSD bytes. All bytes handed out are MSB-first (oldest bit in bit 7) and channel-interleaved:
/// byte index major, channel minor — the DSDIFF layout.
final class DsdContainer {
    enum Kind { case dsf, dff }
    let kind: Kind
    let channels: Int
    let dsdRate: Double
    let bytesPerChannel: Int
    private let fd: Int32
    private let dataStart: Int
    private let blockSize: Int          // DSF only
    private let lsbFirst: Bool

    private static let reverse: [UInt8] = (0..<256).map { v in
        var r: UInt8 = 0; for b in 0..<8 where (v >> b) & 1 == 1 { r |= 1 << UInt8(7 - b) }; return r
    }

    init(path: String) throws {
        let h = open(path, O_RDONLY)
        guard h >= 0 else { throw AureonError.message("cannot open \((path as NSString).lastPathComponent)") }
        func rd(_ off: Int, _ n: Int) -> [UInt8]? {
            var b = [UInt8](repeating: 0, count: n)
            return pread(h, &b, n, off_t(off)) == n ? b : nil
        }
        func le(_ b: [UInt8]) -> Int { b.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        func be(_ b: [UInt8]) -> Int { b.reduce(0) { ($0 << 8) | Int($1) } }

        guard let magic = rd(0, 4) else { close(h); throw AureonError.message("empty file") }
        if magic == Array("DSD ".utf8) {
            kind = .dsf
            guard let fmt = rd(28, 52), fmt.prefix(4) == ArraySlice(Array("fmt ".utf8)) else { close(h); throw AureonError.message("bad DSF header") }
            channels = le(Array(fmt[24..<28])); dsdRate = Double(le(Array(fmt[28..<32])))
            let bps = le(Array(fmt[32..<36])); let samples = le(Array(fmt[36..<44])); blockSize = le(Array(fmt[44..<48]))
            lsbFirst = bps == 1
            bytesPerChannel = (samples + 7) / 8
            dataStart = 28 + 52 + 12                       // "data" chunk header is 12 bytes
            guard channels > 0, blockSize > 0 else { close(h); throw AureonError.message("bad DSF fmt chunk") }
        } else if magic == Array("FRM8".utf8) {
            kind = .dff
            blockSize = 0; lsbFirst = false
            var ch = 0, rate = 0, start = 0, size = 0, compressed = false
            var off = 16                                    // skip "FRM8", size(8), "DSD "
            while let hdr = rd(off, 12) {
                let id = String(bytes: hdr[0..<4], encoding: .ascii) ?? "", sz = be(Array(hdr[4..<12]))
                if id == "PROP" {
                    var p = off + 12 + 4                    // skip "SND "
                    let end = off + 12 + sz
                    while p + 12 <= end, let ph = rd(p, 12) {
                        let pid = String(bytes: ph[0..<4], encoding: .ascii) ?? "", psz = be(Array(ph[4..<12]))
                        if pid == "FS  ", let v = rd(p + 12, 4) { rate = be(v) }
                        if pid == "CHNL", let v = rd(p + 12, 2) { ch = be(v) }
                        if pid == "CMPR", let v = rd(p + 12, 4) { compressed = String(bytes: v, encoding: .ascii) != "DSD " }
                        p += 12 + psz + (psz & 1)
                    }
                } else if id == "DSD " { start = off + 12; size = sz; break }
                off += 12 + sz + (sz & 1)
            }
            guard ch > 0, rate > 0, start > 0 else { close(h); throw AureonError.message("bad DSDIFF file") }
            guard !compressed else { close(h); throw AureonError.message("DST-compressed DSDIFF is not supported") }
            channels = ch; dsdRate = Double(rate); dataStart = start; bytesPerChannel = size / ch
        } else {
            close(h); throw AureonError.message("not a DSF/DFF file")
        }
            fd = h
    }

    deinit { close(fd) }

    var totalBits: Int { bytesPerChannel * 8 }

    /// Reads `count` bytes per channel starting at byte `from`; returns `count * channels` interleaved bytes.
    func read(from: Int, count: Int, into out: UnsafeMutablePointer<UInt8>) -> Int {
        let n = max(0, min(count, bytesPerChannel - from))
        guard n > 0 else { return 0 }
        _ = DiskStats.reads.n.add(1, ordering: .relaxed)
        if kind == .dff {
            let got = pread(fd, out, n * channels, off_t(dataStart + from * channels))
            return max(0, got / channels)
        }
        var tmp = [UInt8](repeating: 0, count: blockSize)
        var done = 0
        while done < n {
            let pos = from + done, blk = pos / blockSize, within = pos % blockSize
            let chunk = min(blockSize - within, n - done)
            for c in 0..<channels {
                let off = dataStart + (blk * channels + c) * blockSize + within
                if pread(fd, &tmp, chunk, off_t(off)) != chunk { return done }
                for i in 0..<chunk {
                    let b = tmp[i]
                    out[(done + i) * channels + c] = lsbFirst ? Self.reverse[Int(b)] : b
                }
            }
            done += chunk
        }
        return n
    }
}

// MARK: - DoP

/// Packs 16 DSD bits per channel into each 24-bit PCM sample: `00 | byte1 | byte2` (marker added later by `DoPStampSource`).
final class DoPSource: FrameSource {
    private let file: DsdContainer
    let info: StreamInfo
    private var pos = 0                          // frame index
    private var scratch: [UInt8]
    private let total: Int

    init(_ file: DsdContainer, codec: String) {
        self.file = file
        total = file.bytesPerChannel / 2
        info = StreamInfo(sampleRate: file.dsdRate / 16, channels: file.channels, sourceBits: 1,
                          totalFrames: Int64(total), codec: codec, isDoP: true, sourceRate: file.dsdRate)
        scratch = [UInt8](repeating: 0, count: 4096 * 2 * file.channels)
    }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let ch = file.channels
        let n = min(min(frames, 4096), total - pos)
        guard n > 0 else { return 0 }
        let got = scratch.withUnsafeMutableBufferPointer { file.read(from: pos * 2, count: n * 2, into: $0.baseAddress!) } / 2
        for f in 0..<got { for c in 0..<ch {
            buf[f * ch + c] = (Int32(scratch[(2 * f) * ch + c]) << 16) | (Int32(scratch[(2 * f + 1) * ch + c]) << 8)
        } }
        pos += got
        return got
    }
    func seek(to frame: Int64) { pos = max(0, min(Int(frame), total)) }
}

// MARK: - DSD → PCM

final class DsdToPcmSource: FrameSource {
    private let file: DsdContainer
    let info: StreamInfo
    private let D: Int, N: Int, c: Int                  // decimation, filter taps, filter half-length (a multiple of 8)
    private let filter: [Double]
    private let gain: Double
    private let outTotal: Int64
    private let ch: Int

    private var buf: [UnsafeMutablePointer<Double>] = []
    private var capacity = 0
    private var base = 0, have = 0                       // window in absolute DSD-bit coordinates
    private var m = 0
    private let chunkBytes = 8192
    private var raw: UnsafeMutablePointer<UInt8>
    private let batch = 2048
    private let tmp: UnsafeMutablePointer<Double>
    private static let lut: [Double] = (0..<256).flatMap { v in (0..<8).map { b in ((v >> (7 - b)) & 1) == 1 ? 1.0 : -1.0 } }

    init?(_ file: DsdContainer, codec: String, pcmRate: Double, gainDB: Double) {
        let ratio = file.dsdRate / pcmRate
        guard ratio >= 8, abs(ratio - ratio.rounded()) < 1e-9, Int(ratio) % 8 == 0 else { return nil }
        self.file = file; D = Int(ratio); ch = file.channels
        gain = pow(10, gainDB / 20)
        let stopEdge = 0.5 / Double(D), passEdge = 0.8 * stopEdge
        let n0 = (100 - 7.95) / (2.285 * 2 * Double.pi * (stopEdge - passEdge))
        c = ((Int(n0 / 2) + 7) / 8) * 8
        N = 2 * c + 1
        filter = DSPMath.lowpass(taps: N, cutoff: (stopEdge + passEdge) / 2, beta: DSPMath.kaiserBeta(attenuation: 100), gain: 1)
        outTotal = Int64(file.totalBits / D)
        info = StreamInfo(sampleRate: pcmRate, channels: ch, sourceBits: 1, totalFrames: outTotal, codec: codec,
                          sourceRate: file.dsdRate, transparent: false)
        capacity = N + batch * D + chunkBytes * 8 + 16
        for _ in 0..<ch { buf.append(.allocate(capacity: capacity)) }
        raw = .allocate(capacity: chunkBytes * ch)
        tmp = .allocate(capacity: batch)
        reset(to: 0)
    }

    deinit { buf.forEach { $0.deallocate() }; raw.deallocate(); tmp.deallocate() }

    private func reset(to frame: Int) {
        m = frame
        let ws = frame * D - c
        if ws < 0 { base = ws; have = -ws; for k in 0..<ch { buf[k].update(repeating: 0, count: have) } }
        else { base = ws; have = 0 }
    }

    func seek(to frame: Int64) { reset(to: max(0, min(Int(frame), Int(outTotal)))) }

    private func ensure(start: Int, end: Int) {
        guard base + have <= end else { return }
        let drop = min(max(0, start - base), have)
        if drop > 0 {
            for k in 0..<ch { buf[k].update(from: buf[k] + drop, count: have - drop) }
            base += drop; have -= drop
        }
        while base + have <= end {
            let bytePos = (base + have) / 8
            let got = bytePos < file.bytesPerChannel ? file.read(from: bytePos, count: chunkBytes, into: raw) : 0
            if got > 0 {
                Self.lut.withUnsafeBufferPointer { lut in
                    for k in 0..<ch { let dst = buf[k] + have
                        for i in 0..<got { (dst + i * 8).update(from: lut.baseAddress! + Int(raw[i * ch + k]) * 8, count: 8) } }
                }
                have += got * 8
            } else {                                            // beyond the end: silence
                for k in 0..<ch { (buf[k] + have).update(repeating: 0, count: chunkBytes * 8) }
                have += chunkBytes * 8
            }
        }
    }

    func read(into out: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var produced = 0
        filter.withUnsafeBufferPointer { fp in
            while produced < frames && Int64(m) < outTotal {
                let want = min(min(frames - produced, batch), Int(outTotal) - m)
                let ws = m * D - c
                ensure(start: ws, end: ws + (want - 1) * D + N - 1)
                for k in 0..<ch {
                    vDSP_desampD(buf[k] + (ws - base), vDSP_Stride(D), fp.baseAddress!, tmp, vDSP_Length(want), vDSP_Length(N))
                    for i in 0..<want {
                        let v = (tmp[i] * gain * 2_147_483_648.0).rounded()
                        out[(produced + i) * ch + k] = v >= 2_147_483_647 ? .max : (v <= -2_147_483_648 ? .min : Int32(v))
                    }
                }
                produced += want; m += want
            }
        }
        return produced
    }
}

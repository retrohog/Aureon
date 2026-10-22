import Foundation
import Accelerate

// High-ratio DSD → PCM (DSD256, DSD512, DSD1024).
//
// A single long FIR from 45 MHz down to 176 kHz needs tens of thousands of taps per output sample: DSD512 does not run in real time on an M4, DSD1024
// runs at a third of real time. The standard answer is a cascade in which every stage only has to be as good as the *next* band it must protect:
//
//   bits ─► byte-LUT FIR, ÷8 ─► halfband ÷2 ─► halfband ÷2 ─► … ─► PCM
//           (K table lookups     (short filters: the early stages have a huge transition band,
//            per output)          because only the final passband must stay clean)
//
// All filters are Kaiser designs with 105 dB of stop-band rejection, the pass-band of the result reaches 0.4 × the PCM rate, like the single-stage converter.

final class FastDsdToPcmSource: FrameSource {
    private let file: DsdContainer
    let info: StreamInfo
    private let ch: Int
    private let D: Int                           // total decimation
    private let stages: Int                      // number of ÷2 stages after the byte stage
    private let K: Int                           // bytes in the first filter
    private let lut: [Double]                    // K × 256
    private let stageFilters: [[Double]]
    private let gain: Double
    private let outTotal: Int64
    private let pad: Int                         // bits of silence fed before the first wanted bit (priming)
    private let skip: Int                        // outputs to discard after priming

    // streaming state, one set per channel
    private var byteBuf: [UnsafeMutablePointer<UInt8>] = []
    private var stageBuf: [[UnsafeMutablePointer<Double>]] = []     // [channel][stage]
    private var stageCount: [[Int]] = []
    private var outQueue: [[Double]] = []
    private var outHead = 0
    private var bitPos = 0                       // next input bit (byte aligned) to feed, absolute (may be negative while priming)
    private var toSkip = 0
    private var produced = 0                     // frames delivered so far (absolute frame index of the next frame)
    private let chunkBytes = 2048
    private let raw: UnsafeMutablePointer<UInt8>
    private let aOut: UnsafeMutablePointer<Double>

    static let attenuationDB = 105.0

    /// True when `dsdRate` / `pcmRate` is 8 × a power of two.
    static func supports(dsdRate: Double, pcmRate: Double) -> Bool {
        let r = dsdRate / pcmRate
        guard r >= 8, abs(r - r.rounded()) < 1e-9 else { return false }
        let n = Int(r.rounded())
        guard n % 8 == 0 else { return false }
        let q = n / 8
        return q & (q - 1) == 0
    }

    init?(_ file: DsdContainer, codec: String, pcmRate: Double, gainDB: Double) {
        guard Self.supports(dsdRate: file.dsdRate, pcmRate: pcmRate) else { return nil }
        self.file = file; ch = file.channels
        D = Int((file.dsdRate / pcmRate).rounded())
        var s = 0; var q = D / 8; while q > 1 { q /= 2; s += 1 }
        stages = s
        gain = pow(10, gainDB / 20)
        outTotal = Int64(file.totalBits / D)
        let A = Self.attenuationDB, beta = DSPMath.kaiserBeta(attenuation: A)
        let fp = 0.4 * pcmRate
        let fsDSD = file.dsdRate, fsA = fsDSD / 8

        // first stage: K bytes. Transition from fp to (fsA − fp), relative to the DSD rate.
        let dA = (fsA - 2 * fp) / fsDSD
        let n0 = (A - 7.95) / (14.36 * dA)
        let k = max(2, Int((n0 / 8).rounded(.up)) + 1)
        K = k
        var hA = DSPMath.lowpass(taps: 8 * k - 1, cutoff: 1.0 / 16, beta: beta, gain: 1)
        hA.append(0)
        var table = [Double](repeating: 0, count: k * 256)
        for j in 0..<k { for v in 0..<256 {
            var acc = 0.0
            for i in 0..<8 { acc += hA[8 * j + 7 - i] * (((v >> (7 - i)) & 1) == 1 ? 1.0 : -1.0) }
            table[j * 256 + v] = acc
        } }
        lut = table
        let delayA = Double(8 * k - 2) / 2

        // the ÷2 stages
        var filters: [[Double]] = []
        var c0 = 7 - delayA
        var spacing = 8.0
        var fin = fsA
        for _ in 0..<s {
            let dn = 0.5 - 2 * fp / fin
            var n = Int(((A - 7.95) / (14.36 * dn)).rounded(.up)) | 1
            n = max(7, n)
            filters.append(DSPMath.lowpass(taps: n, cutoff: 0.25, beta: beta, gain: 1))
            c0 += spacing * Double(n - 1) / 2
            spacing *= 2; fin /= 2
        }
        stageFilters = filters
        // priming: enough silence in front that the first wanted output has seen a settled filter chain
        let reach = c0 + delayA + 16
        let q0 = Int((reach / Double(D)).rounded(.up)) + 1
        pad = q0 * D
        skip = max(0, Int((Double(q0) - c0 / Double(D)).rounded()))

        info = StreamInfo(sampleRate: pcmRate, channels: ch, sourceBits: 1, totalFrames: outTotal, codec: codec, sourceRate: file.dsdRate, transparent: false)
        for _ in 0..<ch {
            byteBuf.append(.allocate(capacity: k + chunkBytes)); byteBuf.last!.initialize(repeating: 0x55, count: k + chunkBytes)
            var row: [UnsafeMutablePointer<Double>] = []
            for f in filters { let p = UnsafeMutablePointer<Double>.allocate(capacity: f.count + chunkBytes + 8); p.initialize(repeating: 0, count: f.count + chunkBytes + 8); row.append(p) }
            stageBuf.append(row); stageCount.append([Int](repeating: 0, count: s))
            outQueue.append([])
        }
        raw = .allocate(capacity: chunkBytes * ch)
        aOut = .allocate(capacity: chunkBytes + 8)
        reset(toFrame: 0)
    }

    deinit {
        byteBuf.forEach { $0.deallocate() }; stageBuf.flatMap { $0 }.forEach { $0.deallocate() }
        raw.deallocate(); aOut.deallocate()
    }

    private func reset(toFrame m: Int) {
        for c in 0..<ch {
            byteBuf[c].initialize(repeating: 0x55, count: K + chunkBytes)       // 0x55: a balanced pattern, the DSD idea of silence
            for i in 0..<stages { stageBuf[c][i].initialize(repeating: 0, count: stageFilters[i].count + chunkBytes + 8); stageCount[c][i] = 0 }
            outQueue[c].removeAll(keepingCapacity: true)
        }
        outHead = 0
        bitPos = m * D - pad
        toSkip = skip
        produced = m
    }

    func seek(to frame: Int64) { reset(toFrame: max(0, min(Int(frame), Int(outTotal)))) }

    /// Feeds one chunk of input bytes through the whole cascade.
    private func pump() {
        let nb = chunkBytes
        // bytes at negative positions (before the file) and past its end are silence
        let startByte = bitPos / 8
        let lead = startByte < 0 ? min(nb, -startByte) : 0
        var got = 0
        if lead < nb, startByte + lead < file.bytesPerChannel { got = file.read(from: startByte + lead, count: min(nb - lead, file.bytesPerChannel - (startByte + lead)), into: raw) }
        for c in 0..<ch {
            let b = byteBuf[c]                           // layout: K−1 bytes of history, then this chunk
            for i in 0..<nb {
                b[K - 1 + i] = (i >= lead && i - lead < got) ? raw[(i - lead) * ch + c] : 0x55
            }
            // first stage: K table lookups per output
            lut.withUnsafeBufferPointer { t in
                for n in 0..<nb {
                    var acc = 0.0
                    let top = K - 1 + n
                    for j in 0..<K { acc += t[j * 256 + Int(b[top - j])] }
                    aOut[n] = acc
                }
            }
            for i in 0..<(K - 1) { b[i] = b[nb + i] }    // history for the next chunk
            // the ÷2 stages
            var count = nb
            for st in 0..<stages {
                let f = stageFilters[st], N = f.count
                let buf = stageBuf[c][st]
                var have = stageCount[c][st]
                memcpy(buf + have, aOut, count * 8); have += count
                let nOut = have >= N ? (have - N) / 2 + 1 : 0
                if nOut > 0 {
                    f.withUnsafeBufferPointer { fp in vDSP_desampD(buf, 2, fp.baseAddress!, aOut, vDSP_Length(nOut), vDSP_Length(N)) }
                    let used = 2 * nOut
                    memmove(buf, buf + used, (have - used) * 8); have -= used
                }
                stageCount[c][st] = have
                count = nOut
                if count == 0 { break }
            }
            if count > 0 { outQueue[c].append(contentsOf: UnsafeBufferPointer(start: aOut, count: count)) }
        }
        bitPos += nb * 8
    }

    func read(into out: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var produced = 0
        while produced < frames && Int64(self.produced) < outTotal {
            // discard the priming outputs
            if toSkip > 0 {
                let have = outQueue[0].count - outHead
                let drop = min(toSkip, have)
                outHead += drop; toSkip -= drop
                if toSkip > 0 { pump(); continue }
            }
            let have = outQueue[0].count - outHead
            let take = min(have, min(frames - produced, Int(outTotal) - self.produced))
            if take == 0 { pump(); continue }
            for k in 0..<ch {
                for i in 0..<take {
                    let v = (outQueue[k][outHead + i] * gain * 2_147_483_648.0).rounded()
                    out[(produced + i) * ch + k] = v >= 2_147_483_647 ? .max : (v <= -2_147_483_648 ? .min : Int32(v))
                }
            }
            outHead += take; produced += take; self.produced += take
            // keep the queue short
            if outHead > 65_536 { for k in 0..<ch { outQueue[k].removeFirst(outHead) }; outHead = 0 }
        }
        return produced
    }
}

enum DsdToPcm {
    /// The converter for this combination of rates: the cascade for the big ratios (DSD128 and up at the usual PCM rates), the single FIR otherwise.
    static func make(_ file: DsdContainer, codec: String, pcmRate: Double, gainDB: Double) -> FrameSource? {
        if let f = FastDsdToPcmSource(file, codec: codec, pcmRate: pcmRate, gainDB: gainDB) { return f }
        return DsdToPcmSource(file, codec: codec, pcmRate: pcmRate, gainDB: gainDB)
    }
}

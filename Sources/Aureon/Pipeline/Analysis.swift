import Foundation

// MARK: - Track analysis (peak and a dynamic-range estimate, computed off the audio thread)

struct TrackAnalysis { var peakDB: Double; var dynamicRange: Double }

/// DR estimate in the spirit of the "DR meter": 3 s blocks, loudest 20% RMS vs the second-highest block peak.
func analyzeTrack(path: String) -> TrackAnalysis? {
    guard let f = try? LosslessFile(path: path), f.info.totalFrames > 0 else { return nil }
    let ch = f.info.channels, block = Int(f.info.sampleRate * 3)
    let buf = UnsafeMutablePointer<Int32>.allocate(capacity: block * ch)
    defer { buf.deallocate() }
    var peaks: [Double] = [], rmss: [Double] = []
    var overall = 0.0
    while true {
        let n = f.read(into: buf, frames: block)
        if n == 0 { break }
        var pk = 0.0, sum = 0.0
        for k in 0..<(n * ch) {
            let v = abs(Double(buf[k])) / 2_147_483_648.0
            pk = max(pk, v); sum += v * v
        }
        peaks.append(pk); rmss.append((sum / Double(n * ch)).squareRoot()); overall = max(overall, pk)
    }
    guard !rmss.isEmpty, overall > 0 else { return nil }
    let top = rmss.sorted(by: >).prefix(max(1, Int((Double(rmss.count) * 0.2).rounded(.up))))
    let rmsTop = (top.map { $0 * $0 }.reduce(0, +) / Double(top.count)).squareRoot()
    let ref = peaks.sorted(by: >).dropFirst(peaks.count > 1 ? 1 : 0).first ?? overall
    guard rmsTop > 0 else { return nil }
    return TrackAnalysis(peakDB: 20 * log10(overall), dynamicRange: 20 * log10(ref / rmsTop))
}

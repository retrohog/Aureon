import Foundation

// MARK: - Track analysis (computed off the audio thread; the loudness figures come from the EBU R128 analyser and its cache)

struct TrackAnalysis {
    var peakDB: Double                  // sample peak, dBFS
    var dynamicRange: Double            // DR score
    var lufs: Double? = nil             // integrated loudness
    var truePeakDB: Double? = nil       // dBTP
    var loudnessRange: Double? = nil    // LU
}

func analyzeTrack(path: String) -> TrackAnalysis? {
    guard let r = LoudnessCache.shared.analysis(path: path) else { return nil }
    return TrackAnalysis(peakDB: r.samplePeakDB, dynamicRange: r.dynamicRange, lufs: r.integratedLUFS, truePeakDB: r.truePeakDB, loudnessRange: r.loudnessRange)
}

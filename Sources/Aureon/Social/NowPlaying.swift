import Foundation

/// What the social integrations need to know about the playing track.
struct NowPlayingInfo: Equatable, Codable {
    var id: String
    var title: String
    var artist: String
    var album: String = ""
    var albumArtist: String = ""
    var duration: Double = 0
    var trackNumber: Int? = nil
    var mbRecordingID: String? = nil
    var mbReleaseID: String? = nil
    var codec: String = ""
    var bitDepth: Int = 0
    var sampleRate: Double = 0
    var coverURL: String? = nil

    var isDSD: Bool { bitDepth == 1 || codec.uppercased().hasPrefix("DSD") }

    /// "FLAC · 24-bit / 192 kHz", "DSD64 · 2.8 MHz", "ALAC · 16-bit / 44.1 kHz".
    var qualityLabel: String {
        func rate(_ hz: Double) -> String {
            if hz >= 1_000_000 { return String(format: "%g MHz", (hz / 100_000).rounded() / 10) }
            let k = hz / 1000
            return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
        }
        if isDSD { return "\(codec.isEmpty ? "DSD" : codec) · \(rate(sampleRate))" }
        var parts: [String] = []
        if !codec.isEmpty { parts.append(codec) }
        if bitDepth > 0 && sampleRate > 0 { parts.append("\(bitDepth)-bit / \(rate(sampleRate))") }
        return parts.joined(separator: " · ")
    }
}

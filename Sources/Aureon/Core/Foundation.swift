import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw AureonError.message("\(what) failed (OSStatus \(status))") }
}

enum AureonError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

func fourCC(_ v: UInt32) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
    return String(bytes: b, encoding: .ascii) ?? "????"
}

final class Counter: @unchecked Sendable { let n = Atomic<Int>(0) }

/// Process-wide disk I/O accounting, used to prove that RAM playback really stops touching the disk.
enum DiskStats {
    static let reads = Counter()
    static var readCalls: Int { reads.n.load(ordering: .relaxed) }
}

// MARK: - Stream description

/// Describes a stream of interleaved 32-bit signed integer frames, left-justified (a 24-bit sample occupies the top 24 bits).
struct StreamInfo: Equatable {
    var sampleRate: Double
    var channels: Int
    var sourceBits: Int          // bit depth stored in the file (16/20/24/32, or 1 for DSD)
    var totalFrames: Int64       // frames at `sampleRate`
    var codec: String
    var isDoP = false            // DSD packed as PCM: must never be gained, resampled or filtered
    var sourceRate: Double? = nil// original file rate when a stage changed it
    var transparent = true       // false once any stage alters sample values (gain, SRC, DSD→PCM, polarity)
    var isLive = false           // an endless stream (internet radio): no duration, no seeking

    var duration: Double { sampleRate > 0 ? Double(totalFrames) / sampleRate : 0 }
}

/// A pull-based stage in the ingestion pipeline. Runs on the producer thread, never on the audio thread.
protocol FrameSource: AnyObject {
    var info: StreamInfo { get }
    /// Reads up to `frames` interleaved frames; returns 0 at end of stream.
    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int
    /// Repositions to an absolute frame (in this stage's output rate).
    func seek(to frame: Int64)
}

// MARK: - Lossless file decoding (CoreAudio's native FLAC / ALAC / PCM decoders)

final class LosslessFile: FrameSource {
    private var ref: ExtAudioFileRef?
    let info: StreamInfo

    init(path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        try check(ExtAudioFileOpenURL(url, &ref), "open \((path as NSString).lastPathComponent)")
        guard let ref else { throw AureonError.message("could not open \(path)") }

        var fileFmt = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout.size(ofValue: fileFmt))
        try check(ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileDataFormat, &sz, &fileFmt), "file format")

        var frames: Int64 = 0
        sz = UInt32(MemoryLayout<Int64>.size)
        try check(ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileLengthFrames, &sz, &frames), "length")

        // FLAC and ALAC carry the source bit depth in mFormatFlags (1=16, 2=20, 3=24, 4=32).
        var bits = Int(fileFmt.mBitsPerChannel)
        var codec = fourCC(fileFmt.mFormatID)
        var lossy = false
        if fileFmt.mFormatID == kAudioFormatFLAC || fileFmt.mFormatID == kAudioFormatAppleLossless {
            bits = [1: 16, 2: 20, 3: 24, 4: 32][Int(fileFmt.mFormatFlags)] ?? bits
            codec = fileFmt.mFormatID == kAudioFormatFLAC ? "FLAC" : "ALAC"
        } else if fileFmt.mFormatID == kAudioFormatLinearPCM {
            codec = "PCM"
        } else {
            codec += " (lossy)"; lossy = true
        }

        // Client format: SAME rate and channel count as the file, 32-bit signed integer.
        // 16/24-bit sources are left-justified into 32 bits (a pure shift: lossless).
        var client = AudioStreamBasicDescription(
            mSampleRate: fileFmt.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * fileFmt.mChannelsPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: 4 * fileFmt.mChannelsPerFrame,
            mChannelsPerFrame: fileFmt.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
        try check(ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout.size(ofValue: client)), &client), "client format")

        info = StreamInfo(sampleRate: fileFmt.mSampleRate, channels: Int(fileFmt.mChannelsPerFrame),
                          sourceBits: bits, totalFrames: frames, codec: codec, transparent: !lossy)
    }

    deinit { if let ref { ExtAudioFileDispose(ref) } }

    func seek(to frame: Int64) {
        if let ref { ExtAudioFileSeek(ref, max(0, min(frame, info.totalFrames))) }
    }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(info.channels), mDataByteSize: UInt32(frames * info.channels * 4), mData: buf))
        var n = UInt32(frames)
        _ = DiskStats.reads.n.add(1, ordering: .relaxed)
        guard let ref, ExtAudioFileRead(ref, &n, &abl) == noErr else { return 0 }
        return Int(n)
    }
}

/// Fully canonical path (every symlink resolved, `/var` → `/private/var`), as the file system itself reports it.
/// `URL.resolvingSymlinksInPath()` is not enough: it deliberately strips a leading `/private`.
func realPath(_ url: URL) -> URL {
    guard let p = realpath(url.path, nil) else { return url }
    defer { free(p) }
    return URL(fileURLWithPath: String(cString: p), isDirectory: url.hasDirectoryPath)
}

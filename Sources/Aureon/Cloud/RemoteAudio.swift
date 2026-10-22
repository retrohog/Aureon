import Foundation
import AudioToolbox

/// A remote file exposed to CoreAudio through `AudioFileOpenWithCallbacks`: the decoders ask for byte ranges and the chunk reader supplies
/// them, so FLAC, ALAC, WAV and friends play straight from a bucket through the normal pipeline (RAM buffer, DSP, integer mode …).
final class RemoteAudioHandle {
    let reader: ChunkedReader
    private(set) var audioFile: AudioFileID?
    var readError: Error?

    init(reader: ChunkedReader) { self.reader = reader }
    deinit { if let f = audioFile { AudioFileClose(f) } }

    static func fileType(forExtension ext: String) -> AudioFileTypeID {
        switch ext.lowercased() {
        case "flac": return kAudioFileFLACType
        case "m4a", "mp4", "alac": return kAudioFileM4AType
        case "wav": return kAudioFileWAVEType
        case "aif", "aiff": return kAudioFileAIFFType
        case "aifc": return kAudioFileAIFCType
        case "caf": return kAudioFileCAFType
        case "mp3": return kAudioFileMP3Type
        case "aac": return kAudioFileAAC_ADTSType
        default: return 0
        }
    }

    /// Opens the remote object as a decodable file. Reading happens on the calling thread; run this off the main thread.
    static func open(reader: ChunkedReader, fileExtension: String) throws -> LosslessFile {
        let handle = RemoteAudioHandle(reader: reader)
        let client = Unmanaged.passUnretained(handle).toOpaque()
        var id: AudioFileID?
        let status = AudioFileOpenWithCallbacks(client,
            { c, pos, count, buffer, actual in
                let h = Unmanaged<RemoteAudioHandle>.fromOpaque(c).takeUnretainedValue()
                do {
                    let n = try h.reader.read(offset: pos, length: Int(count), into: buffer)
                    actual.pointee = UInt32(n)
                    return n == 0 && count > 0 ? kAudioFileEndOfFileError : noErr
                } catch { h.readError = error; actual.pointee = 0; return kAudioFileUnspecifiedError }
            },
            nil,
            { c in Unmanaged<RemoteAudioHandle>.fromOpaque(c).takeUnretainedValue().reader.size },
            nil,
            fileType(forExtension: fileExtension), &id)
        guard status == noErr, let id else {
            throw AureonError.message(handle.readError?.localizedDescription ?? "the remote file is not a readable audio file (\(status))")
        }
        handle.audioFile = id
        var ext: ExtAudioFileRef?
        let w = ExtAudioFileWrapAudioFileID(id, false, &ext)
        guard w == noErr, let ext else { throw AureonError.message(handle.readError?.localizedDescription ?? "could not decode the remote file (\(w))") }
        return try LosslessFile(opened: ext, owner: handle)
    }
}

import Foundation
import WhisperKit

// AureonWhisper: a speech-to-text server on stdin/stdout, one JSON object per line. Aureon uses it to write timed lyrics for songs that have none.
//
//   → {"op":"transcribe","id":3,"path":"/tmp/song.wav","model":"base","language":"en","folder":"~/Library/Application Support/Aureon/Whisper","offline":false}
//        path: a 16 kHz mono WAV made by Aureon.  model: tiny | base | small.  language: optional two-letter code (omitted: detect).
//   ← {"event":"progress","id":3,"fraction":0.1,"message":"Downloading the speech model"}          (zero or more)
//   ← {"event":"result","id":3,"language":"en","segments":[{"start":1.2,"end":4.5,"text":"…","words":[{"start":1.2,"end":1.5,"text":"Hello"}],
//                                                              "avgLogprob":-0.3,"noSpeechProb":0.02}]}
//      or {"event":"error","id":3,"message":"…"}   or {"event":"cancelled","id":3}
//   → {"op":"cancel","id":3}
//   → {"op":"unload"}        ← {"event":"unloaded"}   (then the program exits)
//   → {"op":"ping"}          ← {"event":"pong"}
//
// Models are downloaded once into `folder` (from Hugging Face, argmaxinc/whisperkit-coreml) and reused; with "offline" true nothing is downloaded.

setvbuf(stdout, nil, _IOLBF, 0)

let outputLock = NSLock()
func send(_ o: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return }
    outputLock.lock(); print(s); fflush(stdout); outputLock.unlock()
}

struct Failure: Error { var message: String }

final class Server: @unchecked Sendable {
    private let lock = NSLock()
    private var pipe: WhisperKit?
    private var loadedVariant = ""
    private var currentID = -1
    private var cancelled = false
    private var task: Task<Void, Never>?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func start(_ msg: [String: Any]) {
        let id = msg["id"] as? Int ?? 0
        lock.lock()
        if currentID >= 0 { lock.unlock(); send(["event": "error", "id": id, "message": "Another song is already being transcribed."]); return }
        currentID = id; cancelled = false
        task = Task.detached { [self] in await run(id: id, msg) }
        lock.unlock()
    }

    func cancel(id: Int) {
        lock.lock(); let t = id == currentID ? task : nil; if t != nil { cancelled = true }; lock.unlock()
        t?.cancel()
    }

    private func finish() { lock.lock(); currentID = -1; task = nil; lock.unlock() }

    private func run(id: Int, _ msg: [String: Any]) async {
        defer { finish() }
        guard let path = msg["path"] as? String, FileManager.default.fileExists(atPath: path) else { send(["event": "error", "id": id, "message": "The audio file is missing."]); return }
        let size = (msg["model"] as? String) ?? "base"
        let language = (msg["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let folder = URL(fileURLWithPath: (msg["folder"] as? String) ?? NSTemporaryDirectory(), isDirectory: true)
        let offline = (msg["offline"] as? Bool) ?? false
        do {
            let pipe = try await load(id: id, size: size, folder: folder, offline: offline)
            if isCancelled { send(["event": "cancelled", "id": id]); return }
            send(["event": "progress", "id": id, "fraction": 0.0, "message": "Listening to the song"])

            var options = DecodingOptions()
            options.task = .transcribe
            options.language = language
            options.detectLanguage = language == nil
            options.temperature = 0
            options.wordTimestamps = true
            options.skipSpecialTokens = true
            options.chunkingStrategy = .vad
            let results = try await pipe.transcribe(audioPath: path, decodeOptions: options) { [self] _ in
                // WhisperKit counts the 30-second windows it has finished; returning false stops it
                let p = pipe.progress
                if p.totalUnitCount > 0 { send(["event": "progress", "id": id, "fraction": min(1, Double(p.completedUnitCount) / Double(p.totalUnitCount)), "message": "Listening to the song"]) }
                return isCancelled ? false : nil
            }
            if isCancelled || Task.isCancelled { send(["event": "cancelled", "id": id]); return }
            var segments: [[String: Any]] = []
            for r in results {
                for s in r.segments {
                    var o: [String: Any] = ["start": Double(s.start), "end": Double(s.end), "text": s.text, "avgLogprob": Double(s.avgLogprob), "noSpeechProb": Double(s.noSpeechProb)]
                    if let words = s.words { o["words"] = words.map { ["start": Double($0.start), "end": Double($0.end), "text": $0.word] as [String: Any] } }
                    segments.append(o)
                }
            }
            send(["event": "result", "id": id, "language": results.first?.language ?? language ?? "", "segments": segments])
        } catch is CancellationError {
            send(["event": "cancelled", "id": id])
        } catch let f as Failure {
            send(["event": "error", "id": id, "message": f.message])
        } catch {
            if isCancelled { send(["event": "cancelled", "id": id]) }
            else { send(["event": "error", "id": id, "message": "Transcription failed: \(error.localizedDescription)"]) }
        }
    }

    /// The model for `size`, downloaded if needed and kept loaded for the next song.
    private func load(id: Int, size: String, folder: URL, offline: Bool) async throws -> WhisperKit {
        let variant = "openai_whisper-" + size
        lock.lock(); let existing = loadedVariant == variant ? pipe : nil; lock.unlock()
        if let existing { return existing }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // where WhisperKit keeps a downloaded model: <folder>/models/argmaxinc/whisperkit-coreml/<variant>
        let local = folder.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
        var modelFolder = local
        if !FileManager.default.fileExists(atPath: local.appendingPathComponent("MelSpectrogram.mlmodelc").path) {
            if offline { throw Failure(message: "The speech model has to be downloaded once, and Aureon is set to stay offline.") }
            send(["event": "progress", "id": id, "fraction": 0.0, "message": "Downloading the speech model"])
            modelFolder = try await WhisperKit.download(variant: variant, downloadBase: folder) { progress in
                send(["event": "progress", "id": id, "fraction": progress.fractionCompleted, "message": "Downloading the speech model"])
            }
        }
        send(["event": "progress", "id": id, "fraction": 0.0, "message": "Preparing the speech model"])
        let config = WhisperKitConfig(downloadBase: folder, modelFolder: modelFolder.path, verbose: false, logLevel: .none, prewarm: true, load: true, download: false)
        let p = try await WhisperKit(config)
        lock.lock(); pipe = p; loadedVariant = variant; lock.unlock()
        return p
    }

    func unload() { lock.lock(); pipe = nil; loadedVariant = ""; lock.unlock() }
}

let server = Server()
while let line = readLine(strippingNewline: true) {
    guard let d = line.data(using: .utf8), let msg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let op = msg["op"] as? String else {
        send(["event": "error", "message": "unreadable request"]); continue
    }
    switch op {
    case "ping": send(["event": "pong"])
    case "transcribe": server.start(msg)
    case "cancel": server.cancel(id: msg["id"] as? Int ?? -1)
    case "unload":
        server.cancel(id: msg["id"] as? Int ?? -1)
        server.unload()
        send(["event": "unloaded"])
        exit(0)
    default: send(["event": "error", "message": "unknown request \(op)"])
    }
}

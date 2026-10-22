import Foundation
import Accelerate

// Making lyrics from the recording itself, when a song has none anywhere: a small speech model (OpenAI's Whisper, run on this Mac) listens to the
// song and writes down what is sung, with the time of every line and word. Three parts:
//
//   • SpeechAudio       decodes the song with Aureon's own decoder, mixes it to mono and converts it to the 16 kHz the model takes
//   • the helper        the model runs in its own program (Packages/WhisperHelper), like Smart DJ's, so its memory goes back to the system the
//                       moment it is unloaded and a failure cannot take the player down
//   • WhisperLyrics     turns what the model returns into lyric lines: strips its markers, drops its well-known inventions on silence, splits
//                       long passages into singable lines and marks instrumental stretches
//
// It is an Intelligence feature (`IntelligenceFeature.lyricsGeneration`): off with the master switch, never sent to an API, and only ever run
// after the owner agrees for that song.

enum WhisperModelSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case tiny, base, small

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Parameters in millions: all far below the 1B cap on local models.
    var parametersMillions: Int { switch self { case .tiny: 39; case .base: 74; case .small: 244 } }
    var approxMB: Int { switch self { case .tiny: 75; case .base: 145; case .small: 470 } }
    var detail: String {
        switch self {
        case .tiny: "Fastest, roughly \(approxMB) MB. Fine for clear vocals."
        case .base: "Balanced, roughly \(approxMB) MB. The default."
        case .small: "Most accurate, roughly \(approxMB) MB. Slower, especially on Intel Macs."
        }
    }
}

struct TranscribedWord: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct TranscribedSegment: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var words: [TranscribedWord] = []
    /// The model's own confidence figures, when it gives them.
    var avgLogprob: Double? = nil
    var noSpeechProb: Double? = nil
}

struct Transcription: Equatable, Sendable {
    var segments: [TranscribedSegment]
    var language: String?
    var model: WhisperModelSize
}

enum LyricsError: LocalizedError, Equatable {
    case helperMissing
    case failed(String)
    case stopped
    case stalled
    case unsupported(String)
    case offline

    var errorDescription: String? {
        switch self {
        case .helperMissing: "The lyrics model is not installed with this copy of Aureon."
        case .failed(let m): m
        case .stopped: "The lyrics model stopped unexpectedly."
        case .stalled: "The lyrics model stopped answering."
        case .unsupported(let m): m
        case .offline: "The speech model has to be downloaded once, and Aureon is set to stay offline."
        }
    }
}

/// A speech model that turns a prepared audio file into timed text. The real one is a separate program; tests use stand-ins.
protocol LyricsTranscribing: AnyObject, Sendable {
    /// `progress` gets 0…1 and a short message (model download, then listening). Throws `CancellationError` after `cancel()`.
    func transcribe(audio: URL, model: WhisperModelSize, language: String?, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcription
    /// Stops the running job as soon as the model allows.
    func cancel()
    /// Frees the model completely. Safe when nothing is loaded.
    func unload() async
}

// MARK: - Audio for the model

enum SpeechAudio {
    static let sampleRate = 16_000.0

    /// Averages all channels into one. Runs on the producer-style pull chain, never on the audio thread.
    final class MonoMix: FrameSource {
        private let upstream: FrameSource
        private let ch: Int
        private let scratch: UnsafeMutablePointer<Int32>
        private let capacity = 8192
        let info: StreamInfo

        init(_ upstream: FrameSource) {
            self.upstream = upstream; ch = max(1, upstream.info.channels)
            scratch = .allocate(capacity: capacity * ch)
            var i = upstream.info; i.channels = 1; i.transparent = false
            info = i
        }
        deinit { scratch.deallocate() }

        func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
            let n = upstream.read(into: scratch, frames: min(frames, capacity))
            for f in 0..<n {
                var sum = 0
                for c in 0..<ch { sum += Int(scratch[f * ch + c]) }
                buf[f] = Int32(clamping: sum / ch)
            }
            return n
        }
        func seek(to frame: Int64) { upstream.seek(to: frame) }
    }

    /// Writes the song at `path` as a 16 kHz mono 16-bit WAV at `url`. Returns the length in seconds. `progress` gets 0…1.
    @discardableResult
    static func prepare(path: String, to url: URL, cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> Double {
        let file: FrameSource
        do { file = try openLossless(path: path) } catch { throw LyricsError.unsupported("This kind of file cannot be read for lyrics (\((path as NSString).pathExtension.uppercased())).") }
        guard file.info.totalFrames > 0, file.info.sampleRate > 0 else { throw LyricsError.unsupported("The song has no audio.") }
        var source: FrameSource = MonoMix(file)
        if abs(file.info.sampleRate - sampleRate) > 0.5 {
            // speech needs little: a gentle filter keeps the design short (and fast) even for 352.8 kHz files
            guard let r = ResamplingSource(source, outRate: sampleRate, config: ResamplerConfig(phase: .linear, passband: 0.9, stopbandDB: 80)) else {
                throw LyricsError.unsupported("The song's sample rate (\(Int(file.info.sampleRate)) Hz) cannot be converted for lyrics.")
            }
            source = r
        }
        let total = max(1, source.info.totalFrames)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw LyricsError.failed("Could not create a working file.") }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        try out.write(contentsOf: wavHeader(samples: 0))
        let chunk = 16_384
        let pcm = UnsafeMutablePointer<Int32>.allocate(capacity: chunk); defer { pcm.deallocate() }
        var written = 0, lastReport = 0.0
        while true {
            if cancelled() { throw CancellationError() }
            let n = source.read(into: pcm, frames: chunk)
            if n == 0 { break }
            var bytes = Data(count: n * 2)
            bytes.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<n {
                    // 32-bit left-justified → 16-bit, rounded
                    let v = (Int(pcm[i]) + 0x8000) >> 16
                    p[i] = Int16(truncatingIfNeeded: max(-32768, min(32767, v))).littleEndian
                }
            }
            try out.write(contentsOf: bytes)
            written += n
            let f = min(1, Double(written) / Double(total))
            if f - lastReport >= 0.02 { lastReport = f; progress(f) }
        }
        try out.seek(toOffset: 0)
        try out.write(contentsOf: wavHeader(samples: written))
        progress(1)
        return Double(written) / sampleRate
    }

    static func wavHeader(samples: Int) -> Data {
        func le32(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
        func le16(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255)]) }
        let bytes = samples * 2
        var d = Data("RIFF".utf8)
        d += le32(36 + bytes) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(Int(sampleRate)) + le32(Int(sampleRate) * 2) + le16(2) + le16(16)
        d += Data("data".utf8) + le32(bytes)
        return d
    }

    /// A tag's language ("eng", "fra", "en") as the two-letter code the model takes, or nil to let the model decide.
    static func languageCode(_ tag: String?) -> String? {
        guard let t = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        if t.count == 2 { return t }
        let map = ["eng": "en", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "spa": "es", "ita": "it", "por": "pt", "jpn": "ja", "kor": "ko",
                   "zho": "zh", "chi": "zh", "rus": "ru", "nld": "nl", "dut": "nl", "swe": "sv", "nor": "no", "nob": "no", "dan": "da", "fin": "fi",
                   "pol": "pl", "tur": "tr", "ara": "ar", "hin": "hi", "ces": "cs", "cze": "cs", "ell": "el", "gre": "el", "heb": "he", "hun": "hu",
                   "ukr": "uk", "vie": "vi", "tha": "th", "ind": "id", "cat": "ca"]
        return map[t] ?? (t.count >= 3 ? map[String(t.prefix(3))] : nil)
    }
}

// MARK: - From the model's words to lyric lines

enum WhisperLyrics {
    /// What the model writes over silence and music: not lyrics. Matched in lower case anywhere in a segment.
    static let inventions = ["thanks for watching", "thank you for watching", "subtitles by", "subtitled by", "amara.org", "please subscribe", "like and subscribe",
                             "transcribed by", "translated by", "www.", ".com", "copyright", "all rights reserved"]
    static let maxLineCharacters = 56
    static let breakGap = 0.75
    static let instrumentalGap = 8.0

    /// Without the model's markers (`<|0.00|>`), runs of spaces, and the music notes it puts around sung lines.
    static func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[♪♫♬🎵🎶]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "[Music]", "(upbeat music)", "[BLANK_AUDIO]", "*instrumental*", or only notes: the model describing what it hears, not words.
    static func isMusicCue(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.allSatisfy({ "♪♫♬🎵🎶 .-–—*".contains($0) }) { return true }
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("*", "*"), ("♪", "♪"), ("{", "}")]
        for (a, b) in pairs where t.first == a && t.last == b && t.count >= 2 {
            let inner = t.dropFirst().dropLast().lowercased()
            if inner.contains("music") || inner.contains("instrumental") || inner.contains("blank") || inner.contains("silence") || inner.contains("applause")
                || inner.contains("noise") || inner.contains("guitar") || inner.contains("piano") || inner.contains("drum") || inner.contains("singing") || inner.contains("humming")
                || inner.contains("sound") || inner.count <= 2 { return true }
        }
        return false
    }

    static func isInvention(_ s: String) -> Bool { let l = s.lowercased(); return inventions.contains { l.contains($0) } }

    /// Lyrics from a transcription, or nil when nothing was made out.
    static func build(_ t: Transcription, title: String? = nil, artist: String? = nil, album: String? = nil) -> Lyrics? {
        // 1. what is words, what is a pause
        enum Piece { case words(TranscribedSegment), pause(Double) }
        var pieces: [Piece] = []
        for seg in t.segments.sorted(by: { $0.start < $1.start }) {
            let text = clean(seg.text)
            let silent = (seg.noSpeechProb ?? 0) > 0.8 && (seg.avgLogprob ?? 0) < -1.0
            if isMusicCue(seg.text) || silent { pieces.append(.pause(seg.start)); continue }
            if text.isEmpty || isInvention(text) { continue }
            var s = seg; s.text = text
            s.words = seg.words.map { TranscribedWord(start: $0.start, end: $0.end, text: clean($0.text)) }.filter { !$0.text.isEmpty }
            pieces.append(.words(s))
        }
        // 2. the same text over and over is the model stuck in a loop, not a chorus: a run keeps four
        var run = 0, previous = ""
        pieces = pieces.filter { p in
            guard case .words(let s) = p else { run = 0; previous = ""; return true }
            let k = s.text.lowercased().filter { $0.isLetter || $0.isNumber }
            if k == previous { run += 1 } else { run = 1; previous = k }
            return run <= 4
        }
        // 3. lines
        var lines: [LyricLine] = []
        var lastEnd = 0.0
        let spaced = !(["zh", "ja", "th"].contains(t.language ?? ""))           // these are written without spaces between words
        func addBreak(at time: Double) { if lines.last?.isBreak != true, !lines.isEmpty { lines.append(LyricLine(id: 0, time: time, text: "")) } }
        for p in pieces {
            switch p {
            case .pause(let at):
                addBreak(at: max(at, lastEnd))
            case .words(let seg):
                for part in split(seg, spaced: spaced) {
                    // a long silence before a line is an instrumental passage: close the one before
                    if !lines.isEmpty, part.time - lastEnd > instrumentalGap { addBreak(at: lastEnd + 1) }
                    lines.append(LyricLine(id: 0, time: max(part.time, lines.last?.time ?? 0), text: part.text, words: part.words))
                    lastEnd = max(lastEnd, part.end)
                }
            }
        }
        while lines.last?.isBreak == true { lines.removeLast() }
        guard lines.contains(where: { !$0.isBreak }) else { return nil }
        for i in lines.indices { lines[i].id = i }
        var l = Lyrics(lines: lines, synced: true, origin: .generated, source: "Whisper \(t.model.rawValue)", title: title, artist: artist, album: album)
        l.language = t.language
        return l
    }

    struct Part: Equatable { var time: Double; var end: Double; var text: String; var words: [LyricWord] }

    /// One segment → one or more lines of a singable length, split at pauses between words, then at length.
    static func split(_ seg: TranscribedSegment, spaced: Bool = true) -> [Part] {
        if seg.words.count >= 2 {
            var parts: [Part] = []
            var cur: [TranscribedWord] = []
            func flush() {
                guard let first = cur.first, let last = cur.last else { return }
                // words carry their own spacing: a leading space for every word but the first
                let words = cur.enumerated().map { LyricWord(start: $1.start, text: ($0 == 0 || !spaced || $1.text.first?.isWhitespace == true ? "" : " ") + $1.text) }
                parts.append(Part(time: first.start, end: last.end, text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces), words: words))
                cur = []
            }
            for w in seg.words {
                if let last = cur.last {
                    let length = cur.reduce(0) { $0 + $1.text.count + 1 } + w.text.count
                    if w.start - last.end > breakGap || (length > maxLineCharacters && cur.count >= 3) { flush() }
                }
                cur.append(w)
            }
            flush()
            return parts
        }
        // no word times: split the text, share the time by length
        let pieces = splitText(seg.text)
        let total = max(1, pieces.reduce(0) { $0 + $1.count })
        var t = seg.start
        let span = max(0.5, seg.end - seg.start)
        return pieces.map { s in
            let d = span * Double(s.count) / Double(total)
            defer { t += d }
            return Part(time: t, end: t + d, text: s, words: [])
        }
    }

    /// Splits at sentence and clause punctuation, then at the space nearest the middle, until each piece fits a line.
    static func splitText(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count > maxLineCharacters else { return t.isEmpty ? [] : [t] }
        let chars = Array(t)
        // the punctuation break nearest the middle, if any is far enough from the ends
        var best: Int?
        for (i, c) in chars.enumerated() where ",;.!?".contains(c) && i > 10 && i < chars.count - 10 {
            if best == nil || abs(i - chars.count / 2) < abs(best! - chars.count / 2) { best = i }
        }
        var cut = best.map { $0 + 1 }
        if cut == nil {
            var i = chars.count / 2
            while i < chars.count, chars[i] != " " { i += 1 }
            if i >= chars.count { i = chars.count / 2; while i > 0, chars[i] != " " { i -= 1 } }
            cut = i
        }
        guard let c = cut, c > 0, c < chars.count else { return [t] }
        return splitText(String(chars[..<c])) + splitText(String(chars[c...]))
    }
}

// MARK: - The helper program

enum WhisperHelperLocator {
    static let name = "AureonWhisper"

    /// An override for development, the app bundle, or the build folder next to the source tree.
    static func find(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main, cwd: String = FileManager.default.currentDirectoryPath) -> URL? {
        var candidates: [URL] = []
        if let p = environment["AUREON_WHISPER_HELPER"], !p.isEmpty { candidates.append(URL(fileURLWithPath: p)) }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(name)/\(name)"))
        for base in [cwd, URL(fileURLWithPath: cwd).deletingLastPathComponent().path] {
            candidates.append(URL(fileURLWithPath: base).appendingPathComponent("Packages/WhisperHelper/.build/xcode/Build/Products/Release/\(name)"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Where downloaded models are kept (shared by all sizes).
    static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon/Whisper", isDirectory: true)
    }
}

/// Talks to the helper over a pipe, one JSON object per line:
///
///     → {"op":"transcribe","id":3,"path":"/tmp/x.wav","model":"base","language":"en","folder":"…/Aureon/Whisper","offline":false}
///     ← {"event":"progress","id":3,"fraction":0.4,"message":"Downloading the speech model"}      (zero or more)
///     ← {"event":"result","id":3,"language":"en","segments":[{"start":1.2,"end":4.5,"text":"…","words":[{"start":1.2,"end":1.5,"text":"Hello"}],"avgLogprob":-0.3,"noSpeechProb":0.02}]}
///     ← {"event":"error","id":3,"message":"…"}
///     → {"op":"cancel","id":3}        → {"op":"unload"}  ← {"event":"unloaded"}  (then the program exits)
final class WhisperHelperProcess: LyricsTranscribing, @unchecked Sendable {
    let executable: URL
    var modelFolder = WhisperHelperLocator.modelFolder
    /// No word from the helper for this long: it is stuck, and is ended.
    var stallTimeout: TimeInterval = 240
    var offline: @Sendable () -> Bool = { ProcessInfo.processInfo.environment["AUREON_OFFLINE"] != nil }
    var quitGrace: TimeInterval = 2

    private struct Job {
        var id: Int
        var model: WhisperModelSize
        var continuation: CheckedContinuation<Transcription, Error>
        var progress: @Sendable (Double, String) -> Void
        var lastEvent: Date
    }

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var job: Job?
    private var lastStderr = ""

    init(executable: URL) { self.executable = executable }
    deinit { lock.lock(); let p = process; lock.unlock(); if let p, p.isRunning { p.terminate() } }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }

    // MARK: process

    private func launch() throws {
        lock.lock(); defer { lock.unlock() }
        if let p = process, p.isRunning { return }
        let p = Process(), inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.executableURL = executable
        p.currentDirectoryURL = executable.deletingLastPathComponent()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        buffer = Data(); lastStderr = ""
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.received(d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.lock.lock(); self?.lastStderr = String(((self?.lastStderr ?? "") + String(decoding: d, as: UTF8.self)).suffix(600)); self?.lock.unlock()
        }
        p.terminationHandler = { [weak self, weak p] _ in self?.exited(p) }
        do { try p.run() } catch { throw LyricsError.failed("Could not start the lyrics model: \(error.localizedDescription)") }
        process = p; stdin = inPipe.fileHandleForWriting
    }

    private func exited(_ p: Process?) {
        lock.lock()
        guard process === p || process == nil else { lock.unlock(); return }
        let why = lastStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let j = job
        job = nil; process = nil; stdin = nil
        lock.unlock()
        j?.continuation.resume(throwing: why.isEmpty ? LyricsError.stopped : LyricsError.failed("The lyrics model stopped: \(String(why.suffix(200)))"))
    }

    private func send(_ o: [String: Any]) throws {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        lock.lock(); let h = stdin; lock.unlock()
        guard let h else { throw LyricsError.stopped }
        do { try h.write(contentsOf: d + Data("\n".utf8)) } catch { throw LyricsError.stopped }
    }

    private func received(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 10) { lines.append(buffer.subdata(in: buffer.startIndex..<nl)); buffer.removeSubrange(buffer.startIndex...nl) }
        lock.unlock()
        for l in lines { handle(l) }
    }

    private func handle(_ line: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let ev = o["event"] as? String else { return }
        let id = o["id"] as? Int
        lock.lock()
        guard var j = job, id == nil || id == j.id else { lock.unlock(); return }
        j.lastEvent = Date(); job = j
        lock.unlock()
        switch ev {
        case "progress":
            j.progress((o["fraction"] as? Double) ?? 0, (o["message"] as? String) ?? "")
        case "result":
            lock.lock(); job = nil; lock.unlock()
            j.continuation.resume(returning: Transcription(segments: Self.segments(o["segments"]), language: o["language"] as? String, model: j.model))
        case "cancelled":
            lock.lock(); job = nil; lock.unlock()
            j.continuation.resume(throwing: CancellationError())
        case "error":
            lock.lock(); job = nil; lock.unlock()
            j.continuation.resume(throwing: LyricsError.failed((o["message"] as? String) ?? "The lyrics model reported an error."))
        default: break
        }
    }

    static func segments(_ any: Any?) -> [TranscribedSegment] {
        guard let a = any as? [[String: Any]] else { return [] }
        func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
        return a.compactMap { s in
            guard let start = num(s["start"]), let end = num(s["end"]), let text = s["text"] as? String else { return nil }
            let words = ((s["words"] as? [[String: Any]]) ?? []).compactMap { w -> TranscribedWord? in
                guard let ws = num(w["start"]), let we = num(w["end"]), let wt = w["text"] as? String else { return nil }
                return TranscribedWord(start: ws, end: we, text: wt)
            }
            return TranscribedSegment(start: start, end: end, text: text, words: words, avgLogprob: num(s["avgLogprob"]), noSpeechProb: num(s["noSpeechProb"]))
        }
    }

    // MARK: LyricsTranscribing

    func transcribe(audio: URL, model: WhisperModelSize, language: String?, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcription {
        try launch()
        lock.lock(); nextID += 1; let id = nextID; lock.unlock()
        var request: [String: Any] = ["op": "transcribe", "id": id, "path": audio.path, "model": model.rawValue, "folder": modelFolder.path, "offline": offline()]
        if let language { request["language"] = language }
        do {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Transcription, Error>) in
                lock.lock(); job = Job(id: id, model: model, continuation: c, progress: progress, lastEvent: Date()); lock.unlock()
                watch(id)
                do { try send(request) } catch {
                    lock.lock(); let j = job; job = nil; lock.unlock(); j?.continuation.resume(throwing: error)
                }
            }
        } catch {
            if case LyricsError.stalled = error { terminateNow() }
            throw error
        }
    }

    /// Ends the helper when it has said nothing for `stallTimeout` (a stuck model cannot be interrupted).
    private func watch(_ id: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard let j = self.job, j.id == id else { self.lock.unlock(); return }
            let idle = Date().timeIntervalSince(j.lastEvent)
            if idle > self.stallTimeout { self.job = nil; self.lock.unlock(); j.continuation.resume(throwing: LyricsError.stalled); self.terminateNow(); return }
            self.lock.unlock()
            self.watch(id)
        }
    }

    func cancel() {
        lock.lock(); let j = job; lock.unlock()
        guard let j else { return }
        try? send(["op": "cancel", "id": j.id])
        // the helper answers "cancelled"; if it does not within a few seconds it is stuck in a step it cannot leave, and is ended
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let still = self.job?.id == j.id; let cur = self.job; if still { self.job = nil }; self.lock.unlock()
            if still { cur?.continuation.resume(throwing: CancellationError()); self.terminateNow() }
        }
    }

    func unload() async {
        lock.lock(); let p = process; let alive = p?.isRunning == true; lock.unlock()
        guard let p, alive else { lock.lock(); process = nil; stdin = nil; lock.unlock(); return }
        try? send(["op": "unload"])
        let deadline = Date().addingTimeInterval(quitGrace)
        while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        if p.isRunning { p.terminate() }
        let hard = Date().addingTimeInterval(1)
        while p.isRunning && Date() < hard { try? await Task.sleep(nanoseconds: 20_000_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
        lock.lock(); process = nil; stdin = nil; lock.unlock()
    }

    private func terminateNow() {
        lock.lock(); let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

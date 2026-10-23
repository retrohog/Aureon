import Foundation

/// A language model that answers Smart DJ's questions. The real one is a separate program (see Packages/SmartDJHelper); tests use stand-ins.
protocol SmartDJBackend: AnyObject, Sendable {
    var isLoaded: Bool { get }
    /// Starts the model. `progress` gets 0…1 and a short message while it downloads and loads.
    func load(model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws
    /// Returns the model's answer, constrained to the JSON schema.
    func generate(system: String, user: String, schema: String, maxTokens: Int) async throws -> String
    /// Frees the model completely. Safe to call when nothing is loaded.
    func unload() async
}

enum SmartDJError: LocalizedError {
    case helperMissing
    case failed(String)
    case timedOut
    case stopped
    var errorDescription: String? {
        switch self {
        case .helperMissing: "The Smart DJ language model is not installed with this copy of Aureon."
        case .failed(let m): m
        case .timedOut: "The language model took too long to answer."
        case .stopped: "The language model stopped unexpectedly."
        }
    }
}

enum SmartDJHelperLocator {
    static let name = "AureonSmartDJ"

    /// The helper program: an override for development, the app bundle, or the build folder next to the source tree.
    static func find(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main, cwd: String = FileManager.default.currentDirectoryPath) -> URL? {
        var candidates: [URL] = []
        if let p = environment["AUREON_SMARTDJ_HELPER"], !p.isEmpty { candidates.append(URL(fileURLWithPath: p)) }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(name)/\(name)"))
        for base in [cwd, URL(fileURLWithPath: cwd).deletingLastPathComponent().path] {
            candidates.append(URL(fileURLWithPath: base).appendingPathComponent("Packages/SmartDJHelper/.build/xcode/Build/Products/Release/\(name)"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) && MachOSlices.canRun($0) }
    }
}

/// Talks to the helper program over a pipe, one JSON object per line.
final class HelperProcessBackend: SmartDJBackend, @unchecked Sendable {
    let executable: URL
    var generateTimeout: TimeInterval = 90
    var loadTimeout: TimeInterval = 900
    var quitGrace: TimeInterval = 2

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var loaded = false
    private var nextID = 0
    private var loadWaiter: CheckedContinuation<Void, Error>?
    private var loadProgress: (@Sendable (Double, String) -> Void)?
    private var waiters: [Int: CheckedContinuation<String, Error>] = [:]
    private var lastStderr = ""
    private(set) var launches = 0

    init(executable: URL) { self.executable = executable }
    deinit { terminateNow() }

    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded && process?.isRunning == true }
    var processID: Int32? { lock.lock(); defer { lock.unlock() }; return process?.processIdentifier }

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
            self?.noteStderr(d)
        }
        p.terminationHandler = { [weak self, weak p] _ in self?.exited(p) }
        do { try p.run() } catch { throw SmartDJError.failed("Could not start the language model: \(error.localizedDescription)") }
        process = p; stdin = inPipe.fileHandleForWriting; loaded = false; launches += 1
    }

    private func noteStderr(_ d: Data) {
        lock.lock(); lastStderr = String((lastStderr + String(decoding: d, as: UTF8.self)).suffix(600)); lock.unlock()
    }

    private func exited(_ p: Process?) {
        lock.lock()
        guard process === p || process == nil else { lock.unlock(); return }
        let why = lastStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = waiters, lw = loadWaiter
        waiters = [:]; loadWaiter = nil; loaded = false; process = nil; stdin = nil
        lock.unlock()
        let err = SmartDJError.failed(why.isEmpty ? SmartDJError.stopped.localizedDescription : "The language model stopped: \(String(why.suffix(200)))")
        for (_, c) in w { c.resume(throwing: err) }
        lw?.resume(throwing: err)
    }

    private func send(_ o: [String: Any]) throws {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        lock.lock(); let h = stdin; lock.unlock()
        guard let h else { throw SmartDJError.stopped }
        do { try h.write(contentsOf: d + Data("\n".utf8)) } catch { throw SmartDJError.stopped }
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
        switch ev {
        case "progress":
            lock.lock(); let cb = loadProgress; lock.unlock()
            cb?((o["fraction"] as? Double) ?? 0, (o["message"] as? String) ?? "")
        case "loaded":
            lock.lock(); loaded = true; let w = loadWaiter; loadWaiter = nil; loadProgress = nil; lock.unlock()
            w?.resume()
        case "result":
            lock.lock(); let w = waiters.removeValue(forKey: (o["id"] as? Int) ?? -1); lock.unlock()
            w?.resume(returning: (o["text"] as? String) ?? "")
        case "error":
            let m = SmartDJError.failed((o["message"] as? String) ?? "The language model reported an error.")
            lock.lock()
            if let id = o["id"] as? Int { let w = waiters.removeValue(forKey: id); lock.unlock(); w?.resume(throwing: m) }
            else { let w = loadWaiter; loadWaiter = nil; lock.unlock(); w?.resume(throwing: m) }
        default: break
        }
    }

    // MARK: SmartDJBackend

    func load(model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        try launch()
        lock.lock(); loadProgress = progress; lock.unlock()
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); loadWaiter = c; lock.unlock()
                // a continuation cannot be cancelled, so the timeout resumes it itself
                DispatchQueue.global().asyncAfter(deadline: .now() + loadTimeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let w = self.loadWaiter; self.loadWaiter = nil; self.lock.unlock()
                    w?.resume(throwing: SmartDJError.timedOut)
                }
                do { try send(["op": "load", "model": model]) } catch {
                    lock.lock(); let w = loadWaiter; loadWaiter = nil; lock.unlock(); w?.resume(throwing: error)
                }
            }
        } catch {
            await unload()
            throw error
        }
    }

    func generate(system: String, user: String, schema: String, maxTokens: Int) async throws -> String {
        guard isLoaded else { throw SmartDJError.stopped }
        lock.lock(); nextID += 1; let id = nextID; lock.unlock()
        let schemaObj = (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) ?? [:]
        do {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                lock.lock(); waiters[id] = c; lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + generateTimeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let w = self.waiters.removeValue(forKey: id); self.lock.unlock()
                    w?.resume(throwing: SmartDJError.timedOut)
                }
                do { try send(["op": "generate", "id": id, "system": system, "user": user, "schema": schemaObj, "maxTokens": maxTokens]) } catch {
                    lock.lock(); let w = waiters.removeValue(forKey: id); lock.unlock(); w?.resume(throwing: error)
                }
            }
        } catch {
            if case SmartDJError.timedOut = error { terminateNow() }              // a stuck model cannot be interrupted: end it
            throw error
        }
    }

    func unload() async {
        lock.lock(); let p = process; let alive = p?.isRunning == true; lock.unlock()
        guard let p, alive else { lock.lock(); process = nil; stdin = nil; loaded = false; lock.unlock(); return }
        try? send(["op": "unload"])
        let deadline = Date().addingTimeInterval(quitGrace)
        while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        if p.isRunning { p.terminate() }
        let hard = Date().addingTimeInterval(1)
        while p.isRunning && Date() < hard { try? await Task.sleep(nanoseconds: 20_000_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
        lock.lock(); loaded = false; process = nil; stdin = nil; lock.unlock()
    }

    private func terminateNow() {
        lock.lock(); let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

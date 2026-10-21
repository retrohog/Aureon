import Foundation

struct DaemonTests {
    final class Output: @unchecked Sendable {
        let lock = NSLock(); private var text = ""
        func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    /// Starts the real `Aureon daemon` as a child process and drives it over the network.
    func daemonProcessEndToEnd() {
        guard let exe = Bundle.main.executablePath else { expect(false, "no executable path"); return }
        let dir = realPath(tempDir("daemon-\(UUID().uuidString.prefix(6))"))
        let music = dir.appendingPathComponent("Music"); try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for n in 1...3 { writeWAV(music.appendingPathComponent("track\(n).wav"), rate: 8000, bits: 24, frames: 80_000) { i, c in c == 0 ? n : i } }
        let tokenFile = dir.appendingPathComponent("token"), library = dir.appendingPathComponent("lib.sqlite")

        let p = Process(); p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["daemon", "--no-bonjour", "--null-sink", "--name", "Test daemon", "--music", music.path, "--library", library.path, "--token-file", tokenFile.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        let log = Output()
        out.fileHandleForReading.readabilityHandler = { h in log.append(String(decoding: h.availableData, as: UTF8.self)) }
        try! p.run()
        defer { if p.isRunning { p.terminate() }; p.waitUntilExit(); out.fileHandleForReading.readabilityHandler = nil }

        var port: UInt16 = 0
        let end = Date().addingTimeInterval(15)
        while port == 0 && Date() < end {
            if let r = log.value.range(of: "listening on port "), let n = UInt16(log.value[r.upperBound...].prefix { $0.isNumber }) { port = n } else { usleep(50_000) }
        }
        expect(port != 0, "the daemon announces its port: \(log.value)")
        guard port != 0 else { return }
        let token = (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        expect(token.count == 48, "a pairing token was created")
        let perms = (try? FileManager.default.attributesOfItem(atPath: tokenFile.path))?[.posixPermissions] as? Int
        expect(perms == 0o600, "the token file is private to its owner: \(String(describing: perms))")
        expect(log.value.contains("pairing token: \(token)") && log.value.contains("music folders:"))

        let c = RemoteClient(url: URL(string: "ws://127.0.0.1:\(port)/")!, token: token)
        expect(runAsync { try await c.connect() }.isSuccessWith { _ in true } && c.serverName == "Test daemon", "connected to the daemon")
        defer { c.close() }

        // the background scan fills the library while the server is already usable
        var stats = LibraryStats()
        let deadline = Date().addingTimeInterval(15)
        while stats.tracks < 3 && Date() < deadline { stats = (try? runAsync { try await c.call("library.stats", as: LibraryStats.self) }.get()) ?? stats; usleep(100_000) }
        expect(stats.tracks == 3, "scanned \(stats.tracks) tracks; log: \(log.value)")

        let mirror = LibraryMirror()
        try! runAsync { try await c.syncLibrary(into: mirror) }.get()
        expect(mirror.tracks.count == 3, "a remote app can browse the library")
        let ids = mirror.tracks.values.sorted { $0.path < $1.path }.map(\.id)
        let snap = try! runAsync { try await c.call("queue.add", ["trackIDs": ids, "play": true], as: [QueueEntryDTO].self) }.get()
        expect(snap.count == 3)
        var st = RemoteStatus(state: "", entryID: nil, title: "", artist: "", album: "", position: 0, duration: 0, codec: "", bitDepth: 0, sampleRate: 0, bitPerfect: false, pipeline: [], deviceName: "", volume: nil, errors: [], serverTime: 0)
        let t0 = Date().addingTimeInterval(10)
        while st.state != "playing" && Date() < t0 { st = (try? runAsync { try await c.call("status.get", as: RemoteStatus.self) }.get()) ?? st; usleep(50_000) }
        expect(st.state == "playing" && st.title == "track1" && st.deviceName.contains("null"), "playing through the null sink: \(st.state) \(st.title) \(st.deviceName)")
        let outside = runAsync { try await c.callData("queue.add", ["paths": ["/etc/hosts"]]) }
        if case .failure(let e) = outside { expect((e as? RemoteError)?.code == RemoteErrorCode.forbidden, "paths outside --music are refused: \(e)") } else { expect(false, "must refuse") }

        // a graceful stop
        p.terminate()
        let stopBy = Date().addingTimeInterval(10)
        while p.isRunning && Date() < stopBy { usleep(50_000) }
        expect(!p.isRunning && p.terminationStatus == 0, "SIGTERM stops the daemon cleanly (status \(p.terminationStatus))")
        usleep(200_000)
        expect(log.value.contains("daemon stopped"))
    }

    func launchAgentPlistIsWellFormed() {
        let plist = launchAgentPlist(executable: "/Applications/Aureon.app/Contents/MacOS/Aureon", arguments: ["--name", "Study", "--music", "/Volumes/Music"])
        let d = try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        expect(d?["Label"] as? String == "org.aureon.daemon" && d?["RunAtLoad"] as? Bool == true && d?["KeepAlive"] as? Bool == true)
        expect((d?["ProgramArguments"] as? [String]) == ["/Applications/Aureon.app/Contents/MacOS/Aureon", "daemon", "--name", "Study", "--music", "/Volumes/Music"], "\(String(describing: d?["ProgramArguments"]))")
    }

    func tokenFileIsStable() {
        let f = tempDir("tok").appendingPathComponent("t-\(UUID().uuidString.prefix(5))")
        let a = loadOrCreateToken(at: f), b = loadOrCreateToken(at: f)
        expect(a == b && a.count == 48, "the same token every time, so paired apps keep working")
        expect(((try? FileManager.default.attributesOfItem(atPath: f.path))?[.posixPermissions] as? Int) == 0o600)
    }

    func nullSinkPlaysInRealTime() {
        let dir = tempDir("null")
        let t = writeWAV(dir.appendingPathComponent("n.wav"), rate: 8000, bits: 24, frames: 16_000) { i, _ in i }      // 2 s
        let p = Player(); var o = PlayerOptions(); o.sinkFactory = { _ in NullSink() }
        p.setQueue([t.path]); p.start(options: o)
        let t0 = Date()
        expect(p.waitUntilFinished(timeout: 10))
        let took = Date().timeIntervalSince(t0)
        expect(took > 1.6 && took < 4, "2 s of audio takes about 2 s: \(took)")
    }
}

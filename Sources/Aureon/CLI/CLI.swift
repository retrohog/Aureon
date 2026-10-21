import Foundation
import CoreAudio
import AudioToolbox

// Command line interface. `Aureon` with no arguments opens the GUI.

let usage = """
Aureon — bit-perfect music player

  Aureon                       open the app
  Aureon play [options] <file>...
  Aureon inspect <file>        stream format, tags and loudness
  Aureon verify <a> <b>        prove two files decode to identical samples
  Aureon devices               output devices and their rates
  Aureon selftest [filter]     run the built-in test suite
  Aureon daemon [options]      headless audio engine + network remote control (see below)
  Aureon hwdebug [options]     hardware path diagnostics (hog mode, integer mode, timing)

play options:
  --device <name>          output device (substring match)
  --hog                    exclusive access
  --no-rate-switch         do not follow the stream's sample rate
  --ram [MB]               load whole tracks into RAM before playing (default budget 1024 MB)
  --replaygain track|album [--preamp dB]
  --upsample off|2x|pow2|max [--phase linear|minimum] [--max-rate Hz]
  --dsd pcm|dop            DSD handling (dop needs a DoP-capable DAC)
  --invert                 invert polarity (not bit-transparent)
  --crossfeed [Hz dB]      Bauer BS2B crossfeed (default 700 Hz, 4.5 dB)
  --headphone-eq FILE      AutoEQ ParametricEQ.txt profile
  --convolve IR.wav        room correction by convolution (e.g. a Room EQ Wizard export)
  --buffer-sec N           decode-ahead length (default 5)
daemon options:
  --port N                 TCP port for the remote API (default: any free port)
  --name NAME              name shown to remote apps and in Bonjour
  --music DIR              music folder to scan; remote apps may only add files below it (repeatable; default ~/Music)
  --library FILE           library database (default ~/Library/Application Support/Aureon/Library.sqlite)
  --device NAME            output device
  --no-bonjour             do not advertise on the network
  --null-sink              decode and discard audio (servers without an audio device)
  --token-file FILE        where the pairing token is kept (default ~/Library/Application Support/Aureon/remote-token)
  --print-launchagent      print a launchd plist that starts the daemon at login (nothing is installed)
keys while playing: space pause · ←/→ seek 10 s · n/p next/previous · q quit
"""

// MARK: - Keyboard (raw terminal, non-blocking)

enum Key { case space, left, right, next, prev, quit }

final class Keyboard {
    private var saved = termios()
    private let active: Bool

    init() {
        active = isatty(STDIN_FILENO) != 0
        guard active else { return }
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)   // keep ISIG so Ctrl-C still works
        withUnsafeMutablePointer(to: &raw.c_cc) { $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { c in
            c[Int(VMIN)] = 0; c[Int(VTIME)] = 0 } }
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    func restore() { if active { tcsetattr(STDIN_FILENO, TCSANOW, &saved) } }

    /// Every key waiting in the buffer, in order (several can arrive in one read).
    func poll() -> [Key] {
        guard active else { return [] }
        var b = [UInt8](repeating: 0, count: 64)
        let n = read(STDIN_FILENO, &b, 64)
        var keys: [Key] = [], i = 0
        while i < n {
            switch b[i] {
            case 0x20: keys.append(.space)
            case UInt8(ascii: "q"): keys.append(.quit)
            case UInt8(ascii: "n"): keys.append(.next)
            case UInt8(ascii: "p"): keys.append(.prev)
            case 0x1b where i + 2 < n && b[i + 1] == UInt8(ascii: "["):
                if b[i + 2] == UInt8(ascii: "D") { keys.append(.left) } else if b[i + 2] == UInt8(ascii: "C") { keys.append(.right) }
                i += 2
            default: break
            }
            i += 1
        }
        return keys
    }
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds)); return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Commands

func openAny(_ path: String) throws -> FrameSource {
    let ext = (path as NSString).pathExtension.lowercased()
    if ext == "dsf" || ext == "dff" {
        let f = try DsdContainer(path: path)
        guard let s = DsdToPcmSource(f, codec: dsdRateName(f.dsdRate), pcmRate: 176_400, gainDB: 0) else { throw AureonError.message("cannot convert DSD") }
        return s
    }
    return try LosslessFile(path: path)
}

func cmdInspect(_ path: String) throws {
    let ext = (path as NSString).pathExtension.lowercased()
    print("file:      \(path)")
    if ext == "dsf" || ext == "dff" {
        let f = try DsdContainer(path: path)
        print("codec:     \(dsdRateName(f.dsdRate)) (\(ext.uppercased()))")
        print("format:    1-bit, \(Int(f.dsdRate)) Hz, \(f.channels) ch  → DoP at \(Int(f.dsdRate / 16)) Hz")
        print(String(format: "duration:  %.2f s", Double(f.totalBits) / f.dsdRate))
    } else {
        let f = try LosslessFile(path: path)
        let i = f.info
        print("codec:     \(i.codec)")
        print("format:    \(i.sourceBits)-bit, \(Int(i.sampleRate)) Hz, \(i.channels) ch")
        print(String(format: "duration:  %.2f s (%lld frames)", i.duration, i.totalFrames))
        if let a = analyzeTrack(path: path) { print(String(format: "peak:      %.1f dBFS · DR ≈ %.0f", a.peakDB, a.dynamicRange)) }
        if let l = Loudness.analyze(path: path) { print(String(format: "loudness:  %.1f LUFS (ReplayGain 2.0 gain %+.1f dB)", l.lufs, -18 - l.lufs)) }
        let t = ReplayGainReader.read(path: path)
        print("tags:      " + (t.isEmpty ? "no ReplayGain tags" : "track \(t.trackGain.map { String(format: "%+.2f dB", $0) } ?? "-"), album \(t.albumGain.map { String(format: "%+.2f dB", $0) } ?? "-")"))
    }
    if let dev = OutputDevice() { print("output:    \(dev.name), clock now \(Int(dev.currentRate)) Hz") }
}

func cmdDevices() {
    for d in listOutputDevices() {
        let cur = OutputDevice(id: d.id)?.currentRate ?? 0
        print("\(d.name): now \(Int(cur)) Hz; rates \(d.rates.map { String(Int($0)) }.joined(separator: ", "))")
    }
}

func cmdVerify(_ a: String, _ b: String) throws {
    let x = try openAny(a), y = try openAny(b)
    guard x.info.sampleRate == y.info.sampleRate, x.info.channels == y.info.channels else { fail("format mismatch: \(x.info) vs \(y.info)") }
    let n = 16_384, ch = x.info.channels
    let bx = UnsafeMutablePointer<Int32>.allocate(capacity: n * ch), by = UnsafeMutablePointer<Int32>.allocate(capacity: n * ch)
    var frames = 0, bad = 0
    while true {
        let rx = x.read(into: bx, frames: n), ry = y.read(into: by, frames: n)
        if rx != ry { bad += abs(rx - ry) * ch }
        let m = min(rx, ry)
        for i in 0..<(m * ch) where bx[i] != by[i] { bad += 1 }
        frames += m
        if rx == 0 || ry == 0 { break }
    }
    print("compared \(frames) frames x \(ch) ch (\(x.info.codec) \(x.info.sourceBits)-bit vs \(y.info.codec) \(y.info.sourceBits)-bit): \(bad == 0 ? "BIT-EXACT" : "\(bad) differing samples")")
    exit(bad == 0 ? 0 : 2)
}

func deviceID(matching name: String?) -> AudioDeviceID? {
    guard let name else { return nil }
    return listOutputDevices().first { $0.name.localizedCaseInsensitiveContains(name) }?.id
}

/// Argument reader that can look at the next token without consuming it (so optional values don't swallow the next flag).
struct ArgIter {
    private let a: [String]; private var i = 0
    init(_ a: [String]) { self.a = a }
    mutating func next() -> String? { guard i < a.count else { return nil }; defer { i += 1 }; return a[i] }
    func peek() -> String? { i < a.count ? a[i] : nil }
}

func cmdPlay(_ args: [String]) throws {
    var opt = PlayerOptions(), files: [String] = [], s = PlaybackSettings()
    var it = ArgIter(args)
    while let a = it.next() {
        switch a {
        case "--hog": opt.hog = true
        case "--no-rate-switch": opt.rateSwitch = false
        case "--buffer-sec": opt.bufferSeconds = Double(it.next() ?? "") ?? 5
        case "--device":
            let n = it.next()
            guard let id = deviceID(matching: n) else { fail("no output device matching \(n ?? "")") }
            opt.deviceID = id
        case "--ram": s.ram.enabled = true
        case "--ram-mb": s.ram.budgetMB = Int(it.next() ?? "") ?? 1024
        case "--replaygain": s.replayGain.mode = ReplayGainMode(rawValue: it.next() ?? "") ?? .track
        case "--preamp": s.replayGain.preampDB = Double(it.next() ?? "") ?? 0
        case "--upsample":
            switch it.next() { case "2x": s.upsampling.mode = .double; case "pow2": s.upsampling.mode = .powerOfTwo
            case "max": s.upsampling.mode = .deviceMax; default: s.upsampling.mode = .off }
        case "--phase": s.upsampling.filter.phase = it.next() == "minimum" ? .minimum : .linear
        case "--max-rate": s.upsampling.maxRate = Double(it.next() ?? "") ?? 0
        case "--dsd": s.dsd.mode = it.next() == "dop" ? .dop : .pcm
        case "--invert": s.polarityInverted = true
        case "--crossfeed":
            s.rt.crossfeed.enabled = true
            if let c = it.peek().flatMap(Double.init) { _ = it.next(); s.rt.crossfeed.cutoffHz = c; if let f = it.peek().flatMap(Double.init) { _ = it.next(); s.rt.crossfeed.feedDB = f } }
        case "--headphone-eq":
            guard let f = it.next(), let text = try? String(contentsOfFile: f, encoding: .utf8),
                  let p = AutoEQParser.parse(text, name: ((f as NSString).lastPathComponent as NSString).deletingPathExtension) else { fail("cannot read an AutoEQ profile from that file") }
            s.rt.headphoneEQ = HeadphoneEQSettings(enabled: true, profile: p)
        case "--convolve":
            guard let f = it.next() else { fail("--convolve needs an impulse response file") }
            s.rt.convolution = ConvolutionSettings(enabled: true, irPath: f, gainDB: 0, normalize: true)
        default: files.append(a)
        }
    }
    guard !files.isEmpty else { fail("no files") }

    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let player = Player()
    let sigSources = [SIGINT, SIGTERM].map { n -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: n, queue: .global()); s.setEventHandler { player.send(.stop) }; s.resume(); return s
    }
    defer { withExtendedLifetime(sigSources) {} }

    let kbd = Keyboard()
    defer { kbd.restore() }
    player.settings = s
    player.setQueue(files)
    player.start(options: opt)

    var lastID: UUID?, lastLines: [String] = []
    while true {
        for key in kbd.poll() {
            switch key {
            case .space: player.send(.togglePause)
            case .left: player.send(.seekBy(-10))
            case .right: player.send(.seekBy(10))
            case .next: player.send(.next)
            case .prev: player.send(.previous)
            case .quit: player.send(.stop)
            }
        }
        let st = player.status
        if st.finished { break }
        if let p = st.loadProgress { print("\r  loading into RAM \(Int(p * 100))%   ", terminator: ""); fflush(stdout) }
        if st.state == .playing || st.state == .paused, let info = st.info {
            if st.trackID != lastID || st.pathLines != lastLines {
                if lastID != nil { print("") }
                lastID = st.trackID; lastLines = st.pathLines
                let raw = st.sourceInfo ?? info
                print("▶ \(((files[min(st.trackIndex, files.count - 1)]) as NSString).lastPathComponent): \(raw.codec) \(raw.sourceBits)-bit \(Int(raw.sampleRate)) Hz \(raw.channels) ch")
                for l in st.pipeline { print("  · \(l)") }
                for l in st.rtStages { print("  ⚙ \(l)") }
                for l in st.pathLines { print("  → \(l)") }
                print("  stream: \(Int(info.sampleRate)) Hz\(info.isDoP ? " DoP" : "") — \(st.bitPerfect ? "bit-perfect" : "processed")")
            }
            print("\r  \(st.state == .paused ? "⏸" : "▶") \(clock(st.position)) / \(clock(st.duration))  buffer \(String(format: "%.1f", st.bufferedSeconds))s  underruns \(st.underruns)   ", terminator: "")
            fflush(stdout)
        }
        usleep(50_000)
    }
    print("")
    for e in player.status.errors { print("note: \(e)") }
    print("device restored")
}

func runCLI(_ args: [String]) {
    do {
        switch args.first {
        case "inspect" where args.count == 2: try cmdInspect(args[1])
        case "devices": cmdDevices()
        case "verify" where args.count == 3: try cmdVerify(args[1], args[2])
        case "play": try cmdPlay(Array(args.dropFirst()))
        case "selftest": exit(SelfTestRunner.run(filter: args.count > 1 ? args[1] : nil))
        case "daemon": try cmdDaemon(Array(args.dropFirst()))
        case "hwdebug": try cmdHardwareDebug(Array(args.dropFirst()))
        case "hog-probe": hogProbeMain(Array(args.dropFirst()))
        default: print(usage)
        }
    } catch {
        fail(error.localizedDescription)
    }
}


// MARK: - Headless daemon

func supportDirectory() -> URL {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aureon", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// The pairing token: created once, readable only by the owner.
func loadOrCreateToken(at url: URL) -> String {
    if let s = try? String(contentsOf: url, encoding: .utf8) { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if t.count >= 16 { return t } }
    let t = RemoteProtocol.newToken()
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data((t + "\n").utf8), attributes: [.posixPermissions: 0o600])
    return t
}

func launchAgentPlist(executable: String, arguments: [String]) -> String {
    let args = ([executable, "daemon"] + arguments).map { "        <string>\($0)</string>" }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>org.aureon.daemon</string>
        <key>ProgramArguments</key>
        <array>
    \(args)
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ProcessType</key><string>Interactive</string>
        <key>StandardOutPath</key><string>/tmp/aureon-daemon.log</string>
        <key>StandardErrorPath</key><string>/tmp/aureon-daemon.log</string>
    </dict>
    </plist>
    """
}

func cmdDaemon(_ args: [String]) throws {
    var port: UInt16 = 0, name = Host.current().localizedName ?? "Aureon", music: [String] = [], libraryPath: String?, deviceName: String?
    var bonjour = true, nullSink = false, tokenFile: String?, printAgent = false
    var passthrough: [String] = []
    var it = args.makeIterator()
    while let a = it.next() {
        passthrough.append(a)
        switch a {
        case "--port": port = UInt16(it.next() ?? "") ?? 0; passthrough.append(String(port))
        case "--name": name = it.next() ?? name; passthrough.append(name)
        case "--music": if let m = it.next() { music.append(m); passthrough.append(m) }
        case "--library": libraryPath = it.next(); passthrough.append(libraryPath ?? "")
        case "--device": deviceName = it.next(); passthrough.append(deviceName ?? "")
        case "--token-file": tokenFile = it.next(); passthrough.append(tokenFile ?? "")
        case "--no-bonjour": bonjour = false
        case "--null-sink": nullSink = true
        case "--print-launchagent": printAgent = true
        default: fail("unknown daemon option \(a)")
        }
    }
    if printAgent {
        print(launchAgentPlist(executable: Bundle.main.executablePath ?? CommandLine.arguments[0], arguments: passthrough.filter { $0 != "--print-launchagent" }))
        return
    }
    if music.isEmpty { music = [NSHomeDirectory() + "/Music"] }

    let library = try LibraryStore(url: libraryPath.map { URL(fileURLWithPath: $0) } ?? LibraryStore.defaultURL)
    var options = PlayerOptions()
    if let d = deviceName { guard let id = deviceID(matching: d) else { fail("no output device matching \(d)") }; options.deviceID = id }
    if nullSink { options.sinkFactory = { _ in NullSink() } }
    let player = Player()
    let controller = RemoteController(player: player, library: library, options: options, name: name, allowedRoots: music)
    let token = loadOrCreateToken(at: tokenFile.map { URL(fileURLWithPath: $0) } ?? supportDirectory().appendingPathComponent("remote-token"))
    let server = RemoteServer(controller: controller, token: token, advertise: bonjour)
    let actual = try server.start(port: port)
    print("Aureon daemon \"\(name)\" listening on port \(actual)\(bonjour ? " (Bonjour \(RemoteProtocol.bonjourType))" : "")")
    print("pairing token: \(token)")
    print("music folders: \(music.joined(separator: ", "))")
    fflush(stdout)

    // scan in the background so the server is usable immediately; remote apps are told about new revisions as they land
    DispatchQueue.global(qos: .utility).async {
        for m in music {
            let r = library.importFolder(URL(fileURLWithPath: m))
            print("scanned \(m): \(r.added) added, \(r.updated) updated, \(r.skipped) unchanged, \(r.removed) removed, \(r.failed) failed"); fflush(stdout)
        }
    }

    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let done = DispatchSemaphore(value: 0)
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .global()); s.setEventHandler { done.signal() }; s.resume(); return s
    }
    withExtendedLifetime(sources) { done.wait() }          // the sources must stay alive while we wait, or the signals are lost
    server.stop(); player.stop()
    print("daemon stopped"); fflush(stdout)
}

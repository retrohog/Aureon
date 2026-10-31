import Foundation
import CoreAudio
import AudioToolbox

// Hardware path diagnostics: verifies exclusive (hog) mode, integer / non-mixable format negotiation, sample-rate
// switching and real-time callback health on a given output device, typically a USB DAC.
//
// Read-only tests always run. Tests that change device state are opt-in and restore it afterwards.
// The IOProc test only ever outputs silence.

struct DiagStep: Codable, Identifiable {
    enum Status: String, Codable { case pass, warn, fail, info, skip }
    var id = UUID()
    var title: String
    var status: Status
    var detail: String
    private enum CodingKeys: String, CodingKey { case title, status, detail }
    init(_ title: String, _ status: Status, _ detail: String) { self.title = title; self.status = status; self.detail = detail }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title); status = try c.decode(Status.self, forKey: .status); detail = try c.decode(String.self, forKey: .detail)
    }
    var symbol: String { switch status { case .pass: "✓"; case .warn: "⚠"; case .fail: "✗"; case .info: "·"; case .skip: "–" } }
}

struct DiagReport: Codable {
    var device: String
    var uid: String
    var transport: String
    var date: Date
    var steps: [DiagStep]
    var failures: Int { steps.filter { $0.status == .fail }.count }
    var warnings: Int { steps.filter { $0.status == .warn }.count }
}

struct DiagOptions {
    var deviceID: AudioDeviceID? = nil
    var testHog = false              // take/release exclusive access, then check that a second process is refused
    var testIntegerFormats = false   // negotiate every integer physical format, then restore the original
    var testRates = false            // switch through the standard sample rates, then restore
    var ioSeconds = 2.0              // silent IOProc timing test; 0 skips
}

enum HardwareDiagnostics {
    private static let mixing: AudioObjectPropertySelector = 0x6D69783F    // 'mix?' kAudioDevicePropertySupportsMixing (deprecated, still honoured by drivers)

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = addr(sel, scope), sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var s: Unmanaged<CFString>? = nil
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &s) == noErr ? s?.takeRetainedValue() as String? : nil
    }

    static func describe(_ f: AudioStreamBasicDescription) -> String {
        let isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let ch = max(Int(f.mChannelsPerFrame), 1)
        let container = Int(f.mBytesPerFrame) / ch * 8
        var s = "\(f.mBitsPerChannel)-bit \(isFloat ? "float" : "integer")"
        if container != Int(f.mBitsPerChannel) && container > 0 { s += " in \(container)-bit container" }
        s += f.mFormatFlags & kAudioFormatFlagIsPacked != 0 ? ", packed" : (f.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 ? ", aligned high" : "")
        if f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 { s += ", non-mixable (integer mode)" }
        return s + ", \(ch) ch, \(Int(f.mSampleRate)) Hz"
    }

    static func transportName(_ t: UInt32) -> String {
        switch fourCC(t) {
        case "bltn": "built-in"; case "usb ": "USB"; case "blue", "blea": "Bluetooth"; case "hdmi": "HDMI"; case "dprt": "DisplayPort"
        case "airp": "AirPlay"; case "virt": "virtual"; case "grup": "aggregate"; case "pci ": "PCI"; case "1394": "FireWire"; case "thun": "Thunderbolt"
        default: fourCC(t)
        }
    }

    static func run(_ o: DiagOptions, log: ((DiagStep) -> Void)? = nil) -> DiagReport {
        var steps: [DiagStep] = []
        func add(_ title: String, _ status: DiagStep.Status, _ detail: String) {
            let s = DiagStep(title, status, detail); steps.append(s); log?(s)
        }
        guard let dev = OutputDevice(id: o.deviceID) else {
            add("Device", .fail, "no output device found")
            return DiagReport(device: "none", uid: "", transport: "", date: Date(), steps: steps)
        }
        let id = dev.id
        let uid = string(id, kAudioDevicePropertyDeviceUID) ?? ""
        let transport = getValue(id, addr(kAudioDevicePropertyTransportType), default: UInt32(0)).map(transportName) ?? "unknown"

        // 1 — identification ------------------------------------------------------------------------------------
        add("Device", .info, "\(dev.name) · \(string(id, kAudioObjectPropertyManufacturer) ?? "unknown maker") · \(transport) · UID \(uid)")
        let alive = getValue(id, addr(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0)) ?? 0
        add("Device alive", alive == 1 ? .pass : .fail, alive == 1 ? "responding" : "device reports it is not alive")
        let running = getValue(id, addr(kAudioDevicePropertyDeviceIsRunningSomewhere), default: UInt32(0)) ?? 0
        add("In use by another process", running == 1 ? .warn : .info, running == 1 ? "something is playing on this device right now; exclusive tests may interrupt it" : "idle")
        let owner = getValue(id, addr(kAudioDevicePropertyHogMode), default: pid_t(-1)) ?? -1
        add("Exclusive owner", owner == -1 ? .info : (owner == getpid() ? .info : .warn), owner == -1 ? "nobody (shared mode)" : "pid \(owner)")
        let size = getValue(id, addr(kAudioDevicePropertyBufferFrameSize), default: UInt32(0)) ?? 0
        let range = getValue(id, addr(kAudioDevicePropertyBufferFrameSizeRange), default: AudioValueRange()) ?? AudioValueRange()
        let latency = getValue(id, addr(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput), default: UInt32(0)) ?? 0
        let safety = getValue(id, addr(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput), default: UInt32(0)) ?? 0
        add("Buffer and latency", .info, "I/O buffer \(size) frames (allowed \(Int(range.mMinimum))–\(Int(range.mMaximum))), device latency \(latency) frames, safety offset \(safety) frames")
        add("Sample rates", .info, "now \(Int(dev.currentRate)) Hz; supported: \(dev.supportedRates.map { String(Int($0)) }.joined(separator: ", "))")

        // 2 — streams and formats -------------------------------------------------------------------------------
        let streams = dev.outputStreams
        if streams.isEmpty { add("Output streams", .fail, "device has no output streams") }
        var originals: [(AudioStreamID, AudioStreamBasicDescription, AudioStreamBasicDescription)] = []
        for (i, s) in streams.enumerated() {
            let virt = getValue(s, addr(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
            let phys = getValue(s, addr(kAudioStreamPropertyPhysicalFormat), default: AudioStreamBasicDescription())
            if let v = virt, let p = phys { originals.append((s, v, p)) }
            add("Stream \(i)", .info, "virtual: \(virt.map(describe) ?? "?") · physical: \(phys.map(describe) ?? "?")")
            let avail = getArray(s, addr(kAudioStreamPropertyAvailablePhysicalFormats), of: AudioStreamRangedDescription.self)
            var seen = Set<String>(), lines: [String] = []
            for a in avail {
                var f = a.mFormat; f.mSampleRate = 0
                let key = describe(f)
                if seen.insert(key).inserted {
                    lines.append("\(key.replacingOccurrences(of: ", 0 Hz", with: "")) @ \(Int(a.mSampleRateRange.mMinimum))–\(Int(a.mSampleRateRange.mMaximum)) Hz")
                }
            }
            let ints = avail.filter { $0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0 }
            add("Stream \(i) physical formats", ints.isEmpty ? .warn : .pass,
                (ints.isEmpty ? "only float formats offered: integer mode is not available on this device. " : "\(ints.count) integer format(s) offered. ") + lines.joined(separator: " | "))
        }
        if let mixValue = getValue(id, addr(mixing), default: UInt32(0)) {
            add("Supports mixing", .info, mixValue == 1 ? "yes — shared mode mixes in float; disable mixing (hog) for integer output" : "no — device is already non-mixable")
        } else {
            add("Supports mixing", .info, "property not exposed by this driver")
        }

        // 3 — exclusive access ----------------------------------------------------------------------------------
        if o.testHog {
            if owner != -1 && owner != getpid() {
                add("Hog mode", .fail, "device is already hogged by pid \(owner); cannot test")
            } else {
                let took = dev.takeHog()
                let after = getValue(id, addr(kAudioDevicePropertyHogMode), default: pid_t(-1)) ?? -1
                add("Hog: acquire", took && after == getpid() ? .pass : .fail, took ? "owner is now pid \(after) (this process is \(getpid()))" : "driver refused exclusive access")
                if took {
                    let probe = runHogProbe(deviceID: id)
                    add("Hog: second process refused", probe == "DENIED" ? .pass : (probe == nil ? .warn : .fail),
                        probe == "DENIED" ? "a competing process could not take the device while we hold it" : (probe.map { "unexpected probe result: \($0)" } ?? "could not run the probe process"))
                    // integer-mode tests need exclusivity, so run them while we still hold the device
                    if o.testIntegerFormats { integerTests(dev, originals, add) }
                    _ = setValue(id, addr(kAudioDevicePropertyHogMode), pid_t(-1))
                    let released = getValue(id, addr(kAudioDevicePropertyHogMode), default: pid_t(0)) ?? 0
                    add("Hog: release", released == -1 ? .pass : .fail, released == -1 ? "device is shared again" : "owner still pid \(released)")
                }
            }
        } else if o.testIntegerFormats {
            integerTests(dev, originals, add)
        }

        // 4 — sample-rate switching -----------------------------------------------------------------------------
        if o.testRates {
            let original = dev.currentRate
            for r in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] where dev.canRun(at: r) {
                let t0 = Date()
                let ok = dev.setRate(r)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                add("Rate \(Int(r)) Hz", ok ? .pass : .fail, ok ? "clock switched and confirmed in \(ms) ms (includes a 250 ms settle)" : "device did not report \(Int(r)) Hz")
            }
            _ = dev.setRate(original)
            add("Rate restored", abs(dev.currentRate - original) < 0.5 ? .pass : .warn, "\(Int(dev.currentRate)) Hz")
        }

        // 5 — real-time callback health --------------------------------------------------------------------------
        if o.ioSeconds > 0 { steps.append(contentsOf: ioTimingTest(dev, seconds: o.ioSeconds, log: log)) }

        return DiagReport(device: dev.name, uid: uid, transport: transport, date: Date(), steps: steps)
    }

    // MARK: integer-mode negotiation

    private static func integerTests(_ dev: OutputDevice, _ originals: [(AudioStreamID, AudioStreamBasicDescription, AudioStreamBasicDescription)],
                                     _ add: (String, DiagStep.Status, String) -> Void) {
        let id = dev.id
        let mixBefore = getValue(id, addr(mixing), default: UInt32(1))
        if mixBefore != nil {
            let st = setValue(id, addr(mixing), UInt32(0))
            let now = getValue(id, addr(mixing), default: UInt32(1)) ?? 1
            add("Disable mixing", st == noErr && now == 0 ? .pass : .warn,
                st == noErr && now == 0 ? "device now accepts non-mixable (integer) formats" : "driver kept mixing on (OSStatus \(st)); integer formats may still be accepted when hogged")
        }
        var negotiated = 0
        for (stream, _, origPhys) in originals {
            let avail = getArray(stream, addr(kAudioStreamPropertyAvailablePhysicalFormats), of: AudioStreamRangedDescription.self)
            let rate = dev.currentRate
            let candidates = avail.filter { $0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0 && $0.mSampleRateRange.mMinimum - 0.5 <= rate && rate <= $0.mSampleRateRange.mMaximum + 0.5 }
            if candidates.isEmpty { add("Integer formats at \(Int(rate)) Hz", .warn, "none offered at the current rate") }
            for c in candidates {
                var want = c.mFormat; want.mSampleRate = rate
                let st = setValue(stream, addr(kAudioStreamPropertyPhysicalFormat), want)
                usleep(120_000)
                let got = getValue(stream, addr(kAudioStreamPropertyPhysicalFormat), default: AudioStreamBasicDescription())
                let match = got.map { $0.mBitsPerChannel == want.mBitsPerChannel && $0.mFormatFlags & kAudioFormatFlagIsFloat == 0 && abs($0.mSampleRate - rate) < 0.5 } ?? false
                if st == noErr && match { negotiated += 1 }
                add("Negotiate \(describe(want))", st == noErr && match ? .pass : .warn,
                    st == noErr && match ? "driver accepted and read back the same format" : "requested \(describe(want)); device reports \(got.map(describe) ?? "?") (OSStatus \(st))")
            }
            var orig = origPhys
            _ = setValue(stream, addr(kAudioStreamPropertyPhysicalFormat), orig)
            orig.mSampleRate = 0
        }
        if let m = mixBefore { _ = setValue(id, addr(mixing), m) }
        add("Integer mode", negotiated > 0 ? .pass : .warn, negotiated > 0 ? "\(negotiated) integer format(s) negotiated: the OS float conversion can be bypassed" : "no integer format could be negotiated: output goes through the OS float path")
        add("Formats restored", .info, "original physical formats and mixing flag put back")
    }

    // MARK: second-process probe

    static func runHogProbe(deviceID: AudioDeviceID) -> String? {
        guard let exe = Bundle.main.executablePath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["hog-probe", String(deviceID)]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    // MARK: IOProc timing (silence only)

    private final class Timing: @unchecked Sendable {
        let cap = 200_000
        let hostTimes: UnsafeMutablePointer<UInt64>, sampleTimes: UnsafeMutablePointer<Double>, frames: UnsafeMutablePointer<UInt32>
        let count = Atomic<Int>(0)
        init() { hostTimes = .allocate(capacity: cap); sampleTimes = .allocate(capacity: cap); frames = .allocate(capacity: cap) }
        deinit { hostTimes.deallocate(); sampleTimes.deallocate(); frames.deallocate() }
    }

    private static func ioTimingTest(_ dev: OutputDevice, seconds: Double, log: ((DiagStep) -> Void)?) -> [DiagStep] {
        var out: [DiagStep] = []
        func add(_ t: String, _ s: DiagStep.Status, _ d: String) { let st = DiagStep(t, s, d); out.append(st); log?(st) }
        let tm = Timing()
        let overloads = Counter()
        var procID: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev.id, nil) { _, _, _, outData, outTime in
            let i = tm.count.load(ordering: .relaxed)
            if i < tm.cap {
                tm.hostTimes[i] = outTime.pointee.mHostTime
                tm.sampleTimes[i] = outTime.pointee.mSampleTime
                let abl = UnsafeMutableAudioBufferListPointer(outData)
                var fr: UInt32 = 0
                for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }; if fr == 0 { fr = b.mDataByteSize / max(1, b.mNumberChannels * 4) } }
                tm.frames[i] = fr
                tm.count.store(i + 1, ordering: .releasing)
            }
        }
        guard st == noErr, let procID else { add("IOProc timing", .fail, "could not create an IOProc (OSStatus \(st))"); return out }
        var a = addr(kAudioDeviceProcessorOverload)
        let queue = DispatchQueue(label: "aureon.diag")
        let listener: AudioObjectPropertyListenerBlock = { _, _ in _ = overloads.n.add(1, ordering: .relaxed) }
        AudioObjectAddPropertyListenerBlock(dev.id, &a, queue, listener)
        defer { AudioObjectRemovePropertyListenerBlock(dev.id, &a, queue, listener) }

        guard AudioDeviceStart(dev.id, procID) == noErr else { add("IOProc timing", .fail, "AudioDeviceStart failed"); AudioDeviceDestroyIOProcID(dev.id, procID); return out }
        usleep(UInt32(seconds * 1_000_000))
        AudioDeviceStop(dev.id, procID); AudioDeviceDestroyIOProcID(dev.id, procID)

        let n = tm.count.load(ordering: .acquiring)
        guard n > 10 else { add("IOProc timing", .fail, "only \(n) callbacks in \(seconds) s"); return out }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        func ms(_ ticks: UInt64) -> Double { Double(ticks) * Double(tb.numer) / Double(tb.denom) / 1e6 }
        var deltas: [Double] = [], gaps = 0
        for i in 1..<n {
            deltas.append(ms(tm.hostTimes[i] &- tm.hostTimes[i - 1]))
            if abs(tm.sampleTimes[i] - tm.sampleTimes[i - 1] - Double(tm.frames[i - 1])) > 0.5 { gaps += 1 }
        }
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let sd = (deltas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(deltas.count)).squareRoot()
        let worst = deltas.map { abs($0 - mean) }.max() ?? 0
        let totalFrames = (1..<n).reduce(0.0) { $0 + Double(tm.frames[$1 - 1]) }
        let elapsed = ms(tm.hostTimes[n - 1] &- tm.hostTimes[0]) / 1000
        let measured = elapsed > 0 ? totalFrames / elapsed : 0
        let ppm = dev.currentRate > 0 ? (measured / dev.currentRate - 1) * 1e6 : 0
        add("Callbacks", .info, "\(n) callbacks, \(tm.frames[1]) frames each, mean period \(String(format: "%.3f", mean)) ms")
        add("Callback jitter", worst < mean * 0.25 ? .pass : .warn, String(format: "σ %.3f ms, worst deviation %.3f ms (%.0f%% of the period)", sd, worst, 100 * worst / max(mean, 1e-9)))
        add("Timeline continuity", gaps == 0 ? .pass : .fail, gaps == 0 ? "sample time advanced by exactly one buffer every callback: no dropped or repeated buffers" : "\(gaps) discontinuities in the device's sample timeline (dropouts)")
        add("Clock accuracy", abs(ppm) < 500 ? .pass : .warn, String(format: "measured %.1f Hz vs nominal %d Hz (%+.0f ppm, host-clock referenced)", measured, Int(dev.currentRate), ppm))
        let ov = overloads.n.load(ordering: .relaxed)
        add("Processor overloads", ov == 0 ? .pass : .fail, ov == 0 ? "none reported" : "\(ov) overload notifications from the device")
        return out
    }
}

// MARK: - CLI

/// Child-process entry: `Aureon hog-probe <deviceID>` — prints DENIED if exclusive access is refused.
func hogProbeMain(_ args: [String]) {
    guard let s = args.first, let n = UInt32(s) else { print("ERROR"); exit(1) }
    let st = setValue(n, addr(kAudioDevicePropertyHogMode), getpid())
    let owner = getValue(n, addr(kAudioDevicePropertyHogMode), default: pid_t(-1)) ?? -1
    if st == noErr && owner == getpid() { _ = setValue(n, addr(kAudioDevicePropertyHogMode), pid_t(-1)); print("ACQUIRED") } else { print("DENIED") }
    exit(0)
}

func cmdHardwareDebug(_ args: [String]) throws {
    var o = DiagOptions(), json: String?
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--device": let n = it.next(); guard let id = deviceID(matching: n) else { fail("no output device matching \(n ?? "")") }; o.deviceID = id
        case "--hog": o.testHog = true
        case "--integer": o.testIntegerFormats = true; o.testHog = true      // integer negotiation is meaningful only while exclusive
        case "--rates": o.testRates = true
        case "--all": o.testHog = true; o.testIntegerFormats = true; o.testRates = true
        case "--seconds": o.ioSeconds = Double(it.next() ?? "") ?? 2
        case "--json": json = it.next()
        default: fail("unknown option \(a)")
        }
    }
    print("Hardware path diagnostics")
    let report = HardwareDiagnostics.run(o) { s in print("  \(s.symbol) \(s.title): \(s.detail)") }
    print("\n\(report.failures) failure(s), \(report.warnings) warning(s)")
    if let json {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(report).write(to: URL(fileURLWithPath: json))
        print("report written to \(json)")
    }
    exit(report.failures == 0 ? 0 : 3)
}

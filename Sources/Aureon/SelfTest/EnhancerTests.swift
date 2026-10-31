import Foundation

/// sysctl answers from a dictionary.
struct FakeSysctl: SysctlReading {
    var ints: [String: Int64] = [:]
    var strings: [String: String] = [:]
    func int(_ name: String) -> Int64? { ints[name] }
    func string(_ name: String) -> String? { strings[name] }
}

/// The enhancer's switch and model, the host check behind it, and the atomics every real-time path leans on.
struct EnhancerTests {
    let dir = tempDir("enhancer")

    static let appleM = HostHardware.detect(FakeSysctl(ints: ["hw.optional.arm64": 1, "hw.memsize": 16 << 30, "hw.physicalcpu": 10, "hw.perflevel0.physicalcpu": 4, "hw.perflevel1.physicalcpu": 6],
                                                       strings: ["machdep.cpu.brand_string": "Apple M2 Pro"]))
    static let intel = HostHardware.detect(FakeSysctl(ints: ["hw.memsize": 8 << 30, "hw.physicalcpu": 4], strings: ["machdep.cpu.brand_string": "Intel(R) Core(TM) i7-8559U CPU @ 2.70GHz"]))
    static let rosetta = HostHardware.detect(FakeSysctl(ints: ["hw.optional.arm64": 1, "sysctl.proc_translated": 1, "hw.memsize": 8 << 30, "hw.physicalcpu": 8], strings: ["machdep.cpu.brand_string": "Apple M1"]))

    func hardwareIsDetected() {
        expect(Self.appleM.isAppleSilicon && !Self.appleM.isTranslated && Self.appleM.performanceCores == 4 && Self.appleM.efficiencyCores == 6 && Self.appleM.memoryBytes == 16 << 30, "\(Self.appleM)")
        expect(Self.intel.isIntel && !Self.intel.isTranslated && Self.intel.performanceCores == 4 && Self.intel.efficiencyCores == 0, "\(Self.intel)")
        expect(Self.rosetta.isAppleSilicon && Self.rosetta.isTranslated, "a translated copy on an M-series Mac is still Apple Silicon")
        expect(Self.appleM.audioEnhancerBlocker == nil && Self.intel.audioEnhancerBlocker != nil, "the enhancer needs an M-series chip")
        let now = HostHardware.current
        expect(now.performanceCores >= 1 && now.memoryBytes > 0, "this Mac is read: \(now)")
    }

    func switchFollowsTheSettingsAndTheHardware() {
        var s = EnhancerSettings()
        expect(!s.enabled && s.model == nil, "off by default")
        expect(!EnhancerGate(hardware: Self.appleM, settings: s).isEnabled, "off")
        s.enabled = true
        expect(EnhancerGate(hardware: Self.appleM, settings: s).isEnabled, "on for Apple Silicon")
        expect(!EnhancerGate(hardware: Self.intel, settings: s).isEnabled, "never on for an Intel Mac")
        let d = UserDefaults(suiteName: "aureon.enhancertest.\(UUID().uuidString.prefix(8))")!
        s.model = LocalModelSelection(LocalModelInfo(url: URL(fileURLWithPath: "/m/up.mlpackage"), name: "up", parameters: 1_000_000, bytes: 2_000_000))
        s.save(d)
        expect(EnhancerSettings.load(d) == s, "the choice is remembered")
        d.set(Data("garbage".utf8), forKey: EnhancerSettings.key)
        expect(EnhancerSettings.load(d) == EnhancerSettings(), "damaged settings fall back to off")
        let g = EnhancerGate(hardware: Self.appleM, settings: EnhancerSettings())
        let g0 = g.generation
        g.publish(s)
        expect(g.isEnabled && g.modelURL?.path == "/m/up.mlpackage" && g.generation == g0 + 1, "published")
    }

    func gateReadsAreAtomicWhilePublishing() {
        let g = EnhancerGate(hardware: Self.appleM, settings: EnhancerSettings())
        let stop = Atomic<Bool>(false), reads = Atomic<Int>(0)
        let reader = Thread {
            var n = 0
            while !stop.load(ordering: .relaxed) { _ = g.isEnabled; n += 1 }
            reads.store(n, ordering: .relaxed)
        }
        reader.start()
        var s = EnhancerSettings()
        for i in 0..<4000 { s.enabled = i % 2 == 0; g.publish(s) }
        stop.store(true, ordering: .relaxed)
        while reads.load(ordering: .relaxed) == 0 { usleep(1000) }
        expect(reads.load(ordering: .relaxed) > 1000 && g.generation == 4000, "reads: \(reads.load(ordering: .relaxed)), generation \(g.generation)")
        // cost of a read (a debug build does not inline it; a release build is a single load)
        let t0 = DispatchTime.now().uptimeNanoseconds
        var sum = 0
        for _ in 0..<1_000_000 { if g.isEnabled { sum += 1 } }
        let ns = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        expect(ns < 1000, "one gate read takes \(ns) ns")
        _ = sum
    }

    func modelsAreMeasuredAndCapped() {
        func package(_ name: String, weightBytes: Int) -> URL {
            let u = dir.appendingPathComponent(name + ".mlpackage")
            let w = u.appendingPathComponent("Data/com.apple.CoreML/weights")
            try? FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(to: u.appendingPathComponent("Manifest.json"))
            FileManager.default.createFile(atPath: w.appendingPathComponent("weight.bin").path, contents: nil)
            if let h = try? FileHandle(forWritingTo: w.appendingPathComponent("weight.bin")) { try? h.truncate(atOffset: UInt64(weightBytes)); try? h.close() }
            return u
        }
        let small = try? LocalModelInspector.inspect(package("small", weightBytes: 2_000_000))
        expect(small?.parameters == 1_000_000 && small.map { LocalModelInspector.verdict($0) } == .accepted, "FP16 weights: two bytes each: \(String(describing: small))")
        let big = try? LocalModelInspector.inspect(package("big", weightBytes: 2_400_000_000))
        expect(big?.parameters == 1_200_000_000 && big.map { LocalModelInspector.verdict($0).reason?.contains("parameters") == true } == true, "over one billion parameters is refused")
        let edge = try? LocalModelInspector.inspect(package("edge", weightBytes: 1_700_000_000))
        expect(edge?.parameters == 850_000_000 && edge.map { LocalModelInspector.verdict($0).reason?.contains("memory") == true } == true, "over 1.5 GiB of weights is refused")
        var failures = 0
        for bad in [dir.appendingPathComponent("missing.mlpackage"), dir.appendingPathComponent("x.gguf"), dir.appendingPathComponent("x.mlmodel")] {
            FileManager.default.createFile(atPath: bad.path, contents: Data("x".utf8))
            do { _ = try LocalModelInspector.inspect(bad) } catch { failures += 1 }
        }
        expect(failures == 3, "anything that is not a CoreML model is turned away: \(failures)")
        expect(LocalModelInspector.formatParameters(1_250_000_000) == "1.25B" && LocalModelInspector.formatParameters(65_000_000) == "65M", "formatting")
    }

    func atomicsBehaveLikeTheirSystemCounterparts() {
        let i = Atomic<Int>(-5)
        expect(i.load(ordering: .acquiring) == -5, "negative Int survives the round trip")
        let r = i.add(7, ordering: .relaxed)
        expect(r.oldValue == -5 && r.newValue == 2 && i.load(ordering: .relaxed) == 2, "add returns both values")
        expect(i.exchange(9, ordering: .acquiringAndReleasing) == 2, "exchange returns the old value")
        let ok = i.compareExchange(expected: 9, desired: 1, ordering: .sequentiallyConsistent)
        let no = i.compareExchange(expected: 9, desired: 3, ordering: .sequentiallyConsistent)
        expect(ok.exchanged && ok.original == 9 && !no.exchanged && no.original == 1 && i.load(ordering: .relaxed) == 1, "compare-exchange")
        let u32 = Atomic<UInt32>(Float(-1.5).bitPattern)
        expect(Float(bitPattern: u32.load(ordering: .relaxed)) == -1.5, "Float bit pattern in a UInt32")
        let u64 = Atomic<UInt64>(.max)
        expect(u64.add(2, ordering: .relaxed).newValue == 1 && u64.load(ordering: .relaxed) == 1, "unsigned add wraps")
        let b = Atomic<Bool>(false)
        b.store(true, ordering: .releasing)
        expect(b.load(ordering: .acquiring) && b.exchange(false, ordering: .relaxed) && !b.load(ordering: .relaxed), "Bool")
        let n = Atomic<Int>(Int.min)
        expect(n.load(ordering: .relaxed) == Int.min, "Int.min")
        // four threads adding at once lose nothing
        let c = Atomic<Int>(0)
        let group = DispatchGroup()
        for _ in 0..<4 { group.enter(); Thread { for _ in 0..<50_000 { c.add(1, ordering: .relaxed) }; group.leave() }.start() }
        group.wait()
        expect(c.load(ordering: .acquiring) == 200_000, "\(c.load(ordering: .relaxed))")
        let m = Mutex(0)
        let g2 = DispatchGroup()
        for _ in 0..<4 { g2.enter(); Thread { for _ in 0..<5_000 { m.withLock { $0 += 1 } }; g2.leave() }.start() }
        g2.wait()
        expect(m.withLock { $0 } == 20_000, "the lock keeps its value")
    }
}

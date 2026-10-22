import Foundation
import Synchronization

/// sysctl answers from a dictionary.
struct FakeSysctl: SysctlReading {
    var ints: [String: Int64] = [:]
    var strings: [String: String] = [:]
    func int(_ name: String) -> Int64? { ints[name] }
    func string(_ name: String) -> String? { strings[name] }
}

/// An OpenAI-compatible server stand-in for Smart DJ: answers each chat request with the first allowed ids from the request's own schema.
final class SchemaEchoHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var chats = 0, listings = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = request.url?.absoluteString ?? ""
        if url.hasSuffix("/models") { lock.lock(); listings += 1; lock.unlock(); return (Data(#"{"data":[{"id":"gpt-4.1-mini"}]}"#.utf8), 200) }
        guard url.hasSuffix("/chat/completions"), let b = request.httpBody, let o = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] else { return (Data(), 404) }
        lock.lock(); chats += 1; lock.unlock()
        let schema = ((o["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
        let ids = (((schema?["properties"] as? [String: Any])?["ids"] as? [String: Any])?["items"] as? [String: Any])?["enum"] as? [Int] ?? []
        let n = (((schema?["properties"] as? [String: Any])?["ids"] as? [String: Any])?["minItems"] as? Int) ?? ids.count
        let content = "{\"ids\":[\(ids.prefix(n).map(String.init).joined(separator: ","))]}"
        let reply: [String: Any] = ["choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]]]
        return (try JSONSerialization.data(withJSONObject: reply), 200)
    }
}

/// Text embedding stand-in: a bag of words hashed into 128 dimensions. Counts what it embeds.
final class WordHashEmbedder: TextEmbedder, @unchecked Sendable {
    let identity: String
    private let lock = NSLock()
    private(set) var embedded: [String] = []
    init(identity: String = "test-words-1") { self.identity = identity }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        lock.lock(); embedded += texts; lock.unlock()
        return texts.map { t in
            var v = [Float](repeating: 0, count: 128)
            for w in t.lowercased().split(whereSeparator: { !$0.isLetter }) where w.count > 2 { v[Int(EmbeddingCache.hash(String(w)) % 128)] += 1 }
            return v
        }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return embedded.count }
}

struct IntelligenceTests {
    let dir = tempDir("intelligence")

    static let appleM = HostHardware.detect(FakeSysctl(ints: ["hw.optional.arm64": 1, "hw.memsize": 16 << 30, "hw.physicalcpu": 10, "hw.perflevel0.physicalcpu": 4, "hw.perflevel1.physicalcpu": 6],
                                                       strings: ["machdep.cpu.brand_string": "Apple M2 Pro"]))
    static let intel = HostHardware.detect(FakeSysctl(ints: ["hw.memsize": 8 << 30, "hw.physicalcpu": 4], strings: ["machdep.cpu.brand_string": "Intel(R) Core(TM) i7-8559U CPU @ 2.70GHz"]))
    static let rosetta = HostHardware.detect(FakeSysctl(ints: ["hw.optional.arm64": 1, "sysctl.proc_translated": 1, "hw.memsize": 8 << 30, "hw.physicalcpu": 8], strings: ["machdep.cpu.brand_string": "Apple M1"]))

    private func suite() -> UserDefaults { UserDefaults(suiteName: "aureon.aitest.\(UUID().uuidString.prefix(8))")! }

    @MainActor private func center(_ hw: HostHardware, _ s: IntelligenceSettings? = nil, defaults: UserDefaults? = nil, keys: AIKeyStore = AIKeyStore(store: MemorySecretStore())) -> IntelligenceCenter {
        let settings = s ?? .defaults(for: hw)
        return IntelligenceCenter(gate: IntelligenceGate(hardware: hw, settings: settings), keys: keys, defaults: defaults ?? suite(), persist: defaults != nil, settings: settings)
    }

    @MainActor private func wait(_ timeout: Double = 8, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func dto(_ n: Int, _ title: String, _ artist: String, _ genre: String, year: Int) -> TrackDTO {
        TrackDTO(id: "t\(n)", path: "/music/\(n).flac", title: title, trackNumber: nil, discNumber: nil, duration: 200, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2, year: year,
                 releaseID: nil, releaseTitle: "Album \(n)", workID: nil, workTitle: nil, catalog: nil, movementID: nil, movementNumber: nil, movementTitle: nil,
                 credits: [CreditDTO(role: "artist", name: artist, instrument: nil, partyID: "p-\(artist)")], genres: [genre], mbRecordingID: nil)
    }

    private func analysis(bpm: Double, energy: Double) -> DJTrackAnalysis {
        var a = DJTrackAnalysis(peaks: [], bpm: bpm, confidence: 0.9, duration: 200)
        a.energy = energy
        return a
    }

    // MARK: hardware

    func hardwareIsDetected() {
        let m = Self.appleM, i = Self.intel, r = Self.rosetta
        expect(m.isAppleSilicon && !m.isTranslated && m.canRunMLX && m.hasNeuralEngine, "Apple Silicon: \(m)")
        expect(m.performanceCores == 4 && m.efficiencyCores == 6 && m.memoryBytes == 16 << 30 && m.cpuBrand == "Apple M2 Pro")
        expect(m.badgeTitle == "Apple M-Series Neural Engine Active" && m.badgeDetail.contains("4P + 6E"), m.badgeDetail)
        expect(i.isIntel && !i.canRunMLX && !i.hasNeuralEngine && i.badgeTitle == "Intel x86 · Software Mode" && i.performanceCores == 4 && i.efficiencyCores == 0, "Intel: \(i)")
        expect(r.isAppleSilicon && r.isTranslated && !r.canRunMLX && r.badgeTitle.contains("Rosetta"), "an x86 build under Rosetta is still Apple Silicon hardware: \(r)")
        // the Mac running the test, through the real sysctl
        let real = HostHardware.detect()
        #if arch(arm64)
        expect(real.isAppleSilicon && !real.isTranslated, "a native arm64 build: \(real)")
        #else
        expect(real.isIntel || real.isTranslated, "an x86_64 build runs on Intel or under Rosetta: \(real)")
        #endif
        expect(real.memoryBytes >= 1 << 30 && !real.cpuBrand.isEmpty && real.performanceCores >= 1, "\(real)")
        expect(HostHardware.current == real)
    }

    // MARK: master switch, Intel, gate

    func intelIsOffByDefaultAndWarnsFirst() {
        MainActor.assumeIsolated {
            let d = suite()
            let c = center(Self.intel, defaults: d)
            let g = c.gate
            expect(!c.settings.masterEnabled && !g.isMasterOn && IntelligenceFeature.allCases.allSatisfy { !g.isEnabled($0) }, "everything off on a fresh Intel install")
            c.setMaster(true)
            expect(c.showIntelWarning && !g.isMasterOn && !c.settings.masterEnabled, "the warning comes before anything switches on")
            c.declineIntelWarning()
            expect(!c.showIntelWarning && !g.isMasterOn, "Keep Off keeps it off")
            c.setMaster(true); c.acceptIntelWarning()
            expect(!c.showIntelWarning && g.isMasterOn && g.isEnabled(.smartDJ) && g.isEnabled(.semanticSearch) && !g.isEnabled(.audioEnhancer), "on after accepting; the enhancer stays opt-in")
            let back = IntelligenceSettings.load(d, hardware: Self.intel)
            expect(back.masterEnabled && back.intelRiskAccepted && d.bool(forKey: IntelligenceSettings.masterKey), "the choice is remembered, and the master switch is its own AppStorage key")
            c.setMaster(false); c.setMaster(true)
            expect(!c.showIntelWarning && g.isMasterOn, "accepted once, not asked again")
            c.revokeIntelAcceptance()
            expect(!g.isMasterOn && !c.settings.intelRiskAccepted)
            c.setMaster(true)
            expect(c.showIntelWarning && !g.isMasterOn, "revoking brings the warning back")
            // a saved "on" without the acceptance (hand-edited preferences) still does not switch anything on
            expect(IntelligenceGate.mask(for: IntelligenceSettings(masterEnabled: true), hardware: Self.intel) == 0)

            let a = center(Self.appleM)
            expect(a.isMasterOn && a.isActive(.smartDJ) && a.isActive(.semanticSearch) && a.isActive(.smartShuffle) && a.isActive(.remixer) && !a.isActive(.audioEnhancer), "Apple Silicon starts on, enhancer off")
            a.setMaster(false); a.setMaster(true)
            expect(!a.showIntelWarning && a.isMasterOn, "no warning on Apple Silicon")
        }
    }

    func killswitchClosesEveryFeature() {
        MainActor.assumeIsolated {
            let c = center(Self.appleM)
            for f in IntelligenceFeature.allCases { c.setFeature(f, true) }
            expect(IntelligenceFeature.allCases.allSatisfy { c.gate.isEnabled($0) })
            let heard = Box(0)
            let token = NotificationCenter.default.addObserver(forName: .intelligenceSettingsChanged, object: c.gate, queue: nil) { _ in heard.v += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            let g0 = c.gate.generation
            c.setMaster(false)
            expect(IntelligenceFeature.allCases.allSatisfy { !c.gate.isEnabled($0) } && !c.gate.isMasterOn, "the master switch closes every feature")
            expect(c.gate.generation == g0 + 1 && heard.v == 1, "one change, one notification: \(heard.v)")
            c.setMaster(false)
            expect(c.gate.generation == g0 + 1, "no change, no publish")
            c.setMaster(true)
            expect(IntelligenceFeature.allCases.allSatisfy { c.gate.isEnabled($0) }, "and opens them again with their own switches intact")
            c.setFeature(.semanticSearch, false)
            expect(!c.gate.isEnabled(.semanticSearch) && c.gate.isEnabled(.smartDJ) && c.gate.isEnabled(.audioEnhancer), "one feature alone")
            c.setEngine(.audioEnhancer, .api)
            expect(c.settings.engine(for: .audioEnhancer) == .onDevice, "audio never goes to an API")
            c.setEngine(.smartDJ, .api)
            expect(c.settings.smartDJEngine == .api)
        }
    }

    func gateReadsAreAtomicWhilePublishing() {
        let s = IntelligenceSettings(masterEnabled: true)
        let g = IntelligenceGate(hardware: Self.appleM, settings: s)
        final class Flags: Sendable { let stop = Atomic<Bool>(false), reads = Atomic<Int>(0), torn = Atomic<Int>(0) }
        let f = Flags()
        let reader = Thread {
            var n = 0, bad = 0
            while !f.stop.load(ordering: .relaxed) {
                // a feature can only be on while the master is: both come from one load, so a published state is never seen half-applied
                let st = g.state
                let a = st.isEnabled(.smartDJ), master = st.isMasterOn
                if a && !master { bad += 1 }
                n += 1
            }
            f.reads.store(n, ordering: .relaxed); f.torn.store(bad, ordering: .relaxed)
        }
        reader.start()
        var on = s
        for i in 0..<4000 {
            on.masterEnabled = i % 3 != 0; on.smartDJ = i % 2 == 0
            g.publish(on)
        }
        f.stop.store(true, ordering: .relaxed)
        while f.reads.load(ordering: .relaxed) == 0 { usleep(1000) }
        expect(f.torn.load(ordering: .relaxed) == 0 && f.reads.load(ordering: .relaxed) > 1000, "reads: \(f.reads.load(ordering: .relaxed)), inconsistent: \(f.torn.load(ordering: .relaxed))")
        expect(g.generation == 4000)
        // cost of a read: well under a microsecond (it is called from the render path)
        let t0 = DispatchTime.now().uptimeNanoseconds
        var sum = 0
        for _ in 0..<1_000_000 { if g.isEnabled(.audioEnhancer) { sum += 1 } }
        let ns = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        expect(ns < 50, "one gate read takes \(ns) ns")
        _ = sum
    }

    // MARK: settings and keys

    func settingsPersistAndKeysStayInTheKeychain() {
        MainActor.assumeIsolated {
            let d = suite()
            let keys = AIKeyStore(store: MemorySecretStore())
            let c = center(Self.appleM, defaults: d, keys: keys)
            c.setProvider(.deepSeek)
            expect(c.settings.api.baseURL == "https://api.deepseek.com/v1" && c.settings.api.model == "deepseek-chat" && c.settings.api.embeddingModel.isEmpty, "provider defaults")
            c.setAPI(model: "  deepseek-reasoner ")
            expect(c.settings.api.model == "deepseek-reasoner")
            c.saveKey("  sk-secret-value-123  ", for: .deepSeek)
            expect(keys.key(for: .deepSeek) == "sk-secret-value-123" && c.hasKey(.deepSeek) && !c.hasKey(.openAI), "trimmed and stored")
            // the key appears nowhere in the saved preferences
            let everything = d.dictionaryRepresentation().values.map { v -> String in
                if let data = v as? Data { return String(decoding: data, as: UTF8.self) }
                return "\(v)"
            }.joined()
            expect(!everything.contains("sk-secret-value-123"), "no API key in UserDefaults")
            let back = IntelligenceSettings.load(d, hardware: Self.appleM)
            expect(back == c.settings, "settings round-trip")
            c.removeKey(for: .deepSeek)
            expect(keys.key(for: .deepSeek) == nil && !c.hasKey(.deepSeek))
            // tolerant decoding
            let partial = try? JSONDecoder().decode(IntelligenceSettings.self, from: Data(#"{"masterEnabled":true,"audioEnhancer":true,"api":{"provider":"custom"}}"#.utf8))
            expect(partial?.masterEnabled == true && partial?.audioEnhancer == true && partial?.smartDJ == true && partial?.api.provider == .custom && partial?.api.baseURL == AIProvider.custom.defaultBaseURL, "missing fields take defaults")
            d.set(Data("garbage".utf8), forKey: IntelligenceSettings.key)
            d.removeObject(forKey: IntelligenceSettings.masterKey)
            expect(IntelligenceSettings.load(d, hardware: Self.intel) == .defaults(for: Self.intel), "damaged settings fall back to the defaults")
        }
        // the real Keychain, under a throw-away service
        let kc = KeychainSecretStore(service: "org.aureon.selftest.\(UUID().uuidString.prefix(8))")
        kc.set("k-123", for: "api-key.openAI")
        expect(kc.get("api-key.openAI") == "k-123", "Keychain round trip")
        kc.set(nil, for: "api-key.openAI")
        expect(kc.get("api-key.openAI") == nil, "and removal")
    }

    // MARK: local models

    private func writeSafetensors(_ url: URL, _ tensors: [String: (String, [Int])]) {
        var header: [String: Any] = [:]
        for (k, v) in tensors { header[k] = ["dtype": v.0, "shape": v.1, "data_offsets": [0, 0]] }
        header["__metadata__"] = ["format": "mlx"]
        let json = try! JSONSerialization.data(withJSONObject: header)
        var d = Data()
        withUnsafeBytes(of: UInt64(json.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(json); d.append(Data(count: 64))
        try! d.write(to: url)
    }

    private func mlxFolder(_ name: String, tokenizer: Bool = true, tensors: [String: (String, [Int])]) -> URL {
        let f = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: f)
        try! FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try! Data(#"{"model_type":"qwen2","quantization":{"group_size":64,"bits":4}}"#.utf8).write(to: f.appendingPathComponent("config.json"))
        if tokenizer { try! Data("{}".utf8).write(to: f.appendingPathComponent("tokenizer.json")) }
        writeSafetensors(f.appendingPathComponent("model.safetensors"), tensors)
        return f
    }

    private func gguf(_ name: String, tensors: [(String, [UInt64])], truncate: Bool = false, padTo: UInt64? = nil) -> URL {
        var d = Data()
        func u32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ x: UInt64) { withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } }
        func str(_ s: String) { u64(UInt64(s.utf8.count)); d.append(Data(s.utf8)) }
        u32(0x4655_4747); u32(3); u64(UInt64(tensors.count)); u64(5)
        str("general.architecture"); u32(8); str("llama")
        str("general.name"); u32(8); str("Tiny Test")
        str("llama.context_length"); u32(4); u32(2048)
        str("tokenizer.ggml.tokens"); u32(9); u32(8); u64(3000); for i in 0..<3000 { str("tok\(i)") }
        str("tokenizer.ggml.scores"); u32(9); u32(6); u64(3000); d.append(Data(count: 3000 * 4))
        for (n, dims) in tensors { str(n); u32(UInt32(dims.count)); for x in dims { u64(x) }; u32(1); u64(0) }
        if truncate { d = d.prefix(d.count - 10) }
        let url = dir.appendingPathComponent(name)
        try! d.write(to: url)
        if let padTo, let h = try? FileHandle(forWritingTo: url) { try? h.truncate(atOffset: padTo); try? h.close() }        // sparse: no real disk use
        return url
    }

    func modelsAreMeasuredAndCapped() {
        // MLX, 4-bit: each quantized layer holds rows × scale columns × group size weights; scales and biases are not counted
        let q = mlxFolder("qwen-tiny-4bit", tensors: [
            "model.embed_tokens.weight": ("U32", [1000, 128]), "model.embed_tokens.scales": ("F16", [1000, 16]), "model.embed_tokens.biases": ("F16", [1000, 16]),
            "model.layers.0.mlp.down_proj.weight": ("U32", [512, 64]), "model.layers.0.mlp.down_proj.scales": ("F16", [512, 8]), "model.layers.0.mlp.down_proj.biases": ("F16", [512, 8]),
            "model.norm.weight": ("F16", [1024]), "model.layers.0.self_attn.q_proj.bias": ("F16", [512])])
        let qi = try? LocalModelInspector.inspect(q)
        let expectedParams: Int64 = 1000 * 16 * 64 + 512 * 8 * 64 + 1024 + 512
        let qiShape = qi?.format == .mlx && qi?.parametersEstimated == false
        let qiDetails = qi?.architecture == "qwen2" && qi?.quantizationBits == 4
        expect(qiShape && qi?.parameters == expectedParams && qiDetails,
               "exact count from the headers: \(String(describing: qi))")
        if let qi {
            expect(LocalModelInspector.verdict(qi, role: .languageModel, hardware: Self.appleM) == .accepted, "a small MLX model is accepted on Apple Silicon")
            expect(LocalModelInspector.verdict(qi, role: .languageModel, hardware: Self.intel).reason?.contains("Apple Silicon") == true, "but MLX cannot run on Intel")
            expect(LocalModelInspector.verdict(qi, role: .languageModel, hardware: Self.rosetta).reason?.contains("Rosetta") == true, "nor under Rosetta")
            expect(LocalModelInspector.verdict(qi, role: .audioEnhancer, hardware: Self.appleM).reason?.contains("CoreML") == true, "the enhancer takes CoreML only")
            let viaFile = try? LocalModelInspector.inspect(q.appendingPathComponent("model.safetensors"))
            expect(viaFile?.url == q && viaFile?.parameters == qi.parameters, "choosing the weights file means its folder")
        }
        let noTok = try? LocalModelInspector.inspect(mlxFolder("no-tokenizer", tokenizer: false, tensors: ["w": ("F16", [10, 10])]))
        expect(noTok.map { LocalModelInspector.verdict($0, role: .languageModel, hardware: Self.appleM).reason?.contains("tokenizer") == true } == true, "a folder without its tokenizer is refused")

        // over the parameter cap, judged from the header alone (the file is tiny)
        let big = try? LocalModelInspector.inspect(mlxFolder("too-big", tensors: ["model.embed_tokens.weight": ("F16", [50_000, 25_000])]))
        expect(big?.parameters == 1_250_000_000 && big.map { LocalModelInspector.verdict($0, role: .languageModel, hardware: Self.appleM).reason?.contains("parameters") == true } == true, "1.25B parameters is over the cap")
        let edge = try? LocalModelInspector.inspect(mlxFolder("exactly-1b", tensors: ["w": ("F16", [40_000, 25_000])]))
        expect(edge?.parameters == 1_000_000_000 && edge.map { LocalModelInspector.verdict($0, role: .languageModel, hardware: Self.appleM) } == .accepted, "exactly 1B is allowed")

        // GGUF: metadata with string and number arrays is skipped, every tensor counted
        let g = gguf("tiny.gguf", tensors: [("token_embd.weight", [64, 3000]), ("blk.0.attn_q.weight", [64, 64]), ("output_norm.weight", [64])])
        let gi = try? LocalModelInspector.inspect(g)
        expect(gi?.format == .gguf && gi?.parameters == 64 * 3000 + 64 * 64 + 64 && gi?.name == "Tiny Test" && gi?.architecture == "llama", "GGUF: \(String(describing: gi))")
        expect(gi.map { LocalModelInspector.verdict($0, role: .languageModel, hardware: Self.appleM).reason?.contains("MLX") == true } == true, "GGUF is measured but cannot run here, and says what to do")
        // over the memory cap: a sparse 1.7 GB file
        let fat = gguf("fat.gguf", tensors: [("w", [1000, 1000])], padTo: 1_700_000_000)
        let fi = try? LocalModelInspector.inspect(fat)
        expect(fi?.parameters == 1_000_000 && fi.map { LocalModelInspector.verdict($0, role: .languageModel, hardware: Self.appleM).reason?.contains("memory") == true } == true, "1.7 GB of weights is over the cap")
        try? FileManager.default.removeItem(at: fat)
        var threw = false
        do { _ = try LocalModelInspector.inspect(gguf("cut.gguf", tensors: [("w", [8, 8])], truncate: true)) } catch { threw = true }
        expect(threw, "a truncated GGUF is reported, not misread")
        let junk = dir.appendingPathComponent("junk.gguf"); try? Data("not a model at all".utf8).write(to: junk)
        threw = false
        do { _ = try LocalModelInspector.inspect(junk) } catch { threw = (error as? LocalModelError) != nil }
        expect(threw, "a file with the wrong signature is refused")
        let txt = dir.appendingPathComponent("notes.txt"); try? Data("x".utf8).write(to: txt)
        threw = false
        do { _ = try LocalModelInspector.inspect(txt) } catch { threw = true }
        expect(threw, "other files are refused")

        // CoreML: estimated from the weight file at two bytes per weight
        let pkg = dir.appendingPathComponent("Enhancer.mlpackage", isDirectory: true)
        let weights = pkg.appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true)
        try? FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try? Data(count: 2_000_000).write(to: weights.appendingPathComponent("weight.bin"))
        try? Data(count: 500).write(to: pkg.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"))
        try? Data("{}".utf8).write(to: pkg.appendingPathComponent("Manifest.json"))
        let ci = try? LocalModelInspector.inspect(pkg)
        expect(ci?.format == .coreMLPackage && ci?.parameters == 1_000_000 && ci?.parametersEstimated == true, "CoreML: \(String(describing: ci))")
        expect(ci.map { LocalModelInspector.verdict($0, role: .audioEnhancer, hardware: Self.intel) } == .accepted, "a CoreML model may drive the enhancer, even on Intel (CPU)")
        expect(ci.map { LocalModelInspector.verdict($0, role: .languageModel, hardware: Self.appleM).isAccepted } == false)

        // the center only takes models that pass, and the gate hands their location to the engines
        MainActor.assumeIsolated {
            let c = center(Self.appleM)
            if let gi { expect(!c.useModel(gi, for: .languageModel).isAccepted && c.settings.languageModel == nil, "a refused model changes nothing") }
            if let qi { expect(c.useModel(qi, for: .languageModel).isAccepted && c.gate.languageModelURL == q && c.settings.languageModel?.parameters == qi.parameters) }
            if let ci { expect(c.useModel(ci, for: .audioEnhancer).isAccepted && c.gate.enhancerModelURL == pkg, "the enhancer engine reads its model from the gate") }
            c.useModel(nil, for: .audioEnhancer)
            expect(c.gate.enhancerModelURL == nil && c.settings.enhancerModel == nil)
        }
    }

    // MARK: API

    func apiClientSpeaksOpenAICompatible() {
        let schema = #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"integer","enum":[1,2,3]},"minItems":2,"maxItems":2}},"required":["ids"]}"#
        let ok = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"{\"ids\":[3,1]}"},"finish_reason":"stop"}]}"#
        let http = StubHTTP()
        http.on("/chat/completions", ok)
        http.on("/models", #"{"data":[{"id":"gpt-4.1-mini"},{"id":"other"}]}"#)
        http.on("/embeddings", #"{"data":[{"index":1,"embedding":[0,1]},{"index":0,"embedding":[1,0]}]}"#)
        let openAI = OpenAICompatibleClient(config: APIConfig(provider: .openAI), apiKey: "sk-abc", http: http)
        let r = runAsync { try await openAI.chatJSON(system: "pick", user: "two songs", schema: schema, maxTokens: 50) }
        expect((try? r.get()) == #"{"ids":[3,1]}"#, "\(r)")
        if let req = http.requests.first, let b = req.httpBody, let o = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] {
            expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions" && req.httpMethod == "POST", "\(String(describing: req.url))")
            expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-abc")
            expect(o["model"] as? String == "gpt-4.1-mini" && (o["response_format"] as? [String: Any])?["type"] as? String == "json_schema", "OpenAI gets a JSON schema: \(o)")
        } else { expect(false, "no request was sent") }
        let e = runAsync { try await openAI.embeddings(["a", "b"]) }
        expect((try? e.get()) == [[1, 0], [0, 1]], "embeddings come back in input order: \(e)")
        if let b = http.requests.last?.httpBody, let o = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] {
            expect(o["dimensions"] as? Int == 256 && o["model"] as? String == "text-embedding-3-small", "\(o)")
        }
        let v = runAsync { try await openAI.verifyConnection() }
        expect((try? v.get())?.contains("is available") == true, "\(v)")

        // DeepSeek: JSON mode, with the schema in the instructions
        let ds = StubHTTP(); ds.on("/chat/completions", ok)
        let deep = OpenAICompatibleClient(config: APIConfig(provider: .deepSeek), apiKey: "k", http: ds)
        _ = runAsync { try await deep.chatJSON(system: "pick", user: "u", schema: schema, maxTokens: 50) }
        if let b = ds.requests.first?.httpBody, let o = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] {
            let sys = ((o["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            expect((o["response_format"] as? [String: Any])?["type"] as? String == "json_object" && sys.contains("JSON schema") && sys.contains("\"ids\""), "DeepSeek gets JSON mode: \(o)")
            expect(ds.requests.first?.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        } else { expect(false, "DeepSeek: no request") }

        // a custom server that refuses JSON schemas: the client steps down to JSON mode
        let cs = StubHTTP()
        cs.on("/chat/completions", [(Data(#"{"error":{"message":"response_format json_schema is not supported"}}"#.utf8), 400), (Data(ok.utf8), 200)])
        var cfg = APIConfig(provider: .custom); cfg.baseURL = "http://localhost:1234/v1/"; cfg.model = "local-model"
        let custom = OpenAICompatibleClient(config: cfg, apiKey: "", http: cs)
        let cr = runAsync { try await custom.chatJSON(system: "s", user: "u", schema: schema, maxTokens: 50) }
        expect((try? cr.get()) == #"{"ids":[3,1]}"# && cs.count == 2, "stepped down after a 400: \(cr), \(cs.count) requests")
        if cs.requests.count == 2, let b = cs.requests[1].httpBody, let o = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] {
            expect((o["response_format"] as? [String: Any])?["type"] as? String == "json_object" && cs.requests[1].value(forHTTPHeaderField: "Authorization") == nil, "no key, no header")
            expect(cs.requests[1].url?.absoluteString == "http://localhost:1234/v1/chat/completions", "trailing slash handled: \(String(describing: cs.requests[1].url))")
        }

        // errors a person can act on
        let bad = StubHTTP(); bad.on("/chat/completions", #"{"error":{"message":"Incorrect API key provided"}}"#, status: 401)
        let br = runAsync { try await OpenAICompatibleClient(config: APIConfig(provider: .openAI), apiKey: "x", http: bad).chatJSON(system: "s", user: "u", schema: schema, maxTokens: 5) }
        if case .failure(let err) = br { expect(err.localizedDescription.contains("refused the API key") && err.localizedDescription.contains("Incorrect API key"), err.localizedDescription) } else { expect(false, "a 401 must fail") }
        let fenced = try? OpenAICompatibleClient.content(Data(#"{"choices":[{"message":{"content":"```json\n{\"ids\":[1]}\n```"}}]}"#.utf8))
        expect(fenced == #"{"ids":[1]}"#, "code fences are removed: \(String(describing: fenced))")
        expect((try? OpenAICompatibleClient.content(Data(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#.utf8))) == nil)

        // addresses
        expect((try? OpenAICompatibleClient.validatedBaseURL("https://api.example.com/v1")) != nil)
        expect((try? OpenAICompatibleClient.validatedBaseURL("http://127.0.0.1:11434/v1")) != nil, "plain http only for this Mac")
        var insecure = false
        do { _ = try OpenAICompatibleClient.validatedBaseURL("http://api.example.com/v1") } catch AIAPIError.insecureURL { insecure = true } catch {}
        expect(insecure, "plain http to another host is refused")
        expect((try? OpenAICompatibleClient.validatedBaseURL("not a url")) == nil)
        let keys = AIKeyStore(store: MemorySecretStore())
        expect((try? OpenAICompatibleClient.make(APIConfig(provider: .openAI), keys: keys)) == nil, "no key, no client")
        keys.setKey("sk-1", for: .openAI)
        expect((try? OpenAICompatibleClient.make(APIConfig(provider: .openAI), keys: keys))?.apiKey == "sk-1")
        expect((try? OpenAICompatibleClient.make(cfg, keys: keys)) != nil, "a local server needs no key")
    }

    func smartDJUsesTheChosenEngineAndObeysTheSwitch() {
        MainActor.assumeIsolated {
            let lib = (0..<40).map { i -> SmartDJTrack in
                let g = ["Electronic", "Jazz", "Classical", "Rock"][i % 4]
                return SmartDJTrack(track: dto(i, "Song \(i)", "Artist \(i % 7)", g, year: 1980 + i), bpm: Double(70 + i * 2), energy: Double(i % 10) / 10, key: nil)
            }
            let http = SchemaEchoHTTP()
            let keys = AIKeyStore(store: MemorySecretStore())
            keys.setKey("sk-test", for: .openAI)
            let c = center(Self.appleM, keys: keys)
            c.http = http
            c.setEngine(.smartDJ, .api)
            let s = SmartDJService()
            s.library = { lib }
            s.rng = { 5 }
            c.configure(s)
            s.enable()
            wait { s.state == .ready }
            expect(s.state == .ready && s.modelActive && s.modelProblem == nil && s.engineDescription.contains("OpenAI") && s.model == "gpt-4.1-mini" && http.listings == 1,
                   "connected to the API: \(s.state), \(String(describing: s.modelProblem)), \(s.engineDescription)")
            Task { await s.suggest("6 upbeat electronic tracks") }
            wait { s.suggestion != nil }
            expect(s.suggestion?.usedModel == true && (s.suggestion?.modelPicked ?? 0) > 0 && http.chats == 1, "the API model picked: \(String(describing: s.suggestion?.note))")

            // the killswitch quits it at once, and it cannot be switched back on while closed
            c.setMaster(false)
            expect(s.state == .off && !s.modelActive, "master off stops Smart DJ: \(s.state)")
            s.enable()
            expect(s.state == .off && s.modelProblem?.contains("Intelligence") == true, "refused while switched off: \(String(describing: s.modelProblem))")
            c.setMaster(true)

            // no key: the reason is shown and the ranking still answers
            keys.setKey(nil, for: .openAI)
            s.enable()
            wait { s.state == .ready }
            expect(!s.modelActive && s.modelProblem?.contains("API key") == true, "missing key explained: \(String(describing: s.modelProblem))")
            Task { await s.disableAndWait() }
            wait { s.state == .off }

            // on-device on Intel explains itself
            let ic = center(Self.intel, { var x = IntelligenceSettings(masterEnabled: true); x.intelRiskAccepted = true; return x }())
            var msg = ""
            do { _ = try ic.smartDJBackend() } catch { msg = error.localizedDescription }
            expect(msg.contains("Apple Silicon"), "Intel: \(msg)")
            let (_, model, label) = (try? center(Self.appleM).smartDJBackend()) ?? (nil, "", "")
            expect(model == SmartDJService.modelID && label == "on-device model", "the built-in model by default: \(model)")
        }
    }

    // MARK: semantic search

    func semanticSearchFindsSongsByMeaning() {
        MainActor.assumeIsolated {
            let tracks = [dto(1, "Gymnopedie No 1", "Erik Satie", "Classical", year: 1888), dto(2, "Firestarter", "The Prodigy", "Electronic", year: 1996), dto(3, "So What", "Miles Davis", "Jazz", year: 1959)]
            let moods = ["/music/1.flac": analysis(bpm: 60, energy: 0.1), "/music/2.flac": analysis(bpm: 140, energy: 0.9), "/music/3.flac": analysis(bpm: 95, energy: 0.45)]
            expect(SemanticDescriptor.text(for: tracks[0], analysis: moods["/music/1.flac"]).contains("Slow tempo, relaxed, calm, quiet, mellow"), SemanticDescriptor.text(for: tracks[0], analysis: moods["/music/1.flac"]))
            let cache = dir.appendingPathComponent("semantic-\(UUID().uuidString.prefix(6))", isDirectory: true)
            @MainActor func make(_ e: WordHashEmbedder, _ t: [TrackDTO]) -> SemanticSearchService {
                let s = SemanticSearchService()
                s.library = { { t } }; s.analysis = { moods[$0] }; s.makeEmbedder = { e }; s.cacheDirectory = cache; s.isAllowed = { true }
                return s
            }
            let e1 = WordHashEmbedder()
            let s = make(e1, tracks)
            /// Runs one search to the end and returns what it found.
            @MainActor func run(_ svc: SemanticSearchService, _ q: String) -> [TrackDTO] {
                let out = Box<[TrackDTO]?>(nil)
                Task { out.v = await svc.search(q) }
                wait { out.v != nil }
                return out.v ?? []
            }
            var got = run(s, "calm quiet mellow piano")
            expect(got.first?.title == "Gymnopedie No 1" && s.state == .ready(songs: 3) && s.isLoaded, "calm finds Satie: \(got.map(\.title)), \(s.state)")
            got = run(s, "fast energetic electronic")
            expect(got.first?.title == "Firestarter", "energetic finds the Prodigy: \(got.map(\.title))")
            expect(e1.count == 3 + 2, "three songs and two queries embedded: \(e1.count)")

            // cached on disk: a new session embeds nothing but the query, and only a changed song again
            s.release()
            expect(!s.isLoaded && s.results.isEmpty && s.state == .idle, "released")
            let e2 = WordHashEmbedder()
            var changed = tracks; changed[2].title = "Blue in Green"
            let s2 = make(e2, changed)
            _ = run(s2, "cool jazz")
            expect(e2.embedded.count == 2 && e2.embedded.first?.contains("Blue in Green") == true, "only the changed song and the query: \(e2.embedded)")

            // another model: its own cache file
            let e3 = WordHashEmbedder(identity: "another-model")
            let s3 = make(e3, tracks)
            _ = run(s3, "jazz")
            expect(e3.count == 4, "vectors never mix between models: \(e3.count)")

            // not allowed: nothing is built
            let e4 = WordHashEmbedder()
            let s4 = make(e4, tracks); s4.isAllowed = { false }
            _ = run(s4, "jazz")
            expect(!s4.isLoaded && e4.count == 0, "a closed gate builds nothing")

            // a damaged cache is ignored, not trusted
            let file = EmbeddingCache(directory: cache, identity: e1.identity)
            try? Data("AEMB-garbage".utf8).write(to: file.url)
            expect(file.load() == nil)

            // the master switch frees the index
            let c = center(Self.appleM)
            c.search.library = { { tracks } }; c.search.analysis = { moods[$0] }; c.search.makeEmbedder = { WordHashEmbedder() }; c.search.cacheDirectory = cache
            _ = run(c.search, "calm")
            expect(c.search.isLoaded && c.memoryNote.contains("search index"))
            c.setMaster(false)
            expect(!c.search.isLoaded && c.search.state == .idle && c.memoryNote.hasPrefix("No AI"), "killswitch drops the index")
        }
        // the index arithmetic
        let idx = SemanticIndex(dimension: 2, paths: ["a", "b", "c"], normalized: [1, 0, 0, 1, 0.6, 0.8])
        let hits = idx.search([0.9, 0.1], limit: 2, window: 1)
        expect(hits.map(\.path) == ["a", "c"] && abs(hits[0].score - 0.9939) < 0.001 && abs(hits[1].score - 0.6847) < 0.001, "cosine ranking: \(hits)")
        expect(idx.search([0.9, 0.1], limit: 2).map(\.path) == ["a"], "the default window drops songs far below the best match")
        expect(idx.search([0, 0], limit: 3).isEmpty && idx.search([1, 0, 0], limit: 3).isEmpty, "empty and mismatched queries find nothing")
    }
}

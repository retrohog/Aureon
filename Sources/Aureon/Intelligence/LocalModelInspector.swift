import Foundation

/// The hard limits on a model the user loads to run on this Mac. They keep a model from taking the memory the audio engine needs:
/// a model over the cap is refused before anything is loaded.
enum LocalModelCap {
    /// At most one billion parameters.
    static let maxParameters: Int64 = 1_000_000_000
    /// At most 1.5 GiB of weights on disk (the weights are mapped into memory as they are, so this is close to the memory they take).
    static let maxBytes: Int64 = 1_610_612_736
}

enum LocalModelFormat: String, Codable, Sendable {
    /// A folder of MLX weights: config.json, tokenizer and *.safetensors (quantized or not).
    case mlx
    /// A single GGUF file (llama.cpp's format).
    case gguf
    /// A CoreML package (.mlpackage).
    case coreMLPackage
    /// A compiled CoreML model (.mlmodelc).
    case coreMLCompiled

    var title: String {
        switch self {
        case .mlx: "MLX weights"
        case .gguf: "GGUF"
        case .coreMLPackage: "CoreML package"
        case .coreMLCompiled: "Compiled CoreML model"
        }
    }
    var isCoreML: Bool { self == .coreMLPackage || self == .coreMLCompiled }
}

/// What a model is for decides what may run it.
enum LocalModelRole: Sendable {
    /// Smart DJ's language model, run by the MLX helper.
    case languageModel
    /// The audio enhancer's network, run by CoreML.
    case audioEnhancer
}

/// What was learned about a model without loading it.
struct LocalModelInfo: Equatable, Sendable {
    var url: URL
    var format: LocalModelFormat
    var name: String
    /// The architecture as the model names it ("qwen2", "llama"), when it says.
    var architecture: String?
    var parameters: Int64
    var parametersEstimated: Bool
    /// Bytes of weights on disk.
    var bytes: Int64
    /// Bits per weight of a quantized model, when known.
    var quantizationBits: Int?
    /// Files the runner needs that are missing (an MLX folder without its tokenizer, for example).
    var missing: [String] = []

    var parameterText: String { LocalModelInspector.formatParameters(parameters) + (parametersEstimated ? " (estimated from size)" : "") }
}

enum LocalModelVerdict: Equatable, Sendable {
    case accepted
    case rejected(String)
    var isAccepted: Bool { self == .accepted }
    var reason: String? { if case .rejected(let r) = self { return r }; return nil }
}

enum LocalModelError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupported(String)
    var errorDescription: String? { switch self { case .unreadable(let m), .unsupported(let m): m } }
}

/// Counts a model's parameters by reading only its headers: safetensors headers and GGUF tensor tables give exact counts in milliseconds,
/// even for multi-gigabyte files. CoreML does not publish a count, so it is estimated from the weight file at two bytes per weight (FP16).
enum LocalModelInspector {
    static func inspect(_ url: URL) throws -> LocalModelInfo {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” could not be found.") }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "gguf": return try inspectGGUF(url)
        case "mlpackage", "mlmodelc": return try inspectCoreML(url, compiled: ext == "mlmodelc")
        case "mlmodel": throw LocalModelError.unsupported("Uncompiled .mlmodel files are not loaded directly: save the model as an .mlpackage (Core ML Tools) and choose that.")
        case "safetensors": return try inspectMLX(url.deletingLastPathComponent())
        default:
            if isDir.boolValue { return try inspectMLX(url) }
            throw LocalModelError.unsupported("“\(url.lastPathComponent)” is not a model Aureon can load. Choose an MLX model folder, a .gguf file, or a CoreML .mlpackage / .mlmodelc.")
        }
    }

    /// Whether the model passes the cap and can be run in that role on this Mac.
    static func verdict(_ info: LocalModelInfo, role: LocalModelRole, hardware: HostHardware = .current) -> LocalModelVerdict {
        if info.parameters > LocalModelCap.maxParameters {
            return .rejected("\(info.name) has \(formatParameters(info.parameters)) parameters. Local models are limited to \(formatParameters(LocalModelCap.maxParameters)), so the audio engine always keeps the memory it needs.")
        }
        if info.bytes > LocalModelCap.maxBytes {
            return .rejected("\(info.name) needs \(formatBytes64(info.bytes)) of memory for its weights; the limit is \(formatBytes64(LocalModelCap.maxBytes)). A more strongly quantized build (4-bit) of the same model usually fits.")
        }
        switch role {
        case .languageModel:
            switch info.format {
            case .gguf:
                return .rejected("GGUF files can be checked but not run: Aureon's on-device language runner is MLX. Download the MLX build of the same model (the mlx-community organisation on Hugging Face publishes most small models) and choose its folder.")
            case .coreMLPackage, .coreMLCompiled:
                return .rejected("CoreML models are used by the audio enhancer. Smart DJ needs a language model as an MLX folder.")
            case .mlx:
                if !info.missing.isEmpty { return .rejected("This MLX folder is missing \(info.missing.joined(separator: ", ")).") }
                if !hardware.canRunMLX {
                    return .rejected(hardware.isIntel ? "MLX runs on Apple Silicon only. On this Intel Mac, Smart DJ can use an API model instead (see API provider)."
                                                      : "Aureon is running under Rosetta, where MLX cannot run. Open the native Apple Silicon build to use local language models.")
                }
                return .accepted
            }
        case .audioEnhancer:
            guard info.format.isCoreML else { return .rejected("The audio enhancer runs CoreML models (.mlpackage or .mlmodelc), so it can use the Neural Engine and never leaves this Mac.") }
            return .accepted
        }
    }

    // MARK: MLX / safetensors

    static func inspectMLX(_ dir: URL) throws -> LocalModelInfo {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        let shards = files.filter { $0.pathExtension.lowercased() == "safetensors" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !shards.isEmpty else {
            throw LocalModelError.unsupported("“\(dir.lastPathComponent)” has no .safetensors weights. Choose the folder that contains config.json and the model's .safetensors files.")
        }
        var config: [String: Any] = [:]
        if let d = try? Data(contentsOf: dir.appendingPathComponent("config.json")), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { config = o }
        let quant = (config["quantization"] as? [String: Any]) ?? (config["quantization_config"] as? [String: Any])
        let groupSize = Int64((quant?["group_size"] as? Int) ?? 64)
        let bits = quant?["bits"] as? Int

        var tensors: [String: SafetensorEntry] = [:]
        var bytes: Int64 = 0
        for f in shards {
            bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            for (k, v) in try readSafetensorsHeader(f) { tensors[k] = v }
        }
        let params = countParameters(tensors, groupSize: groupSize)
        var missing: [String] = []
        let names = Set(files.map(\.lastPathComponent))
        if !names.contains("config.json") { missing.append("config.json") }
        if !names.contains("tokenizer.json") && !names.contains("tokenizer.model") { missing.append("its tokenizer (tokenizer.json)") }
        return LocalModelInfo(url: dir, format: .mlx, name: dir.lastPathComponent, architecture: config["model_type"] as? String, parameters: params,
                              parametersEstimated: false, bytes: bytes, quantizationBits: bits, missing: missing)
    }

    struct SafetensorEntry: Equatable { var dtype: String; var shape: [Int64] }

    /// Reads a safetensors file's JSON header: an 8-byte little-endian length, then that many bytes of JSON.
    static func readSafetensorsHeader(_ url: URL) throws -> [String: SafetensorEntry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” could not be opened.") }
        defer { try? h.close() }
        guard let lenData = try h.read(upToCount: 8), lenData.count == 8 else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” is not a safetensors file (too short).") }
        let len = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard len > 1, len < 100_000_000, Int64(len) + 8 <= size else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” has a damaged safetensors header.") }
        guard let json = try h.read(upToCount: Int(len)), json.count == Int(len),
              let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw LocalModelError.unreadable("“\(url.lastPathComponent)” has a damaged safetensors header.")
        }
        var out: [String: SafetensorEntry] = [:]
        for (k, v) in obj where k != "__metadata__" {
            guard let t = v as? [String: Any], let dt = t["dtype"] as? String, let shape = t["shape"] as? [Any] else { continue }
            out[k] = SafetensorEntry(dtype: dt, shape: shape.compactMap { ($0 as? NSNumber)?.int64Value })
        }
        return out
    }

    /// Exact parameter count. MLX-quantized layers store `w.weight` packed into uint32 next to `w.scales` (one per group) and `w.biases`;
    /// such a layer holds rows × (scale columns × group size) weights, and its scales and biases are bookkeeping, not parameters.
    static func countParameters(_ t: [String: SafetensorEntry], groupSize: Int64) -> Int64 {
        var total: Int64 = 0
        for (name, e) in t {
            if name.hasSuffix(".scales") { continue }
            if name.hasSuffix(".biases"), t[String(name.dropLast(".biases".count)) + ".scales"] != nil { continue }
            if name.hasSuffix(".weight"), let s = t[String(name.dropLast(".weight".count)) + ".scales"], e.shape.count >= 2, s.shape.count == e.shape.count {
                let rows = e.shape.dropLast().reduce(Int64(1), multiplySaturating)
                total = addSaturating(total, multiplySaturating(rows, multiplySaturating(s.shape.last ?? 0, groupSize)))
                continue
            }
            total = addSaturating(total, e.shape.reduce(Int64(1), multiplySaturating))
        }
        return total
    }

    // MARK: GGUF

    /// Walks a GGUF header (metadata, then the tensor table) and adds up every tensor's dimensions.
    static func inspectGGUF(_ url: URL) throws -> LocalModelInfo {
        let r = try BufferedFileReader(url)
        func bad(_ why: String) -> LocalModelError { .unreadable("“\(url.lastPathComponent)” is not a readable GGUF file (\(why)).") }
        guard try r.u32() == 0x4655_4747 else { throw bad("wrong signature") }          // "GGUF"
        let version = try r.u32()
        guard version >= 2 && version <= 3 else { throw bad("version \(version) is not supported") }
        let tensorCount = try r.u64(), kvCount = try r.u64()
        guard tensorCount < 1_000_000, kvCount < 1_000_000 else { throw bad("implausible header") }
        var meta: [String: String] = [:]
        var declaredParams: Int64?
        for _ in 0..<kvCount {
            let key = try r.string()
            let type = try r.u32()
            if type == 8 { let v = try r.string(); if key == "general.architecture" || key == "general.name" || key == "general.size_label" { meta[key] = v } }
            else if key == "general.parameter_count", type == 10 || type == 11 { let d = try r.u64(); declaredParams = Int64(bitPattern: d) }
            else { try r.skipValue(type: type) }
        }
        var params: Int64 = 0
        for _ in 0..<tensorCount {
            _ = try r.string()
            let nd = try r.u32()
            guard nd >= 1 && nd <= 8 else { throw bad("a tensor with \(nd) dimensions") }
            var n: Int64 = 1
            for _ in 0..<nd { let d = try r.u64(); n = multiplySaturating(n, Int64(clamping: d)) }
            _ = try r.u32(); _ = try r.u64()                                                  // ggml type, data offset
            params = addSaturating(params, n)
        }
        if params == 0, let d = declaredParams { params = d }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return LocalModelInfo(url: url, format: .gguf, name: meta["general.name"] ?? url.deletingPathExtension().lastPathComponent, architecture: meta["general.architecture"],
                              parameters: params, parametersEstimated: false, bytes: bytes, quantizationBits: nil)
    }

    // MARK: CoreML

    static func inspectCoreML(_ url: URL, compiled: Bool) throws -> LocalModelInfo {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” could not be read.") }
        var total: Int64 = 0, weights: Int64 = 0
        var sawModel = false
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            let s = Int64(v?.fileSize ?? 0)
            total += s
            let n = f.lastPathComponent
            if f.pathExtension == "bin" && f.path.contains("/weights") { weights += s }
            if n == "model.mlmodel" || n == "model.mil" || n == "coremldata.bin" || n == "Manifest.json" { sawModel = true }
        }
        guard sawModel else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” does not look like a CoreML model.") }
        let w = weights > 0 ? weights : total
        return LocalModelInfo(url: url, format: compiled ? .coreMLCompiled : .coreMLPackage, name: url.deletingPathExtension().lastPathComponent, architecture: nil,
                              parameters: w / 2, parametersEstimated: true, bytes: total, quantizationBits: nil)
    }

    // MARK: formatting

    static func formatParameters(_ n: Int64) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.0fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }
}

func formatBytes64(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }

private func multiplySaturating(_ a: Int64, _ b: Int64) -> Int64 { let (r, o) = a.multipliedReportingOverflow(by: b); return o || r < 0 ? .max : r }
private func addSaturating(_ a: Int64, _ b: Int64) -> Int64 { let (r, o) = a.addingReportingOverflow(b); return o ? .max : r }

/// Sequential little-endian reads from a file through a 1 MiB window, for walking headers that can hold megabytes of vocabulary.
final class BufferedFileReader {
    private let handle: FileHandle
    private var buf = Data()
    private var pos = 0
    private let chunk = 1 << 20
    private let name: String

    init(_ url: URL) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw LocalModelError.unreadable("“\(url.lastPathComponent)” could not be opened.") }
        handle = h; name = url.lastPathComponent
    }
    deinit { try? handle.close() }

    private func ensure(_ n: Int) throws {
        if buf.count - pos >= n { return }
        var next = Data(buf[(buf.startIndex + pos)...]); pos = 0
        while next.count < n {
            guard let d = try handle.read(upToCount: max(chunk, n - next.count)), !d.isEmpty else { throw LocalModelError.unreadable("“\(name)” ends in the middle of its header.") }
            next.append(d)
        }
        buf = next
    }

    func bytes(_ n: Int) throws -> Data {
        try ensure(n)
        let s = buf.startIndex + pos
        pos += n
        return buf.subdata(in: s..<(s + n))
    }

    func skip(_ n: UInt64) throws {
        var left = n
        while left > 0 {
            let avail = UInt64(buf.count - pos)
            if avail >= left { pos += Int(left); return }
            left -= avail; pos = buf.count
            try ensure(Int(min(left, UInt64(chunk))))
        }
    }

    func u8() throws -> UInt8 { try bytes(1)[0] }
    func u32() throws -> UInt32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
    func u64() throws -> UInt64 { try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian }

    func string() throws -> String {
        let n = try u64()
        guard n < 64 << 20 else { throw LocalModelError.unreadable("“\(name)” has an implausible string in its header.") }
        return String(decoding: try bytes(Int(n)), as: UTF8.self)
    }

    /// Skips one GGUF metadata value of `type`.
    func skipValue(type: UInt32) throws {
        switch type {
        case 0, 1, 7: try skip(1)
        case 2, 3: try skip(2)
        case 4, 5, 6: try skip(4)
        case 10, 11, 12: try skip(8)
        case 8: let n = try u64(); try skip(n)
        case 9:
            let et = try u32(), count = try u64()
            guard count < 100_000_000 else { throw LocalModelError.unreadable("“\(name)” has an implausible array in its header.") }
            if let w = Self.fixedWidth(et) { try skip(count * w) }
            else { for _ in 0..<count { try skipValue(type: et) } }
        default: throw LocalModelError.unreadable("“\(name)” uses an unknown GGUF value type \(type).")
        }
    }

    static func fixedWidth(_ t: UInt32) -> UInt64? {
        switch t { case 0, 1, 7: 1; case 2, 3: 2; case 4, 5, 6: 4; case 10, 11, 12: 8; default: nil }
    }
}

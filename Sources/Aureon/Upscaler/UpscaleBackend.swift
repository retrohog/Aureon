import Foundation
import CoreML

// The inference side of the neural upscaler: what a model must look like, and the CoreML implementation.
//
// A model takes one channel of `window` float samples at its own sample rate (full scale ±1), already resampled to that rate by the
// classic sinc resampler, and returns the same number of samples with the missing high band restored ("bandwidth extension").
// Input and output are time-aligned: the conversion script (Tools/upscaler/convert_to_coreml.py) refuses models that shift the signal.

/// What the overlap-add needs to know about a model.
struct UpscaleModelInfo: Equatable, Sendable {
    var name: String
    /// The rate the model was trained at; the stream is resampled to it before the model and from it afterwards.
    var sampleRate: Double
    /// Samples per inference block.
    var window: Int
    /// Distance between consecutive blocks; `window / hop` blocks overlap at every sample.
    var hop: Int

    var isValid: Bool { sampleRate >= 8_000 && window >= 64 && hop >= 1 && window % hop == 0 && (2...16).contains(window / hop) }
}

/// A loaded model. `bind` and `run` are called on the upscaler's worker thread only, never on the audio thread.
protocol UpscaleBackend: AnyObject {
    var info: UpscaleModelInfo { get }
    /// Prepares inference from `input` to `output` (planar, `channels` rows of `info.window` floats each). Called once per buffer pair;
    /// the result is handed back to `run` every time those buffers hold a new block.
    func bind(input: UnsafeMutablePointer<Float>, output: UnsafeMutablePointer<Float>, channels: Int) throws -> AnyObject
    /// Runs the model on the bound input and writes the bound output.
    func run(_ binding: AnyObject) throws
}

enum UpscalerError: LocalizedError, Equatable {
    case noModelSelected
    case notAnEnhancerModel(String)
    case unsupportedModel(String)
    case tooSlow(Double)
    case bindingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noModelSelected: "No enhancer model is selected"
        case .notAnEnhancerModel(let why): "This is not an Aureon enhancer model: \(why)"
        case .unsupportedModel(let why): "Unsupported model: \(why)"
        case .tooSlow(let rtf): String(format: "Too slow on this Mac (%.2f× real time); the classic resampler is used instead", rtf)
        case .bindingFailed(let why): "Could not prepare the model's buffers: \(why)"
        }
    }
}

// MARK: - CoreML

/// Runs a converted `.mlpackage` / `.mlmodelc` with CoreML.
///
/// The input and output MLMultiArrays wrap the overlap-add's own slot buffers (no copy in, and `outputBackings` writes the result in
/// place), so a block costs one prediction per channel and nothing else. Apple Silicon runs on CPU + Neural Engine; the GPU is left out
/// on purpose so inference never competes with the 120 Hz interface for it. Intel Macs run on the CPU.
final class CoreMLUpscaleBackend: UpscaleBackend {
    /// Keys the conversion script writes into the model's user-defined metadata.
    enum MetadataKey {
        static let kind = "com.aureon.kind"                 // must be "bandwidth-extension"
        static let sampleRate = "com.aureon.sampleRate"
        static let hop = "com.aureon.hop"
        static let name = "com.aureon.name"
    }

    let info: UpscaleModelInfo
    let computeUnits: MLComputeUnits
    private let model: MLModel
    private let inputName: String, outputName: String
    private let inputShape: [NSNumber], outputShape: [NSNumber]

    private final class Binding {
        let inputs: [MLFeatureProvider]
        let options: [MLPredictionOptions]
        let outputs: [UnsafeMutablePointer<Float>]
        var backingHonoured = true
        init(inputs: [MLFeatureProvider], options: [MLPredictionOptions], outputs: [UnsafeMutablePointer<Float>]) {
            self.inputs = inputs; self.options = options; self.outputs = outputs
        }
    }

    static func computeUnits(for hw: HostHardware) -> MLComputeUnits {
        hw.isAppleSilicon && !hw.isTranslated ? .cpuAndNeuralEngine : .cpuOnly
    }

    static func load(url: URL?, hardware: HostHardware) throws -> UpscaleBackend {
        guard let url else { throw UpscalerError.noModelSelected }
        return try CoreMLUpscaleBackend(url: url, computeUnits: computeUnits(for: hardware))
    }

    init(url: URL, computeUnits: MLComputeUnits) throws {
        let compiled = try Self.compiledModel(for: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        self.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiled, configuration: cfg)
        let d = model.modelDescription
        let meta = d.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard meta[MetadataKey.kind] == "bandwidth-extension" else { throw UpscalerError.notAnEnhancerModel("metadata \(MetadataKey.kind) is missing") }
        guard let rate = meta[MetadataKey.sampleRate].flatMap(Double.init), rate >= 8_000 else {
            throw UpscalerError.notAnEnhancerModel("metadata \(MetadataKey.sampleRate) is missing")
        }
        guard d.inputDescriptionsByName.count == 1, let input = d.inputDescriptionsByName.first, let ic = input.value.multiArrayConstraint else {
            throw UpscalerError.unsupportedModel("it needs exactly one multi-array input")
        }
        guard let output = d.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }), let oc = output.value.multiArrayConstraint else {
            throw UpscalerError.unsupportedModel("it has no multi-array output")
        }
        guard ic.dataType == .float32, oc.dataType == .float32 else { throw UpscalerError.unsupportedModel("input and output must be float32") }
        let w = ic.shape.last?.intValue ?? 0
        let inCount = ic.shape.reduce(1) { $0 * $1.intValue }, outCount = oc.shape.reduce(1) { $0 * $1.intValue }
        guard w >= 64, inCount == w, outCount == w else {
            throw UpscalerError.unsupportedModel("expected one channel of N samples in and out, got \(ic.shape) → \(oc.shape)")
        }
        let hop = meta[MetadataKey.hop].flatMap(Int.init) ?? w / 2
        let name = meta[MetadataKey.name] ?? (d.metadata[.description] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let i = UpscaleModelInfo(name: name, sampleRate: rate, window: w, hop: hop)
        guard i.isValid else { throw UpscalerError.unsupportedModel("hop \(hop) does not divide the \(w)-sample window into 2 to 16 overlaps") }
        info = i
        inputName = input.key; outputName = output.key
        inputShape = ic.shape; outputShape = oc.shape
    }

    private static func strides(_ shape: [NSNumber]) -> [NSNumber] {
        var s = [Int](repeating: 1, count: shape.count)
        if shape.count > 1 { for k in stride(from: shape.count - 2, through: 0, by: -1) { s[k] = s[k + 1] * shape[k + 1].intValue } }
        return s.map { NSNumber(value: $0) }
    }

    func bind(input: UnsafeMutablePointer<Float>, output: UnsafeMutablePointer<Float>, channels: Int) throws -> AnyObject {
        let w = info.window
        var inputs: [MLFeatureProvider] = [], options: [MLPredictionOptions] = [], outs: [UnsafeMutablePointer<Float>] = []
        do {
            for c in 0..<channels {
                let inArr = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(input + c * w), shape: inputShape, dataType: .float32,
                                             strides: Self.strides(inputShape), deallocator: nil)
                inputs.append(try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: inArr)]))
                let outArr = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(output + c * w), shape: outputShape, dataType: .float32,
                                              strides: Self.strides(outputShape), deallocator: nil)
                let o = MLPredictionOptions()
                o.outputBackings = [outputName: outArr]
                options.append(o)
                outs.append(output + c * w)
            }
        } catch { throw UpscalerError.bindingFailed(error.localizedDescription) }
        return Binding(inputs: inputs, options: options, outputs: outs)
    }

    func run(_ binding: AnyObject) throws {
        guard let b = binding as? Binding else { throw UpscalerError.bindingFailed("foreign binding") }
        let w = info.window
        for c in 0..<b.inputs.count {
            let r: MLFeatureProvider
            if b.backingHonoured {
                do { r = try model.prediction(from: b.inputs[c], options: b.options[c]) }
                catch { b.backingHonoured = false; r = try model.prediction(from: b.inputs[c]) }   // some runtimes refuse backings: copy instead
            } else { r = try model.prediction(from: b.inputs[c]) }
            guard let arr = r.featureValue(for: outputName)?.multiArrayValue else { throw UpscalerError.unsupportedModel("the output is missing") }
            if arr.dataPointer == UnsafeMutableRawPointer(b.outputs[c]) { continue }
            guard arr.count == w else { throw UpscalerError.unsupportedModel("the output has \(arr.count) samples, expected \(w)") }
            if arr.dataType == .float32 {
                arr.withUnsafeBufferPointer(ofType: Float.self) { src in b.outputs[c].update(from: src.baseAddress!, count: w) }
            } else {
                for k in 0..<w { b.outputs[c][k] = arr[k].floatValue }
            }
        }
    }

    // MARK: compiled-model cache

    /// A `.mlpackage` is compiled once per file version and kept; a `.mlmodelc` is used as is.
    static func compiledModel(for url: URL) throws -> URL {
        if url.pathExtension.lowercased() == "mlmodelc" { return url }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325            // FNV-1a of path and modification time: stable across launches
        for b in Array("\(url.standardizedFileURL.path)|\(mtime)".utf8) { hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        let dir = cacheDirectory()
        let dest = dir.appendingPathComponent(String(format: "%016llx.mlmodelc", hash), isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        final class Outcome: @unchecked Sendable { var result: Result<URL, Error>? }
        let outcome = Outcome(), done = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            do { outcome.result = .success(try await MLModel.compileModel(at: url)) } catch { outcome.result = .failure(error) }
            done.signal()
        }
        done.wait()
        let temp = try outcome.result!.get()
        _ = try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    static func cacheDirectory() -> URL {
        if ProcessInfo.processInfo.environment["AUREON_TESTING"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("aureon-tests-models-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Aureon/Models/Compiled", isDirectory: true)
    }
}

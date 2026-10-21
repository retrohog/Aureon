import Foundation
import AVFoundation
import AudioToolbox
import Synchronization

// The DSP path of the dual-path architecture.
//
//   ring ─► AVAudioSourceNode ─► parametric EQ ─► hosted Audio Units … ─► mixer ─► engine output
//
// The AVAudioEngine runs in *manual rendering* mode and is never connected to hardware: the device's IOProc
// calls `render`, which pulls exactly the frames it needs through `manualRenderingBlock`. When DSP is off the
// IOProc skips this class entirely and reads the ring directly (the bit-perfect path).

struct EQBand: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case peak, lowShelf, highShelf, lowCut, highCut
        var id: String { rawValue }
        var title: String { switch self { case .peak: "Peak"; case .lowShelf: "Low shelf"; case .highShelf: "High shelf"; case .lowCut: "Low cut"; case .highCut: "High cut" } }
    }
    var id: Int
    var frequency: Double
    var gainDB: Double = 0
    var q: Double = 1.0
    var kind: Kind = .peak
    var enabled = true

    /// AVAudioUnitEQ expresses width in octaves: BW = 2/ln2 · asinh(1/2Q).
    var bandwidthOctaves: Double { 2 / M_LN2 * asinh(1 / (2 * max(q, 0.05))) }
}

struct EQSettings: Codable, Equatable {
    var enabled = false
    var preampDB = 0.0
    /// Lower the preamp automatically by the largest boost so the EQ cannot clip.
    var autoPreamp = true
    var bands: [EQBand] = EQSettings.defaultBands()

    static func defaultBands() -> [EQBand] {
        [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].enumerated().map { EQBand(id: $0.offset, frequency: $0.element) }
    }
    var effectivePreampDB: Double {
        autoPreamp ? preampDB - max(0, bands.filter { $0.enabled && $0.kind != .lowCut && $0.kind != .highCut }.map(\.gainDB).max() ?? 0) : preampDB
    }
}

struct DSPSettings: Codable, Equatable {
    var enabled = false
    var eq = EQSettings()
}

struct PluginInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let description: AudioComponentDescription
    static func == (a: PluginInfo, b: PluginInfo) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

final class DSPChain: @unchecked Sendable {
    private var engine = AVAudioEngine()
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    private(set) var plugins: [AVAudioUnit] = []
    private var source: AVAudioSourceNode?
    private var block: AVAudioEngineManualRenderingBlock?
    // Render target owned by us (no AVAudioPCMBuffer, no Objective-C calls on the audio thread).
    private var abl: UnsafeMutableAudioBufferListPointer?
    private var planes: [UnsafeMutablePointer<Float>] = []
    private let state = RenderState()
    private(set) var prepared = false
    /// Result of the most recent manual render call (diagnostics).
    private(set) var lastStatus: AVAudioEngineManualRenderingStatus = .success
    private(set) var lastOSStatus: OSStatus = noErr
    private(set) var maxFrames = 4096
    private var channels = 2, rate = 44_100.0

    /// State shared with the render callbacks: preallocated, touched only on the audio thread.
    private final class RenderState: @unchecked Sendable {
        var got = 0
        var scratch: UnsafeMutablePointer<Int32>? = nil
        var scratchFrames = 0
        var channels = 2
    }

    // MARK: discovery

    static func availableEffects() -> [PluginInfo] {
        let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: d).map {
            PluginInfo(id: "\(fourCC($0.audioComponentDescription.componentManufacturer))-\(fourCC($0.audioComponentDescription.componentSubType))-\($0.name)",
                       name: $0.name, manufacturer: $0.manufacturerName, description: $0.audioComponentDescription)
        }.sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
    }

    static func instantiate(_ info: PluginInfo) async throws -> AVAudioUnit {
        try await AVAudioUnit.instantiate(with: info.description, options: [])
    }

    // MARK: configuration (any thread except the audio thread)

    func apply(_ s: EQSettings) {
        for (i, b) in s.bands.prefix(10).enumerated() {
            let p = eq.bands[i]
            switch b.kind {
            case .peak: p.filterType = .parametric
            case .lowShelf: p.filterType = .lowShelf
            case .highShelf: p.filterType = .highShelf
            case .lowCut: p.filterType = .highPass
            case .highCut: p.filterType = .lowPass
            }
            p.frequency = Float(b.frequency)
            p.bandwidth = Float(b.bandwidthOctaves)
            p.gain = Float(b.gainDB)
            p.bypass = !(s.enabled && b.enabled)
        }
        eq.globalGain = Float(max(-96, min(24, s.enabled ? s.effectivePreampDB : 0)))
        eq.bypass = !s.enabled
    }

    func setPlugins(_ list: [AVAudioUnit]) {
        plugins = list
        if prepared { try? rebuild() }
    }

    // MARK: lifecycle

    func prepare(sampleRate: Double, channels: Int, ring: RingBuffer, maxFrames: Int = 4096) throws {
        teardown()
        ringRef = ring
        rate = sampleRate; self.channels = channels; self.maxFrames = maxFrames
        state.channels = channels
        state.scratch?.deallocate()
        state.scratch = .allocate(capacity: maxFrames * channels); state.scratchFrames = maxFrames
        try rebuild()
        prepared = true
    }

    /// Connects the graph for the current rate/channels and starts the (hardware-less) engine.
    private func rebuild() throws {
        engine.stop()
        for n in [eq] + plugins { if n.engine != nil { engine.detach(n) } }
        if let s = source, s.engine != nil { engine.detach(s) }
        engine = AVAudioEngine()

        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
        try engine.enableManualRenderingMode(.realtime, format: fmt, maximumFrameCount: AVAudioFrameCount(maxFrames))

        let st = state, ring = ringRef, ch = channels
        let src = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            guard let scratch = st.scratch, n <= st.scratchFrames else { st.got = 0; return noErr }
            let got = ring?.read(into: scratch, frames: n) ?? 0
            st.got = got
            for c in 0..<min(ch, list.count) {
                guard let dst = list[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<got { dst[f] = Float(scratch[f * ch + c]) / 2_147_483_648.0 }
                if got < n { for f in got..<n { dst[f] = 0 } }
            }
            return noErr
        }
        source = src
        engine.attach(src)
        for n in [eq] + plugins { engine.attach(n) }
        var prev: AVAudioNode = src
        for n in [eq] + plugins { engine.connect(prev, to: n, format: fmt); prev = n }
        engine.connect(prev, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try engine.start()
        block = engine.manualRenderingBlock
        freeTarget()
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        for i in 0..<channels {
            let plane = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            plane.initialize(repeating: 0, count: maxFrames)
            planes.append(plane)
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * 4), mData: plane)
        }
        abl = list
    }

    nonisolated(unsafe) private var ringRef: RingBuffer?
    func teardown() {
        prepared = false
        engine.stop()
        for n in [eq] + plugins { if n.engine != nil { engine.detach(n) } }
        if let s = source, s.engine != nil { engine.detach(s) }
        block = nil; source = nil
        freeTarget()
    }

    private func freeTarget() {
        if let a = abl { free(a.unsafeMutablePointer) }
        abl = nil
        planes.forEach { $0.deallocate() }; planes = []
    }

    deinit { state.scratch?.deallocate(); freeTarget() }

    // MARK: real-time

    /// Pulls `frames` through the graph into interleaved Int32. Returns the number of valid frames (always `frames`
    /// while the engine runs: effect tails continue after the source ends). `underrun` reports a starved source.
    func render(frames: Int, into dst: UnsafeMutablePointer<Int32>, underrun: inout Bool) -> Int {
        guard prepared, let block, let list = abl else { return 0 }
        var done = 0
        underrun = false
        while done < frames {
            let n = min(maxFrames, frames - done)
            for i in 0..<list.count { list[i].mDataByteSize = UInt32(n * 4); list[i].mData = UnsafeMutableRawPointer(planes[i]) }
            var status: OSStatus = noErr
            let r = block(AVAudioFrameCount(n), list.unsafeMutablePointer, &status)
            lastStatus = r; lastOSStatus = status
            guard r == .success else { break }
            if state.got < n { underrun = true }
            for c in 0..<min(channels, list.count) {
                guard let src = list[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<n {
                    let v = (Double(src[f]) * 2_147_483_648.0).rounded()
                    dst[(done + f) * channels + c] = v >= 2_147_483_647 ? .max : (v <= -2_147_483_648 ? .min : Int32(v))
                }
            }
            done += n
        }
        return done
    }
}

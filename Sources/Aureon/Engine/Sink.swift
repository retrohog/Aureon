import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

// MARK: - Settings

struct RamSettings: Equatable, Codable {
    var enabled = false
    var budgetMB = 1024
}

/// Real-time post-processing, applied after the decoded stream (live: changes never rebuild the stream).
struct RTSettings: Codable, Equatable {
    var convolution = ConvolutionSettings()
    var crossfeed = CrossfeedSettings()
    var headphoneEQ = HeadphoneEQSettings()
    var anyEnabled: Bool { convolution.enabled || crossfeed.enabled || headphoneEQ.enabled }
}

/// Everything the user can change about how audio is processed. Changes to anything except `dsp` and `rt` rebuild the
/// decoded stream (a short re-buffer); DSP and real-time processing changes apply live.
/// Internet radio is lossy and arrives at 32/44.1/48 kHz. Resampling it once, with a long sinc filter, to the best rate the DAC supports keeps the
/// system mixer out of the path and moves the filter's image rejection far above the audible band. It cannot restore detail the codec threw away.
struct RadioSettings: Equatable, Codable {
    var upscale = true
    var maxRate: Double = 192_000
}

struct PlaybackSettings: Equatable, Codable {
    var radio = RadioSettings()
    /// DJ decks: every track is resampled to this one rate, so two decks can share a device without either changing its clock. nil = off.
    var deckRate: Double? = nil
    var replayGain = ReplayGainSettings()
    var upsampling = UpsamplingSettings()
    var dsd = DSDSettings()
    var ram = RamSettings()
    var polarityInverted = false
    var dsp = DSPSettings()
    var rt = RTSettings()

    init() {}

    /// Tolerant decoding: settings saved by an older version (missing keys) still load.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        radio = try c.decodeIfPresent(RadioSettings.self, forKey: .radio) ?? radio
        deckRate = try c.decodeIfPresent(Double.self, forKey: .deckRate)
        replayGain = try c.decodeIfPresent(ReplayGainSettings.self, forKey: .replayGain) ?? replayGain
        upsampling = try c.decodeIfPresent(UpsamplingSettings.self, forKey: .upsampling) ?? upsampling
        dsd = try c.decodeIfPresent(DSDSettings.self, forKey: .dsd) ?? dsd
        ram = try c.decodeIfPresent(RamSettings.self, forKey: .ram) ?? ram
        polarityInverted = try c.decodeIfPresent(Bool.self, forKey: .polarityInverted) ?? false
        dsp = try c.decodeIfPresent(DSPSettings.self, forKey: .dsp) ?? dsp
        rt = try c.decodeIfPresent(RTSettings.self, forKey: .rt) ?? rt
    }

    var streamKey: PlaybackSettings { var s = self; s.dsp = DSPSettings(); s.rt = RTSettings(); return s }
}

struct PlayerOptions {
    var hog = false                  // exclusive access to the device
    var rateSwitch = true            // follow each stream's sample rate
    var deviceID: AudioDeviceID? = nil
    var bufferSeconds = 5.0
    /// Put the decode/engine thread under a time-constraint scheduling policy.
    var promoteEngineThread = false
    /// Fraction of each IO cycle the device lets our callback use (nil = leave the system default).
    var ioCycleUsage: Float? = nil
    /// Told when playback starts and when it ends (quiet mode).
    var tuning: PlaybackTuning? = nil
    /// Replace the output (tests use a recording sink). Default: CoreAudio on `deviceID`.
    var sinkFactory: ((PlayerOptions) -> AudioSink?)? = nil
    /// Prepare the first track and hold it paused until told to play (DJ decks).
    var startPaused = false
}

/// A level applied to a deck's output (channel fader × crossfader). Read on the real-time thread, written from the interface.
final class DeckGain: @unchecked Sendable {
    private let bits = Atomic<UInt32>(Float(1).bitPattern)
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(max(0, min(4, newValue.isFinite ? newValue : 0)).bitPattern, ordering: .relaxed) }
    }
}

// MARK: - Renderer: the dual path

/// Called from the real-time thread. DSP off → read the ring directly (bit-perfect path).
/// DSP on → pull through the AVAudioEngine manual-rendering block. No locks, no allocation, no I/O.
final class Renderer: @unchecked Sendable {
    let ring: RingBuffer
    let channels: Int
    let dsp: DSPChain
    let useDSP = Atomic<Bool>(false)
    let underruns: Counter
    /// Hot-swappable post-processing (convolution, crossfeed, headphone EQ). Empty by default: the direct path stays untouched.
    let chain = RCUBox<RTChainState>()
    let tap: AnalysisTap
    /// Set before the stream starts (DJ decks). Changes are smoothed over each render block to avoid clicks.
    var deckGain: DeckGain?
    private var lastGain: Float = 1          // real-time thread only

    init(ring: RingBuffer, channels: Int, dsp: DSPChain, underruns: Counter, tap: AnalysisTap) {
        self.ring = ring; self.channels = channels; self.dsp = dsp; self.underruns = underruns; self.tap = tap
    }

    /// Fills `dst` with up to `frames` interleaved frames and returns how many are valid (the caller zero-fills the rest).
    @inline(__always)
    func render(into dst: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var n: Int
        if useDSP.load(ordering: .relaxed) && dsp.prepared {
            var starved = false
            n = dsp.render(frames: frames, into: dst, underrun: &starved)
            if starved && !ring.intentionallySilent { _ = underruns.n.add(1, ordering: .relaxed) }
        } else {
            n = ring.read(into: dst, frames: frames)
            if n < frames && !ring.intentionallySilent { _ = underruns.n.add(1, ordering: .relaxed) }
        }
        if n > 0 {
            _ = chain.read { $0.run(dst, frames: n) }
            if let dg = deckGain {
                let target = dg.value
                if target != 1 || lastGain != 1 {
                    let step = (target - lastGain) / Float(n)
                    var g = lastGain
                    for f in 0..<n {
                        g += step
                        let gd = Double(g)
                        for c in 0..<channels { let i = f * channels + c; dst[i] = Int32(clamping: Int64(Double(dst[i]) * gd)) }
                    }
                    lastGain = target
                }
            }
            tap.write(dst, frames: n, channels: channels)
        }
        return n
    }
}

// MARK: - Sink protocol

struct SinkReport { var lines: [String]; var bitPerfect: Bool }

protocol AudioSink: AnyObject {
    var deviceName: String { get }
    /// Rates the output can run at; empty means unconstrained.
    var supportedRates: [Double] { get }
    func configure(for info: StreamInfo, options: PlayerOptions) -> SinkReport
    func start(renderer: Renderer) throws
    func stop()
    /// Restores anything configure() changed (device clock, exclusive access).
    func shutdown()
}

// MARK: - CoreAudio sink

final class CoreAudioSink: AudioSink {
    let device: OutputDevice
    private var proc: AudioDeviceIOProcID?
    private var scratch: UnsafeMutablePointer<Int32>?
    var deviceName: String { device.name }
    var supportedRates: [Double] { device.supportedRates }

    init?(deviceID: AudioDeviceID?) {
        guard let d = OutputDevice(id: deviceID) else { return nil }
        device = d
    }

    func configure(for f: StreamInfo, options o: PlayerOptions) -> SinkReport {
        var lines: [String] = []
        if o.hog { lines.append(device.takeHog() ? "Exclusive (hog) mode: on" : "Exclusive mode unavailable, sharing the device") }
        if o.rateSwitch {
            if device.canRun(at: f.sampleRate) {
                lines.append(device.setRate(f.sampleRate) ? "Device clock → \(Int(f.sampleRate)) Hz (native)" : "Could not switch clock; device stays at \(Int(device.currentRate)) Hz")
            } else {
                lines.append("Device cannot run \(Int(f.sampleRate)) Hz; the system will resample")
            }
        }
        if let phys = device.negotiateIntegerFormat(rate: f.sampleRate, bits: max(f.sourceBits, f.isDoP ? 24 : 0), channels: f.channels) {
            lines.append("Physical format: \(phys)")
        }
        _ = device.requestInt32Virtual(rate: f.sampleRate, channels: f.channels)
        let rate = device.currentRate
        let exact = abs(rate - f.sampleRate) < 0.5
        let floatOK = device.virtualFormat().map { $0.mFormatFlags & kAudioFormatFlagIsFloat == 0 || f.sourceBits <= 24 } ?? false
        lines.append(exact && floatOK ? "Device accepts the stream at its native rate and depth" : "Device rate \(Int(rate)) Hz differs from the stream's \(Int(f.sampleRate)) Hz")
        return SinkReport(lines: lines, bitPerfect: exact && floatOK)
    }

    func start(renderer: Renderer) throws {
        let isFloat = (device.virtualFormat()?.mFormatFlags ?? kAudioFormatFlagIsFloat) & kAudioFormatFlagIsFloat != 0
        let fileChannels = renderer.channels
        let maxFrames = 65_536
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: maxFrames * fileChannels)   // freed in stop()
        scratch = buf

        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, _, _, outData, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outData)
            guard let b = abl.first, let out = b.mData else { return }
            let devCh = max(Int(b.mNumberChannels), 1)
            let frames = min(Int(b.mDataByteSize) / (devCh * 4), maxFrames)
            let got = renderer.render(into: buf, frames: frames)

            if isFloat {
                // Int32 → Float32 is exact for up to 24-bit sources (float has a 24-bit mantissa).
                let o = out.assumingMemoryBound(to: Float.self)
                for f in 0..<frames { for c in 0..<devCh {
                    o[f * devCh + c] = (f < got && c < fileChannels) ? Float(buf[f * fileChannels + c]) / 2_147_483_648.0 : 0
                } }
            } else {
                let o = out.assumingMemoryBound(to: Int32.self)
                for f in 0..<frames { for c in 0..<devCh {
                    o[f * devCh + c] = (f < got && c < fileChannels) ? buf[f * fileChannels + c] : 0
                } }
            }
        }, "AudioDeviceCreateIOProcID")
        guard let procID else { throw AureonError.message("could not create IOProc") }
        proc = procID
        try check(AudioDeviceStart(device.id, procID), "AudioDeviceStart")
    }

    func stop() {
        if let p = proc { AudioDeviceStop(device.id, p); AudioDeviceDestroyIOProcID(device.id, p); proc = nil }
        scratch?.deallocate(); scratch = nil
    }

    func shutdown() { stop(); device.restore() }
}

// MARK: - Recording sink (tests, offline analysis)

/// Consumes the ring exactly like a DAC would and keeps every sample, so tests can verify the delivered stream.
final class RecordingSink: AudioSink, @unchecked Sendable {
    let deviceName = "Recording sink"
    let supportedRates: [Double]
    private let lock = NSLock()
    private var _samples: [Int32] = []
    private var _configured: [StreamInfo] = []
    private var thread: Thread?
    private var channels = 2
    private var rate = 44_100.0
    /// 0 = consume as fast as the producer delivers; otherwise real-time × speed (lets tests edit the queue mid-playback).
    let speed: Double

    init(rates: [Double] = [], speed: Double = 0) { supportedRates = rates; self.speed = speed }

    var samples: [Int32] { lock.lock(); defer { lock.unlock() }; return _samples }
    var configured: [StreamInfo] { lock.lock(); defer { lock.unlock() }; return _configured }
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return _samples.count / max(channels, 1) }

    func configure(for info: StreamInfo, options: PlayerOptions) -> SinkReport {
        lock.lock(); _configured.append(info); channels = info.channels; rate = info.sampleRate; lock.unlock()
        return SinkReport(lines: ["Recording sink at \(Int(info.sampleRate)) Hz"], bitPerfect: true)
    }

    private final class Loop: @unchecked Sendable { let on = Atomic<Bool>(true); let exited = DispatchSemaphore(value: 0) }
    private var loop: Loop?

    func start(renderer: Renderer) throws {
        let l = Loop(); loop = l
        let ch = renderer.channels
        let t = Thread { [self] in
            let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 1024 * ch)
            defer { buf.deallocate(); l.exited.signal() }
            while l.on.load(ordering: .relaxed) {
                let n = renderer.render(into: buf, frames: 1024)
                if n > 0 {
                    lock.lock(); _samples.append(contentsOf: UnsafeBufferPointer(start: buf, count: n * ch)); lock.unlock()
                    if speed > 0 { usleep(UInt32(Double(n) / rate / speed * 1_000_000)) }
                } else { usleep(300) }
            }
        }
        t.start(); thread = t
    }

    /// Like AudioDeviceStop: returns only once the consumer has exited.
    func stop() {
        guard let l = loop else { return }
        l.on.store(false, ordering: .relaxed); l.exited.wait(); loop = nil; thread = nil
    }
    func shutdown() { stop() }
}

// MARK: - Null sink

/// Consumes audio in real time and throws it away: for servers without an audio device and for `daemon --null-sink`.
final class NullSink: AudioSink, @unchecked Sendable {
    let deviceName = "No audio output (null sink)"
    let supportedRates: [Double] = []
    private var loop: Loop?
    private final class Loop: @unchecked Sendable { let on = Atomic<Bool>(true); let exited = DispatchSemaphore(value: 0) }
    private var rate = 44_100.0

    func configure(for info: StreamInfo, options: PlayerOptions) -> SinkReport {
        rate = info.sampleRate
        return SinkReport(lines: ["Null sink: audio is decoded and discarded"], bitPerfect: false)
    }

    func start(renderer: Renderer) throws {
        let l = Loop(); loop = l
        let ch = renderer.channels, r = rate
        Thread {
            let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 1024 * ch)
            defer { buf.deallocate(); l.exited.signal() }
            while l.on.load(ordering: .relaxed) {
                let n = renderer.render(into: buf, frames: 1024)
                usleep(n > 0 ? UInt32(Double(n) / r * 1_000_000) : 5_000)
            }
        }.start()
    }

    func stop() { guard let l = loop else { return }; l.on.store(false, ordering: .relaxed); l.exited.wait(); loop = nil }
    func shutdown() { stop() }
}

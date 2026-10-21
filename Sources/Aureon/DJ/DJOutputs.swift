import Foundation
import CoreAudio
import AudioToolbox

/// A deck's player renders into this instead of a device: the mixer pulls from the renderer in its own output callback, so both decks run on one clock.
final class DeckSink: AudioSink {
    let deck: DJMixerCore.Deck
    let rate: Double
    var deviceName: String { "DJ mixer" }
    var supportedRates: [Double] { [rate] }
    init(deck: DJMixerCore.Deck, rate: Double) { self.deck = deck; self.rate = rate }
    func configure(for info: StreamInfo, options: PlayerOptions) -> SinkReport { SinkReport(lines: ["Deck stream → mixer at \(Int(info.sampleRate)) Hz"], bitPerfect: false) }
    func start(renderer: Renderer) throws { deck.renderer.publish(renderer) }
    func stop() { deck.renderer.publish(nil) }
    func shutdown() { stop() }
}

/// Where the mixed signal goes.
protocol DJOutput: AnyObject {
    func start() throws
    func stop()
}

/// The main output: the mixer's master bus on a Core Audio device (and, on a device with four or more outputs, the headphone bus on outputs 3-4).
final class CoreAudioDJOutput: DJOutput {
    let device: OutputDevice
    private let core: DJMixerCore
    private let cueRing: FloatRing?
    private let cueOnChannels34: Bool
    private var proc: AudioDeviceIOProcID?
    private var master: UnsafeMutablePointer<Float>?, cue: UnsafeMutablePointer<Float>?

    /// `cueRing`: when a second device is used for headphones, the cue bus is also written here.
    init?(deviceID: AudioDeviceID?, core: DJMixerCore, cueRing: FloatRing? = nil, cueOnChannels34: Bool = false) {
        guard let d = OutputDevice(id: deviceID) else { return nil }
        device = d; self.core = core; self.cueRing = cueRing; self.cueOnChannels34 = cueOnChannels34
    }

    func start() throws {
        let isFloat = (device.virtualFormat()?.mFormatFlags ?? kAudioFormatFlagIsFloat) & kAudioFormatFlagIsFloat != 0
        let maxFrames = 16_384
        let m = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2), c = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
        m.initialize(repeating: 0, count: maxFrames * 2); c.initialize(repeating: 0, count: maxFrames * 2)
        master = m; cue = c
        let core = self.core, ring = cueRing, wantsCue34 = cueOnChannels34
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, _, _, outData, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outData)
            guard let b = abl.first, let out = b.mData else { return }
            let devCh = max(Int(b.mNumberChannels), 1)
            let frames = min(Int(b.mDataByteSize) / (devCh * 4), maxFrames)
            let useCue34 = wantsCue34 && devCh >= 4
            core.process(master: m, cue: (useCue34 || ring != nil) ? c : nil, frames: frames)
            if let ring { ring.write(c, frames: frames) }
            func sample(_ i: Int, _ ch: Int) -> Float {
                if ch < 2 { return m[i * 2 + ch] }
                if useCue34 && ch < 4 { return c[i * 2 + (ch - 2)] }
                return 0
            }
            if isFloat {
                let o = out.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { for ch in 0..<devCh { o[i * devCh + ch] = sample(i, ch) } }
            } else {
                let o = out.assumingMemoryBound(to: Int32.self)
                for i in 0..<frames { for ch in 0..<devCh { o[i * devCh + ch] = Int32(clamping: Int64(max(-1, min(1, sample(i, ch))) * 2_147_483_647)) } }
            }
        }, "AudioDeviceCreateIOProcID")
        guard let procID else { throw AureonError.message("could not create IOProc") }
        proc = procID
        try check(AudioDeviceStart(device.id, procID), "AudioDeviceStart")
    }

    func stop() {
        if let p = proc { AudioDeviceStop(device.id, p); AudioDeviceDestroyIOProcID(device.id, p); proc = nil }
        master?.deallocate(); master = nil; cue?.deallocate(); cue = nil
    }
}

/// Headphones on a second device: reads the cue ring through `CueResampler`, which follows this device's own clock.
final class CoreAudioCueOutput: DJOutput {
    let device: OutputDevice
    private let ring: FloatRing
    private let srcRate: Double
    private var proc: AudioDeviceIOProcID?
    private var resampler: CueResampler?
    private var scratch: UnsafeMutablePointer<Float>?

    init?(deviceID: AudioDeviceID, ring: FloatRing, srcRate: Double) {
        guard let d = OutputDevice(id: deviceID) else { return nil }
        device = d; self.ring = ring; self.srcRate = srcRate
    }

    func start() throws {
        let isFloat = (device.virtualFormat()?.mFormatFlags ?? kAudioFormatFlagIsFloat) & kAudioFormatFlagIsFloat != 0
        let rs = CueResampler(ring: ring, srcRate: srcRate, dstRate: max(8000, device.currentRate), targetFill: Int(srcRate * 0.06))
        resampler = rs
        let maxFrames = 16_384
        let s = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2); s.initialize(repeating: 0, count: maxFrames * 2); scratch = s
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, _, _, outData, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outData)
            guard let b = abl.first, let out = b.mData else { return }
            let devCh = max(Int(b.mNumberChannels), 1)
            let frames = min(Int(b.mDataByteSize) / (devCh * 4), maxFrames)
            rs.render(into: s, frames: frames)
            if isFloat {
                let o = out.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { for ch in 0..<devCh { o[i * devCh + ch] = ch < 2 ? s[i * 2 + ch] : 0 } }
            } else {
                let o = out.assumingMemoryBound(to: Int32.self)
                for i in 0..<frames { for ch in 0..<devCh { o[i * devCh + ch] = ch < 2 ? Int32(clamping: Int64(max(-1, min(1, s[i * 2 + ch])) * 2_147_483_647)) : 0 } }
            }
        }, "AudioDeviceCreateIOProcID")
        guard let procID else { throw AureonError.message("could not create IOProc") }
        proc = procID
        try check(AudioDeviceStart(device.id, procID), "AudioDeviceStart")
    }

    func stop() {
        if let p = proc { AudioDeviceStop(device.id, p); AudioDeviceDestroyIOProcID(device.id, p); proc = nil }
        scratch?.deallocate(); scratch = nil; resampler = nil
    }
}

/// Pulls the mixer at (a multiple of) real time and keeps what it produced: tests and offline rendering.
final class PullOutput: DJOutput, @unchecked Sendable {
    private let core: DJMixerCore
    private let speed: Double
    private let lock = NSLock()
    private var _master: [Float] = [], _cue: [Float] = []
    private let running = Atomic2()
    private var thread: Thread?
    private let exited = DispatchSemaphore(value: 0)
    let keepCue: Bool
    var keep = true

    final class Atomic2: @unchecked Sendable { private let l = NSLock(); private var v = false; var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } } }

    init(core: DJMixerCore, speed: Double = 1, keepCue: Bool = false) { self.core = core; self.speed = max(0.05, speed); self.keepCue = keepCue }

    var master: [Float] { lock.lock(); defer { lock.unlock() }; return _master }
    var cue: [Float] { lock.lock(); defer { lock.unlock() }; return _cue }
    var frames: Int { master.count / 2 }

    func start() throws {
        running.value = true
        let t = Thread { [self] in
            let n = 512
            let m = UnsafeMutablePointer<Float>.allocate(capacity: n * 2), c = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
            defer { m.deallocate(); c.deallocate(); exited.signal() }
            var next = Date()
            while running.value {
                core.process(master: m, cue: keepCue ? c : nil, frames: n)
                lock.lock(); if keep { _master.append(contentsOf: UnsafeBufferPointer(start: m, count: n * 2)) }; if keepCue && keep { _cue.append(contentsOf: UnsafeBufferPointer(start: c, count: n * 2)) }; lock.unlock()
                next = next.addingTimeInterval(Double(n) / core.sampleRate / speed)
                let wait = next.timeIntervalSinceNow
                if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
            }
        }
        t.name = "aureon.pull"; thread = t; t.start()
    }

    func stop() { running.value = false; if thread != nil { exited.wait(); thread = nil } }
}

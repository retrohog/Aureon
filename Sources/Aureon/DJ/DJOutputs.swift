import Foundation
import CoreAudio
import AudioToolbox

/// A deck's player renders into this instead of a device: the mixer pulls from the renderer in its own output callback, so both decks run on one clock.
final class DeckSink: AudioSink {
    let deck: DJMixerCore.Deck
    let rate: Double
    var deviceName: String { "DJ mixer" }
    var supportedRates: [Double] { [rate] }
    var outputChannels: Int { 2 }                    // the mixer works in stereo: multichannel files are mixed down before they reach it
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
                for i in 0..<frames { for ch in 0..<devCh { o[i * devCh + ch] = Int32(clamping: Int64((max(-1, min(1, sample(i, ch))) * 2_147_483_648).rounded())) } }
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
                for i in 0..<frames { for ch in 0..<devCh { o[i * devCh + ch] = ch < 2 ? Int32(clamping: Int64((max(-1, min(1, s[i * 2 + ch])) * 2_147_483_648).rounded())) : 0 } }
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

// MARK: - Live inputs

/// An audio input device (a microphone or a line input).
struct InputDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let channels: Int
    let rate: Double

    /// Every device with at least one input channel.
    static func all() -> [InputDeviceInfo] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { info($0) }
    }

    static func defaultInput() -> InputDeviceInfo? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return info(id)
    }

    static func info(_ id: AudioDeviceID) -> InputDeviceInfo? {
        var cfg = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &cfg, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &cfg, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let ch = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard ch > 0 else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?; var nsz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let name = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsz, &cf) == noErr ? (cf?.takeRetainedValue() as String?) ?? "Input" : "Input"
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(48_000); var rsz = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(id, &rateAddr, 0, nil, &rsz, &rate)
        return InputDeviceInfo(id: id, name: name, channels: ch, rate: rate > 0 ? rate : 48_000)
    }
}

/// Captures an input device into a ring and publishes it as a mixer channel's feed. The capture callback only converts and copies into the ring.
final class CoreAudioLineInput: DJOutput {
    let device: InputDeviceInfo
    private let channel: DJMixerCore.Deck
    private let mixerRate: Double
    private var proc: AudioDeviceIOProcID?
    private let ring: FloatRing
    private var scratch: UnsafeMutablePointer<Float>?

    init(device: InputDeviceInfo, channel: DJMixerCore.Deck, mixerRate: Double) {
        self.device = device; self.channel = channel; self.mixerRate = mixerRate
        ring = FloatRing(frames: Int(device.rate))
    }

    func start() throws {
        let maxFrames = 16_384
        let s = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2); s.initialize(repeating: 0, count: maxFrames * 2); scratch = s
        let ring = self.ring
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, inData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let b = abl.first, let data = b.mData else { return }
            let ch = max(Int(b.mNumberChannels), 1)
            let frames = min(Int(b.mDataByteSize) / (ch * 4), maxFrames)
            let p = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                let l = p[i * ch]
                s[i * 2] = l; s[i * 2 + 1] = ch > 1 ? p[i * ch + 1] : l
            }
            ring.write(s, frames: frames)
        }, "AudioDeviceCreateIOProcID")
        guard let procID else { throw AureonError.message("could not create the input callback") }
        proc = procID
        channel.feed.publish(LineFeed(ring: ring, srcRate: device.rate, dstRate: mixerRate))
        try check(AudioDeviceStart(device.id, procID), "AudioDeviceStart")
    }

    func stop() {
        channel.feed.publish(nil)
        if let p = proc { AudioDeviceStop(device.id, p); AudioDeviceDestroyIOProcID(device.id, p); proc = nil }
        scratch?.deallocate(); scratch = nil
    }
}

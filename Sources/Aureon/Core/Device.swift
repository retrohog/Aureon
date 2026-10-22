import Foundation
import CoreAudio
import AudioToolbox

// MARK: - CoreAudio device helpers

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getValue<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, default def: T) -> T? {
    var a = a, v = def, sz = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr ? v : nil
}

func getArray<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, of: T.Type) -> [T] {
    var a = a, sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    let n = Int(sz) / MemoryLayout<T>.stride
    let p = UnsafeMutablePointer<T>.allocate(capacity: n)
    defer { p.deallocate() }
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, p) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: n))
}

func setValue<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ v: T) -> OSStatus {
    var a = a, v = v
    return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
}

final class OutputDevice {
    let id: AudioDeviceID
    let name: String
    private(set) var originalRate: Double
    private var hogged = false
    private var ioBufferOriginal = 0

    init?(id: AudioDeviceID? = nil) {
        guard let dev = id ?? getValue(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDefaultOutputDevice), default: AudioDeviceID(0)),
              dev != 0 else { return nil }
        self.id = dev
        var nm: Unmanaged<CFString>? = nil
        var a = addr(kAudioObjectPropertyName), sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &nm)
        name = (nm?.takeRetainedValue() as String?) ?? "device \(dev)"
        originalRate = getValue(dev, addr(kAudioDevicePropertyNominalSampleRate), default: Float64(0)) ?? 0
    }

    var currentRate: Double { getValue(id, addr(kAudioDevicePropertyNominalSampleRate), default: Float64(0)) ?? 0 }

    /// Discrete rates the device can run its clock at.
    var supportedRates: [Double] {
        let ranges = getArray(id, addr(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)
        var out = Set<Double>()
        for r in ranges { out.insert(r.mMinimum); out.insert(r.mMaximum) }
        return out.sorted()
    }

    func canRun(at rate: Double) -> Bool {
        getArray(id, addr(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)
            .contains { $0.mMinimum - 0.5 <= rate && rate <= $0.mMaximum + 0.5 }
    }

    var outputStreams: [AudioStreamID] {
        getArray(id, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), of: AudioStreamID.self)
    }

    /// Switch the device clock to `rate` and wait until the hardware reports it.
    func setRate(_ rate: Double) -> Bool {
        if abs(currentRate - rate) < 0.5 { return true }
        guard setValue(id, addr(kAudioDevicePropertyNominalSampleRate), Float64(rate)) == noErr else { return false }
        for _ in 0..<40 {
            if abs(currentRate - rate) < 0.5 { usleep(250_000); return true }  // let the DAC PLL settle
            usleep(50_000)
        }
        return false
    }

    func takeHog() -> Bool {
        let pid = getValue(id, addr(kAudioDevicePropertyHogMode), default: pid_t(-1)) ?? -1
        if pid != -1 && pid != getpid() { print("device is already hogged by pid \(pid)"); return false }
        guard setValue(id, addr(kAudioDevicePropertyHogMode), getpid()) == noErr else { return false }
        hogged = true
        return true
    }

    /// Ask the stream to use an integer physical format of >= `bits` at `rate` (Audirvana "Integer Mode").
    /// Returns a description of what was chosen, or nil if nothing better than the default exists.
    func negotiateIntegerFormat(rate: Double, bits: Int, channels: Int) -> String? {
        guard let stream = outputStreams.first else { return nil }
        let list = getArray(stream, addr(kAudioStreamPropertyAvailablePhysicalFormats), of: AudioStreamRangedDescription.self)
        let candidates = list.filter {
            let f = $0.mFormat
            return f.mFormatID == kAudioFormatLinearPCM
                && $0.mSampleRateRange.mMinimum - 0.5 <= rate && rate <= $0.mSampleRateRange.mMaximum + 0.5
                && Int(f.mChannelsPerFrame) >= channels
        }
        // Prefer integer formats that hold the whole source, smallest sufficient bit depth first.
        let ints = candidates.filter { $0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0 && Int($0.mFormat.mBitsPerChannel) >= bits }
            .sorted { $0.mFormat.mBitsPerChannel < $1.mFormat.mBitsPerChannel }
        guard var pick = ints.first?.mFormat else { return nil }
        pick.mSampleRate = rate
        guard setValue(stream, addr(kAudioStreamPropertyPhysicalFormat), pick) == noErr else { return nil }
        return "\(pick.mBitsPerChannel)-bit integer, \(pick.mChannelsPerFrame) ch"
    }

    /// The format the IOProc actually receives.
    func virtualFormat() -> AudioStreamBasicDescription? {
        guard let s = outputStreams.first else { return nil }
        return getValue(s, addr(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
    }

    /// Try to make the IOProc receive packed Int32 (no float conversion in the signal path).
    func requestInt32Virtual(rate: Double, channels: Int) -> Bool {
        guard let s = outputStreams.first, var f = virtualFormat() else { return false }
        f.mSampleRate = rate
        f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        f.mBitsPerChannel = 32
        f.mBytesPerFrame = 4 * f.mChannelsPerFrame
        f.mBytesPerPacket = f.mBytesPerFrame
        return setValue(s, addr(kAudioStreamPropertyVirtualFormat), f) == noErr
    }

    // MARK: hardware (DAC) volume — scales in the device, never in our sample path

    private var volumeElements: [UInt32] {
        // Prefer the master element; fall back to channels 1 and 2.
        for els: [UInt32] in [[0], [1, 2]] {
            let ok = els.allSatisfy { e in
                var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
                var settable: DarwinBoolean = false
                return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
            }
            if ok { return els }
        }
        return []
    }

    /// The device volume as it is right now, or nil when the device will not say. A volume is never made up: an invented "100 %" looks exactly
    /// like a loud setting and invites a click that really does make it loud.
    func readVolume() -> Float? {
        let els = volumeElements
        guard !els.isEmpty else { return nil }
        var values: [Float] = []
        for e in els {
            let a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
            guard let v: Float32 = getValue(id, a, default: Float32(0)), v.isFinite else { return nil }
            values.append(v)
        }
        return values.max()
    }

    var hasHardwareVolume: Bool { readVolume() != nil }

    /// Sets the device volume (0…1) on every element. Returns false when the device refused any of them.
    @discardableResult
    func writeVolume(_ newValue: Float) -> Bool {
        let v = Float32(max(0, min(1, newValue.isFinite ? newValue : 0)))
        var ok = true
        for e in volumeElements {
            let a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
            ok = (setValue(id, a, v) == noErr) && ok
        }
        return ok
    }

    // MARK: IO buffer size

    var ioBufferFrames: Int { Int(getValue(id, addr(kAudioDevicePropertyBufferFrameSize), default: UInt32(0)) ?? 0) }

    /// Asks for an IO buffer of about `frames` (clamped to what the device allows). At megahertz sample rates the default 512 frames means thousands of callbacks a second.
    @discardableResult
    func setIOBufferFrames(_ frames: Int) -> Bool {
        let ranges = getArray(id, addr(kAudioDevicePropertyBufferFrameSizeRange), of: AudioValueRange.self)
        guard let r = ranges.first else { return false }
        if ioBufferOriginal == 0 { ioBufferOriginal = ioBufferFrames }
        let want = UInt32(max(r.mMinimum, min(r.mMaximum, Double(frames))))
        return setValue(id, addr(kAudioDevicePropertyBufferFrameSize), want) == noErr
    }

    func restore() {
        if ioBufferOriginal > 0 { _ = setValue(id, addr(kAudioDevicePropertyBufferFrameSize), UInt32(ioBufferOriginal)); ioBufferOriginal = 0 }
        if hogged { _ = setValue(id, addr(kAudioDevicePropertyHogMode), pid_t(-1)); hogged = false }
        if originalRate > 0 { _ = setRate(originalRate) }
    }
}



struct OutputDeviceInfo: Identifiable, Hashable { let id: AudioDeviceID; let name: String; let rates: [Double] }

func listOutputDevices() -> [OutputDeviceInfo] {
    getArray(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), of: AudioDeviceID.self)
        .compactMap { id in
            guard let d = OutputDevice(id: id), !d.outputStreams.isEmpty else { return nil }
            return OutputDeviceInfo(id: id, name: d.name, rates: d.supportedRates)
        }
}

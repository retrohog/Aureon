import Foundation
import AudioToolbox
import CoreAudio

// Multichannel playback: which speaker each channel of a file is for, where the device has that speaker, and what to do when it does not.
//
//   file channels ──► (downmix to what the device can play, when it cannot play them all) ──► ring ──► IOProc ──► channel map ──► device buffers
//
// A stereo file on any device, and a 5.1 or 7.1 file on a device with enough outputs, take the direct path: no stage touches the samples
// (the IOProc only copies each channel to the output where that speaker lives). Downmixing is the only processing, and it is applied
// only when the device cannot play every channel (or when the user asks for stereo).

enum Speaker: Int, Codable, CaseIterable {
    case mono, fl, fr, fc, lfe, ls, rs, lb, rb, bc
    var name: String {
        switch self { case .mono: "M"; case .fl: "L"; case .fr: "R"; case .fc: "C"; case .lfe: "LFE"; case .ls: "Ls"; case .rs: "Rs"; case .lb: "Lb"; case .rb: "Rb"; case .bc: "Bc" }
    }
    var isLeft: Bool { self == .fl || self == .ls || self == .lb }
    var isRight: Bool { self == .fr || self == .rs || self == .rb }
}

enum ChannelLayouts {
    /// The channel order of FLAC, WAV and AIFF files (the same table for all three) for a given channel count.
    static func standard(_ n: Int) -> [Speaker] {
        switch n {
        case 1: return [.mono]
        case 2: return [.fl, .fr]
        case 3: return [.fl, .fr, .fc]
        case 4: return [.fl, .fr, .lb, .rb]
        case 5: return [.fl, .fr, .fc, .lb, .rb]
        case 6: return [.fl, .fr, .fc, .lfe, .ls, .rs]
        case 7: return [.fl, .fr, .fc, .lfe, .bc, .ls, .rs]
        case 8: return [.fl, .fr, .fc, .lfe, .lb, .rb, .ls, .rs]
        default: return (0..<max(0, n)).map { _ in Speaker.mono }
        }
    }

    /// CoreAudio channel labels → speakers.
    static func speaker(forLabel l: UInt32) -> Speaker? {
        switch l {
        case 1: return .fl                         // Left
        case 2: return .fr                         // Right
        case 3: return .fc                         // Center
        case 4: return .lfe                        // LFE screen
        case 5, 10: return .ls                     // Left surround / left surround direct (side)
        case 6, 11: return .rs
        case 9: return .bc                         // Center surround
        case 33: return .lb                        // Rear surround left
        case 34: return .rb
        case 42: return .mono
        case 301: return .fl                       // headphones left
        case 302: return .fr
        default: return nil
        }
    }

    /// The explicit channel descriptions of a layout, as speakers.
    private static func descriptions(of layout: UnsafePointer<AudioChannelLayout>) -> [Speaker?] {
        let n = Int(layout.pointee.mNumberChannelDescriptions)
        // the descriptions follow the fixed part of the struct in memory; indexing a copy of the first one would read past it
        let first = UnsafeRawPointer(layout).advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
        return (0..<n).map { speaker(forLabel: first.advanced(by: $0 * MemoryLayout<AudioChannelDescription>.stride).assumingMemoryBound(to: AudioChannelDescription.self).pointee.mChannelLabel) }
    }

    /// The speakers of a CoreAudio layout (a tag, or explicit descriptions). nil entries are channels this player has no use for.
    static func speakers(of layout: UnsafePointer<AudioChannelLayout>) -> [Speaker?]? {
        var tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions { return descriptions(of: layout) }
        if tag == kAudioChannelLayoutTag_UseChannelBitmap { return nil }
        // a tag: ask CoreAudio what it stands for
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &size, raw) == noErr else { return nil }
        return descriptions(of: UnsafePointer(raw.assumingMemoryBound(to: AudioChannelLayout.self)))
    }

    static func speakers(forTag tag: AudioChannelLayoutTag) -> [Speaker?]? {
        var l = AudioChannelLayout(); l.mChannelLayoutTag = tag
        return withUnsafePointer(to: &l) { speakers(of: $0) }
    }
}

/// Where each source channel goes on a device.
enum ChannelRouter {
    /// `map[deviceChannel]` = source channel feeding it, or -1 for silence. Returns nil when some source channel has no output to go to.
    static func map(source: [Speaker], device: [Speaker?]) -> [Int]? {
        var out = [Int](repeating: -1, count: device.count)
        var placed = Set<Int>()
        func tryPlace(_ i: Int, _ s: Speaker) -> Bool {
            if let d = device.indices.first(where: { device[$0] == s && out[$0] < 0 }) { out[d] = i; placed.insert(i); return true }
            return false
        }
        for (i, s) in source.enumerated() { _ = tryPlace(i, s) }
        // equivalent positions: surrounds and rears stand in for each other when the device has only one of the pairs
        for (i, s) in source.enumerated() where !placed.contains(i) {
            let alternatives: [Speaker]
            switch s {
            case .ls: alternatives = [.lb]; case .rs: alternatives = [.rb]; case .lb: alternatives = [.ls]; case .rb: alternatives = [.rs]
            case .mono: alternatives = [.fc, .fl]; case .bc: alternatives = [.lb, .ls]
            default: alternatives = []
            }
            for a in alternatives where tryPlace(i, a) { break }
        }
        return placed.count == source.count ? out : nil
    }

    /// The straightforward map when the device cannot say where its speakers are: source channel i on output i.
    static func identity(source: Int, device: Int) -> [Int] { (0..<device).map { $0 < source ? $0 : -1 } }
}

enum MultichannelMode: String, Codable, CaseIterable, Identifiable {
    case auto, stereo, passthrough
    var id: String { rawValue }
    var title: String { switch self { case .auto: "Automatic"; case .stereo: "Always stereo"; case .passthrough: "Direct only" } }
    var blurb: String {
        switch self {
        case .auto: "Multichannel files play on every speaker the device has; with fewer outputs they are mixed down."
        case .stereo: "Every multichannel file is mixed down to two channels."
        case .passthrough: "Channels are sent as they are; those the device has no output for are dropped."
        }
    }
}

struct MultichannelSettings: Codable, Equatable {
    var mode = MultichannelMode.auto
    /// Add the LFE channel to the downmix (off by default, as in the standard).
    var includeLFE = false

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(MultichannelMode.self, forKey: .mode) ?? .auto
        includeLFE = try c.decodeIfPresent(Bool.self, forKey: .includeLFE) ?? false
    }
}

enum Downmix {
    /// Matrix[outChannel][inChannel] mixing `source` down to `target` speakers (ITU-R BS.775: centre and surrounds at −3 dB), normalised so that
    /// a full-scale signal on every contributing channel cannot clip.
    static func matrix(from source: [Speaker], to target: [Speaker], includeLFE: Bool = false) -> [[Double]] {
        let k = 0.7071067811865476
        var m = [[Double]](repeating: [Double](repeating: 0, count: source.count), count: target.count)
        for (o, t) in target.enumerated() {
            for (i, s) in source.enumerated() {
                var g = 0.0
                switch (t, s) {
                case (_, _) where t == s: g = 1
                case (.fl, .fc), (.fr, .fc): g = target.contains(.fc) ? 0 : k
                case (.fl, .mono), (.fr, .mono): g = 1
                case (.fl, .ls), (.fr, .rs): g = target.contains(.ls) ? 0 : k
                case (.fl, .lb), (.fr, .rb): g = target.contains(.lb) ? 0 : (target.contains(.ls) ? 0 : 0.5)
                case (.fl, .bc), (.fr, .bc): g = target.contains(.ls) ? 0 : 0.5
                case (.fl, .lfe), (.fr, .lfe): g = includeLFE ? k : 0
                case (.ls, .lb), (.rs, .rb): g = k
                case (.ls, .bc), (.rs, .bc): g = k
                case (.fc, .mono): g = 1
                case (.fc, .fl), (.fc, .fr): g = target.contains(.fl) ? 0 : k
                default: g = 0
                }
                m[o][i] = g
            }
        }
        // headroom: no output may be able to exceed full scale
        for o in 0..<m.count { let sum = m[o].reduce(0, +); if sum > 1 { m[o] = m[o].map { $0 / sum } } }
        // keep the sides balanced when the left and right rows normalised differently (they only differ for odd layouts)
        return m
    }

    /// What a stream of `n` channels is mixed down to for a device with `deviceChannels` outputs.
    static func target(sourceChannels n: Int, deviceChannels: Int, mode: MultichannelMode) -> [Speaker]? {
        switch mode {
        case .passthrough: return nil
        case .stereo: return n > 2 ? [.fl, .fr] : nil
        case .auto:
            guard deviceChannels > 0, n > deviceChannels else { return nil }
            if deviceChannels >= 6, n > 6 { return ChannelLayouts.standard(6) }
            return deviceChannels >= 2 ? [.fl, .fr] : [.mono]
        }
    }
}

/// Mixes a multichannel stream down to fewer channels. Always marks the stream as altered.
final class DownmixSource: FrameSource {
    private let base: FrameSource
    let info: StreamInfo
    private let inCh: Int, outCh: Int
    private let coef: [Float]            // row-major [out][in]
    private let scratch: UnsafeMutablePointer<Int32>
    private let capacity = 8192

    init(_ base: FrameSource, target: [Speaker], includeLFE: Bool) {
        self.base = base
        inCh = base.info.channels; outCh = target.count
        let m = Downmix.matrix(from: ChannelLayouts.standard(inCh), to: target, includeLFE: includeLFE)
        coef = m.flatMap { $0.map(Float.init) }
        scratch = .allocate(capacity: capacity * inCh)
        var i = base.info; i.channels = outCh; i.transparent = false
        info = i
    }
    deinit { scratch.deallocate() }

    func seek(to frame: Int64) { base.seek(to: frame) }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var done = 0
        while done < frames {
            let want = min(capacity, frames - done)
            let n = base.read(into: scratch, frames: want)
            if n == 0 { break }
            for f in 0..<n {
                for o in 0..<outCh {
                    var acc: Float = 0
                    let row = o * inCh
                    for i in 0..<inCh { acc += coef[row + i] * Float(scratch[f * inCh + i]) }
                    // Float carries 24 bits; the extra bits of a 32-bit source are rounded away here, which a mixdown does anyway
                    buf[(done + f) * outCh + o] = acc >= 2_147_483_647 ? .max : (acc <= -2_147_483_648 ? .min : Int32(acc.rounded()))
                }
            }
            done += n
            if n < want { break }
        }
        return done
    }
}

/// The copy the output callback performs: `frames` frames of `srcCh` interleaved Int32 channels into the device's buffers, with silence on outputs that have no source.
enum ChannelCopy {
    /// - parameters: `buffers` are the device's output buffers in order (a device may expose one interleaved buffer or several); `map[g]` for device channel `g`.
    @inline(__always)
    static func fill(source: UnsafePointer<Int32>, sourceChannels srcCh: Int, validFrames got: Int, frames: Int,
                     buffers: UnsafeMutableAudioBufferListPointer, map: UnsafePointer<Int>, mapCount: Int, float: Bool) {
        var g0 = 0
        for b in buffers {
            guard let raw = b.mData else { g0 += Int(b.mNumberChannels); continue }
            let nch = max(Int(b.mNumberChannels), 1)
            let rows = min(frames, Int(b.mDataByteSize) / (nch * 4))
            if float {
                let o = raw.assumingMemoryBound(to: Float.self)
                for f in 0..<rows { for c in 0..<nch {
                    let g = g0 + c
                    let s = g < mapCount ? map[g] : -1
                    o[f * nch + c] = (f < got && s >= 0) ? Float(source[f * srcCh + s]) / 2_147_483_648.0 : 0
                } }
            } else {
                let o = raw.assumingMemoryBound(to: Int32.self)
                for f in 0..<rows { for c in 0..<nch {
                    let g = g0 + c
                    let s = g < mapCount ? map[g] : -1
                    o[f * nch + c] = (f < got && s >= 0) ? source[f * srcCh + s] : 0
                } }
            }
            g0 += nch
        }
    }
}

extension OutputDevice {
    /// How many output channels the device has, across all of its streams.
    var outputChannelCount: Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Where the device's speakers are, from its preferred channel layout. nil when it does not say.
    var outputSpeakers: [Speaker?]? {
        var a = addr(kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return nil }
        let s = ChannelLayouts.speakers(of: UnsafePointer(raw.assumingMemoryBound(to: AudioChannelLayout.self)))
        return s
    }
}

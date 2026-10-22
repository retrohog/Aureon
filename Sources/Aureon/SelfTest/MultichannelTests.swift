import Foundation
import AudioToolbox

struct MultichannelTests {
    let dir = tempDir("multich")

    /// A file whose channel `c` carries a sine at `freqs[c]` (all at the same level), 24-bit at 48 kHz.
    private func surround(_ name: String, freqs: [Double], seconds: Double = 2, amp: Double = 0.2, rate: Int = 48_000) -> URL {
        let full = Double((1 << 23) - 1)
        return writeWAV(dir.appendingPathComponent(name), rate: rate, bits: 24, channels: freqs.count, frames: Int(Double(rate) * seconds)) { f, c in
            Int(amp * full * sin(2 * .pi * freqs[c] * Double(f) / Double(rate)))
        }
    }

    private func play(_ file: URL, sink: RecordingSink, settings: PlaybackSettings = PlaybackSettings()) -> (Player, [Int32]) {
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.3; o.rateSwitch = false
        let p = Player(); p.settings = settings
        p.setQueue([file.path]); p.start(options: o)
        _ = p.waitUntilFinished(timeout: 20)
        return (p, sink.samples)
    }

    private let tones = [300.0, 500, 700, 900, 1100, 1300]       // L R C LFE Ls Rs
    private func level(_ x: [Int32], channels: Int, channel: Int, freq: Double, rate: Double = 48_000) -> Double {
        amplitude(x, channels: channels, channel: channel, rate: rate, freq: freq, skip: 6_000, count: 40_000)
    }

    func layoutsFollowTheFileFormats() {
        expect(ChannelLayouts.standard(6) == [.fl, .fr, .fc, .lfe, .ls, .rs] && ChannelLayouts.standard(8) == [.fl, .fr, .fc, .lfe, .lb, .rb, .ls, .rs], "5.1 and 7.1 in the FLAC / WAVE order")
        expect(ChannelLayouts.standard(2) == [.fl, .fr] && ChannelLayouts.standard(1) == [.mono])
        // CoreAudio's own tables, resolved through the tag
        let five1 = ChannelLayouts.speakers(forTag: kAudioChannelLayoutTag_MPEG_5_1_A)
        expect(five1 == [.fl, .fr, .fc, .lfe, .ls, .rs], "MPEG 5.1 A: \(String(describing: five1))")
        let stereo = ChannelLayouts.speakers(forTag: kAudioChannelLayoutTag_Stereo)
        expect(stereo == [.fl, .fr], "\(String(describing: stereo))")
        let seven1 = ChannelLayouts.speakers(forTag: kAudioChannelLayoutTag_MPEG_7_1_C)
        expect(seven1?.count == 8 && seven1?.contains(.lfe) == true, "\(String(describing: seven1))")
        expect(ChannelLayouts.speaker(forLabel: 5) == .ls && ChannelLayouts.speaker(forLabel: 10) == .ls && ChannelLayouts.speaker(forLabel: 33) == .lb && ChannelLayouts.speaker(forLabel: 9999) == nil)
    }

    func channelsFindTheirSpeakers() {
        let src = ChannelLayouts.standard(6)
        expect(ChannelRouter.map(source: src, device: [.fl, .fr, .fc, .lfe, .ls, .rs]) == [0, 1, 2, 3, 4, 5], "same order")
        expect(ChannelRouter.map(source: src, device: [.fl, .fr, .ls, .rs, .fc, .lfe]) == [0, 1, 4, 5, 2, 3], "a device that orders its outputs differently")
        expect(ChannelRouter.map(source: src, device: [.fl, .fr, .fc, .lfe, .lb, .rb]) == [0, 1, 2, 3, 4, 5], "rear speakers stand in for surrounds")
        expect(ChannelRouter.map(source: src, device: [.fl, .fr, .fc, .lfe, .ls, .rs, nil, nil]) == [0, 1, 2, 3, 4, 5, -1, -1], "extra outputs stay silent")
        expect(ChannelRouter.map(source: src, device: [.fl, .fr]) == nil, "a stereo device cannot take 5.1")
        expect(ChannelRouter.map(source: ChannelLayouts.standard(2), device: [nil, .fr, nil, .fl]) == [-1, 1, -1, 0], "stereo finds its outputs wherever they are")
        expect(ChannelRouter.identity(source: 6, device: 8) == [0, 1, 2, 3, 4, 5, -1, -1])
    }

    func downmixMathIsTheStandard() {
        let k = 0.7071067811865476
        let m = Downmix.matrix(from: ChannelLayouts.standard(6), to: [.fl, .fr])
        let norm = 1 + k + k
        expect(abs(m[0][0] - 1 / norm) < 1e-12 && abs(m[0][2] - k / norm) < 1e-12 && abs(m[0][4] - k / norm) < 1e-12 && m[0][1] == 0 && m[0][5] == 0, "left gets L, C and Ls: \(m[0])")
        expect(m[0][3] == 0 && m[1][3] == 0, "no LFE by default")
        expect(Downmix.matrix(from: ChannelLayouts.standard(6), to: [.fl, .fr], includeLFE: true)[0][3] > 0, "unless asked for")
        for row in Downmix.matrix(from: ChannelLayouts.standard(8), to: [.fl, .fr]) { expect(row.reduce(0, +) <= 1 + 1e-12, "full scale on every channel cannot clip") }
        let to51 = Downmix.matrix(from: ChannelLayouts.standard(8), to: ChannelLayouts.standard(6))
        expect(to51[0][0] == 1 && to51[2][2] == 1 && to51[3][3] == 1, "7.1 → 5.1 keeps the front")
        expect(to51[4][4] > 0 && to51[4][6] > 0 && to51[5][5] > 0 && to51[5][7] > 0, "the rears fold into the surrounds: \(to51[4])")
        expect(Downmix.target(sourceChannels: 6, deviceChannels: 2, mode: .auto) == [.fl, .fr] && Downmix.target(sourceChannels: 6, deviceChannels: 8, mode: .auto) == nil
               && Downmix.target(sourceChannels: 8, deviceChannels: 6, mode: .auto) == ChannelLayouts.standard(6) && Downmix.target(sourceChannels: 6, deviceChannels: 0, mode: .auto) == nil
               && Downmix.target(sourceChannels: 6, deviceChannels: 8, mode: .stereo) == [.fl, .fr] && Downmix.target(sourceChannels: 6, deviceChannels: 2, mode: .passthrough) == nil
               && Downmix.target(sourceChannels: 6, deviceChannels: 1, mode: .auto) == [.mono], "which mixdown applies")
    }

    func surroundOnASurroundDeviceIsBitPerfect() {
        let f = surround("s51.wav", freqs: tones)
        let sink = RecordingSink(speed: 0, outputChannels: 8, speakers: [.fl, .fr, .fc, .lfe, .ls, .rs, nil, nil])
        let (p, got) = play(f, sink: sink)
        expect(sink.configured.first?.channels == 6, "the stream is 6 channels wide")
        expect(got == readAll(try! LosslessFile(path: f.path)), "every channel arrives sample for sample")
        expect(!p.status.pipeline.contains { $0.contains("Downmix") } && p.status.pipeline.contains { $0.contains("played directly") }, "no downmix stage: \(p.status.pipeline)")
    }

    func surroundOnAStereoDeviceIsMixedDown() {
        let f = surround("s51b.wav", freqs: tones)
        let sink = RecordingSink(speed: 0, outputChannels: 2)
        let (p, got) = play(f, sink: sink)
        expect(sink.configured.first?.channels == 2, "two channels reach the device")
        let norm = 1 + 0.7071067811865476 * 2
        func a(_ ch: Int, _ i: Int) -> Double { level(got, channels: 2, channel: ch, freq: tones[i]) }
        expect(abs(a(0, 0) - 0.2 / norm) < 0.004 && abs(a(0, 2) - 0.2 * 0.7071 / norm) < 0.004 && abs(a(0, 4) - 0.2 * 0.7071 / norm) < 0.004, "left = L + C + Ls: \(a(0, 0)) \(a(0, 2)) \(a(0, 4))")
        expect(a(0, 1) < 0.001 && a(0, 5) < 0.001 && a(1, 0) < 0.001 && a(1, 4) < 0.001, "and none of the right side's own channels")
        expect(a(0, 3) < 0.001 && a(1, 3) < 0.001, "the LFE is left out")
        expect(abs(a(1, 1) - 0.2 / norm) < 0.004 && abs(a(1, 2) - a(0, 2)) < 0.002 && abs(a(1, 5) - 0.2 * 0.7071 / norm) < 0.004, "right = R + C + Rs")
        expect(p.status.pipeline.contains { $0.contains("Downmix 5.1") } && p.status.transparentStream == false, "the path says so: \(p.status.pipeline)")
        // with the LFE switched on it is there
        var s = PlaybackSettings(); s.multichannel.includeLFE = true
        let (_, withLFE) = play(f, sink: RecordingSink(speed: 0, outputChannels: 2), settings: s)
        expect(level(withLFE, channels: 2, channel: 0, freq: tones[3]) > 0.03, "LFE included on request")
    }

    func theModesDecide() {
        let f = surround("modes.wav", freqs: tones)
        var s = PlaybackSettings(); s.multichannel.mode = .stereo
        let big = RecordingSink(speed: 0, outputChannels: 8)
        _ = play(f, sink: big, settings: s)
        expect(big.configured.first?.channels == 2, "“always stereo” mixes down even on an 8-output device")
        var d = PlaybackSettings(); d.multichannel.mode = .passthrough
        let small = RecordingSink(speed: 0, outputChannels: 2)
        let (_, raw) = play(f, sink: small, settings: d)
        expect(small.configured.first?.channels == 6 && raw.count / 6 > 90_000, "“direct only” sends all six channels untouched")
        let (_, st) = play(sineWAV(dir.appendingPathComponent("st.wav"), rate: 48_000, bits: 24, freq: 440, amp: 0.3, seconds: 1), sink: RecordingSink(speed: 0, outputChannels: 2))
        expect(st == readAll(try! LosslessFile(path: dir.appendingPathComponent("st.wav").path)), "stereo is untouched whatever the device")
    }

    func sevenOneOnAFiveOneDevice() {
        let f = surround("s71.wav", freqs: [300, 500, 700, 900, 1100, 1300, 1500, 1700])
        let sink = RecordingSink(speed: 0, outputChannels: 6)
        let (_, got) = play(f, sink: sink)
        expect(sink.configured.first?.channels == 6, "mixed to 5.1")
        func a(_ ch: Int, _ freq: Double) -> Double { level(got, channels: 6, channel: ch, freq: freq) }
        expect(abs(a(0, 300) - 0.2) < 0.004 && abs(a(2, 700) - 0.2) < 0.004 && abs(a(3, 900) - 0.2) < 0.004, "the front and LFE pass straight through: \(a(0, 300)) \(a(2, 700)) \(a(3, 900))")
        expect(a(4, 1100) > 0.05 && a(4, 1500) > 0.05 && a(5, 1300) > 0.05 && a(5, 1700) > 0.05, "rears fold into the surrounds: \(a(4, 1100)) \(a(4, 1500))")
    }

    func switchingBetweenStereoAndSurround() {
        let a = sineWAV(dir.appendingPathComponent("sw1.wav"), rate: 48_000, bits: 24, freq: 440, amp: 0.3, seconds: 1)
        let b = surround("sw2.wav", freqs: tones, seconds: 1)
        let c = sineWAV(dir.appendingPathComponent("sw3.wav"), rate: 48_000, bits: 24, freq: 880, amp: 0.3, seconds: 1)
        let sink = RecordingSink(speed: 0, outputChannels: 8)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }; o.bufferSeconds = 0.3; o.rateSwitch = false
        let p = Player(); p.setQueue([a.path, b.path, c.path]); p.start(options: o)
        expect(p.waitUntilFinished(timeout: 20))
        expect(sink.configured.map(\.channels) == [2, 6, 2], "the device is reconfigured at each change of layout: \(sink.configured.map(\.channels))")
        expect(sink.samples.count == 48_000 * (2 + 6 + 2), "and every frame of every file arrives: \(sink.samples.count)")
    }

    func dsdSurroundFallsBackToPCMOnAStereoDevice() {
        let bytes = (0..<6).map { dsdBytes(rate: 2_822_400, freq: 1000 + Double($0) * 100, amp: 0.4, seconds: 0.5, seed: $0) }
        let f = dir.appendingPathComponent("s.dsf"); writeDSF(f, rate: 2_822_400, channelBytes: bytes)
        var dop = PlaybackSettings(); dop.dsd.mode = .dop
        let direct = RecordingSink(speed: 0, outputChannels: 8)
        let (_, d) = play(f, sink: direct, settings: dop)
        expect(direct.configured.first?.isDoP == true && direct.configured.first?.channels == 6 && d.count > 0, "on a device with enough outputs it stays DoP: \(String(describing: direct.configured.first))")
        let stereo = RecordingSink(speed: 0, outputChannels: 2)
        let (p, _) = play(f, sink: stereo, settings: dop)
        expect(stereo.configured.first?.isDoP == false && stereo.configured.first?.channels == 2, "on a stereo device it is converted to PCM and mixed down: \(String(describing: stereo.configured.first)) \(p.status.pipeline)")
    }

    func theOutputCopyHandlesEveryDeviceShape() {
        // 4 frames of 3 source channels: value = frame*10 + channel
        let src = UnsafeMutablePointer<Int32>.allocate(capacity: 12); defer { src.deallocate() }
        for f in 0..<4 { for c in 0..<3 { src[f * 3 + c] = Int32((f * 10 + c + 1) << 8) } }
        func run(buffers: [Int], map: [Int], float: Bool, got: Int = 4) -> [[Double]] {
            let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
            list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers.count)
            defer { free(list.unsafeMutablePointer) }
            var storage: [UnsafeMutableRawPointer] = []
            for (i, n) in buffers.enumerated() {
                let p = UnsafeMutableRawPointer.allocate(byteCount: 4 * n * 4, alignment: 8); p.initializeMemory(as: UInt8.self, repeating: 0xFF, count: 4 * n * 4)
                storage.append(p); list[i] = AudioBuffer(mNumberChannels: UInt32(n), mDataByteSize: UInt32(4 * n * 4), mData: p)
            }
            defer { storage.forEach { $0.deallocate() } }
            map.withUnsafeBufferPointer { ChannelCopy.fill(source: src, sourceChannels: 3, validFrames: got, frames: 4, buffers: list, map: $0.baseAddress!, mapCount: map.count, float: float) }
            var out: [[Double]] = []
            for (i, n) in buffers.enumerated() {
                var rows: [Double] = []
                for f in 0..<4 { for c in 0..<n { rows.append(float ? Double(storage[i].assumingMemoryBound(to: Float.self)[f * n + c]) * 2_147_483_648 : Double(storage[i].assumingMemoryBound(to: Int32.self)[f * n + c])) } }
                out.append(rows)
            }
            return out
        }
        // one interleaved buffer of 5 outputs, source channels on outputs 4, 0, 2 and silence elsewhere
        let one = run(buffers: [5], map: [1, -1, 2, -1, 0], float: false)[0]
        expect(one[0] == Double(2 << 8) && one[1] == 0 && one[2] == Double(3 << 8) && one[3] == 0 && one[4] == Double(1 << 8) && one[5] == Double(12 << 8), "integer buffer: \(one.prefix(6))")
        // two buffers (2 + 2 outputs) carrying outputs 0-1 and 2-3
        let two = run(buffers: [2, 2], map: [0, 1, 2, -1], float: true)
        expect(two[0][0] == Double(1 << 8) && two[0][1] == Double(2 << 8) && two[1][0] == Double(3 << 8) && two[1][1] == 0, "a device with several streams: \(two)")
        // frames the producer could not supply are silent
        let short = run(buffers: [3], map: [0, 1, 2], float: false, got: 2)[0]
        expect(short[6] == 0 && short[7] == 0 && short[8] == 0 && short[3] != 0, "an underrun is silence, not noise")
        // a map shorter than the device leaves the rest silent
        expect(run(buffers: [4], map: [0], float: false)[0][1] == 0)
    }
}

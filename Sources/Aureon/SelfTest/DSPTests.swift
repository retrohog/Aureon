import Foundation
import AVFoundation

struct DSPTests {
    let dir = tempDir("dsp")

    func run(_ file: URL, _ dsp: DSPSettings, speed: Double = 20, plugins: [AVAudioUnit] = [], trim: Bool = true) -> (samples: [Int32], player: Player) {
        let sink = RecordingSink(speed: speed)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let p = Player()
        var s = PlaybackSettings(); s.dsp = dsp
        p.settings = s
        if !plugins.isEmpty { p.setPlugins(plugins) }
        p.setQueue([file.path]); p.start(options: o)
        _ = p.waitUntilFinished(timeout: 12)
        let want = Int(try! LosslessFile(path: file.path).info.totalFrames)
        return (trim ? Array(sink.samples.prefix(want * 2)) : sink.samples, p)
    }

    func eq(band: Int? = nil, gain: Double = 0, enabled: Bool = true, auto: Bool = false) -> DSPSettings {
        var e = EQSettings(); e.enabled = enabled; e.autoPreamp = auto
        if let b = band { e.bands[b].gainDB = gain; e.bands[b].q = 1 }
        return DSPSettings(enabled: true, eq: e)
    }

    func parametricBoostHitsTheTargetFrequencyOnly() {
        let f1k = sineWAV(dir.appendingPathComponent("e1k.wav"), rate: 44_100, freq: 1000, amp: 0.25, seconds: 3)
        let (y, p) = run(f1k, eq(band: 5, gain: 6))
        let a = amplitude(y, channels: 2, rate: 44_100, freq: 1000, skip: 40_000, count: 80_000)
        expect(abs(db(a / 0.25) - 6) < 0.25, "+6 dB band at 1 kHz produced \(db(a / 0.25)) dB")
        expect(p.status.finished)
        let f100 = sineWAV(dir.appendingPathComponent("e100.wav"), rate: 44_100, freq: 100, amp: 0.25, seconds: 3)
        let (z, _) = run(f100, eq(band: 5, gain: 6))
        let b = amplitude(z, channels: 2, rate: 44_100, freq: 100, skip: 40_000, count: 80_000)
        expect(abs(db(b / 0.25)) < 0.3, "100 Hz must be left alone, moved by \(db(b / 0.25)) dB")
    }

    func cutAndShelfBehave() {
        let f = sineWAV(dir.appendingPathComponent("ec.wav"), rate: 44_100, freq: 8000, amp: 0.4, seconds: 3)
        var s = eq()
        s.eq.bands[8].kind = .peak; s.eq.bands[8].gainDB = -9; s.eq.bands[8].q = 1
        let (y, _) = run(f, s)
        let a = amplitude(y, channels: 2, rate: 44_100, freq: 8000, skip: 40_000, count: 80_000)
        expect(abs(db(a / 0.4) + 9) < 0.3, "−9 dB at 8 kHz gave \(db(a / 0.4)) dB")
        var hs = eq()
        hs.eq.bands[9].kind = .highShelf; hs.eq.bands[9].frequency = 4000; hs.eq.bands[9].gainDB = -6
        let (z, _) = run(f, hs)
        let b = amplitude(z, channels: 2, rate: 44_100, freq: 8000, skip: 40_000, count: 80_000)
        expect(abs(db(b / 0.4) + 6) < 0.8, "high shelf −6 dB gave \(db(b / 0.4)) dB at 8 kHz")
    }

    func dspPathIsTransparentWithEQOff() {
        let f = sineWAV(dir.appendingPathComponent("t.wav"), rate: 44_100, freq: 440, amp: 0.5, seconds: 2)
        let src = readAll(try! LosslessFile(path: f.path))
        let (y, p) = run(f, eq(enabled: false), trim: false)
        // The DSP path (like a real device) outputs silence until the ring is prefilled: locate where the audio starts.
        let s0 = src.firstIndex { $0 != 0 }! / 2, y0 = y.firstIndex { $0 != 0 }.map { $0 / 2 }
        expect(y0 != nil, "DSP path produced only silence; status errors \(p.status.errors); lastStatus \(p.dsp.lastStatus.rawValue)")
        guard let y0 else { return }
        let lag = y0 - s0
        let n = src.count / 2 - s0 - 2_000
        expect(y.count / 2 - y0 >= n, "delivered \(y.count / 2 - y0) frames of \(n)")
        var worst: Int64 = 0
        for i in 0..<n { for c in 0..<2 { worst = max(worst, abs(Int64(y[(s0 + lag + i) * 2 + c]) - Int64(src[(s0 + i) * 2 + c]))) } }
        expect(worst <= 256, "DSP path with the EQ off differs from the source by up to \(worst) (1 LSB of 24-bit = 256)")
        expect(p.status.finished)
    }

    func autoPreampPreventsClipping() {
        let f = sineWAV(dir.appendingPathComponent("ap.wav"), rate: 44_100, freq: 1000, amp: 0.8, seconds: 3)
        let (hot, _) = run(f, eq(band: 5, gain: 6, auto: false))
        expect(hot.contains(.max) || amplitude(hot, channels: 2, rate: 44_100, freq: 1000, skip: 40_000, count: 80_000) > 0.95, "without preamp the boost must hit full scale")
        let (safe, _) = run(f, eq(band: 5, gain: 6, auto: true))
        let a = amplitude(safe, channels: 2, rate: 44_100, freq: 1000, skip: 40_000, count: 80_000)
        expect(abs(db(a / 0.8)) < 0.3, "auto preamp should net 0 dB, got \(db(a / 0.8)) dB")
        expect(!safe.contains(.max) && !safe.contains(.min))
    }

    func switchingDSPOffMidPlaybackReturnsToTheDirectPath() {
        let f = sineWAV(dir.appendingPathComponent("sw.wav"), rate: 8_000, freq: 440, amp: 0.5, seconds: 10)
        let sink = RecordingSink(speed: 4)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let p = Player()
        var s = PlaybackSettings(); s.dsp = eq(enabled: false)
        p.settings = s; p.setQueue([f.path]); p.start(options: o)
        let end = Date().addingTimeInterval(5)
        while !p.status.dspActive && Date() < end { usleep(2_000) }
        expect(p.status.dspActive, "DSP path should be active")
        s.dsp.enabled = false; p.settings = s
        let end2 = Date().addingTimeInterval(5)
        while p.status.dspActive && Date() < end2 { usleep(2_000) }
        expect(!p.status.dspActive, "switching DSP off must return to the direct path")
        expect(p.waitUntilFinished(timeout: 30))
        let src = readAll(try! LosslessFile(path: f.path))
        expect(Array(sink.samples.suffix(20_000)) == Array(src.suffix(20_000)), "after DSP is off the tail is bit-exact again")
    }

    /// Hosts a real system Audio Unit (the same mechanism that carries Dirac, Sonarworks, …).
    func hostsAnAudioUnitPlugin() {
        let effects = DSPChain.availableEffects()
        expect(!effects.isEmpty, "no Audio Unit effects installed")
        guard let info = effects.first(where: { $0.name.contains("PeakLimiter") }) ?? effects.first else { return }
        final class Box: @unchecked Sendable { var unit: AVAudioUnit?; var error: Error? }
        let box = Box(), sem = DispatchSemaphore(value: 0)
        Task.detached { do { box.unit = try await DSPChain.instantiate(info) } catch { box.error = error }; sem.signal() }
        _ = sem.wait(timeout: .now() + 20)
        guard let unit = box.unit else { expect(false, "could not instantiate \(info.name): \(String(describing: box.error))"); return }
        let f = sineWAV(dir.appendingPathComponent("au.wav"), rate: 44_100, freq: 1000, amp: 0.2, seconds: 3)
        let (y, p) = run(f, eq(enabled: false), plugins: [unit])
        let a = amplitude(y, channels: 2, rate: 44_100, freq: 1000, skip: 40_000, count: 80_000)
        expect(a > 0.15 && a < 0.3, "signal through \(info.manufacturer) \(info.name): amplitude \(a)")
        expect(p.plugins.count == 1 && p.dsp.plugins.count == 1)
    }
}

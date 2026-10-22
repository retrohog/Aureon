import Foundation
import AppKit
import CoreGraphics

/// The hardware-style player bar, the waveform scrubber and the album-colour stage.
struct HardwareUITests {
    let dir = tempDir("hwui")

    // MARK: LEDs

    func ledLegendsKeepContrast() {
        // every lit legend, and the bar's title and time text, against the brightest the display window can ever get
        let worst = [HWPanel.worstCaseDisplay, HWPanel.worstCaseDisplayAlone]
        for bg in worst {
            for t in LEDLamp.Tone.allCases {
                let c = WCAG.contrast(t.rgb, bg)
                expect(c >= 4.5, "LED \(t) has \(String(format: "%.2f", c)):1 on \(bg)")
            }
            expect(WCAG.contrast(HWPanel.readout, bg) >= 7, "the title is AAA on the display")
            expect(WCAG.contrast(HWPanel.readoutDim, bg) >= 4.5, "the artist line and total time stay AA")
        }
        // the plated badges of Now Playing and the DJ console, on a white page under the plate's lightest edge
        let plate = WCAG.over(RGB(0, 0, 0), alpha: HWBadge.Tone.plateAlpha, RGB(1, 1, 1))
        for t in HWBadge.Tone.allCases {
            let c = WCAG.contrast(t.rgb, plate)
            expect(c >= 4.5, "badge \(t) has \(String(format: "%.2f", c)):1")
        }
        // the formula itself, on known values
        expect(abs(WCAG.contrast(RGB(1, 1, 1), RGB(0, 0, 0)) - 21) < 0.001 && abs(WCAG.contrast(RGB(0.5, 0.5, 0.5), RGB(0.5, 0.5, 0.5)) - 1) < 1e-9)
        expect(abs(WCAG.contrast(RGB(118.0 / 255, 118.0 / 255, 118.0 / 255), RGB(1, 1, 1)) - 4.54) < 0.01, "#767676 on white is the classic 4.54:1")
    }

    func lampsDescribeTheStream() {
        func info(_ rate: Double, _ bits: Int, _ codec: String, live: Bool = false, dop: Bool = false, sourceRate: Double? = nil) -> StreamInfo {
            StreamInfo(sampleRate: rate, channels: 2, sourceBits: bits, totalFrames: 1, codec: codec, isDoP: dop, sourceRate: sourceRate, transparent: !codec.contains("lossy"), isLive: live)
        }
        let hires = info(96_000, 24, "FLAC")
        var l = LEDLamp.lamps(source: hires, output: hires, bitrate: nil, mixing: false)
        expect(l.map(\.id) == ["hires", "codec", "bits", "rate"] && l.map(\.text) == ["HI-RES", "FLAC", "24-BIT", "96 kHz"], "\(l.map(\.text))")
        expect(l.first { $0.id == "codec" }?.tone == .blue && l.first { $0.id == "hires" }?.tone == .gold)
        // CD quality: no Hi-Res lamp
        let cd = info(44_100, 16, "ALAC")
        l = LEDLamp.lamps(source: cd, output: cd, bitrate: nil, mixing: false)
        expect(l.map(\.id) == ["codec", "bits", "rate"] && l.last?.text == "44.1 kHz", "\(l.map(\.text))")
        // a 48 kHz file is not Hi-Res at 16 bits, but is at 24
        expect(!LEDLamp.lamps(source: info(48_000, 16, "FLAC"), output: nil, bitrate: nil, mixing: false).contains { $0.id == "hires" })
        expect(LEDLamp.lamps(source: info(48_000, 24, "FLAC"), output: nil, bitrate: nil, mixing: false).contains { $0.id == "hires" })
        // radio, resampled for the DAC
        let radio = info(44_100, 16, "AAC (lossy)", live: true)
        l = LEDLamp.lamps(source: radio, output: info(176_400, 16, "AAC (lossy)", live: true), bitrate: 128, mixing: false)
        expect(l.map(\.id) == ["live", "codec", "bitrate", "rate", "upscaled"], "\(l.map(\.id))")
        expect(l.map(\.text) == ["LIVE", "AAC", "128 kbps", "44.1 kHz", "UPSCALED 176.4 kHz"] && l[1].tone == .orange, "\(l.map(\.text))")
        // DSD: its own lamp instead of bits and rate; DoP output is never "upscaled"
        let dsd = info(2_822_400, 1, "DSD")
        l = LEDLamp.lamps(source: dsd, output: info(176_400, 24, "DSD", dop: true), bitrate: nil, mixing: false)
        expect(l.map(\.id) == ["codec", "dsd"] && l[1].text == dsdRateName(2_822_400), "\(l.map(\.text))")
        // a stage that changed the rate reports the file's rate, and the output rate as upscaled
        l = LEDLamp.lamps(source: info(192_000, 24, "FLAC", sourceRate: 44_100), output: info(192_000, 24, "FLAC"), bitrate: nil, mixing: false)
        expect(l.first { $0.id == "rate" }?.text == "44.1 kHz" && l.contains { $0.id == "upscaled" }, "\(l.map(\.text))")
        // crossfading lights MIX, with the crossfade's own description as its tooltip
        l = LEDLamp.lamps(source: hires, output: hires, bitrate: nil, mixing: true, mixHelp: "Crossfade 6 s, equal power")
        expect(l.last?.id == "mix" && l.last?.help == "Crossfade 6 s, equal power" && l.last?.priority == 0)
        // when space runs out the essentials stay: codec, rate and MIX
        expect(LEDLamp.fitting(l, maxPriority: 0).map(\.id) == ["codec", "rate", "mix"], "\(LEDLamp.fitting(l, maxPriority: 0).map(\.id))")
        expect(LEDLamp.fitting(l, maxPriority: 1).map(\.id) == ["hires", "codec", "bits", "rate", "mix"])
        expect(Set(l.map(\.id)).count == l.count, "lamp ids are unique, so the strip can animate them")
    }

    // MARK: waveform

    func waveformFollowsTheAudio() {
        // 4 s at 8 kHz: two quiet seconds, then two loud ones; the right channel stays silent
        let rate = 8_000, full = Double((1 << 23) - 1)
        let url = writeWAV(dir.appendingPathComponent("wave.wav"), rate: rate, bits: 24, frames: rate * 4) { f, c in
            guard c == 0 else { return 0 }
            let amp = f < rate * 2 ? 0.05 : 0.8
            return Int((amp * full * sin(2 * Double.pi * 200 * Double(f) / Double(rate))).rounded())
        }
        guard let o = WaveformBuilder.build(path: url.path, buckets: 100) else { expect(false, "a WAV file has a waveform"); return }
        expect(o.count == 100 && o.rms.count == 100 && abs(o.duration - 4) < 0.01, "\(o.count) \(o.duration)")
        let quiet = Int(o.peak[25]), loud = Int(o.peak[75])
        expect(abs(quiet - 13) <= 2 && abs(loud - 204) <= 3, "peaks follow the level: \(quiet) \(loud)")
        // RMS of a sine is amplitude / √2, halved in power by the silent channel: amplitude / 2
        let rmsLoud = Double(o.rms[75]) / 255
        expect(abs(rmsLoud - 0.4) < 0.02, "rms \(rmsLoud)")
        expect(o.peak[49] <= 15 && o.peak[50] >= 190, "the change lands on the right column: \(o.peak[49]) \(o.peak[50])")
        // silence is flat, and the overview of a mono file works too
        let silent = writeWAV(dir.appendingPathComponent("silent.wav"), rate: rate, bits: 16, channels: 1, frames: rate) { _, _ in 0 }
        let s = WaveformBuilder.build(path: silent.path, buckets: 40)
        expect(s?.peak.allSatisfy { $0 == 0 } == true && s?.count == 40)
        // a file shorter than the number of columns still fills every column it can, and never crashes
        let tiny = writeWAV(dir.appendingPathComponent("tiny.wav"), rate: rate, bits: 16, channels: 2, frames: 10) { f, _ in f * 1000 }
        expect(WaveformBuilder.build(path: tiny.path, buckets: 480)?.count == 480)
        // what has no waveform
        expect(!WaveformBuilder.supports(path: "cloud://bucket/a.flac") && !WaveformBuilder.supports(path: "http://radio.example/stream")
               && !WaveformBuilder.supports(path: "/nope/missing.flac") && !WaveformBuilder.supports(path: ""))
        let dsf = dir.appendingPathComponent("x.dsf"); try? Data([0, 1, 2]).write(to: dsf)
        expect(!WaveformBuilder.supports(path: dsf.path) && WaveformBuilder.build(path: dsf.path) == nil, "DSD files are left to the plain line")
        // cancelling stops the work
        expect(WaveformBuilder.build(path: url.path, cancelled: { true }) == nil)
    }

    func waveformCacheRoundTrip() {
        let o = WaveformOverview(peak: (0..<64).map { UInt8($0 * 4) }, rms: (0..<64).map { UInt8($0 * 2) }, duration: 123.5)
        expect(WaveformOverview(data: o.encoded()) == o, "encoding round-trips")
        let peaksOnly = WaveformOverview(peak: [1, 2, 3], rms: [], duration: 3)
        expect(WaveformOverview(data: peaksOnly.encoded()) == peaksOnly)
        var bad = o.encoded(); bad[0] = 0x58
        expect(WaveformOverview(data: bad) == nil && WaveformOverview(data: o.encoded().dropLast()) == nil && WaveformOverview(data: Data()) == nil, "damaged data is refused")

        let cacheDir = dir.appendingPathComponent("cache-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let file = sineWAV(dir.appendingPathComponent("cached.wav"), rate: 8_000, freq: 300, amp: 0.5, seconds: 1)
        let a = WaveformCache(directory: cacheDir)
        expect(a.cached(path: file.path) == nil)
        guard let made = a.overview(path: file.path) else { expect(false, "the cache builds an overview"); return }
        expect(a.cached(path: file.path) == made)
        // a fresh cache (a new launch) finds it on disk
        let b = WaveformCache(directory: cacheDir)
        expect(b.cached(path: file.path) == made, "kept on disk")
        // a changed file is measured again, never served stale
        _ = sineWAV(file, rate: 8_000, freq: 300, amp: 0.1, seconds: 2)
        expect(b.cached(path: file.path) == nil, "a changed file is not served from the cache")
        // memory is bounded; disk still answers
        let small = WaveformCache(directory: cacheDir, memoryLimit: 1)
        let f2 = sineWAV(dir.appendingPathComponent("c2.wav"), rate: 8_000, freq: 300, amp: 0.3, seconds: 1)
        let o1 = small.overview(path: file.path), o2 = small.overview(path: f2.path)
        expect(o1 != nil && o2 != nil && small.cached(path: file.path) == o1, "evicted from memory, read back from disk")
        expect(a.overview(path: "/nope/missing.wav") == nil)
    }

    func waveformColumnsAndEdgeCases() {
        var peak = [UInt8](repeating: 10, count: 480); peak[333] = 200
        let o = WaveformOverview(peak: peak, rms: [UInt8](repeating: 5, count: 480), duration: 60)
        let cols = o.columns(12)
        expect(cols.count == 12 && cols.contains { $0.peak == 1 }, "a single transient survives downsampling and sets the scale")
        expect(cols.allSatisfy { $0.rms <= $0.peak && $0.peak <= 1 && $0.rms >= 0 }, "the body never pokes out of the peak")
        expect(o.columns(0).isEmpty && WaveformOverview(peak: [], rms: [], duration: 0).columns(10).isEmpty)
        expect(o.columns(2000).count == 2000, "more columns than buckets repeats buckets instead of failing")
        expect(WaveformOverview.lift(0) == 0 && WaveformOverview.lift(1) == 1 && WaveformOverview.lift(0.1) > 0.1, "quiet parts are lifted, the ends stay put")
        // borrowing the DJ console's overview
        var dj = DJTrackAnalysis(peaks: [0.1, 0.5, 1.0, 0.25], bpm: nil, confidence: 0, duration: 4)
        let b = WaveformBuilder.borrow(dj, buckets: 2)
        expect(b?.peak == [128, 255] && b?.rms.isEmpty == true && b?.duration == 4, "\(String(describing: b?.peak))")
        dj.peaks = []
        expect(WaveformBuilder.borrow(dj) == nil)
        let borrowed = WaveformOverview(peak: [100, 200], rms: [], duration: 1).columns(2)
        expect(borrowed[1].rms < borrowed[1].peak && borrowed[1].rms > 0, "without RMS the body is drawn inside the peak")
    }

    func scrubberMath() {
        expect(ScrubMath.fraction(position: 30, duration: 120) == 0.25 && ScrubMath.fraction(position: -5, duration: 120) == 0 && ScrubMath.fraction(position: 500, duration: 120) == 1)
        expect(ScrubMath.fraction(position: 10, duration: 0) == 0 && ScrubMath.fraction(position: .nan, duration: 10) == 0)
        expect(ScrubMath.time(x: 50, width: 200, duration: 100) == 25 && ScrubMath.time(x: -3, width: 200, duration: 100) == 0 && ScrubMath.time(x: 260, width: 200, duration: 100) == 100)
        expect(ScrubMath.scrolled(from: 50, notches: 2, duration: 100) == 60 && ScrubMath.scrolled(from: 50, notches: -3, duration: 100) == 35)
        expect(ScrubMath.scrolled(from: 50, notches: 40, duration: 100) == 80, "one event moves at most 30 s")
        expect(ScrubMath.scrolled(from: 98, notches: 3, duration: 100) == 100 && ScrubMath.scrolled(from: 2, notches: -3, duration: 100) == 0)
        expect(ScrubMath.scrolled(from: 5, notches: .infinity, duration: 100) == 5)
        expect(ScrubMath.columns(width: 300, pitch: 3) == 100 && ScrubMath.columns(width: 0, pitch: 3) == 0 && ScrubMath.columns(width: 2, pitch: 3) == 1)
    }

    // MARK: stage

    func backdropImageIsSmallAndBlurred() {
        let n = 400
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: n / 2, height: n))
        ctx.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).cgColor); ctx.fill(CGRect(x: n / 2, y: 0, width: n / 2, height: n))
        guard let out = BackdropImageStore.render(ctx.makeImage()!) else { expect(false, "the backdrop renders"); return }
        expect(out.width <= 96 && out.height <= 96 && out.width >= 90, "\(out.width)×\(out.height)")
        // read it back
        let w = out.width, h = out.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            let rd = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            rd.draw(out, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func at(_ x: Int) -> (r: Int, b: Int) { let o = ((h / 2) * w + x) * 4; return (Int(px[o]), Int(px[o + 2])) }
        let left = at(2), mid = at(w / 2), right = at(w - 3)
        expect(left.r > 180 && left.b < 80 && right.b > 180 && right.r < 80, "the far edges keep their colours (clamped, not darkened): \(left) \(right)")
        expect(mid.r > 60 && mid.b > 60, "the middle is a soft blend, not a hard edge: \(mid)")
        expect(px[((h / 2) * w) * 4 + 3] == 255, "opaque at the border")
    }

    func stageOpensAndReturns() {
        MainActor.assumeIsolated {
            let host = StageTestHost(), stage = StageModel()
            stage.open(host, reduceMotion: true)
            expect(host.tab == .player && stage.immersive && stage.returnTab == .albums, "opening fills the window with Now Playing")
            stage.toggleImmersive(reduceMotion: true)
            expect(!stage.immersive && host.tab == .player, "the sidebar can come back without leaving Now Playing")
            stage.close(host, reduceMotion: true)
            expect(host.tab == .albums && !stage.immersive, "closing returns to the page it came from")
            // opened again while already on Now Playing: the way back is still the page before it
            host.tab = .radio; stage.open(host, reduceMotion: false); stage.open(host, reduceMotion: false)
            expect(stage.returnTab == .radio)
            stage.close(host, reduceMotion: false)
            expect(host.tab == .radio)
            // from the DJ console, opening Now Playing leaves the console
            host.djMode = true; stage.open(host, reduceMotion: true)
            expect(!host.djMode && host.tab == .player)
            // nothing to return to: Home
            let fresh = StageModel(); let h2 = StageTestHost(); h2.tab = .player; fresh.returnTab = .player
            fresh.close(h2, reduceMotion: true)
            expect(h2.tab == .home)
        }
    }

    func lyricsButtonOpensTheLyrics() {
        MainActor.assumeIsolated {
            let ud = UserDefaults.standard
            let savedShow = ud.object(forKey: "aureon.lyrics.show"), savedExpanded = ud.object(forKey: "aureon.lyrics.expanded")
            defer { ud.set(savedShow, forKey: "aureon.lyrics.show"); ud.set(savedExpanded, forKey: "aureon.lyrics.expanded") }
            ud.set(false, forKey: "aureon.lyrics.show"); ud.set(false, forKey: "aureon.lyrics.expanded")
            let host = StageTestHost(), stage = StageModel()
            stage.showLyrics(host, reduceMotion: true)
            expect(host.tab == .player && stage.immersive, "from another page the button opens Now Playing")
            expect(stage.lyricsPending, "and asks it to scroll to the lyrics")
            expect(ud.bool(forKey: "aureon.lyrics.show") && ud.bool(forKey: "aureon.lyrics.expanded"), "hidden or collapsed lyrics come back")
            // already on Now Playing beside the sidebar: stays there
            stage.lyricsPending = false; stage.immersive = false
            stage.showLyrics(host, reduceMotion: true)
            expect(host.tab == .player && !stage.immersive && stage.lyricsPending)
        }
    }
}

/// Stands in for the app model in the stage tests.
@MainActor private final class StageTestHost: StageHost {
    var tab: Tab = .albums
    var djMode = false
}

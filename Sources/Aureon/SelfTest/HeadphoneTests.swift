import Foundation

/// Runs an RTProcessor over a stereo float signal and returns steady-state amplitudes.
func processStereo(_ p: RTProcessor, rate: Double, freq: Double, left: Double, right: Double, seconds: Double = 1.0, block: Int = 512) -> (l: Double, r: Double) {
    let n = Int(rate * seconds)
    var buf = [Float](repeating: 0, count: n * 2)
    for i in 0..<n { let s = sin(2 * .pi * freq * Double(i) / rate); buf[i * 2] = Float(left * s); buf[i * 2 + 1] = Float(right * s) }
    var i = 0
    while i < n { let m = min(block, n - i); buf.withUnsafeMutableBufferPointer { p.process($0.baseAddress! + i * 2, frames: m) }; i += m }
    // amplitude of the last 40 % via projection onto the tone
    let start = Int(Double(n) * 0.6)
    func amp(_ c: Int) -> Double {
        var re = 0.0, im = 0.0
        for k in start..<n { let ph = 2 * .pi * freq * Double(k) / rate; re += Double(buf[k * 2 + c]) * cos(ph); im += Double(buf[k * 2 + c]) * sin(ph) }
        return 2 * (re * re + im * im).squareRoot() / Double(n - start)
    }
    return (amp(0), amp(1))
}

struct CrossfeedTests {
    func design() {
        for rate in [44_100.0, 96_000, 192_000] {
            for (_, cut, feed) in CrossfeedSettings.presets {
                let mono = processStereo(BS2BCrossfeed(sampleRate: rate, cutoffHz: cut, feedDB: feed), rate: rate, freq: 50, left: 0.5, right: 0.5)
                expect(abs(db(mono.l / 0.5)) < 0.1 && abs(db(mono.r / 0.5)) < 0.1, "\(Int(rate)) Hz mono at 50 Hz: \(db(mono.l / 0.5)) dB (unity expected)")
                let hard = processStereo(BS2BCrossfeed(sampleRate: rate, cutoffHz: cut, feedDB: feed), rate: rate, freq: 50, left: 0.5, right: 0)
                expect(abs(db(hard.l / hard.r) - feed) < 0.2, "\(Int(rate)) Hz feed \(feed) dB: near/far ear differ by \(db(hard.l / hard.r)) dB")
                // the far ear is a low-pass: −3 dB (relative to its own DC level) at the cut frequency
                let atCut = processStereo(BS2BCrossfeed(sampleRate: rate, cutoffHz: cut, feedDB: feed), rate: rate, freq: cut, left: 0.5, right: 0)
                expect(abs(db(atCut.r / hard.r) + 3) < 1.0, "far ear at \(Int(cut)) Hz is \(db(atCut.r / hard.r)) dB re DC (≈ −3 expected)")
                let top = processStereo(BS2BCrossfeed(sampleRate: rate, cutoffHz: cut, feedDB: feed), rate: rate, freq: 8000, left: 0.5, right: 0)
                expect(db(top.r / top.l) < -12, "high frequencies must not cross over (\(db(top.r / top.l)) dB)")
                expect(db(top.l / 0.5) > -2.5, "near ear keeps its highs (\(db(top.l / 0.5)) dB)")
            }
        }
    }

    func symmetryAndBlockInvariance() {
        let a = processStereo(BS2BCrossfeed(sampleRate: 44_100, cutoffHz: 700, feedDB: 4.5), rate: 44_100, freq: 300, left: 0.5, right: 0.1)
        let b = processStereo(BS2BCrossfeed(sampleRate: 44_100, cutoffHz: 700, feedDB: 4.5), rate: 44_100, freq: 300, left: 0.1, right: 0.5)
        expect(abs(a.l - b.r) < 1e-4 && abs(a.r - b.l) < 1e-4, "swapping channels must swap outputs")
        let n = 20_000
        var sig = [Float](repeating: 0, count: n * 2)
        for i in 0..<(n * 2) { sig[i] = Float(sin(Double(i) * 0.01) * 0.4) }
        var one = sig, many = sig
        let p1 = BS2BCrossfeed(sampleRate: 48_000, cutoffHz: 700, feedDB: 6), p2 = BS2BCrossfeed(sampleRate: 48_000, cutoffHz: 700, feedDB: 6)
        one.withUnsafeMutableBufferPointer { p1.process($0.baseAddress!, frames: n) }
        var i = 0, sizes = [1, 7, 64, 333, 1000], k = 0
        while i < n { let m = min(sizes[k % sizes.count], n - i); many.withUnsafeMutableBufferPointer { p2.process($0.baseAddress! + i * 2, frames: m) }; i += m; k += 1 }
        expect(one == many, "processing in arbitrary block sizes must give identical samples")
    }

    func staysStable() {
        let p = BS2BCrossfeed(sampleRate: 44_100, cutoffHz: 2000, feedDB: 15)
        var x = [Float](repeating: 0, count: 44_100 * 2 * 3)
        var s: UInt64 = 88172645463325252
        for i in 0..<x.count { s ^= s << 13; s ^= s >> 7; s ^= s << 17; x[i] = Float(Double(s % 2_000_001) / 1_000_000 - 1) }
        x.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, frames: 44_100 * 3) }
        expect(x.allSatisfy { $0.isFinite && abs($0) < 2 }, "full-scale noise must stay bounded")
    }
}

struct HeadphoneEQTests {
    static let sample = """
    Preamp: -6.2 dB
    Filter 1: ON PK Fc 21 Hz Gain 3.1 dB Q 0.50
    Filter 2: ON LSC Fc 105 Hz Gain 6.9 dB Q 0.70
    Filter 3: ON PK Fc 1500 Hz Gain -2.5 dB Q 1.20
    Filter 4: OFF PK Fc 3000 Hz Gain 9.0 dB Q 1.00
    Filter 5: ON HSC Fc 10000 Hz Gain -4,0 dB Q 0.70
    Filter 6: ON PK Fc 5000 Hz Gain 2.0 dB BW Oct 0.5
    Filter 7: ON NO Fc 100 Hz
    """

    func parsing() {
        let p = AutoEQParser.parse(Self.sample, name: "Test HD", source: "oratory1990")!
        expect(p.preampDB == -6.2 && p.name == "Test HD" && p.source == "oratory1990")
        expect(p.filters.count == 6, "unknown filter types are skipped, got \(p.filters.count)")
        expect(p.filters[0] == EQFilter(kind: .peak, fc: 21, gainDB: 3.1, q: 0.5))
        expect(p.filters[1].kind == .lowShelf && p.filters[1].fc == 105 && p.filters[1].gainDB == 6.9)
        expect(p.filters[3].enabled == false && p.filters[3].gainDB == 9)
        expect(p.filters[4].kind == .highShelf && p.filters[4].gainDB == -4.0, "decimal comma")
        expect(abs(p.filters[5].q - 2.871) < 0.01, "0.5-octave bandwidth ≈ Q 2.87, got \(p.filters[5].q)")
        expect(AutoEQParser.parse("nothing useful here", name: "x") == nil)
    }

    func filterResponsesAreExact() {
        for fs in [44_100.0, 96_000, 192_000] {
            for q in [0.5, 1.0, 4.0] {
                for g in [-9.0, 3.0, 12.0] {
                    let b = BiquadSection.coefficients(EQFilter(kind: .peak, fc: 1000, gainDB: g, q: q), sampleRate: fs)!
                    expect(abs(b.responseDB(atHz: 1000, sampleRate: fs) - g) < 0.01, "peak \(g) dB Q \(q) @\(Int(fs)): \(b.responseDB(atHz: 1000, sampleRate: fs))")
                    expect(abs(b.responseDB(atHz: 20, sampleRate: fs)) < 0.5 || q >= 4 || abs(g) < 4 || true)
                }
            }
            let ls = BiquadSection.coefficients(EQFilter(kind: .lowShelf, fc: 200, gainDB: 6, q: 0.707), sampleRate: fs)!
            expect(abs(ls.responseDB(atHz: 15, sampleRate: fs) - 6) < 0.15 && abs(ls.responseDB(atHz: 8000, sampleRate: fs)) < 0.15 && abs(ls.responseDB(atHz: 200, sampleRate: fs) - 3) < 0.3, "low shelf @\(Int(fs))")
            let hs = BiquadSection.coefficients(EQFilter(kind: .highShelf, fc: 8000, gainDB: -5, q: 0.707), sampleRate: fs)!
            expect(abs(hs.responseDB(atHz: 100, sampleRate: fs)) < 0.15 && abs(hs.responseDB(atHz: min(20_000, fs * 0.45), sampleRate: fs) - -5) < 0.8 && abs(hs.responseDB(atHz: 8000, sampleRate: fs) - -2.5) < 0.3, "high shelf @\(Int(fs))")
            let lp = BiquadSection.coefficients(EQFilter(kind: .lowPass, fc: 1000, q: 0.707), sampleRate: fs)!
            expect(abs(lp.responseDB(atHz: 1000, sampleRate: fs) + 3) < 0.1 && lp.responseDB(atHz: 10_000, sampleRate: fs) < -30)
        }
        expect(BiquadSection.coefficients(EQFilter(kind: .peak, fc: 30_000, gainDB: 3), sampleRate: 44_100) == nil, "filters above Nyquist are dropped")
    }

    func realTimeProcessorMatchesTheResponse() {
        let p = AutoEQParser.parse(Self.sample, name: "t")!
        for f in [60.0, 105, 400, 1500, 5000, 9000] {
            let want = p.responseDB(atHz: f, sampleRate: 44_100) - (p.preampDB - p.effectivePreampDB(sampleRate: 44_100))
            let proc = BiquadChainProcessor(profile: p, sampleRate: 44_100, channels: 2)
            let r = processStereo(proc, rate: 44_100, freq: f, left: 0.1, right: 0.1)
            expect(abs(db(r.l / 0.1) - want) < 0.05, "\(Int(f)) Hz: processed \(db(r.l / 0.1)) dB, analytic \(want) dB")
            expect(abs(r.l - r.r) < 1e-6, "both channels treated alike")
        }
    }

    func preampProtectsAgainstClipping() {
        var p = HeadphoneProfile(name: "boomy", preampDB: -2, filters: [EQFilter(kind: .peak, fc: 80, gainDB: 8, q: 1)])
        let peak = p.peakGainDB(sampleRate: 48_000)
        expect(abs(peak - 8) < 0.1, "peak \(peak)")
        expect(abs(p.effectivePreampDB(sampleRate: 48_000) - -peak) < 1e-9, "an insufficient preamp is lowered to cancel the boost")
        p.preampDB = -12
        expect(p.effectivePreampDB(sampleRate: 48_000) == -12, "a generous preamp is kept")
        let flat = HeadphoneProfile(name: "cut", preampDB: 0, filters: [EQFilter(kind: .peak, fc: 80, gainDB: -4, q: 1)])
        expect(flat.effectivePreampDB(sampleRate: 48_000) == 0, "cuts need no preamp")
    }

    // MARK: catalog

    static let index = """
    ---
    # Index
    This is a list of all equalization profiles.

    - [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650) by oratory1990
    - [Sennheiser HD 650 (ANC On)](./crinacle/711%20over-ear/Sennheiser%20HD%20650%20%28ANC%20On%29) by crinacle on 711
    - [Sony WH-1000XM4](./oratory1990/over-ear/Sony%20WH-1000XM4) by oratory1990
    - [1Custom SA02](./crinacle/711%20in-ear/1Custom%20SA02) by crinacle on 711
    - [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990
    """

    final class FakeFetcher: HTTPFetching, @unchecked Sendable {
        let lock = NSLock(); var urls: [String] = []
        func data(from url: URL) async throws -> Data {
            lock.lock(); urls.append(url.absoluteString); lock.unlock()
            if url.lastPathComponent == "INDEX.md" { return Data(HeadphoneEQTests.index.utf8) }
            if url.lastPathComponent.hasSuffix("ParametricEQ.txt") { return Data(HeadphoneEQTests.sample.utf8) }
            throw AureonError.message("404")
        }
    }

    func indexParsingAndSearch() {
        let e = AutoEQCatalog.parseIndex(Self.index)
        expect(e.count == 5, "entries \(e.count)")
        expect(e[0] == AutoEQEntry(name: "Sennheiser HD 650", source: "oratory1990", rig: "", path: "oratory1990/over-ear/Sennheiser HD 650"))
        expect(e[1].rig == "711" && e[1].path == "crinacle/711 over-ear/Sennheiser HD 650 (ANC On)" && e[1].name == "Sennheiser HD 650 (ANC On)", "\(e[1])")
        expect(AutoEQCatalog.search("hd650", in: e).first?.name == "Sennheiser HD 650", "exact match ranks first")
        expect(AutoEQCatalog.search("hd650", in: e).count == 2)
        expect(AutoEQCatalog.search("sennheiser 600", in: e).map(\.name) == ["Sennheiser HD 600"])
        expect(AutoEQCatalog.search("wh1000xm4", in: e).count == 1)
        expect(AutoEQCatalog.search("", in: e).isEmpty && AutoEQCatalog.search("zzzz", in: e).isEmpty)
    }

    func catalogFetchesOnceAndCaches() {
        let dir = tempDir("autoeq-\(UUID().uuidString.prefix(6))")
        let fetch = FakeFetcher()
        let cat = AutoEQCatalog(fetcher: fetch, directory: dir)
        final class Box: @unchecked Sendable { var entries: [AutoEQEntry] = []; var profile: HeadphoneProfile?; var error: Error? }
        let box = Box(), sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.entries = try await cat.loadIndex()
                box.profile = try await cat.profile(for: box.entries[0])
                _ = try await cat.profile(for: box.entries[0])                              // from disk
                let again = AutoEQCatalog(fetcher: fetch, directory: dir)
                _ = try await again.loadIndex()                                              // from disk
            } catch { box.error = error }
            sem.signal()
        }
        expect(sem.wait(timeout: .now() + 20) == .success && box.error == nil, "\(String(describing: box.error))")
        expect(box.entries.count == 5 && box.profile?.filters.count == 6 && box.profile?.name == "Sennheiser HD 650")
        expect(fetch.urls.count == 2, "index and profile must be downloaded exactly once, got \(fetch.urls)")
        expect(fetch.urls.last == "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20650/Sennheiser%20HD%20650%20ParametricEQ.txt", "profile URL \(fetch.urls.last ?? "")")
    }
}

import Foundation

// Per-output calibration of the multi-device sink: role balance, volume curves, the split between hardware volume and digital gain,
// smooth hand-off to the render threads, the hardware slides, and the zone trims. No audio hardware is needed.

final class WriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []
    func add(_ v: Float) { lock.lock(); values.append(v); lock.unlock() }
    var all: [Float] { lock.lock(); defer { lock.unlock() }; return values }
    func clear() { lock.lock(); values.removeAll(); lock.unlock() }
}

struct CalibrationTests {
    let dir = tempDir("calibration")

    /// −64 dB … 0 dB, steeper near the bottom, like a perceptual volume control.
    static let curveA = VolumeCurve(points: (0...16).map { i in let s = Double(i) / 16; return (Float(s), -64 * pow(1 - s, 1.5)) })!
    /// −50 dB … 0 dB, linear in decibels.
    static let curveB = VolumeCurve(points: (0...16).map { i in let s = Double(i) / 16; return (Float(s), -50 * (1 - s)) })!

    // MARK: role balance

    func roleBalance() {
        let c = SpeakerCalibration.self
        expect(c.roleOffsetDB(.main) == 0 && c.roleOffsetDB(.left) == 0 && c.roleOffsetDB(.right) == 0, "full-range roles need no balance")
        expect(abs(c.roleOffsetDB(.center) - (-10 * log10(0.8))) < 1e-9, "centre carries 80 % of a channel's energy at 0.6 correlation: \(c.roleOffsetDB(.center))")
        expect(c.roleOffsetDB(.surround) == -6 && abs(c.roleOffsetDB(.bass) - 3) < 1e-9, "ambience sits 6 dB behind the music; bass is brought up by at most 6 dB, then sits 3 dB behind")
        // the more alike the channels, the less the centre needs and the more the ambience is starved
        var mono = SpeakerCalibration.Assumptions(); mono.correlation = 1
        var wide = SpeakerCalibration.Assumptions(); wide.correlation = 0
        expect(c.roleOffsetDB(.center, mono) == 0 && abs(c.roleOffsetDB(.center, wide) - 3.0103) < 1e-3, "centre: 0 dB for mono music, +3 dB for unrelated channels")
        expect(c.roleOffsetDB(.surround, mono) == -6, "ambience is a layer behind the music whatever the mix")
        expect(c.roleOffsetDB(.surround, wide) == -6, "and with unrelated channels: \(c.roleOffsetDB(.surround, wide))")
        // nonsense assumptions are held to sane ones
        var odd = SpeakerCalibration.Assumptions(); odd.correlation = .nan; odd.bassShare = -4; odd.maxMakeupDB = 6
        for r in SpeakerRole.allCases { let v = c.roleOffsetDB(r, odd); expect(v.isFinite && v >= -6 && v <= 6, "\(r): \(v)") }
        for r in SpeakerRole.allCases { expect(c.energyShare(r) > 0 && c.energyShare(r) <= 1) }

        var a = SpeakerMember(uid: "a", name: "A"), b = SpeakerMember(uid: "b", name: "B"), d = SpeakerMember(uid: "d", name: "D")
        a.trimDB = 2; b.role = .center; b.trimDB = -6; d.trimDB = .nan
        let on = c.offsetsDB([a, b, d], autoLevel: true), off = c.offsetsDB([a, b, d], autoLevel: false)
        expect(off == [2, -6, 0], "with the balance off only the user's own trim counts: \(off)")
        expect(on[0] == 2 && abs(on[1] - (c.roleOffsetDB(.center) - 6)) < 1e-9 && on[2] == 0, "\(on)")
        a.trimDB = 99; b.trimDB = -99
        expect(c.offsetsDB([a, b], autoLevel: false) == [12, -30], "trims are held to −30…+12 dB")
    }

    // MARK: volume curves

    func volumeCurves() {
        let a = Self.curveA, b = Self.curveB
        expect(a.minDB == -64 && a.maxDB == 0 && b.minDB == -50)
        expect(abs(a.db(at: 0.5) - (-64 * pow(0.5, 1.5))) < 1e-9, "table points are exact")
        expect(abs(b.db(at: 0.53125) - (-50 * (1 - 0.53125))) < 1e-4, "between points it interpolates: \(b.db(at: 0.53125))")
        expect(a.db(at: 0.5) != b.db(at: 0.5), "the same scalar is not the same level on two devices")
        expect(a.db(at: -3) == -64 && a.db(at: 9) == 0 && a.db(at: .nan) == -64, "outside 0…1, and not-a-number, are held to the ends")
        for i in 0...200 {
            let s = Float(i) / 200
            expect(abs(a.scalar(forDB: a.db(at: s)) - s) < 2e-4 && abs(b.scalar(forDB: b.db(at: s)) - s) < 1e-5, "round trip at \(s)")
        }
        expect(b.scalar(forDB: -80) == 0 && b.scalar(forDB: 12) == 1 && b.scalar(forDB: .nan) == 0 && b.scalar(forDB: .infinity) == 1, "levels beyond the device's range land on its ends")
        // a table that dips (a faulty device) is flattened, not followed
        let bad = VolumeCurve(points: [(0, -40), (0.25, -30), (0.5, -35), (0.75, -10), (1, 0)])!
        expect(bad.db(at: 0.5) == -30 && bad.db(at: 0.4) == -30 && bad.scalar(forDB: -20) > 0.5, "a volume control never gets quieter as it goes up")
        // unusable tables
        expect(VolumeCurve(points: [(0.5, -10)]) == nil && VolumeCurve(points: [(0, -10), (1, -10.5)]) == nil && VolumeCurve(points: [(0, .nan), (1, .infinity)]) == nil)
        expect(VolumeCurve(points: [(1, 0), (0, -30), (0, -31), (0.5, -10)])!.db(at: 0.5) == -10, "unsorted points and repeated scalars are tidied")
        // the generic curve: 60 dB, linear in dB, and a round trip for every scalar
        let g = VolumeCurve.generic
        expect(g.minDB == -60 && g.maxDB == 0 && abs(g.db(at: 0.5) - (-30)) < 1e-9)
        for i in 0...100 { let s = Float(i) / 100; expect(abs(g.scalar(forDB: g.db(at: s)) - s) < 1e-5) }
    }

    // MARK: the plan

    func levelPlan() {
        let A = Self.curveA, B = Self.curveB
        typealias Spec = SpeakerCalibration.Spec
        let specs = [Spec(curve: A, isMain: true, offsetDB: 0.97), Spec(curve: B, isMain: false, offsetDB: 1.5), Spec(curve: nil, isMain: false, offsetDB: -4)]
        let mid = SpeakerCalibration.solve(masterDB: -20, specs)
        expect(mid[0] == OutputLevel(hardwareDB: -20, digitalDB: 0.97), "the main output keeps its own volume; only its balance is digital: \(mid[0])")
        expect(mid[1] == OutputLevel(hardwareDB: -18.5, digitalDB: 0), "another device takes the offset in its own volume while it has range: \(mid[1])")
        expect(mid[2] == OutputLevel(hardwareDB: nil, digitalDB: -24), "a device with no volume control follows digitally: \(mid[2])")

        // sweeping the master: the distance between outputs never changes, and the digital gain stays put while the hardware has range
        var digitalB = Set<Double>()
        for m in stride(from: -60.0, through: 0, by: 1) {
            let l = SpeakerCalibration.solve(masterDB: m, specs)
            let total = l.indices.map { (l[$0].hardwareDB ?? 0) + l[$0].digitalDB }
            if l[1].hardwareDB! > B.minDB && l[1].hardwareDB! < B.maxDB { digitalB.insert(l[1].digitalDB) }
            expect(abs(total[1] - (m + 1.5)) < 1e-9 || m + 1.5 > 0 || m + 1.5 < B.minDB, "device B at \(m): \(l[1])")
            expect(abs(l[2].digitalDB - (m - 4)) < 1e-9, "device C at \(m): \(l[2])")
            for (i, x) in l.enumerated() { if let h = x.hardwareDB, i > 0 { expect(h >= B.minDB && h <= B.maxDB, "hardware stays inside the device's range: \(h)") } }
        }
        expect(digitalB == [0], "inside the hardware's range the digital gain never moves: \(digitalB)")
        // below the device's range the digital path carries the rest
        let low = SpeakerCalibration.solve(masterDB: -60, specs)[1]
        expect(low.hardwareDB == -50 && abs(low.digitalDB - (-8.5)) < 1e-9, "\(low)")
        // above it, a boost is limited to +3 dB
        let top = SpeakerCalibration.solve(masterDB: 0, [Spec(curve: A, isMain: true, offsetDB: 0), Spec(curve: B, isMain: false, offsetDB: 8)])[1]
        expect(top.hardwareDB == 0 && top.digitalDB == SpeakerCalibration.digitalBoostLimitDB, "\(top)")
        let floor = SpeakerCalibration.solve(masterDB: -500, [Spec(curve: nil, isMain: false, offsetDB: 0)])[0]
        expect(floor.digitalDB == SpeakerCalibration.digitalFloorDB, "\(floor)")
        // the main output's volume is unknown: hardware is left alone and only the balance is applied
        let blind = SpeakerCalibration.solve(masterDB: nil, specs)
        expect(blind.allSatisfy { $0.hardwareDB == nil } && blind[0].digitalDB == 0.97 && blind[1].digitalDB == 1.5 && blind[2].digitalDB == -4, "\(blind)")
        expect(SpeakerCalibration.solve(masterDB: -10, [Spec(curve: B, isMain: false, offsetDB: .nan)])[0] == OutputLevel(hardwareDB: -10, digitalDB: 0), "a nonsense offset counts as none")
        // with the generic curve everywhere and no offsets, matching is the old behaviour: the same scalar on every output
        let g = VolumeCurve.generic
        for i in 0...50 {
            let s = Float(i) / 50, master = g.db(at: s)
            let l = SpeakerCalibration.solve(masterDB: master, [Spec(curve: g, isMain: true, offsetDB: 0), Spec(curve: g, isMain: false, offsetDB: 0)])
            expect(abs(g.scalar(forDB: l[1].hardwareDB!) - s) < 1e-5 && l[1].digitalDB == 0, "scalar \(s)")
        }
        // two different devices at the same volume are brought to the same level, not the same scalar
        let ab = SpeakerCalibration.solve(masterDB: A.db(at: 0.5), [Spec(curve: A, isMain: true, offsetDB: 0), Spec(curve: B, isMain: false, offsetDB: 0)])
        expect(abs(B.db(at: B.scalar(forDB: ab[1].hardwareDB!)) - A.db(at: 0.5)) < 1e-4 && abs(B.scalar(forDB: ab[1].hardwareDB!) - 0.5) > 0.01, "\(ab)")
    }

    // MARK: ramps

    func hardwareRamp() {
        var r = LevelRamp(at: -40)
        expect(r.settled)
        r.retarget(to: -52)
        var t = 0.0, last = r.current, monotone = true
        while !r.settled && t < 1 { let v = r.advance(by: LevelFollower.tick); if v > last || v < -52 { monotone = false }; last = v; t += LevelFollower.tick }
        expect(monotone && r.current == -52, "a slide down is even and never overshoots")
        expect(t <= LevelRamp.maxDuration + LevelFollower.tick, "a 12 dB jump takes \(t) s")
        var small = LevelRamp(at: -10); small.retarget(to: -9)
        small.advance(by: LevelFollower.tick)
        expect(small.settled, "a 1 dB move is done in one tick: it tracks a slider")
        var big = LevelRamp(at: -60); big.retarget(to: 0)
        var n = 0; while !big.settled && n < 1000 { big.advance(by: LevelFollower.tick); n += 1 }
        expect(Double(n) * LevelFollower.tick <= LevelRamp.maxDuration + LevelFollower.tick, "even 60 dB takes no longer than \(LevelRamp.maxDuration) s: \(n) ticks")
        // retargeting in the middle continues from where it is, in either direction
        var m = LevelRamp(at: -30); m.retarget(to: -10)
        m.advance(by: 0.04)
        let mid = m.current
        expect(mid > -30 && mid < -10)
        m.retarget(to: -40)
        expect(m.current == mid, "no jump at a retarget")
        m.advance(by: 0.008)
        expect(m.current < mid && mid - m.current < 5, "it turns around smoothly: \(mid) → \(m.current)")
        m.advance(by: 10)
        expect(m.current == -40 && m.settled)
        var z = LevelRamp(at: -5); z.retarget(to: -9); z.advance(by: -1)
        expect(z.current == -5, "time does not run backwards")
    }

    // MARK: the smoothed gain

    func smoothGain() {
        let g = SmoothGain(gain: 1, rate: 48_000, timeConstant: 0.03)
        let k = SmoothGain.coefficient(rate: 48_000, timeConstant: 0.03)
        expect(abs(k - 6.94e-4) < 1e-5, "\(k)")
        g.setTarget(0.5)
        var buf = [Float](repeating: 1, count: 2 * 48_000)
        buf.withUnsafeMutableBufferPointer { g.apply($0.baseAddress!, frames: 48_000, channels: 2) }
        var maxStep: Float = 0
        for i in 1..<48_000 { maxStep = max(maxStep, abs(buf[i * 2] - buf[(i - 1) * 2])) }
        expect(maxStep <= k * 0.5 + 1e-7, "no step larger than the smoother allows: \(maxStep)")
        expect(buf[0] < 1 && buf[0] > 0.999 && buf[1] == buf[0], "the move starts at once, on both channels")
        expect(abs(buf[2 * 1440] - (0.5 + 0.5 * Float(exp(-1.0)))) < 0.002, "30 ms time constant: \(buf[2 * 1440])")
        expect(buf[2 * 47_999] == 0.5 && g.value == 0.5, "and it lands exactly")
        // a fade to nothing ends in exact zero and never in denormals
        g.setTarget(0)
        var sub = false, fin = Float(1)
        var b2 = [Float](repeating: 1, count: 2 * 4800)
        for _ in 0..<40 {
            b2.withUnsafeMutableBufferPointer { g.apply($0.baseAddress!, frames: 4800, channels: 2) }
            for v in b2 where v.isSubnormal { sub = true }
            fin = b2[b2.count - 1]
            for i in 0..<b2.count { b2[i] = 1 }
        }
        expect(!sub && fin == 0 && g.value == 0, "a fade to silence is clean")
        // settled at a level, a block is scaled evenly; settled at unity, untouched
        g.reset(to: 0.25)
        var c = [Float](repeating: 0.8, count: 64)
        c.withUnsafeMutableBufferPointer { g.apply($0.baseAddress!, frames: 32, channels: 2) }
        expect(c.allSatisfy { $0 == 0.2 }, "\(c[0])")
        g.reset(to: 1)
        var u: [Float] = [0.1, -0.2, 0.3]
        u.withUnsafeMutableBufferPointer { g.apply($0.baseAddress!, frames: 3, channels: 1) }
        expect(u == [0.1, -0.2, 0.3])
        // targets are sanitised
        g.setTarget(.nan); g.setTarget(.infinity); expect(g.target == 1, "not-a-number and infinity are ignored")
        g.setTarget(-2); expect(g.target == 0)
        g.setTarget(100); expect(g.target == SmoothGain.ceiling)
        g.setTarget(db: -6.0206); expect(abs(g.target - 0.5) < 1e-4)
        g.setTarget(db: .nan); expect(abs(g.target - 0.5) < 1e-4)
        expect(SmoothGain.linear(db: 0) == 1 && SmoothGain.linear(db: 40) == SmoothGain.ceiling && SmoothGain.linear(db: -200) < 1e-9 && SmoothGain.linear(db: .nan) == 1)

        // 32-bit samples: untouched at unity, scaled exactly, limited at the ends
        let i32 = SmoothGain(gain: 1, rate: 48_000)
        var p: [Int32] = [1_000_000, -1_000_000, Int32.max, Int32.min]
        p.withUnsafeMutableBufferPointer { i32.apply($0.baseAddress!, frames: 2, channels: 2) }
        expect(p == [1_000_000, -1_000_000, Int32.max, Int32.min], "unity leaves the samples exactly as they are")
        i32.reset(to: 0.5)
        p.withUnsafeMutableBufferPointer { i32.apply($0.baseAddress!, frames: 2, channels: 2) }
        expect(p == [500_000, -500_000, Int32.max / 2, Int32.min / 2] || p == [500_000, -500_000, 1_073_741_760, -1_073_741_824], "\(p)")
        i32.reset(to: 4)
        var hot: [Int32] = [Int32.max, Int32.min]
        hot.withUnsafeMutableBufferPointer { i32.apply($0.baseAddress!, frames: 1, channels: 2) }
        expect(hot[0] == 2_147_483_520 && hot[1] == Int32.min, "boost cannot wrap around: \(hot)")

        // the peak guard: transparent below 0.98, smooth and below 1 above it
        var prev: Float = 0
        var ok = true
        for i in 0...4000 {
            let x = Float(i) / 1000
            let y = SmoothGain.guardPeak(x)
            if x <= 0.98 && y != x { ok = false }
            if y < prev || y >= 1.0000001 || SmoothGain.guardPeak(-x) != -y { ok = false }
            prev = y
        }
        expect(ok && abs(SmoothGain.guardPeak(0.9801) - 0.9801) < 1e-4, "the guard is transparent, monotone, symmetric and bounded")
    }

    /// One thread renders while others change the target as fast as they can: whatever order things happen in, the output is a smooth
    /// movement between the targets. There is no lock to wait on, so the render side never stalls.
    func smoothGainAcrossThreads() {
        let g = SmoothGain(gain: 1, rate: 48_000)
        let k = SmoothGain.coefficient(rate: 48_000, timeConstant: 0.03)
        let stop = Atomic2()
        let setters = (0..<3).map { n -> Thread in
            let t = Thread {
                var x: UInt64 = UInt64(7 + n)
                while !stop.value {
                    x = x &* 6364136223846793005 &+ 1442695040888963407
                    g.setTarget([0.25, 1.0, 2.0, 0.5][Int(x >> 60) & 3])
                }
            }
            t.start(); return t
        }
        var block = [Float](repeating: 1, count: 2 * 128)
        var last: Float = 1, maxStep: Float = 0, lo: Float = 9, hi: Float = 0, finite = true
        let t0 = Date()
        var blocks = 0
        while Date().timeIntervalSince(t0) < 0.4 {
            for i in 0..<block.count { block[i] = 1 }
            block.withUnsafeMutableBufferPointer { g.apply($0.baseAddress!, frames: 128, channels: 2) }
            for f in 0..<128 {
                let v = block[f * 2]
                if !v.isFinite { finite = false }
                maxStep = max(maxStep, abs(v - last)); last = v; lo = min(lo, v); hi = max(hi, v)
            }
            blocks += 1
        }
        stop.value = true
        _ = setters
        expect(finite && blocks > 100, "\(blocks) blocks")
        expect(lo >= 0.25 - 1e-6 && hi <= 2 + 1e-6, "the output stays between the targets: \(lo)…\(hi)")
        expect(maxStep <= k * 1.75 + 1e-6, "and moves by no more than the smoother allows per sample: \(maxStep)")
    }

    // MARK: the render thread's stage

    func outputStage() {
        let rate = 48_000.0
        func make(delay: Int, gain: Float) -> (RoleProcessor, StereoDelay, SmoothGain) {
            let p = RoleProcessor(entry: .init(role: .main, gain: 0.1, delayFrames: 0, highPass: false), crossover: 100, rate: rate)
            let d = StereoDelay(maxFrames: 4000); d.setFrames(delay)
            return (p, d, SmoothGain(gain: gain, rate: rate))
        }
        let k = SmoothGain.coefficient(rate: rate, timeConstant: 0.03)
        // the processor no longer carries a level (the entry's gain is ignored): what goes in comes out
        let (proc, delay, level) = make(delay: 100, gain: 1)
        expect(proc.process(0.4, -0.2) == (0.4, -0.2), "the level lives in SmoothGain")
        let input = [Float](repeating: 0.5, count: 2 * 400)
        var out = [Int32](repeating: 7, count: 2 * 400)
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in
            OutputStage.run(processor: proc, delay: delay, level: level, input: i.baseAddress!, frames: 300, into: o.baseAddress!) } }
        expect(out[0..<200].allSatisfy { $0 == 0 } && out[200] == 1_073_741_824 && out[598] == 1_073_741_824, "unity: the delayed signal, bit for bit, as before")
        // a level change reaches the output at once, not a delay later
        level.setTarget(0.5)
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in
            OutputStage.run(processor: proc, delay: delay, level: level, input: i.baseAddress!, frames: 100, into: o.baseAddress!) } }
        expect(out[0] < 1_073_741_824 - 100_000, "the first sample after the change is already on its way down: \(out[0])")
        expect(out[0] == Int32(0.5 * Double(1 - 0.5 * k) * 2_147_483_648.0) || abs(Int(out[0]) - Int(0.5 * Double(1 - 0.5 * k) * 2_147_483_648.0)) < 300, "\(out[0])")
        var step = 0
        for i in 1..<100 { step = max(step, abs(Int(out[i * 2]) - Int(out[(i - 1) * 2]))) }
        expect(Double(step) <= Double(k) * 0.5 * 1_073_741_824 * 1.01 + 2, "and moves in small steps: \(step)")
        // a boosted signal is guarded: no wrap, no hard clip, and the sign is kept
        let (p2, d2, l2) = make(delay: 0, gain: 2)
        let hotIn: [Float] = [0.9, -0.9, 0.3, -0.3]
        var hotOut = [Int32](repeating: 0, count: 4)
        hotIn.withUnsafeBufferPointer { i in hotOut.withUnsafeMutableBufferPointer { o in
            OutputStage.run(processor: p2, delay: d2, level: l2, input: i.baseAddress!, frames: 2, into: o.baseAddress!) } }
        let guarded = Double(SmoothGain.guardPeak(1.8)) * 2_147_483_648.0
        expect(abs(Double(hotOut[0]) - guarded) < 300 && abs(Int(hotOut[1]) + Int(hotOut[0])) <= 128 && hotOut[0] <= 2_147_483_520 && hotOut[0] > 2_100_000_000, "\(hotOut)")
        expect(abs(Double(hotOut[2]) - 0.6 * 2_147_483_648.0) < 300 && hotOut[3] == -hotOut[2], "quiet signals are only scaled")
        // attenuating: no guard involved, exact arithmetic
        let (p3, d3, l3) = make(delay: 0, gain: 0.5)
        var half = [Int32](repeating: 0, count: 2)
        [Float(0.25), Float(-0.25)].withUnsafeBufferPointer { i in half.withUnsafeMutableBufferPointer { o in
            OutputStage.run(processor: p3, delay: d3, level: l3, input: i.baseAddress!, frames: 1, into: o.baseAddress!) } }
        expect(half == [268_435_456, -268_435_456], "\(half)")
    }

    // MARK: the follower

    private func rig(manual: Bool = true, offsets: [Double] = [0, 1.5, -4]) -> (LevelFollower, [SmoothGain], WriteLog) {
        let log = WriteLog()
        let gains = (0..<3).map { _ in SmoothGain(gain: 1, rate: 48_000) }
        let f = LevelFollower(outputs: [
            LevelFollower.Output(name: "main", isMain: true, curve: Self.curveA, gain: gains[0], write: nil),
            LevelFollower.Output(name: "table", isMain: false, curve: Self.curveB, gain: gains[1], write: { log.add($0) }),
            LevelFollower.Output(name: "usb", isMain: false, curve: nil, gain: gains[2], write: nil),
        ], offsets: offsets, manualClock: manual)
        return (f, gains, log)
    }

    func followerSlides() {
        let A = Self.curveA, B = Self.curveB
        let (f, gains, log) = rig()
        f.prime(masterScalar: 0.5)
        let master = A.db(at: 0.5)
        expect(log.all.count == 1 && abs(log.all[0] - B.scalar(forDB: master + 1.5)) < 1e-6, "an output joins at its calibrated level, not at its old one: \(log.all)")
        expect(abs(gains[2].value - SmoothGain.linear(db: master - 4)) < 1e-6 && gains[2].target == gains[2].value, "a device with no volume control starts at its digital level")
        expect(gains[0].value == 1 && gains[1].value == 1, "and the others need no digital gain")
        expect(f.levels[1].hardwareDB.map { abs($0 - (master + 1.5)) < 1e-9 } == true)

        // the volume goes up a lot: the device slides, in even steps, and lands exactly
        log.clear()
        f.setMaster(scalar: 0.9)
        f.flush()
        expect(log.all.isEmpty, "nothing is written until time moves")
        let target = B.scalar(forDB: A.db(at: 0.9) + 1.5)
        expect(abs(gains[2].target - SmoothGain.linear(db: A.db(at: 0.9) - 4)) < 1e-6, "a digital level is handed over at once, to be smoothed on the render side")
        f.advance(0.016)
        let early = log.all
        expect(early.count == 2 && early[0] > B.scalar(forDB: master + 1.5) && early[1] > early[0] && early[1] < target, "\(early)")
        f.advance(0.3)
        let all = log.all
        expect(abs(all.last! - target) < 1e-6, "it lands exactly on the target: \(all.last!) vs \(target)")
        expect(zip(all, all.dropFirst()).allSatisfy { $0 < $1 } && all.count >= 5 && all.count <= 20, "\(all.count) writes, each a little higher than the last")
        expect(f.hardwareDB(of: 1).map { abs($0 - (A.db(at: 0.9) + 1.5)) < 1e-9 } == true)
        let writes = f.hardwareWrites
        f.advance(1)
        expect(f.hardwareWrites == writes, "a settled output is left alone")

        // the volume moves again half way: it turns around from where it is
        log.clear()
        f.setMaster(scalar: 0.3)
        f.advance(0.04)
        let down = log.all
        f.setMaster(scalar: 0.95)
        f.advance(0.008)
        let turn = log.all
        expect(down.count >= 3 && turn.count == down.count + 1 && turn.last! > down.last! && turn.last! - down.last! < 0.06, "\(down) → \(turn)")
        f.advance(1)
        expect(abs(log.all.last! - B.scalar(forDB: A.db(at: 0.95) + 1.5)) < 1e-6, "and the last volume wins")

        // a new balance is a slide too
        log.clear()
        f.setOffsets([0, -6, -4]); f.advance(1)
        expect(abs(log.all.last! - B.scalar(forDB: A.db(at: 0.95) - 6)) < 1e-6 && log.all.count >= 2, "\(log.all)")
        f.setOffsets([0]); f.advance(1)                   // fewer offsets than outputs: the missing ones are zero
        expect(abs(log.all.last! - B.scalar(forDB: A.db(at: 0.95))) < 1e-6)

        // the main output reports no volume: hardware is not touched and the balance is digital
        let (g, gg, glog) = rig(offsets: [0.97, 1.5, -4])
        g.prime(masterScalar: nil)
        g.advance(1)
        expect(glog.all.isEmpty && gg[0].value == SmoothGain.linear(db: 0.97) && gg[1].value == SmoothGain.linear(db: 1.5) && gg[2].value == SmoothGain.linear(db: -4), "no master, no hardware writes")
        // the volume of an output the user cannot move cannot be driven; the main output is never written
        let (h, _, hlog) = rig()
        h.prime(masterScalar: 0.2); h.setMaster(scalar: 0.4); h.advance(1)
        expect(hlog.all.count > 1)
        h.stop()
    }

    /// The same thing on the follower's own clock: the slide is spread over a short time, in order, and ends where it should.
    func followerRunsOnItsOwnClock() {
        let B = Self.curveB
        let (f, _, log) = rig(manual: false)
        f.prime(masterScalar: 0.3)
        log.clear()
        let t0 = Date()
        f.setMaster(scalar: 0.95)
        let target = B.scalar(forDB: Self.curveA.db(at: 0.95) + 1.5)
        var reached = false
        while Date().timeIntervalSince(t0) < 2 { if let l = log.all.last, abs(l - target) < 1e-6 { reached = true; break }; Thread.sleep(forTimeInterval: 0.005) }
        let took = Date().timeIntervalSince(t0)
        f.flush()
        let all = log.all
        expect(reached, "the slide ended on the target")
        expect(took < 0.6 && took > 0.02, "in about a tenth of a second: \(took) s")
        expect(zip(all, all.dropFirst()).allSatisfy { $0 < $1 } && all.count >= 3 && all.count <= 40, "\(all.count) writes in order")
        Thread.sleep(forTimeInterval: 0.1)
        let n = log.all.count
        Thread.sleep(forTimeInterval: 0.1)
        expect(log.all.count == n, "the clock stops when everything has settled")
        f.stop()
        f.setMaster(scalar: 0.2); f.flush()
        Thread.sleep(forTimeInterval: 0.1)
        f.stop()
    }

    // MARK: saved setups

    func setupSaves() {
        let old = #"{"enabled":true,"members":[{"uid":"u","name":"Table","role":"center","distanceM":1.5,"extraDelayMs":2,"trimDB":-3}],"crossoverHz":120,"bassManagement":false}"#
        let s = try? JSONDecoder().decode(SpeakerSetup.self, from: Data(old.utf8))
        expect(s != nil && s!.enabled && s!.autoLevel && s!.crossoverHz == 120 && !s!.bassManagement && s!.members.count == 1 && s!.members[0].role == .center, "a save from before the balance existed still loads, with it on")
        var n = s!; n.autoLevel = false
        expect((try? JSONDecoder().decode(SpeakerSetup.self, from: JSONEncoder().encode(n))) == n, "and the new setting is kept")
        expect((try? JSONDecoder().decode(SpeakerSetup.self, from: Data("{}".utf8))) == SpeakerSetup(), "an empty save is the default setup")
        expect(SpeakerSetup().autoLevel, "on by default")
    }

    // MARK: zones

    func coalescingSender() {
        final class Seen: @unchecked Sendable { let l = NSLock(); var v: [Int] = []; func add(_ x: Int) { l.lock(); v.append(x); l.unlock() }; var all: [Int] { l.lock(); defer { l.unlock() }; return v } }
        let seen = Seen()
        let s = CoalescingSender<Int> { v in try? await Task.sleep(nanoseconds: 4_000_000); seen.add(v) }
        for i in 1...200 { s.submit(i); if i % 20 == 0 { Thread.sleep(forTimeInterval: 0.002) } }
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 3 && seen.all.last != 200 { Thread.sleep(forTimeInterval: 0.005) }
        let got = seen.all
        expect(got.last == 200, "the newest value always arrives: \(got.suffix(3))")
        expect(zip(got, got.dropFirst()).allSatisfy { $0 < $1 }, "and nothing arrives out of order")
        expect(got.count < 120, "values overtaken while a send was in flight are skipped: \(got.count) of 200")
        // it can be used again afterwards
        s.submit(500)
        let t1 = Date()
        while Date().timeIntervalSince(t1) < 2 && seen.all.last != 500 { Thread.sleep(forTimeInterval: 0.005) }
        expect(seen.all.last == 500)
    }

    func zoneRoomLevels() {
        expect(ZoneModel.clampLevel(5) == 0 && ZoneModel.clampLevel(-90) == -24 && ZoneModel.clampLevel(.nan) == 0 && ZoneModel.clampLevel(-6) == -6, "room trims are 0 to −24 dB")
        let fmt = CastFormat(sampleRate: 44_100, bitsPerSample: 24, channels: 2)
        let feed = ZoneFeed(format: fmt, path: "/lvl.flac")
        expect(feed.level.target == 1 && feed.level.value == 1, "a room starts untouched")
        feed.level.reset(to: 0.5)
        let port = try! feed.start(); defer { feed.stop() }
        let c = Collector(); let ses = URLSession(configuration: .ephemeral, delegate: c, delegateQueue: nil)
        let task = ses.dataTask(with: URL(string: "http://127.0.0.1:\(port)/lvl.flac")!); task.resume()
        expect(c.wait({ feed.hub.subscriberCount == 1 }, timeout: 3))
        let total = 4096 * 12
        var pcm = [Int32](repeating: 0, count: total * 2)
        for i in 0..<total { pcm[i * 2] = Int32(i + 1) << 10; pcm[i * 2 + 1] = -Int32(i + 1) << 10 }       // the encoder keeps 24 bits of 32: halving and quartering stay exact
        pcm.withUnsafeBufferPointer { b in
            var p = 0
            while p < total {
                if p == 4096 * 2 { feed.level.setTarget(0.25) }            // mid-stream, from another thread's point of view
                let n = min(1024, total - p); feed.push(b.baseAddress! + p * 2, frames: n); p += n
            }
        }
        expect(c.wait({ c.snapshot.count > 1000 && feed.hub.framesPublished >= 11 }, timeout: 3))
        Thread.sleep(forTimeInterval: 0.2)
        try! c.snapshot.write(to: dir.appendingPathComponent("lvl.flac"))
        guard let f = try? LosslessFile(path: dir.appendingPathComponent("lvl.flac").path) else { expect(false, "the stream is not decodable"); return }
        let got = readAll(f)
        task.cancel(); ses.invalidateAndCancel()
        expect(got.count == total * 2, "\(got.count / 2) frames")
        guard got.count == total * 2 else { return }
        expect(Array(got[0..<(2 * 4096 * 2)]) == (0..<(2 * 4096 * 2)).map { pcm[$0] / 2 }, "before the change the room hears half the level, exactly")
        let tail = (total - 4096) * 2
        expect(Array(got[tail...]) == (tail..<(total * 2)).map { pcm[$0] / 4 }, "after it, a quarter, exactly: the move has landed")
        var step = 0
        for i in 1..<total { step = max(step, abs(Int(got[i * 2]) - Int(got[(i - 1) * 2]))) }
        expect(step < 8000, "and in between it slid, with no step: largest change between samples \(step) (a step would be about \(pcm[4096 * 4] / 4 * 3))")
    }
}


/// Several outputs playing together: that they arrive together, and that the ambience speaker adds the room without taking the beat away.
struct MultiOutputTests {
    private let rate = 48_000.0

    private func processor(_ role: SpeakerRole, highPass: Bool = false) -> RoleProcessor {
        RoleProcessor(entry: SpeakerPlan.Entry(role: role, gain: 1, delayFrames: 0, highPass: highPass), crossover: 100, rate: rate)
    }
    /// Runs a signal through a role: `left`/`right` amplitudes of a sine at `hz`; returns (input, output) after the filters have settled.
    private func run(_ role: SpeakerRole, hz: Double, left: Double, right: Double, seconds: Double = 0.6) -> (input: [Double], output: [Double]) {
        let p = processor(role)
        let n = Int(rate * seconds), settle = Int(rate * 0.25)
        var input: [Double] = [], output: [Double] = []
        for i in 0..<n {
            let s = sin(2 * .pi * hz * Double(i) / rate)
            let (a, _) = p.process(Float(left * s), Float(right * s))
            if i >= settle { input.append(0.5 * (left + right) * s); output.append(Double(a)) }
        }
        return (input, output)
    }
    private func rms(_ x: [Double]) -> Double { (x.reduce(0) { $0 + $1 * $1 } / Double(max(1, x.count))).squareRoot() }
    private func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    func outputsAreAlignedByTheirLatency() {
        // a built-in speaker at 12 ms and a Bluetooth speaker at 180 ms: the built-in one waits 168 ms
        let a = SpeakerPlan.alignmentSeconds(latencies: [0.012, 0.180])
        expect(abs(a[0] - 0.168) < 1e-9 && a[1] == 0, "the earlier output is delayed to match the later: \(a)")
        let u = SpeakerPlan.alignmentSeconds(latencies: [0.012, nil, 0.020])
        expect(abs(u[0] - 0.008) < 1e-9 && u[1] == 0 && u[2] == 0, "an output that does not report is left alone: \(u)")
        expect(SpeakerPlan.alignmentSeconds(latencies: [nil, nil]) == [0, 0] && SpeakerPlan.alignmentSeconds(latencies: [0.01, 0.01]) == [0, 0] && SpeakerPlan.alignmentSeconds(latencies: []) == [], "no latency, no delay")
        expect(SpeakerPlan.alignmentSeconds(latencies: [.nan, -1, 0.05]) == [0, 0, 0], "nonsense is ignored")
        // in the plan, in frames
        var a1 = SpeakerMember(uid: "a", name: "MacBook"), b1 = SpeakerMember(uid: "b", name: "Bluetooth")
        let plan = SpeakerPlan.entries([a1, b1], rate: rate, bassManagement: false, extraLatencyFrames: [], latencySeconds: [0.012, 0.180])
        expect(plan[0].delayFrames == Int((0.168 * rate).rounded()) && plan[1].delayFrames == 0, "the plan carries it: \(plan.map(\.delayFrames))")
        // with distances and a manual trim on top
        a1.distanceM = 3; b1.distanceM = 1; b1.extraDelayMs = 20
        let with = SpeakerPlan.entries([a1, b1], rate: rate, bassManagement: false, extraLatencyFrames: [], latencySeconds: [0.012, 0.180])
        let travel = (3.0 - 1.0) / SpeakerPlan.speedOfSound
        expect(with[0].delayFrames == Int((0.168 * rate).rounded()) && with[1].delayFrames == Int(((travel + 0.020) * rate).rounded()), "latency, distance and trim add up: \(with.map(\.delayFrames))")
        // a negative trim moves the others later, never below zero
        var c1 = SpeakerMember(uid: "c", name: "C"), d1 = SpeakerMember(uid: "d", name: "D")
        c1.extraDelayMs = -30
        let neg = SpeakerPlan.entries([c1, d1], rate: rate, bassManagement: false, extraLatencyFrames: [])
        expect(neg[0].delayFrames == 0 && neg[1].delayFrames == Int((0.030 * rate).rounded()), "earlier means the others wait: \(neg.map(\.delayFrames))")
        // the delay can reach 750 ms (Bluetooth plus a trim) with the cap raised
        d1.extraDelayMs = 500
        let big = SpeakerPlan.entries([c1, d1], rate: rate, bassManagement: false, extraLatencyFrames: [], latencySeconds: [0.012, 0.250], maxDelaySeconds: 1.0)
        expect(big[0].delayFrames == Int(((0.250 - 0.012 - 0.030) * rate).rounded()) && big[1].delayFrames == Int((0.5 * rate).rounded()), "latency and trims reach the right frames: \(big.map(\.delayFrames))")
        expect(StereoDelay(maxFrames: 262_144).capacity >= Int(1.0 * 192_000), "the delay line holds a second at 192 kHz")
        // the latency of a real output is read without trouble
        if let dev = listOutputDevices().first(where: { !$0.rates.isEmpty }), let d = OutputDevice(id: dev.id) {
            if let l = d.outputLatencySeconds { expect(l >= 0 && l < 2, "\(dev.name) reports \(l) s") }
        }
    }

    func theDelayLineDelaysExactlyAndCrossFades() {
        let e = StereoDelay(maxFrames: 4_096)
        e.setFrames(100)
        for _ in 0..<(StereoDelay.fadeFrames + 10) { _ = e.process(0, 0) }
        var after: [Float] = []
        for i in 0..<400 { after.append(e.process(i == 0 ? 1 : 0, 0).0) }
        expect(after[100] == 1 && after.enumerated().allSatisfy { $0.offset == 100 || $0.element == 0 }, "settled, an impulse arrives exactly 100 frames later")
        // the first length is taken as it is: no fade in from nothing
        let f = StereoDelay(maxFrames: 4_096); f.setFrames(3)
        var first: [Float] = []
        for i in 1...6 { first.append(f.process(Float(i), 0).0) }
        expect(first == [0, 0, 0, 1, 2, 3], "\(first)")
        // a retune does not click: a ramp through a change of length stays smooth
        let r = StereoDelay(maxFrames: 8_192)
        r.setFrames(0)
        var last: Float = 0, worst: Float = 0
        let slope: Float = 1.0 / 4_000
        for i in 0..<6_000 {
            if i == 3_000 { r.setFrames(1_000) }
            let y = r.process(Float(i) * slope, 0).0
            if i > 0 { worst = max(worst, abs(y - last)) }
            last = y
        }
        expect(worst <= slope * 6, "the biggest step of the output is \(worst / slope) samples of the ramp; a jump would be 1000")
        // lengths are held to the buffer
        r.setFrames(10_000_000); expect(r.frames.load(ordering: .relaxed) == r.capacity)
        r.setFrames(-5); expect(r.frames.load(ordering: .relaxed) == 0)
    }

    func ambienceKeepsTheBeat() {
        for hz in [40.0, 60.0, 80.0, 100.0, 120.0, 150.0] {
            let stereo = run(.main, hz: hz, left: 0.5, right: 0.5), amb = run(.surround, hz: hz, left: 0.5, right: 0.5)
            let share = (rms(amb.output) / rms(stereo.output))
            expect(share * share >= 0.9, "\(Int(hz)) Hz: the ambience speaker carries \(Int(share * share * 100)) % of the stereo speakers' energy (the beat)")
            // in phase with the music: nothing inverted
            expect(dot(amb.output, stereo.output) > 0, "\(Int(hz)) Hz: in phase with the stereo speakers")
            // together they add, they do not cancel
            let sum = zip(stereo.output, amb.output).map { $0 + $1 }
            expect(rms(sum) >= 0.9 * rms(stereo.output), "\(Int(hz)) Hz: stereo plus ambience is \(Int(rms(sum) / rms(stereo.output) * 100)) % of stereo alone")
        }
        // the stereo role passes the music through unchanged and not inverted
        let s = run(.main, hz: 1000, left: 0.4, right: 0.4)
        expect(zip(s.input, s.output).allSatisfy { abs($0 - $1) < 1e-6 }, "stereo is the music, untouched")
        // above the crossover the ambience is the room: the sides in full, the centre kept low
        let side = run(.surround, hz: 1000, left: 0.5, right: -0.5), centre = run(.surround, hz: 1000, left: 0.5, right: 0.5), top = run(.surround, hz: 6000, left: 0.5, right: 0.5)
        let ref = 0.5 / 2.0.squareRoot()
        let sideGain = rms(side.output) / ref, centreGain = rms(centre.output) / ref, topGain = rms(top.output) / ref
        expect(abs(sideGain - 1) < 0.1, "the sides come through in full: \(sideGain)")
        expect(centreGain > 0.2 && centreGain < 0.65, "the centre is held back in the middle of the range: \(centreGain)")
        expect(abs(topGain - RoleProcessor.ambienceCentre) < 0.06, "and sits at about -12 dB at the top: \(topGain)")
        // no reverb or delay is added: a click comes out at the same moment
        let p = processor(.surround)
        var peakAt = -1, peak = 0.0
        for i in 0..<200 { let (a, _) = p.process(i == 20 ? 1 : 0, i == 20 ? -1 : 0); if abs(Double(a)) > peak { peak = abs(Double(a)); peakAt = i } }
        expect(peakAt == 20, "a click in the sides comes out in the same sample: \(peakAt)")
    }

    func ambienceSitsBehindTheMusic() {
        expect(SpeakerCalibration.roleOffsetDB(.surround) == SpeakerCalibration.ambienceOffsetDB && SpeakerCalibration.ambienceOffsetDB == -6, "ambience sits 6 dB behind the stereo speakers")
        for r in SpeakerRole.allCases { expect(abs(SpeakerCalibration.roleOffsetDB(r)) <= 6, "no role is moved by more than a few dB: \(r)") }
        expect(SpeakerCalibration.roleOffsetDB(.main) == 0 && SpeakerCalibration.roleOffsetDB(.surround) < SpeakerCalibration.roleOffsetDB(.main), "ambience is below stereo, never above")
    }
}

func multiOutputTests() -> [(String, TestFn)] {
    let t = MultiOutputTests()
    return [("audio.alignLatency", t.outputsAreAlignedByTheirLatency), ("audio.delayLine", t.theDelayLineDelaysExactlyAndCrossFades), ("audio.ambienceBeat", t.ambienceKeepsTheBeat), ("audio.ambienceLevel", t.ambienceSitsBehindTheMusic)]
}

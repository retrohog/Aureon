import Foundation

// A minimal built-in test runner: `Aureon selftest [filter]`.
// The Command Line Tools ship no XCTest / Swift Testing plugin, so the project verifies itself.
// CI and contributors run the same command; it needs no Xcode and no audio hardware.

final class SelfTest: @unchecked Sendable {
    nonisolated(unsafe) static var current = SelfTest()
    var failures: [String] = []
    var checks = 0
}

func expect(_ ok: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: Int = #line) {
    SelfTest.current.checks += 1
    if !ok { SelfTest.current.failures.append("\(file):\(line) \(message())") }
}

typealias TestFn = () -> Void

enum SelfTestRunner {
    static var all: [(String, TestFn)] {
        var t: [(String, TestFn)] = []
        let r = RingTests()
        t += [("ring.roundTrip", r.writeReadRoundTrip), ("ring.wrapAround", r.wrapAround), ("ring.truncateDropsTail", r.truncateDropsOnlyTheTail),
              ("ring.truncateRefused", r.truncateRefusedWhenAlreadyPlayed), ("ring.flush", r.flushDiscardsEverything),
              ("ring.concurrentOrder", r.concurrentProducerConsumerKeepsOrder)]
        let s = ResamplerTests()
        t += [("resampler.sinePreserved", s.sineIsPreservedAndTimeAligned), ("resampler.passbandFlat", s.passbandIsFlat),
              ("resampler.imagesRejected", s.imagesAreRejected), ("resampler.minimumPhaseMagnitude", s.minimumPhaseKeepsMagnitude),
              ("resampler.preRinging", s.preRingingDiffersByPhase), ("resampler.seekDeterministic", s.seekIsDeterministic),
              ("resampler.targetSelection", s.targetSelection)]
        t += extraTests()
        t += upscalerTests()
        return t
    }

    static func run(filter: String?) -> Int32 {
        setenv("AUREON_TESTING", "1", 1)          // tests never write the user's saved profiles, cues or settings
        var failed = 0, ran = 0
        let start = Date()
        for (name, fn) in all where filter == nil || name.localizedCaseInsensitiveContains(filter!) {
            SelfTest.current = SelfTest()
            let t0 = Date()
            fn()
            ran += 1
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if SelfTest.current.failures.isEmpty { print("  ✓ \(name) (\(SelfTest.current.checks) checks, \(ms) ms)") }
            else {
                failed += 1
                print("  ✗ \(name)")
                for f in SelfTest.current.failures.prefix(6) { print("      \(f)") }
            }
        }
        print("\n\(ran - failed)/\(ran) passed in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        return failed == 0 ? 0 : 1
    }
}

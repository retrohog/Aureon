import Foundation
import AureonNeuralCore

/// The enhancer as a pipeline stage. Runs on the player's decode thread, like every `FrameSource`; never on the audio thread.
///
/// Each `read` keeps up to `UpscaleStream.lookahead` blocks in flight with the worker, then commits blocks oldest first:
///
/// * the model's block is DONE: it is overlap-added in;
/// * it is still pending or running and the device has enough audio queued: wait for it, at most until the queue would fall to
///   `lowWaterSeconds` and never longer than three hops per block;
/// * otherwise, or when the enhancer is switched off: the block commits as fallback, which is the input itself (the sinc-resampled
///   stream). That decision is one atomic load and at most a few compare-and-swaps in `au_ola_commit`: it never waits for the worker.
///
/// Because blocks overlap and the synthesis windows add up to one, a fallback block between neural ones is a crossfade, not a step;
/// stretches with no neural block are bit-identical to the input. The breaker (`AUGuard`) stops sending blocks altogether when the
/// model is too slow or keeps missing, and tries again after a cooldown measured in audio time.
final class NeuralUpscaleSource: FrameSource {
    let info: StreamInfo
    let stream: UpscaleStream
    private let upstream: FrameSource
    private weak var service: NeuralUpscaler?
    private let gate: EnhancerGate
    private let status: NeuralUpscaleStatus
    private let gauge: PlayoutGauge?
    private let ch: Int
    private let scratch: UnsafeMutablePointer<Int32>
    private let scratchFrames: Int
    private var upstreamEnded = false, finished = false

    let hopSeconds: Double
    /// Below this much queued audio a late block is not waited for.
    var lowWaterSeconds = 0.5
    /// Below this much queued audio a late block also trips the breaker at once.
    var criticalSeconds = 0.25
    /// The longest the decode thread waits for one block.
    let maxWaitSeconds: Double

    init(_ upstream: FrameSource, stream: UpscaleStream, service: NeuralUpscaler, gauge: PlayoutGauge?) {
        self.upstream = upstream; self.stream = stream; self.service = service; self.gauge = gauge
        gate = service.gate; status = service.status
        var i = upstream.info
        i.transparent = false
        info = i
        ch = i.channels
        let hop = Int(au_ola_hop(stream.ola))
        hopSeconds = Double(hop) / i.sampleRate
        maxWaitSeconds = max(0.1, 3 * hopSeconds)
        scratchFrames = max(1024, hop)
        scratch = .allocate(capacity: scratchFrames * ch)
    }

    deinit {
        scratch.deallocate()
        service?.unregister(stream)
    }

    var latencyFrames: Int { Int(au_ola_latency_frames(stream.ola)) }

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        var produced = 0
        while produced < frames {
            produced += Int(au_ola_pull(stream.ola, buf + produced * ch, Int32(frames - produced)))
            if produced == frames || finished { break }
            advance()
        }
        return produced
    }

    func seek(to frame: Int64) {
        au_ola_reset(stream.ola)            // running blocks are abandoned, not waited for
        upstream.seek(to: frame)
        upstreamEnded = false; finished = false
    }

    // MARK: -

    private var enabled: Bool { gate.isEnabled }

    private func advance() {
        fill()
        if au_ola_poll(stream.ola) == Int32(AU_WINDOW_NONE) {
            if upstreamEnded { au_ola_finish(stream.ola); finished = true }
            return
        }
        commitOldest()
    }

    /// Reads ahead until the lookahead is full, sending each completed block to the model when that is wanted.
    private func fill() {
        var space = Int(au_ola_input_space(stream.ola))
        while space > 0 && !upstreamEnded {
            let n = upstream.read(into: scratch, frames: min(space, scratchFrames))
            if n == 0 { upstreamEnded = true; break }
            let submit: Int32 = enabled && au_guard_should_submit(stream.breaker) != 0 && (service?.isReady ?? false) ? 1 : 0
            var off = 0
            while off < n {
                var created: Int32 = 0
                let took = Int(au_ola_push(stream.ola, scratch + off * ch, Int32(n - off), submit, &created))
                if created > 0 { service?.signal(Int(created)) }
                if took == 0 { break }       // cannot happen: n ≤ space
                off += took
            }
            space = Int(au_ola_input_space(stream.ola))
        }
    }

    private func commitOldest() {
        let accept = enabled
        var st = au_ola_poll(stream.ola)
        let submitted = st != Int32(AU_WINDOW_UNSUBMITTED)
        if accept && isInFlight(st) {
            // Bounded wait on the decode thread only. The device keeps playing from the ring meanwhile.
            let start = DispatchTime.now().uptimeNanoseconds
            while isInFlight(st) {
                let waited = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                var budget = maxWaitSeconds - waited
                if let h = gauge?.headroomSeconds { budget = min(budget, h - lowWaterSeconds) }
                if budget <= 0 { break }
                _ = stream.finished.wait(timeout: .now() + min(budget, 0.05))
                st = au_ola_poll(stream.ola)
            }
        }
        let neural = au_ola_commit(stream.ola, accept ? 1 : 0)
        var stats = AUOlaStats()
        au_ola_stats(stream.ola, &stats)
        let learned: Int32 = submitted && accept ? 1 : 0
        au_guard_on_window(stream.breaker, learned, neural, stats.inferEmaSeconds)
        if learned != 0 && neural == 0, let h = gauge?.headroomSeconds, h < criticalSeconds { au_guard_trip(stream.breaker) }
        publish(neural: neural == 1, accept: accept)
    }

    @inline(__always) private func isInFlight(_ st: Int32) -> Bool { st == Int32(AU_SLOT_PENDING) || st == Int32(AU_SLOT_RUNNING) }

    private func publish(neural: Bool, accept: Bool) {
        status.countWindow(neural: neural)
        status.setRealTimeFactor(au_guard_rtf(stream.breaker))
        guard accept else { status.set(.off); return }
        switch au_guard_state(stream.breaker) {
        case Int32(AU_GUARD_BYPASSED): status.set(.bypassed("This Mac could not keep up; the classic resampler is playing and the enhancer will retry shortly"))
        default: status.set(neural || service?.isReady == true ? .active : .bypassed("The model is not loaded"))
        }
    }
}

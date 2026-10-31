// AureonNeuralCore: the real-time-safe part of the neural upscaler.
//
// Two objects, both allocated once in `create` and never again:
//
//  * AUOla, the overlap-add stream stitcher. The producer (the player's decode thread) pushes Int32 frames in; every `hop`
//    frames a `window`-long block is copied into a free inference slot for the model. Results are committed oldest first,
//    each one either neural (the model's output) or fallback (the input itself), and summed with a synthesis window that is
//    normalised so the overlapping windows add up to exactly 1. Mixing neural and fallback windows is therefore always a
//    smooth crossfade, never a step. Frames that no neural window touched come out bit-identical to the input.
//
//  * AUGuard, the circuit breaker. It watches the inference time against the hop duration and the windows that missed their
//    deadline, and bypasses the model (stops submitting work) for a cooldown measured in audio time, with exponential backoff.
//
// Threading. Producer calls: push, poll, commit, pull, finish, reset, input_space, ready_frames and every au_guard_* call except
// the read-only ones. Worker calls: worker_take, worker_finish, slot_input, slot_output. Any thread: stats, au_guard_state,
// au_guard_rtf, au_guard_trips. Producer and worker meet only through per-slot atomic state words; no call blocks, locks or
// allocates, and every producer decision (commit, poll, push) is wait-free: it finishes in a bounded number of steps whatever
// the worker is doing.
//
// Plain C interface so Swift imports it without C++ interop.

#ifndef AUREON_NEURAL_CORE_H
#define AUREON_NEURAL_CORE_H

#include <stdint.h>
#include "AureonAtomics.h"

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Overlap-add stitcher

typedef struct AUOla AUOla;

typedef struct {
    int32_t channels;    // 1 ... 8
    int32_t window;      // W, frames per model block, 64 ... 262144
    int32_t hop;         // H, W must be a multiple of H with W / H in 2 ... 16
    int32_t slots;       // inference buffers, 1 ... 64
    int32_t lookahead;   // windows that may be formed ahead of the output, 1 ... 64
} AUOlaConfig;

/// Slot states. A slot cycles FREE → PENDING (producer) → RUNNING (worker) → DONE / FAILED (worker) → FREE (producer).
/// A producer that gives up on a slot moves PENDING → FREE or RUNNING → ABANDONED; the worker then returns ABANDONED → FREE.
enum {
    AU_SLOT_FREE = 0,
    AU_SLOT_PENDING = 1,
    AU_SLOT_RUNNING = 2,
    AU_SLOT_DONE = 3,
    AU_SLOT_FAILED = 4,
    AU_SLOT_ABANDONED = 5,
};

/// What `au_ola_poll` reports about the oldest window that is formed but not committed.
enum {
    AU_WINDOW_NONE = -1,       // no window is waiting (more input is needed, or the stream finished)
    AU_WINDOW_UNSUBMITTED = 6, // formed without a slot (not submitted, or every slot busy): commits as fallback
    // otherwise one of AU_SLOT_PENDING / RUNNING / DONE / FAILED
};

typedef struct {
    int64_t windowsFormed;
    int64_t windowsNeural;      // committed with the model's output
    int64_t windowsFallback;    // committed with the input (late, failed, unsubmitted, refused or non-finite)
    int64_t jobsSubmitted;
    int64_t jobsCompleted;      // finished by the worker (in time or not)
    int64_t jobsFailed;         // the worker reported an error
    int64_t jobsLate;           // still pending or running when the producer committed
    int64_t jobsNonFinite;      // the model returned NaN or infinity: thrown away
    int64_t slotsExhausted;     // a window wanted a slot and none was free
    double inferLastSeconds;    // duration of the most recent inference
    double inferEmaSeconds;     // exponential moving average (α = 0.2) of the inference duration
} AUOlaStats;

/// Returns NULL when the configuration is out of range or memory is short.
AUOla *au_ola_create(const AUOlaConfig *config);
/// The worker must no longer touch the object (it holds no slot).
void au_ola_destroy(AUOla *ola);

/// Producer. Forgets every frame and window (used on seek). Slots that the worker is running are abandoned, not waited for.
void au_ola_reset(AUOla *ola);

/// Producer. Frames that `push` accepts right now: limited by the lookahead and by the history buffer.
int32_t au_ola_input_space(const AUOla *ola);

/// Producer. Appends up to `frames` interleaved frames and returns how many were taken (at most `au_ola_input_space`).
/// Each window this completes is copied into a free slot and marked PENDING when `submit` is non-zero; `submitted`
/// (optional) receives the number of jobs created, so the caller can wake its worker once per job.
int32_t au_ola_push(AUOla *ola, const int32_t *frames_interleaved, int32_t frames, int32_t submit, int32_t *submitted);

/// Producer. State of the oldest formed, uncommitted window (see the enums above).
int32_t au_ola_poll(const AUOla *ola);

/// Producer, wait-free. Commits the oldest formed window: neural when `accept_neural` is non-zero and its job is DONE with
/// finite output, otherwise fallback (a pending job is cancelled, a running one abandoned). Returns 1 neural, 0 fallback,
/// -1 when no window is waiting.
int32_t au_ola_commit(AUOla *ola, int32_t accept_neural);

/// Producer. End of input: every formed window still waiting commits as fallback and every frame pushed becomes final.
void au_ola_finish(AUOla *ola);

/// Producer. Frames that are final and not yet pulled.
int32_t au_ola_ready_frames(const AUOla *ola);

/// Producer. Copies up to `frames` final frames out (interleaved Int32) and returns how many.
int32_t au_ola_pull(AUOla *ola, int32_t *dst_interleaved, int32_t frames);

/// Worker. Takes the oldest PENDING job (marks it RUNNING) and returns its slot index, or -1 when there is none.
int32_t au_ola_worker_take(AUOla *ola);
/// Worker. Planar float buffers of a slot: `channels` rows of `window` samples, full scale ±1.
float *au_ola_slot_input(AUOla *ola, int32_t slot);
float *au_ola_slot_output(AUOla *ola, int32_t slot);
/// Worker. Hands a slot back: DONE when `ok`, FAILED otherwise; frees it at once if the producer abandoned it meanwhile.
void au_ola_worker_finish(AUOla *ola, int32_t slot, int32_t ok, double seconds);

/// Any thread. Relaxed snapshot of the counters.
void au_ola_stats(const AUOla *ola, AUOlaStats *out);

/// Accessors for the configuration the object was created with.
int32_t au_ola_channels(const AUOla *ola);
int32_t au_ola_window(const AUOla *ola);
int32_t au_ola_hop(const AUOla *ola);
int32_t au_ola_slots(const AUOla *ola);
/// Frames between a sample entering `push` and it being final, when the model keeps up: window + (lookahead - 1) × hop.
int32_t au_ola_latency_frames(const AUOla *ola);

// MARK: - Circuit breaker

typedef struct AUGuard AUGuard;

typedef struct {
    double hopSeconds;          // audio time per window (hop / sample rate)
    double tripRTF;             // inference time ÷ hop time above which the model is bypassed (e.g. 0.8)
    int32_t missSpan;           // how many recent submitted windows are remembered (1 ... 64)
    int32_t missLimit;          // late or failed windows within that span that trip the breaker
    int32_t warmupWindows;      // windows after a (re)start before the speed rule applies
    int32_t probeWindows;       // windows a probe must survive to count as recovered
    double cooldownSeconds;     // first bypass length, in audio time
    double maxCooldownSeconds;  // the bypass doubles on every trip in a row, up to this
} AUGuardConfig;

enum { AU_GUARD_ACTIVE = 0, AU_GUARD_BYPASSED = 1, AU_GUARD_PROBING = 2 };

AUGuard *au_guard_create(const AUGuardConfig *config);
void au_guard_destroy(AUGuard *guard);
void au_guard_reset(AUGuard *guard);
/// Producer. Whether new windows should be sent to the model.
int32_t au_guard_should_submit(const AUGuard *guard);
/// Producer, once per committed window. `submitted`: it had a job; `neural`: it was committed with the model's output;
/// `infer_ema_seconds`: the worker's current average. Returns the state after the update.
int32_t au_guard_on_window(AUGuard *guard, int32_t submitted, int32_t neural, double infer_ema_seconds);
/// Producer. Forces a bypass now (e.g. the playout buffer ran low), with the usual cooldown and backoff.
void au_guard_trip(AUGuard *guard);
/// Any thread.
int32_t au_guard_state(const AUGuard *guard);
double au_guard_rtf(const AUGuard *guard);
int32_t au_guard_trips(const AUGuard *guard);

#ifdef __cplusplus
}
#endif

#endif

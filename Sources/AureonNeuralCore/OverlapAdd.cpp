// Overlap-add stitcher for block-based neural audio models. See AureonNeuralCore.h for the contract.
//
// Timeline (frames at the model's sample rate, absolute since the last reset):
//
//   window k covers [k·H, k·H + W)        it is *formed* once the input reaches k·H + W
//   segment m covers [m·H, (m+1)·H)       it is covered by windows m − W/H + 1 … m
//   segment m is *final* once window m is committed (all windows covering it are decided)
//
// Output sample n = x(n)·(1 − Σ w_k(n)) + Σ w_k(n)·y_k(n), the sums running over the neural windows covering n, where w is a
// periodic Hann window divided by the sum of its overlapping copies (so the copies add up to exactly 1 at every n). A fallback
// window therefore contributes w·x, and any mix of neural and fallback windows is a Hann-shaped crossfade. Where no neural
// window contributes, Σ w_k = 0 and the input Int32 is copied unchanged.

#include "AureonNeuralCore.h"

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>

namespace {

static_assert(std::atomic<int32_t>::is_always_lock_free, "slot state must be lock-free");
static_assert(std::atomic<int64_t>::is_always_lock_free, "counters must be lock-free");
static_assert(std::atomic<double>::is_always_lock_free, "timings must be lock-free");

constexpr double kFullScale = 2147483648.0;     // Int32 ↔ ±1.0
constexpr float kToFloat = 1.0f / 2147483648.0f;

template <typename T> T *alignedArray(size_t count) {
    void *p = nullptr;
    if (count == 0 || posix_memalign(&p, 64, count * sizeof(T)) != 0) return nullptr;
    std::memset(p, 0, count * sizeof(T));
    return static_cast<T *>(p);
}

inline int32_t toInt32(double v) {
    const double r = std::nearbyint(v);
    if (r >= 2147483647.0) return std::numeric_limits<int32_t>::max();
    if (r <= -2147483648.0) return std::numeric_limits<int32_t>::min();
    return static_cast<int32_t>(r);
}

inline int32_t nextPowerOfTwo(int64_t v) {
    int64_t p = 1;
    while (p < v) p <<= 1;
    return p > std::numeric_limits<int32_t>::max() ? 0 : static_cast<int32_t>(p);
}

struct Slot {
    std::atomic<int32_t> state{AU_SLOT_FREE};
    std::atomic<int64_t> seq{-1};      // window index of the job it holds
    float *in = nullptr;               // planar [channels][window]
    float *out = nullptr;
};

} // namespace

struct AUOla {
    int32_t C = 0, W = 0, H = 0, S = 0, L = 0;
    int32_t X = 0, mask = 0;           // history capacity (power of two) and its mask

    int32_t *hist = nullptr;           // X × C interleaved input, kept exact
    float *acc = nullptr;              // X × C interleaved Σ w·y of committed neural windows
    float *wsum = nullptr;             // X: Σ w of committed neural windows
    float *win = nullptr;              // W: normalised synthesis window
    float *slotMemory = nullptr;
    Slot *slots = nullptr;
    int32_t *jobSlot = nullptr;        // L: slot of each formed, uncommitted window (−1 = none), indexed by k mod L

    // producer-only state
    int64_t inputEnd = 0, formed = 0, committed = 0, finalized = 0, emitted = 0;
    bool finished = false;
    int32_t slotHint = 0;

    // statistics (written by one thread each, read by any)
    std::atomic<int64_t> windowsFormed{0}, windowsNeural{0}, windowsFallback{0}, jobsSubmitted{0}, jobsCompleted{0},
        jobsFailed{0}, jobsLate{0}, jobsNonFinite{0}, slotsExhausted{0};
    std::atomic<double> inferLast{0}, inferEma{-1};
};

namespace {

inline void bump(std::atomic<int64_t> &c) { c.store(c.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed); }

/// Producer: gives a slot back without using its result. Wait-free: the worker can move the state at most three times
/// (PENDING → RUNNING → DONE/FAILED), so the loop ends after at most four rounds. Returns true when the job was still in flight.
bool releaseSlot(AUOla *o, int32_t s) {
    Slot &slot = o->slots[s];
    for (int round = 0; round < 8; ++round) {
        int32_t st = slot.state.load(std::memory_order_acquire);
        if (st == AU_SLOT_DONE || st == AU_SLOT_FAILED) { slot.state.store(AU_SLOT_FREE, std::memory_order_release); return false; }
        if (st == AU_SLOT_PENDING) {
            int32_t e = AU_SLOT_PENDING;
            if (slot.state.compare_exchange_strong(e, AU_SLOT_FREE, std::memory_order_acq_rel)) return true;
        } else if (st == AU_SLOT_RUNNING) {
            int32_t e = AU_SLOT_RUNNING;
            if (slot.state.compare_exchange_strong(e, AU_SLOT_ABANDONED, std::memory_order_acq_rel)) return true;
        } else {
            return false;   // FREE / ABANDONED: not ours any more
        }
    }
    return false;
}

void formWindow(AUOla *o, int64_t k, bool submit, int32_t *submitted) {
    o->jobSlot[k % o->L] = -1;
    bump(o->windowsFormed);
    if (!submit) return;
    int32_t found = -1;
    for (int32_t t = 0; t < o->S; ++t) {
        const int32_t s = (o->slotHint + t) % o->S;
        if (o->slots[s].state.load(std::memory_order_acquire) == AU_SLOT_FREE) { found = s; break; }
    }
    if (found < 0) { bump(o->slotsExhausted); return; }
    Slot &slot = o->slots[found];
    const int64_t base = k * o->H;
    const int32_t C = o->C, W = o->W;
    for (int32_t n = 0; n < W; ++n) {
        const int32_t *src = o->hist + static_cast<size_t>((base + n) & o->mask) * C;
        for (int32_t c = 0; c < C; ++c) slot.in[static_cast<size_t>(c) * W + n] = static_cast<float>(src[c]) * kToFloat;
    }
    slot.seq.store(k, std::memory_order_relaxed);
    slot.state.store(AU_SLOT_PENDING, std::memory_order_release);   // publishes the input copy
    o->jobSlot[k % o->L] = found;
    o->slotHint = (found + 1) % o->S;
    bump(o->jobsSubmitted);
    if (submitted) ++*submitted;
}

bool allFinite(const float *p, size_t n) {
    for (size_t i = 0; i < n; ++i) if (!std::isfinite(p[i])) return false;
    return true;
}

void accumulate(AUOla *o, int64_t k, const float *y) {
    const int64_t base = k * o->H;
    const int32_t C = o->C, W = o->W;
    for (int32_t n = 0; n < W; ++n) {
        const float w = o->win[n];
        const size_t i = static_cast<size_t>((base + n) & o->mask);
        o->wsum[i] += w;
        float *a = o->acc + i * C;
        for (int32_t c = 0; c < C; ++c) a[c] += w * y[static_cast<size_t>(c) * W + n];
    }
}

} // namespace

extern "C" {

AUOla *au_ola_create(const AUOlaConfig *cfg) {
    if (!cfg) return nullptr;
    const int32_t C = cfg->channels, W = cfg->window, H = cfg->hop, S = cfg->slots, L = cfg->lookahead;
    if (C < 1 || C > 8 || W < 64 || W > 262144 || H < 1 || W % H != 0 || W / H < 2 || W / H > 16) return nullptr;
    if (S < 1 || S > 64 || L < 1 || L > 64) return nullptr;
    const int32_t X = nextPowerOfTwo(static_cast<int64_t>(W) + static_cast<int64_t>(L + 2) * H);
    if (X == 0) return nullptr;

    AUOla *o = new (std::nothrow) AUOla();
    if (!o) return nullptr;
    o->C = C; o->W = W; o->H = H; o->S = S; o->L = L; o->X = X; o->mask = X - 1;
    o->hist = alignedArray<int32_t>(static_cast<size_t>(X) * C);
    o->acc = alignedArray<float>(static_cast<size_t>(X) * C);
    o->wsum = alignedArray<float>(static_cast<size_t>(X));
    o->win = alignedArray<float>(static_cast<size_t>(W));
    o->slotMemory = alignedArray<float>(static_cast<size_t>(S) * 2 * C * W);
    o->slots = new (std::nothrow) Slot[S];
    o->jobSlot = alignedArray<int32_t>(static_cast<size_t>(L));
    if (!o->hist || !o->acc || !o->wsum || !o->win || !o->slotMemory || !o->slots || !o->jobSlot) { au_ola_destroy(o); return nullptr; }
    for (int32_t s = 0; s < S; ++s) {
        o->slots[s].in = o->slotMemory + static_cast<size_t>(s) * 2 * C * W;
        o->slots[s].out = o->slots[s].in + static_cast<size_t>(C) * W;
    }
    for (int32_t i = 0; i < L; ++i) o->jobSlot[i] = -1;

    // Periodic Hann, divided by the sum of its copies shifted by multiples of the hop: the copies then add up to 1 exactly
    // (up to float rounding) for any overlap factor, so a model that returns its input reproduces the input.
    const double pi = 3.14159265358979323846;
    double *h = new (std::nothrow) double[W];
    double *norm = new (std::nothrow) double[H];
    if (!h || !norm) { delete[] h; delete[] norm; au_ola_destroy(o); return nullptr; }
    for (int32_t n = 0; n < W; ++n) h[n] = 0.5 - 0.5 * std::cos(2.0 * pi * n / W);
    for (int32_t r = 0; r < H; ++r) { double s = 0; for (int32_t j = r; j < W; j += H) s += h[j]; norm[r] = s; }
    for (int32_t n = 0; n < W; ++n) o->win[n] = static_cast<float>(h[n] / norm[n % H]);
    delete[] h; delete[] norm;
    return o;
}

void au_ola_destroy(AUOla *o) {
    if (!o) return;
    std::free(o->hist); std::free(o->acc); std::free(o->wsum); std::free(o->win); std::free(o->slotMemory); std::free(o->jobSlot);
    delete[] o->slots;
    delete o;
}

void au_ola_reset(AUOla *o) {
    for (int64_t k = o->committed; k < o->formed; ++k) {
        const int32_t s = o->jobSlot[k % o->L];
        if (s >= 0) releaseSlot(o, s);
        o->jobSlot[k % o->L] = -1;
    }
    std::memset(o->acc, 0, static_cast<size_t>(o->X) * o->C * sizeof(float));
    std::memset(o->wsum, 0, static_cast<size_t>(o->X) * sizeof(float));
    o->inputEnd = o->formed = o->committed = o->finalized = o->emitted = 0;
    o->finished = false;
}

int32_t au_ola_input_space(const AUOla *o) {
    if (o->finished) return 0;
    const int64_t byLookahead = (o->committed + o->L - 1) * o->H + o->W - o->inputEnd;
    const int64_t byHistory = o->X - (o->inputEnd - o->emitted);
    const int64_t s = byLookahead < byHistory ? byLookahead : byHistory;
    return s > 0 ? static_cast<int32_t>(s) : 0;
}

int32_t au_ola_push(AUOla *o, const int32_t *src, int32_t frames, int32_t submit, int32_t *submitted) {
    if (submitted) *submitted = 0;
    if (frames <= 0 || !src) return 0;
    const int32_t space = au_ola_input_space(o);
    const int32_t n = frames < space ? frames : space;
    const int32_t C = o->C;
    for (int32_t i = 0; i < n; ++i) {
        std::memcpy(o->hist + static_cast<size_t>((o->inputEnd + i) & o->mask) * C, src + static_cast<size_t>(i) * C, sizeof(int32_t) * C);
    }
    o->inputEnd += n;
    while (o->formed * o->H + o->W <= o->inputEnd) { formWindow(o, o->formed, submit != 0, submitted); ++o->formed; }
    return n;
}

int32_t au_ola_poll(const AUOla *o) {
    if (o->committed >= o->formed) return AU_WINDOW_NONE;
    const int32_t s = o->jobSlot[o->committed % o->L];
    if (s < 0) return AU_WINDOW_UNSUBMITTED;
    return o->slots[s].state.load(std::memory_order_acquire);
}

int32_t au_ola_commit(AUOla *o, int32_t accept) {
    if (o->committed >= o->formed) return -1;
    const int64_t k = o->committed;
    const int32_t s = o->jobSlot[k % o->L];
    int32_t neural = 0;
    if (s >= 0) {
        Slot &slot = o->slots[s];
        const int32_t st = slot.state.load(std::memory_order_acquire);
        if (st == AU_SLOT_DONE && accept) {
            // DONE is terminal for the worker: the output is stable until we free the slot.
            if (allFinite(slot.out, static_cast<size_t>(o->C) * o->W)) { accumulate(o, k, slot.out); neural = 1; }
            else bump(o->jobsNonFinite);
            slot.state.store(AU_SLOT_FREE, std::memory_order_release);
        } else if (releaseSlot(o, s)) {
            bump(o->jobsLate);
        }
        o->jobSlot[k % o->L] = -1;
    }
    ++o->committed;
    o->finalized = o->committed * o->H;
    bump(neural ? o->windowsNeural : o->windowsFallback);
    return neural;
}

void au_ola_finish(AUOla *o) {
    while (o->committed < o->formed) au_ola_commit(o, 0);
    o->finished = true;
    o->finalized = o->inputEnd;
}

int32_t au_ola_ready_frames(const AUOla *o) {
    const int64_t r = o->finalized - o->emitted;
    return r > 0 ? static_cast<int32_t>(r) : 0;
}

int32_t au_ola_pull(AUOla *o, int32_t *dst, int32_t frames) {
    const int32_t ready = au_ola_ready_frames(o);
    const int32_t n = frames < ready ? frames : ready;
    const int32_t C = o->C;
    for (int32_t i = 0; i < n; ++i) {
        const size_t idx = static_cast<size_t>((o->emitted + i) & o->mask);
        const int32_t *x = o->hist + idx * C;
        int32_t *d = dst + static_cast<size_t>(i) * C;
        const float ws = o->wsum[idx];
        if (ws == 0.0f) {
            std::memcpy(d, x, sizeof(int32_t) * C);   // untouched by the model: bit-exact
        } else {
            const double keep = 1.0 - static_cast<double>(ws);
            float *a = o->acc + idx * C;
            for (int32_t c = 0; c < C; ++c) {
                d[c] = toInt32(static_cast<double>(x[c]) * keep + static_cast<double>(a[c]) * kFullScale);
                a[c] = 0.0f;
            }
            o->wsum[idx] = 0.0f;
        }
    }
    o->emitted += n;
    return n;
}

int32_t au_ola_worker_take(AUOla *o) {
    for (int attempt = 0; attempt <= o->S; ++attempt) {
        int32_t best = -1;
        int64_t bestSeq = std::numeric_limits<int64_t>::max();
        for (int32_t s = 0; s < o->S; ++s) {
            if (o->slots[s].state.load(std::memory_order_acquire) != AU_SLOT_PENDING) continue;
            const int64_t q = o->slots[s].seq.load(std::memory_order_relaxed);
            if (q < bestSeq) { bestSeq = q; best = s; }
        }
        if (best < 0) return -1;
        int32_t e = AU_SLOT_PENDING;
        if (o->slots[best].state.compare_exchange_strong(e, AU_SLOT_RUNNING, std::memory_order_acq_rel)) return best;
    }
    return -1;
}

float *au_ola_slot_input(AUOla *o, int32_t s) { return (s >= 0 && s < o->S) ? o->slots[s].in : nullptr; }
float *au_ola_slot_output(AUOla *o, int32_t s) { return (s >= 0 && s < o->S) ? o->slots[s].out : nullptr; }

void au_ola_worker_finish(AUOla *o, int32_t s, int32_t ok, double seconds) {
    if (s < 0 || s >= o->S) return;
    Slot &slot = o->slots[s];
    int32_t e = AU_SLOT_RUNNING;
    if (!slot.state.compare_exchange_strong(e, ok ? AU_SLOT_DONE : AU_SLOT_FAILED, std::memory_order_acq_rel)) {
        slot.state.store(AU_SLOT_FREE, std::memory_order_release);   // the producer abandoned it while we ran
    }
    bump(o->jobsCompleted);
    if (!ok) bump(o->jobsFailed);
    o->inferLast.store(seconds, std::memory_order_relaxed);
    const double ema = o->inferEma.load(std::memory_order_relaxed);
    o->inferEma.store(ema < 0 ? seconds : ema + 0.2 * (seconds - ema), std::memory_order_relaxed);
}

void au_ola_stats(const AUOla *o, AUOlaStats *out) {
    if (!out) return;
    out->windowsFormed = o->windowsFormed.load(std::memory_order_relaxed);
    out->windowsNeural = o->windowsNeural.load(std::memory_order_relaxed);
    out->windowsFallback = o->windowsFallback.load(std::memory_order_relaxed);
    out->jobsSubmitted = o->jobsSubmitted.load(std::memory_order_relaxed);
    out->jobsCompleted = o->jobsCompleted.load(std::memory_order_relaxed);
    out->jobsFailed = o->jobsFailed.load(std::memory_order_relaxed);
    out->jobsLate = o->jobsLate.load(std::memory_order_relaxed);
    out->jobsNonFinite = o->jobsNonFinite.load(std::memory_order_relaxed);
    out->slotsExhausted = o->slotsExhausted.load(std::memory_order_relaxed);
    out->inferLastSeconds = o->inferLast.load(std::memory_order_relaxed);
    const double ema = o->inferEma.load(std::memory_order_relaxed);
    out->inferEmaSeconds = ema < 0 ? 0 : ema;
}

int32_t au_ola_channels(const AUOla *o) { return o->C; }
int32_t au_ola_window(const AUOla *o) { return o->W; }
int32_t au_ola_hop(const AUOla *o) { return o->H; }
int32_t au_ola_slots(const AUOla *o) { return o->S; }
int32_t au_ola_latency_frames(const AUOla *o) { return o->W + (o->L - 1) * o->H; }

} // extern "C"

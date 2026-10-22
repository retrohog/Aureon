// Circuit breaker for the neural upscaler. Producer-thread state machine; the public state is mirrored into atomics for the UI.
//
//   ACTIVE ──(too slow, or too many late/failed windows)──► BYPASSED ──(cooldown of audio time elapsed)──► PROBING
//     ▲                                                                                                        │
//     └──────────────────────────(probeWindows windows without tripping)───────────────────────────────────────┘
//
// Every trip in a row doubles the cooldown (up to maxCooldownSeconds); a successful probe resets it. Time is counted in audio
// (committed windows × hop), so a paused player does not "wait out" a cooldown.

#include "AureonNeuralCore.h"

#include <atomic>
#include <new>

struct AUGuard {
    AUGuardConfig cfg{};
    int32_t state = AU_GUARD_ACTIVE;
    uint64_t missMask = 0;          // bit i set = the i-th most recent submitted window missed
    uint64_t spanMask = 0;
    int32_t sinceStart = 0;         // submitted windows since the last (re)start
    int32_t probed = 0;
    double audioTime = 0, resumeAt = 0, cooldown = 0;
    std::atomic<int32_t> publicState{AU_GUARD_ACTIVE};
    std::atomic<int32_t> trips{0};
    std::atomic<double> rtf{0};
};

namespace {

void enterBypass(AUGuard *g) {
    g->state = AU_GUARD_BYPASSED;
    g->resumeAt = g->audioTime + g->cooldown;
    g->cooldown = g->cooldown * 2 > g->cfg.maxCooldownSeconds ? g->cfg.maxCooldownSeconds : g->cooldown * 2;
    g->missMask = 0;
    g->sinceStart = 0;
    g->trips.store(g->trips.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    g->publicState.store(g->state, std::memory_order_relaxed);
}

} // namespace

extern "C" {

AUGuard *au_guard_create(const AUGuardConfig *c) {
    if (!c || !(c->hopSeconds > 0) || !(c->tripRTF > 0) || c->missSpan < 1 || c->missSpan > 64 || c->missLimit < 1 ||
        c->warmupWindows < 0 || c->probeWindows < 1 || !(c->cooldownSeconds > 0) || c->maxCooldownSeconds < c->cooldownSeconds) return nullptr;
    AUGuard *g = new (std::nothrow) AUGuard();
    if (!g) return nullptr;
    g->cfg = *c;
    g->spanMask = c->missSpan == 64 ? ~0ULL : ((1ULL << c->missSpan) - 1);
    au_guard_reset(g);
    return g;
}

void au_guard_destroy(AUGuard *g) { delete g; }

void au_guard_reset(AUGuard *g) {
    g->state = AU_GUARD_ACTIVE;
    g->missMask = 0; g->sinceStart = 0; g->probed = 0;
    g->audioTime = 0; g->resumeAt = 0; g->cooldown = g->cfg.cooldownSeconds;
    g->publicState.store(AU_GUARD_ACTIVE, std::memory_order_relaxed);
}

int32_t au_guard_should_submit(const AUGuard *g) { return g->state != AU_GUARD_BYPASSED; }

int32_t au_guard_on_window(AUGuard *g, int32_t submitted, int32_t neural, double ema) {
    g->audioTime += g->cfg.hopSeconds;
    const double r = ema > 0 ? ema / g->cfg.hopSeconds : 0;
    g->rtf.store(r, std::memory_order_relaxed);
    if (g->state == AU_GUARD_BYPASSED) {
        if (g->audioTime >= g->resumeAt - 1e-9) {   // audio time is a running sum of hops: allow for its rounding
            g->state = AU_GUARD_PROBING; g->probed = 0; g->sinceStart = 0; g->missMask = 0;
            g->publicState.store(g->state, std::memory_order_relaxed);
        }
        return g->state;
    }
    if (!submitted) return g->state;               // nothing learned about the model from this window
    ++g->sinceStart;
    g->missMask = ((g->missMask << 1) | (neural ? 0ULL : 1ULL)) & g->spanMask;
    const int misses = __builtin_popcountll(g->missMask);
    const bool tooSlow = g->sinceStart > g->cfg.warmupWindows && r > g->cfg.tripRTF;
    if (misses >= g->cfg.missLimit || tooSlow) { enterBypass(g); return g->state; }
    if (g->state == AU_GUARD_PROBING && ++g->probed >= g->cfg.probeWindows) {
        g->state = AU_GUARD_ACTIVE;
        g->cooldown = g->cfg.cooldownSeconds;
        g->publicState.store(g->state, std::memory_order_relaxed);
    }
    return g->state;
}

void au_guard_trip(AUGuard *g) { if (g->state != AU_GUARD_BYPASSED) enterBypass(g); }

int32_t au_guard_state(const AUGuard *g) { return g->publicState.load(std::memory_order_relaxed); }
double au_guard_rtf(const AUGuard *g) { return g->rtf.load(std::memory_order_relaxed); }
int32_t au_guard_trips(const AUGuard *g) { return g->trips.load(std::memory_order_relaxed); }

} // extern "C"

// AureonAtomics: lock-free 64-bit atomic operations on plain memory, as static inline functions.
//
// They stand in for the Swift `Synchronization.Atomic` type, which needs macOS 15. Every call compiles to a single hardware
// atomic instruction (or a load-linked / store-conditional loop); none of them allocates, locks or enters the Objective-C or
// Swift runtimes, so they are safe on the audio render thread. The memory order is a plain int taking the AU_ORDER_* values;
// with a constant argument it folds away after inlining. Orders that make no sense for an operation are strengthened to the
// nearest valid one (an acquire-release store becomes a release store, a release load becomes an acquire load).

#ifndef AUREON_ATOMICS_H
#define AUREON_ATOMICS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    AU_ORDER_RELAXED = 0,
    AU_ORDER_ACQUIRE = 1,
    AU_ORDER_RELEASE = 2,
    AU_ORDER_ACQ_REL = 3,
    AU_ORDER_SEQ_CST = 4
};

static inline uint64_t au_atomic_load(const uint64_t *p, int order) {
    switch (order) {
    case AU_ORDER_RELAXED: return __atomic_load_n(p, __ATOMIC_RELAXED);
    case AU_ORDER_SEQ_CST: return __atomic_load_n(p, __ATOMIC_SEQ_CST);
    default:               return __atomic_load_n(p, __ATOMIC_ACQUIRE);
    }
}

static inline void au_atomic_store(uint64_t *p, uint64_t v, int order) {
    switch (order) {
    case AU_ORDER_RELAXED: __atomic_store_n(p, v, __ATOMIC_RELAXED); break;
    case AU_ORDER_SEQ_CST: __atomic_store_n(p, v, __ATOMIC_SEQ_CST); break;
    default:               __atomic_store_n(p, v, __ATOMIC_RELEASE); break;
    }
}

static inline uint64_t au_atomic_exchange(uint64_t *p, uint64_t v, int order) {
    switch (order) {
    case AU_ORDER_RELAXED: return __atomic_exchange_n(p, v, __ATOMIC_RELAXED);
    case AU_ORDER_ACQUIRE: return __atomic_exchange_n(p, v, __ATOMIC_ACQUIRE);
    case AU_ORDER_RELEASE: return __atomic_exchange_n(p, v, __ATOMIC_RELEASE);
    case AU_ORDER_ACQ_REL: return __atomic_exchange_n(p, v, __ATOMIC_ACQ_REL);
    default:               return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST);
    }
}

// Wrapping add; returns the previous value.
static inline uint64_t au_atomic_fetch_add(uint64_t *p, uint64_t v, int order) {
    switch (order) {
    case AU_ORDER_RELAXED: return __atomic_fetch_add(p, v, __ATOMIC_RELAXED);
    case AU_ORDER_ACQUIRE: return __atomic_fetch_add(p, v, __ATOMIC_ACQUIRE);
    case AU_ORDER_RELEASE: return __atomic_fetch_add(p, v, __ATOMIC_RELEASE);
    case AU_ORDER_ACQ_REL: return __atomic_fetch_add(p, v, __ATOMIC_ACQ_REL);
    default:               return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST);
    }
}

// Strong compare-exchange. On failure *expected receives the value that was found.
static inline bool au_atomic_compare_exchange(uint64_t *p, uint64_t *expected, uint64_t desired, int order) {
    switch (order) {
    case AU_ORDER_RELAXED: return __atomic_compare_exchange_n(p, expected, desired, false, __ATOMIC_RELAXED, __ATOMIC_RELAXED);
    case AU_ORDER_ACQUIRE: return __atomic_compare_exchange_n(p, expected, desired, false, __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE);
    case AU_ORDER_RELEASE: return __atomic_compare_exchange_n(p, expected, desired, false, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
    case AU_ORDER_ACQ_REL: return __atomic_compare_exchange_n(p, expected, desired, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    default:               return __atomic_compare_exchange_n(p, expected, desired, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    }
}

#ifdef __cplusplus
}
#endif

#endif

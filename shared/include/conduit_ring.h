// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Timeline ring: lock-free SPSC ring addressed by absolute sample time.
// Single C implementation shared by the C++ driver (TimelineRing wrapper) and
// the Swift app (via the CConduit module), so both sides of a shared-memory
// ring are guaranteed to agree on layout and algorithm.
//
// All functions are real-time safe except conduit_ring_create/reset.
#ifndef CONDUIT_RING_H
#define CONDUIT_RING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#define CONDUIT_STATIC_ASSERT(c, m) static_assert(c, m)
#else
#define CONDUIT_STATIC_ASSERT(c, m) _Static_assert(c, m)
#endif

#define CONDUIT_RING_MAGIC 0x43524E47u /* 'CRNG' */
#define CONDUIT_RING_VERSION 1u
#define CONDUIT_CACHE_LINE 64

typedef struct __attribute__((aligned(CONDUIT_CACHE_LINE))) {
    uint32_t magic, version, channels, capacityFrames, mask;
} ConduitRingConfig;

typedef struct __attribute__((aligned(CONDUIT_CACHE_LINE))) {
    int64_t  writeBegin; /* exclusive end of range being written (seqlock) */
    int64_t  writeEnd;   /* exclusive end of fully published data */
    uint64_t gapFrames;  /* frames zero-filled because the producer skipped time */
} ConduitRingProducer;

typedef struct __attribute__((aligned(CONDUIT_CACHE_LINE))) {
    uint64_t underrunFrames; /* requested but never produced */
    uint64_t lappedFrames;   /* produced but overwritten before the copy finished */
} ConduitRingConsumer;

typedef struct {
    ConduitRingConfig   config;
    ConduitRingProducer producer;
    ConduitRingConsumer consumer;
} ConduitRingHeader;

CONDUIT_STATIC_ASSERT(sizeof(ConduitRingConfig) == 64, "config line");
CONDUIT_STATIC_ASSERT(sizeof(ConduitRingProducer) == 64, "producer line");
CONDUIT_STATIC_ASSERT(sizeof(ConduitRingConsumer) == 64, "consumer line");
CONDUIT_STATIC_ASSERT(sizeof(ConduitRingHeader) == 192, "ring header");

/* Per-process handle onto ring memory (which may be shared between processes). */
typedef struct {
    ConduitRingHeader* hdr;
    float*             data;
} ConduitRing;

static inline size_t conduit_ring_bytes(uint32_t channels, uint32_t capacityFrames) {
    return sizeof(ConduitRingHeader) + (size_t)channels * capacityFrames * sizeof(float);
}

static inline bool conduit_ring_attach(void* mem, ConduitRing* out) {
    out->hdr = NULL;
    out->data = NULL;
    if (!mem || ((uintptr_t)mem & (CONDUIT_CACHE_LINE - 1))) return false;
    ConduitRingHeader* h = (ConduitRingHeader*)mem;
    if (h->config.magic != CONDUIT_RING_MAGIC || h->config.version != CONDUIT_RING_VERSION) return false;
    out->hdr = h;
    out->data = (float*)((uint8_t*)mem + sizeof(ConduitRingHeader));
    return true;
}

/* Control plane: zero audio, rewind timeline. Pre-faults all pages. No IO may be in flight. */
static inline void conduit_ring_reset(ConduitRing* r) {
    memset(r->data, 0, (size_t)r->hdr->config.channels * r->hdr->config.capacityFrames * sizeof(float));
    __atomic_store_n(&r->hdr->producer.writeBegin, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&r->hdr->producer.writeEnd, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&r->hdr->producer.gapFrames, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&r->hdr->consumer.underrunFrames, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&r->hdr->consumer.lappedFrames, 0, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
}

/* Control plane: initialise fresh memory. capacityFrames must be a power of two. */
static inline bool conduit_ring_create(void* mem, uint32_t channels, uint32_t capacityFrames, ConduitRing* out) {
    out->hdr = NULL;
    out->data = NULL;
    if (!mem || channels == 0 || capacityFrames == 0 || (capacityFrames & (capacityFrames - 1)) ||
        ((uintptr_t)mem & (CONDUIT_CACHE_LINE - 1)))
        return false;
    ConduitRingHeader* h = (ConduitRingHeader*)mem;
    memset(h, 0, sizeof(*h));
    h->config.channels = channels;
    h->config.capacityFrames = capacityFrames;
    h->config.mask = capacityFrames - 1;
    h->config.version = CONDUIT_RING_VERSION;
    h->config.magic = CONDUIT_RING_MAGIC;
    if (!conduit_ring_attach(mem, out)) return false;
    conduit_ring_reset(out);
    return true;
}

static inline float* conduit__slot(const ConduitRing* r, int64_t absFrame) {
    return r->data + (size_t)((uint64_t)absFrame & r->hdr->config.mask) * r->hdr->config.channels;
}

/* Copy [absStart, absStart+frames) between linear memory and the ring, in <= 2 runs. */
static inline void conduit__copy(const ConduitRing* r, int64_t absStart, uint32_t frames, float* linear, bool toRing) {
    const uint32_t ch = r->hdr->config.channels, cap = r->hdr->config.capacityFrames;
    const uint32_t first = cap - (uint32_t)((uint64_t)absStart & r->hdr->config.mask);
    const uint32_t n1 = frames < first ? frames : first;
    float* s1 = conduit__slot(r, absStart);
    if (toRing) memcpy(s1, linear, (size_t)n1 * ch * sizeof(float)); else memcpy(linear, s1, (size_t)n1 * ch * sizeof(float));
    if (n1 < frames) {
        float* s2 = conduit__slot(r, absStart + n1);
        if (toRing) memcpy(s2, linear + (size_t)n1 * ch, (size_t)(frames - n1) * ch * sizeof(float));
        else memcpy(linear + (size_t)n1 * ch, s2, (size_t)(frames - n1) * ch * sizeof(float));
    }
}
static inline void conduit__zero_ring(const ConduitRing* r, int64_t absStart, uint32_t frames) {
    const uint32_t ch = r->hdr->config.channels, cap = r->hdr->config.capacityFrames;
    const uint32_t first = cap - (uint32_t)((uint64_t)absStart & r->hdr->config.mask);
    const uint32_t n1 = frames < first ? frames : first;
    memset(conduit__slot(r, absStart), 0, (size_t)n1 * ch * sizeof(float));
    if (n1 < frames) memset(conduit__slot(r, absStart + n1), 0, (size_t)(frames - n1) * ch * sizeof(float));
}

/* PRODUCER (real-time safe). `start` is the absolute sample time of the first frame. */
static inline void conduit_ring_write(ConduitRing* r, int64_t start, uint32_t frames, const float* src) {
    const uint32_t ch = r->hdr->config.channels;
    const int64_t cap = r->hdr->config.capacityFrames;
    if (frames == 0) return;
    if ((int64_t)frames > cap) { /* keep only the newest `cap` frames */
        const uint32_t drop = frames - (uint32_t)cap;
        src += (size_t)drop * ch;
        start += drop;
        frames = (uint32_t)cap;
    }
    const int64_t end = start + frames;
    const int64_t prevEnd = __atomic_load_n(&r->hdr->producer.writeEnd, __ATOMIC_RELAXED);

    __atomic_store_n(&r->hdr->producer.writeBegin, end, __ATOMIC_RELAXED); /* seqlock: announce first */
    __atomic_thread_fence(__ATOMIC_RELEASE);

    if (start > prevEnd) { /* skipped time: stale audio from an older lap must not replay */
        int64_t gap = start - prevEnd;
        if (gap > cap) gap = cap;
        conduit__zero_ring(r, start - gap, (uint32_t)gap);
        __atomic_fetch_add(&r->hdr->producer.gapFrames, (uint64_t)gap, __ATOMIC_RELAXED);
    }
    conduit__copy(r, start, frames, (float*)src, true);
    __atomic_store_n(&r->hdr->producer.writeEnd, end, __ATOMIC_RELEASE);
}

/* CONSUMER (real-time safe). Unproduced/overwritten frames read as silence.
   Returns the number of frames carrying real audio. */
static inline uint32_t conduit_ring_read(ConduitRing* r, int64_t start, uint32_t frames, float* dst) {
    const uint32_t ch = r->hdr->config.channels;
    const int64_t cap = r->hdr->config.capacityFrames;
    if (frames == 0) return 0;
    const int64_t end = start + frames;
    const int64_t w = __atomic_load_n(&r->hdr->producer.writeEnd, __ATOMIC_ACQUIRE);

    int64_t lo = w - cap; if (start > lo) lo = start;
    int64_t hi = end < w ? end : w;
    if (hi <= lo) {
        memset(dst, 0, (size_t)frames * ch * sizeof(float));
        __atomic_fetch_add(&r->hdr->consumer.underrunFrames, frames, __ATOMIC_RELAXED);
        return 0;
    }
    memset(dst, 0, (size_t)(lo - start) * ch * sizeof(float));                      /* head: older than ring holds */
    conduit__copy(r, lo, (uint32_t)(hi - lo), dst + (size_t)(lo - start) * ch, false);
    memset(dst + (size_t)(hi - start) * ch, 0, (size_t)(end - hi) * ch * sizeof(float)); /* tail: not produced yet */

    __atomic_thread_fence(__ATOMIC_ACQUIRE); /* seqlock validation */
    const int64_t wb = __atomic_load_n(&r->hdr->producer.writeBegin, __ATOMIC_RELAXED);
    const int64_t safeLo = wb - cap;
    int64_t valid = hi - lo;
    if (safeLo > lo) {
        int64_t bad = (safeLo < hi ? safeLo : hi) - lo;
        memset(dst + (size_t)(lo - start) * ch, 0, (size_t)bad * ch * sizeof(float));
        valid -= bad;
        __atomic_fetch_add(&r->hdr->consumer.lappedFrames, (uint64_t)bad, __ATOMIC_RELAXED);
    }
    const int64_t missing = (lo - start) + (end - hi);
    if (missing > 0) __atomic_fetch_add(&r->hdr->consumer.underrunFrames, (uint64_t)missing, __ATOMIC_RELAXED);
    return (uint32_t)valid;
}

static inline uint32_t conduit_ring_channels(const ConduitRing* r) { return r->hdr->config.channels; }
static inline uint64_t conduit_ring_underruns(const ConduitRing* r) { return __atomic_load_n(&r->hdr->consumer.underrunFrames, __ATOMIC_RELAXED); }
static inline uint64_t conduit_ring_lapped(const ConduitRing* r) { return __atomic_load_n(&r->hdr->consumer.lappedFrames, __ATOMIC_RELAXED); }
static inline uint64_t conduit_ring_gaps(const ConduitRing* r) { return __atomic_load_n(&r->hdr->producer.gapFrames, __ATOMIC_RELAXED); }

#ifdef __cplusplus
}
#endif
#endif /* CONDUIT_RING_H */

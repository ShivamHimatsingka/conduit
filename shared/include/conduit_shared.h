// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Layout of the memory region shared between the driver (inside coreaudiod)
// and the app. Plain integers only; every cross-process access goes through
// the accessors below, which use relaxed/acquire/release atomics (__atomic
// builtins work identically in C, C++ and Swift's C importer). Floats are
// stored as their IEEE-754 bit patterns in uint32_t so they can be atomic.
//
//   region = [ ConduitShared (control + telemetry + clock) | pad | app ring ]
//
// Writers: app  -> ConduitControl     (gain, mute, solo, matrix)
//          driver -> ConduitMeters, ConduitClock
//          app  -> app ring producer, driver -> app ring consumer
#ifndef CONDUIT_SHARED_H
#define CONDUIT_SHARED_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "conduit_ring.h"

#ifdef __cplusplus
extern "C" {
#endif

#define CONDUIT_SHARED_MAGIC 0x444E4F43u /* 'CODN' */
#define CONDUIT_SHARED_VERSION 1u
#define CONDUIT_MAX_CHANNELS 64u
#define CONDUIT_RING_OFFSET_ALIGN 16384u /* Apple Silicon page size */
#define CONDUIT_MACH_MSG_HELLO 0x434F0001
#define CONDUIT_MACH_MSG_HELLO_REPLY 0x434F0101

typedef struct __attribute__((aligned(64))) {
    uint32_t magic, version, headerBytes, regionBytes;
    uint32_t channels, maxChannels, ringOffset, ringBytes;
    uint32_t ringFrames;
} ConduitSharedHeader;

/* Driver-written. Seqlock: `seq` is odd while the driver is updating. */
typedef struct __attribute__((aligned(64))) {
    uint32_t seq;
    uint32_t sampleRate;
    uint32_t running;
    uint32_t reserved;
    uint64_t anchorHostTime;        /* mach_absolute_time() at sample time 0; 0 when stopped */
    uint64_t hostTicksPerFrameBits; /* IEEE-754 double bits */
    uint64_t seed;
} ConduitClock;

/* App-written control plane. */
typedef struct __attribute__((aligned(64))) {
    uint64_t muteMask;     /* input strips */
    uint64_t soloMask;     /* input strips */
    uint64_t busMuteMask;  /* output buses */
    uint32_t generation;   /* bumped on every change (informational) */
    uint32_t reserved;
    uint32_t inGain[CONDUIT_MAX_CHANNELS];  /* float bits, linear */
    uint32_t busGain[CONDUIT_MAX_CHANNELS]; /* float bits, linear */
    uint32_t matrix[CONDUIT_MAX_CHANNELS * CONDUIT_MAX_CHANNELS]; /* [bus * MAX + input], float bits */
} ConduitControl;

/* Driver-written telemetry. Peaks are max-hold until the reader takes them. */
typedef struct __attribute__((aligned(64))) {
    uint64_t blockCount;
    uint32_t inPeak[CONDUIT_MAX_CHANNELS];   /* pre-fader, what apps send into the device */
    uint32_t inMsq[CONDUIT_MAX_CHANNELS];    /* mean square of the last block */
    uint32_t busPeak[CONDUIT_MAX_CHANNELS];  /* post-fader, what the device input delivers */
    uint32_t busMsq[CONDUIT_MAX_CHANNELS];
} ConduitMeters;

typedef struct {
    ConduitSharedHeader header;
    ConduitClock        clock;
    ConduitControl      control;
    ConduitMeters       meters;
} ConduitShared;

#ifdef __cplusplus
static_assert(sizeof(ConduitShared) % 64 == 0, "alignment");
#else
_Static_assert(sizeof(ConduitShared) % 64 == 0, "alignment");
#endif

/* ---- float <-> bits -------------------------------------------------- */
static inline uint32_t conduit_f2b(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }
static inline float conduit_b2f(uint32_t b) { float f; memcpy(&f, &b, 4); return f; }
static inline uint32_t conduit_ld32(const uint32_t* p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }
static inline void conduit_st32(uint32_t* p, uint32_t v) { __atomic_store_n(p, v, __ATOMIC_RELAXED); }
static inline uint64_t conduit_ld64(const uint64_t* p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }

static inline uint32_t conduit_region_bytes(uint32_t ringBytes, uint32_t* ringOffsetOut) {
    uint32_t off = ((uint32_t)sizeof(ConduitShared) + CONDUIT_RING_OFFSET_ALIGN - 1) & ~(CONDUIT_RING_OFFSET_ALIGN - 1);
    if (ringOffsetOut) *ringOffsetOut = off;
    return (off + ringBytes + CONDUIT_RING_OFFSET_ALIGN - 1) & ~(CONDUIT_RING_OFFSET_ALIGN - 1);
}

/* Driver: fill defaults (unity gains, identity matrix). Control plane only. */
static inline void conduit_shared_init(ConduitShared* s, uint32_t channels, uint32_t ringFrames, uint32_t ringBytes,
                                       uint32_t ringOffset, uint32_t regionBytes) {
    memset(s, 0, sizeof(*s));
    s->header.headerBytes = sizeof(ConduitShared);
    s->header.regionBytes = regionBytes;
    s->header.channels = channels;
    s->header.maxChannels = CONDUIT_MAX_CHANNELS;
    s->header.ringOffset = ringOffset;
    s->header.ringBytes = ringBytes;
    s->header.ringFrames = ringFrames;
    for (uint32_t i = 0; i < CONDUIT_MAX_CHANNELS; ++i) {
        s->control.inGain[i] = conduit_f2b(1.0f);
        s->control.busGain[i] = conduit_f2b(1.0f);
        s->control.matrix[i * CONDUIT_MAX_CHANNELS + i] = conduit_f2b(1.0f);
    }
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    s->header.version = CONDUIT_SHARED_VERSION;
    __atomic_store_n(&s->header.magic, CONDUIT_SHARED_MAGIC, __ATOMIC_RELEASE);
}

static inline uint32_t conduit_channels(const ConduitShared* s) { return s->header.channels; }

/* ---- control plane (app writes, driver reads on the RT thread) ------- */
static inline bool conduit_ch_ok(const ConduitShared* s, uint32_t ch) { return ch < s->header.channels; }
static inline void conduit__bump(ConduitShared* s) { __atomic_fetch_add(&s->control.generation, 1, __ATOMIC_RELAXED); }

static inline float conduit_get_in_gain(const ConduitShared* s, uint32_t ch) { return conduit_b2f(conduit_ld32(&s->control.inGain[ch & (CONDUIT_MAX_CHANNELS - 1)])); }
static inline float conduit_get_bus_gain(const ConduitShared* s, uint32_t ch) { return conduit_b2f(conduit_ld32(&s->control.busGain[ch & (CONDUIT_MAX_CHANNELS - 1)])); }
static inline float conduit_get_matrix(const ConduitShared* s, uint32_t bus, uint32_t in) {
    return conduit_b2f(conduit_ld32(&s->control.matrix[(bus & (CONDUIT_MAX_CHANNELS - 1)) * CONDUIT_MAX_CHANNELS + (in & (CONDUIT_MAX_CHANNELS - 1))]));
}
static inline bool conduit_set_in_gain(ConduitShared* s, uint32_t ch, float g) {
    if (!conduit_ch_ok(s, ch)) return false;
    conduit_st32(&s->control.inGain[ch], conduit_f2b(g)); conduit__bump(s); return true;
}
static inline bool conduit_set_bus_gain(ConduitShared* s, uint32_t ch, float g) {
    if (!conduit_ch_ok(s, ch)) return false;
    conduit_st32(&s->control.busGain[ch], conduit_f2b(g)); conduit__bump(s); return true;
}
static inline bool conduit_set_matrix(ConduitShared* s, uint32_t bus, uint32_t in, float g) {
    if (!conduit_ch_ok(s, bus) || !conduit_ch_ok(s, in)) return false;
    conduit_st32(&s->control.matrix[bus * CONDUIT_MAX_CHANNELS + in], conduit_f2b(g)); conduit__bump(s); return true;
}
static inline uint64_t conduit__bit(uint32_t ch) { return (uint64_t)1 << (ch & 63u); }
static inline bool conduit__set_mask(ConduitShared* s, uint64_t* mask, uint32_t ch, bool on) {
    if (!conduit_ch_ok(s, ch)) return false;
    if (on) __atomic_fetch_or(mask, conduit__bit(ch), __ATOMIC_RELAXED);
    else __atomic_fetch_and(mask, ~conduit__bit(ch), __ATOMIC_RELAXED);
    conduit__bump(s); return true;
}
static inline bool conduit_set_mute(ConduitShared* s, uint32_t ch, bool on) { return conduit__set_mask(s, &s->control.muteMask, ch, on); }
static inline bool conduit_set_solo(ConduitShared* s, uint32_t ch, bool on) { return conduit__set_mask(s, &s->control.soloMask, ch, on); }
static inline bool conduit_set_bus_mute(ConduitShared* s, uint32_t ch, bool on) { return conduit__set_mask(s, &s->control.busMuteMask, ch, on); }
static inline uint64_t conduit_mute_mask(const ConduitShared* s) { return conduit_ld64(&s->control.muteMask); }
static inline uint64_t conduit_solo_mask(const ConduitShared* s) { return conduit_ld64(&s->control.soloMask); }
static inline uint64_t conduit_bus_mute_mask(const ConduitShared* s) { return conduit_ld64(&s->control.busMuteMask); }

/* ---- telemetry (driver writes on RT thread, app reads at 60 fps) ----- */
/* Driver: max-hold. Single writer, so load/compare/store is race-free against itself. */
static inline void conduit_meter_hold(uint32_t* p, float v) {
    if (v > conduit_b2f(conduit_ld32(p))) conduit_st32(p, conduit_f2b(v));
}
static inline float conduit_take_in_peak(ConduitShared* s, uint32_t ch) { return conduit_b2f(__atomic_exchange_n(&s->meters.inPeak[ch & 63u], 0u, __ATOMIC_RELAXED)); }
static inline float conduit_take_bus_peak(ConduitShared* s, uint32_t ch) { return conduit_b2f(__atomic_exchange_n(&s->meters.busPeak[ch & 63u], 0u, __ATOMIC_RELAXED)); }
static inline float conduit_in_msq(const ConduitShared* s, uint32_t ch) { return conduit_b2f(conduit_ld32(&s->meters.inMsq[ch & 63u])); }
static inline float conduit_bus_msq(const ConduitShared* s, uint32_t ch) { return conduit_b2f(conduit_ld32(&s->meters.busMsq[ch & 63u])); }
static inline uint64_t conduit_block_count(const ConduitShared* s) { return conduit_ld64(&s->meters.blockCount); }

/* ---- device clock ----------------------------------------------------- */
typedef struct {
    uint32_t sampleRate;
    bool     running;
    uint64_t anchorHostTime;
    double   hostTicksPerFrame;
    uint64_t seed;
} ConduitClockSnapshot;

/* Driver (control plane): publish clock state under the seqlock. */
static inline void conduit_clock_publish(ConduitShared* s, uint32_t rate, bool running, uint64_t anchor, double ticksPerFrame, uint64_t seed) {
    uint32_t q = __atomic_load_n(&s->clock.seq, __ATOMIC_RELAXED);
    __atomic_store_n(&s->clock.seq, q + 1, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    s->clock.sampleRate = rate;
    s->clock.running = running ? 1 : 0;
    s->clock.anchorHostTime = anchor;
    uint64_t bits; memcpy(&bits, &ticksPerFrame, 8);
    s->clock.hostTicksPerFrameBits = bits;
    s->clock.seed = seed;
    __atomic_store_n(&s->clock.seq, q + 2, __ATOMIC_RELEASE);
}

/* App: consistent snapshot (retries while the driver is mid-update). */
static inline bool conduit_clock_read(const ConduitShared* s, ConduitClockSnapshot* out) {
    for (int tries = 0; tries < 1000; ++tries) {
        uint32_t q1 = __atomic_load_n(&s->clock.seq, __ATOMIC_ACQUIRE);
        if (q1 & 1u) continue;
        out->sampleRate = s->clock.sampleRate;
        out->running = s->clock.running != 0;
        out->anchorHostTime = s->clock.anchorHostTime;
        uint64_t bits = s->clock.hostTicksPerFrameBits; memcpy(&out->hostTicksPerFrame, &bits, 8);
        out->seed = s->clock.seed;
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(&s->clock.seq, __ATOMIC_RELAXED) == q1) return true;
    }
    return false;
}

/* Device sample time corresponding to a host time (valid only while running). */
static inline int64_t conduit_clock_sample_at(const ConduitClockSnapshot* c, uint64_t hostTime) {
    if (!c->running || c->hostTicksPerFrame <= 0.0) return 0;
    double d = (double)((int64_t)(hostTime - c->anchorHostTime));
    return (int64_t)(d / c->hostTicksPerFrame);
}

/* Attach to the app->driver injection ring inside a mapped region. */
static inline bool conduit_shared_app_ring(ConduitShared* s, ConduitRing* out) {
    if (conduit_ld32(&s->header.magic) != CONDUIT_SHARED_MAGIC) return false;
    return conduit_ring_attach((uint8_t*)s + s->header.ringOffset, out);
}

#ifdef __cplusplus
}
#endif
#endif /* CONDUIT_SHARED_H */

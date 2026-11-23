// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
#include "conduit_tap_engine.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SCRATCH_FRAMES 4096u
#define RESYNC_TOLERANCE_FRAMES 48
#define AN_MASK (CONDUIT_ANALYSIS_FRAMES - 1)

enum { FLAG_MUTE = 1u, FLAG_MONO = 2u };

struct ConduitTapEngine {
    ConduitShared* shared;
    ConduitRing*   ring;
    uint32_t       channels; /* device channel count (ring width) */

    /* control plane -> RT (relaxed atomics) */
    uint32_t sourceCount, tapCount, latencyFrames;
    uint32_t kind[CONDUIT_MAX_TAP_SOURCES], ordinal[CONDUIT_MAX_TAP_SOURCES], flags[CONDUIT_MAX_TAP_SOURCES];
    uint32_t sendBits[CONDUIT_MAX_TAP_SOURCES][CONDUIT_MAX_PAIRS];

    /* RT -> control plane */
    uint32_t peakBits[CONDUIT_MAX_TAP_SOURCES];
    uint64_t stats[5];
    uint64_t anCount[CONDUIT_MAX_TAP_SOURCES];       /* total mono samples ever written */
    float*   analysis;                               /* [source][CONDUIT_ANALYSIS_FRAMES] */

    /* RT-private */
    float    prevSend[CONDUIT_MAX_TAP_SOURCES][CONDUIT_MAX_PAIRS];
    float*   scratch; /* SCRATCH_FRAMES * channels */
    int64_t  next;
    uint64_t lastSeed;
    bool     synced;
};

static inline uint32_t ld(const uint32_t* p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }
static inline void st(uint32_t* p, uint32_t v) { __atomic_store_n(p, v, __ATOMIC_RELAXED); }
static inline void bump(uint64_t* p, uint64_t n) { __atomic_fetch_add(p, n, __ATOMIC_RELAXED); }

ConduitTapEngine* conduit_tap_engine_create(ConduitShared* shared, ConduitRing* ring) {
    ConduitTapEngine* e = (ConduitTapEngine*)calloc(1, sizeof(*e));
    if (!e) return NULL;
    e->shared = shared;
    e->ring = ring;
    e->channels = (shared && ring) ? conduit_ring_channels(ring) : 0;
    e->analysis = (float*)calloc((size_t)CONDUIT_MAX_TAP_SOURCES * CONDUIT_ANALYSIS_FRAMES, sizeof(float));
    if (e->channels) e->scratch = (float*)calloc((size_t)SCRATCH_FRAMES * e->channels, sizeof(float));
    if (!e->analysis || (e->channels && !e->scratch)) { free(e->analysis); free(e->scratch); free(e); return NULL; }
    e->latencyFrames = 192;
    return e;
}

void conduit_tap_engine_destroy(ConduitTapEngine* e) {
    free(e->analysis);
    free(e->scratch);
    free(e);
}

void conduit_tap_engine_configure(ConduitTapEngine* e, uint32_t count, uint32_t tapCount) {
    st(&e->tapCount, tapCount > CONDUIT_MAX_TAP_SOURCES ? CONDUIT_MAX_TAP_SOURCES : tapCount);
    st(&e->sourceCount, count > CONDUIT_MAX_TAP_SOURCES ? CONDUIT_MAX_TAP_SOURCES : count);
}
void conduit_tap_engine_set_source(ConduitTapEngine* e, uint32_t s, ConduitSourceKind kind, uint32_t ordinal) {
    if (s >= CONDUIT_MAX_TAP_SOURCES) return;
    st(&e->kind[s], (uint32_t)kind);
    st(&e->ordinal[s], ordinal);
}
void conduit_tap_engine_set_latency(ConduitTapEngine* e, uint32_t frames) { st(&e->latencyFrames, frames); }
void conduit_tap_engine_set_flags(ConduitTapEngine* e, uint32_t s, bool mute, bool mono) {
    if (s < CONDUIT_MAX_TAP_SOURCES) st(&e->flags[s], (mute ? FLAG_MUTE : 0u) | (mono ? FLAG_MONO : 0u));
}
void conduit_tap_engine_set_send(ConduitTapEngine* e, uint32_t s, uint32_t pair, float gain) {
    if (s < CONDUIT_MAX_TAP_SOURCES && pair < CONDUIT_MAX_PAIRS) st(&e->sendBits[s][pair], conduit_f2b(gain));
}

float conduit_tap_engine_take_peak(ConduitTapEngine* e, uint32_t s) {
    return s < CONDUIT_MAX_TAP_SOURCES ? conduit_b2f(__atomic_exchange_n(&e->peakBits[s], 0u, __ATOMIC_RELAXED)) : 0.0f;
}

bool conduit_tap_engine_latest(ConduitTapEngine* e, uint32_t s, float* dst, uint32_t frames) {
    if (s >= CONDUIT_MAX_TAP_SOURCES || frames == 0 || frames > CONDUIT_ANALYSIS_FRAMES / 2) return false;
    const float* a = e->analysis + (size_t)s * CONDUIT_ANALYSIS_FRAMES;
    const uint64_t n = __atomic_load_n(&e->anCount[s], __ATOMIC_ACQUIRE);
    if (n < frames) return false;
    for (uint32_t i = 0; i < frames; ++i) dst[i] = a[(n - frames + i) & AN_MASK];
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    /* If the writer lapped us while copying, the snapshot may be torn: report failure. */
    return __atomic_load_n(&e->anCount[s], __ATOMIC_RELAXED) - n <= CONDUIT_ANALYSIS_FRAMES - frames;
}

uint64_t conduit_tap_engine_stat(const ConduitTapEngine* e, ConduitTapStat which) {
    return which <= CONDUIT_STAT_LAST_FRAMES ? __atomic_load_n(&e->stats[which], __ATOMIC_RELAXED) : 0;
}

static inline uint32_t frames_of(const AudioBuffer* b) {
    return b->mNumberChannels ? b->mDataByteSize / (b->mNumberChannels * (uint32_t)sizeof(float)) : 0;
}

/* Locate source s's buffer in this cycle's input list, or NULL. */
static const AudioBuffer* source_buffer(const ConduitTapEngine* e, const AudioBufferList* in, uint32_t s, uint32_t taps) {
    const UInt32 nb = in->mNumberBuffers;
    UInt32 idx;
    if (ld(&e->kind[s]) == CONDUIT_SOURCE_TAP) {
        if (nb < taps) return NULL;
        idx = nb - taps + ld(&e->ordinal[s]);
    } else {
        idx = ld(&e->ordinal[s]);
    }
    if (idx >= nb || !in->mBuffers[idx].mData || in->mBuffers[idx].mNumberChannels == 0) return NULL;
    return &in->mBuffers[idx];
}

/* Peak + analysis feed, for every source, always (also in monitor mode). */
static void analyse(ConduitTapEngine* e, uint32_t s, const AudioBuffer* b, uint32_t frames) {
    const float* x = (const float*)b->mData;
    const uint32_t nch = b->mNumberChannels;
    float* a = e->analysis + (size_t)s * CONDUIT_ANALYSIS_FRAMES;
    uint64_t n = __atomic_load_n(&e->anCount[s], __ATOMIC_RELAXED);
    float pk = 0.0f;
    for (uint32_t f = 0; f < frames; ++f) {
        const float L = x[(size_t)f * nch], R = nch > 1 ? x[(size_t)f * nch + 1] : L;
        const float aL = fabsf(L), aR = fabsf(R);
        pk = aL > pk ? aL : pk;
        pk = aR > pk ? aR : pk;
        a[(n + f) & AN_MASK] = 0.5f * (L + R);
    }
    __atomic_store_n(&e->anCount[s], n + frames, __ATOMIC_RELEASE);
    conduit_meter_hold(&e->peakBits[s], pk);
}

/* Sum every source into its sends and write the result at device time `start`. */
static void mix_and_write(ConduitTapEngine* e, const AudioBufferList* in, uint32_t count, uint32_t taps, uint32_t frames, int64_t start) {
    const uint32_t ch = e->channels, pairs = (ch + 1) / 2;
    const float inv = 1.0f / (float)frames;

    for (uint32_t done = 0; done < frames;) {
        const uint32_t n = (frames - done) < SCRATCH_FRAMES ? (frames - done) : SCRATCH_FRAMES;
        memset(e->scratch, 0, (size_t)n * ch * sizeof(float));

        for (uint32_t s = 0; s < count; ++s) {
            const AudioBuffer* b = source_buffer(e, in, s, taps);
            if (!b || frames_of(b) < done + n) continue;
            const float* x = (const float*)b->mData;
            const uint32_t nch = b->mNumberChannels, fl = ld(&e->flags[s]);
            const bool mono = (fl & FLAG_MONO) != 0, muted = (fl & FLAG_MUTE) != 0;

            for (uint32_t p = 0; p < pairs && p < CONDUIT_MAX_PAIRS; ++p) {
                const float g0 = e->prevSend[s][p];
                const float g1 = muted ? 0.0f : conduit_b2f(ld(&e->sendBits[s][p]));
                if (g0 == 0.0f && g1 == 0.0f) continue;
                const float step = (g1 - g0) * inv;
                const uint32_t cL = 2 * p, cR = 2 * p + 1;
                for (uint32_t f = 0; f < n; ++f) {
                    const float* fr = x + (size_t)(done + f) * nch;
                    float L = fr[0], R = nch > 1 ? fr[1] : L;
                    if (mono) L = R = 0.5f * (L + R);
                    const float g = g0 + step * (float)(done + f + 1);
                    float* y = e->scratch + (size_t)f * ch;
                    y[cL] += L * g;
                    if (cR < ch) y[cR] += R * g;
                }
            }
        }
        conduit_ring_write(e->ring, start + done, n, e->scratch);
        done += n;
    }
    for (uint32_t s = 0; s < count; ++s) {
        const bool muted = (ld(&e->flags[s]) & FLAG_MUTE) != 0;
        for (uint32_t p = 0; p < CONDUIT_MAX_PAIRS; ++p) e->prevSend[s][p] = muted ? 0.0f : conduit_b2f(ld(&e->sendBits[s][p]));
    }
}

OSStatus conduit_tap_ioproc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                            const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                            void* clientData) {
    (void)device; (void)outputTime;
    ConduitTapEngine* e = (ConduitTapEngine*)clientData;

    /* The aggregate also contains the Conduit device's output stream. Core Audio does not
       guarantee zeroed output buffers, and stale data would be mixed into the loopback. */
    if (output)
        for (UInt32 i = 0; i < output->mNumberBuffers; ++i)
            if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);

    const uint32_t count = ld(&e->sourceCount), taps = ld(&e->tapCount);
    if (!input || count == 0) return kAudioHardwareNoError;

    uint32_t frames = 0;
    bool missing = false;
    for (uint32_t s = 0; s < count; ++s) {
        const AudioBuffer* b = source_buffer(e, input, s, taps);
        if (!b) { missing = true; continue; }
        const uint32_t n = frames_of(b);
        if (frames == 0 || n < frames) frames = n;
        analyse(e, s, b, n);
    }
    if (missing) bump(&e->stats[CONDUIT_STAT_SHORT], 1);
    if (frames == 0) return kAudioHardwareNoError;
    __atomic_store_n(&e->stats[CONDUIT_STAT_LAST_FRAMES], frames, __ATOMIC_RELAXED);
    bump(&e->stats[CONDUIT_STAT_CYCLES], 1);

    if (!e->ring || !e->shared || !e->scratch) return kAudioHardwareNoError;

    ConduitClockSnapshot clk;
    if (!conduit_clock_read(e->shared, &clk) || !clk.running) {
        bump(&e->stats[CONDUIT_STAT_IDLE], 1);
        return kAudioHardwareNoError;
    }

    /* Device time of the first captured frame, plus a latency budget so the driver has not
       already consumed that slot. */
    const uint64_t host = (inputTime && (inputTime->mFlags & kAudioTimeStampHostTimeValid)) ? inputTime->mHostTime : now->mHostTime;
    const int64_t ideal = conduit_clock_sample_at(&clk, host) + (int64_t)ld(&e->latencyFrames);

    /* Keep writes contiguous; re-align only when the clocks disagree by more than a few frames
       (or after a driver restart), so ordinary jitter never creates gaps or overlaps. */
    const int64_t err = ideal - e->next;
    if (!e->synced || clk.seed != e->lastSeed || err > RESYNC_TOLERANCE_FRAMES || err < -RESYNC_TOLERANCE_FRAMES) {
        if (e->synced) bump(&e->stats[CONDUIT_STAT_RESYNCS], 1);
        e->next = ideal;
        e->lastSeed = clk.seed;
        e->synced = true;
    }
    mix_and_write(e, input, count, taps, frames, e->next);
    e->next += frames;
    return kAudioHardwareNoError;
}

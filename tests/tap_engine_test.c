// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Drives the real conduit_tap_ioproc with synthetic aggregate-device buffers
// (device stream + two taps) against a real shared region and verifies what
// lands in the injection ring: routing, gain, mono fold, latency offset,
// contiguity, resync, mute, zeroed outputs and idle-when-driver-stopped.
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "conduit_tap_engine.h"

#define CH 16
#define FRAMES 128
static int fails = 0;
#define CHECK(c) do { if (!(c)) { if (fails++ < 10) printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)
static int near(float a, float b) { return fabsf(a - b) < 1e-5f; }

typedef struct { AudioBufferList* list; } Bufs;
static AudioBufferList* make_list(UInt32 n) { return calloc(1, sizeof(AudioBufferList) + (n - 1) * sizeof(AudioBuffer)); }

int main(void) {
    // Region with a real header + injection ring, exactly as the driver builds it.
    uint32_t ringBytes = (uint32_t)conduit_ring_bytes(CH, 32768), off = 0;
    uint32_t total = conduit_region_bytes(ringBytes, &off);
    void* mem = NULL; posix_memalign(&mem, 16384, total); memset(mem, 0, total);
    ConduitShared* sh = mem;
    conduit_shared_init(sh, CH, 32768, ringBytes, off, total);
    ConduitRing ring; CHECK(conduit_ring_create((uint8_t*)mem + off, CH, 32768, &ring));

    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    const double tpf = 1e9 * tb.denom / tb.numer / 48000.0;
    const uint64_t anchor = mach_absolute_time();
    conduit_clock_publish(sh, 48000, true, anchor, tpf, 7);

    ConduitTapEngine* e = conduit_tap_engine_create(sh, &ring);
    CHECK(e != NULL);
    conduit_tap_engine_set_latency(e, 192);
    // source 0: tap #0 -> pair 1 (ch 2,3) at -6 dB
    // source 1: tap #1, mono-folded -> pair 4 (ch 8,9) at 1.0 AND pair 5 (ch 10,11) at 0.5  (multi-destination)
    // source 2: hardware mic (aggregate buffer 1, mono) -> pair 0 (ch 0,1)
    conduit_tap_engine_set_source(e, 0, CONDUIT_SOURCE_TAP, 0);
    conduit_tap_engine_set_source(e, 1, CONDUIT_SOURCE_TAP, 1);
    conduit_tap_engine_set_source(e, 2, CONDUIT_SOURCE_HARDWARE, 1);
    conduit_tap_engine_configure(e, 3, 2);
    conduit_tap_engine_set_send(e, 0, 1, 0.5f);
    conduit_tap_engine_set_flags(e, 1, false, true);
    conduit_tap_engine_set_send(e, 1, 4, 1.0f);
    conduit_tap_engine_set_send(e, 1, 5, 0.5f);
    conduit_tap_engine_set_send(e, 2, 0, 1.0f);

    // Aggregate input: [Conduit device stream (16ch)] [mic mono] [tap0 stereo] [tap1 stereo]
    AudioBufferList* in = make_list(4);
    float* mic = malloc(FRAMES * sizeof(float));
    for (int f = 0; f < FRAMES; ++f) mic[f] = 0.3f;
    float* dev = calloc(FRAMES * CH, sizeof(float));
    float* t0 = malloc(FRAMES * 2 * sizeof(float));
    float* t1 = malloc(FRAMES * 2 * sizeof(float));
    for (int f = 0; f < FRAMES; ++f) { t0[2*f] = 0.8f; t0[2*f+1] = 0.4f; t1[2*f] = 0.2f; t1[2*f+1] = 0.6f; }
    in->mNumberBuffers = 4;
    in->mBuffers[0] = (AudioBuffer){CH, FRAMES * CH * 4, dev};
    in->mBuffers[1] = (AudioBuffer){1, FRAMES * 4, mic};
    in->mBuffers[2] = (AudioBuffer){2, FRAMES * 2 * 4, t0};
    in->mBuffers[3] = (AudioBuffer){2, FRAMES * 2 * 4, t1};

    AudioBufferList* out = make_list(1);
    float* outbuf = malloc(FRAMES * CH * sizeof(float));
    for (int i = 0; i < FRAMES * CH; ++i) outbuf[i] = 9.0f;  // garbage that must be cleared
    out->mNumberBuffers = 1;
    out->mBuffers[0] = (AudioBuffer){CH, FRAMES * CH * 4, outbuf};

    AudioTimeStamp now = {0}, inT = {0};
    inT.mFlags = kAudioTimeStampHostTimeValid;
    const uint64_t t_first = anchor + (uint64_t)(tpf * 48000.0);  // 1 s after the anchor
    inT.mHostTime = t_first; now.mHostTime = t_first;

    ConduitClockSnapshot snap; conduit_clock_read(sh, &snap);
    const int64_t start0 = conduit_clock_sample_at(&snap, t_first) + 192;

    // 0) warm-up cycle one buffer earlier: gains ramp from their initial unity to the target
    //    inside it, so the measured cycle below sees steady state.
    inT.mHostTime = now.mHostTime = t_first - (uint64_t)(tpf * FRAMES);
    conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    inT.mHostTime = now.mHostTime = t_first;

    // 1) first measured cycle (contiguous with the warm-up)
    OSStatus rc = conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    CHECK(rc == 0);
    CHECK(near(outbuf[0], 0.0f) && near(outbuf[FRAMES * CH - 1], 0.0f));  // outputs zeroed
    float* rd = malloc(FRAMES * 2 * CH * sizeof(float));
    ConduitRing rdr = ring;
    CHECK(conduit_ring_read(&rdr, start0, FRAMES, rd) == FRAMES);
    for (int f = 0; f < FRAMES; ++f) {
        const float* r = rd + f * CH;
        CHECK(near(r[2], 0.4f) && near(r[3], 0.2f));          // 0.8*0.5, 0.4*0.5
        CHECK(near(r[8], 0.4f) && near(r[9], 0.4f));          // mono fold 0.5*(0.2+0.6), both channels
        CHECK(near(r[10], 0.2f) && near(r[11], 0.2f));        // second destination at 0.5
        CHECK(near(r[0], 0.3f) && near(r[1], 0.3f));          // mono mic duplicated to the pair
        CHECK(near(r[4], 0) && near(r[12], 0) && near(r[15], 0));
    }
    CHECK(near(conduit_tap_engine_take_peak(e, 0), 0.8f) && near(conduit_tap_engine_take_peak(e, 1), 0.6f));
    CHECK(near(conduit_tap_engine_take_peak(e, 2), 0.3f));
    {   // analysis feed: pre-fader mono mix of L/R, newest samples last
        float an[256];
        CHECK(conduit_tap_engine_latest(e, 0, an, 256));
        CHECK(near(an[255], 0.6f) && near(an[0], 0.6f));       // 0.5*(0.8+0.4)
        CHECK(!conduit_tap_engine_latest(e, 0, an, CONDUIT_ANALYSIS_FRAMES));  // more than allowed
    }
    CHECK(conduit_tap_engine_stat(e, CONDUIT_STAT_LAST_FRAMES) == FRAMES);

    // 2) next cycle exactly one buffer later: contiguous, no resync
    inT.mHostTime = now.mHostTime = t_first + (uint64_t)(tpf * FRAMES);
    conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    CHECK(conduit_tap_engine_stat(e, CONDUIT_STAT_RESYNCS) == 0);
    CHECK(conduit_ring_read(&rdr, start0, 2 * FRAMES, rd) == 2 * FRAMES);
    CHECK(near(rd[(2 * FRAMES - 1) * CH + 2], 0.4f));

    // 3) jitter of a few frames must not resync; a big jump must
    inT.mHostTime = now.mHostTime = t_first + (uint64_t)(tpf * (2 * FRAMES + 10));
    conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    CHECK(conduit_tap_engine_stat(e, CONDUIT_STAT_RESYNCS) == 0);
    inT.mHostTime = now.mHostTime = t_first + (uint64_t)(tpf * 20000.0);
    conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    CHECK(conduit_tap_engine_stat(e, CONDUIT_STAT_RESYNCS) == 1);

    // 4) mute: gain ramps to zero within one block, then stays silent
    conduit_tap_engine_set_flags(e, 0, true, false);
    inT.mHostTime = now.mHostTime = t_first + (uint64_t)(tpf * (20000.0 + FRAMES));
    conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    inT.mHostTime = now.mHostTime = t_first + (uint64_t)(tpf * (20000.0 + 2 * FRAMES));
    conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    conduit_clock_read(sh, &snap);
    int64_t s2 = conduit_clock_sample_at(&snap, inT.mHostTime) + 192;
    CHECK(conduit_ring_read(&rdr, s2, FRAMES, rd) == FRAMES);
    CHECK(near(rd[2], 0) && near(rd[3], 0) && near(rd[8], 0.4f) && near(rd[0], 0.3f));  // source 0 muted, others still routed

    // 5) driver clock stopped -> engine idles, writes nothing
    conduit_clock_publish(sh, 48000, false, 0, tpf, 7);
    uint64_t gapsBefore = conduit_ring_gaps(&ring);
    conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    CHECK(conduit_tap_engine_stat(e, CONDUIT_STAT_IDLE) == 1);
    CHECK(conduit_ring_gaps(&ring) == gapsBefore);

    // 6) too few buffers (taps missing) is survivable
    in->mNumberBuffers = 1;  // aggregate lost its taps and mic
    conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    CHECK(conduit_tap_engine_stat(e, CONDUIT_STAT_SHORT) == 1);

    // 7) monitor-only engine (no driver) still meters
    ConduitTapEngine* m = conduit_tap_engine_create(NULL, NULL);
    conduit_tap_engine_set_source(m, 0, CONDUIT_SOURCE_TAP, 0);
    conduit_tap_engine_set_source(m, 1, CONDUIT_SOURCE_TAP, 1);
    conduit_tap_engine_configure(m, 2, 2);
    in->mNumberBuffers = 4;
    conduit_tap_ioproc(1, &now, in, &inT, out, &inT, m);
    CHECK(near(conduit_tap_engine_take_peak(m, 0), 0.8f));
    conduit_tap_engine_destroy(m);

    conduit_tap_engine_destroy(e);
    printf(fails ? "tap engine FAILED (%d)\n" : "tap engine PASSED\n", fails);
    return fails != 0;
}

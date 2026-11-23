// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Offline latency / drift characterisation. Runs the *same* measurement code the live `conduit-bench` uses
// (conduit_bench.c) against the real driver binary and the real tap engine, on a simulated HAL schedule, so
// the numbers are deterministic and need no audio hardware.
//
//  A. Driver loopback: impulse round trip at 44.1/48/96 kHz x buffer sizes 32..1024.
//  B. Tap-injection budget: how large must `latencyFrames` be so a captured frame is never injected into a slot
//     the driver has already read? Latency from capture to availability for each budget.
//  C. Clock handling in the injection engine: timestamp jitter, uncompensated drift (ppm), driver restart / rate change.
//
//   bench_offline <path/to/Conduit.driver/Contents/MacOS/Conduit>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>

#include "conduit_bench.h"
#include "conduit_tap_engine.h"

static constexpr uint32_t kCh = 16;
static constexpr AudioObjectID kDevice = 2, kIn = 3, kOut = 4;
static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { std::printf("  FAIL %s:%d: %s  ", __FILE__, __LINE__, #c); std::printf(__VA_ARGS__); std::printf("\n"); ++failures; } } while (0)

static int gRequests = 0; static UInt64 gAction = 0;
static OSStatus hostChanged(AudioServerPlugInHostRef, AudioObjectID, UInt32, const AudioObjectPropertyAddress*) { return 0; }
static OSStatus hostRequest(AudioServerPlugInHostRef, AudioObjectID, UInt64 a, void*) { gAction = a; ++gRequests; return 0; }
static const AudioServerPlugInHostInterface kHost{hostChanged, nullptr, nullptr, nullptr, hostRequest};

static AudioServerPlugInDriverInterface* vt; static AudioServerPlugInDriverRef drv;

static bool setRate(double r) {
    AudioObjectPropertyAddress a{kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    const int before = gRequests;
    if (vt->SetPropertyData(drv, kDevice, 0, &a, 0, nullptr, sizeof(r), &r)) return false;
    for (int i = 0; i < 300 && gRequests == before; ++i) usleep(10000);   // the driver hops to a queue before asking the host
    return gRequests > before && vt->PerformDeviceConfigurationChange(drv, kDevice, gAction, nullptr) == 0;
}

// ------------------------------------------------------------------ A
static void driverLoopback() {
    std::printf("A. driver loopback round trip (impulse bench against the real driver, simulated HAL: output one buffer ahead, input one buffer behind)\n");
    std::printf("   rate    buffer   impulses  sample-offset  round-trip   expected (2 x buffer)\n");
    for (double rate : {44100.0, 48000.0, 96000.0}) {
        CHECK(setRate(rate), "rate switch to %.0f", rate);
        for (uint32_t N : {32u, 64u, 128u, 480u, 1024u}) {
            vt->StartIO(drv, kDevice, 1);
            const double tpf = 24e6 / rate;  // arbitrary but exact host-tick scale for the simulation
            ConduitBench* b = conduit_bench_create(0, std::max<uint32_t>(uint32_t(rate / 10), 6 * N), 64, 0.5f, tpf);
            std::vector<float> out(N * kCh), in(N * kCh);
            AudioServerPlugInIOCycleInfo cyc{};
            const int cycles = int(1.5 * rate / N);
            for (int k = 0; k < cycles; ++k) {
                const int64_t W = int64_t(k) * N;
                cyc.mInputTime.mSampleTime = double(W - int64_t(N));
                cyc.mOutputTime.mSampleTime = double(W + int64_t(N));
                vt->DoIOOperation(drv, kDevice, kIn, 1, kAudioServerPlugInIOOperationReadInput, N, &cyc, in.data(), nullptr);
                conduit_bench_cycle(b, out.data(), kCh, N, double(W + N), uint64_t((W + N) * tpf), in.data(), kCh, N, double(W - N),
                                    uint64_t(std::max<int64_t>(0, W - N) * tpf), uint64_t(W * tpf));
                vt->DoIOOperation(drv, kDevice, kOut, 1, kAudioServerPlugInIOOperationWriteMix, N, &cyc, out.data(), nullptr);
            }
            const uint32_t sched = conduit_bench_scheduled(b), done = conduit_bench_completed(b);
            double off = 0, trip = 0; ConduitBenchRecord r;
            for (uint32_t i = 0; i < done; ++i) { conduit_bench_record(b, i, &r); off = std::max(off, std::fabs(double(r.detectSample - r.writeSample)));
                trip = std::max(trip, std::fabs(double(r.detectCallbackHost - r.writeCallbackHost) / tpf - 2.0 * N)); }
            const double ms = 2.0 * N / rate * 1000;
            std::printf("   %6.0f  %6u   %3u/%-3u   %6.0f fr     %7.3f ms   %7.3f ms\n", rate, N, done, sched, off, ms, ms);
            CHECK(sched >= 8 && done == sched, "impulses lost (%u of %u)", sched - done, sched);
            CHECK(off == 0, "driver added %.0f frames of offset", off);
            CHECK(trip < 1.0, "round trip deviates from 2 buffers by %.2f frames", trip);
            conduit_bench_destroy(b);
            vt->StopIO(drv, kDevice, 1);
        }
    }
    setRate(48000);
}

// ------------------------------------------------------------------ shared fixture for B and C
struct Fixture {
    void* mem; ConduitShared* sh; ConduitRing ring; ConduitTapEngine* e = nullptr;
    double tpf; uint32_t rate; uint64_t seed = 1;
    std::vector<float> dev, tap, scratch;
    AudioBufferList* in; AudioBufferList* out; std::vector<float> outBuf;

    explicit Fixture(uint32_t rate_, uint32_t N, uint32_t latency) : tpf(24e6 / rate_), rate(rate_) {
        uint32_t off = 0, rb = (uint32_t)conduit_ring_bytes(kCh, 32768), total = conduit_region_bytes(rb, &off);
        posix_memalign(&mem, 16384, total); std::memset(mem, 0, total);
        sh = (ConduitShared*)mem; conduit_shared_init(sh, kCh, 32768, rb, off, total);
        conduit_ring_create((uint8_t*)mem + off, kCh, 32768, &ring);
        publish(true);
        e = conduit_tap_engine_create(sh, &ring);
        conduit_tap_engine_set_latency(e, latency);
        conduit_tap_engine_set_source(e, 0, CONDUIT_SOURCE_TAP, 0);
        conduit_tap_engine_configure(e, 1, 1);
        conduit_tap_engine_set_send(e, 0, 0, 1.0f);        // pair 0 -> device channels 0,1
        dev.assign(N * kCh, 0.f); tap.assign(N * 2, 0.f); outBuf.assign(N * kCh, 0.f);
        in = (AudioBufferList*)calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer)); out = (AudioBufferList*)calloc(1, sizeof(AudioBufferList));
        in->mNumberBuffers = 2; in->mBuffers[0] = {kCh, N * kCh * 4, dev.data()}; in->mBuffers[1] = {2, N * 8, tap.data()};
        out->mNumberBuffers = 1; out->mBuffers[0] = {kCh, N * kCh * 4, outBuf.data()};
    }
    ~Fixture() { conduit_tap_engine_destroy(e); free(mem); free(in); free(out); }
    void publish(bool running, uint64_t anchor = 0) { conduit_clock_publish(sh, rate, running, anchor, tpf, seed); }

    // One capture cycle: `N` frames captured over device time [start, start+N), data in tap[]. `hostOffsetTicks` perturbs the stamp.
    void cycle(int64_t startSample, uint32_t N, int64_t hostOffsetTicks = 0) {
        AudioTimeStamp now{}, inT{};
        inT.mFlags = kAudioTimeStampHostTimeValid;
        inT.mHostTime = uint64_t(int64_t(double(startSample + 1000000) * tpf) + hostOffsetTicks);   // +1e6 keeps host > anchor 0
        now.mHostTime = inT.mHostTime + uint64_t(N * tpf);
        conduit_tap_ioproc(1, &now, in, &inT, out, &inT, e);
    }
};
// Device time t is host tick (t + 1e6) * tpf, i.e. the clock anchor sits 1e6 frames before sample 0.
static void anchorClock(Fixture& f) { f.publish(true, uint64_t(1e6 * f.tpf)); }

// ------------------------------------------------------------------ B
static void injectionBudget() {
    std::printf("\nB. tap -> device injection budget (consumer reads each slot at the end of its buffer; worst-case ordering: consumer runs before the engine)\n");
    std::printf("   buffer  budget(L)  lost  latency capture->readable, frames (min / mean / max)   ms @48k mean/max\n");
    const uint32_t rate = 48000;
    for (uint32_t N : {32u, 64u, 128u, 256u}) {
        for (int32_t L : {int32_t(N) - 1, int32_t(N), int32_t(N) + 32, int32_t(N) + 64}) {
            int lost = 0; double sum = 0, mn = 1e9, mx = 0; int found = 0;
            for (uint32_t j = 0; j < N; j += (N >= 64 ? 3 : 1)) {   // impulse at every capture offset j
                Fixture f(rate, N, uint32_t(L));
                anchorClock(f);
                const int64_t W = 16 * int64_t(N);                  // wall time, in frames, at the end of the capture buffer
                // warm-up cycle so the engine is synced and contiguous
                std::fill(f.tap.begin(), f.tap.end(), 0.f);
                f.cycle(W - 2 * N, N);
                std::fill(f.tap.begin(), f.tap.end(), 0.f);
                f.tap[j * 2] = 1.0f;
                // consumer window for the same wall instant is read BEFORE the engine runs (worst case)
                std::vector<float> win(N * kCh);
                bool seen = false; int64_t seenAt = 0;
                auto consume = [&](int64_t wall) {
                    conduit_ring_read(&f.ring, wall - N, N, win.data());
                    for (uint32_t i = 0; i < N && !seen; ++i) if (win[i * kCh] > 0.5f) { seen = true; seenAt = wall; }
                };
                consume(W);
                f.cycle(W - N, N);                                   // capture block [W-N, W)
                for (int k = 1; k <= 6 && !seen; ++k) consume(W + int64_t(k) * N);
                if (!seen) { ++lost; continue; }
                const double lat = double(seenAt - (W - int64_t(N) + j));
                sum += lat; mn = std::min(mn, lat); mx = std::max(mx, lat); ++found;
            }
            if (found) std::printf("   %5u   %7d    %4d   %6.0f / %6.1f / %6.0f                           %5.2f / %5.2f\n", N, L, lost, mn, sum / found, mx, sum / found / rate * 1000, mx / rate * 1000);
            else std::printf("   %5u   %7d    %4d   (everything lost)\n", N, L, lost);
            if (L < int32_t(N)) CHECK(lost > 0, "L < buffer must lose frames that are injected into already-read slots");
            else { CHECK(lost == 0, "L >= buffer must lose nothing (lost %d)", lost); CHECK(mx <= L + N + 1, "max latency %.0f frames exceeds budget + one buffer (%d)", mx, L + int32_t(N)); }
        }
    }
    std::printf("   => a budget below one IO buffer loses audio; at or above it nothing is lost and the worst case is exactly budget + one buffer (min ~ budget).\n");
    std::printf("   => default budget = buffer + 64 frames: at 48 kHz that is 4.0 ms worst / 3.3 ms mean for 64-frame buffers.\n");
    std::printf("      (injection stage only; the tap's own capture latency is not included and has to be measured live)\n");
}

// ------------------------------------------------------------------ C
static void clockHandling() {
    std::printf("\nC. clock handling in the injection engine (128-frame buffers, 120 s simulated)\n");
    const uint32_t N = 128, rate = 48000;
    struct Case { const char* name; double ppm; int jitterTicks; bool expectGlitch; };
    const Case cases[] = {
        {"exact clock, +-4 frame timestamp jitter", 0, int(4 * (24e6 / rate)), false},
        {"exact clock, +-40 frame timestamp jitter", 0, int(40 * (24e6 / rate)), false},
        {"+50 ppm, uncompensated", 50, 0, true},
        {"-200 ppm, uncompensated", -200, 0, true},
    };
    std::mt19937 rng(7);
    for (const Case& c : cases) {
        Fixture f(rate, N, N + 64); anchorClock(f);
        std::uniform_int_distribution<int> jit(-c.jitterTicks, c.jitterTicks);
        const int cycles = int(120.0 * rate / N);
        double captureClock = 0;                                        // capture device's own time, in frames of ITS clock
        for (int k = 0; k < cycles; ++k) {
            const int64_t trueStart = int64_t(k) * N + 8 * N;
            captureClock = double(trueStart) * (1.0 + c.ppm * 1e-6);    // timestamps drift against the driver clock
            f.cycle(int64_t(captureClock), N, c.jitterTicks ? jit(rng) : 0);
        }
        const uint64_t resyncs = conduit_tap_engine_stat(f.e, CONDUIT_STAT_RESYNCS);
        const double expected = std::fabs(c.ppm) * 1e-6 * 120.0 * rate / 48.0;
        std::printf("   %-44s resyncs (audible re-alignments): %3llu   (analytic ~%.0f)\n", c.name, (unsigned long long)resyncs, expected);
        if (!c.expectGlitch) CHECK(resyncs == 0, "jitter alone must never re-align (%llu)", (unsigned long long)resyncs);
        else CHECK(std::fabs(double(resyncs) - expected) <= 3, "resync count %llu vs analytic %.1f", (unsigned long long)resyncs, expected);
    }
    // Driver restart / sample-rate change: seed changes, engine re-aligns exactly once and keeps injecting.
    {
        Fixture f(48000, N, N + 64); anchorClock(f);
        for (int k = 0; k < 50; ++k) f.cycle(int64_t(k) * N + 8 * N, N);
        CHECK(conduit_tap_engine_stat(f.e, CONDUIT_STAT_RESYNCS) == 0, "steady state");
        f.rate = 96000; f.tpf = 24e6 / 96000.0; f.seed = 2; f.publish(true, uint64_t(1e6 * f.tpf));   // device switched to 96 kHz: new seed, new clock ratio
        std::fill(f.tap.begin(), f.tap.end(), 0.f); f.tap[0] = 1.f;
        f.cycle(int64_t(60) * N, N);
        for (int k = 61; k < 110; ++k) { std::fill(f.tap.begin(), f.tap.end(), 0.f); f.cycle(int64_t(k) * N, N); }
        std::printf("   driver switched 48 -> 96 kHz mid-stream: engine re-aligned %llu time(s)\n", (unsigned long long)conduit_tap_engine_stat(f.e, CONDUIT_STAT_RESYNCS));
        CHECK(conduit_tap_engine_stat(f.e, CONDUIT_STAT_RESYNCS) == 1, "must re-align exactly once on a seed change");
        std::vector<float> win(N * 2 * kCh); ConduitClockSnapshot s; conduit_clock_read(f.sh, &s);
        const int64_t slot = conduit_clock_sample_at(&s, uint64_t(int64_t(double(60 * N + 1000000) * f.tpf))) + N + 64;
        conduit_ring_read(&f.ring, slot, N, win.data());
        CHECK(std::fabs(win[0] - 1.0f) < 1e-6f, "impulse injected after the rate change lands at the new clock's slot (got %.3f)", win[0]);
    }
}

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s <driver-binary>\n", argv[0]); return 2; }
    void* lib = dlopen(argv[1], RTLD_NOW);
    auto factory = lib ? reinterpret_cast<void* (*)(CFAllocatorRef, CFUUIDRef)>(dlsym(lib, "ConduitFactory")) : nullptr;
    if (!factory) { std::fprintf(stderr, "cannot load driver\n"); return 2; }
    drv = static_cast<AudioServerPlugInDriverRef>(factory(nullptr, kAudioServerPlugInTypeUUID));
    vt = *drv;
    if (vt->Initialize(drv, &kHost)) return 2;
    driverLoopback();
    injectionBudget();
    clockHandling();
    std::printf(failures ? "\nbench offline FAILED (%d)\n" : "\nbench offline PASSED\n", failures);
    return failures ? 1 : 0;
}

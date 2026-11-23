// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Measurement core for latency and clock-drift benchmarking.
//
//  * ConduitBench: injects a unit impulse into a device's output at known device sample times and
//    detects when it comes back on the device's input. Used two ways with the same code:
//    live, as a Core Audio IOProc on the installed Conduit device, and offline, fed by the harness
//    that drives the driver binary directly.
//  * ConduitClockProbe: records (host time, device sample time) pairs from an IOProc so a device's
//    real sample rate and its drift against another device can be regressed.
//
// The per-cycle functions are real-time safe (no allocation, no locks, no logging).
#ifndef CONDUIT_BENCH_H
#define CONDUIT_BENCH_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ConduitBench ConduitBench;
typedef struct ConduitClockProbe ConduitClockProbe;

/* One measured impulse. "Callback host" = host time at which the IOProc ran; "sample host" = host time at which
   that device sample is scheduled to be played/captured. */
typedef struct {
    int64_t  writeSample;
    int64_t  detectSample;
    uint64_t writeCallbackHost;
    uint64_t writeSampleHost;
    uint64_t detectCallbackHost;
    uint64_t detectSampleHost;
} ConduitBenchRecord;

#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

/* Control plane. */
ConduitBench* __nullable conduit_bench_create(uint32_t channel, uint32_t intervalFrames, uint32_t maxImpulses, float threshold,
                                              double hostTicksPerFrame);
void conduit_bench_destroy(ConduitBench* b);
uint32_t conduit_bench_scheduled(const ConduitBench* b);
uint32_t conduit_bench_completed(const ConduitBench* b);
bool conduit_bench_record(const ConduitBench* b, uint32_t index, ConduitBenchRecord* out);

/* Real-time: one IO cycle. `out` is zeroed here, then the impulse is written when its sample time falls in the
   block; `in` is scanned for the returning impulse. Buffers are interleaved Float32. Either side may be NULL. */
void conduit_bench_cycle(ConduitBench* b, float* __nullable out, uint32_t outChannels, uint32_t outFrames, double outSampleTime,
                         uint64_t outSampleHost, const float* __nullable in, uint32_t inChannels, uint32_t inFrames,
                         double inSampleTime, uint64_t inSampleHost, uint64_t callbackHost);

OSStatus conduit_bench_ioproc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                              const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                              void* __nullable clientData);

/* Clock probe: records (callback host, device sample time) per IO cycle, silencing any output. */
ConduitClockProbe* __nullable conduit_clock_probe_create(uint32_t capacity);
void conduit_clock_probe_destroy(ConduitClockProbe* p);
uint32_t conduit_clock_probe_count(const ConduitClockProbe* p);
bool conduit_clock_probe_get(const ConduitClockProbe* p, uint32_t index, uint64_t* hostTime, double* sampleTime);
OSStatus conduit_clock_probe_ioproc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                                    const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                                    void* __nullable clientData);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif
#endif

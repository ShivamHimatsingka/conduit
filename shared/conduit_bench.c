// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
#include "conduit_bench.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

struct ConduitBench {
    uint32_t channel, interval, capacity;
    float threshold;
    double ticksPerFrame;
    uint32_t scheduled, completed;  /* written by the RT thread; read by the control thread after stopping */
    int64_t nextWrite;
    bool primed;
    ConduitBenchRecord* rec;
};

ConduitBench* conduit_bench_create(uint32_t channel, uint32_t intervalFrames, uint32_t maxImpulses, float threshold, double ticksPerFrame) {
    if (maxImpulses == 0 || intervalFrames == 0) return NULL;
    ConduitBench* b = (ConduitBench*)calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->rec = (ConduitBenchRecord*)calloc(maxImpulses, sizeof(ConduitBenchRecord));
    if (!b->rec) { free(b); return NULL; }
    b->channel = channel; b->interval = intervalFrames; b->capacity = maxImpulses;
    b->threshold = threshold; b->ticksPerFrame = ticksPerFrame;
    return b;
}
void conduit_bench_destroy(ConduitBench* b) { if (b) { free(b->rec); free(b); } }
uint32_t conduit_bench_scheduled(const ConduitBench* b) { return __atomic_load_n(&b->scheduled, __ATOMIC_ACQUIRE); }
uint32_t conduit_bench_completed(const ConduitBench* b) { return __atomic_load_n(&b->completed, __ATOMIC_ACQUIRE); }
bool conduit_bench_record(const ConduitBench* b, uint32_t i, ConduitBenchRecord* out) {
    if (i >= conduit_bench_completed(b)) return false;
    *out = b->rec[i];
    return true;
}

void conduit_bench_cycle(ConduitBench* b, float* out, uint32_t outCh, uint32_t outFrames, double outSampleTime, uint64_t outSampleHost,
                         const float* in, uint32_t inCh, uint32_t inFrames, double inSampleTime, uint64_t inSampleHost, uint64_t callbackHost) {
    if (out && outCh) {
        memset(out, 0, (size_t)outFrames * outCh * sizeof(float));
        const int64_t first = (int64_t)llround(outSampleTime);
        if (!b->primed) { b->nextWrite = first + 4 * (int64_t)outFrames; b->primed = true; }  /* let the device settle first */
        while (b->scheduled < b->capacity && b->nextWrite < first + (int64_t)outFrames) {
            if (b->nextWrite >= first && b->channel < outCh) {
                const uint32_t f = (uint32_t)(b->nextWrite - first);
                out[(size_t)f * outCh + b->channel] = 1.0f;
                ConduitBenchRecord* r = &b->rec[b->scheduled];
                r->writeSample = b->nextWrite;
                r->writeCallbackHost = callbackHost;
                r->writeSampleHost = outSampleHost + (uint64_t)((double)f * b->ticksPerFrame);
                __atomic_store_n(&b->scheduled, b->scheduled + 1, __ATOMIC_RELEASE);
            }
            b->nextWrite += b->interval;
        }
    }
    if (in && inCh && b->channel < inCh) {
        const int64_t first = (int64_t)llround(inSampleTime);
        for (uint32_t f = 0; f < inFrames && b->completed < b->scheduled; ++f) {
            ConduitBenchRecord* r = &b->rec[b->completed];
            if (first + f < r->writeSample) continue;  /* nothing can have come back before it was written */
            if (fabsf(in[(size_t)f * inCh + b->channel]) < b->threshold) continue;
            r->detectSample = first + f;
            r->detectCallbackHost = callbackHost;
            r->detectSampleHost = inSampleHost + (uint64_t)((double)f * b->ticksPerFrame);
            __atomic_store_n(&b->completed, b->completed + 1, __ATOMIC_RELEASE);
        }
    }
}

static inline uint32_t frames_of(const AudioBuffer* b) {
    return b->mNumberChannels ? b->mDataByteSize / (b->mNumberChannels * (uint32_t)sizeof(float)) : 0;
}
static inline uint64_t host_of(const AudioTimeStamp* t, const AudioTimeStamp* fallback) {
    return (t->mFlags & kAudioTimeStampHostTimeValid) ? t->mHostTime : fallback->mHostTime;
}

OSStatus conduit_bench_ioproc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                              const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime, void* clientData) {
    (void)device;
    ConduitBench* b = (ConduitBench*)clientData;
    if (!b) return kAudioHardwareNoError;
    float* out = NULL; uint32_t oc = 0, of = 0;
    const float* in = NULL; uint32_t ic = 0, inf = 0;
    if (output && output->mNumberBuffers > 0 && output->mBuffers[0].mData) {
        out = (float*)output->mBuffers[0].mData; oc = output->mBuffers[0].mNumberChannels; of = frames_of(&output->mBuffers[0]);
        for (UInt32 i = 1; i < output->mNumberBuffers; ++i)
            if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
    if (input && input->mNumberBuffers > 0 && input->mBuffers[0].mData) {
        in = (const float*)input->mBuffers[0].mData; ic = input->mBuffers[0].mNumberChannels; inf = frames_of(&input->mBuffers[0]);
    }
    conduit_bench_cycle(b, out, oc, of, outputTime->mSampleTime, host_of(outputTime, now), in, ic, inf, inputTime->mSampleTime,
                        host_of(inputTime, now), now->mHostTime);
    return kAudioHardwareNoError;
}

struct ConduitClockProbe {
    uint32_t capacity, count;
    uint64_t* host;
    double* sample;
};

ConduitClockProbe* conduit_clock_probe_create(uint32_t capacity) {
    if (capacity == 0) return NULL;
    ConduitClockProbe* p = (ConduitClockProbe*)calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->host = (uint64_t*)calloc(capacity, sizeof(uint64_t));
    p->sample = (double*)calloc(capacity, sizeof(double));
    if (!p->host || !p->sample) { free(p->host); free(p->sample); free(p); return NULL; }
    p->capacity = capacity;
    return p;
}
void conduit_clock_probe_destroy(ConduitClockProbe* p) { if (p) { free(p->host); free(p->sample); free(p); } }
uint32_t conduit_clock_probe_count(const ConduitClockProbe* p) { return __atomic_load_n(&p->count, __ATOMIC_ACQUIRE); }
bool conduit_clock_probe_get(const ConduitClockProbe* p, uint32_t i, uint64_t* host, double* sample) {
    if (i >= conduit_clock_probe_count(p)) return false;
    *host = p->host[i]; *sample = p->sample[i];
    return true;
}
OSStatus conduit_clock_probe_ioproc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                                    const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime, void* clientData) {
    (void)device; (void)input; (void)inputTime; (void)outputTime;
    ConduitClockProbe* p = (ConduitClockProbe*)clientData;
    if (output)
        for (UInt32 i = 0; i < output->mNumberBuffers; ++i)
            if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    if (!p || p->count >= p->capacity || !(now->mFlags & kAudioTimeStampSampleTimeValid) || !(now->mFlags & kAudioTimeStampHostTimeValid)) return kAudioHardwareNoError;
    p->host[p->count] = now->mHostTime;
    p->sample[p->count] = now->mSampleTime;
    __atomic_store_n(&p->count, p->count + 1, __ATOMIC_RELEASE);
    return kAudioHardwareNoError;
}

// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Real-time engine behind the aggregate-device IOProc that mixes sources
// (per-app Process Taps and hardware inputs such as microphones) into pairs of
// device channels. Written in C on purpose: the IOProc runs on a Core Audio
// real-time thread where the Swift/ObjC runtime (ARC, boxing, allocation,
// locks) must never execute. Everything here touches only preallocated memory
// and relaxed/acquire/release atomics.
//
// Control plane (Swift) creates the engine, sets sends and reads meters; the
// IOProc (C) reads sends and publishes peaks and an analysis feed.
#ifndef CONDUIT_TAP_ENGINE_H
#define CONDUIT_TAP_ENGINE_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "conduit_shared.h"

#ifdef __cplusplus
extern "C" {
#endif

#define CONDUIT_MAX_TAP_SOURCES 16
#define CONDUIT_MAX_PAIRS 32 /* stereo destinations: pair p = device channels 2p, 2p+1 */

typedef struct ConduitTapEngine ConduitTapEngine; /* opaque */

typedef enum {
    CONDUIT_SOURCE_TAP = 0,      /* ordinal = index among tap sources; buffers sit at the END of the aggregate input list */
    CONDUIT_SOURCE_HARDWARE = 1  /* ordinal = absolute index of the input buffer (after the clock device's streams) */
} ConduitSourceKind;

typedef enum {
    CONDUIT_STAT_CYCLES = 0,   /* IOProc invocations that carried source data */
    CONDUIT_STAT_IDLE,         /* cycles not injected because the driver clock was not running */
    CONDUIT_STAT_RESYNCS,      /* times the write position was re-aligned to the device clock */
    CONDUIT_STAT_SHORT,        /* cycles where a source buffer was missing */
    CONDUIT_STAT_LAST_FRAMES   /* frames in the most recent cycle (I/O buffer size) */
} ConduitTapStat;

#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

/* Control plane. `shared` and `ring` may both be NULL: the engine then only meters
   (monitor mode). `ring` must stay valid for the engine's lifetime. */
ConduitTapEngine* __nullable conduit_tap_engine_create(ConduitShared* __nullable shared, ConduitRing* __nullable ring);
void conduit_tap_engine_destroy(ConduitTapEngine* e); /* only after the IOProc is stopped */

/* Declare sources 0..count-1. `tapCount` = how many of them are CONDUIT_SOURCE_TAP. */
void conduit_tap_engine_configure(ConduitTapEngine* e, uint32_t count, uint32_t tapCount);
void conduit_tap_engine_set_source(ConduitTapEngine* e, uint32_t source, ConduitSourceKind kind, uint32_t ordinal);
/* Frames between a source frame's capture time and the device time it is injected for. */
void conduit_tap_engine_set_latency(ConduitTapEngine* e, uint32_t frames);
/* Per-source: mute and mono-fold (L+R)/2 sent to both channels of each pair. */
void conduit_tap_engine_set_flags(ConduitTapEngine* e, uint32_t source, bool mute, bool mono);
/* Send level (linear) of a source into stereo pair `pair`; 0 disconnects. Changes ramp inside the block. */
void conduit_tap_engine_set_send(ConduitTapEngine* e, uint32_t source, uint32_t pair, float gain);

float conduit_tap_engine_take_peak(ConduitTapEngine* e, uint32_t source); /* max-hold, cleared by the read */
/* Copies the most recent `frames` mono samples (pre-fader mix of L/R) of a source, oldest first.
   Returns false if fewer than `frames` have been produced or `frames` > CONDUIT_ANALYSIS_FRAMES/2. */
#define CONDUIT_ANALYSIS_FRAMES 8192
bool conduit_tap_engine_latest(ConduitTapEngine* e, uint32_t source, float* dst, uint32_t frames);
uint64_t conduit_tap_engine_stat(const ConduitTapEngine* e, ConduitTapStat which);

/* Real-time. Register with AudioDeviceCreateIOProcID(aggregate, conduit_tap_ioproc, engine, ...).
   Signature matches AudioDeviceIOProc exactly (all pointers non-null except clientData). */
OSStatus conduit_tap_ioproc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                            const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                            void* __nullable clientData);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif
#endif

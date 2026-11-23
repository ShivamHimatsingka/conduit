// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Compile-time device configuration. Every value can be overridden from the
// Makefile (e.g. `make CHANNELS=2 DEVICE_NAME="Conduit 2ch" DEVICE_UID=...`),
// which lets you ship several differently-sized virtual devices side by side.
#pragma once

#include <CoreAudio/AudioServerPlugIn.h>

#include <array>
#include <cstdint>

#ifndef CONDUIT_CHANNELS
#define CONDUIT_CHANNELS 16
#endif
#ifndef CONDUIT_DEVICE_NAME
#define CONDUIT_DEVICE_NAME "Conduit 16ch"
#endif
#ifndef CONDUIT_DEVICE_UID
#define CONDUIT_DEVICE_UID "com.conduit.driver.device.16ch"
#endif
#ifndef CONDUIT_MODEL_UID
#define CONDUIT_MODEL_UID "com.conduit.driver.model"
#endif
#ifndef CONDUIT_MACH_SERVICE
#define CONDUIT_MACH_SERVICE "com.conduit.driver.ipc"
#endif
#ifndef CONDUIT_MANUFACTURER
#define CONDUIT_MANUFACTURER "Conduit Audio"
#endif

namespace conduit {

inline constexpr std::uint32_t kChannels = CONDUIT_CHANNELS;
static_assert(kChannels >= 1 && kChannels <= 64, "CONDUIT_CHANNELS must be in [1, 64]");
static_assert(kChannels <= 64, "shared control block is sized for CONDUIT_MAX_CHANNELS");

inline constexpr std::array<double, 3> kSampleRates{44100.0, 48000.0, 96000.0};
inline constexpr double kDefaultSampleRate = 48000.0;

// Ring capacity in frames (power of two). 32768 frames = 341 ms @ 96 kHz and
// 2 MiB for 16 channels of float32 - comfortably above any HAL buffer size.
inline constexpr std::uint32_t kRingFrames = 1u << 15;

// Period of the device's zero-timestamp clock, in frames.
inline constexpr std::uint32_t kZeroTimeStampPeriod = 16384;

// Latency / safety offset, in frames. A time-indexed loopback needs none:
// output for sample time T is always written before input for T is read.
inline constexpr std::uint32_t kLatencyFrames      = 0;
inline constexpr std::uint32_t kSafetyOffsetFrames = 0;

// Object IDs (fixed object graph: plug-in -> device -> {input, output} streams).
inline constexpr AudioObjectID kPlugInID       = kAudioObjectPlugInObject;
inline constexpr AudioObjectID kDeviceID       = 2;
inline constexpr AudioObjectID kInputStreamID  = 3;
inline constexpr AudioObjectID kOutputStreamID = 4;

// Device configuration-change action codes (passed through the HAL verbatim).
inline constexpr UInt64 kChangeActionSetSampleRate = 1;

}  // namespace conduit

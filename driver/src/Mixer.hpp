// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Real-time mixing and metering stage between the device streams and the
// rings. Reads the app-written control block with relaxed atomics, writes
// telemetry with relaxed atomics. All buffers are allocated once in init().
//
//   WriteMix (apps -> device):  strip gain/mute/solo -> NxN matrix -> loopback ring
//   ReadInput (device -> apps): loopback ring (+ app injection ring) -> bus gain/mute
#pragma once

#include <cstdint>
#include <memory>

#include "Config.hpp"
#include "RingBuffer.hpp"
#include "conduit_shared.h"

namespace conduit {

class Mixer {
public:
    // Control plane. Allocates and pre-faults all scratch memory.
    [[nodiscard]] bool init(ConduitShared* shared, TimelineRing* loopback, TimelineRing* app) noexcept;
    // Control plane (IO stopped): adopt the current control state without ramping.
    void snapshot() noexcept;

    // Real-time safe.
    void write(std::int64_t sampleTime, std::uint32_t frames, const float* in) noexcept;
    void read(std::int64_t sampleTime, std::uint32_t frames, float* dst) noexcept;

private:
    static constexpr std::uint32_t kChunk = 2048;
    static constexpr std::uint32_t kMax   = CONDUIT_MAX_CHANNELS;

    struct Entry {
        std::uint16_t input;
        float         c0;
        float         step;
    };

    void computeMatrix(float* out) const noexcept;
    void computeBusGains(float* out) const noexcept;
    static void meter(const float* x, std::uint32_t frames, std::uint32_t* peak, std::uint32_t* msq) noexcept;

    ConduitShared* s_{nullptr};
    TimelineRing*  loop_{nullptr};
    TimelineRing*  app_{nullptr};

    std::unique_ptr<float[]> scratchMix_;  // kChunk * kChannels
    std::unique_ptr<float[]> scratchApp_;  // kChunk * kChannels
    std::unique_ptr<float[]> prevCoef_;    // kChannels * kChannels (bus-major)
    std::unique_ptr<float[]> curCoef_;
    std::unique_ptr<Entry[]> entries_;     // sparse view, rebuilt every block
    std::unique_ptr<std::uint32_t[]> rowStart_;
    float prevBus_[kMax]{};
    float curBus_[kMax]{};
};

}  // namespace conduit

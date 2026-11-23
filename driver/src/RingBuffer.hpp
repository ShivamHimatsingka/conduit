// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// TimelineRing: C++ face of the lock-free SPSC "timeline" ring defined in
// shared/include/conduit_ring.h.
//
// Slots are addressed by *absolute sample time* instead of free-running
// head/tail cursors. Core Audio's output (WriteMix) and input (ReadInput) IO
// cycles are scheduled independently, may use different buffer sizes, and are
// each tagged with a device sample time. Time addressing keeps them
// phase-locked at zero added latency, and dropouts self-heal (a missing block
// reads as silence) instead of permanently skewing a read cursor.
//
// The algorithm lives in C so that the Swift app can be the producer of the
// very same ring in shared memory (Phase 2/3) with a guaranteed-identical
// layout. Torn reads are prevented by a seqlock (writeBegin/writeEnd).
//
// Threading: exactly one producer calls write(), exactly one consumer calls
// read(). create()/reset() are control-plane only.
#pragma once

#include <cstddef>
#include <cstdint>

#include "conduit_ring.h"

namespace conduit {

inline constexpr std::size_t kCacheLine = CONDUIT_CACHE_LINE;

class TimelineRing {
public:
    TimelineRing() noexcept = default;

    static constexpr std::size_t bytesRequired(std::uint32_t channels, std::uint32_t capacityFrames) noexcept {
        return conduit_ring_bytes(channels, capacityFrames);
    }
    // `memory` must be 64-byte aligned and bytesRequired() long.
    static TimelineRing create(void* memory, std::uint32_t channels, std::uint32_t capacityFrames) noexcept {
        TimelineRing r;
        if (!conduit_ring_create(memory, channels, capacityFrames, &r.ring_)) r.ring_ = {};
        return r;
    }
    static TimelineRing attach(void* memory) noexcept {
        TimelineRing r;
        if (!conduit_ring_attach(memory, &r.ring_)) r.ring_ = {};
        return r;
    }

    [[nodiscard]] bool valid() const noexcept { return ring_.hdr != nullptr; }
    [[nodiscard]] std::uint32_t channels() const noexcept { return conduit_ring_channels(&ring_); }
    [[nodiscard]] std::uint32_t capacityFrames() const noexcept { return ring_.hdr->config.capacityFrames; }
    [[nodiscard]] std::uint64_t underrunFrames() const noexcept { return conduit_ring_underruns(&ring_); }
    [[nodiscard]] std::uint64_t lappedFrames() const noexcept { return conduit_ring_lapped(&ring_); }
    [[nodiscard]] std::uint64_t gapFrames() const noexcept { return conduit_ring_gaps(&ring_); }

    void reset() noexcept { conduit_ring_reset(&ring_); }

    // PRODUCER, real-time safe.
    void write(std::int64_t start, std::uint32_t frames, const float* src) noexcept { conduit_ring_write(&ring_, start, frames, src); }
    // CONSUMER, real-time safe. Missing/overwritten frames read as silence;
    // returns the number of frames that carry real audio.
    std::uint32_t read(std::int64_t start, std::uint32_t frames, float* dst) noexcept { return conduit_ring_read(&ring_, start, frames, dst); }

private:
    ConduitRing ring_{};
};

}  // namespace conduit

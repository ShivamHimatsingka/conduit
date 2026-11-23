// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
#pragma once

#include <atomic>

#include "Config.hpp"
#include "Object.hpp"

namespace conduit {

class Device;

// One direction of the loopback device. Format: interleaved, packed,
// native-endian 32-bit float, kChannels channels, at the device's rate.
class Stream final : public Object {
public:
    Stream(AudioObjectID id, bool isInput, Device& owner) noexcept;

    [[nodiscard]] bool isInput() const noexcept { return isInput_; }
    // Read from the real-time thread: a single relaxed atomic load.
    [[nodiscard]] bool isActive() const noexcept { return active_.load(std::memory_order_relaxed); }

    OSStatus get(const AudioObjectPropertyAddress& addr, const void* qualifier, UInt32 qualifierSize,
                 PropertyReply& reply) const override;
    [[nodiscard]] bool settable(const AudioObjectPropertyAddress& addr) const noexcept override;
    OSStatus set(const AudioObjectPropertyAddress& addr, const void* qualifier, UInt32 qualifierSize,
                 const void* data, UInt32 size) override;

    static AudioStreamBasicDescription makeFormat(double sampleRate) noexcept;

private:
    bool            isInput_;
    Device&         owner_;
    std::atomic<bool> active_{true};
};

}  // namespace conduit

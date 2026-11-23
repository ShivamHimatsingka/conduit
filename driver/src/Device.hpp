// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>

#include "Config.hpp"
#include "IpcServer.hpp"
#include "Mixer.hpp"
#include "Object.hpp"
#include "RingBuffer.hpp"
#include "SharedRegion.hpp"
#include "Stream.hpp"

namespace conduit {

// The virtual loopback device. Control-plane methods (property access,
// StartIO/StopIO, configuration changes) may lock and allocate. The methods
// in the "real-time" section touch only atomics and preallocated memory.
class Device final : public Object {
public:
    Device() noexcept;
    ~Device() override;

    // Returns false if the shared ring could not be allocated.
    [[nodiscard]] bool ok() const noexcept { return ring_.valid() && mixerReady_; }
    // Starts the Mach server that hands the shared region to the app. Failure is
    // non-fatal: the device still works as a plain loopback without the app.
    bool startIpc() noexcept;

    void attachStreams(Stream* input, Stream* output) noexcept {
        input_  = input;
        output_ = output;
    }
    void setHost(AudioServerPlugInHostRef host) noexcept { host_.store(host, std::memory_order_release); }
    [[nodiscard]] AudioServerPlugInHostRef host() const noexcept { return host_.load(std::memory_order_acquire); }

    // ---- control plane ---------------------------------------------------
    OSStatus get(const AudioObjectPropertyAddress& addr, const void* qualifier, UInt32 qualifierSize,
                 PropertyReply& reply) const override;
    [[nodiscard]] bool settable(const AudioObjectPropertyAddress& addr) const noexcept override;
    OSStatus set(const AudioObjectPropertyAddress& addr, const void* qualifier, UInt32 qualifierSize,
                 const void* data, UInt32 size) override;

    [[nodiscard]] double sampleRate() const noexcept { return rate_.load(std::memory_order_relaxed); }
    // Validates and schedules an asynchronous sample-rate change.
    OSStatus requestSampleRate(double rate);
    OSStatus performConfigurationChange(UInt64 action, void* info);

    OSStatus startIO();
    OSStatus stopIO();

    // ---- real-time -------------------------------------------------------
    OSStatus getZeroTimeStamp(Float64* sampleTime, UInt64* hostTime, UInt64* seed) const noexcept;
    static void willDoOperation(UInt32 operation, Boolean* willDo, Boolean* inPlace) noexcept;
    OSStatus doOperation(AudioObjectID stream, UInt32 operation, UInt32 frames,
                         const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer) noexcept;

    [[nodiscard]] TimelineRing& ring() noexcept { return ring_; }

private:
    static void deferredRateChange(void* self) noexcept;
    void recomputeClock() noexcept;

    std::atomic<AudioServerPlugInHostRef> host_{nullptr};
    Stream* input_{nullptr};
    Stream* output_{nullptr};

    // Sample rate and derived host-clock ratio. Only mutated while IO is stopped.
    std::atomic<double> rate_{kDefaultSampleRate};
    std::atomic<double> hostTicksPerFrame_{0.0};
    double              pendingRate_{kDefaultSampleRate};  // guarded by controlMutex_

    // IO lifecycle.
    mutable std::mutex           controlMutex_;  // control plane only
    std::uint32_t                ioClients_{0};  // guarded by controlMutex_
    std::atomic<std::uint32_t>   running_{0};    // mirror for lock-free reads
    std::atomic<std::uint64_t>   anchorHostTime_{0};
    std::atomic<std::uint64_t>   clockSeed_{1};

    void publishClock(bool running) noexcept;

    SharedRegion region_;
    Mixer        mixer_;
    IpcServer    ipc_;
    bool         mixerReady_{false};

    void*       ringMemory_{nullptr};
    std::size_t ringBytes_{0};
    TimelineRing ring_;
};

}  // namespace conduit

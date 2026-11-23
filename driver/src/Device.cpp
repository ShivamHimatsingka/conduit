// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
#include "Device.hpp"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <sys/mman.h>

#include <algorithm>
#include <array>
#include <cmath>

namespace conduit {

namespace {

[[nodiscard]] bool isSupportedRate(double r) noexcept {
    return std::any_of(kSampleRates.begin(), kSampleRates.end(), [r](double s) { return s == r; });
}

[[nodiscard]] double hostTicksPerSecond() noexcept {
    static const double ticks = [] {
        mach_timebase_info_data_t tb{};
        mach_timebase_info(&tb);
        return 1.0e9 * static_cast<double>(tb.denom) / static_cast<double>(tb.numer);
    }();
    return ticks;
}

}  // namespace

Device::Device() noexcept : Object(kDeviceID) {
    // The ring is allocated exactly once, here, on the control plane. Anonymous
    // mmap gives page-aligned (hence cache-line-aligned) zeroed memory;
    // TimelineRing::create() then touches every page so IO never faults.
    ringBytes_ = TimelineRing::bytesRequired(kChannels, kRingFrames);
    void* mem  = ::mmap(nullptr, ringBytes_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem != MAP_FAILED) {
        ringMemory_ = mem;
        ::mlock(mem, ringBytes_);  // best effort; coreaudiod may lack the rlimit
        ring_ = TimelineRing::create(mem, kChannels, kRingFrames);
    }
    recomputeClock();
    if (ring_.valid() && region_.init()) {
        mixerReady_ = mixer_.init(region_.shared(), &ring_, &region_.appRing());
        publishClock(false);
    }
}

Device::~Device() {
    if (ringMemory_) ::munmap(ringMemory_, ringBytes_);
}

bool Device::startIpc() noexcept {
    return mixerReady_ && ipc_.start(CONDUIT_MACH_SERVICE, region_.entry(), region_.bytes());
}

void Device::publishClock(bool running) noexcept {
    if (!region_.shared()) return;
    conduit_clock_publish(region_.shared(), static_cast<std::uint32_t>(rate_.load(std::memory_order_relaxed)), running,
                          anchorHostTime_.load(std::memory_order_relaxed), hostTicksPerFrame_.load(std::memory_order_relaxed),
                          clockSeed_.load(std::memory_order_relaxed));
}

void Device::recomputeClock() noexcept {
    hostTicksPerFrame_.store(hostTicksPerSecond() / rate_.load(std::memory_order_relaxed), std::memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

OSStatus Device::get(const AudioObjectPropertyAddress& addr, const void*, UInt32, PropertyReply& reply) const {
    const bool wantInput  = addr.mScope == kAudioObjectPropertyScopeInput;
    const bool wantOutput = addr.mScope == kAudioObjectPropertyScopeOutput;

    switch (addr.mSelector) {
        case kAudioObjectPropertyBaseClass:
            return reply.value<AudioClassID>(kAudioObjectClassID);
        case kAudioObjectPropertyClass:
            return reply.value<AudioClassID>(kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:
            return reply.value<AudioObjectID>(kPlugInID);
        case kAudioObjectPropertyName:
            return reply.string(CFSTR(CONDUIT_DEVICE_NAME));
        case kAudioObjectPropertyManufacturer:
            return reply.string(CFSTR(CONDUIT_MANUFACTURER));
        case kAudioObjectPropertyOwnedObjects: {
            const std::array<AudioObjectID, 2> owned{kInputStreamID, kOutputStreamID};
            return reply.array(owned.data(), static_cast<UInt32>(owned.size()));
        }
        case kAudioObjectPropertyControlList:
            return reply.array<AudioObjectID>(nullptr, 0);
        case kAudioDevicePropertyDeviceUID:
            return reply.string(CFSTR(CONDUIT_DEVICE_UID));
        case kAudioDevicePropertyModelUID:
            return reply.string(CFSTR(CONDUIT_MODEL_UID));
        case kAudioDevicePropertyTransportType:
            return reply.value<UInt32>(kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: {
            const AudioObjectID self = kDeviceID;
            return reply.array(&self, 1);
        }
        case kAudioDevicePropertyClockDomain:
            return reply.value<UInt32>(0);
        case kAudioDevicePropertyDeviceIsAlive:
            return reply.value<UInt32>(1);
        case kAudioDevicePropertyDeviceIsRunning:
            return reply.value<UInt32>(running_.load(std::memory_order_relaxed));
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            return reply.value<UInt32>(1);
        case kAudioDevicePropertyLatency:
            return reply.value<UInt32>(kLatencyFrames);
        case kAudioDevicePropertySafetyOffset:
            return reply.value<UInt32>(kSafetyOffsetFrames);
        case kAudioDevicePropertyIsHidden:
            return reply.value<UInt32>(0);
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return reply.value<UInt32>(kZeroTimeStampPeriod);
        case kAudioDevicePropertyStreams: {
            std::array<AudioObjectID, 2> ids{};
            UInt32                       n = 0;
            if (!wantOutput) ids[n++] = kInputStreamID;
            if (!wantInput) ids[n++] = kOutputStreamID;
            return reply.array(ids.data(), n);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (!wantInput && !wantOutput) return kAudioHardwareUnknownPropertyError;
            const std::array<UInt32, 2> stereo{1, kChannels >= 2 ? 2u : 1u};
            return reply.array(stereo.data(), 2);
        }
        case kAudioDevicePropertyNominalSampleRate:
            return reply.value<Float64>(sampleRate());
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            std::array<AudioValueRange, kSampleRates.size()> ranges{};
            for (std::size_t i = 0; i < kSampleRates.size(); ++i) ranges[i] = {kSampleRates[i], kSampleRates[i]};
            return reply.array(ranges.data(), static_cast<UInt32>(ranges.size()));
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

bool Device::settable(const AudioObjectPropertyAddress& addr) const noexcept {
    return addr.mSelector == kAudioDevicePropertyNominalSampleRate;
}

OSStatus Device::set(const AudioObjectPropertyAddress& addr, const void*, UInt32, const void* data, UInt32 size) {
    if (addr.mSelector != kAudioDevicePropertyNominalSampleRate) return kAudioHardwareUnknownPropertyError;
    if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
    return requestSampleRate(*static_cast<const Float64*>(data));
}

// ---------------------------------------------------------------------------
// Sample-rate change (asynchronous, performed by the HAL while IO is stopped)
// ---------------------------------------------------------------------------

OSStatus Device::requestSampleRate(double rate) {
    if (!isSupportedRate(rate)) return kAudioDeviceUnsupportedFormatError;
    {
        std::lock_guard lock(controlMutex_);
        if (rate == rate_.load(std::memory_order_relaxed) && rate == pendingRate_) return kAudioHardwareNoError;
        pendingRate_ = rate;
    }
    if (host()) {
        // Never call back into the host from inside a property call; hop to a queue.
        dispatch_async_f(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), this, &Device::deferredRateChange);
    }
    return kAudioHardwareNoError;
}

void Device::deferredRateChange(void* self) noexcept {
    auto* dev = static_cast<Device*>(self);
    if (auto* h = dev->host()) h->RequestDeviceConfigurationChange(h, kDeviceID, kChangeActionSetSampleRate, nullptr);
}

OSStatus Device::performConfigurationChange(UInt64 action, void*) {
    if (action != kChangeActionSetSampleRate) return kAudioHardwareUnsupportedOperationError;
    std::lock_guard lock(controlMutex_);
    rate_.store(pendingRate_, std::memory_order_relaxed);
    recomputeClock();
    publishClock(false);
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// IO lifecycle
// ---------------------------------------------------------------------------

OSStatus Device::startIO() {
    if (!ring_.valid()) return kAudioHardwareUnspecifiedError;
    std::lock_guard lock(controlMutex_);
    if (ioClients_++ == 0) {
        ring_.reset();  // no IO thread is running yet, so this is race-free
        mixer_.snapshot();
        clockSeed_.fetch_add(1, std::memory_order_relaxed);
        anchorHostTime_.store(mach_absolute_time(), std::memory_order_release);
        running_.store(1, std::memory_order_relaxed);
        publishClock(true);
    }
    return kAudioHardwareNoError;
}

OSStatus Device::stopIO() {
    std::lock_guard lock(controlMutex_);
    if (ioClients_ == 0) return kAudioHardwareIllegalOperationError;
    if (--ioClients_ == 0) {
        running_.store(0, std::memory_order_relaxed);
        anchorHostTime_.store(0, std::memory_order_release);
        publishClock(false);
    }
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// Real-time path: no locks, no allocation, no logging, no ObjC/CF.
// ---------------------------------------------------------------------------

OSStatus Device::getZeroTimeStamp(Float64* sampleTime, UInt64* hostTime, UInt64* seed) const noexcept {
    const UInt64 now    = mach_absolute_time();
    const UInt64 anchor = anchorHostTime_.load(std::memory_order_acquire);
    *seed               = clockSeed_.load(std::memory_order_relaxed);
    if (anchor == 0 || now < anchor) {
        *sampleTime = 0.0;
        *hostTime   = now;
        return kAudioHardwareNoError;
    }
    // Stateless: the zero timestamp is a pure function of (anchor, now, rate),
    // so concurrent callers always agree and no state needs synchronising.
    const double   ticksPerPeriod = hostTicksPerFrame_.load(std::memory_order_relaxed) * kZeroTimeStampPeriod;
    const UInt64   periods        = static_cast<UInt64>(static_cast<double>(now - anchor) / ticksPerPeriod);
    *sampleTime                   = static_cast<Float64>(periods * kZeroTimeStampPeriod);
    *hostTime                     = anchor + static_cast<UInt64>(static_cast<double>(periods) * ticksPerPeriod);
    return kAudioHardwareNoError;
}

void Device::willDoOperation(UInt32 operation, Boolean* willDo, Boolean* inPlace) noexcept {
    const bool ours = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
    *willDo         = ours;
    *inPlace        = true;
}

OSStatus Device::doOperation(AudioObjectID stream, UInt32 operation, UInt32 frames,
                             const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer) noexcept {
    switch (operation) {
        case kAudioServerPlugInIOOperationReadInput:
            if (stream == kInputStreamID && input_->isActive()) {
                mixer_.read(std::llround(cycle->mInputTime.mSampleTime), frames, static_cast<float*>(mainBuffer));
            }
            return kAudioHardwareNoError;
        case kAudioServerPlugInIOOperationWriteMix:
            if (stream == kOutputStreamID && output_->isActive()) {
                mixer_.write(std::llround(cycle->mOutputTime.mSampleTime), frames, static_cast<const float*>(mainBuffer));
            }
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareNoError;
    }
}

}  // namespace conduit

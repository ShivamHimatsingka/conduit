// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
#include "Stream.hpp"

#include <array>
#include <cmath>

#include "Device.hpp"

namespace conduit {

Stream::Stream(AudioObjectID id, bool isInput, Device& owner) noexcept : Object(id), isInput_(isInput), owner_(owner) {}

AudioStreamBasicDescription Stream::makeFormat(double sampleRate) noexcept {
    AudioStreamBasicDescription f{};
    f.mSampleRate       = sampleRate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = static_cast<AudioFormatFlags>(kAudioFormatFlagIsFloat) |
                          static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeEndian) |
                          static_cast<AudioFormatFlags>(kAudioFormatFlagIsPacked);
    f.mBytesPerPacket   = kChannels * sizeof(float);
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = kChannels * sizeof(float);
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel   = 32;
    return f;
}

OSStatus Stream::get(const AudioObjectPropertyAddress& addr, const void*, UInt32, PropertyReply& reply) const {
    switch (addr.mSelector) {
        case kAudioObjectPropertyBaseClass:
            return reply.value<AudioClassID>(kAudioObjectClassID);
        case kAudioObjectPropertyClass:
            return reply.value<AudioClassID>(kAudioStreamClassID);
        case kAudioObjectPropertyOwner:
            return reply.value<AudioObjectID>(kDeviceID);
        case kAudioObjectPropertyOwnedObjects:
            return reply.array<AudioObjectID>(nullptr, 0);
        case kAudioStreamPropertyIsActive:
            return reply.value<UInt32>(isActive() ? 1u : 0u);
        case kAudioStreamPropertyDirection:
            return reply.value<UInt32>(isInput_ ? 1u : 0u);  // 0 = output, 1 = input
        case kAudioStreamPropertyTerminalType:
            return reply.value<UInt32>(kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel:
            return reply.value<UInt32>(1);
        case kAudioStreamPropertyLatency:
            return reply.value<UInt32>(kLatencyFrames);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return reply.value<AudioStreamBasicDescription>(makeFormat(owner_.sampleRate()));
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            std::array<AudioStreamRangedDescription, kSampleRates.size()> formats{};
            for (std::size_t i = 0; i < kSampleRates.size(); ++i) {
                formats[i].mFormat                = makeFormat(kSampleRates[i]);
                formats[i].mSampleRateRange.mMinimum = kSampleRates[i];
                formats[i].mSampleRateRange.mMaximum = kSampleRates[i];
            }
            return reply.array(formats.data(), static_cast<UInt32>(formats.size()));
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

bool Stream::settable(const AudioObjectPropertyAddress& addr) const noexcept {
    switch (addr.mSelector) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return true;
        default:
            return false;
    }
}

OSStatus Stream::set(const AudioObjectPropertyAddress& addr, const void*, UInt32, const void* data, UInt32 size) {
    switch (addr.mSelector) {
        case kAudioStreamPropertyIsActive: {
            if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            const bool want = *static_cast<const UInt32*>(data) != 0;
            if (active_.exchange(want, std::memory_order_relaxed) != want) {
                if (auto* host = owner_.host()) {
                    const AudioObjectPropertyAddress changed{kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal,
                                                             kAudioObjectPropertyElementMain};
                    host->PropertiesChanged(host, id(), 1, &changed);
                }
            }
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const auto& f = *static_cast<const AudioStreamBasicDescription*>(data);
            const auto  want = makeFormat(f.mSampleRate);
            if (f.mFormatID != want.mFormatID || f.mFormatFlags != want.mFormatFlags ||
                f.mBytesPerPacket != want.mBytesPerPacket || f.mFramesPerPacket != want.mFramesPerPacket ||
                f.mBytesPerFrame != want.mBytesPerFrame || f.mChannelsPerFrame != want.mChannelsPerFrame ||
                f.mBitsPerChannel != want.mBitsPerChannel) {
                return kAudioDeviceUnsupportedFormatError;
            }
            return owner_.requestSampleRate(f.mSampleRate);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

}  // namespace conduit

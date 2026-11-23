// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Base class for objects in the plug-in's object graph, plus a small helper
// that lets every property be implemented once and serve both
// GetPropertyDataSize and GetPropertyData.
//
// Everything here is CONTROL-PLANE code: it may allocate, retain CF objects
// and take locks. It is never called from the real-time IO path.
#pragma once

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cstring>

namespace conduit {

// One reply object serves both "how big is this property?" (data == nullptr)
// and "give me the property" (data != nullptr).
struct PropertyReply {
    UInt32 capacity{0};
    void*  data{nullptr};
    UInt32 size{0};

    template <class T>
    OSStatus value(const T& v) noexcept {
        size = sizeof(T);
        if (!data) return kAudioHardwareNoError;
        if (capacity < sizeof(T)) return kAudioHardwareBadPropertySizeError;
        std::memcpy(data, &v, sizeof(T));
        return kAudioHardwareNoError;
    }

    // Arrays are truncated to whole elements that fit, as the HAL expects.
    template <class T>
    OSStatus array(const T* items, UInt32 count) noexcept {
        const UInt32 fit = data ? std::min<UInt32>(count, capacity / sizeof(T)) : count;
        size = fit * static_cast<UInt32>(sizeof(T));
        if (data && fit) std::memcpy(data, items, size);
        return kAudioHardwareNoError;
    }

    // The HAL releases CFStrings we hand back, so hand over a +1 reference.
    OSStatus string(CFStringRef s) noexcept {
        size = sizeof(CFStringRef);
        if (!data) return kAudioHardwareNoError;
        if (capacity < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        CFRetain(s);
        *static_cast<CFStringRef*>(data) = s;
        return kAudioHardwareNoError;
    }
};

class Object {
public:
    explicit Object(AudioObjectID id) noexcept : id_(id) {}
    virtual ~Object() = default;
    Object(const Object&)            = delete;
    Object& operator=(const Object&) = delete;

    [[nodiscard]] AudioObjectID id() const noexcept { return id_; }

    // Returns kAudioHardwareUnknownPropertyError for unsupported selectors.
    virtual OSStatus get(const AudioObjectPropertyAddress& addr, const void* qualifier, UInt32 qualifierSize,
                         PropertyReply& reply) const = 0;
    [[nodiscard]] virtual bool settable(const AudioObjectPropertyAddress&) const noexcept { return false; }
    virtual OSStatus set(const AudioObjectPropertyAddress&, const void* /*qualifier*/, UInt32 /*qualifierSize*/,
                         const void* /*data*/, UInt32 /*size*/) {
        return kAudioHardwareUnsupportedOperationError;
    }

private:
    AudioObjectID id_;
};

}  // namespace conduit

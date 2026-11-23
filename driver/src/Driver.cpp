// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Clean-room AudioServerPlugInDriverInterface implementation.
// Object graph:  PlugIn(1) -> Device(2) -> { InputStream(3), OutputStream(4) }
//
// This file owns the COM-style vtable, the plug-in object and the CFPlugIn
// factory. Every vtable entry is a thin router to the object that owns the
// requested AudioObjectID.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <new>

#include "Config.hpp"
#include "Device.hpp"
#include "Object.hpp"
#include "Stream.hpp"

namespace conduit {
namespace {

class PlugIn final : public Object {
public:
    explicit PlugIn(Device& device) noexcept : Object(kPlugInID), device_(device) {}

    OSStatus get(const AudioObjectPropertyAddress& addr, const void* qualifier, UInt32 qualifierSize,
                 PropertyReply& reply) const override {
        switch (addr.mSelector) {
            case kAudioObjectPropertyBaseClass:
                return reply.value<AudioClassID>(kAudioObjectClassID);
            case kAudioObjectPropertyClass:
                return reply.value<AudioClassID>(kAudioPlugInClassID);
            case kAudioObjectPropertyOwner:
                return reply.value<AudioObjectID>(kAudioObjectUnknown);
            case kAudioObjectPropertyManufacturer:
                return reply.string(CFSTR(CONDUIT_MANUFACTURER));
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                const AudioObjectID dev = device_.id();
                return reply.array(&dev, 1);
            }
            case kAudioPlugInPropertyBoxList:
                return reply.array<AudioObjectID>(nullptr, 0);
            case kAudioPlugInPropertyTranslateUIDToBox:
                return translate(qualifier, qualifierSize, reply, nullptr);
            case kAudioPlugInPropertyTranslateUIDToDevice:
                return translate(qualifier, qualifierSize, reply, CFSTR(CONDUIT_DEVICE_UID));
            case kAudioPlugInPropertyResourceBundle:
                return reply.string(CFSTR(""));
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

private:
    // Qualifier is a CFStringRef UID; reply is the matching AudioObjectID or kAudioObjectUnknown.
    OSStatus translate(const void* qualifier, UInt32 qualifierSize, PropertyReply& reply, CFStringRef deviceUID) const {
        if (!reply.data) {  // size query: no qualifier validation needed
            reply.size = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
        const auto uid   = *static_cast<const CFStringRef*>(qualifier);
        const bool match = deviceUID && uid && CFStringCompare(uid, deviceUID, 0) == kCFCompareEqualTo;
        return reply.value<AudioObjectID>(match ? device_.id() : kAudioObjectUnknown);
    }

    Device& device_;
};

// The whole driver is one leaked singleton created on first factory call.
struct Driver {
    Device   device;
    Stream   input{kInputStreamID, true, device};
    Stream   output{kOutputStreamID, false, device};
    PlugIn   plugin{device};
    std::atomic<UInt32> refCount{1};

    Driver() noexcept { device.attachStreams(&input, &output); }

    Object* lookup(AudioObjectID id) noexcept {
        switch (id) {
            case kPlugInID:       return &plugin;
            case kDeviceID:       return &device;
            case kInputStreamID:  return &input;
            case kOutputStreamID: return &output;
            default:              return nullptr;
        }
    }
};

Driver*                           gDriver = nullptr;
AudioServerPlugInDriverInterface  gInterface;
AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
AudioServerPlugInDriverRef        gRef          = &gInterfacePtr;

// ---------------------------------------------------------------------------
// IUnknown
// ---------------------------------------------------------------------------
HRESULT QueryInterface(void* self, REFIID uuid, LPVOID* out) {
    if (!out) return E_POINTER;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, uuid);
    if (!requested) return E_OUTOFMEMORY;
    const bool known = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!known) {
        *out = nullptr;
        return E_NOINTERFACE;
    }
    gDriver->refCount.fetch_add(1, std::memory_order_relaxed);
    *out = self;
    return S_OK;
}
ULONG AddRef(void*) { return gDriver->refCount.fetch_add(1, std::memory_order_relaxed) + 1; }
ULONG Release(void*) {
    // The singleton lives for the life of coreaudiod; never free it.
    const UInt32 prev = gDriver->refCount.load(std::memory_order_relaxed);
    if (prev > 1) gDriver->refCount.fetch_sub(1, std::memory_order_relaxed);
    return prev > 1 ? prev - 1 : 1;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef host) {
    if (!gDriver->device.ok()) return kAudioHardwareUnspecifiedError;
    gDriver->device.setHost(host);
    gDriver->device.startIpc();  // best effort; the device works without the app
    return kAudioHardwareNoError;
}
OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*) {
    return kAudioHardwareUnsupportedOperationError;
}
OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID) { return kAudioHardwareUnsupportedOperationError; }
OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID id, const AudioServerPlugInClientInfo*) {
    return id == kDeviceID ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID id, const AudioServerPlugInClientInfo*) {
    return id == kDeviceID ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID id, UInt64 action, void* info) {
    if (id != kDeviceID) return kAudioHardwareBadObjectError;
    return gDriver->device.performConfigurationChange(action, info);
}
OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID id, UInt64, void*) {
    return id == kDeviceID ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------
Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID id, pid_t, const AudioObjectPropertyAddress* addr) {
    Object* obj = gDriver->lookup(id);
    if (!obj || !addr) return false;
    PropertyReply probe{};
    return obj->get(*addr, nullptr, 0, probe) != kAudioHardwareUnknownPropertyError;
}
OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID id, pid_t, const AudioObjectPropertyAddress* addr,
                            Boolean* out) {
    Object* obj = gDriver->lookup(id);
    if (!obj) return kAudioHardwareBadObjectError;
    if (!addr || !out) return kAudioHardwareIllegalOperationError;
    PropertyReply probe{};
    if (obj->get(*addr, nullptr, 0, probe) == kAudioHardwareUnknownPropertyError) return kAudioHardwareUnknownPropertyError;
    *out = obj->settable(*addr);
    return kAudioHardwareNoError;
}
OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID id, pid_t, const AudioObjectPropertyAddress* addr,
                             UInt32 qualSize, const void* qual, UInt32* outSize) {
    Object* obj = gDriver->lookup(id);
    if (!obj) return kAudioHardwareBadObjectError;
    if (!addr || !outSize) return kAudioHardwareIllegalOperationError;
    PropertyReply reply{};
    const OSStatus st = obj->get(*addr, qual, qualSize, reply);
    if (st == kAudioHardwareNoError) *outSize = reply.size;
    return st;
}
OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID id, pid_t, const AudioObjectPropertyAddress* addr,
                         UInt32 qualSize, const void* qual, UInt32 inSize, UInt32* outSize, void* outData) {
    Object* obj = gDriver->lookup(id);
    if (!obj) return kAudioHardwareBadObjectError;
    if (!addr || !outSize || !outData) return kAudioHardwareIllegalOperationError;
    PropertyReply reply{inSize, outData, 0};
    const OSStatus st = obj->get(*addr, qual, qualSize, reply);
    if (st == kAudioHardwareNoError) *outSize = reply.size;
    return st;
}
OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID id, pid_t, const AudioObjectPropertyAddress* addr,
                         UInt32 qualSize, const void* qual, UInt32 size, const void* data) {
    Object* obj = gDriver->lookup(id);
    if (!obj) return kAudioHardwareBadObjectError;
    if (!addr || !data) return kAudioHardwareIllegalOperationError;
    PropertyReply probe{};
    if (obj->get(*addr, nullptr, 0, probe) == kAudioHardwareUnknownPropertyError) return kAudioHardwareUnknownPropertyError;
    if (!obj->settable(*addr)) return kAudioHardwareUnsupportedOperationError;
    return obj->set(*addr, qual, qualSize, data, size);
}

// ---------------------------------------------------------------------------
// IO. Everything below this line may run on the real-time IO thread.
// ---------------------------------------------------------------------------
OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID id, UInt32) {
    return id == kDeviceID ? gDriver->device.startIO() : kAudioHardwareBadObjectError;
}
OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID id, UInt32) {
    return id == kDeviceID ? gDriver->device.stopIO() : kAudioHardwareBadObjectError;
}
OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID id, UInt32, Float64* sampleTime, UInt64* hostTime,
                          UInt64* seed) {
    if (id != kDeviceID) return kAudioHardwareBadObjectError;
    return gDriver->device.getZeroTimeStamp(sampleTime, hostTime, seed);
}
OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID id, UInt32, UInt32 op, Boolean* willDo,
                           Boolean* inPlace) {
    if (id != kDeviceID) return kAudioHardwareBadObjectError;
    Device::willDoOperation(op, willDo, inPlace);
    return kAudioHardwareNoError;
}
OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32,
                          const AudioServerPlugInIOCycleInfo*) {
    return kAudioHardwareNoError;
}
OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID id, AudioObjectID stream, UInt32, UInt32 op, UInt32 frames,
                       const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer, void*) {
    if (id != kDeviceID) return kAudioHardwareBadObjectError;
    return gDriver->device.doOperation(stream, op, frames, cycle, mainBuffer);
}
OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32,
                        const AudioServerPlugInIOCycleInfo*) {
    return kAudioHardwareNoError;
}

}  // namespace
}  // namespace conduit

// ---------------------------------------------------------------------------
// CFPlugIn factory (symbol name is referenced from Info.plist).
// ---------------------------------------------------------------------------
extern "C" __attribute__((visibility("default"))) void* ConduitFactory(CFAllocatorRef, CFUUIDRef requestedType) {
    using namespace conduit;
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) return nullptr;

    // Function-local static: initialisation is thread-safe and happens once.
    static const bool ready = [] {
        gDriver = new (std::nothrow) Driver;
        if (!gDriver) return false;
        gInterface = AudioServerPlugInDriverInterface{
            nullptr,
            QueryInterface,
            AddRef,
            Release,
            Initialize,
            CreateDevice,
            DestroyDevice,
            AddDeviceClient,
            RemoveDeviceClient,
            PerformDeviceConfigurationChange,
            AbortDeviceConfigurationChange,
            HasProperty,
            IsPropertySettable,
            GetPropertyDataSize,
            GetPropertyData,
            SetPropertyData,
            StartIO,
            StopIO,
            GetZeroTimeStamp,
            WillDoIOOperation,
            BeginIOOperation,
            DoIOOperation,
            EndIOOperation,
        };
        return true;
    }();
    if (!ready) return nullptr;
    gDriver->refCount.fetch_add(1, std::memory_order_relaxed);
    return gRef;
}

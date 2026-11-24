// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// In-process harness: dlopen()s the built driver binary, drives it through the
// AudioServerPlugInDriverInterface exactly as coreaudiod would (minus the
// sandbox), and verifies the object graph, formats, sample-rate negotiation,
// the zero-timestamp clock and a loopback round trip. No sudo required.
//
//   driver_harness <path/to/Conduit.driver/Contents/MacOS/Conduit>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "IpcServer.hpp"

#ifndef CONDUIT_CHANNELS
#define CONDUIT_CHANNELS 16
#endif
static constexpr UInt32 kExpectedChannels = CONDUIT_CHANNELS;

static int failures = 0;
#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);          \
            ++failures;                                                          \
        }                                                                        \
    } while (0)

static constexpr AudioObjectID kPlugIn = 1, kDevice = 2, kIn = 3, kOut = 4;

static std::atomic<int>    gConfigChangeRequests{0};
static std::atomic<UInt64> gRequestedAction{0};

static OSStatus hostPropertiesChanged(AudioServerPlugInHostRef, AudioObjectID, UInt32, const AudioObjectPropertyAddress*) {
    return 0;
}
static OSStatus hostRequestChange(AudioServerPlugInHostRef, AudioObjectID, UInt64 action, void*) {
    gRequestedAction = action;
    ++gConfigChangeRequests;
    return 0;
}
static const AudioServerPlugInHostInterface kHost{hostPropertiesChanged, nullptr, nullptr, nullptr, hostRequestChange};

static AudioServerPlugInDriverInterface* gVt;
static AudioServerPlugInDriverRef        gDrv;

static AudioObjectPropertyAddress A(AudioObjectPropertySelector s, AudioObjectPropertyScope sc = kAudioObjectPropertyScopeGlobal) {
    return {s, sc, kAudioObjectPropertyElementMain};
}

template <class T>
static OSStatus getValue(AudioObjectID obj, AudioObjectPropertyAddress a, T& out) {
    UInt32 sz = 0;
    OSStatus st = gVt->GetPropertyDataSize(gDrv, obj, 0, &a, 0, nullptr, &sz);
    if (st) return st;
    if (sz != sizeof(T)) return -1;
    return gVt->GetPropertyData(gDrv, obj, 0, &a, 0, nullptr, sizeof(T), &sz, &out);
}
template <class T>
static std::vector<T> getArray(AudioObjectID obj, AudioObjectPropertyAddress a) {
    UInt32 sz = 0;
    if (gVt->GetPropertyDataSize(gDrv, obj, 0, &a, 0, nullptr, &sz)) return {};
    std::vector<T> v(sz / sizeof(T));
    UInt32 got = 0;
    if (gVt->GetPropertyData(gDrv, obj, 0, &a, 0, nullptr, sz, &got, v.data())) return {};
    v.resize(got / sizeof(T));
    return v;
}

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: %s <driver-binary>\n", argv[0]); return 2; }
    void* lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { std::printf("dlopen failed: %s\n", dlerror()); return 2; }
    auto factory = reinterpret_cast<void* (*)(CFAllocatorRef, CFUUIDRef)>(dlsym(lib, "ConduitFactory"));
    if (!factory) { std::printf("ConduitFactory not exported\n"); return 2; }

    CHECK(factory(nullptr, CFUUIDGetConstantUUIDWithBytes(nullptr, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)) == nullptr);
    gDrv = static_cast<AudioServerPlugInDriverRef>(factory(nullptr, kAudioServerPlugInTypeUUID));
    CHECK(gDrv != nullptr);
    if (!gDrv) return 1;
    gVt = *gDrv;

    // IPC authorisation policy (regression: coreaudiod starts at boot while /dev/console is still owned by root)
    CHECK(conduit::IpcServer::isAuthorised(0, 202, 501));      // root
    CHECK(conduit::IpcServer::isAuthorised(202, 202, 0));      // the server's own uid
    CHECK(conduit::IpcServer::isAuthorised(501, 202, 501));    // the user who owns the console now
    CHECK(!conduit::IpcServer::isAuthorised(502, 202, 501));   // another local user
    CHECK(!conduit::IpcServer::isAuthorised(501, 202, 0));     // at the login window the console is root's: a user is not let in...
    CHECK(conduit::IpcServer::isAuthorised(501, 202, 501));    // ...but the same user is, as soon as the console owner is re-read

    // IUnknown
    LPVOID iface = nullptr;
    CFUUIDRef iu = IUnknownUUID;
    CHECK(gVt->QueryInterface(gDrv, CFUUIDGetUUIDBytes(iu), &iface) == S_OK && iface == gDrv);
    CHECK(gVt->QueryInterface(gDrv, CFUUIDGetUUIDBytes(CFUUIDGetConstantUUIDWithBytes(nullptr, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9)), &iface) == E_NOINTERFACE);
    CHECK(gVt->Initialize(gDrv, &kHost) == 0);

    // Object graph
    AudioClassID cls = 0;
    CHECK(getValue(kPlugIn, A(kAudioObjectPropertyClass), cls) == 0 && cls == kAudioPlugInClassID);
    auto devs = getArray<AudioObjectID>(kPlugIn, A(kAudioPlugInPropertyDeviceList));
    CHECK(devs.size() == 1 && devs[0] == kDevice);
    CHECK(getValue(kDevice, A(kAudioObjectPropertyClass), cls) == 0 && cls == kAudioDeviceClassID);
    auto owned = getArray<AudioObjectID>(kDevice, A(kAudioObjectPropertyOwnedObjects));
    CHECK(owned.size() == 2);
    CHECK(getArray<AudioObjectID>(kDevice, A(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)) == std::vector<AudioObjectID>{kIn});
    CHECK(getArray<AudioObjectID>(kDevice, A(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)) == std::vector<AudioObjectID>{kOut});

    // UID translation (qualifier-based)
    {
        CFStringRef uid = nullptr;
        auto a = A(kAudioDevicePropertyDeviceUID);
        UInt32 sz = sizeof(uid);
        CHECK(gVt->GetPropertyData(gDrv, kDevice, 0, &a, 0, nullptr, sz, &sz, &uid) == 0 && uid);
        AudioObjectID found = 0;
        auto t = A(kAudioPlugInPropertyTranslateUIDToDevice);
        sz = sizeof(found);
        CHECK(gVt->GetPropertyData(gDrv, kPlugIn, 0, &t, sizeof(uid), &uid, sizeof(found), &sz, &found) == 0 && found == kDevice);
        if (uid) CFRelease(uid);
    }

    // Formats: 16ch interleaved packed float32, rates 44.1/48/96k
    AudioStreamBasicDescription fmt{};
    CHECK(getValue(kOut, A(kAudioStreamPropertyVirtualFormat), fmt) == 0);
    CHECK(fmt.mChannelsPerFrame == kExpectedChannels && fmt.mBitsPerChannel == 32 && fmt.mFormatID == kAudioFormatLinearPCM);
    CHECK(fmt.mBytesPerFrame == kExpectedChannels * 4 && (fmt.mFormatFlags & kAudioFormatFlagIsFloat));
    CHECK(fmt.mSampleRate == 48000.0);
    auto rates = getArray<AudioValueRange>(kDevice, A(kAudioDevicePropertyAvailableNominalSampleRates));
    CHECK(rates.size() == 3 && rates[0].mMinimum == 44100 && rates[1].mMinimum == 48000 && rates[2].mMinimum == 96000);
    UInt32 dir = 9;
    CHECK(getValue(kIn, A(kAudioStreamPropertyDirection), dir) == 0 && dir == 1);
    CHECK(getValue(kOut, A(kAudioStreamPropertyDirection), dir) == 0 && dir == 0);

    // Unknown things are rejected cleanly
    {
        auto bad = A('zzzz');
        UInt32 sz = 0;
        CHECK(!gVt->HasProperty(gDrv, kDevice, 0, &bad));
        CHECK(gVt->GetPropertyDataSize(gDrv, kDevice, 0, &bad, 0, nullptr, &sz) == kAudioHardwareUnknownPropertyError);
        CHECK(gVt->GetPropertyDataSize(gDrv, 99, 0, &bad, 0, nullptr, &sz) == kAudioHardwareBadObjectError);
        AudioObjectPropertyAddress nsr = A(kAudioDevicePropertyNominalSampleRate);
        Boolean settable = false;
        CHECK(gVt->IsPropertySettable(gDrv, kDevice, 0, &nsr, &settable) == 0 && settable);
        Float64 bogus = 12345.0;
        CHECK(gVt->SetPropertyData(gDrv, kDevice, 0, &nsr, 0, nullptr, sizeof(bogus), &bogus) == kAudioDeviceUnsupportedFormatError);
    }

    // Sample-rate negotiation: set -> host asked for config change -> Perform applies it
    {
        Float64 want = 96000.0;
        auto nsr = A(kAudioDevicePropertyNominalSampleRate);
        CHECK(gVt->SetPropertyData(gDrv, kDevice, 0, &nsr, 0, nullptr, sizeof(want), &want) == 0);
        for (int i = 0; i < 200 && gConfigChangeRequests == 0; ++i) usleep(10'000);
        CHECK(gConfigChangeRequests == 1);
        CHECK(gVt->PerformDeviceConfigurationChange(gDrv, kDevice, gRequestedAction, nullptr) == 0);
        Float64 now = 0;
        CHECK(getValue(kDevice, nsr, now) == 0 && now == 96000.0);
        CHECK(getValue(kIn, A(kAudioStreamPropertyVirtualFormat), fmt) == 0 && fmt.mSampleRate == 96000.0);
    }

    // IO: loopback round trip at 96 kHz
    CHECK(gVt->StartIO(gDrv, kDevice, 100) == 0);
    CHECK(gVt->StartIO(gDrv, kDevice, 101) == 0);
    Float64 z0 = -1; UInt64 h0 = 0, seed0 = 0;
    CHECK(gVt->GetZeroTimeStamp(gDrv, kDevice, 100, &z0, &h0, &seed0) == 0);
    CHECK(z0 == 0.0 && seed0 != 0);

    Boolean will = false, inPlace = false;
    CHECK(gVt->WillDoIOOperation(gDrv, kDevice, 100, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace) == 0 && will && inPlace);
    CHECK(gVt->WillDoIOOperation(gDrv, kDevice, 100, kAudioServerPlugInIOOperationReadInput, &will, &inPlace) == 0 && will && inPlace);
    CHECK(gVt->WillDoIOOperation(gDrv, kDevice, 100, kAudioServerPlugInIOOperationProcessOutput, &will, &inPlace) == 0 && !will);

    constexpr UInt32 kFrames = 512;
    std::vector<float> tx(kFrames * kExpectedChannels), rx(kFrames * kExpectedChannels, -1.f);
    for (UInt32 f = 0; f < kFrames; ++f)
        for (UInt32 c = 0; c < kExpectedChannels; ++c) tx[f * kExpectedChannels + c] = static_cast<float>(f + 1) + 1000.f * static_cast<float>(c);
    AudioServerPlugInIOCycleInfo cycle{};
    cycle.mOutputTime.mSampleTime = 4096;
    cycle.mInputTime.mSampleTime  = 4096;
    CHECK(gVt->DoIOOperation(gDrv, kDevice, kOut, 100, kAudioServerPlugInIOOperationWriteMix, kFrames, &cycle, tx.data(), nullptr) == 0);
    CHECK(gVt->DoIOOperation(gDrv, kDevice, kIn, 101, kAudioServerPlugInIOOperationReadInput, kFrames, &cycle, rx.data(), nullptr) == 0);
    CHECK(rx == tx);
    // Different read alignment: offset by 100 frames -> tail beyond what was written reads as silence.
    cycle.mInputTime.mSampleTime = 4096 + 100;
    CHECK(gVt->DoIOOperation(gDrv, kDevice, kIn, 101, kAudioServerPlugInIOOperationReadInput, kFrames, &cycle, rx.data(), nullptr) == 0);
    bool alignedOk = true;
    for (UInt32 f = 0; f < kFrames - 100; ++f)
        for (UInt32 c = 0; c < kExpectedChannels; ++c) alignedOk &= rx[f * kExpectedChannels + c] == tx[(f + 100) * kExpectedChannels + c];
    for (UInt32 f = kFrames - 100; f < kFrames; ++f)
        for (UInt32 c = 0; c < kExpectedChannels; ++c) alignedOk &= rx[f * kExpectedChannels + c] == 0.f;
    CHECK(alignedOk);

    // Zero-timestamp clock advances at the device rate (96 kHz => ~1 period per 170.7 ms).
    usleep(400'000);
    Float64 z1 = 0; UInt64 h1 = 0, seed1 = 0;
    CHECK(gVt->GetZeroTimeStamp(gDrv, kDevice, 100, &z1, &h1, &seed1) == 0);
    CHECK(seed1 == seed0 && h1 > h0 && std::fmod(z1, 16384.0) == 0.0);
    mach_timebase_info_data_t tb{}; mach_timebase_info(&tb);
    const double elapsedSec = static_cast<double>(h1 - h0) * tb.numer / tb.denom / 1e9;
    const double frames     = z1 - z0;
    CHECK(frames > 0 && std::fabs(frames / elapsedSec - 96000.0) / 96000.0 < 0.001);  // within 0.1 %
    std::printf("  clock: %.0f frames in %.4f s = %.1f Hz\n", frames, elapsedSec, frames / elapsedSec);

    // Restart bumps the seed and clears the ring.
    CHECK(gVt->StopIO(gDrv, kDevice, 101) == 0);
    CHECK(gVt->StopIO(gDrv, kDevice, 100) == 0);
    CHECK(gVt->StopIO(gDrv, kDevice, 100) == kAudioHardwareIllegalOperationError);
    CHECK(gVt->StartIO(gDrv, kDevice, 100) == 0);
    UInt64 seed2 = 0;
    CHECK(gVt->GetZeroTimeStamp(gDrv, kDevice, 100, &z1, &h1, &seed2) == 0 && seed2 != seed0);
    cycle.mInputTime.mSampleTime = 4096;
    CHECK(gVt->DoIOOperation(gDrv, kDevice, kIn, 100, kAudioServerPlugInIOOperationReadInput, kFrames, &cycle, rx.data(), nullptr) == 0);
    bool silent = true;
    for (float s : rx) silent &= (s == 0.f);
    CHECK(silent);
    CHECK(gVt->StopIO(gDrv, kDevice, 100) == 0);

    std::printf(failures ? "driver harness FAILED (%d)\n" : "driver harness PASSED\n", failures);
    return failures ? 1 : 0;
}

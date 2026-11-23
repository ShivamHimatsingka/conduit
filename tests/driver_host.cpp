// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Minimal stand-in for coreaudiod: loads the driver, runs IO cycles against a
// 1 kHz tone on channel 0, and stays alive so a *separate process* (conduitctl)
// can connect over Mach IPC and exercise control, telemetry and injection.
//
//   CONDUIT_IPC_ALLOW_REGISTER=1 driver_host <driver-binary> <seconds>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#ifndef CONDUIT_CHANNELS
#define CONDUIT_CHANNELS 16
#endif
static constexpr UInt32 kCh = CONDUIT_CHANNELS, kBlock = 480;
static constexpr AudioObjectID kDevice = 2, kIn = 3, kOut = 4;

static OSStatus hostChanged(AudioServerPlugInHostRef, AudioObjectID, UInt32, const AudioObjectPropertyAddress*) { return 0; }
static OSStatus hostRequest(AudioServerPlugInHostRef, AudioObjectID, UInt64, void*) { return 0; }
static const AudioServerPlugInHostInterface kHost{hostChanged, nullptr, nullptr, nullptr, hostRequest};

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: %s <driver-binary> <seconds>\n", argv[0]); return 2; }
    void* lib = dlopen(argv[1], RTLD_NOW);
    auto factory = lib ? reinterpret_cast<void* (*)(CFAllocatorRef, CFUUIDRef)>(dlsym(lib, "ConduitFactory")) : nullptr;
    if (!factory) { std::fprintf(stderr, "cannot load driver\n"); return 2; }
    auto drv = static_cast<AudioServerPlugInDriverRef>(factory(nullptr, kAudioServerPlugInTypeUUID));
    auto* vt = *drv;
    if (vt->Initialize(drv, &kHost) || vt->StartIO(drv, kDevice, 1)) { std::fprintf(stderr, "init failed\n"); return 1; }

    mach_timebase_info_data_t tb{}; mach_timebase_info(&tb);
    const double tpf = 1e9 * tb.denom / tb.numer / 48000.0;
    std::vector<float> tx(kBlock * kCh), rx(kBlock * kCh);
    AudioServerPlugInIOCycleInfo cyc{};
    int64_t nextIn = 0;
    std::vector<float> peak(kCh, 0.f);
    std::printf("READY\n"); std::fflush(stdout);

    const double end = static_cast<double>(mach_absolute_time()) + std::atof(argv[2]) * 1e9 * tb.denom / tb.numer;
    while (static_cast<double>(mach_absolute_time()) < end) {
        Float64 z; UInt64 h, seed;
        vt->GetZeroTimeStamp(drv, kDevice, 1, &z, &h, &seed);
        const double tNow = z + static_cast<double>(mach_absolute_time() - h) / tpf;
        while (static_cast<double>(nextIn + kBlock) <= tNow) {
            // App writes the block 2 cycles ahead of when the input reads it back.
            const int64_t wt = nextIn + 2 * kBlock;
            for (UInt32 f = 0; f < kBlock; ++f) {
                for (UInt32 c = 0; c < kCh; ++c) tx[f * kCh + c] = 0.f;
                tx[f * kCh] = 0.5f * static_cast<float>(std::sin(2.0 * M_PI * 1000.0 * static_cast<double>(wt + f) / 48000.0));
            }
            cyc.mOutputTime.mSampleTime = static_cast<Float64>(wt);
            vt->DoIOOperation(drv, kDevice, kOut, 1, kAudioServerPlugInIOOperationWriteMix, kBlock, &cyc, tx.data(), nullptr);
            cyc.mInputTime.mSampleTime = static_cast<Float64>(nextIn);
            vt->DoIOOperation(drv, kDevice, kIn, 1, kAudioServerPlugInIOOperationReadInput, kBlock, &cyc, rx.data(), nullptr);
            for (UInt32 f = 0; f < kBlock; ++f)
                for (UInt32 c = 0; c < kCh; ++c) peak[c] = std::fmax(peak[c], std::fabs(rx[f * kCh + c]));
            nextIn += kBlock;
        }
        usleep(2000);
    }
    vt->StopIO(drv, kDevice, 1);
    std::printf("host done, final input peaks:");
    for (UInt32 c = 0; c < kCh; ++c) if (peak[c] > 0.f) std::printf(" ch%u=%.3f", c, peak[c]);
    std::printf("\n");
    return 0;
}

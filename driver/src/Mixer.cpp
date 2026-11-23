// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
#include "Mixer.hpp"

#include <cmath>
#include <cstring>
#include <new>

namespace conduit {

bool Mixer::init(ConduitShared* shared, TimelineRing* loopback, TimelineRing* app) noexcept {
    s_    = shared;
    loop_ = loopback;
    app_  = app;
    const std::size_t n = static_cast<std::size_t>(kChannels) * kChannels;
    scratchMix_.reset(new (std::nothrow) float[static_cast<std::size_t>(kChunk) * kChannels]);
    scratchApp_.reset(new (std::nothrow) float[static_cast<std::size_t>(kChunk) * kChannels]);
    prevCoef_.reset(new (std::nothrow) float[n]);
    curCoef_.reset(new (std::nothrow) float[n]);
    entries_.reset(new (std::nothrow) Entry[n]);
    rowStart_.reset(new (std::nothrow) std::uint32_t[kChannels + 1]);
    if (!s_ || !loop_ || !scratchMix_ || !scratchApp_ || !prevCoef_ || !curCoef_ || !entries_ || !rowStart_) return false;
    std::memset(scratchMix_.get(), 0, sizeof(float) * kChunk * kChannels);  // pre-fault
    std::memset(scratchApp_.get(), 0, sizeof(float) * kChunk * kChannels);
    std::memset(entries_.get(), 0, sizeof(Entry) * n);
    snapshot();
    return true;
}

void Mixer::snapshot() noexcept {
    computeMatrix(prevCoef_.get());
    computeBusGains(prevBus_);
}

// Effective coefficient = matrix[bus][in] * stripGain[in], where a strip is
// silenced by mute, or by solo being active on some *other* strip.
void Mixer::computeMatrix(float* out) const noexcept {
    const std::uint64_t mute = conduit_mute_mask(s_), solo = conduit_solo_mask(s_);
    float strip[kMax];
    for (std::uint32_t i = 0; i < kChannels; ++i) {
        const std::uint64_t bit = std::uint64_t{1} << i;
        const bool silenced     = (mute & bit) || (solo && !(solo & bit));
        strip[i]                = silenced ? 0.0f : conduit_get_in_gain(s_, i);
    }
    for (std::uint32_t j = 0; j < kChannels; ++j)
        for (std::uint32_t i = 0; i < kChannels; ++i) out[j * kChannels + i] = conduit_get_matrix(s_, j, i) * strip[i];
}

void Mixer::computeBusGains(float* out) const noexcept {
    const std::uint64_t mute = conduit_bus_mute_mask(s_);
    for (std::uint32_t j = 0; j < kChannels; ++j) out[j] = (mute & (std::uint64_t{1} << j)) ? 0.0f : conduit_get_bus_gain(s_, j);
}

void Mixer::meter(const float* x, std::uint32_t frames, std::uint32_t* peakOut, std::uint32_t* msqOut) noexcept {
    float pk[kChannels]{}, sq[kChannels]{};
    for (std::uint32_t f = 0; f < frames; ++f) {
        const float* row = x + static_cast<std::size_t>(f) * kChannels;
        for (std::uint32_t c = 0; c < kChannels; ++c) {
            const float v = std::fabs(row[c]);
            pk[c]         = v > pk[c] ? v : pk[c];
            sq[c] += v * v;
        }
    }
    const float inv = frames ? 1.0f / static_cast<float>(frames) : 0.0f;
    for (std::uint32_t c = 0; c < kChannels; ++c) {
        conduit_meter_hold(&peakOut[c], pk[c]);
        conduit_st32(&msqOut[c], conduit_f2b(sq[c] * inv));
    }
}

void Mixer::write(std::int64_t t, std::uint32_t frames, const float* in) noexcept {
    if (frames == 0) return;
    meter(in, frames, s_->meters.inPeak, s_->meters.inMsq);
    __atomic_fetch_add(&s_->meters.blockCount, 1, __ATOMIC_RELAXED);

    float* cur  = curCoef_.get();
    float* prev = prevCoef_.get();
    computeMatrix(cur);

    // Sparse rows over the union of old and new non-zero coefficients, so
    // entries fading to zero are still ramped rather than clicking off.
    const float inv = 1.0f / static_cast<float>(frames);
    std::uint32_t k = 0;
    for (std::uint32_t j = 0; j < kChannels; ++j) {
        rowStart_[j] = k;
        for (std::uint32_t i = 0; i < kChannels; ++i) {
            const float c0 = prev[j * kChannels + i], c1 = cur[j * kChannels + i];
            if (c0 != 0.0f || c1 != 0.0f) entries_[k++] = Entry{static_cast<std::uint16_t>(i), c0, (c1 - c0) * inv};
        }
    }
    rowStart_[kChannels] = k;

    for (std::uint32_t o = 0; o < frames; o += kChunk) {
        const std::uint32_t n = frames - o < kChunk ? frames - o : kChunk;
        float* out            = scratchMix_.get();
        for (std::uint32_t f = 0; f < n; ++f) {
            const float  fl = static_cast<float>(o + f + 1);
            const float* x  = in + static_cast<std::size_t>(o + f) * kChannels;
            float*       y  = out + static_cast<std::size_t>(f) * kChannels;
            for (std::uint32_t j = 0; j < kChannels; ++j) {
                float acc = 0.0f;
                for (std::uint32_t e = rowStart_[j]; e < rowStart_[j + 1]; ++e) acc += (entries_[e].c0 + entries_[e].step * fl) * x[entries_[e].input];
                y[j] = acc;
            }
        }
        loop_->write(t + o, n, out);
    }
    std::memcpy(prev, cur, sizeof(float) * kChannels * kChannels);
}

void Mixer::read(std::int64_t t, std::uint32_t frames, float* dst) noexcept {
    if (frames == 0) return;
    computeBusGains(curBus_);
    bool unity = true;
    for (std::uint32_t j = 0; j < kChannels; ++j) unity &= (prevBus_[j] == 1.0f && curBus_[j] == 1.0f);
    const float inv = 1.0f / static_cast<float>(frames);

    for (std::uint32_t o = 0; o < frames; o += kChunk) {
        const std::uint32_t n = frames - o < kChunk ? frames - o : kChunk;
        float* d              = dst + static_cast<std::size_t>(o) * kChannels;
        loop_->read(t + o, n, d);
        if (app_ && app_->read(t + o, n, scratchApp_.get()) > 0) {
            const float* a = scratchApp_.get();
            for (std::size_t i = 0, total = static_cast<std::size_t>(n) * kChannels; i < total; ++i) d[i] += a[i];
        }
        if (!unity) {
            for (std::uint32_t f = 0; f < n; ++f) {
                const float fl = static_cast<float>(o + f + 1);
                float*      row = d + static_cast<std::size_t>(f) * kChannels;
                for (std::uint32_t j = 0; j < kChannels; ++j) row[j] *= prevBus_[j] + (curBus_[j] - prevBus_[j]) * inv * fl;
            }
        }
    }
    std::memcpy(prevBus_, curBus_, sizeof(float) * kChannels);
    meter(dst, frames, s_->meters.busPeak, s_->meters.busMsq);
}

}  // namespace conduit

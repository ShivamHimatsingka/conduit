// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Host-side tests for TimelineRing: correctness, gap/underrun semantics and a
// two-thread stress test that proves the consumer never observes torn or
// foreign data.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

#include "RingBuffer.hpp"

using conduit::TimelineRing;

static int failures = 0;
#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);          \
            ++failures;                                                          \
        }                                                                        \
    } while (0)

static constexpr std::uint32_t kCh  = 4;
static constexpr std::uint32_t kCap = 1024;

struct Fixture {
    void*       mem;
    TimelineRing ring;
    Fixture(std::uint32_t ch = kCh, std::uint32_t cap = kCap) {
        const std::size_t bytes = TimelineRing::bytesRequired(ch, cap);
        mem                     = std::aligned_alloc(conduit::kCacheLine, (bytes + 63) & ~std::size_t{63});
        ring                    = TimelineRing::create(mem, ch, cap);
    }
    ~Fixture() { std::free(mem); }
};

static float sampleFor(std::int64_t frame, std::uint32_t ch) { return static_cast<float>((frame % 100000) + 1) + 0.25f * static_cast<float>(ch); }

static std::vector<float> makeBlock(std::int64_t start, std::uint32_t frames) {
    std::vector<float> v(static_cast<std::size_t>(frames) * kCh);
    for (std::uint32_t f = 0; f < frames; ++f)
        for (std::uint32_t c = 0; c < kCh; ++c) v[f * kCh + c] = sampleFor(start + f, c);
    return v;
}

static void testRejectsBadArgs() {
    alignas(64) static std::byte small[4096];
    CHECK(!TimelineRing::create(nullptr, 2, 64).valid());
    CHECK(!TimelineRing::create(small, 0, 64).valid());
    CHECK(!TimelineRing::create(small, 2, 100).valid());       // not a power of two
    CHECK(!TimelineRing::create(small + 1, 2, 64).valid());    // misaligned
    CHECK(TimelineRing::create(small, 2, 64).valid());
}

static void testRoundTripAndWrap() {
    Fixture fx;
    auto&   r = fx.ring;
    // Write across the physical wrap point (capacity 1024; start at 1000, 100 frames).
    auto in = makeBlock(1000, 100);
    r.write(1000, 100, in.data());
    std::vector<float> out(100 * kCh, -1.f);
    CHECK(r.read(1000, 100, out.data()) == 100);
    CHECK(out == in);
}

static void testUnwrittenAndGapAreSilent() {
    Fixture fx;
    auto&   r = fx.ring;
    std::vector<float> out(64 * kCh, -1.f);
    CHECK(r.read(0, 64, out.data()) == 0);  // nothing produced yet
    for (float s : out) CHECK(s == 0.f);

    auto a = makeBlock(0, 64);
    r.write(0, 64, a.data());
    // Producer skips 2000 frames (> capacity): everything in between must read as silence.
    auto b = makeBlock(2064, 64);
    r.write(2064, 64, b.data());
    std::vector<float> mid(256 * kCh, -1.f);
    r.read(1900, 256, mid.data());
    for (std::uint32_t f = 0; f < 164; ++f)
        for (std::uint32_t c = 0; c < kCh; ++c) CHECK(mid[f * kCh + c] == 0.f);  // [1900, 2064)
    for (std::uint32_t f = 164; f < 228; ++f)
        for (std::uint32_t c = 0; c < kCh; ++c) CHECK(mid[f * kCh + c] == sampleFor(1900 + f, c));
    for (std::uint32_t f = 228; f < 256; ++f)
        for (std::uint32_t c = 0; c < kCh; ++c) CHECK(mid[f * kCh + c] == 0.f);  // beyond writeEnd
    CHECK(r.gapFrames() > 0);
}

static void testOverwrittenDataIsNotReturned() {
    Fixture fx;
    auto&   r = fx.ring;
    for (std::int64_t t = 0; t < 4096; t += 128) {
        auto blk = makeBlock(t, 128);
        r.write(t, 128, blk.data());
    }
    std::vector<float> out(128 * kCh, -1.f);
    CHECK(r.read(0, 128, out.data()) == 0);  // long since overwritten
    for (float s : out) CHECK(s == 0.f);
    CHECK(r.read(4096 - 128, 128, out.data()) == 128);
    CHECK(out == makeBlock(4096 - 128, 128));
}

static void testNegativeSampleTimes() {
    Fixture fx;
    auto&   r = fx.ring;
    auto blk = makeBlock(-32, 64);  // straddles zero
    r.write(-32, 64, blk.data());
    std::vector<float> out(64 * kCh);
    CHECK(r.read(-32, 64, out.data()) == 64);
    CHECK(out == blk);
}

static void testConcurrentStress() {
    constexpr std::uint32_t kChunkP = 96, kChunkC = 160;  // mismatched block sizes on purpose
    constexpr std::int64_t  kTotal  = 3'000'000;
    Fixture fx;
    auto&   r = fx.ring;
    std::atomic<bool>        done{false};
    std::atomic<std::int64_t> produced{0};

    std::thread producer([&] {
        for (std::int64_t t = 0; t < kTotal; t += kChunkP) {
            auto blk = makeBlock(t, kChunkP);
            r.write(t, kChunkP, blk.data());
            produced.store(t + kChunkP, std::memory_order_release);
            if (((t / kChunkP) & 0x3F) == 0) std::this_thread::yield();
        }
        done.store(true);
    });

    std::uint64_t bad = 0, good = 0;
    std::vector<float> out(static_cast<std::size_t>(kChunkC) * kCh);
    std::uint64_t iter = 0;
    while (!done.load()) {
        // Read close to the oldest-valid edge so the producer is actively
        // overwriting the very slots being copied (exercises the seqlock).
        const std::int64_t p = produced.load(std::memory_order_acquire);
        const std::int64_t t = std::max<std::int64_t>(0, p - (kCap - 200) + static_cast<std::int64_t>(iter++ % 190));
        r.read(t, kChunkC, out.data());
        for (std::uint32_t f = 0; f < kChunkC; ++f)
            for (std::uint32_t c = 0; c < kCh; ++c) {
                const float v = out[f * kCh + c];
                if (v == 0.f) continue;  // silence is always legal
                (v == sampleFor(t + f, c)) ? ++good : ++bad;  // anything else = torn / stale / foreign
            }
    }
    producer.join();
    std::printf("  stress: %llu good samples, %llu corrupt, lapped=%llu underrun=%llu\n", (unsigned long long)good,
                (unsigned long long)bad, (unsigned long long)r.lappedFrames(), (unsigned long long)r.underrunFrames());
    CHECK(bad == 0);
    CHECK(good > 0);
}

int main() {
    std::printf("TimelineRing tests\n");
    testRejectsBadArgs();
    testRoundTripAndWrap();
    testUnwrittenAndGapAreSilent();
    testOverwrittenDataIsNotReturned();
    testNegativeSampleTimes();
    testConcurrentStress();
    std::printf(failures ? "FAILED (%d)\n" : "PASSED\n", failures);
    return failures ? 1 : 0;
}

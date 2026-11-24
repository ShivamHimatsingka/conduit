// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// The control/telemetry/injection region shared with the app. Allocated with
// mach_vm_allocate so it can be wrapped in a memory-entry port and handed to
// the app over Mach IPC; no filesystem name, no shm_open, nothing the
// coreaudiod sandbox would deny.
#pragma once

#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdlib.h>
#include <sys/mman.h>

#include "Config.hpp"
#include "RingBuffer.hpp"
#include "conduit_shared.h"

namespace conduit {

class SharedRegion {
public:
    SharedRegion() noexcept = default;
    SharedRegion(const SharedRegion&)            = delete;
    SharedRegion& operator=(const SharedRegion&) = delete;
    ~SharedRegion() {
        if (entry_ != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), entry_);
        if (addr_) mach_vm_deallocate(mach_task_self(), addr_, bytes_);
    }

    // Control plane. Returns false on any failure (driver then runs without IPC).
    [[nodiscard]] bool init() noexcept {
        const std::uint32_t ringBytes = static_cast<std::uint32_t>(TimelineRing::bytesRequired(kChannels, kRingFrames));
        std::uint32_t ringOffset      = 0;
        const std::uint32_t total     = conduit_region_bytes(ringBytes, &ringOffset);
        bytes_                        = total;
        if (mach_vm_allocate(mach_task_self(), &addr_, bytes_, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
            addr_ = 0;
            return false;
        }
        ::mlock(reinterpret_cast<void*>(addr_), bytes_);  // best effort
        shared_ = reinterpret_cast<ConduitShared*>(addr_);
        conduit_shared_init(shared_, kChannels, kRingFrames, ringBytes, ringOffset, total);
        // Fresh identity for this driver instance. A restarted coreaudiod creates a new region with a new ID, which is how
        // the app notices its mapping is stale. Written before any client can connect (the Mach server starts later).
        shared_->header.instanceID = (static_cast<std::uint64_t>(arc4random()) << 32) | arc4random() | 1u;
        appRing_ = TimelineRing::create(reinterpret_cast<std::uint8_t*>(addr_) + ringOffset, kChannels, kRingFrames);
        if (!appRing_.valid()) return false;

        memory_object_size_t size = bytes_;
        return mach_make_memory_entry_64(mach_task_self(), &size, addr_, VM_PROT_READ | VM_PROT_WRITE, &entry_, MACH_PORT_NULL) == KERN_SUCCESS &&
               size == bytes_;
    }

    [[nodiscard]] ConduitShared* shared() const noexcept { return shared_; }
    [[nodiscard]] TimelineRing& appRing() noexcept { return appRing_; }
    [[nodiscard]] mach_port_t entry() const noexcept { return entry_; }
    [[nodiscard]] std::uint64_t bytes() const noexcept { return bytes_; }

private:
    mach_vm_address_t addr_{0};
    mach_vm_size_t    bytes_{0};
    ConduitShared*    shared_{nullptr};
    TimelineRing      appRing_;
    mach_port_t       entry_{MACH_PORT_NULL};
};

}  // namespace conduit

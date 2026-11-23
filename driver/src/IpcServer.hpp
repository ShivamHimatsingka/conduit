// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Mach "hello" server. Registers the service named in Info.plist
// (AudioServerPlugIn_MachServices) and answers each authorised client with a
// send right to the shared-memory entry. Runs on its own thread; never touches
// the IO path.
#pragma once

#include <mach/mach.h>

#include <cstdint>

namespace conduit {

class IpcServer {
public:
    // Starts the server thread. Returns false if the service could not be claimed.
    bool start(const char* serviceName, mach_port_t regionEntry, std::uint64_t regionBytes) noexcept;

private:
    static void* threadMain(void* self) noexcept;
    void         run() noexcept;
    [[nodiscard]] bool authorised(std::uint32_t euid) const noexcept;

    mach_port_t   service_{MACH_PORT_NULL};
    mach_port_t   region_{MACH_PORT_NULL};
    std::uint64_t regionBytes_{0};
    std::uint32_t consoleUid_{0};
};

}  // namespace conduit

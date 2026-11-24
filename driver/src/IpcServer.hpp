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

    // Who may map the shared region: root, the server's own uid, or whoever owns /dev/console *right now*.
    // The console owner must be looked up per request: at boot coreaudiod starts before anyone logs in, when the
    // owner is still root, and a value cached at start would lock the real user out for the whole session.
    [[nodiscard]] static constexpr bool isAuthorised(std::uint32_t euid, std::uint32_t selfEuid, std::uint32_t consoleOwner) noexcept {
        return euid == 0 || euid == selfEuid || euid == consoleOwner;
    }

private:
    static void* threadMain(void* self) noexcept;
    void         run() noexcept;
    [[nodiscard]] static bool authorised(std::uint32_t euid) noexcept;

    mach_port_t   service_{MACH_PORT_NULL};
    mach_port_t   region_{MACH_PORT_NULL};
    std::uint64_t regionBytes_{0};
};

}  // namespace conduit

// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
#include "IpcServer.hpp"

#include <bsm/libbsm.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>

#include "conduit_client.h"

namespace conduit {

bool IpcServer::start(const char* serviceName, mach_port_t regionEntry, std::uint64_t regionBytes) noexcept {
    region_      = regionEntry;
    regionBytes_ = regionBytes;

    // Normal path inside coreaudiod: the service is pre-declared, so check in.
    kern_return_t kr = bootstrap_check_in(bootstrap_port, serviceName, &service_);
    if (kr != KERN_SUCCESS && std::getenv("CONDUIT_IPC_ALLOW_REGISTER")) {
        // Development/test hosts (not coreaudiod): claim the name ourselves.
        if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &service_) == KERN_SUCCESS &&
            mach_port_insert_right(mach_task_self(), service_, service_, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            kr = bootstrap_register(bootstrap_port, const_cast<char*>(serviceName), service_);
#pragma clang diagnostic pop
        }
    }
    if (kr != KERN_SUCCESS || service_ == MACH_PORT_NULL) return false;

    struct stat st{};
    consoleUid_ = ::stat("/dev/console", &st) == 0 ? st.st_uid : 0;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t tid;
    const int rc = pthread_create(&tid, &attr, &IpcServer::threadMain, this);
    pthread_attr_destroy(&attr);
    return rc == 0;
}

void* IpcServer::threadMain(void* self) noexcept {
    pthread_setname_np("conduit.ipc");
    static_cast<IpcServer*>(self)->run();
    return nullptr;
}

// Only root, the logged-in console user, or our own uid may map the region.
bool IpcServer::authorised(std::uint32_t euid) const noexcept { return euid == 0 || euid == consoleUid_ || euid == ::geteuid(); }

void IpcServer::run() noexcept {
    struct {
        ConduitHelloRequest      req;
        mach_msg_audit_trailer_t trailer;
    } rx;

    for (;;) {
        std::memset(&rx, 0, sizeof(rx));
        rx.req.head.msgh_size       = sizeof(rx);
        rx.req.head.msgh_local_port = service_;
        const mach_msg_return_t rc =
            mach_msg(&rx.req.head, MACH_RCV_MSG | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                     0, sizeof(rx), service_, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (rc == MACH_RCV_TOO_LARGE) continue;  // oversized garbage: kernel dropped the body
        if (rc != MACH_MSG_SUCCESS) {
            if (rc == MACH_RCV_PORT_DIED || rc == MACH_RCV_INVALID_NAME) return;
            continue;
        }

        const bool wellFormed = rx.req.head.msgh_id == CONDUIT_MACH_MSG_HELLO && rx.req.head.msgh_size == sizeof(ConduitHelloRequest) &&
                                !(rx.req.head.msgh_bits & MACH_MSGH_BITS_COMPLEX) && rx.req.magic == CONDUIT_SHARED_MAGIC &&
                                rx.req.head.msgh_remote_port != MACH_PORT_NULL;
        if (!wellFormed || !authorised(audit_token_to_euid(rx.trailer.msgh_audit))) {
            mach_msg_destroy(&rx.req.head);
            continue;
        }

        ConduitHelloReply rep;
        std::memset(&rep, 0, sizeof(rep));
        rep.head.msgh_bits        = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(rx.req.head.msgh_bits), 0) | MACH_MSGH_BITS_COMPLEX;
        rep.head.msgh_size        = sizeof(rep);
        rep.head.msgh_remote_port = rx.req.head.msgh_remote_port;
        rep.head.msgh_id          = CONDUIT_MACH_MSG_HELLO_REPLY;
        rep.body.msgh_descriptor_count = 1;
        rep.region.name        = region_;
        rep.region.disposition = MACH_MSG_TYPE_COPY_SEND;
        rep.region.type        = MACH_MSG_PORT_DESCRIPTOR;
        rep.magic              = CONDUIT_SHARED_MAGIC;
        rep.version            = CONDUIT_SHARED_VERSION;
        rep.regionBytes        = regionBytes_;
        // Reply right is send-once, so this cannot block on a dead client.
        if (mach_msg(&rep.head, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(rep), 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL) != MACH_MSG_SUCCESS)
            mach_msg_destroy(&rep.head);
    }
}

}  // namespace conduit

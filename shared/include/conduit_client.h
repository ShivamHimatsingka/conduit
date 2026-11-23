// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Client side of the Mach handshake: look up the driver's service, send HELLO,
// receive a memory-entry port, vm_map it, validate it.
#ifndef CONDUIT_CLIENT_H
#define CONDUIT_CLIENT_H

#include <mach/mach.h>
#include <stddef.h>

#include "conduit_shared.h"

#ifdef __cplusplus
extern "C" {
#endif

#define CONDUIT_DEFAULT_SERVICE "com.conduit.driver.ipc"

typedef struct {
    ConduitShared* shared;
    ConduitRing    appRing; /* producer side: the app writes, the driver reads */
    void*          base;
    size_t         size;
} ConduitConnection;

/* Hello protocol (wire format shared with the driver). */
typedef struct { mach_msg_header_t head; uint32_t magic; uint32_t version; } ConduitHelloRequest;
typedef struct {
    mach_msg_header_t          head;
    mach_msg_body_t            body;
    mach_msg_port_descriptor_t region;
    uint32_t                   magic;
    uint32_t                   version;
    uint64_t                   regionBytes;
} ConduitHelloReply;

/* Returns 0 on success, otherwise a kern_return_t / CONDUIT_ERR_* code. */
#define CONDUIT_ERR_LOOKUP 1001
#define CONDUIT_ERR_PROTOCOL 1002
#define CONDUIT_ERR_VERSION 1003
int conduit_connect(const char* service, ConduitConnection* out);
void conduit_disconnect(ConduitConnection* c);

#ifdef __cplusplus
}
#endif
#endif

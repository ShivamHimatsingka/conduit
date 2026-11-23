// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
#include "conduit_client.h"

#include <mach/mach_vm.h>
#include <servers/bootstrap.h>
#include <string.h>

int conduit_connect(const char* service, ConduitConnection* out) {
    memset(out, 0, sizeof(*out));
    mach_port_t svc = MACH_PORT_NULL, reply = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, service ? service : CONDUIT_DEFAULT_SERVICE, &svc);
    if (kr != KERN_SUCCESS) return CONDUIT_ERR_LOOKUP;
    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
    if (kr != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), svc); return kr; }

    union { ConduitHelloRequest req; ConduitHelloReply rep; } u; /* request is sent from the start of the buffer */
    struct { ConduitHelloReply rep; mach_msg_max_trailer_t trailer; } rx;
    memset(&u, 0, sizeof(u));
    memset(&rx, 0, sizeof(rx));
    ConduitHelloRequest* req = &u.req;
    req->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    req->head.msgh_size = sizeof(*req);
    req->head.msgh_remote_port = svc;
    req->head.msgh_local_port = reply;
    req->head.msgh_id = CONDUIT_MACH_MSG_HELLO;
    req->magic = CONDUIT_SHARED_MAGIC;
    req->version = CONDUIT_SHARED_VERSION;

    kr = mach_msg(&req->head, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(*req), 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), svc);
    if (kr == KERN_SUCCESS)
        kr = mach_msg(&rx.rep.head, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(rx), reply, 2000, MACH_PORT_NULL);
    mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);
    if (kr != KERN_SUCCESS) return kr;

    ConduitHelloReply* rep = &rx.rep;
    if (rep->head.msgh_id != CONDUIT_MACH_MSG_HELLO_REPLY || !(rep->head.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        rep->body.msgh_descriptor_count != 1 || rep->region.type != MACH_MSG_PORT_DESCRIPTOR || rep->magic != CONDUIT_SHARED_MAGIC) {
        mach_msg_destroy(&rep->head);
        return CONDUIT_ERR_PROTOCOL;
    }
    if (rep->version != CONDUIT_SHARED_VERSION) { mach_msg_destroy(&rep->head); return CONDUIT_ERR_VERSION; }

    mach_vm_address_t addr = 0;
    const mach_vm_size_t size = rep->regionBytes;
    kr = mach_vm_map(mach_task_self(), &addr, size, 0, VM_FLAGS_ANYWHERE, rep->region.name, 0, FALSE,
                     VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    mach_port_deallocate(mach_task_self(), rep->region.name); /* mapping holds its own reference */
    if (kr != KERN_SUCCESS) return kr;

    ConduitShared* s = (ConduitShared*)(uintptr_t)addr;
    if (size < sizeof(ConduitShared) || s->header.magic != CONDUIT_SHARED_MAGIC || s->header.version != CONDUIT_SHARED_VERSION ||
        s->header.regionBytes != size || s->header.headerBytes != sizeof(ConduitShared) ||
        (uint64_t)s->header.ringOffset + s->header.ringBytes > size || !conduit_shared_app_ring(s, &out->appRing)) {
        mach_vm_deallocate(mach_task_self(), addr, size);
        return CONDUIT_ERR_VERSION;
    }
    out->shared = s;
    out->base = (void*)(uintptr_t)addr;
    out->size = (size_t)size;
    return 0;
}

void conduit_disconnect(ConduitConnection* c) {
    if (c->base) mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)(uintptr_t)c->base, c->size);
    memset(c, 0, sizeof(*c));
}

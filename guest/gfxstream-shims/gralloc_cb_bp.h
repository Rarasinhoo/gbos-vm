// Stand-in for goldfish-opengl's gralloc_cb_bp.h. The Goldfish gralloc is never in use on this
// device (minigbm is), so no handle is ever recognised as one of its buffers.
#pragma once
#include <cutils/native_handle.h>
#include <stdint.h>
#include <stddef.h>
struct cb_handle_t : public native_handle_t {
    uint32_t hostHandle;
    uint32_t format;
    uint32_t drmformat;
    uint64_t allocatedSize() const { return 0; }
    static const cb_handle_t* from(const void*) { return nullptr; }
};

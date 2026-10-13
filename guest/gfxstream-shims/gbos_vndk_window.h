// LL-NDK ANativeWindow calls (frameworks/native vndk/window.h) that mesa's android_stub headers
// leave out. libnativewindow on the device provides them.
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct ANativeWindow;
struct ANativeWindowBuffer;
int ANativeWindow_setUsage(struct ANativeWindow* window, uint64_t usage);
int ANativeWindow_dequeueBuffer(struct ANativeWindow* window, struct ANativeWindowBuffer** buffer, int* fenceFd);
int ANativeWindow_queueBuffer(struct ANativeWindow* window, struct ANativeWindowBuffer* buffer, int fenceFd);
int ANativeWindow_cancelBuffer(struct ANativeWindow* window, struct ANativeWindowBuffer* buffer, int fenceFd);
#ifdef __cplusplus
}
#endif

#!/bin/bash
# Build the pieces that go inside the guest image, plus the host-side SELinux policy tool:
#   the pointer/clipboard helper, a Vulkan self-test, and guest_graphics_memfd_policy.
# Needs the Android NDK, SDK build-tools and platform, and a JDK. Output: $WORK/guest, $WORK/tools.
. "$(dirname "$0")/lib.sh"
find_android
[ -n "$ANDROID_NDK" ] && [ -n "$D8" ] && [ -n "$ANDROID_JAR" ] && [ -n "$JAVA_HOME" ] \
  || die "Android build tools are missing. Run ./prereqs.sh to see what, and to install it."
[ "$(basename "$ANDROID_NDK")" = "$NDK_TESTED" ] || echo "note: NDK $NDK_TESTED not installed; using $(basename "$ANDROID_NDK")"
NDK_BIN="$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
[ -f "$MESA_SRC/include/drm-uapi/virtgpu_drm.h" ] || die "run build-host.sh first (it fetches the headers)"
mkdir -p "$WORK/src" "$WORK/build" "$WORK/guest" "$WORK/tools"

say "Pointer and clipboard helper"
rm -rf "$WORK/build/input"; mkdir -p "$WORK/build/input"
"$JAVA_HOME/bin/javac" -source 11 -target 11 -Xlint:-options -cp "$ANDROID_JAR" -d "$WORK/build/input" "$ROOT/guest/input/vm/Input.java"
"$D8" --min-api 34 --lib "$ANDROID_JAR" --output "$WORK/guest/vm-input.jar" "$WORK"/build/input/vm/*.class

say "Guest Vulkan self-test"
"$NDK_BIN/aarch64-linux-android35-clang" -O2 -I"$MESA_SRC/include/drm-uapi" "$ROOT/guest/guest_vulkan_probe.c" \
  -lvulkan -lnativewindow -lEGL -lGLESv2 -o "$WORK/guest/guest-vulkan-probe"

say "SELinux policy tool (runs on the Mac while the image is assembled)"
fetch "$LIBSEPOL_URL" "$DOWNLOADS/libsepol-3.11.tar.gz" "${LIBSEPOL_SHA256:-}"
[ -d "$WORK/src/libsepol-3.11" ] || tar -xzf "$DOWNLOADS/libsepol-3.11.tar.gz" -C "$WORK/src"
[ -f "$WORK/src/libsepol-3.11/src/libsepol.a" ] || make -s -C "$WORK/src/libsepol-3.11/src" libsepol.a \
  CFLAGS="-O2 -Wno-error -D_DARWIN_C_SOURCE" >"$WORK/build/libsepol.build.log" 2>&1 || { tail -20 "$WORK/build/libsepol.build.log"; die "libsepol build failed"; }
cc -O2 -I"$WORK/src/libsepol-3.11/include" "$ROOT/tools-src/guest_graphics_memfd_policy.c" \
  "$WORK/src/libsepol-3.11/src/libsepol.a" -o "$WORK/tools/guest_graphics_memfd_policy"

say "Guest build complete"
ls -l "$WORK/guest" "$WORK/tools"

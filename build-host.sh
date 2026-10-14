#!/bin/bash
# Build the Mac-side pieces: the build tools environment, libepoxy headers for QEMU's OpenGL
# display, the small QEMU launcher and the viewer app. QEMU itself and the renderer come from
# build-gfxstream.sh. Output: $WORK/host/{qemu-interop,Googlebook VM.app}
. "$(dirname "$0")/lib.sh"
no_running_vm
need git "Xcode command line tools"; need clang "Xcode command line tools"
need python3 "Homebrew or Xcode"; need pkg-config "brew install pkg-config"
find_build_python; [ -n "$BUILD_PYTHON" ] || die "meson needs Python 3.10 or newer (Apple's python3 is 3.9): brew install python@3.13"
FW="$UTM_BETA_APP/Contents/Frameworks"
[ -d "$FW/epoxy.0.framework" ] || die "UTM 5 beta not found at $UTM_BETA_APP (set UTM_BETA_APP)"
mkdir -p "$WORK/src" "$WORK/build" "$WORK/host" "$WORK/pkgconfig"
say "Mesa source (Khronos and kernel headers; build-gfxstream.sh builds the guest driver from it)"
checkout "$MESA_GFX_REPO" "$MESA_GFX_COMMIT" "$MESA_SRC"

say "Python build environment (meson, ninja)"
# Rebuild when the pinned list changes, or an earlier run left it half-installed or on a too-old Python.
REQ_HASH="$(shasum -a 256 "$ROOT/host/requirements-build.txt" | cut -d' ' -f1)"
if [ ! -x "$WORK/env/bin/meson" ] || [ ! -x "$WORK/env/bin/ninja" ] \
   || ! "$WORK/env/bin/python3" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null \
   || [ "$(cat "$WORK/env/.requirements-sha256" 2>/dev/null || true)" != "$REQ_HASH" ]; then
  rm -rf "$WORK/env"
  "$BUILD_PYTHON" -m venv "$WORK/env"
  "$WORK/env/bin/pip" -q install --require-hashes -r "$ROOT/host/requirements-build.txt"
  echo "$REQ_HASH" > "$WORK/env/.requirements-sha256"
fi
export PATH="$WORK/env/bin:$PATH" CCACHE_DISABLE=1

say "libepoxy headers matching UTM's bundled epoxy"
# Only the generated headers are needed; the library itself comes from the UTM frameworks.
checkout "$EPOXY_REPO" "$EPOXY_COMMIT" "$WORK/src/libepoxy"
[ -f "$WORK/build/libepoxy/build.ninja" ] || meson setup "$WORK/build/libepoxy" "$WORK/src/libepoxy" \
  -Dtests=false -Dglx=no -Degl=yes -Dx11=false >/dev/null
ninja -j "$JOBS" -C "$WORK/build/libepoxy" include/epoxy/gl_generated.h include/epoxy/egl_generated.h \
  include/epoxy/gl_angle_ext_generated.h include/epoxy/egl_angle_ext_generated.h >/dev/null

cat > "$WORK/pkgconfig/epoxy.pc" <<PC
Name: epoxy
Description: UTM's bundled epoxy with matching generated headers
Version: 1.5.10
epoxy_has_egl=1
epoxy_has_glx=0
Cflags: -I$MESA_SRC/include -I$WORK/src/libepoxy/include -I$WORK/build/libepoxy/include
Libs: -F$FW -framework epoxy.0
PC
cat > "$WORK/pkgconfig/vulkan.pc" <<PC
Name: vulkan
Description: UTM's bundled Vulkan loader
Version: 1.4.0
Libs: -F$FW -framework vulkan.1
PC

say "QEMU launcher with the hypervisor entitlement"
clang -O2 "$ROOT/host/qemu-launcher.c" -o "$WORK/host/qemu-interop"
codesign --force --sign - --entitlements "$ROOT/host/hypervisor.entitlements.plist" "$WORK/host/qemu-interop" 2>/dev/null

say "Googlebook VM app"
checkout "$COCOASPICE_REPO" "$COCOASPICE_COMMIT" "$WORK/src/CocoaSpice"
apply_patch "$WORK/src/CocoaSpice" "$ROOT/patches/cocoaspice-viewer.patch"
rm -rf "$WORK/host/Googlebook Viewer.app"
python3 "$ROOT/host/build_viewer.py" "$WORK/src/CocoaSpice" "$FW" "$ROOT/host/viewer.m" "$WORK/host" "$ROOT/run" "$WORK" >/dev/null

say "Host build complete: $WORK/host"
ls -l "$WORK/host"

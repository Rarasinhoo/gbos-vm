#!/bin/bash
# Experimental: the gfxstream graphics stack (Google's Android-emulator renderer), to replace
# virglrenderer one day. Not used by install.sh or the app yet.
#   gfxstream host renderer (Vulkan on MoltenVK), from the macOS work in google/gfxstream#168
#   rutabaga_gfx with gfxstream, the C library QEMU drives it through
#   QEMU 10.0.12 with UTM's changes, built as a library with the virtio-gpu-rutabaga device
#   the guest's gfxstream Vulkan driver, from the Mesa revision the host renderer was cut from
# Needs build-host.sh and build-guest.sh to have run first, plus Rust, CMake and Bazel
# (brew install rust cmake bazelisk). Output: $WORK/build/gfxstream/lib,
# $WORK/build/qemu-gfx/libqemu-aarch64-softmmu.dylib, $WORK/host/lib64/vulkan/libvulkan.dylib,
# $WORK/guest/vulkan.gfxstream.so.
. "$(dirname "$0")/lib.sh"
need cargo "brew install rust"; need cmake "brew install cmake"; need bazelisk "brew install bazelisk"
[ -x "$WORK/env/bin/meson" ] && [ -f "$WORK/pkgconfig/epoxy.pc" ] || die "run build-host.sh first"
[ -f "$WORK/android-aarch64.cross" ] || die "run build-guest.sh first"
find_android; NDK_BIN="$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
export PATH="$WORK/env/bin:$PATH"
GFXSTREAM_REPO="https://github.com/utzcoz/gfxstream.git"   # google/gfxstream#168, macos-followup
GFXSTREAM_COMMIT="e9eed53df8fe16109503341b4b255e01bd456c7b"
RUTABAGA_REPO="https://github.com/magma-gpu/rutabaga_gfx.git"
RUTABAGA_COMMIT="60603afa5b2cc195f9df6f57009ed29ea47033a5"
QEMU_UTM_URL="https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz"
QEMU_UTM_SHA256="7c9605290b34152debb842e965a55d2e4fbba4793e536ab677b4027e5dc0ba1a"
# The guest driver and the host decoder must speak the same protocol revision: the host fork
# above was cut from this Mesa (Android's mirror, Mesa 26.3.0-devel).
MESA_GFX_REPO="https://android.googlesource.com/platform/external/mesa3d"
MESA_GFX_COMMIT="9ac80d5c43c46e85700a75ca34bd1036ee15467e"
MINIGBM_HANDLE_URL="https://android.googlesource.com/platform/external/minigbm/+/455b7456397dff01443584b09e2fd594079e905c/cros_gralloc/cros_gralloc_handle.h?format=TEXT"
UTM_FW="$UTM_BETA_APP/Contents/Frameworks"

say "gfxstream host renderer"
checkout "$GFXSTREAM_REPO" "$GFXSTREAM_COMMIT" "$WORK/src/gfxstream"
apply_patch "$WORK/src/gfxstream" "$ROOT/patches/gfxstream-host.patch"
( cd "$WORK/src/gfxstream" && bazelisk --output_user_root="$WORK/build/bazel" build -c opt //host:gfxstream_backend ) >"$WORK/build/gfxstream-backend.log" 2>&1 \
  || { tail -20 "$WORK/build/gfxstream-backend.log"; die "gfxstream build failed"; }
mkdir -p "$WORK/build/gfxstream/lib"
cp -f "$(cd "$WORK/src/gfxstream" && readlink -f bazel-bin/host/libgfxstream_backend.dylib)" "$WORK/build/gfxstream/lib/"
chmod u+w "$WORK/build/gfxstream/lib/libgfxstream_backend.dylib"

say "rutabaga_gfx with gfxstream"
checkout "$RUTABAGA_REPO" "$RUTABAGA_COMMIT" "$WORK/src/rutabaga_gfx"
R="$WORK/build/rutabaga-gfxstream"
( cd "$WORK/src/rutabaga_gfx" && GFXSTREAM_PATH="$WORK/build/gfxstream/lib" CARGO_TARGET_DIR="$R" \
    cargo build --release -p rutabaga_gfx_ffi --features gfxstream ) >"$WORK/build/rutabaga.log" 2>&1 \
  || { tail -20 "$WORK/build/rutabaga.log"; die "rutabaga build failed"; }
# QEMU includes <rutabaga_gfx/rutabaga_gfx_ffi.h> and finds the library through pkg-config.
mkdir -p "$R/include/rutabaga_gfx" "$R/pkgconfig"
ln -sf "$WORK/src/rutabaga_gfx/ffi/src/include/rutabaga_gfx_ffi.h" "$R/include/rutabaga_gfx/rutabaga_gfx_ffi.h"
cat > "$R/pkgconfig/rutabaga_gfx_ffi.pc" <<PC
Name: rutabaga_gfx_ffi
Description: rutabaga_gfx C API, built with gfxstream
Version: 0.1.85
Cflags: -I$R/include
Libs: -L$R/release -lrutabaga_gfx_ffi -Wl,-rpath,$WORK/build/gfxstream/lib
PC

say "QEMU (UTM's 10.0.12) with the gfxstream device"
for f in libslirp spice-protocol spice-server libusb usbredir; do
  brew list --formula "$f" >/dev/null 2>&1 || die "missing $f: brew install libslirp spice-protocol spice-server libusb usbredir"
done
[ -d "$WORK/src/qemu-10.0.12-utm" ] || { fetch "$QEMU_UTM_URL" "$WORK/downloads/qemu-10.0.12-utm.tar.xz" "$QEMU_UTM_SHA256"; tar -xf "$WORK/downloads/qemu-10.0.12-utm.tar.xz" -C "$WORK/src"; }
# Our changes on top (applied once; a dry run fails when they are already in)
if patch -d "$WORK/src/qemu-10.0.12-utm" -p1 -N --dry-run --silent <"$ROOT/patches/qemu-gfxstream.patch" >/dev/null 2>&1; then
  patch -d "$WORK/src/qemu-10.0.12-utm" -p1 -N --silent <"$ROOT/patches/qemu-gfxstream.patch"
fi
mkdir -p "$WORK/build/qemu-gfx"
# apple-gfx (macOS guests) uses APIs the macOS 27 SDK removed, and GTK clashes with the library
# build; neither is needed here. UTM's SPICE GL path uses an ANGLE constant its epoxy headers
# don't generate: GL_TEXTURE_RECTANGLE_ANGLE is 0x84F5, the ARB rectangle target.
( cd "$WORK/build/qemu-gfx" && \
  PKG_CONFIG_PATH="$R/pkgconfig:$WORK/pkgconfig:$WORK/build/virglrenderer/meson-uninstalled:$(brew --prefix)/lib/pkgconfig" \
  "$WORK/src/qemu-10.0.12-utm/configure" --target-list=aarch64-softmmu --enable-shared-lib --disable-cocoa --disable-sdl \
    --disable-gtk --disable-vte --disable-docs --disable-werror --disable-pvg --extra-cflags=-DGL_TEXTURE_RECTANGLE_ANGLE=0x84F5 \
    --enable-hvf --enable-spice --enable-opengl --enable-virglrenderer --enable-rutabaga-gfx --enable-slirp \
    --enable-libusb --enable-usb-redir --enable-coreaudio && \
  ninja -j "$JOBS" libqemu-aarch64-softmmu.dylib ) >"$WORK/build/qemu-gfx.log" 2>&1 \
  || { grep -E 'FAILED|error:' "$WORK/build/qemu-gfx.log" | head; die "QEMU build failed"; }

# gfxstream looks for the Vulkan loader next to the launcher; UTM ships one (and MoltenVK).
mkdir -p "$WORK/host/lib64/vulkan"
ln -sf "$UTM_FW/vulkan.1.framework/Versions/A/vulkan.1" "$WORK/host/lib64/vulkan/libvulkan.dylib"
say "gfxstream guest Vulkan driver"
checkout "$MESA_GFX_REPO" "$MESA_GFX_COMMIT" "$WORK/src/mesa3d-gfxstream"
# Built outside AOSP: no goldfish pipe or render-control encoder (virtio-gpu only)
apply_patch "$WORK/src/mesa3d-gfxstream" "$ROOT/patches/mesa-gfxstream-guest.patch"
# The few AOSP pieces it includes: our small stand-ins (guest/gfxstream-shims), minigbm's handle
# layout, and empty pkg-config entries for the AOSP libraries meson asks after.
SH="$WORK/build/gfxstream-guest-shims"; rm -rf "$SH"; mkdir -p "$SH/pkgconfig" "$SH/include/cros_gralloc"
cp -R "$ROOT/guest/gfxstream-shims/." "$SH/include/"
curl -fsSL "$MINIGBM_HANDLE_URL" | base64 -d >"$SH/include/cros_gralloc/cros_gralloc_handle.h"
grep -q cros_gralloc_handle "$SH/include/cros_gralloc/cros_gralloc_handle.h" || die "could not fetch minigbm's handle header"
for n in android-base android-arect android-aemu-base android-aemu-gl-codec android-aemu-qemupipe \
         android-aemu-ringbuffer android-aemu-rc-encoder android-utils android-minigbm-headers \
         android-nativebase-headers android-aemu-gralloc-headers; do
  printf 'Name: %s\nDescription: build stand-in\nVersion: 1\nCflags: -I%s/include\nLibs:\n' "$n" "$SH" >"$SH/pkgconfig/$n.pc"
done
DEFS="-DANDROID -DANDROID_API_LEVEL=35"
[ -f "$WORK/build/mesa-gfxstream/build.ninja" ] || meson setup "$WORK/build/mesa-gfxstream" "$WORK/src/mesa3d-gfxstream" \
  --cross-file "$WORK/android-aarch64.cross" --buildtype=release -Dforce_fallback_for=libdrm,expat \
  -Dallow-fallback-for=libdrm -Dplatforms=android -Dplatform-sdk-version=35 -Dandroid-stub=true \
  -Dandroid-libbacktrace=disabled -Dllvm=disabled -Dglx=disabled -Dgbm=disabled -Dvideo-codecs= \
  -Dgallium-va=disabled -Dzstd=disabled -Dgallium-drivers= -Dvulkan-drivers=gfxstream -Degl=disabled \
  -Dgles1=disabled -Dgles2=disabled -Dopengl=false -Db_lundef=false -Dpkg_config_path="$SH/pkgconfig" \
  -Dc_args="$DEFS" -Dcpp_args="$DEFS -include $SH/include/gbos_vndk_window.h" >"$WORK/build/mesa-gfxstream.configure.log" 2>&1 \
  || { tail -20 "$WORK/build/mesa-gfxstream.configure.log"; die "gfxstream guest configure failed"; }
ninja -j "$JOBS" -C "$WORK/build/mesa-gfxstream" src/gfxstream/guest/vulkan/libvulkan_gfxstream.so >"$WORK/build/mesa-gfxstream.build.log" 2>&1 \
  || { grep -E 'error:|FAILED' "$WORK/build/mesa-gfxstream.build.log" | head; die "gfxstream guest build failed"; }
"$NDK_BIN/llvm-strip" --strip-unneeded -o "$WORK/guest/vulkan.gfxstream.so" "$WORK/build/mesa-gfxstream/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so"

say "gfxstream build complete"
ls -lh "$WORK/build/gfxstream/lib/libgfxstream_backend.dylib" "$WORK/build/qemu-gfx/libqemu-aarch64-softmmu.dylib" "$WORK/guest/vulkan.gfxstream.so"

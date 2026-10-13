#!/bin/bash
# Experimental: the Mac side of the gfxstream graphics stack (Google's Android-emulator renderer),
# to replace virglrenderer one day. Not used by install.sh or the app yet.
#   gfxstream host renderer (Vulkan on MoltenVK), from the macOS work in google/gfxstream#168
#   rutabaga_gfx with gfxstream, the C library QEMU drives it through
#   QEMU 10.0.12 with UTM's changes, built as a library with the virtio-gpu-rutabaga device
# Needs build-host.sh to have run first (epoxy headers, virglrenderer, the launcher), plus Rust,
# CMake and Bazel (brew install rust cmake bazelisk). Output: $WORK/build/gfxstream/lib,
# $WORK/build/qemu-gfx/libqemu-aarch64-softmmu.dylib, $WORK/host/lib64/vulkan/libvulkan.dylib.
. "$(dirname "$0")/lib.sh"
need cargo "brew install rust"; need cmake "brew install cmake"; need bazelisk "brew install bazelisk"
[ -x "$WORK/env/bin/meson" ] && [ -f "$WORK/pkgconfig/epoxy.pc" ] || die "run build-host.sh first"
export PATH="$WORK/env/bin:$PATH"
GFXSTREAM_REPO="https://github.com/utzcoz/gfxstream.git"   # google/gfxstream#168, macos-followup
GFXSTREAM_COMMIT="e9eed53df8fe16109503341b4b255e01bd456c7b"
RUTABAGA_REPO="https://github.com/magma-gpu/rutabaga_gfx.git"
RUTABAGA_COMMIT="60603afa5b2cc195f9df6f57009ed29ea47033a5"
QEMU_UTM_URL="https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz"
QEMU_UTM_SHA256="7c9605290b34152debb842e965a55d2e4fbba4793e536ab677b4027e5dc0ba1a"
UTM_FW="$UTM_BETA_APP/Contents/Frameworks"

say "gfxstream host renderer"
checkout "$GFXSTREAM_REPO" "$GFXSTREAM_COMMIT" "$WORK/src/gfxstream"
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
say "gfxstream build complete"
ls -lh "$WORK/build/gfxstream/lib/libgfxstream_backend.dylib" "$WORK/build/qemu-gfx/libqemu-aarch64-softmmu.dylib"

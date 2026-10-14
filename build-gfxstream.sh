#!/bin/bash
# The graphics stack: gfxstream (Google's Android-emulator renderer).
#   gfxstream host renderer (Vulkan on MoltenVK), from the macOS work in google/gfxstream#168
#   rutabaga_gfx with gfxstream, the C library QEMU drives it through
#   QEMU 10.0.12 with UTM's changes, built as a library with the virtio-gpu-rutabaga device
#   the guest's gfxstream Vulkan driver, from the Mesa revision the host renderer was cut from
# Needs build-host.sh to have run first, the Android NDK, and Rust, CMake and Bazel (prereqs.sh
# installs them). Output: $WORK/build/gfxstream/lib,
# $WORK/build/qemu-gfx/libqemu-aarch64-softmmu.dylib, $WORK/host/lib64/vulkan/libvulkan.dylib,
# $WORK/guest/{vulkan.gfxstream.so,libdrm.so}.
. "$(dirname "$0")/lib.sh"
no_running_vm  # it replaces the renderer library a running VM has loaded
need cargo "brew install rust"; need cmake "brew install cmake"; need bazelisk "brew install bazelisk"
[ -x "$WORK/env/bin/meson" ] && [ -f "$WORK/pkgconfig/epoxy.pc" ] && [ -d "$MESA_SRC/.git" ] || die "run build-host.sh first"
find_android; [ -n "$ANDROID_NDK" ] || die "the Android NDK is missing; run ./prereqs.sh"
NDK_BIN="$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
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
apply_patch "$WORK/src/gfxstream" "$ROOT/patches/gfxstream-host.patch"
( cd "$WORK/src/gfxstream" && bazelisk --output_user_root="$WORK/build/bazel" build -c opt //host:gfxstream_backend ) >"$WORK/build/gfxstream-backend.log" 2>&1 \
  || { tail -20 "$WORK/build/gfxstream-backend.log"; die "gfxstream build failed"; }
mkdir -p "$WORK/build/gfxstream/lib"
G="$WORK/build/gfxstream/lib/libgfxstream_backend.dylib"
cp -f "$(cd "$WORK/src/gfxstream" && readlink -f bazel-bin/host/libgfxstream_backend.dylib)" "$G.tmp"
chmod u+w "$G.tmp"; mv -f "$G.tmp" "$G"  # a new file, never a rewrite of one in use

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
# A fresh tree with our changes on top, whenever those change (zero-copy display, RGBA
# consoles, renderer features from the environment)
QSRC="$WORK/src/qemu-10.0.12-utm"
if ! cmp -s "$ROOT/patches/qemu-gfxstream.patch" "$QSRC/.gbos-patch"; then
  fetch "$QEMU_UTM_URL" "$DOWNLOADS/qemu-10.0.12-utm.tar.xz" "$QEMU_UTM_SHA256"
  rm -rf "$QSRC"; tar -xf "$DOWNLOADS/qemu-10.0.12-utm.tar.xz" -C "$WORK/src"
  patch -d "$QSRC" -p1 --silent <"$ROOT/patches/qemu-gfxstream.patch" || die "QEMU patch does not apply"
  cp "$ROOT/patches/qemu-gfxstream.patch" "$QSRC/.gbos-patch"
fi
mkdir -p "$WORK/build/qemu-gfx"
# apple-gfx (macOS guests) uses APIs the macOS 27 SDK removed, and GTK clashes with the library
# build; neither is needed here. UTM's SPICE GL path uses an ANGLE constant its epoxy headers
# don't generate: GL_TEXTURE_RECTANGLE_ANGLE is 0x84F5, the ARB rectangle target.
( cd "$WORK/build/qemu-gfx" && \
  PKG_CONFIG_PATH="$R/pkgconfig:$WORK/pkgconfig:$(brew --prefix)/lib/pkgconfig" \
  "$QSRC/configure" --target-list=aarch64-softmmu --enable-shared-lib --disable-cocoa --disable-sdl \
    --disable-gtk --disable-vte --disable-docs --disable-werror --disable-pvg --extra-cflags=-DGL_TEXTURE_RECTANGLE_ANGLE=0x84F5 \
    --enable-hvf --enable-spice --enable-opengl --disable-virglrenderer --enable-rutabaga-gfx --enable-slirp \
    --enable-libusb --enable-usb-redir --enable-coreaudio && \
  ninja -j "$JOBS" libqemu-aarch64-softmmu.dylib ) >"$WORK/build/qemu-gfx.log" 2>&1 \
  || { grep -E 'FAILED|error:' "$WORK/build/qemu-gfx.log" | head; die "QEMU build failed"; }

# gfxstream looks for the Vulkan loader and MoltenVK's driver manifest next to the launcher;
# UTM ships both libraries.
mkdir -p "$WORK/host/lib64/vulkan"
ln -sf "$UTM_FW/vulkan.1.framework/Versions/A/vulkan.1" "$WORK/host/lib64/vulkan/libvulkan.dylib"
cat > "$WORK/host/lib64/vulkan/MoltenVK_icd.json" <<JSON
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "$UTM_FW/MoltenVK.framework/Versions/Current/MoltenVK",
        "api_version" : "1.4.0",
        "is_portability_driver" : true
    }
}
JSON
say "gfxstream guest Vulkan driver"
checkout "$MESA_GFX_REPO" "$MESA_GFX_COMMIT" "$MESA_SRC"
# Built outside AOSP: no goldfish pipe or render-control encoder (virtio-gpu only)
apply_patch "$MESA_SRC" "$ROOT/patches/mesa-gfxstream-guest.patch"
# The few AOSP pieces it includes: our small stand-ins and minigbm's handle layout
# (guest/gfxstream-shims), and empty pkg-config entries for the AOSP libraries meson asks after.
SH="$WORK/build/gfxstream-guest-shims"; rm -rf "$SH"; mkdir -p "$SH/pkgconfig" "$WORK/android-pkgconfig"
cp -R "$ROOT/guest/gfxstream-shims" "$SH/include"
for n in android-base android-arect android-aemu-base android-aemu-gl-codec android-aemu-qemupipe \
         android-aemu-ringbuffer android-aemu-rc-encoder android-utils android-minigbm-headers \
         android-nativebase-headers android-aemu-gralloc-headers; do
  printf 'Name: %s\nDescription: build stand-in\nVersion: 1\nCflags: -I%s/include\nLibs:\n' "$n" "$SH" >"$SH/pkgconfig/$n.pc"
done
cat > "$WORK/android-aarch64.cross" <<CROSS
[constants]
ndk = '$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64'
[binaries]
c = ndk / 'bin/aarch64-linux-android35-clang'
cpp = [ndk / 'bin/aarch64-linux-android35-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
ar = ndk / 'bin/llvm-ar'
strip = ndk / 'bin/llvm-strip'
c_ld = 'lld'
cpp_ld = 'lld'
pkg-config = '$(command -v pkg-config)'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$WORK/android-pkgconfig'
CROSS
DEFS="-DANDROID -DANDROID_API_LEVEL=35"
MESON_ARGS=(--cross-file "$WORK/android-aarch64.cross" --buildtype=release -Dforce_fallback_for=libdrm,expat
  -Dallow-fallback-for=libdrm -Dplatforms=android -Dplatform-sdk-version=35 -Dandroid-stub=true
  -Dandroid-libbacktrace=disabled -Dllvm=disabled -Dglx=disabled -Dgbm=disabled -Dvideo-codecs=
  -Dgallium-va=disabled -Dzstd=disabled -Dgallium-drivers= -Dvulkan-drivers=gfxstream -Degl=disabled
  -Dgles1=disabled -Dgles2=disabled -Dopengl=false -Db_lundef=false -Dpkg_config_path="$SH/pkgconfig"
  -Dc_args="$DEFS" -Dcpp_args="$DEFS -include $SH/include/gbos_vndk_window.h")
# Configure again whenever the settings (or the cross file) change, not only the first time
MB="$WORK/build/mesa-gfxstream"; ARGS_ID="$(printf '%s\n' "${MESON_ARGS[@]}" | cat - "$WORK/android-aarch64.cross" | shasum -a 256 | cut -d' ' -f1)"
if [ "$(cat "$MB/.gbos-args" 2>/dev/null)" != "$ARGS_ID" ]; then
  rm -rf "$MB"
  meson setup "$MB" "$MESA_SRC" "${MESON_ARGS[@]}" >"$WORK/build/mesa-gfxstream.configure.log" 2>&1 \
    || { tail -20 "$WORK/build/mesa-gfxstream.configure.log"; die "gfxstream guest configure failed"; }
  echo "$ARGS_ID" >"$MB/.gbos-args"
fi
ninja -j "$JOBS" -C "$MB" src/gfxstream/guest/vulkan/libvulkan_gfxstream.so subprojects/libdrm-2.4.133/libdrm.so >"$WORK/build/mesa-gfxstream.build.log" 2>&1 \
  || { grep -E 'error:|FAILED' "$WORK/build/mesa-gfxstream.build.log" | head; die "gfxstream guest build failed"; }
"$NDK_BIN/llvm-strip" --strip-unneeded -o "$WORK/guest/vulkan.gfxstream.so" "$MB/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so"
"$NDK_BIN/llvm-strip" --strip-unneeded -o "$WORK/guest/libdrm.so" "$MB/subprojects/libdrm-2.4.133/libdrm.so"

say "gfxstream build complete"
ls -lh "$WORK/build/gfxstream/lib/libgfxstream_backend.dylib" "$WORK/build/qemu-gfx/libqemu-aarch64-softmmu.dylib" "$WORK/guest/vulkan.gfxstream.so"

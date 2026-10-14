#!/bin/bash
# Assemble the bootable disk image from the verified Googlebook image, the Cuttlefish pieces and
# the guest components. Output: $WORK/image/{googlebook.raw,initrd.img,kernel.Image}
# Never modifies the downloaded image; works on copy-on-write clones.
. "$(dirname "$0")/lib.sh"
# Only your own disk is in use while a VM runs; a test image elsewhere can be built beside it
[ "${GBOS_IMAGE_DIR:-$WORK/image}" != "$WORK/image" ] || no_running_vm
need brew "https://brew.sh"; need lz4 "brew install lz4"
GUEST="${GOOGLEBOOK_GUEST_DIR:-$WORK/guest}"; TOOLS="${GOOGLEBOOK_TOOLS_DIR:-$WORK/tools}"
for f in "$WORK/googlebook/mica-recovery.raw" "$WORK/cuttlefish/manifest.json" "$WORK/cuttlefish/camera/com.google.emulated.camera.provider.hal.v4l2.apex" \
         "$WORK/cuttlefish/bluetooth/android.hardware.bluetooth-service.cuttlefish" "$GUEST/vm-input.jar" "$TOOLS/guest_graphics_memfd_policy"; do
  [ -e "$f" ] || die "missing input: $f"
done
IMAGE_DIR="${GBOS_IMAGE_DIR:-$WORK/image}"
[ -f "$GUEST/vulkan.gfxstream.so" ] && [ -f "$GUEST/libdrm.so" ] && [ -f "$WORK/build/qemu-gfx/libqemu-aarch64-softmmu.dylib" ] || "$ROOT/build-gfxstream.sh"
[ -e "$IMAGE_DIR/googlebook.raw" ] && die "$IMAGE_DIR already has a disk; move it away first (it holds your data)"

# The image scripts expect one root folder with fixed relative paths (artifacts/, experiments/,
# scripts/). Build that layout from links rather than rewriting every path in them.
WS="$WORK/ws"; rm -rf "$WS"
mkdir -p "$WS/scripts" "$WS/artifacts/mica" "$WS/artifacts/graphics-port-review" "$WS/artifacts/cuttlefish-arm17" \
         "$WS/experiments/erofs-utils/1.9.4" "$WS/experiments/ext4-tools/e2fsprogs/1.47.4"
cp "$ROOT"/image/*.py "$ROOT"/image/*.sh "$WS/scripts/"
ln -s "$WORK/googlebook/mica-recovery.raw" "$WS/artifacts/mica-recovery.raw"
ln -s "$WORK/cuttlefish/security" "$WS/artifacts/security-port-review"
ln -s "$WORK/cuttlefish/graphics/extracted" "$WS/artifacts/graphics-port-review/extracted"
ln -s "$WORK/cuttlefish/graphics/cf-composer" "$WS/artifacts/graphics-port-review/cf-composer"
ln -s "$WORK/cuttlefish/modules" "$WS/artifacts/cuttlefish-arm17/modules"
ln -s "$WORK/cuttlefish/audio-config" "$WS/artifacts/cuttlefish-audio-config"
ln -s "$WORK/cuttlefish/bluetooth" "$WS/artifacts/cuttlefish-bluetooth"
ln -s "$WORK/cuttlefish/camera" "$WS/artifacts/cuttlefish-camera"
ln -s "$(brew --prefix erofs-utils)/bin" "$WS/experiments/erofs-utils/1.9.4/bin"
ln -s "$(brew --prefix e2fsprogs)/sbin" "$WS/experiments/ext4-tools/e2fsprogs/1.47.4/sbin"
export GOOGLEBOOK_GUEST_DIR="$GUEST" GOOGLEBOOK_TOOLS_DIR="$TOOLS"
cd "$WS"

say "Kernel and ramdisks from the Googlebook image"
python3 scripts/extract_mica_normal.py >"$WORK/build-image.log" 2>&1 || { tail -20 "$WORK/build-image.log"; die "extract failed"; }
python3 scripts/make_mica_gpu_initrd.py >>"$WORK/build-image.log" 2>&1 || { tail -20 "$WORK/build-image.log"; die "ramdisk failed"; }

say "Vendor overlay, policy and services"
# Test images add --self-test, --perf-test or --stress-test through GBOS_IMAGE_FLAGS
python3 scripts/make_mica_security_port.py base ${GBOS_IMAGE_FLAGS:-} >>"$WORK/build-image.log" 2>&1 || { tail -30 "$WORK/build-image.log"; die "image assembly failed"; }

say "User data area"
python3 scripts/expand_mica_userdata.py artifacts/mica/base/googlebook.raw >>"$WORK/build-image.log" 2>&1 \
  || { tail -30 "$WORK/build-image.log"; die "image finishing failed"; }

mkdir -p "$IMAGE_DIR"; chmod 700 "$IMAGE_DIR"
mv artifacts/mica/base/googlebook.raw artifacts/mica/base/initrd.img "$IMAGE_DIR/"
# Holds all guest data: keep it private.
chmod 600 "$IMAGE_DIR/googlebook.raw"
cp artifacts/mica/normal/kernel.Image "$IMAGE_DIR/kernel.Image"
cp artifacts/mica/base/*.json "$IMAGE_DIR/" 2>/dev/null || true
cd "$WORK"; rm -rf "$WS"
say "Image ready: $IMAGE_DIR"
ls -lh "$IMAGE_DIR" | grep -v json

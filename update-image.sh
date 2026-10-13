#!/bin/bash
# Rebuild the system part of an existing disk image after pulling new changes, keeping your
# data. Builds a fresh image next to the old one, copies over only the system area and the
# ramdisk, and keeps the previous disk as googlebook.raw.before-update (a copy-on-write clone).
. "$(dirname "$0")/lib.sh"
no_running_vm
IMAGE_DIR="${GBOS_IMAGE_DIR:-$WORK/image}"
[ -f "$IMAGE_DIR/googlebook.raw" ] || die "no existing image in $IMAGE_DIR; run ./build-image.sh"
"$ROOT/fetch.sh"
# A fresh scratch folder, so nothing that already exists (your image included) is ever removed.
NEW="$(mktemp -d "$WORK/image-new.XXXXXX")"
trap 'rm -rf "$NEW"' EXIT
GBOS_IMAGE_DIR="$NEW" "$ROOT/build-image.sh"

say "Updating $IMAGE_DIR (previous disk kept as googlebook.raw.before-update)"
rm -f "$IMAGE_DIR/googlebook.raw.before-update"
cp -c "$IMAGE_DIR/googlebook.raw" "$IMAGE_DIR/googlebook.raw.before-update"
python3 "$ROOT/image/sync_super.py" "$IMAGE_DIR/googlebook.raw" "$NEW/googlebook.raw" \
  || { mv -f "$IMAGE_DIR/googlebook.raw.before-update" "$IMAGE_DIR/googlebook.raw"; die "update failed; your disk is unchanged"; }
mv -f "$NEW/initrd.img" "$NEW/kernel.Image" "$IMAGE_DIR/"
rm -f "$IMAGE_DIR/gfxstream.json"  # the new build says again if it is one
cp "$NEW"/*.json "$IMAGE_DIR/" 2>/dev/null || true
say "Graphics: $([ -f "$IMAGE_DIR/gfxstream.json" ] && echo gfxstream || echo virgl)"
say "Image updated"

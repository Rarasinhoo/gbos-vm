#!/bin/bash
# Rebuild everything after pulling new changes, and the system part of an existing disk image,
# keeping your data. Builds a fresh image next to the old one, copies over only the system area and the
# ramdisk, and keeps the previous disk as googlebook.raw.before-update (a copy-on-write clone).
. "$(dirname "$0")/lib.sh"
no_running_vm
IMAGE_DIR="${GBOS_IMAGE_DIR:-$WORK/image}"
[ -f "$IMAGE_DIR/googlebook.raw" ] || die "no existing image in $IMAGE_DIR; run ./build-image.sh"
"$ROOT/fetch.sh"
# Bring the app, the guest helpers and the graphics stack up to date first (each only rebuilds
# what changed), so the new image is made from what was just pulled.
"$ROOT/build-host.sh"
"$ROOT/build-guest.sh"
"$ROOT/build-gfxstream.sh"
# What the system part is made from: this repository's image, guest and tool sources, the guest
# binaries just built, and the image flags. Unchanged since the disk was last brought up to date,
# there is nothing to rebuild (an app-only change stops here).
inputs() {
  { cd "$ROOT" && git ls-files -co --exclude-standard -- image guest tools tools-src patches '*.sh' | LC_ALL=C sort | while read -r f; do if [ -f "$f" ]; then printf "%s " "$f"; shasum -a 256 <"$f"; fi; done
    find "$WORK/guest" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 shasum -a 256
    echo "flags ${GBOS_IMAGE_FLAGS:-}"; } | shasum -a 256 | cut -d' ' -f1
}
STAMP="$IMAGE_DIR/system-inputs.sha256"
if [ "$(cat "$STAMP" 2>/dev/null)" = "$(inputs)" ]; then say "The system part is already up to date"; exit 0; fi
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
rm -f "$IMAGE_DIR"/*.json  # build notes describe the system part, so they all come from the new build
cp "$NEW"/*.json "$IMAGE_DIR/" 2>/dev/null || true
inputs >"$STAMP"
say "Image updated"

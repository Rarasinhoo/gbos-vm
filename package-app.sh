#!/bin/bash
# Make the downloadable app from a finished build (./install.sh or ./update-image.sh first):
# work/dist/Googlebook VM.app and work/dist/Googlebook-VM-VERSION.dmg.
#
# The app carries what we build, prebuilt: the viewer, QEMU with the gfxstream device and every
# library it needs, the guest pieces, the image tools, run/setup.py and a Python to run it. What we
# may not redistribute (Google's images, UTM) it downloads on the user's Mac at first start
# (run/setup.py), as install.sh does. Signed ad hoc: macOS asks once to open it.
#
#   ./package-app.sh [--release] [VERSION]   VERSION defaults to the date and commit; --release
#                                            also collects the sources of what it bundles
. "$(dirname "$0")/lib.sh"
RELEASE=0; [ "${1:-}" = --release ] && { RELEASE=1; shift; }
VERSION="${1:-$(date +%Y.%m.%d)-$(git -C "$ROOT" rev-parse --short HEAD)}"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.13.15%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz"
PY_SHA256="d3904bd6a072246e07aa0bdadee9a14e80521e42a943c0848059feb16a2816dc"
for f in "$WORK/host/qemu-interop" "$WORK/build/qemu-gfx/libqemu-aarch64-softmmu.dylib" "$WORK/guest/vm-input.jar" \
         "$WORK/guest/vulkan.gfxstream.so" "$WORK/tools/guest_graphics_memfd_policy"; do
  [ -e "$f" ] || die "missing $f: build first (./install.sh, or ./update-image.sh)"
done
need brew "https://brew.sh"

say "The app (version $VERSION)"
# From the app build-host.sh made (packaging never touches a running VM's app)
for f in "$ROOT"/host/*.m "$ROOT"/host/*.h "$ROOT"/host/build_viewer.py; do
  [ "$f" -nt "$WORK/host/Googlebook VM.app/Contents/MacOS/GooglebookViewer" ] && die "$(basename "$f") changed since the app was built: run ./build-host.sh first"
done
DIST="$WORK/dist"; STAGE="$DIST/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
APP="$STAGE/Googlebook VM.app"; RT="$APP/Contents/Resources/runtime"
cp -R "$WORK/host/Googlebook VM.app" "$APP"
# Not tied to this machine's work folder: it lives in the user's Application Support
/usr/libexec/PlistBuddy -c "Delete :GBOSWork" "$APP/Contents/Info.plist"
# The runner scripts as they are now
for n in run_vm.py vm_control.py lan-setup.sh storage.py setup.py; do cp "$ROOT/run/$n" "$APP/Contents/Resources/"; done
for k in CFBundleShortVersionString CFBundleVersion; do /usr/libexec/PlistBuddy -c "Set :$k $VERSION" "$APP/Contents/Info.plist"; done
# UTM's libraries are found where setup puts them (the app restarts itself with them), not
# through this machine's paths
V="$APP/Contents/MacOS/GooglebookViewer"
for r in $(otool -l "$V" | awk '/cmd LC_RPATH/{getline;getline;print $2}'); do install_name_tool -delete_rpath "$r" "$V"; done
mkdir -p "$RT"/{host/lib,build/qemu-gfx,guest,tools/lib,scripts/image}
RECORD="$DIST/bundled.txt"; : >"$RECORD"

say "Python"
fetch "$PY_URL" "$DOWNLOADS/python-3.13.15-aarch64-apple-darwin.tar.gz" "$PY_SHA256"
tar -xzf "$DOWNLOADS/python-3.13.15-aarch64-apple-darwin.tar.gz" -C "$RT"
rm -rf "$RT/python/lib/python3.13/"{test,idlelib,tkinter,turtledemo,ensurepip} "$RT/python/lib/"{libtcl*,libtk*,tcl*,tk*} "$RT/python/include"

say "QEMU, gfxstream and their libraries"
cp "$WORK/host/qemu-interop" "$RT/host/"; cp "$WORK/build/qemu-gfx/libqemu-aarch64-softmmu.dylib" "$RT/host/"
chmod u+w "$RT/host/"*
python3 "$ROOT/tools/bundle_dylibs.py" --record "$RECORD" "$RT/host/lib" "$RT/host/qemu-interop" "$RT/host/libqemu-aarch64-softmmu.dylib"
codesign --force --sign - --entitlements "$ROOT/host/hypervisor.entitlements.plist" "$RT/host/qemu-interop"
# run_vm.py takes QEMU from the build folder and keeps its copy beside the launcher (host/lib)
mv "$RT/host/libqemu-aarch64-softmmu.dylib" "$RT/build/qemu-gfx/"

say "Guest pieces and image tools"
for f in vm-input.jar vulkan.gfxstream.so libdrm.so guest-vulkan-probe; do cp "$WORK/guest/$f" "$RT/guest/"; done
cp "$WORK/tools/guest_graphics_memfd_policy" "$RT/tools/"
for t in lz4 erofs-utils e2fsprogs socket_vmnet; do echo "$(brew --cellar "$t")/$(brew list --versions "$t" | awk '{print $2}')" >>"$RECORD"; done
for t in "$(brew --prefix lz4)/bin/lz4" "$(brew --prefix erofs-utils)/bin/"{dump,mkfs,fsck}.erofs \
         "$(brew --prefix e2fsprogs)/sbin/debugfs" "$(brew --prefix socket_vmnet)/bin/socket_vmnet"; do cp "$t" "$RT/tools/"; done
chmod u+w "$RT/tools/"*
python3 "$ROOT/tools/bundle_dylibs.py" --record "$RECORD" "$RT/tools/lib" "$RT/tools/"{lz4,dump.erofs,mkfs.erofs,fsck.erofs,debugfs,socket_vmnet,guest_graphics_memfd_policy}
cp "$ROOT"/image/*.py "$ROOT"/image/*.sh "$RT/scripts/image/"; cp "$ROOT/tools/unpack_cuttlefish.py" "$RT/scripts/"

say "Manifest"
python3 - "$RT/manifest.json" "$VERSION" "$(system_inputs)" <<PY
import json,sys
pins={k:v for k,v in dict(GOOGLEBOOK_URL="$GOOGLEBOOK_URL",GOOGLEBOOK_ZIP_SHA256="$GOOGLEBOOK_ZIP_SHA256",GOOGLEBOOK_RAW_SHA256="$GOOGLEBOOK_RAW_SHA256",
  CUTTLEFISH_BUILD="$CUTTLEFISH_BUILD",CUTTLEFISH_ZIP="$CUTTLEFISH_ZIP",CUTTLEFISH_SHA256="$CUTTLEFISH_SHA256",
  UTM_DMG_URL="$UTM_DMG_URL",UTM_DMG_SHA256="$UTM_DMG_SHA256").items()}
json.dump({'version':sys.argv[2],'system':sys.argv[3],'pins':pins},open(sys.argv[1],'w'),indent=2)
PY
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
SRC="$DIST/sources"; rm -rf "$SRC"
if [ "$RELEASE" = 1 ]; then
  python3 "$ROOT/tools/third_party.py" "$RECORD" "$APP/Contents/Resources/THIRD_PARTY.md" --sources "$SRC"
  cp "$DOWNLOADS/qemu-10.0.12-utm.tar.xz" "$SRC/"
  fetch "$LIBSEPOL_URL" "$DOWNLOADS/libsepol-3.11.tar.gz" "$LIBSEPOL_SHA256"; cp "$DOWNLOADS/libsepol-3.11.tar.gz" "$SRC/"
  git -C "$ROOT" archive --format=tar.gz -o "$SRC/gbos-vm-$VERSION.tar.gz" HEAD   # our code and patches
  tar -cf "$DIST/Googlebook-VM-sources.tar" -C "$SRC" .
else
  python3 "$ROOT/tools/third_party.py" "$RECORD" "$APP/Contents/Resources/THIRD_PARTY.md"
fi

# Nothing in it may point back into this machine
if grep -rl --binary-files=without-match "$WORK" "$APP" | grep -v '\.pyc$' | head -1 | grep -q .; then
  die "the app still names $WORK in: $(grep -rl --binary-files=without-match "$WORK" "$APP" | head -3)"
fi
codesign --force --sign - "$APP"
codesign --verify --deep "$APP" || die "the app's signature doesn't verify"

say "Disk image"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Googlebook-VM.dmg"; rm -f "$DMG"   # one name, so the README links the latest release
hdiutil create -quiet -volname "Googlebook VM" -srcfolder "$STAGE" -fs APFS -format ULMO "$DMG"
rm -f "$STAGE/Applications"
ls -lh "$DMG"; du -sh "$APP"
say "Done: $DMG"

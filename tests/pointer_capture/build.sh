#!/bin/bash
# Builds the pointer capture test app (tests/pointer_capture.py) into WORK/guest/vm-pointer-test.apk,
# signed with a throwaway key: it only ever goes on test images.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/lib.sh"
find_android
TOOLS="$(dirname "$D8")"
[ -x "$TOOLS/aapt2" ] && [ -x "$TOOLS/apksigner" ] && [ -n "$JAVA_HOME" ] || die "needs the Android SDK build tools and a JDK"
B="$WORK/build/pointer-test"; rm -rf "$B"; mkdir -p "$B/classes" "$B/dex"
"$JAVA_HOME/bin/javac" -source 11 -target 11 -Xlint:-options -cp "$ANDROID_JAR" -d "$B/classes" \
  "$ROOT"/tests/pointer_capture/src/vm/pointertest/*.java
"$D8" --min-api 34 --lib "$ANDROID_JAR" --output "$B/dex" "$B"/classes/vm/pointertest/*.class
"$TOOLS/aapt2" link --manifest "$ROOT/tests/pointer_capture/AndroidManifest.xml" -I "$ANDROID_JAR" -o "$B/unsigned.apk"
(cd "$B/dex" && zip -q "$B/unsigned.apk" classes.dex)
"$TOOLS/zipalign" -f 4 "$B/unsigned.apk" "$B/aligned.apk"
"$JAVA_HOME/bin/keytool" -genkeypair -keystore "$B/key.jks" -storepass testtest -keypass testtest -alias test \
  -keyalg RSA -keysize 2048 -validity 365 -dname CN=gbos-vm-test >/dev/null 2>&1
mkdir -p "$WORK/guest"
"$TOOLS/apksigner" sign --ks "$B/key.jks" --ks-pass pass:testtest --out "$WORK/guest/vm-pointer-test.apk" "$B/aligned.apk"
say "Pointer test app: $WORK/guest/vm-pointer-test.apk"

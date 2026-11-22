#!/usr/bin/env bash
#
# Builds a tiny pure-Java test APK (no Gradle) with the Android SDK that is
# preinstalled on GitHub's Ubuntu runners.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$PWD/test.apk}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
PLATFORM="$(ls -d "$SDK"/platforms/android-* | sort -V | tail -n 1)"
BUILD_TOOLS="$(ls -d "$SDK"/build-tools/* | sort -V | tail -n 1)"
ANDROID_JAR="$PLATFORM/android.jar"
echo "platform: $PLATFORM"
echo "build-tools: $BUILD_TOOLS"

WORK="$(mktemp -d)"
mkdir -p "$WORK/obj" "$WORK/dex"
javac -source 1.8 -target 1.8 -nowarn -classpath "$ANDROID_JAR" -d "$WORK/obj" "$HERE/testapp/MainActivity.java"
"$BUILD_TOOLS/d8" --min-api 21 --lib "$ANDROID_JAR" --output "$WORK/dex" $(find "$WORK/obj" -name '*.class')
"$BUILD_TOOLS/aapt2" link -o "$WORK/base.apk" -I "$ANDROID_JAR" --manifest "$HERE/testapp/AndroidManifest.xml" \
    --min-sdk-version 21 --target-sdk-version 28
(cd "$WORK/dex" && zip -q -u "$WORK/base.apk" classes.dex)
"$BUILD_TOOLS/zipalign" -f 4 "$WORK/base.apk" "$WORK/aligned.apk"
keytool -genkeypair -keystore "$WORK/debug.jks" -storepass android -keypass android -alias debug \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=APK Runner Test" > /dev/null 2>&1
"$BUILD_TOOLS/apksigner" sign --ks "$WORK/debug.jks" --ks-pass pass:android --out "$OUT" "$WORK/aligned.apk"
ls -la "$OUT"
rm -rf "$WORK"

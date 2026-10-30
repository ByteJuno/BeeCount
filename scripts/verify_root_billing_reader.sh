#!/usr/bin/env bash
set -euo pipefail

# The helper is Java-only. Loading its dex from the APK does not install or run
# Flutter, open a payment app, or read the current screen.
adb root
adb wait-for-device
test "$(adb shell id -u | tr -d '\r')" = 0
apks=(build/app/outputs/flutter-apk/*debug.apk)
adb push "${apks[0]}" /data/local/tmp/beecount-root-reader-test.apk
reader_classpath=/data/local/tmp/beecount-root-reader-test.apk

# An explicit diagnostic run can test the current Java source against an older
# APK without rebuilding Flutter. Normal verification always reads from the APK.
if [[ "${1:-}" == --source ]]; then
  reader_dir="$(mktemp -d)"
  mkdir "$reader_dir/classes"
  javac -cp "$ANDROID_HOME/platforms/android-36/android.jar" -d "$reader_dir/classes" android/app/src/main/java/com/tntlikely/beecount/RootBillingWindowReader.java
  jar cf "$reader_dir/reader.jar" -C "$reader_dir/classes" .
  d8_paths=("$ANDROID_HOME"/build-tools/*/d8)
  d8_path="$(printf '%s\n' "${d8_paths[@]}" | sort -V | tail -n 1)"
  "$d8_path" --lib "$ANDROID_HOME/platforms/android-36/android.jar" --min-api 26 --output "$reader_dir/reader-dex.jar" "$reader_dir/reader.jar"
  adb push "$reader_dir/reader-dex.jar" /data/local/tmp/beecount-root-reader-source.jar
  reader_classpath="/data/local/tmp/beecount-root-reader-source.jar:$reader_classpath"
fi

# A second connection also verifies that the first probe released its session.
for attempt in 1 2; do
  if ! result="$(adb shell "CLASSPATH=$reader_classpath timeout 10 app_process /system/bin com.tntlikely.beecount.RootBillingWindowReader com.tencent.mm --probe" | tr -d '\r')"; then
    # This emulator has no user data; collect runtime errors from this probe.
    adb logcat -d -s AndroidRuntime:E
    exit 1
  fi
  printf '%s\n' "$result"
  test "$result" = BEECOUNT_ROOT_READY
done
adb shell rm /data/local/tmp/beecount-root-reader-test.apk
if [[ "${1:-}" == --source ]]; then
  adb shell rm /data/local/tmp/beecount-root-reader-source.jar
fi

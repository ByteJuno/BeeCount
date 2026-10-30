#!/usr/bin/env bash
set -euo pipefail

# The helper is Java-only. Loading its dex from the APK does not install or run
# Flutter, open a payment app, or read the current screen.
adb root
adb wait-for-device
test "$(adb shell id -u | tr -d '\r')" = 0
apks=(build/app/outputs/flutter-apk/*debug.apk)
adb push "${apks[0]}" /data/local/tmp/beecount-root-reader-test.apk

# A second connection also verifies that the first probe released its session.
for attempt in 1 2; do
  result="$(adb shell 'CLASSPATH=/data/local/tmp/beecount-root-reader-test.apk timeout 10 app_process /system/bin com.tntlikely.beecount.RootBillingWindowReader com.tencent.mm --probe' | tr -d '\r')"
  printf '%s\n' "$result"
  test "$result" = BEECOUNT_ROOT_READY
done
adb shell rm /data/local/tmp/beecount-root-reader-test.apk

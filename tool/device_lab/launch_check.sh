#!/usr/bin/env bash
# Launch check before a nightly or an agent merge: installs an APK on the
# phone attached over adb, starts it, and fails if it crashes or is not in
# front after a minute.
#
#   tool/device_lab/launch_check.sh path/to/app.apk [package]
#
# The package defaults to the one inside the APK name: *debug* APKs are
# dev.conest.conest.debug, the others dev.conest.conest. The installed
# app's data is kept (adb install -r): this checks an update as users get
# it.
set -euo pipefail

apk=${1:?path to the APK}
package=${2:-}
if [ -z "$package" ]; then
  case "$(basename "$apk")" in
    *debug*) package=dev.conest.conest.debug ;;
    *) package=dev.conest.conest ;;
  esac
fi
seconds=${SECONDS_TO_WATCH:-60}

adb get-state >/dev/null
adb install -r "$apk" >/dev/null
adb logcat -c
adb shell am force-stop "$package"
adb shell monkey -p "$package" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep "$seconds"

pid=$(adb shell pidof "$package" | tr -d '\r' || true)
fatal=$(adb logcat -d -b crash 2>/dev/null | grep -c "$package" || true)
front=$(adb shell dumpsys activity activities | grep -m1 "topResumedActivity" || true)
echo "pid: ${pid:-none}"
echo "crash-buffer lines for $package: $fatal"
echo "in front: $front"
if [ -z "$pid" ] || [ "$fatal" != 0 ] || ! grep -q "$package" <<<"$front"; then
  echo "LAUNCH CHECK FAILED"
  adb logcat -d -b crash | tail -40
  exit 1
fi
echo "Launch check passed."

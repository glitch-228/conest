#!/usr/bin/env bash
# Runs a debug build's automatic transport tests on real devices and
# collects the reports (Q6). Each device needs a debug build from CI
# (debug.yml artifacts) with contacts already set up between them.
#
#   tool/device_lab/run_tests.sh android           # over adb (USB or Wi-Fi)
#   tool/device_lab/run_tests.sh linux PATH/TO/BUNDLE
#   tool/device_lab/run_tests.sh windows USER@HOST 'C:\path\to\conest.exe'
#
# Reports land in ./device-lab-reports/<device>-<time>.json. Start all
# devices within the wait (default 60 s) so each finds the others online.
set -euo pipefail

kind=${1:?android, linux or windows}
wait_seconds=${WAIT:-60}
out=device-lab-reports
mkdir -p "$out"
stamp=$(date -u +%Y%m%dT%H%M%SZ)

case "$kind" in
  android)
    package=${PACKAGE:-dev.conest.conest.debug}
    # The report stays private to the app; a debug build lets run-as read it.
    remote=files/conest-debug-report.json
    adb shell run-as "$package" rm -f "$remote" || true
    adb shell am force-stop "$package"
    adb shell am start -n "$package/dev.conest.conest.MainActivity" \
      --es conestDebugRun routes >/dev/null
    echo "Started on Android; waiting for the report…"
    for _ in $(seq 1 120); do
      if adb shell run-as "$package" test -s "$remote"; then break; fi
      sleep 5
    done
    adb exec-out run-as "$package" cat "$remote" > "$out/android-$stamp.json"
    ;;
  linux)
    bundle=${2:?path to the Linux bundle directory}
    "$bundle/conest" --debug-run=routes --debug-wait="$wait_seconds" \
      --debug-report="$PWD/$out/linux-$stamp.json" --debug-exit
    ;;
  windows)
    host=${2:?user@host}
    exe=${3:?path to conest.exe on the Windows machine}
    remote='%TEMP%\conest-debug-report.json'
    ssh "$host" "\"$exe\" --debug-run=routes --debug-wait=$wait_seconds --debug-report=$remote --debug-exit"
    scp "$host:$remote" "$out/windows-$stamp.json" ||
      ssh "$host" "type $remote" > "$out/windows-$stamp.json"
    ;;
  *)
    echo "unknown device kind: $kind" >&2
    exit 2
    ;;
esac
echo "Report: $out/$kind-$stamp.json"

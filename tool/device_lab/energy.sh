#!/usr/bin/env bash
# What a lab run costs in battery and data, per device.
#
#   tool/device_lab/energy.sh start OUT    # before the run
#   tool/device_lab/energy.sh stop OUT     # after it
#
# Android (adb, the debug package): battery statistics are reset at start
# and read at stop (CPU time, wakeup alarms, wakelocks, bytes): the app's
# lines of `dumpsys batterystats --checkin` in OUT/energy-android.txt. Linux and Windows: the lab instance's CPU seconds
# and memory, sampled every 10 s into OUT/energy-linux.csv and
# OUT/energy-windows.csv (Windows only for conest.exe under conest-lab, never
# the user's own). lab.sh runs this with ENERGY=1.
set -uo pipefail

action=${1:?start or stop}
out=${2:?report folder}
PACKAGE=${PACKAGE:-dev.conest.conest.debug}
mkdir -p "$out"

win() { sshpass -e ssh -o StrictHostKeyChecking=accept-new "$WINDOWS" "$@"; }

sample_linux() {
  echo "time,cpu_seconds,rss_kb" >"$out/energy-linux.csv"
  local tick
  tick=$(getconf CLK_TCK)
  while [ -f "$out/.energy-on" ]; do
    # The lab bundle's conest only.
    for pid in $(pgrep -x conest); do
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
      case "$exe" in "$LINUX_BUNDLE"/*) ;; *) continue ;; esac
      read -r utime stime < <(awk '{print $14, $15}' "/proc/$pid/stat")
      rss=$(awk '/VmRSS/ {print $2}' "/proc/$pid/status")
      echo "$(date -u +%FT%TZ),$(( (utime + stime) / tick )),$rss" >>"$out/energy-linux.csv"
    done
    sleep 10
  done
}

sample_windows() {
  echo "time,cpu_seconds,working_set_kb" >"$out/energy-windows.csv"
  while [ -f "$out/.energy-on" ]; do
    win "powershell -NoProfile -Command \"Get-Process conest -ErrorAction SilentlyContinue | Where-Object Path -Like '*\\conest-lab\\*' | ForEach-Object { '{0},{1},{2}' -f (Get-Date).ToUniversalTime().ToString('s'), [int]\$_.CPU, [int](\$_.WorkingSet64 / 1024) }\"" \
      2>/dev/null | tr -d '\r' >>"$out/energy-windows.csv"
    sleep 10
  done
}

case "$action" in
  start)
    touch "$out/.energy-on"
    if adb get-state >/dev/null 2>&1; then
      adb shell dumpsys batterystats --reset >/dev/null
      adb shell dumpsys batterystats --enable full-wake-history >/dev/null 2>&1 || true
      date -u +%FT%TZ >"$out/energy-android-start.txt"
    fi
    [ -n "${LINUX_BUNDLE:-}" ] && { sample_linux & echo $! >"$out/.energy-linux.pid"; }
    [ -n "${WINDOWS:-}" ] && [ -n "${SSHPASS:-}" ] && { sample_windows & echo $! >"$out/.energy-windows.pid"; }
    ;;
  stop)
    rm -f "$out/.energy-on"
    # The samplers (started by "start", another process) see the flag gone
    # within their 10 s period and write their last line.
    sleep 12
    rm -f "$out"/.energy-*.pid
    if adb get-state >/dev/null 2>&1; then
      # The machine-readable form, keyed by the app's uid.
      uid=$(adb shell cmd package list packages -U "$PACKAGE" | tr -d '\r' |
        sed -n "s/^package:$PACKAGE uid:\([0-9]*\)$/\1/p")
      {
        echo "from $(cat "$out/energy-android-start.txt" 2>/dev/null) to $(date -u +%FT%TZ)"
        echo "uid $uid"
        adb shell dumpsys batterystats --checkin | tr -d '\r' | grep "^9,$uid,l,"
      } >"$out/energy-android.txt" 2>&1
    fi
    python3 "$(dirname "$0")/energy_summary.py" "$out" || true
    ;;
esac

#!/usr/bin/env bash
# What a lab run costs in battery and data, per device.
#
#   tool/device_lab/energy.sh start OUT    # before the run
#   tool/device_lab/energy.sh stop OUT     # after it
#
# Android (adb, the debug package): battery statistics are reset at start
# and read at stop (CPU time, wakeup alarms, wakelocks, bytes): the app's
# lines of `dumpsys batterystats --checkin` in OUT/energy-android.txt.
# Android counts nothing while charging, and the lab phones charge: the
# phone is told it runs on battery for the run (`dumpsys battery unplug`,
# set back at stop), and Android resets its statistics when a phone near
# full leaves its charger. The app's process CPU and memory are sampled
# too, every 10 s into OUT/energy-android.csv (from /proc, needing no
# battery statistics). Linux and Windows: the lab instance's CPU seconds
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

# adb for one phone: the given serial, or adb's default (ANDROID_SERIAL).
phone_adb() { # serial or "", adb arguments…
  local serial=$1; shift
  if [ -n "$serial" ]; then adb -s "$serial" "$@"; else adb "$@"; fi
}

sample_android() { # serial or "", phone name
  local serial=$1 phone=$2 pid stat
  echo "time,cpu_seconds,rss_kb" >"$out/energy-$phone.csv"
  while [ -f "$out/.energy-on" ]; do
    pid=$(phone_adb "$serial" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' | awk '{print $1}')
    if [ -n "$pid" ]; then
      # utime and stime in ticks (100 a second on Android), and RSS pages.
      stat=$(phone_adb "$serial" shell cat "/proc/$pid/stat" 2>/dev/null | tr -d '\r' |
        sed 's/^.*) //' | awk '{print $12 + $13, $22 * 4}')
      [ -n "$stat" ] && echo "$(date -u +%FT%TZ),$(echo "$stat" |
        awk '{printf "%d,%d", $1 / 100, $2}')" >>"$out/energy-$phone.csv"
    fi
    sleep 10
  done
}

case "$action" in
  start)
    touch "$out/.energy-on"
    for phone in android ${ANDROID2:+android2}; do
      serial=""
      [ "$phone" = android2 ] && serial=$ANDROID2
      if phone_adb "$serial" get-state >/dev/null 2>&1; then
        phone_adb "$serial" shell dumpsys battery unplug >/dev/null
        phone_adb "$serial" shell dumpsys batterystats --reset >/dev/null
        phone_adb "$serial" shell dumpsys batterystats --enable full-wake-history >/dev/null 2>&1 || true
        date -u +%FT%TZ >"$out/energy-$phone-start.txt"
        sample_android "$serial" "$phone" &
      fi
    done
    [ -n "${LINUX_BUNDLE:-}" ] && { sample_linux & echo $! >"$out/.energy-linux.pid"; }
    [ -n "${WINDOWS:-}" ] && [ -n "${SSHPASS:-}" ] && { sample_windows & echo $! >"$out/.energy-windows.pid"; }
    ;;
  stop)
    rm -f "$out/.energy-on"
    # The samplers (started by "start", another process) see the flag gone
    # within their 10 s period and write their last line.
    sleep 12
    rm -f "$out"/.energy-*.pid
    for phone in android ${ANDROID2:+android2}; do
      serial=""
      [ "$phone" = android2 ] && serial=$ANDROID2
      phone_adb "$serial" get-state >/dev/null 2>&1 || continue
      # The machine-readable form, keyed by the app's uid.
      uid=$(phone_adb "$serial" shell cmd package list packages -U "$PACKAGE" | tr -d '\r' |
        sed -n "s/^package:$PACKAGE uid:\([0-9]*\)$/\1/p")
      {
        echo "from $(cat "$out/energy-$phone-start.txt" 2>/dev/null) to $(date -u +%FT%TZ)"
        echo "uid $uid"
        phone_adb "$serial" shell dumpsys batterystats --checkin | tr -d '\r' | grep "^9,$uid,l,"
      } >"$out/energy-$phone.txt" 2>&1
      phone_adb "$serial" shell dumpsys battery reset >/dev/null
    done
    python3 "$(dirname "$0")/energy_summary.py" "$out" || true
    ;;
esac

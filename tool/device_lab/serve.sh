#!/usr/bin/env bash
# Persistent lab: the devices start, pair and make the group once, with
# every transport on, and stay up; each phase then switches transports at
# runtime (one alone, or all) and runs one kind of test, instead of wiping
# the data and starting everything again per run.
#
#   PHASES="messages:lan burst:conestRelay calls:all contacts:nostr" \
#     SSHPASS=… WINDOWS=user@host LINUX_BUNDLE=… [lab.sh's other settings] \
#     tool/device_lab/serve.sh
#
# Each phase is KIND:TRANSPORT (KIND a --debug-run kind, TRANSPORT a
# TransportKind name or all). The devices are started by lab.sh with
# RUN=serve; every phase line goes to each device's <report>.cmd (see
# LabPhase in lib/src/debug_auto_run.dart), and its reports land in
# <run>/phase-N-KIND-TRANSPORT/, summarised like a whole run.
set -euo pipefail

: "${PHASES:?KIND:TRANSPORT …, such as messages:lan burst:all}"
: "${WINDOWS:?user@host of the Windows PC}"
: "${SSHPASS:?the Windows password, in the environment only}"
: "${LINUX_BUNDLE:?the unpacked Linux debug bundle}"
PACKAGE=${PACKAGE:-dev.conest.conest.debug}
ANDROID=${ANDROID:-1}
ANDROID2=${ANDROID2:-}
# Per phase, at most this long for every device's report.
PHASE_TIMEOUT=${PHASE_TIMEOUT:-1800}
win_user=${WINDOWS%@*}
WINDOWS_DIR=${WINDOWS_DIR:-C:\\Users\\$win_user\\conest-lab\\conest-debug-windows-x64}
android_report=files/conest-debug-report.json
win_report="$WINDOWS_DIR\\lab-report.json"
here=$(dirname "$0")
win() { sshpass -e ssh -o StrictHostKeyChecking=accept-new "$WINDOWS" "$@"; }

for phase in $PHASES; do
  case "$phase" in
    *:*) ;;
    *) echo "Not KIND:TRANSPORT: $phase" >&2; exit 2 ;;
  esac
done

phones=()
[ "$ANDROID" = 1 ] && phones+=("android:")
[ -n "$ANDROID2" ] && phones+=("android2:$ANDROID2")
adb_for() { # serial ("" = adb's default)
  if [ -n "$1" ]; then echo "adb -s $1"; else echo adb; fi
}

# Phases of an earlier serve run (kept lab data) must not run again.
win "del /Q \"$win_report.cmd\" \"$win_report.p*.json\"" >/dev/null 2>&1 || true
for entry in "${phones[@]}"; do
  $(adb_for "${entry#*:}") shell "run-as $PACKAGE sh -c 'rm -f $android_report.cmd $android_report.p*.json'" || true
done

mkdir -p device-lab-reports
before=$(ls device-lab-reports)
# Each device lingers (per phase) until the others are done with it.
lab_log=device-lab-reports/.serve-$$.log
RUN=serve LINGER=${LINGER:-300} "$here/lab.sh" > >(tee "$lab_log") 2>&1 &
lab_pid=$!
out=""
for _ in $(seq 1 60); do
  out=$(comm -13 <(echo "$before") <(ls device-lab-reports) | tail -1)
  [ -n "$out" ] && break
  sleep 1
done
[ -n "$out" ] || { echo "lab.sh made no report folder" >&2; exit 1; }
out=device-lab-reports/$out
linux_report="$PWD/$out/linux.json"
echo "Serving in $out"
# Phases are told once every device is up (FRESH=1 wipes a phone's data,
# and an earlier line with it, after the run's folder exists).
up_lines=("Linux is up." "Windows started.")
[ "$ANDROID" = 1 ] && up_lines+=("lab-android is up.")
[ -n "$ANDROID2" ] && up_lines+=("lab-android2 is up.")
for line in "${up_lines[@]}"; do
  until grep -qxF "$line" "$lab_log"; do
    kill -0 "$lab_pid" 2>/dev/null || { echo "lab.sh ended early" >&2; exit 1; }
    sleep 2
  done
done
mv "$lab_log" "$out/lab.log"
lab_log="$out/lab.log"

tell() { # one line for every device (one out of reach must not stop it)
  echo "$1" >>"$linux_report.cmd"
  win "echo $1>> \"$win_report.cmd\"" || echo "Could not tell Windows: $1" >&2
  local entry
  for entry in "${phones[@]}"; do
    $(adb_for "${entry#*:}") shell "run-as $PACKAGE sh -c 'echo \"$1\" >> $android_report.cmd'" ||
      echo "Could not tell ${entry%%:*}: $1" >&2
  done
}
# However this script ends, the devices are told to stop (each also stops
# by itself after two hours with no phase).
trap 'tell "stop stop" 2>/dev/null || true' EXIT

has_report() { # device, phase id
  case "$1" in
    linux) test -s "$linux_report.$2.json" ;;
    windows) win "if exist \"$win_report.$2.json\" (exit 0) else (exit 1)" ;;
    *) $(adb_for "$3") shell run-as "$PACKAGE" test -s "$android_report.$2.json" ;;
  esac
}

fetch_report() { # device, phase id, folder, serial
  case "$1" in
    linux) cp "$linux_report.$2.json" "$3/linux.json" ;;
    windows) win "type \"$win_report.$2.json\"" >"$3/windows.json" ;;
    *) $(adb_for "$4") exec-out run-as "$PACKAGE" cat "$android_report.$2.json" >"$3/$1.json" ;;
  esac
}

index=0
for phase in $PHASES; do
  index=$((index + 1))
  kind=${phase%%:*}
  transport=${phase#*:}
  id="p$index"
  folder="$out/phase-$index-$kind-$transport"
  mkdir -p "$folder"
  echo "=== Phase $index: $kind on $transport ($(date -u +%FT%TZ))"
  tell "$id $kind $transport"
  devices=("linux:" "windows:")
  for entry in "${phones[@]}"; do devices+=("$entry"); done
  deadline=$(($(date +%s) + PHASE_TIMEOUT))
  for entry in "${devices[@]}"; do
    name=${entry%%:*}
    serial=${entry#*:}
    until has_report "$name" "$id" "$serial" >/dev/null 2>&1; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "No $name report for phase $index" >&2
        break
      fi
      if ! kill -0 "$lab_pid" 2>/dev/null; then
        echo "lab.sh ended early" >&2
        exit 1
      fi
      sleep 5
    done
    fetch_report "$name" "$id" "$folder" "$serial" 2>/dev/null || true
  done
  python3 "$here/summarize.py" "$folder" || true
done

tell "stop stop"
trap - EXIT
wait "$lab_pid" || true

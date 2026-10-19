#!/usr/bin/env bash
# All-for-all device lab: debug builds on Android (adb), this Linux machine
# and a Windows PC (ssh) pair with each other, make a group, then test
# messages, files and every route between each pair and in the group.
#
#   SSHPASS=… WINDOWS=user@host LINUX_BUNDLE=~/conest-lab/linux \
#     RELAY=host:7667 [MATRIX_URL=http://lan-ip:8008 MATRIX_PASSWORD=…] \
#     tool/device_lab/lab.sh
#
# Needs the CI debug artifacts installed:
#   Android: the debug APK (package dev.conest.conest.debug);
#   Linux:   the debug bundle unpacked at $LINUX_BUNDLE;
#   Windows: the debug bundle unpacked at $WINDOWS_DIR (default
#            C:\Users\<user>\conest-lab\conest-debug-windows-x64).
# Each lab instance keeps its own data (portable on desktops, the debug
# package's own on Android), next to the user's real Conest.
#
# Pairing, so that every device is every other's contact:
#   A (Android) waits and approves; B (Linux) takes A's invite and
#   approves; C (Windows) takes both and makes the group lab-all.
# Reports land in ./device-lab-reports/<run>/, summarised at the end
# (tool/device_lab/summarize.py).
set -euo pipefail

: "${WINDOWS:?user@host of the Windows PC}"
: "${SSHPASS:?the Windows password, in the environment only}"
: "${LINUX_BUNDLE:?the unpacked Linux debug bundle}"
RELAY=${RELAY:-}
RUN=${RUN:-all}
WAIT=${WAIT:-20}
# How long each device stays online after its own tests, for the others.
LINGER=${LINGER:-600}
PACKAGE=${PACKAGE:-dev.conest.conest.debug}
win_user=${WINDOWS%@*}
WINDOWS_DIR=${WINDOWS_DIR:-C:\\Users\\$win_user\\conest-lab\\conest-debug-windows-x64}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=device-lab-reports/$stamp
mkdir -p "$out"

relay_arg=()
[ -n "$RELAY" ] && relay_arg=("--debug-relay=$RELAY")
# Every carrier the devices can run, switched on before pairing (empty:
# none). Meshtastic and MeshCore need radios and are not in the lab.
CARRIERS=${CARRIERS-nostr,tor,email,bitchat,reticulum}
RETICULUM=${RETICULUM:-}
# The chatmail server for email (a network may block the default).
CHATMAIL=${CHATMAIL:-}
# A lab homeserver with an account per device named lab-android,
# lab-linux and lab-windows, all with MATRIX_PASSWORD (empty: no Matrix).
# One transport only (a TransportKind name, such as nostr or tor): every
# other one, LAN too, is off on every device from before pairing, so
# contacts are added and messages sent over it alone.
ONLY=${ONLY:-}
MATRIX_URL=${MATRIX_URL:-}
MATRIX_PASSWORD=${MATRIX_PASSWORD:-}
# Conest sends Matrix passwords over plain HTTP only to this machine
# (localhost). MATRIX_TUNNEL=PORT makes a lab homeserver on this Linux
# machine's PORT local on the phone (adb reverse) and on Windows (an ssh
# tunnel for the run); use MATRIX_URL=http://localhost:PORT with it.
MATRIX_TUNNEL=${MATRIX_TUNNEL:-}
# TUNNELS="PORT …" does the same for other lab services on this machine
# (a Reticulum node: RETICULUM=localhost:PORT), past its firewall.
TUNNELS=${TUNNELS:-}
# Per device: ANDROID_CARRIERS, LINUX_CARRIERS, WINDOWS_CARRIERS.
carrier_args() { # device name
  local args=() var carriers
  var=$(echo "${1#lab-}" | tr '[:lower:]' '[:upper:]')_CARRIERS
  carriers=${!var-$CARRIERS}
  [ -n "$carriers" ] && args+=("--debug-carriers=$carriers")
  [ -n "$RETICULUM" ] && args+=("--debug-reticulum=$RETICULUM")
  [ -n "$CHATMAIL" ] && args+=("--debug-chatmail=$CHATMAIL")
  [ -n "$MATRIX_URL" ] && args+=("--debug-matrix=$MATRIX_URL,$1,$MATRIX_PASSWORD")
  [ -n "$ONLY" ] && args+=("--debug-only-transport=$ONLY")
  echo "${args[*]:-}"
}

win() { sshpass -e ssh -o StrictHostKeyChecking=accept-new "$WINDOWS" "$@"; }

# FRESH=1: every device starts from empty lab data (new identities, no
# contacts), so pairing is tested again. Only the lab instances' data.
if [ "${FRESH:-0}" = 1 ]; then
  # pm clear needs a permission some phones (Xiaomi) withhold from adb;
  # the debug app's own data can be removed with run-as instead.
  if [ "${ANDROID:-1}" = 1 ]; then
    adb shell am force-stop "$PACKAGE"
    adb shell "su -c 'pm clear $PACKAGE'" >/dev/null 2>&1 ||
      adb shell "run-as $PACKAGE sh -c 'for f in * .[!.]*; do [ \"\$f\" = lib ] || rm -rf \"\$f\"; done'" 2>/dev/null || true
  fi
  rm -rf "$LINUX_BUNDLE/conest_data"
  win "if exist \"$WINDOWS_DIR\\conest_data\" rmdir /S /Q \"$WINDOWS_DIR\\conest_data\"" || true
fi

# Android blocks a backgrounded app's network (netpolicy APP_BACKGROUND):
# once another app came to the front the lab app failed every send. The
# screen stays on for the run (on battery too), and the phone's own
# setting is put back; using the phone mid-run still backgrounds the app.
stay_on=""
if [ "${ANDROID:-1}" = 1 ]; then
  stay_on=$(adb shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')
  adb shell svc power stayon true >/dev/null 2>&1 || true
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
fi
restore_phone() {
  [ -n "$stay_on" ] && adb shell settings put global stay_on_while_plugged_in "$stay_on" >/dev/null 2>&1
  true
}
trap restore_phone EXIT

tunnel_pid=""
tunnel_ports=$(echo $MATRIX_TUNNEL $TUNNELS)
if [ -n "$tunnel_ports" ]; then
  forwards=()
  for port in $tunnel_ports; do
    [ "${ANDROID:-1}" = 1 ] && adb reverse "tcp:$port" "tcp:$port" >/dev/null
    forwards+=(-R "$port:localhost:$port")
  done
  sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
    -N "${forwards[@]}" "$WINDOWS" 2>/dev/null &
  tunnel_pid=$!
  trap '[ -n "$tunnel_pid" ] && kill "$tunnel_pid" 2>/dev/null; for port in $tunnel_ports; do adb reverse --remove "tcp:$port" 2>/dev/null; done; restore_phone' EXIT
fi

wait_for() { # description, command that succeeds when ready, tries
  for _ in $(seq 1 "${3:-120}"); do
    if eval "$2" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "Timed out waiting for $1" >&2
  return 1
}

# --- Devices ------------------------------------------------------------------
# Each device takes the invites it is given (and so sends those contact
# requests) and approves the requests it gets. ORDER=reverse turns who
# asks whom around, so both directions of adding a contact get tested:
#   normal:  Android; Linux takes Android's; Windows takes both, makes the group
#   reverse: Windows; Linux takes Windows'; Android takes both, makes the group
ANDROID=${ANDROID:-1}
ORDER=${ORDER:-normal}
android_report=files/conest-debug-report.json
linux_report="$PWD/$out/linux.json"
win_report="$WINDOWS_DIR\\lab-report.json"
# Invites hold | and other characters cmd reads: each is quoted, and
# their % (percent-encoded carrier addresses) doubled, or a batch file
# expands %…% as variables and the invite's signature no longer matches.
cmd_escape() { printf '%s' "${1//%/%%}"; }
adb_root() { adb shell "su -c '$1'" >/dev/null 2>&1 || adb shell "$1" >/dev/null 2>&1; }
linux_pid=""

start_android() { # group title or "", invites…
  local group=$1; shift
  adb shell am force-stop "$PACKAGE"
  # The Bluetooth mesh asks for these and nobody is there to tap Allow;
  # some phones (Xiaomi) refuse pm grant from adb, but not as root.
  for permission in BLUETOOTH_SCAN BLUETOOTH_CONNECT BLUETOOTH_ADVERTISE \
    ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION POST_NOTIFICATIONS NEARBY_WIFI_DEVICES; do
    adb_root "pm grant $PACKAGE android.permission.$permission"
  done
  adb shell run-as "$PACKAGE" rm -f "$android_report" "$android_report.invite" || true
  local args="--debug-run=$RUN --debug-name=lab-android --debug-approve --debug-no-reserve --debug-linger=$LINGER --debug-serve=600 --debug-expect-contacts=2 --debug-wait=$WAIT ${relay_arg[*]:-} $(carrier_args lab-android)"
  if [ -n "$group" ]; then args="$args --debug-group=$group"; else args="$args --debug-expect-group=lab-all"; fi
  for invite in "$@"; do args="$args --debug-accept-invite=$invite"; done
  adb shell am start -n "$PACKAGE/dev.conest.conest.MainActivity" \
    --es conestDebugArgs "'$args'" >/dev/null
  wait_for "the Android invite" "adb shell run-as $PACKAGE test -s $android_report.invite" 300
  invite_android=$(adb exec-out run-as "$PACKAGE" cat "$android_report.invite")
  echo "Android is up."
}

start_linux() { # group title or "", invites…
  local group=$1; shift
  local args=()
  if [ -n "$group" ]; then args+=("--debug-group=$group"); else args+=("--debug-expect-group=lab-all"); fi
  for invite in "$@"; do args+=("--debug-accept-invite=$invite"); done
  "$LINUX_BUNDLE/conest" --debug-run="$RUN" --debug-name=lab-linux \
    "${args[@]}" --debug-approve --debug-no-reserve --debug-linger="$LINGER" --debug-serve=540 --debug-expect-contacts=2 \
    --debug-wait="$WAIT" "${relay_arg[@]}" $(carrier_args lab-linux) --debug-report="$linux_report" \
    --debug-exit >"$out/linux.log" 2>&1 &
  linux_pid=$!
  wait_for "the Linux invite" "test -s '$linux_report.invite'" 300
  invite_linux=$(cat "$linux_report.invite")
  echo "Linux is up."
}

start_windows() { # group title or "", invites…
  local group=$1; shift
  # Started by a scheduled task, so it runs on the user's desktop, not in
  # the ssh session.
  win "if exist \"$win_report\" del \"$win_report\"" || true
  win "if exist \"$win_report.invite\" del \"$win_report.invite\"" || true
  local extra=""
  if [ -n "$group" ]; then extra="--debug-group=$group"; else extra="--debug-expect-group=lab-all"; fi
  for invite in "$@"; do extra="$extra \"--debug-accept-invite=$(cmd_escape "$invite")\""; done
  cat >"$out/start-windows.cmd" <<EOF
@echo off
"$WINDOWS_DIR\\conest.exe" --debug-run=$RUN --debug-name=lab-windows $extra --debug-approve --debug-no-reserve --debug-linger=$LINGER --debug-serve=540 --debug-expect-contacts=2 --debug-wait=$WAIT ${relay_arg[*]:-} $(carrier_args lab-windows) --debug-report="$win_report" --debug-exit
EOF
  sshpass -e scp -q "$out/start-windows.cmd" "$WINDOWS:conest-lab/start-lab.cmd"
  # LAN tests need inbound connections to the lab exe (only it, and only
  # for the run).
  win "netsh advfirewall firewall add rule name=ConestLab dir=in action=allow program=\"$WINDOWS_DIR\\conest.exe\" enable=yes" >/dev/null ||
    echo "Could not add the Windows firewall rule (LAN may be one-way)."
  # A task, so it runs on the user's desktop; allowed on battery (a laptop
  # on battery otherwise leaves it queued).
  cat >"$out/lab-task.ps1" <<'PS1'
$a = New-ScheduledTaskAction -Execute "$env:USERPROFILE\conest-lab\start-lab.cmd"
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
$p = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
Register-ScheduledTask -TaskName ConestLab -Action $a -Settings $s -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName ConestLab
PS1
  sshpass -e scp -q "$out/lab-task.ps1" "$WINDOWS:conest-lab/lab-task.ps1"
  win "powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\\conest-lab\\lab-task.ps1" >/dev/null
  wait_for "the Windows invite" "win \"if exist \\\"$win_report.invite\\\" (exit 0) else (exit 1)\"" 300
  invite_windows=$(win "type \"$win_report.invite\"" | tr -d '\r\n')
  echo "Windows started."
}

if [ "$ORDER" = reverse ]; then
  start_windows ""
  start_linux "" "$invite_windows"
  if [ "$ANDROID" = 1 ]; then
    start_android lab-all "$invite_windows" "$invite_linux"
  fi
else
  invites=()
  if [ "$ANDROID" = 1 ]; then
    start_android ""
    invites=("$invite_android")
  fi
  start_linux "" "${invites[@]}"
  start_windows lab-all "${invites[@]}" "$invite_linux"
fi

# --- Reports ------------------------------------------------------------------------
[ -n "$linux_pid" ] && { wait "$linux_pid" || echo "Linux run ended with an error (see linux.log)."; }
# A missing report must not cost the others (or the clean-up below).
if wait_for "the Windows report" "win \"if exist \\\"$win_report\\\" (exit 0) else (exit 1)\"" 300; then
  sshpass -e scp -q "$WINDOWS:conest-lab/conest-debug-windows-x64/lab-report.json" "$out/windows.json" ||
    win "type \"$win_report\"" >"$out/windows.json"
fi
if [ "$ANDROID" = 1 ]; then
  if wait_for "the Android report" "adb shell run-as $PACKAGE test -s $android_report" 300; then
    adb exec-out run-as "$PACKAGE" cat "$android_report" >"$out/android.json"
  fi
  adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
fi
# The lab build only (by its folder): the user's own Conest keeps running.
win "powershell -NoProfile -Command \"Get-Process conest -ErrorAction SilentlyContinue | Where-Object Path -Like '*\\conest-lab\\*' | Stop-Process -Force\"" >/dev/null 2>&1 || true
win "schtasks /Delete /F /TN ConestLab" >/dev/null || true
win "netsh advfirewall firewall delete rule name=ConestLab" >/dev/null || true
echo "Reports in $out"
python3 "$(dirname "$0")/summarize.py" "$out" || true

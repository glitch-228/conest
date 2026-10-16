#!/usr/bin/env bash
# All-for-all device lab: debug builds on Android (adb), this Linux machine
# and a Windows PC (ssh) pair with each other, make a group, then test
# messages, files and every route between each pair and in the group.
#
#   SSHPASS=… WINDOWS=user@host LINUX_BUNDLE=~/conest-lab/linux \
#     RELAY=host:7667 tool/device_lab/lab.sh
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

win() { sshpass -e ssh -o StrictHostKeyChecking=accept-new "$WINDOWS" "$@"; }

wait_for() { # description, command that succeeds when ready, tries
  for _ in $(seq 1 "${3:-120}"); do
    if eval "$2" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "Timed out waiting for $1" >&2
  return 1
}

# --- A: Android (ANDROID=0 leaves it out) ---------------------------------------
ANDROID=${ANDROID:-1}
android_report=files/conest-debug-report.json
invite_args=()
if [ "$ANDROID" = 1 ]; then
adb shell am force-stop "$PACKAGE"
adb shell run-as "$PACKAGE" rm -f "$android_report" "$android_report.invite" || true
args_a="--debug-run=$RUN --debug-name=lab-android --debug-approve --debug-no-reserve --debug-linger=$LINGER --debug-serve=300 --debug-wait=$WAIT ${relay_arg[*]:-}"
adb shell am start -n "$PACKAGE/dev.conest.conest.MainActivity" \
  --es conestDebugArgs "'$args_a'" >/dev/null
wait_for "the Android invite" "adb shell run-as $PACKAGE test -s $android_report.invite"
invite_a=$(adb exec-out run-as "$PACKAGE" cat "$android_report.invite")
invite_args=("--debug-accept-invite=$invite_a")
echo "Android is up."
fi

# --- B: Linux -------------------------------------------------------------------
linux_report="$PWD/$out/linux.json"
"$LINUX_BUNDLE/conest" --debug-run="$RUN" --debug-name=lab-linux \
  "${invite_args[@]}" --debug-approve --debug-no-reserve --debug-linger="$LINGER" --debug-serve=240 \
  --debug-wait="$WAIT" "${relay_arg[@]}" --debug-report="$linux_report" \
  --debug-exit >"$out/linux.log" 2>&1 &
linux_pid=$!
wait_for "the Linux invite" "test -s '$linux_report.invite'"
invite_b=$(cat "$linux_report.invite")
echo "Linux is up."

# --- C: Windows -----------------------------------------------------------------
# Started by a scheduled task, so it runs on the user's desktop, not in the
# ssh session.
win_report="$WINDOWS_DIR\\lab-report.json"
win "if exist \"$win_report\" del \"$win_report\""
# Invites hold | and other characters cmd reads: each is quoted.
win_invites=""
[ "$ANDROID" = 1 ] && win_invites="\"--debug-accept-invite=$invite_a\" "
win_invites="$win_invites\"--debug-accept-invite=$invite_b\""
cat >"$out/start-windows.cmd" <<EOF
@echo off
"$WINDOWS_DIR\\conest.exe" --debug-run=$RUN --debug-name=lab-windows $win_invites --debug-no-reserve --debug-linger=$LINGER --debug-serve=30 --debug-group=lab-all --debug-wait=$WAIT ${relay_arg[*]:-} --debug-report="$win_report" --debug-exit
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
echo "Windows started."

# --- Reports ------------------------------------------------------------------------
wait "$linux_pid" || echo "Linux run ended with an error (see linux.log)."
wait_for "the Windows report" "win \"if exist \\\"$win_report\\\" (exit 0) else (exit 1)\"" 300
sshpass -e scp -q "$WINDOWS:conest-lab/conest-debug-windows-x64/lab-report.json" "$out/windows.json" ||
  win "type \"$win_report\"" >"$out/windows.json"
if [ "$ANDROID" = 1 ]; then
  wait_for "the Android report" "adb shell run-as $PACKAGE test -s $android_report" 300
  adb exec-out run-as "$PACKAGE" cat "$android_report" >"$out/android.json"
fi
win "schtasks /Delete /F /TN ConestLab" >/dev/null || true
win "netsh advfirewall firewall delete rule name=ConestLab" >/dev/null || true
echo "Reports in $out"
python3 "$(dirname "$0")/summarize.py" "$out" || true

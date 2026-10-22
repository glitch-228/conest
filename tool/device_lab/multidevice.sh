#!/usr/bin/env bash
# One account on two devices, and a contact: the device lab for own-device
# sync (M29e).
#
#   ANDROID_SERIAL=… ANDROID2=… ACCOUNT_BUNDLE=~/conest-lab/linux-account/… \
#     [RELAY=host:7667] [RUN=messages] tool/device_lab/multidevice.sh
#
# A (a Linux instance in ACCOUNT_BUNDLE, lab-account) holds the account:
# a bundle of its own, so the other lab runs never touch its data. FRESH=1
# (the default) starts it from nothing too; FRESH=0 keeps the account it
# had (to test linking into an older one).
#
# B (the second phone, lab-android2) joins A's account: B shows the link
# text, A takes it, each writes the code it shows, and the script hands
# each the other's (each confirms only if they match). C (the first phone,
# lab-android) then adds A from A's invite and runs RUN against it; what
# reaches the account should reach B too. The reports land in
# ./device-lab-reports/<run>/ (a.json, b.json, c.json).
set -euo pipefail

: "${ANDROID_SERIAL:?the first phone, C (adb serial)}"
: "${ANDROID2:?the second phone, B (adb serial)}"
: "${ACCOUNT_BUNDLE:?a Linux debug bundle kept for A}"
RELAY=${RELAY:-}
RUN=${RUN:-messages}
LINGER=${LINGER:-300}
WAIT=${WAIT:-20}
PACKAGE=${PACKAGE:-dev.conest.conest.debug}
report=files/conest-debug-report.json
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=device-lab-reports/$stamp
mkdir -p "$out"
a_report="$PWD/$out/a.json"
relay_arg=""
[ -n "$RELAY" ] && relay_arg="--debug-relay=$RELAY"

phone() { adb -s "$1" "${@:2}"; }
wait_for() { # description, command that succeeds when ready, tries
  for _ in $(seq 1 "${3:-150}"); do
    if eval "$2" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "Timed out waiting for $1" >&2
  return 1
}
phone_file() { phone "$1" exec-out run-as "$PACKAGE" cat "$report.$2"; }
has_file() { phone "$1" shell run-as "$PACKAGE" test -s "$report.$2"; }

# Fresh lab data on both phones (the lab app only), and on A unless kept.
[ "${FRESH:-1}" = 1 ] && rm -rf "$ACCOUNT_BUNDLE/conest_data"
for serial in "$ANDROID_SERIAL" "$ANDROID2"; do
  phone "$serial" shell am force-stop "$PACKAGE"
  phone "$serial" shell "su -c 'pm clear $PACKAGE'" >/dev/null 2>&1 ||
    phone "$serial" shell "run-as $PACKAGE sh -c 'for f in * .[!.]*; do [ \"\$f\" = lib ] || rm -rf \"\$f\"; done'" 2>/dev/null || true
  phone "$serial" shell svc power stayon true >/dev/null 2>&1 || true
  phone "$serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  phone "$serial" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  for permission in POST_NOTIFICATIONS NEARBY_WIFI_DEVICES RECORD_AUDIO; do
    phone "$serial" shell "su -c 'pm grant $PACKAGE android.permission.$permission'" >/dev/null 2>&1 ||
      phone "$serial" shell "pm grant $PACKAGE android.permission.$permission" >/dev/null 2>&1 || true
  done
done

start_phone() { # serial, args
  phone "$1" shell am start -n "$PACKAGE/dev.conest.conest.MainActivity" \
    --es conestDebugArgs "'$2'" >/dev/null
}
common="--debug-approve --debug-no-reserve --debug-linger=$LINGER --debug-wait=$WAIT"

# B: the new device, shows its link text.
start_phone "$ANDROID2" "--debug-run=none --debug-name=lab-android2 --debug-link-new --debug-serve=600 $common $relay_arg"
wait_for "B's link text" "has_file $ANDROID2 link"
link=$(phone_file "$ANDROID2" link)

# A: takes it, then waits for C.
"$ACCOUNT_BUNDLE/conest" --debug-run=none --debug-name=lab-account \
  "--debug-link-from=$link" --debug-expect-contacts=1 --debug-serve=600 \
  $common $relay_arg --debug-report="$a_report" --debug-exit \
  >"$out/account.log" 2>&1 &
a_pid=$!

# The codes, as a person compares the two screens.
wait_for "A's code" "test -s '$a_report.code'"
wait_for "B's code" "has_file $ANDROID2 code"
code_a=$(tr -dc '0-9A-Za-z -' <"$a_report.code")
code_b=$(phone_file "$ANDROID2" code | tr -dc '0-9A-Za-z -')
echo "Codes: A '$code_a', B '$code_b'"
printf '%s' "$code_b" >"$a_report.peer-code"
phone "$ANDROID2" shell "run-as $PACKAGE sh -c 'echo \"$code_a\" > $report.peer-code'"
wait_for "A's invite" "test -s '$a_report.invite'" 300
invite=$(cat "$a_report.invite")

# C: adds A and runs RUN against the account.
start_phone "$ANDROID_SERIAL" "--debug-run=$RUN --debug-name=lab-android --debug-accept-invite=$invite --debug-expect-contacts=1 --debug-serve=540 $common $relay_arg"

wait "$a_pid" || echo "A ended with an error (see account.log)."
for pair in "$ANDROID_SERIAL:c" "$ANDROID2:b"; do
  serial=${pair%:*}
  name=${pair##*:}
  if wait_for "report $name" "phone $serial shell run-as $PACKAGE test -s $report" 300; then
    phone "$serial" exec-out run-as "$PACKAGE" cat "$report" >"$out/$name.json"
  fi
  phone "$serial" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
done
echo "Reports in $out"
python3 "$(dirname "$0")/summarize.py" "$out" || true

#!/usr/bin/env bash
# One short lab run per transport: every device starts from empty lab
# data, every other transport (LAN too) is off, and the devices add each
# other as contacts and send messages over that transport alone.
#
#   SSHPASS=… WINDOWS=user@host LINUX_BUNDLE=… RELAY=host:7667 \
#     [MATRIX_PASSWORD=… MATRIX_TUNNEL=8008] \
#     tool/device_lab/per_transport.sh [transport …]
#
# Transports are TransportKind names; the default is all those the lab has:
# conestRelay iroh nostr tor deltaChat reticulum matrix bitchat. Each runs in
# both pairing orders (ORDERS="normal reverse"), so every device both sends
# and approves contact requests over it. Each run's
# reports land in device-lab-reports/ as usual; a one-line verdict per
# transport is printed at the end.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
transports=("$@")
[ ${#transports[@]} = 0 ] && transports=(conestRelay iroh nostr tor deltaChat reticulum matrix bitchat)
verdicts=()

orders=(${ORDERS:-normal reverse})
for transport in "${transports[@]}"; do
for order in "${orders[@]}"; do
  carriers=""
  case "$transport" in
    nostr | tor | reticulum | bitchat) carriers=$transport ;;
    deltaChat) carriers=email ;;
  esac
  matrix_url=""
  [ "$transport" = matrix ] && matrix_url=${MATRIX_URL:-http://localhost:${MATRIX_TUNNEL:-8008}}
  echo "=== $transport ($order) ==="
  before=$(ls device-lab-reports 2>/dev/null | tail -1)
  env -u ANDROID_CARRIERS -u LINUX_CARRIERS -u WINDOWS_CARRIERS \
    FRESH=1 ORDER=$order ONLY=$transport CARRIERS=$carriers MATRIX_URL=$matrix_url \
    RUN=${RUN:-messages} LINGER=${LINGER:-180} WAIT=${WAIT:-20} \
    "$here/lab.sh" > "per-transport-$transport-$order.log" 2>&1
  run=$(ls device-lab-reports | tail -1)
  if [ "$run" = "$before" ]; then
    verdicts+=("$transport ($order): no reports (see per-transport-$transport-$order.log)")
    continue
  fi
  verdicts+=("$transport ($order): $(python3 "$here/summarize.py" --verdict "device-lab-reports/$run")")
done
done

echo
printf '%s\n' "${verdicts[@]}"

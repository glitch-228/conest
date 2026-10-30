#!/usr/bin/env bash
# The release gate: lab runs on the installed build, compared with the last
# gate that passed, so a release never delivers less than the one before.
#
#   SSHPASS=… WINDOWS=user@host LINUX_BUNDLE=… RELAY=host:7667 \
#     [MATRIX_PASSWORD=… MATRIX_TUNNEL=8008 TUNNELS=4242 RETICULUM=localhost:4242] \
#     tool/device_lab/release_gate.sh quick|full
#
#   quick (before every nightly tag, about an hour): all transports together
#     in both orders, then the relay, Iroh, Nostr, Matrix and email each
#     alone, then a calls run.
#   full (before every stable, a few hours): every transport alone in both
#     orders, contacts on the main ones, all together, interactions, calls.
#
# Install the build first (tool/device_lab/install.sh <run id>). The
# baseline is ~/conest-lab/gate/<mode>-last-pass.json; a passing run
# replaces it (a dated copy stays). Exit 1 on a regression (gate.py says
# why). Credentials only in the environment.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
gate_dir=${GATE_DIR:-$HOME/conest-lab/gate}
mkdir -p "$gate_dir"
baseline="$gate_dir/$mode-last-pass.json"
labels=()

run_lab() { # label, then env assignments for lab.sh
  local label=$1
  shift
  local before run
  before=$(ls device-lab-reports 2>/dev/null | tail -1)
  echo "=== $label $(date -u +%FT%TZ)"
  env -u ANDROID_CARRIERS -u LINUX_CARRIERS -u WINDOWS_CARRIERS \
    LINGER="${LINGER:-180}" WAIT="${WAIT:-20}" "$@" \
    "$here/lab.sh" >"gate-$label.log" 2>&1
  run=$(ls device-lab-reports 2>/dev/null | tail -1)
  if [ "$run" = "$before" ]; then
    echo "$label: no reports (see gate-$label.log)"
    labels+=("$label=device-lab-reports/missing-$label")
  else
    labels+=("$label=device-lab-reports/$run")
  fi
}

alone() { # transport, order, scenario
  local carriers="" matrix_url=""
  case "$1" in
    nostr | tor | reticulum | bitchat) carriers=$1 ;;
    deltaChat) carriers=email ;;
  esac
  [ "$1" = matrix ] && matrix_url=${MATRIX_URL:-http://localhost:${MATRIX_TUNNEL:-8008}}
  run_lab "$1-$2-$3" FRESH=1 ORDER="$2" ONLY="$1" CARRIERS="$carriers" \
    MATRIX_URL="$matrix_url" RUN="$3"
}

together() { # order, scenario
  run_lab "all-$1-$2" FRESH=1 ORDER="$1" RUN="$2"
}

case "$mode" in
  quick)
    together normal burst
    together reverse burst
    for transport in conestRelay iroh nostr matrix deltaChat; do
      alone "$transport" normal burst
    done
    together normal calls
    ;;
  full)
    for transport in lan conestRelay iroh nostr deltaChat matrix tor reticulum bitchat; do
      for order in normal reverse; do alone "$transport" "$order" burst; done
    done
    for transport in lan conestRelay iroh nostr deltaChat matrix; do
      alone "$transport" normal contacts
    done
    for order in normal reverse; do
      together "$order" burst
      together "$order" interactions
      together "$order" calls
    done
    ;;
  *)
    echo "usage: $0 quick|full" >&2
    exit 2
    ;;
esac

echo "=== gate ($mode) against $baseline"
budgets=()
# Before a stable, the app's own stutter and latency must also stay within
# fixed budgets (gate.py), whatever the last run did.
[ "$mode" = full ] && budgets=(--budgets)
if python3 "$here/gate.py" check "$baseline" "${budgets[@]}" "${labels[@]}"; then
  python3 "$here/gate.py" record "$baseline" "${labels[@]}"
  cp "$baseline" "$gate_dir/$mode-$(date -u +%Y%m%dT%H%M%SZ).json"
  echo "gate passed"
else
  echo "gate FAILED: no tag until this is explained or fixed"
  exit 1
fi

#!/bin/sh
# Conest relay installer.
#
#   curl -fsSL https://github.com/glitch-228/conest/releases/latest/download/install-relay.sh | sh
#   wget -qO- https://github.com/glitch-228/conest/releases/latest/download/install-relay.sh | sh
#
# Asks before each step (answers come from the terminal even when the
# script itself is piped in). `--yes` takes every default; see --help.
#
# What it can do, each step optional:
#   - download the relay (and its supervisor) for this machine, checking the
#     signed release manifest and every file's SHA-256;
#   - create a system account and folders for it;
#   - open its port in ufw or firewalld;
#   - install it as a systemd service: the supervisor (signed automatic
#     updates in a maintenance hour, rollback when a new version fails its
#     health check) or the relay alone;
#   - start it, check it answers, and print what to add in Conest.
# Run it again to upgrade, or with --uninstall to remove it.

set -eu

REPO="glitch-228/conest"
# Filled in when the release is published; --release-key overrides it.
RELEASE_PUBLIC_KEY="@RELEASE_PUBLIC_KEY@"

CHANNEL="stable"
PORT="7667"
BIND_HOST="0.0.0.0"
SERVICE_USER="conest-relay"
DATA_DIR="/var/lib/conest-relay"
BUNDLE_DIR="/opt/conest-relay"
MAINTENANCE_HOUR="3"
ASSUME_YES=0
MODE="install"
TAG=""
WORK=""

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Conest relay installer

  --yes                 take every default without asking
  --channel stable|nightly
  --port N              (default 7667)
  --bind HOST           address to listen on (default 0.0.0.0)
  --user NAME           service account (default conest-relay)
  --data-dir PATH       (default /var/lib/conest-relay)
  --bundle-dir PATH     (default /opt/conest-relay)
  --maintenance-hour H  hour (UTC, 0-23) updates may restart it (default 3)
  --tag TAG             a specific release instead of the newest
  --release-key BASE64  the release signing key (if this copy has none)
  --uninstall           stop and remove the service (keeps the data)
  --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
  --yes | -y) ASSUME_YES=1 ;;
  --channel) CHANNEL="${2:?}"; shift ;;
  --port) PORT="${2:?}"; shift ;;
  --bind) BIND_HOST="${2:?}"; shift ;;
  --user) SERVICE_USER="${2:?}"; shift ;;
  --data-dir) DATA_DIR="${2:?}"; shift ;;
  --bundle-dir) BUNDLE_DIR="${2:?}"; shift ;;
  --maintenance-hour) MAINTENANCE_HOUR="${2:?}"; shift ;;
  --tag) TAG="${2:?}"; shift ;;
  --release-key) RELEASE_PUBLIC_KEY="${2:?}"; shift ;;
  --uninstall) MODE="uninstall" ;;
  --help | -h)
    usage
    exit 0
    ;;
  *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done

# Answers come from the terminal: stdin is this script when piped.
TTY=""
if [ "$ASSUME_YES" -eq 0 ]; then
  if (exec </dev/tty) 2>/dev/null; then
    TTY=/dev/tty
  else
    die "no terminal to ask on: run with --yes (and options) instead"
  fi
fi

# ask "question" default(y|n) -> 0 for yes
ask() {
  if [ "$ASSUME_YES" -eq 1 ]; then
    [ "$2" = y ]
    return
  fi
  if [ "$2" = y ]; then hint="Y/n"; else hint="y/N"; fi
  while :; do
    printf '%s [%s] ' "$1" "$hint" >&2
    read -r answer <"$TTY" || answer=""
    case "${answer:-$2}" in
    y | Y | yes | YES) return 0 ;;
    n | N | no | NO) return 1 ;;
    esac
  done
}

# ask_value "question" default -> prints the answer
ask_value() {
  if [ "$ASSUME_YES" -eq 1 ]; then
    printf '%s' "$2"
    return
  fi
  printf '%s [%s] ' "$1" "$2" >&2
  read -r answer <"$TTY" || answer=""
  printf '%s' "${answer:-$2}"
}

need() { command -v "$1" >/dev/null 2>&1; }

fetch() { # url file
  if need curl; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
  elif need wget; then
    wget -q --https-only -O "$2" "$1"
  else
    die "curl or wget is needed"
  fi
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif need sudo; then
    sudo "$@"
  else
    die "this step needs root (run as root, or install sudo)"
  fi
}

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

valid_port() {
  case "$1" in
  '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# --- Uninstall ---------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
  step "Removing the Conest relay service"
  if need systemctl && [ -f /etc/systemd/system/conest-relay.service ]; then
    as_root systemctl disable --now conest-relay.service || true
    as_root rm -f /etc/systemd/system/conest-relay.service
    as_root systemctl daemon-reload
    say "Service removed."
  else
    say "No conest-relay service found."
  fi
  if ask "Also delete the program files in $BUNDLE_DIR?" n; then
    as_root rm -rf "$BUNDLE_DIR"
  fi
  if ask "Also delete the relay's identity and stored messages in $DATA_DIR? (Contacts will see a different relay.)" n; then
    as_root rm -rf "$DATA_DIR"
  fi
  exit 0
fi

# --- This machine -------------------------------------------------------------
step "Checking this machine"
[ "$(uname -s)" = Linux ] || die "this installer is for Linux servers"
case "$(uname -m)" in
x86_64 | amd64) ARCH="x64" ;;
aarch64 | arm64) ARCH="arm64" ;;
*) die "no relay build for $(uname -m) yet" ;;
esac
need sha256sum || die "sha256sum is needed"
need base64 || die "base64 is needed"
INIT="none"
if need systemctl && [ -d /run/systemd/system ]; then INIT="systemd"; fi
say "Linux $ARCH, service manager: $INIT"

case "$RELEASE_PUBLIC_KEY" in
@*@ | "")
  die "this copy has no release key: download install-relay.sh from a Conest release, or pass --release-key"
  ;;
esac

if [ "$ASSUME_YES" -eq 0 ]; then
  CHANNEL=$(ask_value "Release channel (stable or nightly)" "$CHANNEL")
fi
case "$CHANNEL" in
stable | nightly) ;;
*) die "channel must be stable or nightly" ;;
esac

# --- Download and verify ------------------------------------------------------
step "Downloading the relay ($CHANNEL)"
WORK=$(mktemp -d)
if [ -n "$TAG" ]; then
  BASE="https://github.com/$REPO/releases/download/$TAG"
elif [ "$CHANNEL" = stable ]; then
  BASE="https://github.com/$REPO/releases/latest/download"
else
  fetch "https://api.github.com/repos/$REPO/releases?per_page=20" "$WORK/releases.json"
  # The newest pre-release that carries a manifest.
  BASE=$(tr ',' '\n' <"$WORK/releases.json" |
    sed -n 's#.*"browser_download_url": *"\(https://github.com/'"$REPO"'/releases/download/[^"]*-nightly[^"]*\)/RELEASE-MANIFEST.json".*#\1#p' |
    head -n 1)
  [ -n "$BASE" ] || die "no nightly release found"
fi
fetch "$BASE/RELEASE-MANIFEST.json" "$WORK/RELEASE-MANIFEST.json"
fetch "$BASE/RELEASE-MANIFEST.ed25519.sig" "$WORK/RELEASE-MANIFEST.ed25519.sig"

# The manifest's Ed25519 signature: openssl 3 when present; otherwise the
# supervisor checks it (below) before anything runs.
SIGNATURE_CHECKED=0
if need openssl && openssl version 2>/dev/null | grep -q '^OpenSSL 3'; then
  # A raw Ed25519 key wrapped as SubjectPublicKeyInfo (fixed 12-byte prefix).
  {
    printf '\060\052\060\005\006\003\053\145\160\003\041\000'
    printf '%s' "$RELEASE_PUBLIC_KEY" | base64 -d
  } >"$WORK/key.der"
  base64 -d <"$WORK/RELEASE-MANIFEST.ed25519.sig" >"$WORK/manifest.sig"
  if openssl pkeyutl -verify -pubin -inkey "$WORK/key.der" -keyform DER \
    -rawin -in "$WORK/RELEASE-MANIFEST.json" -sigfile "$WORK/manifest.sig" >/dev/null 2>&1; then
    SIGNATURE_CHECKED=1
    say "Release manifest signature: valid."
  else
    die "the release manifest's signature does not match the Conest release key"
  fi
fi

TAG_NAME=$(sed -n 's/.*"tagName": *"\([^"]*\)".*/\1/p' "$WORK/RELEASE-MANIFEST.json" | head -n 1)
[ -n "$TAG_NAME" ] || die "the release manifest has no tag"
say "Release: $TAG_NAME"

# asset_hash NAME -> its sha256 in the manifest
asset_hash() {
  # One asset per line (the manifest is pretty-printed).
  tr -d '\n\r' <"$WORK/RELEASE-MANIFEST.json" | tr '{' '\n' |
    grep "\"name\": *\"$1\"" |
    sed -n 's/.*"sha256": *"\([0-9a-f]\{64\}\)".*/\1/p' |
    head -n 1
}

download_asset() { # name target
  expected=$(asset_hash "$1")
  [ -n "$expected" ] || die "$1 is not in this release (no $ARCH build?)"
  fetch "$BASE/$1" "$WORK/$1"
  actual=$(sha256sum "$WORK/$1" | cut -d' ' -f1)
  [ "$actual" = "$expected" ] || die "$1 does not match the release manifest"
  cp "$WORK/$1" "$2"
  chmod 0755 "$2"
}

RELAY_ASSET="conest_relay-linux-$ARCH-$TAG_NAME"
SUPERVISOR_ASSET="conest_relay_supervisor-linux-$ARCH-$TAG_NAME"
download_asset "$RELAY_ASSET" "$WORK/conest_relay"
download_asset "$SUPERVISOR_ASSET" "$WORK/conest_relay_supervisor"
if [ "$SIGNATURE_CHECKED" -eq 0 ]; then
  # Without openssl 3 the hashes above are only as good as the manifest:
  # the supervisor verifies its signature with the embedded key.
  "$WORK/conest_relay_supervisor" verify-manifest \
    --manifest "$WORK/RELEASE-MANIFEST.json" \
    --signature "$WORK/RELEASE-MANIFEST.ed25519.sig" \
    --release-public-key "$RELEASE_PUBLIC_KEY" ||
    die "the release manifest's signature does not match the Conest release key"
  say "Release manifest signature: valid."
fi
say "Downloaded and checked."

# --- Settings -----------------------------------------------------------------
step "Settings"
if [ "$ASSUME_YES" -eq 0 ]; then
  PORT=$(ask_value "Port to listen on (TCP and UDP)" "$PORT")
  BIND_HOST=$(ask_value "Address to listen on (0.0.0.0 = all)" "$BIND_HOST")
fi
valid_port "$PORT" || die "not a port: $PORT"

# --- Account and folders --------------------------------------------------------
USE_ACCOUNT=0
if ask "Run it as its own system account ($SERVICE_USER) instead of root?" y; then
  USE_ACCOUNT=1
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    if need useradd; then
      as_root useradd --system --home-dir "$DATA_DIR" --no-create-home \
        --shell /usr/sbin/nologin "$SERVICE_USER"
    elif need adduser; then
      as_root adduser -S -D -H -h "$DATA_DIR" -s /sbin/nologin "$SERVICE_USER"
    else
      die "cannot create a system account (no useradd or adduser)"
    fi
  fi
fi
as_root mkdir -p "$DATA_DIR" "$BUNDLE_DIR"
as_root install -m 0755 "$WORK/conest_relay" "$BUNDLE_DIR/conest_relay"
as_root install -m 0755 "$WORK/conest_relay_supervisor" "$BUNDLE_DIR/conest_relay_supervisor"
if [ "$USE_ACCOUNT" -eq 1 ]; then
  as_root chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR" "$BUNDLE_DIR"
  as_root chmod 0700 "$DATA_DIR"
fi
say "Installed in $BUNDLE_DIR; data in $DATA_DIR."

# --- Firewall -----------------------------------------------------------------
if need ufw && as_root ufw status 2>/dev/null | grep -q 'Status: active'; then
  if ask "Open port $PORT (TCP and UDP) in ufw?" y; then
    as_root ufw allow "$PORT/tcp"
    as_root ufw allow "$PORT/udp"
  fi
elif need firewall-cmd && as_root firewall-cmd --state >/dev/null 2>&1; then
  if ask "Open port $PORT (TCP and UDP) in firewalld?" y; then
    as_root firewall-cmd --permanent --add-port="$PORT/tcp"
    as_root firewall-cmd --permanent --add-port="$PORT/udp"
    as_root firewall-cmd --reload
  fi
else
  say "No ufw or firewalld running: make sure port $PORT (TCP and UDP) is reachable, including in your provider's firewall."
fi

# --- Service --------------------------------------------------------------------
if [ "$INIT" != systemd ]; then
  say "No systemd here: start it yourself with"
  say "  $BUNDLE_DIR/conest_relay $BIND_HOST:$PORT --identity-seed-path $DATA_DIR/relay-identity.seed --database-path $DATA_DIR/relay.sqlite3"
  exit 0
fi

step "Service"
USER_OPTION=""
[ "$USE_ACCOUNT" -eq 1 ] && USER_OPTION="--service-user $SERVICE_USER"
if ask "Install the supervisor (signed automatic updates, with rollback)? Otherwise the relay runs on its own." y; then
  if [ "$ASSUME_YES" -eq 0 ]; then
    MAINTENANCE_HOUR=$(ask_value "Hour (UTC, 0-23) updates may restart it" "$MAINTENANCE_HOUR")
  fi
  # shellcheck disable=SC2086
  as_root "$BUNDLE_DIR/conest_relay_supervisor" install \
    --data-dir "$DATA_DIR" --bundle-dir "$BUNDLE_DIR" \
    --bind "$BIND_HOST:$PORT" --channel "$CHANNEL" \
    --manifest-url "github:$REPO" \
    --release-public-key "$RELEASE_PUBLIC_KEY" \
    --maintenance-hour "$MAINTENANCE_HOUR" $USER_OPTION
else
  RELAY_ID_FILE="$DATA_DIR/relay-id"
  if ! as_root test -s "$RELAY_ID_FILE"; then
    printf 'relay-%s' "$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" |
      as_root tee "$RELAY_ID_FILE" >/dev/null
  fi
  RELAY_ID=$(as_root cat "$RELAY_ID_FILE")
  UNIT_USER=""
  [ "$USE_ACCOUNT" -eq 1 ] && UNIT_USER="User=$SERVICE_USER
Group=$SERVICE_USER
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$DATA_DIR"
  as_root tee /etc/systemd/system/conest-relay.service >/dev/null <<EOF
[Unit]
Description=Conest Relay
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=$BUNDLE_DIR/conest_relay $BIND_HOST:$PORT --relay-id $RELAY_ID --identity-seed-path $DATA_DIR/relay-identity.seed --database-path $DATA_DIR/relay.sqlite3
Restart=always
RestartSec=3
$UNIT_USER

[Install]
WantedBy=multi-user.target
EOF
  as_root systemctl daemon-reload
  as_root systemctl enable --now conest-relay.service
fi

# --- Check ------------------------------------------------------------------------
step "Checking it answers"
HEALTH=""
i=0
while [ $i -lt 20 ]; do
  if need curl; then
    HEALTH=$(curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null || true)
  else
    HEALTH=$(wget -qO- "http://127.0.0.1:$PORT/health" 2>/dev/null || true)
  fi
  [ -n "$HEALTH" ] && break
  i=$((i + 1))
  sleep 1
done
[ -n "$HEALTH" ] || die "the relay does not answer on port $PORT (see: journalctl -u conest-relay)"
KEY=$(printf '%s' "$HEALTH" | sed -n 's/.*"identity_public_key": *"\([^"]*\)".*/\1/p')
ID=$(printf '%s' "$HEALTH" | sed -n 's/.*"relay_id": *"\([^"]*\)".*/\1/p')
VERSION=$(printf '%s' "$HEALTH" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')

ADDRESS=$(ask_value "This server's public address or domain (as Conest should reach it)" \
  "$( (need curl && curl -fsS https://api.ipify.org 2>/dev/null) || hostname -f 2>/dev/null || hostname)")
LINK="conest-relay://$ADDRESS:$PORT?id=$ID&key=$(printf '%s' "$KEY" | sed 's/+/%2B/g; s#/#%2F#g; s/=/%3D/g')"

step "Done"
say "Conest relay $VERSION is running."
say "  Address:      $ADDRESS:$PORT"
say "  Relay id:     $ID"
say "  Identity key: $KEY"
say ""
say "In Conest: Settings > Relays > Add from link, and paste:"
say "  $LINK"
if need qrencode; then
  qrencode -t ANSIUTF8 "$LINK"
else
  say "(Install qrencode to show it as a QR code.)"
fi
say ""
say "Logs: journalctl -u conest-relay -f"
say "Remove: run this installer again with --uninstall"

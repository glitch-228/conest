#!/usr/bin/env bash
# Builds lyrebird, Tor's pluggable transport client (obfs4, webtunnel,
# snowflake, meek), from pinned source for bundling with Conest.
#
#   tool/build_lyrebird.sh linux-x64 build/linux/x64/release/bundle/lyrebird
#   tool/build_lyrebird.sh windows-x64 build/windows/x64/runner/Release/lyrebird.exe
#   tool/build_lyrebird.sh android-arm64 build/app/lyrebirdJniLibs/arm64-v8a/liblyrebird.so
#
# Android needs ANDROID_NDK_HOME: Go links Android programs with the NDK.
set -euo pipefail

VERSION=lyrebird-0.8.1
COMMIT=0b10edbb61e0ca6fb70c7d57aeaabf315f1fade1
REPOSITORY=https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird.git

target=$1
output=$(realpath -m "$2")
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

# The same commit through the Go module proxy, checked against Go's
# checksum database and this hash, for when gitlab.torproject.org is down.
MODULE=gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird
MODULE_VERSION=v0.0.0-20260115133752-0b10edbb61e0
MODULE_SUM=h1:l15DHGpOwsY5auqBcLjmHxUvm7EV3bhRbPVsiu40Hsw=

cloned=false
for delay in 0 20 60; do
  sleep "$delay"
  rm -rf "$work/lyrebird"
  if git clone --quiet --depth 1 --branch "$VERSION" "$REPOSITORY" \
    "$work/lyrebird"; then
    cloned=true
    break
  fi
done
if $cloned; then
  actual=$(git -C "$work/lyrebird" rev-parse HEAD)
  if [ "$actual" != "$COMMIT" ]; then
    echo "lyrebird $VERSION is $actual, expected $COMMIT" >&2
    exit 1
  fi
else
  echo "gitlab.torproject.org unreachable; using the Go module proxy" >&2
  download=$(cd "$work" && GOFLAGS=-mod=mod GOPATH="$work/gopath" \
    go mod download -json "$MODULE@$MODULE_VERSION")
  sum=$(printf '%s' "$download" | sed -n 's/^\t"Sum": "\(.*\)",$/\1/p')
  if [ "$sum" != "$MODULE_SUM" ]; then
    echo "lyrebird module sum is '$sum', expected $MODULE_SUM" >&2
    exit 1
  fi
  cp -r "$work/gopath/pkg/mod/$MODULE@$MODULE_VERSION" "$work/lyrebird"
  chmod -R u+w "$work/lyrebird" "$work/gopath"
fi

export CGO_ENABLED=0
ldflags='-s -w -buildid='
case "$target" in
  linux-x64) export GOOS=linux GOARCH=amd64 ;;
  windows-x64) export GOOS=windows GOARCH=amd64 ;;
  android-arm64)
    toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    export GOOS=android GOARCH=arm64 CGO_ENABLED=1 \
      CC="$toolchain/aarch64-linux-android24-clang"
    # snowflake's Android network-interface helper (wlynxg/anet) links to
    # a Go-internal symbol, which Go 1.23+ only allows with this flag.
    ldflags="$ldflags -checklinkname=0"
    ;;
  *)
    echo "unknown target $target" >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$output")"
(cd "$work/lyrebird" &&
  go build -trimpath -buildvcs=false -ldflags="$ldflags" \
    -o "$output" ./cmd/lyrebird)
echo "Built $VERSION for $target at $output"

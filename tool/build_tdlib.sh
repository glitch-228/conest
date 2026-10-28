#!/usr/bin/env bash
# Builds TDLib's JSON library (libtdjson) from pinned source for the
# Telegram client (M30). Used on Linux; Android and Windows follow once
# their OpenSSL toolchains are set up in CI.
#
#   tool/build_tdlib.sh linux-x64 build/linux/x64/profile/bundle/lib/libtdjson.so
#
# Needs: cmake, gperf, zlib and OpenSSL development files, a C++17 compiler.
set -euo pipefail

VERSION=1.8.69
COMMIT=4c6377aa7386c39217878a9a56d581922ad37ca4
REPOSITORY=https://github.com/tdlib/td.git

target=$1
output=$(realpath -m "$2")

cache_dir=${CONEST_TDLIB_CACHE:-$HOME/.cache/conest-tdlib}
cached="$cache_dir/$target-$COMMIT"
# A cached build is used only if it still matches the hash written when it
# was built (a poisoned or damaged cache entry is rebuilt, not shipped).
if [ -s "$cached" ] && [ -s "$cached.sha256" ] &&
  (cd "$cache_dir" && sha256sum --check --status "$(basename "$cached").sha256"); then
  mkdir -p "$(dirname "$output")"
  cp "$cached" "$output"
  echo "Reused TDLib $VERSION for $target from $cached"
  exit 0
fi
case "$target" in
  linux-x64) ;;
  *) echo "unknown target $target" >&2; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init --quiet "$work/td"
git -C "$work/td" fetch --quiet --depth 1 "$REPOSITORY" "$COMMIT"
git -C "$work/td" checkout --quiet FETCH_HEAD
actual=$(git -C "$work/td" rev-parse HEAD)
if [ "$actual" != "$COMMIT" ]; then
  echo "TDLib is $actual, expected $COMMIT" >&2
  exit 1
fi
cmake -S "$work/td" -B "$work/build" -DCMAKE_BUILD_TYPE=Release \
  -DTD_ENABLE_LTO=OFF > /dev/null
cmake --build "$work/build" --target tdjson -j"$(nproc)"
mkdir -p "$(dirname "$output")" "$cache_dir"
cp "$work/build/libtdjson.so" "$output"
strip --strip-unneeded "$output" || true
cp "$output" "$cached"
(cd "$cache_dir" && sha256sum "$(basename "$cached")" > "$(basename "$cached").sha256")
echo "Built TDLib $VERSION for $target at $output"

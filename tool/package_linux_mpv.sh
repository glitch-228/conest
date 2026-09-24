#!/usr/bin/env bash
set -euo pipefail

bundle="${1:?usage: package_linux_mpv.sh <bundle-directory>}"
mpv_path="$(command -v mpv)"
mkdir -p "$bundle/bin" "$bundle/lib/mpv-runtime" "$bundle/share/licenses/mpv"
install -m 755 "$mpv_path" "$bundle/bin/mpv"

# Bundle mpv's direct shared-library requirements. Core glibc and the ELF
# loader stay supplied by the user's Linux system; every codec/audio/helper
# dependency reported by ldd is shipped beside the application.
ldd "$mpv_path" | awk '/=> \/[^ ]+/ {print $3} /^\// {print $1}' | sort -u |
while IFS= read -r dependency; do
  [[ -f "$dependency" ]] || continue
  name="$(basename "$dependency")"
  case "$name" in
    libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*|libnss_*.so.*|ld-linux*.so.*|linux-vdso.so.*)
      continue
      ;;
  esac
  install -m 755 "$dependency" "$bundle/lib/mpv-runtime/$name"
done

copyright_file="/usr/share/doc/mpv/copyright"
if [[ -f "$copyright_file" ]]; then
  install -m 644 "$copyright_file" "$bundle/share/licenses/mpv/copyright"
fi

if ldd "$bundle/bin/mpv" | grep -q 'not found'; then
  echo "mpv has unbundled shared-library dependencies" >&2
  exit 1
fi

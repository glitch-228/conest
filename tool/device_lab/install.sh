#!/usr/bin/env bash
# Installs one CI debug run's builds on the lab devices, each with fresh lab
# data: the Android debug app (adb), the Linux bundle at $LAB/linux and the
# Windows bundle at %USERPROFILE%\conest-lab (ssh). The user's own Conest
# apps are other packages and folders, and are not touched.
#
#   SSHPASS=… WINDOWS=user@host [ANDROID_SERIAL=…] [LAB=~/conest-lab] \
#     tool/device_lab/install.sh RUN_ID
set -euo pipefail

run=${1:?the CI debug run id}
: "${WINDOWS:?user@host of the Windows PC}"
: "${SSHPASS:?the Windows password, in the environment only}"
LAB=${LAB:-$HOME/conest-lab}
PACKAGE=${PACKAGE:-dev.conest.conest.debug}
number=$(gh run view "$run" --json number --jq .number)
art=$LAB/art
rm -rf "$art" && mkdir -p "$art"

win() { sshpass -e ssh -o StrictHostKeyChecking=accept-new "$WINDOWS" "$@" 2>/dev/null; }

gh run download "$run" -n "conest-debug-linux-x64-$number" -D "$art/linux"
rm -rf "$LAB/linux" && mkdir -p "$LAB/linux"
(cd "$LAB/linux" && unzip -q "$art"/linux/*.zip)
echo "Linux: build $number"

gh run download "$run" -n "conest-debug-windows-x64-$number" -D "$art/windows"
win 'if exist conest-lab\conest-debug-windows-x64 rmdir /S /Q conest-lab\conest-debug-windows-x64' || true
sshpass -e scp -q "$art/windows/conest-debug-windows-x64-$number.zip" "${WINDOWS}:conest-lab/"
win "powershell -NoProfile -Command \"\$ProgressPreference='SilentlyContinue'; Expand-Archive -Force -Path \$env:USERPROFILE\\conest-lab\\conest-debug-windows-x64-$number.zip -DestinationPath \$env:USERPROFILE\\conest-lab; Remove-Item \$env:USERPROFILE\\conest-lab\\conest-debug-windows-x64-$number.zip\""
echo "Windows: build $number"

gh run download "$run" -n "conest-debug-android-arm64-$number" -D "$art/android"
adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
adb install "$art/android/conest-debug-android-arm64-$number.apk" >/dev/null
echo "Android: build $number"
# A second phone (ANDROID2=serial), when the lab has one.
if [ -n "${ANDROID2:-}" ]; then
  adb -s "$ANDROID2" uninstall "$PACKAGE" >/dev/null 2>&1 || true
  adb -s "$ANDROID2" install "$art/android/conest-debug-android-arm64-$number.apk" >/dev/null
  echo "Android 2: build $number"
fi
rm -rf "$art"

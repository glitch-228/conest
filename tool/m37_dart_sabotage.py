"""Behavioral negative checks for desktop BLE, using Flutter tests only."""
from pathlib import Path
import os
import shutil
import subprocess

sdk = Path.home() / ".local/share/flutter-sdk/bin/flutter"
flutter = str(sdk) if sdk.exists() else shutil.which("flutter")
assert flutter, "Flutter SDK required"


def check(path, before, after, name, controller=False):
    original = path.read_text()
    assert original.count(before) == 1, f"Sabotage anchor changed: {before}"
    try:
        path.write_text(original.replace(before, after))
        file = "test/messenger_controller_test.dart" if controller else "test/desktop_bitchat_links_test.dart"
        result = subprocess.run(
            [flutter, "test", "--no-pub", "--reporter", "expanded", file,
             "--plain-name", name], capture_output=True, text=True)
        assert result.returncode != 0 and "[E]" in result.stdout and "Compilation failed" not in result.stdout, (
            f"Test did not detect sabotage: {name}\n{result.stdout}\n{result.stderr}")
        print(f"PASS negative check: {name}", flush=True)
    finally:
        path.write_text(original)


links = Path("lib/src/bitchat/desktop_links.dart")
check(links, "_received.add((link, bytes));", "// Sabotage: drop native packets.",
      "native packets, link snapshots and problem recovery reach Dart")
check(links, "..addAll(nextLimits);", "..addAll(<String, int>{});",
      "native packets, link snapshots and problem recovery reach Dart")
check(links, "if (problem != _problem || oldSummary != adapterSummary)", "if (false)",
      "native packets, link snapshots and problem recovery reach Dart")
check(links, "!_native.sendTo(link, packet)", "false",
      "send and broadcast preserve bytes and the excluded link")
check(links, "_native.broadcast(packet, except: except)", "_native.broadcast(packet)",
      "send and broadcast preserve bytes and the excluded link")
check(links, "if (listener.isPaused)", "if (false)",
      "paused consumers cannot accumulate radio packets")
check(links, "_closing ??= _close()", "_close()",
      "close is idempotent and does not wait for paused streams")
check(Path("lib/src/bitchat/platform_links.dart"),
      "(openDesktop ?? DesktopBitchatLinks.start)()",
      "(openAndroid ?? AndroidBitchatLinks.start)()",
      "Linux and Windows select the desktop connector")
# The group test must prove forwarding, not delivery through the relay server.
check(links, "_native.broadcast(packet, except: except)", "0",
      "group members who are not contacts talk through a desktop mesh relay", True)

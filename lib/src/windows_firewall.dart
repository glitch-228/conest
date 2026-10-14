/// Windows Firewall: an inbound rule so contacts on the same network (a
/// phone's hotspot, say, which Windows treats as public) can reach this PC.
/// Without it messages and files went one way only.
library;

import 'dart:io';

abstract final class WindowsFirewall {
  static const String ruleName = 'Conest';

  /// The PowerShell command that asks for administrator rights once and
  /// replaces Conest's inbound rule for [executable], on every network.
  static String command(String executable) {
    final program = executable.replaceAll('"', '');
    final netsh =
        '/c netsh advfirewall firewall delete rule name=$ruleName & '
        'netsh advfirewall firewall add rule name=$ruleName dir=in '
        'action=allow program="$program" enable=yes profile=any';
    // A single-quoted PowerShell string: quotes inside are doubled,
    // including the typographic ones PowerShell also treats as quotes.
    final argument = netsh.replaceAllMapped(
      RegExp("['\u2018\u2019\u201A\u201B]"),
      (match) => '${match[0]}${match[0]}',
    );
    return "Start-Process -FilePath cmd -Verb RunAs -Wait -WindowStyle Hidden "
        "-ArgumentList '$argument'";
  }

  /// Adds the rule (Windows asks the user to confirm). True when it ran;
  /// false when the user declined or it failed.
  static Future<bool> allowIncoming({String? executable}) async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        command(executable ?? Platform.resolvedExecutable),
      ]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}

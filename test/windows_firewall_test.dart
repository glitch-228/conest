import 'package:conest/src/windows_firewall.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the firewall command replaces one rule for the app, once elevated', () {
    final command = WindowsFirewall.command(
      r"C:\Users\O'Neil\Apps\conest\conest.exe",
    );
    expect(command, startsWith('Start-Process -FilePath cmd -Verb RunAs'));
    // One elevation: delete and add in the same cmd.
    expect(
      command,
      contains('delete rule name=Conest & netsh advfirewall firewall add rule'),
    );
    expect(
      command,
      contains('program="C:\\Users\\O\'\'Neil\\Apps\\conest\\conest.exe"'),
    );
    expect(command, contains('profile=any'));
  });

  test('typographic quotes in the path are doubled too', () {
    // PowerShell ends a single-quoted string at ’ as well as at '.
    final command = WindowsFirewall.command(
      'C:\\Users\\O\u2019Brien\\conest.exe',
    );
    expect(command, contains('O\u2019\u2019Brien'));
    final quoted = command.substring(command.indexOf("-ArgumentList '") + 15);
    // The argument closes only at its end.
    expect(
      RegExp(
        "(?<!['\u2018\u2019\u201A\u201B])['\u2018\u2019\u201A\u201B](?!['\u2018\u2019\u201A\u201B])",
      ).allMatches(quoted).length,
      1,
    );
  });
}

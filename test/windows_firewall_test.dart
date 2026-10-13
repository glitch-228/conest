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
}

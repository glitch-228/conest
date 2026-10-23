import 'dart:io';

import 'package:conest/src/desktop_autostart.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake `reg`: a Run key of one value, and the calls made.
class _FakeRegistry {
  String? value;
  final calls = <List<String>>[];

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    expect(executable, 'reg');
    calls.add(arguments);
    switch (arguments.first) {
      case 'add':
        value = arguments[arguments.indexOf('/d') + 1];
        return ProcessResult(0, 0, '', '');
      case 'query':
        if (value == null) return ProcessResult(0, 1, '', 'not found');
        return ProcessResult(0, 0, '    Conest    REG_SZ    $value\r\n', '');
      case 'delete':
        value = null;
        return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 1, '', '');
  }
}

void main() {
  test('Linux: an autostart entry that starts this Conest hidden', () async {
    final folder = await Directory.systemTemp.createTemp('conest_autostart_');
    addTearDown(() => folder.delete(recursive: true));
    final autostart = DesktopAutostart(
      executable: r'/opt/My Apps/conest $1/conest',
      linuxAutostartDirectory: folder,
      windows: false,
    );
    await autostart.apply(true);
    final entry = await File('${folder.path}/conest.desktop').readAsString();
    // Quoted and escaped as desktop entries want it.
    expect(entry, contains(r'Exec="/opt/My Apps/conest \$1/conest" --hidden'));
    expect(entry, contains('Type=Application'));
    await autostart.apply(false);
    expect(await File('${folder.path}/conest.desktop').exists(), isFalse);
  });

  test('Linux: off leaves another Conest\'s entry alone', () async {
    final folder = await Directory.systemTemp.createTemp('conest_autostart_');
    addTearDown(() => folder.delete(recursive: true));
    await DesktopAutostart(
      executable: '/home/me/Documents/conest-linux/conest',
      linuxAutostartDirectory: folder,
      windows: false,
    ).apply(true);
    // The lab's Conest, its setting off, starts.
    await DesktopAutostart(
      executable: '/home/me/conest-lab/linux/conest',
      linuxAutostartDirectory: folder,
      windows: false,
    ).apply(false);
    expect(
      await File('${folder.path}/conest.desktop').readAsString(),
      contains('/home/me/Documents/conest-linux/conest'),
    );
  });

  test(
    'Windows: the Run key starts this Conest; off removes only its own',
    () async {
      final registry = _FakeRegistry();
      final mine = DesktopAutostart(
        executable: r'C:\Users\me\conest\conest.exe',
        run: registry.run,
        windows: true,
      );
      await mine.apply(true);
      expect(registry.value, r'"C:\Users\me\conest\conest.exe" --hidden');
      expect(
        registry.calls.single,
        containsAllInOrder(['add', '/v', 'Conest']),
      );

      // Another copy (the lab's) with the setting off: not its entry.
      await DesktopAutostart(
        executable: r'C:\Users\me\conest-lab\conest.exe',
        run: registry.run,
        windows: true,
      ).apply(false);
      expect(registry.value, r'"C:\Users\me\conest\conest.exe" --hidden');

      await mine.apply(false);
      expect(registry.value, isNull);
    },
  );
}

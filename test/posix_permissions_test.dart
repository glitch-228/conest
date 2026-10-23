import 'dart:io';

import 'package:conest/src/posix_permissions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final skip = Platform.isLinux || Platform.isMacOS ? null : 'POSIX only';

  test('a file is made owner-only without starting chmod', () async {
    final folder = await Directory.systemTemp.createTemp('conest_mode_');
    addTearDown(() => folder.delete(recursive: true));
    final file = File('${folder.path}/vault.json')..writeAsStringSync('{}');
    await Process.run('chmod', ['644', file.path]);
    expect(chmodCallAvailable, isTrue);
    final result = await setPosixMode(file.path, ownerReadWrite);
    expect(result.exitCode, 0);
    expect((await file.stat()).mode & 0x1ff, 0x180);
  }, skip: skip);

  test('a refused change still says why', () async {
    final result = await setPosixMode('/no/such/conest/file', ownerReadWrite);
    expect(result.exitCode, isNot(0));
    expect('${result.stderr}', isNotEmpty);
  }, skip: skip);
}

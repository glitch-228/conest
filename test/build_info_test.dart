import 'package:conest/src/build_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stable, nightly, and debug are distinct build channels', () {
    expect(UpdateChannel.parse('stable'), UpdateChannel.stable);
    expect(UpdateChannel.parse('nightly'), UpdateChannel.nightly);
    expect(UpdateChannel.parse('debug'), UpdateChannel.debug);
  });

  test('canary is a fourth channel; unknown values stay stable', () {
    expect(UpdateChannel.parse('canary'), UpdateChannel.canary);
    expect(UpdateChannel.parse(' Canary '), UpdateChannel.canary);
    expect(UpdateChannel.parse('beta'), UpdateChannel.nightly);
    expect(UpdateChannel.parse('canaries'), UpdateChannel.stable);
    expect(UpdateChannel.parse(null), UpdateChannel.stable);
    expect(UpdateChannel.canary.label, 'canary');
    // Persisted by name or index elsewhere: canary is appended.
    expect(UpdateChannel.values.last, UpdateChannel.canary);
    expect(UpdateChannel.values.indexOf(UpdateChannel.debug), 2);
  });

  test('canaryFeatures is on only for canary and debug builds', () {
    ConestBuildInfo build(UpdateChannel channel) => ConestBuildInfo(
      appName: 'Conest',
      packageName: 'dev.conest.conest',
      version: '0.4.3',
      buildNumber: '1',
      channel: channel,
      isDebugBuild: false,
    );
    expect(build(UpdateChannel.canary).canaryFeatures, isTrue);
    expect(build(UpdateChannel.debug).canaryFeatures, isTrue);
    expect(build(UpdateChannel.nightly).canaryFeatures, isFalse);
    expect(build(UpdateChannel.stable).canaryFeatures, isFalse);
    expect(build(UpdateChannel.canary).debugProtocolId, isNull);
  });

  test('only debug builds expose an exact battle-test protocol id', () {
    final debug = ConestBuildInfo(
      appName: 'Conest Debug',
      packageName: 'dev.conest.conest.debug',
      version: '0.3.7',
      buildNumber: '33',
      channel: UpdateChannel.debug,
      isDebugBuild: true,
      buildTag: 'debug-42',
      commit: 'abc123',
    );
    final nightly = ConestBuildInfo(
      appName: 'Conest',
      packageName: 'dev.conest.conest',
      version: '0.3.7',
      buildNumber: '33',
      channel: UpdateChannel.nightly,
      isDebugBuild: false,
    );

    expect(debug.debugProtocolId, 'debug-42@abc123');
    expect(nightly.debugProtocolId, isNull);
  });

  test('unidentified local debug builds cannot auto-accept file tests', () {
    final local = ConestBuildInfo(
      appName: 'Conest Debug',
      packageName: 'dev.conest.conest.debug',
      version: '0.3.7',
      buildNumber: '33',
      channel: UpdateChannel.debug,
      isDebugBuild: true,
    );

    expect(local.debugProtocolId, isNull);
  });
}

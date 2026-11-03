import 'dart:io';

/// The manifest file names of a channel. Canary releases carry their own
/// pair, so readers of the standard names (relay supervisors, the install
/// script, older apps) never see a canary manifest.
({String manifest, String signature}) manifestNamesFor(String channel) =>
    channel == 'canary'
    ? (
        manifest: 'RELEASE-MANIFEST.canary.json',
        signature: 'RELEASE-MANIFEST.canary.ed25519.sig',
      )
    : (
        manifest: 'RELEASE-MANIFEST.json',
        signature: 'RELEASE-MANIFEST.ed25519.sig',
      );

const releaseChannels = {'stable', 'nightly', 'canary'};

/// The names of every manifest file a release may hold, for telling
/// metadata from assets.
List<String> allManifestNames() => [
  for (final channel in ['stable', 'canary']) ...[
    manifestNamesFor(channel).manifest,
    manifestNamesFor(channel).signature,
  ],
];

/// What `tool/release_channel.sh` says about [tag]: the one rule that maps a
/// tag to a channel. Null (with a message on stderr) when it refuses.
Future<Map<String, String>?> classifyTag(String tag) async {
  final script = File.fromUri(
    Platform.script.resolve('release_channel.sh'),
  ).path;
  final result = await Process.run('bash', [script, '--classify-only', tag]);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    return null;
  }
  return {
    for (final line in (result.stdout as String).split('\n'))
      if (line.contains('='))
        line.substring(0, line.indexOf('=')): line.substring(
          line.indexOf('=') + 1,
        ),
  };
}

/// Exits unless [channel] is exactly the tag's own channel.
Future<void> requireChannelOfTag(String channel, String tag) async {
  if (!releaseChannels.contains(channel)) {
    stderr.writeln('--channel must be stable, nightly or canary.');
    exit(2);
  }
  final classified = await classifyTag(tag);
  if (classified == null) exit(2);
  if (classified['channel'] != channel) {
    stderr.writeln(
      'Tag $tag is a ${classified['channel']} release, not $channel.',
    );
    exit(2);
  }
}

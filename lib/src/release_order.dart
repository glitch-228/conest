/// Which release lines exist and how releases are ordered, without any I/O.
///
/// Semver alone cannot order a canary against a nightly (`-canary.*` sorts
/// below `-nightly.*` of the same core), so releases of different lines are
/// compared by one lexicographic key:
///
///     (major.minor.patch, isStable, date, lineRank, n)
///
/// where `n` only matters within one line, never across lines. Within one
/// line this is the same order as semver.
library;

import 'package:pub_semver/pub_semver.dart';

import 'build_info.dart';

/// The lines releases are published on. The rank is the index: canary is
/// the newest line, stable the most settled.
enum ReleaseLine {
  stable,
  nightly,
  canary;

  int get rank => index;

  /// The line a build of [channel] belongs to; debug builds have none.
  static ReleaseLine? ofChannel(UpdateChannel channel) => switch (channel) {
    UpdateChannel.stable => ReleaseLine.stable,
    UpdateChannel.nightly => ReleaseLine.nightly,
    UpdateChannel.canary => ReleaseLine.canary,
    UpdateChannel.debug => null,
  };

  /// The lines a user following this line is offered: a newer line also
  /// takes the releases of the lines before it, an older one never takes
  /// the newer.
  Set<ReleaseLine> get offered => {
    for (final line in ReleaseLine.values)
      if (line.rank <= rank) line,
  };
}

/// A release tag that has been understood.
class ReleaseId implements Comparable<ReleaseId> {
  const ReleaseId._({
    required this.line,
    required this.version,
    required this.date,
    required this.n,
  });

  final ReleaseLine line;
  final Version version;

  /// `YYYYMMDD` of a dated nightly or canary, else 0 (stable, old nightly).
  final int date;

  /// The counter of a dated tag (`.N`), else 0.
  final int n;

  bool get isStable => line == ReleaseLine.stable;

  @override
  int compareTo(ReleaseId other) {
    final core = _compareCore(version, other.version);
    if (core != 0) return core;
    if (isStable != other.isStable) return isStable ? 1 : -1;
    if (isStable) return 0;
    if (line == other.line) return version.compareTo(other.version);
    final byDate = date.compareTo(other.date);
    if (byDate != 0) return byDate;
    return line.rank.compareTo(other.line.rank);
  }

  @override
  String toString() => 'ReleaseId($line $version)';
}

int _compareCore(Version a, Version b) {
  final major = a.major.compareTo(b.major);
  if (major != 0) return major;
  final minor = a.minor.compareTo(b.minor);
  if (minor != 0) return minor;
  return a.patch.compareTo(b.patch);
}

final RegExp _canaryTag = RegExp(
  r'^v(\d+)\.(\d+)\.(\d+)-canary\.(\d{8})\.(\d+)$',
);

/// Whether [yyyymmdd] is a real calendar date from 2026 on.
bool isValidReleaseDate(int yyyymmdd) {
  if (yyyymmdd < 20260101 || yyyymmdd > 99991231) return false;
  final year = yyyymmdd ~/ 10000;
  final month = yyyymmdd ~/ 100 % 100;
  final day = yyyymmdd % 100;
  final parsed = DateTime.utc(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day;
}

String _stripV(String value) {
  final trimmed = value.trim();
  return trimmed.startsWith('v') || trimmed.startsWith('V')
      ? trimmed.substring(1)
      : trimmed;
}

/// Understands [tag]; null for anything that is not a stable, nightly or
/// canary release of this project (rc, beta, garbage, a tag that disagrees
/// with the [prerelease] flag GitHub carries, a canary that does not match
/// the exact format). [prerelease] null skips the flag check, for the
/// identity of an installed build.
ReleaseId? classifyRelease(String tag, {bool? prerelease}) {
  final trimmed = tag.trim();
  if (trimmed.length > 128) return null;
  if (trimmed.toLowerCase().contains('canary')) {
    if (prerelease == false) return null;
    final match = _canaryTag.firstMatch(trimmed);
    if (match == null) return null;
    final date = int.parse(match.group(4)!);
    final n = int.tryParse(match.group(5)!);
    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = int.tryParse(match.group(3)!);
    if (!isValidReleaseDate(date) ||
        n == null ||
        major == null ||
        minor == null ||
        patch == null) {
      return null;
    }
    return ReleaseId._(
      line: ReleaseLine.canary,
      version: Version(major, minor, patch, pre: 'canary.$date.$n'),
      date: date,
      n: n,
    );
  }
  final Version version;
  try {
    version = Version.parse(_stripV(trimmed).toLowerCase());
  } catch (_) {
    return null;
  }
  if (version.isPreRelease) {
    if (prerelease == false) return null;
    final pre = version.preRelease;
    if (pre.first != 'nightly' || pre.length > 3) return null;
    // Counters only: a word would sort above every number in semver but
    // below every canary by date.
    if (pre.skip(1).any((part) => part is! int)) return null;
    var date = 0;
    var n = 0;
    if (pre.length >= 2) {
      final first = pre[1] as int;
      if (first >= 10000000) {
        if (!isValidReleaseDate(first)) return null;
        date = first;
        if (pre.length == 3) n = pre[2] as int;
      } else if (pre.length == 3) {
        return null;
      }
    }
    return ReleaseId._(
      line: ReleaseLine.nightly,
      version: version,
      date: date,
      n: n,
    );
  }
  if (prerelease == true) return null;
  if (version.build.isNotEmpty) return null;
  return ReleaseId._(line: ReleaseLine.stable, version: version, date: 0, n: 0);
}

/// One release as the list on GitHub names it.
class ReleaseCandidate {
  const ReleaseCandidate({
    required this.tagName,
    required this.prerelease,
    required this.draft,
  });

  final String tagName;
  final bool prerelease;
  final bool draft;
}

/// The newest of [releases] that a user following [followed] is offered,
/// with its understood identity. Null when none qualifies.
(T, ReleaseId)? chooseRelease<T>(
  Iterable<T> releases,
  ReleaseLine followed, {
  required ReleaseCandidate Function(T release) describe,
}) {
  final allowed = followed.offered;
  (T, ReleaseId)? best;
  for (final release in releases) {
    final info = describe(release);
    if (info.draft) continue;
    final id = classifyRelease(info.tagName, prerelease: info.prerelease);
    if (id == null || !allowed.contains(id.line)) continue;
    if (best == null || id.compareTo(best.$2) > 0) best = (release, id);
  }
  return best;
}

/// Whether [candidate] is strictly newer than the installed [identity]
/// (its tag, or its version without a tag). Never for an identity that is
/// not understood: no guessing, no downgrade.
bool isNewerThanInstalled(ReleaseId candidate, String identity) {
  final installed = classifyRelease(identity);
  if (installed == null) return false;
  return candidate.compareTo(installed) > 0;
}

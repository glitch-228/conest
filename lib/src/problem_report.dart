/// "Report a problem": one text file the user can read, then copy or save.
///
/// It holds the version, build, channel and platform; whether each
/// transport is ready (never its address); the crash records; and the first
/// line of each error in the error history. It never holds message text,
/// keys, contact names or addresses, and nothing here touches the network:
/// the user decides where the text goes.
///
/// What stays out is decided twice. At the source, the error history is fed
/// by code that avoids interpolating message content (see the audit in the
/// canary handoff). Here, every free-text line is cut to its first line
/// (error history), capped, and passed through [redactReportText], which
/// replaces the names and servers the controller lists in the deny-list and
/// anything shaped like a token, address, id or private path. Redaction is
/// a net, not the guarantee: the user reads the preview before sharing.
library;

import 'dart:isolate';

/// One transport and whether it is working; deliberately nothing else.
class ReportTransportLine {
  const ReportTransportLine(this.name, this.state);

  /// A transport kind (`tor`, `matrix`, ...), a fixed word.
  final String name;

  /// `ready`, `not ready` or `error`: a fixed word, never the error text.
  final String state;
}

/// A crash record (full text, stack included; crashes are the one place a
/// stack is wanted).
class ReportCrash {
  const ReportCrash(this.at, this.kind, this.text);

  final DateTime at;
  final String kind;
  final String text;
}

/// An error-history entry (only its first line is used).
class ReportError {
  const ReportError(this.at, this.kind, this.text);

  final DateTime at;
  final String kind;
  final String text;
}

/// Everything the report is made of, as plain data (it is built off the main
/// isolate).
class ProblemReportInputs {
  const ProblemReportInputs({
    required this.generatedAt,
    required this.appVersion,
    required this.buildNumber,
    required this.channel,
    required this.updateChannel,
    required this.platform,
    this.buildTag,
    this.commit,
    this.transports = const [],
    this.transportsAvailable = true,
    this.crashes = const [],
    this.errors = const [],
    this.errorHistoryAvailable = true,
    this.denyList = const [],
  });

  final DateTime generatedAt;
  final String appVersion;
  final String buildNumber;
  final String? buildTag;
  final String? commit;
  final String channel;
  final String updateChannel;
  final String platform;
  final List<ReportTransportLine> transports;

  /// False while the vault is locked (the crash notice at start).
  final bool transportsAvailable;
  final List<ReportCrash> crashes;
  final List<ReportError> errors;

  /// False on stable builds (no error history) or while locked.
  final bool errorHistoryAvailable;

  /// Names and hosts to replace wherever they occur: contact and group
  /// names, the user's own name, account ids, configured servers and relay
  /// hosts, account emails.
  final List<String> denyList;
}

/// Limits of the report.
class ProblemReportLimits {
  static const int crashEntryChars = 2000;
  static const int errorEntryChars = 1000;
  static const int totalChars = 256 * 1024;
  static const int maxCrashes = 64;
  static const int maxErrors = 400;
  static const int maxDenyEntries = 2000;
  static const int maxDenyChars = 120;
}

/// Kinds that the crash catcher forwards to the error history; they are
/// shown with the crash records.
const Set<String> _crashKinds = {
  'flutter',
  'uncaught',
  'zone',
  'isolate',
  'native',
  'android',
  'exit',
};

final RegExp _frameLine = RegExp(
  r'^\s*(?:#\d+\s|\d+:\s|at\s|(?:package|dart|file):)',
);

/// A crash record keeps its first line and its stack frames. Any other
/// line may be an excerpt of what failed (a `FormatException` prints the
/// source it could not parse under its message).
String _crashShape(String text) {
  final lines = text.split('\n');
  return [
    lines.first,
    for (final line in lines.skip(1))
      if (_frameLine.hasMatch(line)) line,
  ].join('\n');
}

String _safeWord(String value, int max) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  return cleaned.length <= max ? cleaned : cleaned.substring(0, max);
}

/// Builds the report text. Pure and synchronous; for long inputs use
/// [buildProblemReportOffMain].
String buildProblemReport(ProblemReportInputs inputs) {
  final redactor = _Redactor(inputs.denyList);
  String clean(String text, int max) {
    final cut = text.length <= max ? text : '${text.substring(0, max)}…';
    return redactor.apply(cut);
  }

  final header = StringBuffer()
    ..writeln('Conest problem report')
    ..writeln('Generated: ${inputs.generatedAt.toUtc().toIso8601String()}')
    ..writeln(
      'Version: ${_safeWord(inputs.appVersion, 40)} '
      '(build ${_safeWord(inputs.buildNumber, 20)})',
    );
  if (inputs.buildTag != null) {
    header.writeln('Tag: ${_safeWord(inputs.buildTag!, 80)}');
  }
  if (inputs.commit != null) {
    header.writeln('Commit: ${_safeWord(inputs.commit!, 64)}');
  }
  header
    ..writeln('Channel: ${_safeWord(inputs.channel, 20)}')
    ..writeln('Update channel followed: ${_safeWord(inputs.updateChannel, 20)}')
    ..writeln('Platform: ${redactor.apply(inputs.platform)}')
    ..writeln()
    ..writeln(
      'Read this before you send it. It holds no messages and no keys, and '
      'names are replaced, but an error line may still mention something '
      'this could not recognise. Nothing was sent anywhere.',
    )
    ..writeln();

  final transports = StringBuffer('== Transports ==\n');
  if (!inputs.transportsAvailable) {
    transports.writeln('Not available until Conest is unlocked.');
  } else if (inputs.transports.isEmpty) {
    transports.writeln('None running.');
  } else {
    for (final line in inputs.transports) {
      transports.writeln(
        '${_safeWord(line.name, 24)}: ${_safeWord(line.state, 12)}',
      );
    }
  }

  // Newest entries win when the report is too big.
  final crashes = inputs.crashes.length > ProblemReportLimits.maxCrashes
      ? inputs.crashes.sublist(
          inputs.crashes.length - ProblemReportLimits.maxCrashes,
        )
      : inputs.crashes;
  final crashBlocks = <String>[
    for (final crash in crashes)
      '${crash.at.toUtc().toIso8601String()} [${_safeWord(crash.kind, 16)}] '
          '${clean(_crashShape(crash.text), ProblemReportLimits.crashEntryChars)}',
  ];

  final errorLines = <String>[];
  if (inputs.errorHistoryAvailable) {
    for (final error in inputs.errors.reversed) {
      if (errorLines.length >= ProblemReportLimits.maxErrors) break;
      if (error.kind == 'log' || _crashKinds.contains(error.kind)) continue;
      final firstLine = error.text.split('\n').first.trim();
      if (firstLine.isEmpty) continue;
      errorLines.add(
        '${error.at.toUtc().toIso8601String()} [${_safeWord(error.kind, 16)}] '
        '${clean(firstLine, ProblemReportLimits.errorEntryChars)}',
      );
    }
  }

  String assemble(List<String> crashParts, List<String> errorParts) {
    final out = StringBuffer(header)
      ..write(transports)
      ..writeln()
      ..writeln('== Crash records ==');
    if (crashParts.isEmpty) out.writeln('None.');
    for (final part in crashParts) {
      out
        ..writeln(part)
        ..writeln();
    }
    out.writeln('== Error history ==');
    if (!inputs.errorHistoryAvailable) {
      out.writeln('Not available (not kept on this build, or locked).');
    } else if (errorParts.isEmpty) {
      out.writeln('Nothing recorded.');
    }
    // errorParts is newest first; the file reads oldest first.
    for (final part in errorParts.reversed) {
      out.writeln(part);
    }
    return out.toString();
  }

  // Over the cap: the oldest errors go first, then the oldest crashes. The
  // header and transports always stay.
  var keptCrashes = crashBlocks;
  var keptErrors = errorLines;
  var text = assemble(keptCrashes, keptErrors);
  while (text.length > ProblemReportLimits.totalChars &&
      (keptErrors.isNotEmpty || keptCrashes.length > 1)) {
    if (keptErrors.isNotEmpty) {
      keptErrors = keptErrors.sublist(
        0,
        keptErrors.length > 8 ? keptErrors.length * 3 ~/ 4 : 0,
      );
    } else {
      keptCrashes = keptCrashes.sublist(keptCrashes.length ~/ 2);
    }
    text = assemble(keptCrashes, keptErrors);
  }
  if (text.length > ProblemReportLimits.totalChars) {
    text = '${text.substring(0, ProblemReportLimits.totalChars)}…';
  }
  return text;
}

/// [buildProblemReport] on another isolate: a big history is not parsed on
/// the main one.
Future<String> buildProblemReportOffMain(ProblemReportInputs inputs) =>
    Isolate.run(() => buildProblemReport(inputs));

/// Replaces what must not leave the device in [text]; see the library notes.
String redactReportText(String text, {List<String> denyList = const []}) =>
    _Redactor(denyList).apply(text);

class _Redactor {
  _Redactor(List<String> denyList) : _deny = _denyPattern(denyList);

  final RegExp? _deny;

  static RegExp? _denyPattern(List<String> names) {
    final seen = <String>{};
    final usable = <String>[];
    for (final raw in names) {
      final name = raw.trim();
      if (name.length < 2 || name.length > ProblemReportLimits.maxDenyChars) {
        continue;
      }
      if (seen.add(name.toLowerCase())) usable.add(name);
      if (usable.length >= ProblemReportLimits.maxDenyEntries) break;
    }
    if (usable.isEmpty) return null;
    usable.sort((a, b) => b.length.compareTo(a.length));
    return RegExp(
      '(?<![\\p{L}\\p{N}])(?:${usable.map(RegExp.escape).join('|')})'
      '(?![\\p{L}\\p{N}])',
      caseSensitive: false,
      unicode: true,
    );
  }

  // Private places: the whole path goes (a file name can name a person).
  static final _privatePath = RegExp(
    r'(?:file://)?(?:'
    r'/home/[^/\s]+|/Users/[^/\s]+|/root|[A-Za-z]:\\Users\\[^\\\s]+|'
    r'/storage/emulated/\d+|/storage/[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}|'
    r'/sdcard|/data/user/\d+/[\w.]+|/data/data/[\w.]+'
    r')(?:[/\\][^\s\x27")\]>,;]*)?',
  );
  static final _url = RegExp(
    r'\b([a-zA-Z][a-zA-Z0-9+.-]*)://(?:[^\s/@]*@)?([^\s/?#:]+)(?::\d+)?'
    r'(?:/[^\s?#\x27")\]>]*)?(?:\?[^\s\x27")\]>]*)?(?:#[^\s\x27")\]>]*)?',
  );
  static final _email = RegExp(r'(?<![\w.+-])[\w.+-]+@[\w-]+(?:\.[\w-]+)+');
  static final _matrixId = RegExp(
    r'[@!#][\w.=/+-]+:[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?::\d+)?',
  );
  static final _onion = RegExp(
    r'[a-z2-7]{16,56}\.onion\b',
    caseSensitive: false,
  );
  static final _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b');
  static final _ipv6Full = RegExp(
    r'(?<![\w:])(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(?![\w:])',
  );
  static final _ipv6Short = RegExp(
    r'(?<![\w:])\[?[0-9a-fA-F:]*::[0-9a-fA-F:.]*\]?(?::\d{1,5})?(?![\w:])',
  );
  static final _hostPort = RegExp(
    r'\b[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.(?!(?:dart|rs|kt|java|cpp|cc|so|js|ts|py)\b)[A-Za-z]{2,}:\d{2,5}\b',
  );
  static final _bearer = RegExp(
    r'\b(Bearer|Basic)\s+\S+',
    caseSensitive: false,
  );
  static final _secretField = RegExp(
    r'\b(access_token|refresh_token|token|password|passwd|secret|api[_-]?key|'
    r'authorization|private[_-]?key|seed)(["\x27]?\s*[=:]\s*["\x27]?)[^\s"\x27,;&)]+',
    caseSensitive: false,
  );
  static final _longRun = RegExp(r'[A-Za-z0-9+/_=-]{24,}');
  static final _hexRun = RegExp(r'\b[0-9a-fA-F]{32,}\b');
  static final _phone = RegExp(
    r'\+\d[\d ()-]{6,}\d|'
    r'\(\d{3}\)\s?\d{3}[-.\s]?\d{4}|'
    r'\b\d{3,4}[ .-]\d{3,4}[ .-]\d{3,4}\b',
  );
  static final _digits = RegExp(r'\b\d{9,}\b');

  String apply(String input) {
    var text = input;
    final deny = _deny;
    if (deny != null) text = text.replaceAll(deny, '[name]');
    text = text.replaceAll(_privatePath, '[path]');
    text = text.replaceAllMapped(_url, (m) {
      final host = m.group(2) ?? '';
      // An address or a hidden service is not a name worth keeping.
      return _ipv4.hasMatch(host) ||
              host.endsWith('.onion') ||
              host.contains(':')
          ? '${m.group(1)}://[host]'
          : '${m.group(1)}://$host';
    });
    text = text.replaceAll(_onion, '[onion]');
    text = text.replaceAll(_email, '[email]');
    text = text.replaceAll(_matrixId, '[matrix-id]');
    text = text.replaceAll(_bearer, r'[auth]');
    text = text.replaceAllMapped(
      _secretField,
      (m) => '${m.group(1)}${m.group(2)}[secret]',
    );
    text = text.replaceAll(_ipv4, '[ip]');
    text = text.replaceAll(_ipv6Full, '[ip]');
    text = text.replaceAll(_ipv6Short, '[ip]');
    text = text.replaceAll(_hostPort, '[host:port]');
    text = text.replaceAll(_hexRun, '[hex]');
    text = text.replaceAllMapped(_longRun, (m) {
      final run = m.group(0)!;
      final mixed =
          run.contains(RegExp(r'\d')) && run.contains(RegExp(r'[A-Za-z]'));
      return mixed || run.contains(RegExp(r'[+=]')) ? '[token]' : run;
    });
    text = text.replaceAll(_phone, '[number]');
    text = text.replaceAll(_digits, '[number]');
    return text;
  }
}

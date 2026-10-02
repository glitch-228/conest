import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Stateless Olm operations (`native/conest_native/src/ratchet.rs`). Every
/// request carries the pickles it needs and every result returns updated
/// pickles, so [RatchetSessions] alone decides when a step is committed.
abstract class RatchetEngine {
  Map<String, dynamic> call(Map<String, Object?> request);
}

class RatchetEngineException implements Exception {
  const RatchetEngineException(this.message);
  final String message;

  @override
  String toString() => 'RatchetEngineException: $message';
}

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ErrorNative = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// FFI binding to `conest_ratchet_call`. A library without the symbol (an
/// older build) yields null rather than an engine.
class NativeRatchetEngine implements RatchetEngine {
  NativeRatchetEngine._(DynamicLibrary library)
    : _call = library.lookupFunction<_CallNative, _CallNative>(
        'conest_ratchet_call',
      ),
      _lastError = library.lookupFunction<_ErrorNative, _ErrorNative>(
        'conest_last_error',
      ),
      _free = library.lookupFunction<_FreeNative, _FreeDart>(
        'conest_string_free',
      );

  final _CallNative _call;
  final _ErrorNative _lastError;
  final _FreeDart _free;

  static NativeRatchetEngine? tryCreate() {
    for (final candidate in _candidateLibraryPaths()) {
      try {
        return NativeRatchetEngine._(DynamicLibrary.open(candidate));
      } catch (_) {
        // Missing library or symbol: try the next location.
      }
    }
    return null;
  }

  @override
  Map<String, dynamic> call(Map<String, Object?> request) {
    final input = jsonEncode(request).toNativeUtf8();
    try {
      final output = _call(input);
      if (output == nullptr) throw RatchetEngineException(_takeLastError());
      try {
        return jsonDecode(output.toDartString()) as Map<String, dynamic>;
      } finally {
        _free(output);
      }
    } finally {
      // The request holds pickles and plaintext; clear it before release.
      final bytes = input.cast<Uint8>();
      var length = 0;
      while (bytes[length] != 0) {
        bytes[length++] = 0;
      }
      malloc.free(input);
    }
  }

  String _takeLastError() {
    final pointer = _lastError();
    if (pointer == nullptr) return 'Unknown ratchet error.';
    try {
      final value = pointer.toDartString();
      return value.isEmpty ? 'Unknown ratchet error.' : value;
    } finally {
      _free(pointer);
    }
  }

  static Iterable<String> _candidateLibraryPaths() sync* {
    final override = Platform.environment['CONEST_NATIVE_LIBRARY'];
    if (override != null && override.trim().isNotEmpty) {
      yield override.trim();
    }
    final name = Platform.isWindows
        ? 'conest_native.dll'
        : Platform.isMacOS
        ? 'libconest_native.dylib'
        : 'libconest_native.so';
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final executableDirectory = File(Platform.resolvedExecutable).parent.path;
      yield '$executableDirectory${Platform.pathSeparator}$name';
      yield '$executableDirectory${Platform.pathSeparator}lib${Platform.pathSeparator}$name';
    }
    yield name;
  }
}

/// A peer's published keys. Bundles travel only inside envelopes that the
/// existing static pairwise key authenticates.
class RatchetBundle {
  const RatchetBundle({
    required this.identityKey,
    required this.fallbackKey,
    this.oneTimeKey,
  });

  final String identityKey;
  final String fallbackKey;
  final String? oneTimeKey;

  /// The key an initiator should consume: the one-time key when offered.
  String get sessionKey => oneTimeKey ?? fallbackKey;

  Map<String, Object?> toJson() => {
    'version': 1,
    'identityKey': identityKey,
    'fallbackKey': fallbackKey,
    if (oneTimeKey != null) 'oneTimeKey': oneTimeKey,
  };

  static RatchetBundle fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['version'] != 1) {
      throw const FormatException('Unsupported ratchet bundle.');
    }
    final identity = json['identityKey'];
    final fallback = json['fallbackKey'];
    final oneTime = json['oneTimeKey'];
    if (!_isCurveKey(identity) ||
        !_isCurveKey(fallback) ||
        (oneTime != null && !_isCurveKey(oneTime))) {
      throw const FormatException('Invalid ratchet bundle key.');
    }
    return RatchetBundle(
      identityKey: identity as String,
      fallbackKey: fallback as String,
      oneTimeKey: oneTime as String?,
    );
  }

  // vodozemac encodes Curve25519 keys as 43 characters of unpadded base64.
  static bool _isCurveKey(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9+/]{43}$').hasMatch(value);
}

/// One Olm ciphertext: type 0 opens a session, type 1 continues one.
class RatchetMessage {
  const RatchetMessage({required this.type, required this.ciphertext});

  final int type;
  final List<int> ciphertext;

  bool get opensSession => type == 0;
}

class RatchetSessionState {
  const RatchetSessionState({
    required this.sessionId,
    required this.pickle,
    required this.createdAtMs,
    required this.lastUsedAtMs,
  });

  final String sessionId;
  final String pickle;
  final int createdAtMs;
  final int lastUsedAtMs;

  RatchetSessionState used(String pickle, int nowMs) => RatchetSessionState(
    sessionId: sessionId,
    pickle: pickle,
    createdAtMs: createdAtMs,
    lastUsedAtMs: nowMs,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'pickle': pickle,
    'createdAtMs': createdAtMs,
    'lastUsedAtMs': lastUsedAtMs,
  };

  static RatchetSessionState fromJson(Map<String, dynamic> json) =>
      RatchetSessionState(
        sessionId: json['sessionId'] as String,
        pickle: json['pickle'] as String,
        createdAtMs: json['createdAtMs'] as int,
        lastUsedAtMs: json['lastUsedAtMs'] as int,
      );
}

/// Everything stored for one peer device. Sessions are ordered most
/// recently used first.
class RatchetPeerState {
  const RatchetPeerState({this.peerIdentityKey, this.sessions = const []});

  final String? peerIdentityKey;
  final List<RatchetSessionState> sessions;

  Map<String, Object?> toJson() => {
    'version': 1,
    'peerIdentityKey': peerIdentityKey,
    'sessions': [for (final session in sessions) session.toJson()],
  };

  static RatchetPeerState fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported ratchet peer state.');
    }
    return RatchetPeerState(
      peerIdentityKey: json['peerIdentityKey'] as String?,
      sessions: [
        for (final session in json['sessions'] as List)
          RatchetSessionState.fromJson(session as Map<String, dynamic>),
      ],
    );
  }
}

/// Durable ratchet state. Every write must be on disk when its future
/// completes: callers send ciphertext only after that.
abstract class RatchetStore {
  /// 32-byte key that vodozemac uses to encrypt pickles.
  List<int> get pickleKey;
  Future<String?> readAccount();
  Future<void> writeAccount(String pickle);
  Future<RatchetPeerState?> readPeer(String deviceId);
  Future<void> writePeer(String deviceId, RatchetPeerState state);
  Future<void> deletePeer(String deviceId);
}

class MemoryRatchetStore implements RatchetStore {
  MemoryRatchetStore({List<int>? pickleKey})
    : pickleKey = pickleKey ?? List<int>.filled(32, 1);

  @override
  final List<int> pickleKey;
  String? account;
  final Map<String, String> peers = {};

  @override
  Future<String?> readAccount() async => account;

  @override
  Future<void> writeAccount(String pickle) async => account = pickle;

  @override
  Future<RatchetPeerState?> readPeer(String deviceId) async {
    final stored = peers[deviceId];
    return stored == null
        ? null
        : RatchetPeerState.fromJson(jsonDecode(stored) as Map<String, dynamic>);
  }

  @override
  Future<void> writePeer(String deviceId, RatchetPeerState state) async =>
      peers[deviceId] = jsonEncode(state.toJson());

  @override
  Future<void> deletePeer(String deviceId) async => peers.remove(deviceId);
}

class RatchetDecryptException implements Exception {
  const RatchetDecryptException(this.message);
  final String message;

  @override
  String toString() => 'RatchetDecryptException: $message';
}

/// Olm sessions per peer device, with write-before-send persistence.
///
/// Operations for one peer run strictly in order. A step's new state is
/// stored before its ciphertext or plaintext is returned, so a crash can
/// never replay a message key, and a failed decrypt leaves stored state
/// untouched because the engine is stateless.
class RatchetSessions {
  RatchetSessions({
    required RatchetEngine engine,
    required RatchetStore store,
    DateTime Function()? now,
  }) : _engine = engine,
       _store = store,
       _now = now ?? DateTime.now;

  /// Old sessions are kept only to decrypt in-flight messages.
  static const int maxSessionsPerPeer = 4;

  final RatchetEngine _engine;
  final RatchetStore _store;
  final DateTime Function() _now;
  final Map<String, Future<void>> _peerTails = {};
  Future<void> _accountTail = Future<void>.value();

  late final String _pickleKey = base64Encode(_store.pickleKey);

  /// This device's Olm identity key, creating the account on first use.
  Future<String> identityKey() => _withAccount((account) async {
    final result = _run({'op': 'bundle', 'account': account});
    return (result['account'] as String, result['identityKey'] as String);
  });

  /// A bundle for one peer. Each call reserves a fresh one-time key.
  Future<RatchetBundle> createBundle({bool oneTimeKey = true}) =>
      _withAccount((account) async {
        final result = _run({
          'op': 'bundle',
          'account': account,
          'oneTimeKey': oneTimeKey,
        });
        return (
          result['account'] as String,
          RatchetBundle(
            identityKey: result['identityKey'] as String,
            fallbackKey: result['fallbackKey'] as String,
            oneTimeKey: result['oneTimeKey'] as String?,
          ),
        );
      });

  /// Replaces the fallback key; the previous one keeps working until the
  /// next rotation so slow first messages still open.
  Future<String> rotateFallbackKey() => _withAccount((account) async {
    final result = _run({'op': 'rotate_fallback', 'account': account});
    return (result['account'] as String, result['fallbackKey'] as String);
  });

  Future<bool> hasSession(String peerDeviceId) async =>
      (await _store.readPeer(peerDeviceId))?.sessions.isNotEmpty ?? false;

  /// Opens an outbound session from [bundle]; it becomes the send session.
  Future<void> startSession(String peerDeviceId, RatchetBundle bundle) =>
      _withPeer(peerDeviceId, () async {
        final account = await _withAccount(
          (account) async => (account, account),
        );
        final result = _run({
          'op': 'outbound',
          'account': account,
          'peerIdentityKey': bundle.identityKey,
          'peerOneTimeKey': bundle.sessionKey,
        });
        final state = await _store.readPeer(peerDeviceId);
        final nowMs = _nowMs();
        await _store.writePeer(
          peerDeviceId,
          _withSession(
            state,
            RatchetSessionState(
              sessionId: result['sessionId'] as String,
              pickle: result['session'] as String,
              createdAtMs: nowMs,
              lastUsedAtMs: nowMs,
            ),
            peerIdentityKey: bundle.identityKey,
          ),
        );
      });

  /// Encrypts with the most recently used session. Throws [StateError]
  /// when no session exists yet.
  Future<RatchetMessage> encrypt(String peerDeviceId, List<int> plaintext) =>
      _withPeer(peerDeviceId, () async {
        final state = await _store.readPeer(peerDeviceId);
        final session = state?.sessions.firstOrNull;
        if (state == null || session == null) {
          throw StateError('No ratchet session with $peerDeviceId.');
        }
        final result = _run({
          'op': 'encrypt',
          'session': session.pickle,
          'plaintext': base64Encode(plaintext),
        });
        await _store.writePeer(
          peerDeviceId,
          _withSession(
            state,
            session.used(result['session'] as String, _nowMs()),
          ),
        );
        return RatchetMessage(
          type: result['messageType'] as int,
          ciphertext: base64Decode(result['ciphertext'] as String),
        );
      });

  /// Decrypts with any stored session, or opens an inbound session from a
  /// pre-key message. [peerIdentityKey] overrides the stored peer key.
  Future<List<int>> decrypt(
    String peerDeviceId,
    RatchetMessage message, {
    String? peerIdentityKey,
  }) => _withPeer(peerDeviceId, () async {
    final state = await _store.readPeer(peerDeviceId);
    final request = {
      'messageType': message.type,
      'ciphertext': base64Encode(message.ciphertext),
    };
    for (final session in state?.sessions ?? const <RatchetSessionState>[]) {
      final Map<String, dynamic> result;
      try {
        result = _run({'op': 'decrypt', 'session': session.pickle, ...request});
      } on RatchetEngineException {
        continue;
      }
      await _store.writePeer(
        peerDeviceId,
        _withSession(
          state,
          session.used(result['session'] as String, _nowMs()),
        ),
      );
      return base64Decode(result['plaintext'] as String);
    }
    final identity = peerIdentityKey ?? state?.peerIdentityKey;
    if (!message.opensSession || identity == null) {
      throw const RatchetDecryptException(
        'No ratchet session can decrypt this message.',
      );
    }
    return _withAccount((account) async {
      final Map<String, dynamic> result;
      try {
        result = _run({
          'op': 'inbound',
          'account': account,
          'peerIdentityKey': identity,
          ...request,
        });
      } on RatchetEngineException catch (error) {
        throw RatchetDecryptException(error.message);
      }
      final nowMs = _nowMs();
      await _store.writePeer(
        peerDeviceId,
        _withSession(
          state,
          RatchetSessionState(
            sessionId: result['sessionId'] as String,
            pickle: result['session'] as String,
            createdAtMs: nowMs,
            lastUsedAtMs: nowMs,
          ),
          peerIdentityKey: identity,
        ),
      );
      return (
        result['account'] as String,
        base64Decode(result['plaintext'] as String),
      );
    });
  });

  /// Drops every session with a peer (reset or contact removal).
  Future<void> forget(String peerDeviceId) =>
      _withPeer(peerDeviceId, () => _store.deletePeer(peerDeviceId));

  Map<String, dynamic> _run(Map<String, Object?> request) =>
      _engine.call({...request, 'pickleKey': _pickleKey});

  int _nowMs() => _now().toUtc().millisecondsSinceEpoch;

  RatchetPeerState _withSession(
    RatchetPeerState? state,
    RatchetSessionState session, {
    String? peerIdentityKey,
  }) {
    final others = [
      for (final existing in state?.sessions ?? const <RatchetSessionState>[])
        if (existing.sessionId != session.sessionId) existing,
    ];
    return RatchetPeerState(
      peerIdentityKey: peerIdentityKey ?? state?.peerIdentityKey,
      sessions: [
        session,
        ...others,
      ].take(maxSessionsPerPeer).toList(growable: false),
    );
  }

  Future<T> _withPeer<T>(String peerDeviceId, Future<T> Function() action) {
    final previous = _peerTails[peerDeviceId] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _peerTails[peerDeviceId] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_peerTails[peerDeviceId], tail)) {
          _peerTails.remove(peerDeviceId);
        }
      }),
    );
    return result;
  }

  /// Runs [action] with the account pickle and stores the pickle it returns
  /// before completing. Creates the account on first use.
  Future<T> _withAccount<T>(
    Future<(String, T)> Function(String account) action,
  ) {
    final result = _accountTail.then((_) async {
      var account = await _store.readAccount();
      if (account == null) {
        account = _run({'op': 'account_new'})['account'] as String;
        await _store.writeAccount(account);
      }
      final (updated, value) = await action(account);
      if (updated != account) await _store.writeAccount(updated);
      return value;
    });
    _accountTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

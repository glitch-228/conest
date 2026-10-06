import 'dart:async';
import 'dart:io';

import 'package:conest/src/network_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('network errors are told apart and described', () {
    const lookup = SocketException(
      "Failed host lookup: 'relay.0xchat.com'",
      osError: OSError('No address associated with hostname', 7),
    );
    const aborted = SocketException(
      'Software caused connection abort',
      osError: OSError('Software caused connection abort', 103),
      port: 49082,
    );
    const refused = SocketException(
      'Connection refused',
      osError: OSError('Connection refused', 111),
    );
    final timeout = TimeoutException('x', const Duration(seconds: 15));

    expect(isTransientNetworkError(lookup), isTrue);
    expect(isTransientNetworkError(aborted), isTrue);
    expect(isTransientNetworkError(timeout), isTrue);
    expect(isTransientNetworkError(refused), isFalse);
    expect(isTransientNetworkError(StateError('login refused')), isFalse);

    expect(describeNetworkError(lookup), contains('relay.0xchat.com'));
    expect(describeNetworkError(lookup), contains('no internet'));
    expect(describeNetworkError(aborted), contains('dropped'));
    expect(describeNetworkError(refused), contains('refused'));
    expect(describeNetworkError(timeout), startsWith('Timed out'));
    expect(describeNetworkError(const FormatException('odd')), contains('odd'));

    expect(
      describeActionError(ArgumentError('Enter a name.')),
      'Enter a name.',
    );
    expect(describeActionError(StateError('Turn it on.')), 'Turn it on.');
  });
}

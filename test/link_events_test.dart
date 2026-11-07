import 'package:conest/src/net/link_events.dart';
import 'package:conest/src/net/link_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('linkEventSourceFromAndroid', () {
    test('the three kinds the plugin sends', () {
      expect(
        linkEventSourceFromAndroid({'source': 'network'}),
        LinkEventSource.androidNetwork,
      );
      expect(
        linkEventSourceFromAndroid({'source': 'usb'}),
        LinkEventSource.androidUsbState,
      );
      expect(
        linkEventSourceFromAndroid({'source': 'tether'}),
        LinkEventSource.androidTether,
      );
    });

    test('anything else is not an event', () {
      expect(linkEventSourceFromAndroid({'source': 'other'}), isNull);
      expect(linkEventSourceFromAndroid({'source': 5}), isNull);
      expect(linkEventSourceFromAndroid('usb'), isNull);
      expect(linkEventSourceFromAndroid(null), isNull);
      expect(linkEventSourceFromAndroid(<String, Object?>{}), isNull);
    });

    test('a network callback is never the proof that the broadcasts work', () {
      // The mapping keeps the two apart: only usb and tether switch the
      // fallback off in the watcher.
      expect(
        linkEventSourceFromAndroid({'source': 'network'}),
        isNot(LinkEventSource.androidUsbState),
      );
    });
  });
}

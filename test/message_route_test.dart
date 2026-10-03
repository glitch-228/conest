import 'package:conest/src/models.dart';
import 'package:conest/src/transport_models.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message({
  MessageRoute? route,
  TransportKind? kind,
  TransportPathKind? path,
}) => ChatMessage(
  id: 'm',
  conversationId: 'c',
  senderDeviceId: 'a',
  recipientDeviceId: 'b',
  body: 'hi',
  outbound: false,
  state: DeliveryState.delivered,
  createdAt: DateTime.utc(2026, 10, 3),
  route: route,
  transportKind: kind,
  transportPath: path,
);

void main() {
  test('the route survives storage by name', () {
    final stored = _message(route: MessageRoute.lanRelay).toJson();
    expect(stored['route'], 'lanRelay');
    expect(ChatMessage.fromJson(stored).route, MessageRoute.lanRelay);
    // An unknown name from a newer build reads as unknown, not an error.
    expect(
      ChatMessage.fromJson({...stored, 'route': 'carrierPigeon'}).route,
      isNull,
    );
  });

  test('messages from before routes were recorded are derived', () {
    MessageRoute? derived(TransportKind kind, TransportPathKind path) =>
        _message(kind: kind, path: path).effectiveRoute;
    expect(
      derived(TransportKind.lan, TransportPathKind.local),
      MessageRoute.lanDirect,
    );
    expect(
      derived(TransportKind.iroh, TransportPathKind.direct),
      MessageRoute.irohDirect,
    );
    expect(
      derived(TransportKind.iroh, TransportPathKind.relayed),
      MessageRoute.irohRelay,
    );
    expect(
      derived(TransportKind.conestRelay, TransportPathKind.storeForward),
      MessageRoute.conestRelay,
    );
    expect(
      derived(TransportKind.conestRelay, TransportPathKind.direct),
      MessageRoute.internetDirect,
    );
    expect(
      derived(TransportKind.matrix, TransportPathKind.relayed),
      MessageRoute.matrixCarrier,
    );
    expect(_message().effectiveRoute, isNull);
    // A recorded route wins over the transport fields.
    expect(
      _message(
        route: MessageRoute.plainMatrix,
        kind: TransportKind.matrix,
        path: TransportPathKind.relayed,
      ).effectiveRoute,
      MessageRoute.plainMatrix,
    );
  });
}

import 'package:conest/src/content_routing.dart';
import 'package:conest/src/transport_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the built-in table is what each transport carries today', () {
    for (final kind in TransportKind.values) {
      for (final content in ContentClass.values) {
        final expected = switch (content) {
          ContentClass.fileSmall || ContentClass.fileMedium => kind.carriesBulk,
          ContentClass.fileLarge =>
            kind == TransportKind.lan || kind == TransportKind.iroh,
          _ => true,
        };
        expect(
          contentAllowed(kind, content),
          expected,
          reason: '${kind.name} ${content.name}',
        );
      }
    }
  });

  test('envelope kinds and file sizes map to their classes', () {
    expect(contentClassOfEnvelope('direct_message'), ContentClass.text);
    expect(contentClassOfEnvelope('group_message'), ContentClass.text);
    expect(contentClassOfEnvelope('ack'), ContentClass.receipt);
    expect(contentClassOfEnvelope('account_sync'), ContentClass.ownSync);
    expect(contentClassOfEnvelope('group_history'), ContentClass.history);
    expect(
      contentClassOfEnvelope('voice_call_signal'),
      ContentClass.callSignal,
    );
    expect(contentClassOfEnvelope('attachment_offer'), ContentClass.control);
    expect(contentClassOfEnvelope('route_update'), ContentClass.control);
    expect(contentClassOfEnvelope('attachment_chunk'), ContentClass.fileMedium);
    expect(
      contentClassOfEnvelope('attachment_chunk', fileSizeBytes: 1000),
      ContentClass.fileSmall,
    );
    expect(
      contentClassOfEnvelope('group_file_part', fileSizeBytes: smallFileBytes),
      ContentClass.fileSmall,
    );
    expect(
      contentClassOfEnvelope(
        'attachment_chunk_request',
        fileSizeBytes: smallFileBytes + 1,
      ),
      ContentClass.fileMedium,
    );
    expect(
      contentClassOfEnvelope('attachment_chunk', fileSizeBytes: largeFileBytes),
      ContentClass.fileMedium,
    );
    expect(
      contentClassOfEnvelope(
        'attachment_chunk',
        fileSizeBytes: largeFileBytes + 1,
      ),
      ContentClass.fileLarge,
    );
  });

  test('every layer only narrows, and control and receipts always pass', () {
    final noFilesOverRelay = ContentRefusals.none.withRefused(
      TransportKind.conestRelay,
      ContentClass.fileSmall,
      true,
    );
    for (final (device, contact, peer) in [
      (noFilesOverRelay, ContentRefusals.none, ContentRefusals.none),
      (ContentRefusals.none, noFilesOverRelay, ContentRefusals.none),
      (ContentRefusals.none, ContentRefusals.none, noFilesOverRelay),
    ]) {
      bool allowed(TransportKind kind, ContentClass content) => contentAllowed(
        kind,
        content,
        device: device,
        contact: contact,
        peer: peer,
      );
      expect(allowed(TransportKind.conestRelay, ContentClass.fileSmall), false);
      expect(allowed(TransportKind.conestRelay, ContentClass.fileMedium), true);
      expect(allowed(TransportKind.iroh, ContentClass.fileSmall), true);
      // A refusal never widens what a transport carries.
      expect(allowed(TransportKind.nostr, ContentClass.fileSmall), false);
    }

    var everything = ContentRefusals.none;
    for (final content in ContentClass.values) {
      everything = everything.withRefused(TransportKind.nostr, content, true);
    }
    expect(
      contentAllowed(
        TransportKind.nostr,
        ContentClass.control,
        device: everything,
      ),
      true,
    );
    expect(
      contentAllowed(
        TransportKind.nostr,
        ContentClass.receipt,
        device: everything,
      ),
      true,
    );
    expect(
      contentAllowed(
        TransportKind.nostr,
        ContentClass.text,
        device: everything,
      ),
      false,
    );
  });

  test('refusals round-trip, skip unknown names, and union', () {
    final refusals = ContentRefusals.none
        .withRefused(TransportKind.nostr, ContentClass.history, true)
        .withRefused(TransportKind.tor, ContentClass.fileMedium, true);
    expect(ContentRefusals.fromJson(refusals.toJson()), refusals);
    final fromNewer = ContentRefusals.fromJson({
      'nostr': ['history', 'hologram'],
      'pigeon': ['text'],
      'tor': 'not a list',
    });
    expect(fromNewer.toJson(), {
      'nostr': ['history'],
    });
    expect(ContentRefusals.fromJson(null), ContentRefusals.none);
    expect(ContentRefusals.fromJson('x'), ContentRefusals.none);

    final both = refusals.union(
      ContentRefusals.none.withRefused(
        TransportKind.nostr,
        ContentClass.ownSync,
        true,
      ),
    );
    expect(both.refuses(TransportKind.nostr, ContentClass.history), true);
    expect(both.refuses(TransportKind.nostr, ContentClass.ownSync), true);
    expect(both.refuses(TransportKind.tor, ContentClass.fileMedium), true);

    // Allowing again leaves nothing behind.
    final back = refusals
        .withRefused(TransportKind.nostr, ContentClass.history, false)
        .withRefused(TransportKind.tor, ContentClass.fileMedium, false);
    expect(back.isEmpty, true);
    expect(back.toJson(), isEmpty);
  });

  test('presets leave LAN alone and are recognised again', () {
    for (final preset in ContentRoutingPreset.values) {
      expect(ContentRoutingPreset.of(preset.refusals), preset);
      for (final content in ContentClass.values) {
        expect(preset.refusals.refuses(TransportKind.lan, content), false);
      }
    }
    final small = ContentRoutingPreset.messagesAndSmallFiles.refusals;
    expect(small.refuses(TransportKind.iroh, ContentClass.fileSmall), false);
    expect(small.refuses(TransportKind.iroh, ContentClass.fileMedium), true);
    final messages = ContentRoutingPreset.messagesOnly.refusals;
    expect(messages.refuses(TransportKind.iroh, ContentClass.fileSmall), true);
    expect(messages.refuses(TransportKind.iroh, ContentClass.text), false);
    expect(
      ContentRoutingPreset.of(
        ContentRefusals.none.withRefused(
          TransportKind.nostr,
          ContentClass.history,
          true,
        ),
      ),
      isNull,
    );
  });
}

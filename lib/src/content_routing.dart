import 'transport_models.dart';

/// What a piece of traffic is, for deciding which transports may carry it.
/// Persisted by name: append only.
enum ContentClass {
  /// Messages, and their edits, reactions and deletions (1:1 and groups).
  text,

  /// Contact, route, session and transfer upkeep; file offers.
  control,

  /// Delivery and read receipts.
  receipt,

  /// Sync between this account's own devices.
  ownSync,

  /// Older messages fetched to catch up (group history).
  history,

  /// Blocks of a file up to [smallFileBytes].
  fileSmall,

  /// Blocks of a file up to [largeFileBytes].
  fileMedium,

  /// Blocks of a file over [largeFileBytes].
  fileLarge,

  /// Setting up, answering and ending calls.
  callSignal,
}

/// Files up to this size are small.
const int smallFileBytes = 1024 * 1024;

/// Files over this size are large (the most a relay takes).
const int largeFileBytes = 30 * 1024 * 1024;

const Set<ContentClass> fileContentClasses = {
  ContentClass.fileSmall,
  ContentClass.fileMedium,
  ContentClass.fileLarge,
};

/// The file class for a file of [sizeBytes].
ContentClass fileContentClass(int sizeBytes) => sizeBytes <= smallFileBytes
    ? ContentClass.fileSmall
    : sizeBytes <= largeFileBytes
    ? ContentClass.fileMedium
    : ContentClass.fileLarge;

/// The class of an envelope of [kind]; file blocks by [fileSizeBytes] when
/// known (medium otherwise).
ContentClass contentClassOfEnvelope(String kind, {int? fileSizeBytes}) =>
    switch (kind) {
      'attachment_chunk_request' ||
      'attachment_chunk' ||
      'attachment_progress' ||
      'group_file_part' =>
        fileSizeBytes == null
            ? ContentClass.fileMedium
            : fileContentClass(fileSizeBytes),
      'direct_message' ||
      'group_message' ||
      'message_reaction' ||
      'message_edit' ||
      'message_delete' ||
      'lan_lobby_message' => ContentClass.text,
      'ack' || 'group_membership_ack' => ContentClass.receipt,
      'account_sync' || 'account_link' => ContentClass.ownSync,
      'group_history' => ContentClass.history,
      'voice_call_signal' || 'group_call_signal' => ContentClass.callSignal,
      _ => ContentClass.control,
    };

/// What a transport can carry at all. File blocks go only on transports
/// built for volume; large files only on LAN and Iroh.
bool transportCarries(TransportKind kind, ContentClass content) =>
    switch (content) {
      ContentClass.fileSmall || ContentClass.fileMedium => kind.carriesBulk,
      ContentClass.fileLarge =>
        kind == TransportKind.lan || kind == TransportKind.iroh,
      _ => true,
    };

/// Content refused per transport: a sparse narrowing. Layers (this device,
/// a contact, what the contact asked for) only ever add refusals.
class ContentRefusals {
  const ContentRefusals([this.byTransport = const {}]);

  final Map<TransportKind, Set<ContentClass>> byTransport;

  static const none = ContentRefusals();

  bool get isEmpty => byTransport.values.every((refused) => refused.isEmpty);

  bool refuses(TransportKind kind, ContentClass content) =>
      byTransport[kind]?.contains(content) ?? false;

  /// Both sets of refusals.
  ContentRefusals union(ContentRefusals other) {
    if (other.isEmpty) return this;
    if (isEmpty) return other;
    return ContentRefusals({
      for (final kind in {...byTransport.keys, ...other.byTransport.keys})
        kind: {...?byTransport[kind], ...?other.byTransport[kind]},
    });
  }

  /// With [content] over [kind] refused or allowed again.
  ContentRefusals withRefused(
    TransportKind kind,
    ContentClass content,
    bool refused,
  ) {
    final next = {
      for (final entry in byTransport.entries) entry.key: {...entry.value},
    };
    final set = next.putIfAbsent(kind, () => {});
    refused ? set.add(content) : set.remove(content);
    if (set.isEmpty) next.remove(kind);
    return ContentRefusals(next);
  }

  /// Unknown transports and classes (from a newer build) are skipped.
  factory ContentRefusals.fromJson(Object? json) {
    if (json is! Map) return none;
    final result = <TransportKind, Set<ContentClass>>{};
    for (final entry in json.entries) {
      final kind = TransportKind.values
          .where((value) => value.name == entry.key)
          .firstOrNull;
      final names = entry.value;
      if (kind == null || names is! List) continue;
      final refused = {
        for (final name in names)
          ?ContentClass.values.where((value) => value.name == name).firstOrNull,
      };
      if (refused.isNotEmpty) result[kind] = refused;
    }
    return ContentRefusals(result);
  }

  Map<String, List<String>> toJson() => {
    for (final entry in byTransport.entries)
      if (entry.value.isNotEmpty)
        entry.key.name: [for (final content in entry.value) content.name]
          ..sort(),
  };

  @override
  bool operator ==(Object other) =>
      other is ContentRefusals && _sameJson(toJson(), other.toJson());

  @override
  int get hashCode => Object.hashAllUnordered(
    toJson().entries.map(
      (entry) => Object.hash(entry.key, entry.value.join(',')),
    ),
  );

  static bool _sameJson(
    Map<String, List<String>> left,
    Map<String, List<String>> right,
  ) =>
      left.length == right.length &&
      left.entries.every(
        (entry) => right[entry.key]?.join(',') == entry.value.join(','),
      );
}

/// Simple choices for people who do not want the full table. LAN is
/// never narrowed by them: it costs nothing.
enum ContentRoutingPreset {
  everything,
  messagesAndSmallFiles,
  messagesOnly;

  ContentRefusals get refusals => switch (this) {
    everything => ContentRefusals.none,
    messagesAndSmallFiles => _beyondLan({
      ContentClass.fileMedium,
      ContentClass.fileLarge,
    }),
    messagesOnly => _beyondLan(fileContentClasses),
  };

  static ContentRefusals _beyondLan(Set<ContentClass> refused) =>
      ContentRefusals({
        for (final kind in TransportKind.values)
          if (kind != TransportKind.lan) kind: refused,
      });

  /// The preset these refusals are, or null for a custom table.
  static ContentRoutingPreset? of(ContentRefusals refusals) {
    for (final preset in values) {
      if (preset.refusals == refusals) return preset;
    }
    return null;
  }
}

/// Classes no layer may refuse: without them contacts and routes are not
/// kept up, and nothing would say a message arrived.
const Set<ContentClass> unrefusableContent = {
  ContentClass.control,
  ContentClass.receipt,
};

/// Whether [content] may go over [kind]: what the transport can carry,
/// less every layer's refusals.
bool contentAllowed(
  TransportKind kind,
  ContentClass content, {
  ContentRefusals device = ContentRefusals.none,
  ContentRefusals contact = ContentRefusals.none,
  ContentRefusals peer = ContentRefusals.none,
}) =>
    transportCarries(kind, content) &&
    (unrefusableContent.contains(content) ||
        !device.refuses(kind, content) &&
            !contact.refuses(kind, content) &&
            !peer.refuses(kind, content));

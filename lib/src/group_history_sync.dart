import 'dart:async';

import 'group_history_event.dart';
import 'group_history_journal.dart';
import 'group_membership_history.dart';
import 'models.dart';

const groupSyncPageSize = 32;

class GroupSyncCursor {
  const GroupSyncCursor({
    required this.authorDeviceId,
    required this.afterSequence,
  });
  final String authorDeviceId;
  final int afterSequence;
}

class GroupSyncInventoryEntry {
  const GroupSyncInventoryEntry({
    required this.eventId,
    required this.authorDeviceId,
    required this.sequence,
  });
  final String eventId;
  final String authorDeviceId;
  final int sequence;
}

class GroupSyncInventory {
  GroupSyncInventory({
    required List<GroupSyncInventoryEntry> entries,
    required this.next,
  }) : entries = List.unmodifiable(entries);
  final List<GroupSyncInventoryEntry> entries;
  final GroupSyncCursor? next;
}

/// Implement this interface using encrypted, group-scoped peer envelopes.
/// The network adapter must bind requesterDeviceId to its authenticated sender,
/// never to an identity supplied in an untrusted request body.
abstract interface class GroupHistoryExchange {
  Future<List<GroupHistoryEvent>> membershipPage(
    String requesterDeviceId, {
    String? afterEventId,
  });
  Future<GroupSyncInventory> inventory(
    String requesterDeviceId, {
    GroupSyncCursor? cursor,
  });
  Future<List<GroupHistoryEvent>> events(
    String requesterDeviceId,
    List<String> ids,
  );
}

/// Durable, transport-independent catch-up. Journal contents are the persisted
/// progress: an interrupted exchange restarts metadata paging but requests only
/// missing events. A carrier need not be the author or the group owner.
///
/// The controller still owns local group-removal state and payload projection
/// (edit ownership, receipt targets, etc.). Construct this only for an approved
/// group, and stop using it when the local group is explicitly removed.
class GroupHistoryReplica implements GroupHistoryExchange {
  GroupHistoryReplica._(this.journal, this.localDeviceId, this._membership);

  final GroupHistoryJournal journal;
  final String localDeviceId;
  GroupMembershipHistory _membership;
  Future<void> _tail = Future.value();
  GroupMembershipHistory get membership => _membership.fork();

  static Future<GroupHistoryReplica> restore({
    required GroupHistoryJournal journal,
    required String groupId,
    required String localDeviceId,
    required GroupMemberProfile trustedOwner,
  }) async {
    final membership = GroupMembershipHistory(
      groupId: groupId,
      trustedOwner: trustedOwner,
    );
    String? cursor;
    while (true) {
      final page = await journal.readMembershipPage(afterEventId: cursor);
      if (page.isEmpty) break;
      for (final proof in page) {
        if (await membership.import(GroupMembershipRecord.fromEvent(proof)) ==
            GroupMembershipImport.missingParents) {
          throw const FormatException(
            'Journal is missing a membership dependency.',
          );
        }
      }
      cursor = page.last.eventId;
    }
    return GroupHistoryReplica._(journal, localDeviceId, membership);
  }

  Future<T> _serialize<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<GroupMembershipImport> importMembership(GroupHistoryEvent proof) =>
      _serialize(() async {
        final candidate = _membership.fork();
        final result = await candidate.import(
          GroupMembershipRecord.fromEvent(proof),
        );
        if (result == GroupMembershipImport.accepted) {
          await journal.append(proof);
          _membership = candidate;
        }
        return result;
      });

  /// Already signed membership proofs are handled separately. The caller binds
  /// carrierDeviceId to the authenticated transport session before this call.
  Future<bool> importEvent(
    GroupHistoryEvent event, {
    required String carrierDeviceId,
  }) => _serialize(() async {
    if (!await _membership.canForward(
      event,
      carrierDeviceId: carrierDeviceId,
      recipientDeviceId: localDeviceId,
    )) {
      throw const FormatException('Unauthorized group history event.');
    }
    return journal.append(event);
  });

  void _requirePeer(String peer) {
    final head = _membership.current;
    if (head == null ||
        !head.group.hasActiveMember(peer) ||
        !head.group.hasActiveMember(localDeviceId)) {
      throw StateError(
        'Group membership must be current and undisputed before serving history.',
      );
    }
  }

  @override
  Future<List<GroupHistoryEvent>> membershipPage(
    String requesterDeviceId, {
    String? afterEventId,
  }) async {
    // During a fork, existing peers common to every head may exchange the
    // signed control records needed for resolution; ordinary history stays shut.
    final heads = _membership.heads;
    if (heads.isEmpty ||
        !heads.every((id) {
          final group = _membership.record(id)!.group;
          return group.hasActiveMember(requesterDeviceId) &&
              group.hasActiveMember(localDeviceId);
        })) {
      throw StateError('Unauthorized membership history request.');
    }
    final page = await journal.readMembershipPage(afterEventId: afterEventId);
    if (heads.join(',') != _membership.heads.join(',')) {
      throw StateError('Membership changed during history request.');
    }
    return page;
  }

  @override
  Future<GroupSyncInventory> inventory(
    String requesterDeviceId, {
    GroupSyncCursor? cursor,
  }) async {
    _requirePeer(requesterDeviceId);
    final head = _membership.current!.id;
    if (cursor != null &&
        (cursor.afterSequence < 0 ||
            cursor.afterSequence > groupEventMaxCounter)) {
      throw const FormatException('Invalid inventory cursor.');
    }
    var author = cursor?.authorDeviceId;
    if (author == null) {
      final authors = await journal.authors(limit: 1);
      if (authors.isEmpty) return GroupSyncInventory(entries: [], next: null);
      author = authors.single;
    }
    final after = cursor?.afterSequence ?? 0;
    final page = after == groupEventMaxCounter
        ? <GroupHistoryEvent>[]
        : await journal.readAuthorRange(
            author,
            start: after + 1,
            end: groupEventMaxCounter,
            limit: groupSyncPageSize,
          );
    final entries = <GroupSyncInventoryEntry>[];
    for (final event in page) {
      if (event.kind != GroupEventKind.membership &&
          await _membership.canForward(
            event,
            carrierDeviceId: localDeviceId,
            recipientDeviceId: requesterDeviceId,
          )) {
        entries.add(
          GroupSyncInventoryEntry(
            eventId: event.eventId,
            authorDeviceId: event.authorDeviceId,
            sequence: event.sequence,
          ),
        );
      }
    }
    GroupSyncCursor? next;
    if (page.isNotEmpty) {
      next = GroupSyncCursor(
        authorDeviceId: author,
        afterSequence: page.last.sequence,
      );
    } else {
      final authors = await journal.authors(after: author, limit: 1);
      if (authors.isNotEmpty) {
        next = GroupSyncCursor(
          authorDeviceId: authors.single,
          afterSequence: 0,
        );
      }
    }
    if (head != _membership.current?.id) {
      throw StateError('Membership changed during inventory.');
    }
    return GroupSyncInventory(entries: entries, next: next);
  }

  @override
  Future<List<GroupHistoryEvent>> events(
    String requesterDeviceId,
    List<String> ids,
  ) async {
    _requirePeer(requesterDeviceId);
    if (ids.isEmpty ||
        ids.length > groupSyncPageSize ||
        ids.toSet().length != ids.length) {
      throw const FormatException('Invalid history request size.');
    }
    final head = _membership.current!.id;
    final result = <GroupHistoryEvent>[];
    for (final event in await journal.readEvents(ids)) {
      if (event.kind != GroupEventKind.membership &&
          await _membership.canForward(
            event,
            carrierDeviceId: localDeviceId,
            recipientDeviceId: requesterDeviceId,
          )) {
        result.add(event);
      }
    }
    if (head != _membership.current?.id) {
      throw StateError('Membership changed during event request.');
    }
    return result;
  }

  /// Returns the number of newly durable ordinary events. Batches can be
  /// interrupted safely: the next invocation derives missing IDs from disk.
  Future<int> pullFrom(
    GroupHistoryExchange peer, {
    required String carrierDeviceId,
    int maxPages = 256,
  }) async {
    if (maxPages < 1 || maxPages > 4096) {
      throw ArgumentError('Invalid sync work budget.');
    }
    final progress = await journal.syncProgress(carrierDeviceId);
    var membershipComplete =
        progress['phase'] == 'inventory' &&
        progress['head'] == _membership.current?.id;
    String? membershipCursor = progress['membershipAfter'] is String
        ? progress['membershipAfter'] as String
        : null;
    GroupSyncCursor? cursor;
    if (progress['head'] == _membership.current?.id &&
        progress['author'] is String &&
        progress['sequence'] is int) {
      final sequence = progress['sequence'] as int;
      if (sequence >= 0 && sequence <= groupEventMaxCounter) {
        cursor = GroupSyncCursor(
          authorDeviceId: progress['author'] as String,
          afterSequence: sequence,
        );
      }
    }
    Future<void> saveProgress() => journal.saveSyncProgress(carrierDeviceId, {
      'phase': membershipComplete ? 'inventory' : 'membership',
      'head': _membership.current?.id,
      'membershipAfter': membershipCursor,
      'author': cursor?.authorDeviceId,
      'sequence': cursor?.afterSequence,
    });
    final beforeHead = _membership.current?.id;
    var pages = 0;
    while (!membershipComplete) {
      if (++pages > maxPages) {
        throw StateError('History exchange work budget reached; resume later.');
      }
      final page = await peer.membershipPage(
        localDeviceId,
        afterEventId: membershipCursor,
      );
      if (page.length > groupSyncPageSize) {
        throw const FormatException('Oversized membership page.');
      }
      if (page.isEmpty) {
        membershipComplete = true;
        break;
      }
      for (final proof in page) {
        if (await importMembership(proof) ==
            GroupMembershipImport.missingParents) {
          throw const FormatException('Peer omitted a membership dependency.');
        }
      }
      if (membershipCursor == page.last.eventId) {
        throw const FormatException('Membership cursor did not advance.');
      }
      membershipCursor = page.last.eventId;
      if (beforeHead != _membership.current?.id) cursor = null;
      await saveProgress();
    }
    membershipCursor = null;
    if (beforeHead != _membership.current?.id) cursor = null;
    await saveProgress();
    _requirePeer(carrierDeviceId);
    var imported = 0;
    do {
      if (++pages > maxPages) {
        throw StateError('History exchange work budget reached; resume later.');
      }
      final page = await peer.inventory(localDeviceId, cursor: cursor);
      if (page.entries.length > groupSyncPageSize) {
        throw const FormatException('Oversized history inventory.');
      }
      final ids = page.entries.map((entry) => entry.eventId).toList();
      if (ids.toSet().length != ids.length ||
          page.entries.any(
            (entry) =>
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.eventId) ||
                entry.authorDeviceId.isEmpty ||
                entry.authorDeviceId.length > 128 ||
                entry.sequence < 1 ||
                entry.sequence > groupEventMaxCounter,
          )) {
        throw const FormatException('Invalid group inventory entry.');
      }
      final retained = ids.isEmpty
          ? <String>{}
          : await journal.retainedIds(ids);
      final missing = ids.where((id) => !retained.contains(id)).toList();
      if (missing.isNotEmpty) {
        final wanted = missing.toSet();
        while (wanted.isNotEmpty) {
          final received = await peer.events(localDeviceId, wanted.toList());
          if (received.length > groupSyncPageSize) {
            throw const FormatException('Oversized history response.');
          }
          if (received.isEmpty) {
            throw StateError(
              'History provider is missing requested events; retry another peer.',
            );
          }
          for (final event in received) {
            if (!wanted.remove(event.eventId)) {
              throw const FormatException('Unrequested history event.');
            }
            final advertised = page.entries.firstWhere(
              (entry) => entry.eventId == event.eventId,
            );
            if (event.authorDeviceId != advertised.authorDeviceId ||
                event.sequence != advertised.sequence) {
              throw const FormatException(
                'History response does not match inventory.',
              );
            }
            if (await importEvent(event, carrierDeviceId: carrierDeviceId)) {
              imported++;
            }
          }
        }
      }
      final next = page.next;
      if (cursor != null &&
          next != null &&
          (next.authorDeviceId.compareTo(cursor.authorDeviceId) < 0 ||
              (next.authorDeviceId == cursor.authorDeviceId &&
                  next.afterSequence <= cursor.afterSequence))) {
        throw const FormatException(
          'History inventory cursor did not advance.',
        );
      }
      cursor = next;
      await saveProgress();
    } while (cursor != null);
    await journal.saveSyncProgress(carrierDeviceId, {});
    return imported;
  }
}

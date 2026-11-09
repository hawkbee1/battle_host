import 'dart:async';
import 'dart:typed_data';

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:dart_appwrite/models.dart' as models;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

/// [count] log entries, the first at [start] seconds, each with one event
/// and a few with a command.
List<LogEntry> sampleEntries(int count, {int start = 0}) => [
  for (var i = start; i < start + count; i++)
    LogEntry(
      at: Duration(seconds: i),
      command: i.isEven
          ? Command(
              sender: const Sender(accountId: 'a-1', sectionId: 's-1'),
              sentAt: Duration(seconds: i),
              order: const EnterBattle(),
              origin: Origin.server,
              seq: i + 1,
            )
          : null,
      events: [OrderRefused(seq: i + 1, reason: 'sample $i')],
    ),
];

/// A source of battle IDs that no earlier test used: [prefix] and a
/// number. A store that outlives the tests (the local Appwrite) needs a
/// [prefix] of its own on each run.
final class BattleIds {
  new(this.prefix);

  final String prefix;
  var _next = 0;

  String next() => '$prefix-${_next++}';
}

/// The contract of every [LogSink] (Liskov, stack decision 7).
void logSinkContract(LogSink Function() make, {required BattleIds ids}) {
  late LogSink sink;
  late String battle;

  setUp(() {
    sink = make();
    battle = ids.next();
  });

  test('reads the batches back in order, from the start of one', () async {
    final entries = sampleEntries(5);
    await sink.upload(
      LogBatch(battleId: battle, from: 0, entries: entries.sublist(0, 3)),
    );
    await sink.upload(
      LogBatch(battleId: battle, from: 3, entries: entries.sublist(3)),
    );

    expect(await sink.read(battle), equals(entries));
    expect(await sink.read(battle, from: 3), equals(entries.sublist(3)));
  });

  test(
    'reads nothing where no batch starts, nor for a battle with none',
    () async {
      await sink.upload(
        LogBatch(battleId: battle, from: 0, entries: sampleEntries(3)),
      );

      expect(await sink.read(battle, from: 1), isEmpty);
      expect(await sink.read(battle, from: 3), isEmpty);
      expect(await sink.read(ids.next()), isEmpty);
    },
  );

  test('keeps a batch uploaded again as it was', () async {
    final batch = LogBatch(
      battleId: battle,
      from: 0,
      entries: sampleEntries(2),
    );
    await sink.upload(batch);
    await sink.upload(batch);

    expect(await sink.read(battle), equals(batch.entries));
  });

  test('keeps the logs of two battles apart', () async {
    final other = ids.next();
    await sink.upload(
      LogBatch(battleId: battle, from: 0, entries: sampleEntries(2)),
    );
    await sink.upload(
      LogBatch(battleId: other, from: 0, entries: sampleEntries(1, start: 7)),
    );

    expect(await sink.read(battle), equals(sampleEntries(2)));
    expect(await sink.read(other), equals(sampleEntries(1, start: 7)));
  });

  test('refuses a batch with no entry', () {
    expect(
      () => sink.upload(LogBatch(battleId: battle, from: 0, entries: const [])),
      throwsArgumentError,
    );
  });
}

/// A snapshot of [battleId] at [position], at [seconds] of battle time.
BattleSnapshot sampleSnapshot(
  String battleId,
  int position, {
  int seconds = 0,
  List<int> data = const [1, 2, 3],
}) => BattleSnapshot(
  battleId: battleId,
  position: position,
  time: Duration(seconds: seconds),
  data: Uint8List.fromList(data),
);

/// The contract of every [SnapshotStore] (Liskov, stack decision 7).
void snapshotStoreContract(
  SnapshotStore Function() make, {
  required BattleIds ids,
}) {
  late SnapshotStore store;
  late String battle;

  setUp(() {
    store = make();
    battle = ids.next();
  });

  void expectSame(BattleSnapshot? actual, BattleSnapshot expected) {
    expect(actual, isNotNull);
    expect(
      (actual!.battleId, actual.position, actual.time),
      (expected.battleId, expected.position, expected.time),
    );
    expect(actual.data, equals(expected.data));
  }

  test('has no snapshot of a battle it never kept', () async {
    expect(await store.latest(battle), isNull);
  });

  test('gives back the latest snapshot kept, whole', () async {
    await store.save(sampleSnapshot(battle, 0));
    await store.save(sampleSnapshot(battle, 4, seconds: 9, data: [4, 5]));
    final third = sampleSnapshot(battle, 4, seconds: 12, data: [6]);
    await store.save(third);

    expectSame(await store.latest(battle), third);
  });

  test('keeps the snapshots of two battles apart', () async {
    final other = ids.next();
    final mine = sampleSnapshot(battle, 2);
    final theirs = sampleSnapshot(other, 5, data: [9]);
    await store.save(mine);
    await store.save(theirs);

    expectSame(await store.latest(battle), mine);
    expectSame(await store.latest(other), theirs);
  });
}

/// Checks that [held] are [entries] from the log position [from].
void expectHeld(
  HeldEntries held, {
  required int from,
  required List<LogEntry> entries,
}) {
  expect(held.from, from);
  expect(held.entries, equals(entries));
}

/// The contract of every [WriteAheadLog].
void writeAheadLogContract(WriteAheadLog Function() make) {
  late WriteAheadLog wal;

  setUp(() => wal = make());

  test('holds what it was given, in order', () {
    final entries = sampleEntries(3);
    for (final (position, entry) in entries.indexed) {
      wal.append('b-1', position, entry);
    }

    expectHeld(wal.read('b-1'), from: 0, entries: entries);
    expectHeld(wal.read('b-2'), from: 0, entries: const []);
  });

  test('starts again at a position past its end', () {
    final entries = sampleEntries(6);
    wal
      ..append('b-1', 0, entries[0])
      ..append('b-1', 4, entries[4])
      ..append('b-1', 5, entries[5]);

    expectHeld(wal.read('b-1'), from: 4, entries: entries.sublist(4));
  });

  test('forgets a battle it discards, and holds it again from any '
      'position', () {
    final entries = sampleEntries(6);
    wal
      ..append('b-1', 0, entries[0])
      ..append('b-1', 1, entries[1])
      ..append('b-2', 0, entries[0])
      ..discard('b-1')
      ..discard('b-3');

    expectHeld(wal.read('b-1'), from: 0, entries: const []);
    expectHeld(wal.read('b-2'), from: 0, entries: entries.sublist(0, 1));
    wal.append('b-1', 1, entries[1]);
    expectHeld(wal.read('b-1'), from: 1, entries: entries.sublist(1, 2));
  });

  test('refuses a position it already holds', () {
    wal.append('b-1', 0, sampleEntries(1).single);

    expect(
      () => wal.append('b-1', 0, sampleEntries(1).single),
      throwsStateError,
    );
  });
}

class _MockStorage extends Mock implements Storage;

/// An Appwrite Storage service in memory: files by bucket and ID, with the
/// codes Appwrite answers (404 for a missing file, 409 for one that
/// exists), and [failing] to make every call fail.
final class FakeStorage {
  new() {
    registerFallbackValue(InputFile.fromBytes(bytes: const [], filename: ''));
    when(
      () => storage.createFile(
        bucketId: any(named: 'bucketId'),
        fileId: any(named: 'fileId'),
        file: any(named: 'file'),
      ),
    ).thenAnswer((call) async {
      _check();
      final key = _key(call);
      if (files.containsKey(key)) {
        throw AppwriteException('exists', 409, 'storage_file_already_exists');
      }
      files[key] = Uint8List.fromList(
        (call.namedArguments[#file] as InputFile).bytes!,
      );
      return _MockFile();
    });
    when(
      () => storage.getFileDownload(
        bucketId: any(named: 'bucketId'),
        fileId: any(named: 'fileId'),
      ),
    ).thenAnswer((call) async {
      _check();
      return files[_key(call)] ?? (throw _notFound());
    });
    when(
      () => storage.deleteFile(
        bucketId: any(named: 'bucketId'),
        fileId: any(named: 'fileId'),
      ),
    ).thenAnswer((call) async {
      _check();
      if (files.remove(_key(call)) == null) throw _notFound();
    });
  }

  /// The service.
  final Storage storage = _MockStorage();

  /// The files, by `<bucket>/<file ID>`.
  final files = <String, Uint8List>{};

  /// The code every call fails with, while set.
  int? failing;

  static String _key(Invocation call) =>
      '${call.namedArguments[#bucketId]}/${call.namedArguments[#fileId]}';

  static AppwriteException _notFound() =>
      AppwriteException('not found', 404, 'storage_file_not_found');

  void _check() {
    if (failing case final code?) throw AppwriteException('failed', code);
  }
}

class _MockFile extends Mock implements models.File;

/// A [LogSink] that a stopped host no longer reaches: once [cut], what it
/// is sent never arrives.
final class SeveredLogSink implements LogSink {
  new(this.inner);

  final LogSink inner;
  bool cut = false;

  @override
  Future<void> upload(LogBatch batch) =>
      cut ? Completer<void>().future : inner.upload(batch);

  @override
  Future<List<LogEntry>> read(String battleId, {int from = 0}) =>
      inner.read(battleId, from: from);
}

/// A [SnapshotStore] that a stopped host no longer reaches.
final class SeveredSnapshotStore implements SnapshotStore {
  new(this.inner);

  final SnapshotStore inner;
  bool cut = false;

  @override
  Future<void> save(BattleSnapshot snapshot) =>
      cut ? Completer<void>().future : inner.save(snapshot);

  @override
  Future<BattleSnapshot?> latest(String battleId) => inner.latest(battleId);
}

/// A [LogSink] whose next [failures] uploads fail.
final class FlakyLogSink implements LogSink {
  new(this.inner, {this.failures = 0});

  final MemoryLogSink inner;
  int failures;
  final attempts = <LogBatch>[];

  @override
  Future<void> upload(LogBatch batch) async {
    attempts.add(batch);
    if (failures > 0) {
      failures--;
      throw StateError('upload failed');
    }
    await inner.upload(batch);
  }

  @override
  Future<List<LogEntry>> read(String battleId, {int from = 0}) =>
      inner.read(battleId, from: from);
}

/// A [SnapshotStore] whose next [failures] saves fail.
final class FlakySnapshotStore implements SnapshotStore {
  new(this.inner, {this.failures = 0});

  final MemorySnapshotStore inner;
  int failures;

  @override
  Future<void> save(BattleSnapshot snapshot) async {
    if (failures > 0) {
      failures--;
      throw StateError('save failed');
    }
    await inner.save(snapshot);
  }

  @override
  Future<BattleSnapshot?> latest(String battleId) => inner.latest(battleId);
}

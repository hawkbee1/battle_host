import 'dart:io';
import 'dart:typed_data';

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:test/test.dart';

import '../../helpers/stores.dart';

void main() {
  group(MemoryLogSink, () {
    logSinkContract(MemoryLogSink.new, ids: BattleIds('b'));

    test('lists the batches of a battle in their order', () async {
      final sink = MemoryLogSink();
      final entries = sampleEntries(3);
      await sink.upload(
        LogBatch(battleId: 'b-1', from: 2, entries: entries.sublist(2)),
      );
      await sink.upload(
        LogBatch(battleId: 'b-1', from: 0, entries: entries.sublist(0, 2)),
      );

      expect([for (final batch in sink.batchesOf('b-1')) batch.from], [0, 2]);
      expect(sink.batchesOf('b-1').last.end, 3);
      expect(sink.batchesOf('b-2'), isEmpty);
    });
  });

  group(AppwriteLogSink, () {
    late FakeStorage fake;

    setUp(() => fake = FakeStorage());

    logSinkContract(() => AppwriteLogSink(fake.storage), ids: BattleIds('b'));

    test('names a batch file by its battle and its first position, and '
        'stores the batch compressed', () async {
      final entries = sampleEntries(4);
      await AppwriteLogSink(fake.storage)
          .upload(LogBatch(battleId: 'b-1', from: 42, entries: entries));

      final data = fake.files['$battleLogsBucket/b-1-000000000042']!;
      expect(decodeBatch(data), equals(entries));
      expect(
        data.length,
        lessThan(const BinaryProtocolCodec().encodeLog(entries).length),
      );
    });

    test('passes on the errors other than a batch already there', () async {
      final sink = AppwriteLogSink(fake.storage);
      fake.failing = 500;

      await expectLater(
        sink.upload(
          LogBatch(battleId: 'b-1', from: 0, entries: sampleEntries(1)),
        ),
        throwsA(isA<AppwriteException>()),
      );
      await expectLater(sink.read('b-1'), throwsA(isA<AppwriteException>()));
    });

    test('stops reading at a batch with no entry', () async {
      fake.files['$battleLogsBucket/b-1-000000000000'] = encodeBatch(const []);

      expect(await AppwriteLogSink(fake.storage).read('b-1'), isEmpty);
    });

    test('refuses a battle ID that cannot name a file', () {
      expect(
        () => AppwriteLogSink.fileId('a' * (maxStoredBattleId + 1), 0),
        throwsArgumentError,
      );
      expect(() => AppwriteLogSink.fileId('../b-1', 0), throwsArgumentError);
      expect(AppwriteLogSink.fileId('a' * maxStoredBattleId, 1).length, 36);
    });
  });

  group(MemorySnapshotStore, () {
    snapshotStoreContract(MemorySnapshotStore.new, ids: BattleIds('b'));
  });

  group(AppwriteSnapshotStore, () {
    late FakeStorage fake;

    setUp(() => fake = FakeStorage());

    snapshotStoreContract(
      () => AppwriteSnapshotStore(fake.storage),
      ids: BattleIds('b'),
    );

    test('keeps two files per battle, the latest one whole while the next '
        'is written', () async {
      final store = AppwriteSnapshotStore(fake.storage);
      for (var position = 0; position < 5; position++) {
        await store.save(sampleSnapshot('b-1', position));
      }

      expect(fake.files.keys, {
        '$battleSnapshotsBucket/b-1-s0',
        '$battleSnapshotsBucket/b-1-s1',
      });
      final restarted = AppwriteSnapshotStore(fake.storage);
      expect((await restarted.latest('b-1'))!.position, 4);
      await restarted.save(sampleSnapshot('b-1', 5));
      expect((await restarted.latest('b-1'))!.position, 5);
      expect((await store.latest('b-1'))!.position, 5);
    });

    test('refuses a file that is not a snapshot', () async {
      for (final bytes in [
        <int>[],
        [0x42, 0x54, 0x53, 0x4E, 0x80],
        [0x42, 0x54, 0x53, 0x4E, 3],
      ]) {
        fake.files['$battleSnapshotsBucket/b-1-s0'] = Uint8List.fromList(
          gzip.encode(bytes),
        );

        await expectLater(
          AppwriteSnapshotStore(fake.storage).latest('b-1'),
          throwsFormatException,
          reason: '$bytes',
        );
      }
    });

    test('passes on the errors other than a missing file', () async {
      final store = AppwriteSnapshotStore(fake.storage);
      fake.failing = 503;

      await expectLater(
        store.save(sampleSnapshot('b-1', 0)),
        throwsA(isA<AppwriteException>()),
      );
      await expectLater(store.latest('b-1'), throwsA(isA<AppwriteException>()));
    });
  });

  group(MemoryWriteAheadLog, () {
    writeAheadLogContract(MemoryWriteAheadLog.new);
  });

  group(FileWriteAheadLog, () {
    late Directory directory;
    final opened = <FileWriteAheadLog>[];

    FileWriteAheadLog open() {
      final wal = FileWriteAheadLog('${directory.path}/wal');
      opened.add(wal);
      return wal;
    }

    File fileOf(String battleId) => File('${directory.path}/wal/$battleId.wal');

    setUp(() {
      directory = Directory.systemTemp.createTempSync('wal');
    });

    tearDown(() {
      for (final wal in opened) {
        wal.close();
      }
      opened.clear();
      directory.deleteSync(recursive: true);
    });

    writeAheadLogContract(open);

    test('an entry is on disk once it is appended: a new reader finds it', () {
      final entries = sampleEntries(2);
      open()
        ..append('b-1', 0, entries[0])
        ..append('b-1', 1, entries[1]);

      expectHeld(open().read('b-1'), from: 0, entries: entries);
      final bytes = fileOf('b-1').readAsBytesSync();
      expect(bytes.sublist(0, 4), 'BTWL'.codeUnits);
    });

    test('a host stopped in the middle of an append loses only that entry, '
        'and the next host writes over it', () {
      final entries = sampleEntries(3);
      open()
        ..append('b-1', 0, entries[0])
        ..append('b-1', 1, entries[1]);
      final file = fileOf('b-1');
      final whole = file.readAsBytesSync();
      file.writeAsBytesSync(whole.sublist(0, whole.length - 3));

      expect(open().read('b-1').entries, equals(entries.sublist(0, 1)));
      open().append('b-1', 1, entries[2]);
      expect(open().read('b-1').entries, equals([entries[0], entries[2]]));
    });

    test('goes on after a restart where the last host stopped', () {
      final entries = sampleEntries(3);
      open().append('b-1', 0, entries[0]);
      final restarted = open()..append('b-1', 1, entries[1]);

      expect(() => restarted.append('b-1', 1, entries[2]), throwsStateError);
      expect(open().read('b-1').entries, equals(entries.sublist(0, 2)));
    });

    test('starts its file again at a position past its end', () {
      final entries = sampleEntries(4);
      open()
        ..append('b-1', 0, entries[0])
        ..append('b-1', 3, entries[3]);

      expectHeld(open().read('b-1'), from: 3, entries: [entries[3]]);
      expect(File('${fileOf('b-1').path}.new').existsSync(), isFalse);
    });

    test('refuses a file that is not a write-ahead log of its version', () {
      fileOf('b-1')
        ..createSync(recursive: true)
        ..writeAsBytesSync([0x42, 0x54, 0x57, 0x4C, 0, 0x42]);
      fileOf('b-2').writeAsStringSync('nothing');

      for (final battle in ['b-1', 'b-2']) {
        expect(() => open().read(battle), throwsFormatException);
        expect(
          () => open().append(battle, 0, sampleEntries(1).single),
          throwsFormatException,
        );
      }
    });

    test('refuses a battle ID that cannot name a file', () {
      expect(() => open().read('../b-1'), throwsArgumentError);
      expect(() => open().read(''), throwsArgumentError);
    });
  });
}

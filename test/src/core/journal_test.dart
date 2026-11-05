import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/stores.dart';

/// A write-ahead log on a disk with room for [room] entries.
final class _FullDisk implements WriteAheadLog {
  new({this.room = 1});

  int room;

  @override
  void append(String battleId, int position, LogEntry entry) {
    if (room-- <= 0) {
      throw const FileSystemException('No space left on device');
    }
  }

  @override
  HeldEntries read(String battleId) => (from: 0, entries: const []);
}

void main() {
  late ManualClock clock;
  late RecordingErrorReporter reporter;

  setUp(() {
    clock = ManualClock(DateTime.utc(2026, 11, 5, 10));
    reporter = RecordingErrorReporter();
  });

  SimulationHost hostOn({
    WriteAheadLog? wal,
    LogSink? logs,
    SnapshotStore? snapshots,
  }) => SimulationHost(
    clock: clock,
    maps: MapLibrary(
      source: MemoryMapSource({'valley': valley}),
      terrain: planData.terrain,
    ),
    definitions: planData,
    reporter: reporter,
    wal: wal,
    logs: logs,
    snapshots: snapshots,
  );

  HandledOrder logIn(SimulationHost host, {String account = 'a-1'}) =>
      host.submit(
        'b-1',
        Command(
          sender: Sender(accountId: account, sectionId: 's-1'),
          sentAt: host['b-1']!.time,
          order: const EnterBattle(),
        ),
        origin: Origin.server,
      );

  Future<void> wait(SimulationHost host, Duration step) async {
    clock.advance(step);
    host.advance();
    await host.settle();
  }

  group('stack decision 2 the write path', () {
    test('an order is acknowledged only once its entry is on disk', () {
      final directory = Directory.systemTemp.createTempSync('journal');
      addTearDown(() => directory.deleteSync(recursive: true));
      final disk = FileWriteAheadLog(directory.path);
      addTearDown(disk.close);
      final host = hostOn(wal: disk)..start(valleySetup());

      final handled = logIn(host);

      final restarted = FileWriteAheadLog(directory.path);
      addTearDown(restarted.close);
      final last = restarted.read('b-1').entries.last;
      expect(last.command?.order, const EnterBattle());
      expect(last.command?.seq, 1);
      expect(last.events, equals(handled.events));
    });

    test('decision 143 a battle starts with an entry naming every section and '
        'its units, written before its first snapshot', () async {
      final wal = MemoryWriteAheadLog();
      final snapshots = MemorySnapshotStore();
      final host = hostOn(wal: wal, snapshots: snapshots)..start(valleySetup());
      await host.settle();

      final start = wal.read('b-1').entries.single;
      expect(start.command, isNull);
      expect(
        start.events.first,
        const BattleStarted(battleId: 'b-1', mapId: 'valley', seed: 7),
      );
      expect(
        start.events.skip(1).whereType<SectionJoined>().map((s) => s.sectionId),
        ['s-1', 's-2'],
      );
      expect((await snapshots.latest('b-1'))!.position, 1);
    });

    test('a battle whose start cannot be written does not start', () {
      final host = hostOn(wal: _FullDisk(room: 0));

      expect(
        () => host.start(valleySetup()),
        throwsA(isA<FileSystemException>()),
      );
      expect(host['b-1'], isNull);
      expect(host.failed, isEmpty);
    });

    test('an order whose entry cannot be written is not acknowledged, and '
        'its battle stops', () async {
      final host = hostOn(wal: _FullDisk())..start(valleySetup());

      expect(() => logIn(host), throwsA(isA<FileSystemException>()));
      await host.settle();

      expect(host.failed, {'b-1'});
      expect(host['b-1'], isNull);
      expect(reporter.reports.single.$2, 'b-1');
    });

    test('the new entries go up every 10 seconds as one batch; an interval '
        'with none uploads nothing', () async {
      final logs = MemoryLogSink();
      final host = hostOn(logs: logs)..start(valleySetup());
      await host.settle();
      // The start entry goes up at once, before the first snapshot.
      expect(logs.batchesOf('b-1').single.entries, hasLength(1));
      logIn(host);
      logIn(host, account: 'a-2');

      await wait(host, const Duration(seconds: 5));
      expect(logs.batchesOf('b-1'), hasLength(1));
      await wait(host, const Duration(seconds: 5));
      expect(logs.batchesOf('b-1').last.entries, hasLength(2));
      await wait(host, const Duration(seconds: 10));
      await wait(host, const Duration(seconds: 10));
      expect(logs.batchesOf('b-1'), hasLength(2));

      logIn(host);
      await wait(host, const Duration(seconds: 10));
      expect(
        [for (final batch in logs.batchesOf('b-1')) batch.from],
        [0, 1, 3],
      );
    });

    test('a battle is snapshotted when it starts, then every 5 minutes with '
        'new entries', () async {
      final snapshots = MemorySnapshotStore();
      final host = hostOn(snapshots: snapshots)..start(valleySetup());
      await host.settle();
      expect((await snapshots.latest('b-1'))!.position, 1);

      logIn(host);
      await wait(host, const Duration(minutes: 4));
      expect((await snapshots.latest('b-1'))!.position, 1);
      await wait(host, const Duration(minutes: 1));
      final taken = (await snapshots.latest('b-1'))!;
      expect(taken.position, 2);
      expect(taken.time, const Duration(minutes: 5));

      await wait(host, const Duration(minutes: 5));
      expect(await snapshots.latest('b-1'), same(taken));
    });

    test('a failed upload is reported and sent again, the same, and the '
        'snapshot after it waits for it', () async {
      final logs = FlakyLogSink(MemoryLogSink());
      final snapshots = MemorySnapshotStore();
      final host = hostOn(logs: logs, snapshots: snapshots)
        ..start(valleySetup());
      await host.settle();
      logs.failures = 1;
      logIn(host);

      await wait(host, const Duration(minutes: 5));
      expect(reporter.reports.single.$1, isA<StateError>());
      expect((await snapshots.latest('b-1'))!.position, 1);

      logIn(host);
      await wait(host, const Duration(seconds: 10));
      expect(logs.attempts, hasLength(4));
      expect(logs.attempts[2].entries, equals(logs.attempts[1].entries));
      expect(logs.attempts[3].from, 2);
      expect((await snapshots.latest('b-1'))!.position, 2);
      expect(await logs.read('b-1'), hasLength(3));
    });

    test(
      'a failed snapshot is reported and kept at the next interval',
      () async {
        final snapshots = FlakySnapshotStore(
          MemorySnapshotStore(),
          failures: 1,
        );
        final host = hostOn(snapshots: snapshots)..start(valleySetup());
        await host.settle();
        expect(reporter.reports, hasLength(1));
        expect(await snapshots.latest('b-1'), isNull);

        await wait(host, const Duration(seconds: 10));
        expect((await snapshots.latest('b-1'))!.position, 1);
      },
    );

    test('a battle stopped by an error uploads no more; its entries stay in '
        'the write-ahead log', () async {
      final wal = MemoryWriteAheadLog();
      final logs = MemoryLogSink();
      final host = hostOn(wal: wal, logs: logs)..start(valleySetup());
      logIn(host);
      host['b-1']!.schedule(
        const Duration(seconds: 1),
        const SectionUnlocks('s-9'),
      );

      await wait(host, const Duration(seconds: 10));

      expect(host.failed, {'b-1'});
      expect(logs.batchesOf('b-1').single.entries.single.command, isNull);
      expect(wal.read('b-1').entries, hasLength(2));
      expect(() => host.snapshot('b-1'), throwsArgumentError);
    });
  });
}

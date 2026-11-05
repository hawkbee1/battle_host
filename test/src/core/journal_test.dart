import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/stores.dart';

/// A write-ahead log on a full disk.
final class _FullDisk implements WriteAheadLog {
  @override
  void append(String battleId, int position, LogEntry entry) =>
      throw const FileSystemException('No space left on device');

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
      logIn(host);
      logIn(host, account: 'a-2');

      await wait(host, const Duration(seconds: 5));
      expect(logs.batchesOf('b-1'), isEmpty);
      await wait(host, const Duration(seconds: 5));
      expect(logs.batchesOf('b-1').single.entries, hasLength(2));
      await wait(host, const Duration(seconds: 10));
      await wait(host, const Duration(seconds: 10));
      expect(logs.batchesOf('b-1'), hasLength(1));

      logIn(host);
      await wait(host, const Duration(seconds: 10));
      expect([for (final batch in logs.batchesOf('b-1')) batch.from], [0, 2]);
    });

    test('a battle is snapshotted when it starts, then every 5 minutes with '
        'new entries', () async {
      final snapshots = MemorySnapshotStore();
      final host = hostOn(snapshots: snapshots)..start(valleySetup());
      await host.settle();
      expect((await snapshots.latest('b-1'))!.position, 0);

      logIn(host);
      await wait(host, const Duration(minutes: 4));
      expect((await snapshots.latest('b-1'))!.position, 0);
      await wait(host, const Duration(minutes: 1));
      final taken = (await snapshots.latest('b-1'))!;
      expect(taken.position, 1);
      expect(taken.time, const Duration(minutes: 5));

      await wait(host, const Duration(minutes: 5));
      expect(await snapshots.latest('b-1'), same(taken));
    });

    test('a failed upload is reported and sent again, the same, and the '
        'snapshot after it waits for it', () async {
      final logs = FlakyLogSink(MemoryLogSink(), failures: 1);
      final snapshots = MemorySnapshotStore();
      final host = hostOn(logs: logs, snapshots: snapshots)
        ..start(valleySetup());
      logIn(host);

      await wait(host, const Duration(minutes: 5));
      expect(reporter.reports.single.$1, isA<StateError>());
      expect((await snapshots.latest('b-1'))!.position, 0);

      logIn(host);
      await wait(host, const Duration(seconds: 10));
      expect(logs.attempts, hasLength(3));
      expect(logs.attempts[1].entries, equals(logs.attempts[0].entries));
      expect(logs.attempts[2].from, 1);
      expect((await snapshots.latest('b-1'))!.position, 1);
      expect(await logs.read('b-1'), hasLength(2));
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
        expect((await snapshots.latest('b-1'))!.position, 0);
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
      expect(logs.batchesOf('b-1'), isEmpty);
      expect(wal.read('b-1').entries, hasLength(1));
      expect(() => host.snapshot('b-1'), throwsArgumentError);
    });
  });
}

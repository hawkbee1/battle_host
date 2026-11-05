import 'dart:io';
import 'dart:math' as math;

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/orders.dart';
import '../../helpers/scripted_battle.dart';
import '../../helpers/stores.dart';

/// Everything the battle of [run] holds, as its snapshot writes it.
String stateOf(ScriptedHost run) => snapshotOf(run.battle);

/// Ends a run: the last entries are sealed and everything is uploaded.
Future<void> finish(ScriptedHost run) async {
  await run.host.settle();
  run.wait(const Duration(seconds: 10));
  await run.host.settle();
}

/// A host on these stores and `clock`; once `stop` is called, what it
/// sends no longer arrives, as if its process had stopped.
final class StoppingHost {
  new({
    required ManualClock clock,
    required WriteAheadLog wal,
    required LogSink logs,
    required SnapshotStore snapshots,
  }) : _logs = SeveredLogSink(logs),
       _snapshots = SeveredSnapshotStore(snapshots) {
    run = ScriptedHost(
      clock: clock,
      wal: wal,
      logs: _logs,
      snapshots: _snapshots,
    );
  }

  final SeveredLogSink _logs;
  final SeveredSnapshotStore _snapshots;
  late final ScriptedHost run;

  void stop() {
    _logs.cut = true;
    _snapshots.cut = true;
  }
}

void main() {
  late ScriptedHost live;
  late String liveState;
  late List<LogEntry> liveLog;

  setUpAll(() async {
    live = ScriptedHost.alone();
    await live.begin();
    for (final step in script) {
      step(live);
      await live.host.settle();
    }
    await finish(live);
    liveState = stateOf(live);
    liveLog = live.wal.read('b-1').entries;
  });

  group('decision 3 stack decision 2 recovery', () {
    test('the scripted battle uses every kind of order and runs over a day '
        'of timers', () {
      // The start entry, then 4 entries of timers.
      expect(liveLog.where((entry) => entry.command == null), hasLength(5));
      expect(live.battle.time, greaterThan(const Duration(hours: 34)));
      expect(live.battle.state.delta.built, isNotEmpty);
      expect(live.recruit, startsWith('unit-'));
      expect(live.battle.state.units['commander-2']!.location, isA<Deployed>());
      expect(live.reporter.reports, isEmpty);
    });

    test('decision 143 the uploaded log reads whole from the start, each '
        'attack with its outcome, for the statistics', () async {
      final uploaded = await live.logs.read('b-1');

      expect(uploaded, equals(liveLog));
      final attacks = uploaded
          .expand((entry) => entry.events)
          .whereType<Attacked>()
          .toList();
      expect(attacks, hasLength(5));
      expect(attacks.where((attack) => attack.hit), isNotEmpty);
      expect(
        attacks.expand((attack) => attack.impacts),
        contains(
          isA<Impact>()
              .having((impact) => impact.damage, 'damage', greaterThan(0))
              .having(
                (impact) => impact.result,
                'result',
                ImpactResult.damaged,
              ),
        ),
      );
    });

    test('decision 162 decision 166 every command logged keeps its origin: '
        'player, AI or server', () async {
      final origins = [
        for (final entry in await live.logs.read('b-1'))
          if (entry.command case final command?) command.origin,
      ];

      expect(origins, isNot(contains(null)));
      expect(origins.toSet(), {Origin.server, Origin.player, Origin.ai});
      expect(origins.first, Origin.server);
    });

    test('a host stopped at any point of the scripted battle recovers to the '
        'state of a host that never stopped', () async {
      // Which steps let the uploads under way land before the next one.
      final random = math.Random(15);
      for (var stop = 0; stop <= script.length; stop++) {
        final wal = MemoryWriteAheadLog();
        final logs = MemoryLogSink();
        final snapshots = MemorySnapshotStore();
        final clock = ManualClock(scriptStart);
        final first = StoppingHost(
          clock: clock,
          wal: wal,
          logs: logs,
          snapshots: snapshots,
        );
        await first.run.begin();
        for (final step in script.take(stop)) {
          step(first.run);
          if (random.nextBool()) await first.run.host.settle();
        }
        first.stop();

        final second = ScriptedHost(
          clock: clock,
          wal: wal,
          logs: logs,
          snapshots: snapshots,
        );
        await second.host.recover('b-1');
        for (final step in script.skip(stop)) {
          step(second);
          if (random.nextBool()) await second.host.settle();
        }
        await finish(second);

        expect(stateOf(second), equals(liveState), reason: 'stop $stop');
        expect(wal.read('b-1').entries, equals(liveLog), reason: 'stop $stop');
        expect(await logs.read('b-1'), equals(liveLog), reason: 'stop $stop');
        expect(second.reporter.reports, isEmpty, reason: 'stop $stop');
      }
    });

    test('a host restarted on the same disk recovers from its write-ahead '
        'log file what it had not uploaded', () async {
      final directory = Directory.systemTemp.createTempSync('recovery');
      addTearDown(() => directory.deleteSync(recursive: true));
      final logs = MemoryLogSink();
      final snapshots = MemorySnapshotStore();
      final clock = ManualClock(scriptStart);
      final disk = FileWriteAheadLog(directory.path);
      final first = StoppingHost(
        clock: clock,
        wal: disk,
        logs: logs,
        snapshots: snapshots,
      );
      await first.run.begin();
      const stop = 20;
      script.take(stop).forEach((step) => step(first.run));
      first.stop();
      disk.close();

      final restarted = FileWriteAheadLog(directory.path);
      addTearDown(restarted.close);
      final second = ScriptedHost(
        clock: clock,
        wal: restarted,
        logs: logs,
        snapshots: snapshots,
      );
      expect((await logs.read('b-1')).length, lessThan(stop));
      await second.host.recover('b-1');
      script.skip(stop).forEach((step) => step(second));
      await finish(second);

      expect(stateOf(second), equals(liveState));
      expect(await logs.read('b-1'), equals(liveLog));
    });

    test('decision 222 a battle stopped for two hours comes back with the '
        'timers of that time fired', () async {
      const stop = 29;
      const outage = Duration(hours: 2);
      final waited = ScriptedHost.alone();
      await waited.begin();
      script.take(stop).forEach((step) => step(waited));
      waited.wait(outage);
      script.skip(stop).forEach((step) => step(waited));
      await finish(waited);

      final wal = MemoryWriteAheadLog();
      final logs = MemoryLogSink();
      final snapshots = MemorySnapshotStore();
      final clock = ManualClock(scriptStart);
      final first = StoppingHost(
        clock: clock,
        wal: wal,
        logs: logs,
        snapshots: snapshots,
      );
      await first.run.begin();
      script.take(stop).forEach((step) => step(first.run));
      first.stop();
      clock.advance(outage);
      final second = ScriptedHost(
        clock: clock,
        wal: wal,
        logs: logs,
        snapshots: snapshots,
      );
      await second.host.recover('b-1');
      script.skip(stop).forEach((step) => step(second));
      await finish(second);

      expect(stateOf(second), equals(stateOf(waited)));
      expect(wal.read('b-1').entries, equals(waited.wal.read('b-1').entries));
    });

    test('a host whose disk is lost recovers what was uploaded, loses the '
        'rest, and goes on from there', () async {
      const stop = 27;
      final logs = MemoryLogSink();
      final snapshots = MemorySnapshotStore();
      final clock = ManualClock(scriptStart);
      final first = StoppingHost(
        clock: clock,
        wal: MemoryWriteAheadLog(),
        logs: logs,
        snapshots: snapshots,
      );
      await first.run.begin();
      for (final step in script.take(stop)) {
        step(first.run);
        await first.run.host.settle();
      }
      first.stop();
      final uploaded = await logs.read('b-1');
      expect(
        uploaded.length,
        lessThan(first.run.wal.read('b-1').entries.length),
      );

      final newDisk = MemoryWriteAheadLog();
      final second = ScriptedHost(
        clock: clock,
        wal: newDisk,
        logs: logs,
        snapshots: snapshots,
      );
      await second.host.recover('b-1');
      expect(liveLog.sublist(0, uploaded.length), equals(uploaded));
      script.skip(stop).forEach((step) => step(second));
      await finish(second);
      expect(newDisk.read('b-1').from, uploaded.length);

      final third = ScriptedHost(
        clock: clock,
        wal: MemoryWriteAheadLog(),
        logs: logs,
        snapshots: snapshots,
      );
      await third.host.recover('b-1');
      expect(stateOf(third), equals(stateOf(second)));
      expect(
        await logs.read('b-1'),
        equals([...uploaded, ...newDisk.read('b-1').entries]),
      );
    });

    test('refuses a battle that runs, has no snapshot, or whose write-ahead '
        'log starts after its uploaded log', () async {
      final run = ScriptedHost.alone();
      await expectLater(run.host.recover('b-1'), throwsStateError);
      await run.begin();
      await expectLater(run.host.recover('b-1'), throwsArgumentError);

      final wal = MemoryWriteAheadLog()
        ..append('b-1', 9, sampleEntries(1).single);
      final later = ScriptedHost(
        clock: ManualClock(scriptStart),
        wal: wal,
        logs: run.logs,
        snapshots: run.snapshots,
      );
      await expectLater(later.host.recover('b-1'), throwsStateError);
    });

    test(
      'a battle stopped by an error is recovered on the same host',
      () async {
        final run = ScriptedHost.alone();
        await run.begin();
        script.take(10).forEach((step) => step(run));
        run.battle.schedule(
          run.battle.time + const Duration(seconds: 1),
          const SectionUnlocks('s-9'),
        );
        run.wait(const Duration(seconds: 2));
        expect(run.host.failed, {'b-1'});
        expect(run.host['b-1'], isNull);

        await run.host.recover('b-1');

        expect(run.host.failed, isEmpty);
        expect(run.host['b-1'], isNotNull);
        script.skip(10).forEach((step) => step(run));
        await finish(run);
        expect(run.reporter.reports, hasLength(1));
      },
    );
  });
}

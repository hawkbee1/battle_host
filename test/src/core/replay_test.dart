import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/scripted_battle.dart';

void main() {
  late ScriptedHost run;
  late BattleSnapshot snapshot;
  late List<LogEntry> log;

  setUpAll(() async {
    run = ScriptedHost.alone();
    await run.begin();
    snapshot = (await run.snapshots.latest('b-1'))!;
    for (final step in script) {
      step(run);
    }
    log = run.wal.read('b-1').entries.sublist(snapshot.position);
  });

  Battle restored() => Battle.restore(
    decodeSnapshot(snapshot.data, definitions: planData).memento,
    map: run.battle.map,
    definitions: planData,
  );

  Matcher divergesAt(int index) => throwsA(
    isA<StateError>().having(
      (error) => error.message,
      'message',
      endsWith('at position ${snapshot.position + index}'),
    ),
  );

  int firstTimerEntry() => log.indexWhere((entry) => entry.command == null);

  group(replay, () {
    test('makes the logged battle again', () {
      final battle = restored();
      void listener(Duration at, List<BattleEvent> events) {}
      battle.onEvents = listener;

      replay(battle, log, from: snapshot.position);

      expect(battle.time, log.last.at);
      expect(battle.onEvents, same(listener));
    });

    test('stops at an entry whose events differ', () {
      final index = log.indexWhere((entry) => entry.command != null) + 1;
      final changed = [...log];
      changed[index] = LogEntry(
        at: log[index].at,
        command: log[index].command,
        events: const [OrderRefused(seq: 99, reason: 'changed')],
      );

      expect(
        () => replay(restored(), changed, from: snapshot.position),
        divergesAt(index),
      );
    });

    test('stops at an entry of its own the battle does not make', () {
      final index = firstTimerEntry();
      final changed = [...log]
        ..insert(
          index,
          LogEntry(
            at: log[index].at,
            events: const [OrderRefused(seq: 0, reason: 'invented')],
          ),
        );

      expect(
        () => replay(restored(), changed, from: snapshot.position),
        divergesAt(index),
      );
    });

    test('stops at a command whose sequence number is not the next one', () {
      final command = log.first.command!;
      final changed = [
        LogEntry(
          at: log.first.at,
          command: command.stamped(origin: command.origin!, seq: 77),
          events: log.first.events,
        ),
        ...log.skip(1),
      ];

      expect(
        () => replay(restored(), changed, from: snapshot.position),
        divergesAt(0),
      );
    });

    test('stops where the battle makes an entry the log does not hold', () {
      final index = firstTimerEntry();
      final cut = log.sublist(0, index);
      final until = [...cut, LogEntry(at: log[index].at, events: const [])];

      expect(
        () => replay(restored(), until, from: snapshot.position),
        divergesAt(index),
      );
      expect(
        () => replay(restored(), [
          ...cut,
          ...log.skip(index + 1).take(1),
        ], from: snapshot.position),
        divergesAt(index),
      );
    });
  });
}

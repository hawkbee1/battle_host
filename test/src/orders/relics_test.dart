import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';

void main() {
  late OrdersFixture f;

  setUp(() => f = OrdersFixture());

  final xpRules = XpRules(planData.units.progression);
  const sky = 'sky';

  void place(String id, CellRef cell) => f.changeUnit(
    id,
    (unit) => unit.copyWith(location: const Deployed(), cell: cell),
  );

  RelicState relic(String id) => f.battle.state.relics[id]!;

  HandledOrder send(Order order, String section) =>
      f.send(order, section: section, account: 'a-${section[2]}');

  List<BattleEvent> eventsOf(Order order, {String section = 's-1'}) {
    final handled = send(order, section);
    expect(handled.refusal, isNull, reason: '$order');
    return handled.events;
  }

  /// The events the battle made on its own since the last command.
  List<BattleEvent> hostEvents() => [
    for (final entry in f.entries.reversed.takeWhile((e) => e.command == null))
      ...entry.events,
  ];

  /// Gives [relicIds] to [team], as if it had captured them.
  void own(String team, List<String> relicIds) => f.battle.change((state) {
    var next = state;
    for (final id in relicIds) {
      next = next.withRelic(next.relics[id]!.copyWith(owner: team));
    }
    final victory = next.victory!;
    return next.withVictory(
      VictoryState(
        relicOwners: {
          ...victory.relicOwners,
          for (final id in relicIds) id: team,
        },
        teams: victory.teams,
      ),
    );
  });

  const team1Pushers = [
    'commander-1',
    'soldier-1',
    'medic-1',
    'engineer-1',
    'scout-1',
    'artillery-1',
    'truck-1',
    'jeep-1',
    'soldier-4',
    'soldier-5',
  ];

  /// Fills the capture pot of [relicId] with [units] of [section], two
  /// contributions each.
  void fillCapture(String relicId, List<String> units, String section) {
    for (var turn = 0; turn < 2; turn++) {
      for (final id in units) {
        eventsOf(
          Capture(unitId: id, relicId: relicId),
          section: section,
        );
      }
    }
  }

  group('captures', () {
    test('RELIC-05 RELIC-11 UNIT-07 a full pot captures the relic 30 minutes '
        'later; its contributors share the capture XP', () {
      const units = [
        'commander-1',
        'soldier-1',
        'medic-1',
        'engineer-1',
        'scout-1',
      ];
      fillCapture('relic-1', units, 's-1');
      expect(relic('relic-1').capturePot!.fullAt, equals(Duration.zero));

      f.wait(const Duration(minutes: 30));
      expect(
        hostEvents(),
        contains(const RelicCaptured(relicId: 'relic-1', team: 'team-1')),
      );
      expect(relic('relic-1').owner, equals('team-1'));
      final share = xpRules.split(
        planData.units.progression.xpSources.capture / units.length,
      );
      for (final id in units) {
        expect(f.unit(id).xp.earned, closeTo(share.unit, 1e-9), reason: id);
      }
    });

    test('RELIC-10 RELIC-12 another team retakes it at once and its previous '
        'owner is alerted', () {
      own('team-1', ['relic-1']);
      for (final id in team1Pushers) {
        place(id, const CellRef(8, 7));
      }
      for (final id in ['commander-2', 'soldier-2', 'soldier-3']) {
        place(id, const CellRef(0, 4));
      }
      for (var i = 0; i < 10; i++) {
        final id = ['commander-2', 'soldier-2', 'soldier-3'][i % 3];
        eventsOf(
          Capture(unitId: id, relicId: 'relic-1'),
          section: 's-2',
        );
      }

      f.wait(const Duration(minutes: 30));
      expect(
        hostEvents(),
        contains(
          const RelicCaptured(
            relicId: 'relic-1',
            team: 'team-2',
            previousOwner: 'team-1',
          ),
        ),
      );
    });

    test('RELIC-08 an enemy entering the radius loses the capture and its '
        'pot', () {
      fillCapture('relic-1', ['commander-1', 'soldier-1'], 's-1');

      final events = eventsOf(
        Move(unitId: 'soldier-2', to: centreOf(f.battle, const CellRef(1, 4))),
        section: 's-2',
      );
      expect(
        events,
        contains(const CaptureLost(relicId: 'relic-1', team: 'team-1')),
      );
      expect(relic('relic-1').capturePot, isNull);
    });

    test('RELIC-08 a full pot lost before its 30 minutes captures nothing', () {
      fillCapture('relic-1', [
        'commander-1',
        'soldier-1',
        'medic-1',
        'engineer-1',
        'scout-1',
      ], 's-1');
      eventsOf(
        Move(unitId: 'soldier-2', to: centreOf(f.battle, const CellRef(1, 4))),
        section: 's-2',
      );

      f.wait(const Duration(hours: 1));
      expect(relic('relic-1').owner, isNull);
    });
  });

  group('the relic hold', () {
    test('RELIC-17 a battle starts with its relics unowned and no hold', () {
      final victory = f.battle.state.victory!;
      expect(victory.relicOwners.values, everyElement(isNull));
      expect(victory.relicOwners, hasLength(6));
      expect((victory.hold, victory.winner), equals((null, null)));
    });

    test('RELIC-13 owning a relic gives nothing but the hold', () {
      fillCapture('relic-1', [
        'commander-1',
        'soldier-1',
        'medic-1',
        'engineer-1',
        'scout-1',
      ], 's-1');
      f.wait(const Duration(minutes: 30));
      final money = f.battle.state.sections['s-1']!.money;
      final xp = f.unit('radio-1').xp.earned;

      f.wait(const Duration(hours: 12));
      expect(f.battle.state.sections['s-1']!.money, equals(money));
      expect(f.unit('radio-1').xp.earned, equals(xp));
    });

    test('RELIC-14 RELIC-16 UNIT-11 a team that holds 5 relics for 24 hours '
        'wins, and its units earn the victory XP', () {
      own('team-1', ['relic-2', 'relic-3', 'relic-4', 'relic-5']);
      fillCapture('relic-1', [
        'commander-1',
        'soldier-1',
        'medic-1',
        'engineer-1',
        'scout-1',
      ], 's-1');

      f.wait(const Duration(minutes: 30));
      const winsAt = Duration(minutes: 30, hours: 24);
      expect(
        hostEvents(),
        contains(const VictoryHoldStarted(team: 'team-1', winsAt: winsAt)),
      );
      final radioXp = f.unit('radio-1').xp.earned;

      f.wait(const Duration(hours: 24));
      expect(
        hostEvents(),
        contains(
          const BattleEnded(
            winner: 'team-1',
            kind: WinKind.relics,
            eliminated: [],
          ),
        ),
      );
      expect(f.battle.state.ended, isTrue);
      expect(
        f.unit('radio-1').xp.earned,
        closeTo(radioXp + xpRules.split(xpRules.victoryXp).unit, 1e-9),
      );
      expect(
        f.send(const Reload(unitId: 'jeep-1')).refusal?.code,
        equals('battle_over'),
      );
    });

    test('RELIC-15 RELIC-18 one capture that drops a team below 5 relics '
        'resets its countdown', () {
      own('team-1', ['relic-2', 'relic-3', 'relic-4', 'relic-5']);
      fillCapture('relic-1', [
        'commander-1',
        'soldier-1',
        'medic-1',
        'engineer-1',
        'scout-1',
      ], 's-1');
      f.wait(const Duration(minutes: 30));

      for (final id in ['commander-2', 'soldier-2', 'soldier-3']) {
        place(id, const CellRef(6, 6));
      }
      for (var i = 0; i < 10; i++) {
        final id = ['commander-2', 'soldier-2', 'soldier-3'][i % 3];
        eventsOf(
          Capture(unitId: id, relicId: 'relic-4'),
          section: 's-2',
        );
      }
      f.wait(const Duration(minutes: 30));
      expect(hostEvents(), contains(const VictoryHoldReset(team: 'team-1')));

      f.wait(const Duration(hours: 24));
      expect(f.battle.state.ended, isFalse);
    });
  });

  group('eliminations', () {
    test('HQ-18 HQ-19 HQ-20 HQ-45 a destroyed HQ eliminates its team, stores '
        'its units on the field, and the last HQ wins', () {
      f.changeUnit(
        'soldier-3',
        (unit) => unit.copyWith(location: const Stored(), clearCell: true),
      );
      final team = f.battle.state.teams['team-2']!;
      f.battle.change(
        (state) => state.withTeam(
          team.withHq(
            HqState(
              cell: team.hq.cell,
              health: Health(current: 0.1, max: team.hq.health.max),
              pool: team.hq.pool,
            ),
          ),
        ),
      );
      f.changeUnit(
        'soldier-1',
        (unit) => unit.copyWith(cell: const CellRef(8, 1)),
      );

      final events = eventsOf(
        FireAimed(
          unitId: 'soldier-1',
          aim: Direction.of(3, -1, 0),
          fireTime: f.battle.time,
        ),
      );
      expect(
        events,
        containsAllInOrder([
          const Eliminated(team: 'team-2', loss: HqLoss.destroyed),
          const BattleEnded(
            winner: 'team-1',
            kind: WinKind.lastHq,
            eliminated: ['team-2'],
          ),
        ]),
      );
      expect(f.battle.state.teams['team-2']!.eliminated, isTrue);
      expect(f.unit('soldier-2').location, isA<Stored>());
      expect(events, isNot(contains(const UnitStored(unitId: 'soldier-3'))));
      expect(f.battle.state.eliminated, equals(['team-2']));
    });

    test('RELIC-26 HQ-23 a destroyed reinforced bridge loses the relic and '
        'the HQ on it', () {
      final before = f.battle.state;
      final relics = f.battle.orders.relics;
      final lost = f.battle.orders.react(
        before,
        relics.bridgeDestroyed(const [CellRef(3, 0), CellRef(11, 0)]),
      );

      expect(
        lost,
        containsAllInOrder([
          const RelicLost(relicId: 'relic-2'),
          const Eliminated(team: 'team-2', loss: HqLoss.lostWithBridge),
          isA<BattleEnded>(),
        ]),
      );
      expect(f.battle.state.relics, isNot(contains('relic-2')));
      expect(relics.bridgeDestroyed(const [CellRef(0, 0)]), isEmpty);
    });
  });

  group('pushes', () {
    /// A soldier [id] of `s-1`, on the field.
    void recruit(String id) {
      final extra = f.unit('soldier-1');
      f.battle.change(
        (state) => state.withUnit(
          UnitState(
            id: id,
            sectionId: 's-1',
            type: extra.type,
            tree: extra.tree,
            xp: extra.xp,
            location: const Deployed(),
            pool: extra.pool,
            health: extra.health,
            morale: extra.morale,
            weapon: extra.weapon,
          ),
        ),
      );
    }

    /// Puts [pushers] next to [relicId], owned by team 1, and has each push
    /// [times] times; the first push names [path].
    void push(
      String relicId,
      List<Cell> path, {
      required CellRef near,
      List<String> pushers = team1Pushers,
      int times = 2,
    }) {
      own('team-1', [relicId]);
      for (final id in pushers) {
        place(id, near);
      }
      for (var turn = 0; turn < times; turn++) {
        for (final id in pushers) {
          f.send(
            Push(unitId: id, relicId: relicId, path: turn == 0 ? path : null),
          );
        }
      }
    }

    test('RELIC-24 ten pushers move a relic along its path at 5 m per hour, '
        'paid by the pot', () {
      push('relic-2', const [
        Cell(3, 0),
        Cell(4, 0),
      ], near: const CellRef(3, 1));

      final moved = f.entries
          .expand((entry) => entry.events)
          .whereType<MoveStarted>()
          .single;
      expect(moved.moverId, equals('relic-2'));
      expect(moved.arrivesAt, equals(const Duration(hours: 2)));
      expect(relic('relic-2').cell, equals(const CellRef(4, 0)));

      f.wait(const Duration(hours: 2));
      final arrived = relic('relic-2');
      expect(arrived.push, isNull);
      expect(arrived.pushPot!.ap, equals(0));
      expect(arrived.pushers, isEmpty);
      expect(arrived.pushPath, isNull);
    });

    test('RELIC-24 fewer than ten pushers do not move it', () {
      push(
        'relic-2',
        const [Cell(3, 0), Cell(4, 0)],
        near: const CellRef(3, 1),
        pushers: team1Pushers.take(9).toList(),
        times: 3,
      );
      expect(relic('relic-2').push, isNull);
      expect(relic('relic-2').cell, equals(const CellRef(3, 0)));
    });

    test('RELIC-25 an extra pusher crushes the unit in its way; without it '
        'the relic stops before', () {
      place('soldier-3', const CellRef(4, 0));
      push('relic-2', const [
        Cell(3, 0),
        Cell(4, 0),
      ], near: const CellRef(3, 1));
      expect(relic('relic-2').push, isNull);
      expect(relic('relic-2').cell, equals(const CellRef(3, 0)));

      f = OrdersFixture();
      recruit('soldier-9');
      place('soldier-3', const CellRef(4, 0));
      push(
        'relic-2',
        const [Cell(3, 0), Cell(4, 0)],
        near: const CellRef(3, 1),
        pushers: [...team1Pushers, 'soldier-9'],
      );
      f.wait(const Duration(hours: 2));
      expect(
        hostEvents(),
        contains(
          const Crushed(
            byId: 'relic-2',
            unitId: 'soldier-3',
            unitType: 'soldier',
          ),
        ),
      );
      expect(f.battle.state.units, isNot(contains('soldier-3')));
    });

    test('RELIC-22 a relic pushed over an island edge falls, kills the units '
        'under it and empties its pot', () {
      place('soldier-2', const CellRef(9, 7));
      push(
        'relic-6',
        const [Cell(9, 6, island: sky), Cell(9, 7)],
        near: const CellRef(9, 5, surface: sky),
        times: 1,
      );
      f.wait(const Duration(hours: 1));

      expect(
        hostEvents(),
        contains(
          const Crushed(
            byId: 'relic-6',
            unitId: 'soldier-2',
            unitType: 'soldier',
          ),
        ),
      );
      final fallen = relic('relic-6');
      expect(fallen.cell, equals(const CellRef(9, 7)));
      expect(fallen.owner, equals('team-1'));
      expect(fallen.pushPot!.ap, equals(0));
    });

    test('RELIC-24 the AP put in during a push stay in the pot', () {
      push('relic-2', const [
        Cell(3, 0),
        Cell(4, 0),
      ], near: const CellRef(3, 1));
      expect(relic('relic-2').push, isNotNull);
      f
        ..send(const Push(unitId: 'soldier-1', relicId: 'relic-2'))
        ..wait(const Duration(hours: 2));
      expect(relic('relic-2').push, isNull);
      expect(relic('relic-2').pushPot!.ap, equals(5));
    });

    group('decision 225 the pushers inside the radius', () {
      const path = [CellRef(3, 0), CellRef(4, 0), CellRef(4, 1), CellRef(4, 2)];

      /// Gives relic-2 to team 1 with [ap] in its pot and [path] chosen,
      /// then has each of [pushers], standing on [near], push it once.
      List<BattleEvent> pushWith(
        List<String> pushers, {
        double ap = 400,
        CellRef near = const CellRef(3, 2),
      }) {
        own('team-1', ['relic-2']);
        f.battle.change(
          (state) => state.withRelic(
            state.relics['relic-2']!.withPots(
              pushPot: PushPot(owner: 'team-1', ap: ap),
              pushPath: path,
            ),
          ),
        );
        final events = <BattleEvent>[];
        for (final id in pushers) {
          place(id, near);
          events.addAll(eventsOf(Push(unitId: id, relicId: 'relic-2')));
        }
        return events;
      }

      HandledOrder walk(String unitId, CellRef to) =>
          f.send(Move(unitId: unitId, to: centreOf(f.battle, to)));

      test('a pusher outside does not push; one coming back pushes again', () {
        pushWith(team1Pushers.where((id) => id != 'jeep-1').toList());
        expect(relic('relic-2').push, isNull);
        pushWith(['jeep-1'], ap: relic('relic-2').pushPot!.ap);
        expect(relic('relic-2').push, isNotNull);

        f.wait(const Duration(minutes: 30));
        expect(
          walk('jeep-1', const CellRef(0, 7)).events,
          contains(isA<MoveStopped>()),
        );
        expect(relic('relic-2').push, isNull);
        expect(relic('relic-2').cell, equals(const CellRef(3, 0)));
        expect(
          walk('jeep-1', const CellRef(3, 2)).events,
          contains(
            isA<MoveStarted>().having((e) => e.moverId, 'id', 'relic-2'),
          ),
        );
        expect(relic('relic-2').push!.pushers, contains('jeep-1'));
      });

      test('the relic stops on the first cell where one is outside, then '
          'goes on with the others', () {
        recruit('soldier-9');
        place('soldier-9', const CellRef(1, 0));
        own('team-1', ['relic-2']);
        eventsOf(const Push(unitId: 'soldier-9', relicId: 'relic-2'));
        pushWith(team1Pushers);

        final first = relic('relic-2').push!;
        expect(first.pushers, hasLength(10));
        expect(first.cell, equals(const CellRef(4, 1)));

        f.wait(first.endsAt - f.battle.time);
        final second = relic('relic-2').push!;
        expect(second.pushers, isNot(contains('soldier-9')));
        expect(second.cell, equals(const CellRef(4, 2)));
      });

      test('a pusher walking away stops the push on the cell it reached; the '
          'pot gets back the rest', () {
        pushWith(team1Pushers);
        final push = relic('relic-2').push!;
        expect(push.cell, equals(const CellRef(4, 2)));
        expect(
          relic('relic-2').pushPot!.ap,
          closeTo(450 - push.spent.last, 1e-9),
        );

        f.wait(const Duration(hours: 3));
        final stopped = walk('jeep-1', const CellRef(0, 7)).events;
        expect(
          stopped,
          contains(
            MoveStopped(
              moverId: 'relic-2',
              at: centreOf(f.battle, const CellRef(4, 0)),
            ),
          ),
        );
        final relic2 = relic('relic-2');
        expect(relic2.push, isNull);
        expect(relic2.cell, equals(const CellRef(4, 0)));
        expect(relic2.pushPath, equals(path.sublist(1)));
        expect(relic2.pushPot!.ap, closeTo(450 - push.spent[1], 1e-9));
      });

      test('RELIC-25 decision 185 a relic that crushed its extra units stops '
          'at the next and does not crush it later', () {
        recruit('soldier-9');
        place('soldier-2', const CellRef(4, 0));
        place('soldier-3', const CellRef(4, 1));
        pushWith([...team1Pushers, 'soldier-9']);
        expect(relic('relic-2').push!.cell, equals(const CellRef(4, 0)));

        f.wait(const Duration(hours: 3));
        eventsOf(const Push(unitId: 'soldier-1', relicId: 'relic-2'));
        f.wait(const Duration(hours: 3));

        expect(f.battle.state.units, isNot(contains('soldier-2')));
        expect(f.battle.state.units, contains('soldier-3'));
        expect(relic('relic-2').cell, equals(const CellRef(4, 0)));
        expect(relic('relic-2').crushes, equals(1));
      });
    });

    test('RELIC-28 a relic with no path stays stuck', () {
      push('relic-2', const [
        Cell(3, 0),
        Cell(5, 0),
      ], near: const CellRef(3, 1));
      expect(relic('relic-2').push, isNull);
    });

    test('HQ-48 the HQ falls from an island and kills the units under it', () {
      final team = f.battle.state.teams['team-1']!;
      f.battle.change(
        (state) => state.withTeam(
          team.withHq(
            HqState(
              cell: const CellRef(9, 6, surface: sky),
              health: team.hq.health,
              pool: team.hq.pool,
            ),
          ),
        ),
      );
      place('soldier-2', const CellRef(9, 7));

      final events = eventsOf(
        MoveHq(
          to: centreOf(f.battle, const CellRef(9, 7)),
          path: const [
            Cell(9, 6, island: sky),
            Cell(9, 7),
          ],
        ),
      );
      expect(
        events,
        contains(
          Crushed(
            byId: hqId('team-1'),
            unitId: 'soldier-2',
            unitType: 'soldier',
          ),
        ),
      );
    });
  });

  group('a replay', () {
    test('decision 225 of a push its pushers stop and start again reaches '
        'the same state', () {
      void prepare(Battle battle) => battle.change((state) {
        var next = state.withRelic(
          state.relics['relic-2']!.copyWith(
            owner: 'team-1',
            pushPot: () => const PushPot(owner: 'team-1', ap: 400),
            pushPath: () => const [
              CellRef(3, 0),
              CellRef(4, 0),
              CellRef(4, 1),
              CellRef(4, 2),
            ],
          ),
        );
        for (final id in team1Pushers) {
          next = next.withUnit(
            next.units[id]!.copyWith(
              location: const Deployed(),
              cell: const CellRef(3, 2),
            ),
          );
        }
        return next;
      });
      void walk(CellRef to) =>
          eventsOf(Move(unitId: 'jeep-1', to: centreOf(f.battle, to)));

      prepare(f.battle);
      for (final id in team1Pushers) {
        eventsOf(Push(unitId: id, relicId: 'relic-2'));
      }
      f.wait(const Duration(hours: 3));
      walk(const CellRef(0, 7));
      f.wait(const Duration(hours: 1));
      walk(const CellRef(3, 2));
      f.wait(const Duration(hours: 10));

      expect(relic('relic-2').cell, equals(const CellRef(4, 2)));
      expect(relic('relic-2').push, isNull);
      expectReplay(f, prepare: prepare);
    });

    test('of a battle won by the relic timer reaches the same result', () {
      void prepare(Battle battle) => battle.change((state) {
        var next = state;
        for (final id in ['relic-2', 'relic-3', 'relic-4', 'relic-5']) {
          next = next.withRelic(next.relics[id]!.copyWith(owner: 'team-1'));
        }
        return next.withVictory(
          VictoryState(
            relicOwners: {
              ...next.victory!.relicOwners,
              for (final id in ['relic-2', 'relic-3', 'relic-4', 'relic-5'])
                id: 'team-1',
            },
            teams: next.victory!.teams,
          ),
        );
      });
      prepare(f.battle);
      fillCapture('relic-1', [
        'commander-1',
        'soldier-1',
        'medic-1',
        'engineer-1',
        'scout-1',
      ], 's-1');
      f.wait(const Duration(hours: 25));

      expect(f.battle.state.victory!.winner?.kind, VictoryKind.relics);
      expectReplay(f, prepare: prepare);
    });

    test('of a battle won by the last HQ reaches the same result', () {
      void prepare(Battle battle) => battle.change((state) {
        final team = state.teams['team-2']!;
        return state
            .withTeam(
              team.withHq(
                HqState(
                  cell: team.hq.cell,
                  health: Health(current: 0.1, max: team.hq.health.max),
                  pool: team.hq.pool,
                ),
              ),
            )
            .withUnit(
              state.units['soldier-1']!.copyWith(cell: const CellRef(8, 1)),
            );
      });
      prepare(f.battle);
      eventsOf(
        FireAimed(
          unitId: 'soldier-1',
          aim: Direction.of(3, -1, 0),
          fireTime: f.battle.time,
        ),
      );

      expect(f.battle.state.victory!.winner?.kind, VictoryKind.lastHq);
      expectReplay(f, prepare: prepare);
    });
  });
}

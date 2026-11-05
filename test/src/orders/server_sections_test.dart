import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/orders.dart';
import '../../helpers/scripted_battle.dart';

void main() {
  late OrdersFixture f;

  setUp(() => f = OrdersFixture(serverManaged: true));

  const checks = Duration(minutes: 30);
  const serverUnits = ['commander-2', 'soldier-2', 'soldier-3'];

  HandledOrder sendTwo(Order order, {Origin origin = Origin.server}) =>
      f.send(order, section: 's-2', account: 'a-2', origin: origin);

  /// The fire checks waiting, by unit, with their time.
  List<(Duration, String)> pendingChecks() => [
    for (final (at, timer) in f.battle.timers)
      if (timer case ServerCheck(:final unitId)) (at, unitId),
  ];

  /// The orders the server's fire checks gave: their time, unit and
  /// target.
  List<(Duration, String, String)> shots(List<LogEntry> entries) => [
    for (final entry in entries)
      if (entry.command case Command(
        origin: Origin.server,
        order: Fire(:final unitId, :final targetId),
      ))
        (entry.at, unitId, targetId),
  ];

  /// Takes every unit of team 1 off the field.
  void storeTeamOne() => f.battle.change((state) {
    var next = state;
    for (final unit in state.units.values) {
      if (unit.sectionId == 's-1') {
        next = next.withUnit(
          unit.copyWith(location: const Stored(), clearCell: true),
        );
      }
    }
    return next;
  });

  group('AI-06 decisions 159 163 a server-managed section', () {
    test('looks like any other section in what the battle tells', () {
      final plain = OrdersFixture();
      final events = [for (final entry in f.entries) ...entry.events];
      final plainEvents = [for (final entry in plain.entries) ...entry.events];

      expect(events, equals(plainEvents));
      expect(f.battle.state.sections['s-2']!.serverManaged, isTrue);
      expect(plain.battle.state.sections['s-2']!.serverManaged, isFalse);
    });

    test('AI-09 decision 165 takes its orders through the command handler, '
        'with their rules and refusals', () {
      final moved = sendTwo(
        Move(unitId: 'soldier-2', to: centreOf(f.battle, const CellRef(6, 3))),
      );
      final refused = sendTwo(const Store(unitId: 'commander-1'));

      expect(moved.events.single, isA<MoveStarted>());
      expect(refused.refusal!.code, equals('not_your_unit'));
    });

    test('a unit it buys gets its own fire check, an interval after it '
        'arrives', () {
      f
        ..battle.change(
          (state) =>
              state.withSection(state.sections['s-2']!.withWallet(money: 1000)),
        )
        ..wait(const Duration(minutes: 10));
      final bought =
          sendTwo(const BuyUnit(unitType: 'soldier')).events.first
              as UnitPurchased;

      expect(
        pendingChecks(),
        contains((const Duration(minutes: 40), bought.unitId)),
      );
    });
  });

  group('AI-07 decisions 160 196 the fire check', () {
    test('runs for each unit every 30 minutes from the start', () {
      expect(pendingChecks(), [for (final id in serverUnits) (checks, id)]);

      f.wait(checks);
      expect(pendingChecks(), [for (final id in serverUnits) (checks * 2, id)]);
    });

    test('draws nothing when an enemy comes into range, only at the check '
        'that sees it', () {
      storeTeamOne();
      final untouched = f.battle.random.state;

      f.wait(checks);
      expect(f.battle.random.state, equals(untouched));
      f
        ..changeUnit(
          'jeep-1',
          (unit) => unit.copyWith(
            location: const Deployed(),
            cell: const CellRef(4, 2),
          ),
        )
        ..wait(const Duration(minutes: 29));
      expect(f.battle.random.state, equals(untouched));

      f.wait(const Duration(minutes: 1));
      expect(f.battle.random.state, isNot(equals(untouched)));
    });

    test('a unit in storage, carried or without a weapon does not fire, and '
        'keeps its check', () {
      f
        ..changeUnit(
          'soldier-2',
          (unit) => unit.copyWith(location: const Stored(), clearCell: true),
        )
        ..changeUnit(
          'soldier-3',
          (unit) => unit.copyWith(location: const Carried('truck-9')),
        )
        ..changeUnit(
          'commander-2',
          (unit) => unit.copyWith(weapon: const WeaponState.unarmed()),
        );
      final untouched = f.battle.random.state;

      f.wait(checks * 4);
      expect(f.battle.random.state, equals(untouched));
      expect(pendingChecks(), hasLength(3));
    });

    test('AI-08 a seeded run fires the expected shots, at the nearest enemy, '
        'carried out like any other order', () {
      f.wait(const Duration(hours: 3));
      final fired = shots(f.entries);

      // 8 shots in 18 checks; commander-2 sees only the jeep past the
      // building.
      Duration h(double hours) => Duration(minutes: (hours * 60).round());
      expect(fired, [
        (h(1), 'soldier-2', 'jeep-1'),
        (h(1), 'soldier-3', 'jeep-1'),
        (h(1.5), 'commander-2', 'jeep-1'),
        (h(2), 'commander-2', 'jeep-1'),
        (h(2), 'soldier-2', 'jeep-1'),
        (h(2), 'soldier-3', 'jeep-1'),
        (h(3), 'commander-2', 'jeep-1'),
        (h(3), 'soldier-2', 'jeep-1'),
      ]);
      for (final entry in f.entries.where(
        (entry) => entry.command?.order is Fire,
      )) {
        expect(entry.command!.origin, Origin.server);
        expect(entry.at.inMicroseconds % checks.inMicroseconds, isZero);
        expect(entry.events.first, isA<Attacked>());
      }
    });

    test('a unit that left its section or died has no check after the one '
        'due', () {
      f
        ..changeUnit('soldier-2', (unit) => unit.copyWith(sectionId: 's-1'))
        ..battle.change((state) => state.withoutUnit('soldier-3'))
        ..wait(checks);

      expect(pendingChecks(), [(checks * 2, 'commander-2')]);
    });

    test('a unit turned into the section gets its own check', () {
      f.wait(const Duration(minutes: 5));
      final before = f.battle.state;
      f.changeUnit('soldier-1', (unit) => unit.copyWith(sectionId: 's-2'));
      const turned = Attacked(
        attackerId: 'commander-2',
        sectionId: 's-2',
        weapon: 'rifle',
        hit: true,
        impacts: [
          Impact(
            targetId: 'soldier-1',
            targetType: 'soldier',
            damage: 1,
            friendly: false,
            result: ImpactResult.defected,
          ),
        ],
      );

      f.battle.orders.servers.hear(const [turned], before);
      f.battle.orders.servers.hear(const [turned], f.battle.state);

      expect(pendingChecks().where((check) => check.$2 == 'soldier-1'), [
        (const Duration(minutes: 35), 'soldier-1'),
      ]);
    });

    test('stops once the battle has ended', () {
      f.battle.change(
        (state) => state.withVictory(
          VictoryState(
            relicOwners: state.victory!.relicOwners,
            teams: state.victory!.teams,
            winner: const BattleWon(team: 'team-1', kind: VictoryKind.lastHq),
          ),
        ),
      );
      f.wait(checks);

      expect(pendingChecks(), isEmpty);
    });
  });

  group('AI-05 decision 166 the log', () {
    test('every server order is logged with the origin server, and a replay '
        'gives the same battle', () {
      sendTwo(
        Move(unitId: 'soldier-3', to: centreOf(f.battle, const CellRef(7, 1))),
      );
      f.wait(const Duration(hours: 2));

      final server = [
        for (final entry in f.entries)
          if (entry.command case final command?
              when command.sender.sectionId == 's-2')
            command,
      ];
      expect(server.length, greaterThan(1));
      expect(server.map((command) => command.origin).toSet(), {Origin.server});
      expectReplay(f);
    });

    test('stack decision 2 a host stopped between checks recovers its checks '
        'and the orders they gave', () async {
      Future<void> hours(ScriptedHost run, int count) async {
        for (var hour = 0; hour < count; hour++) {
          run.wait(const Duration(minutes: 47));
          await run.host.settle();
        }
      }

      final live = ScriptedHost.alone(serverManaged: true);
      await live.begin();
      await hours(live, 6);

      final first = ScriptedHost.alone(serverManaged: true);
      await first.begin();
      await hours(first, 3);
      final second = ScriptedHost(
        clock: first.clock,
        wal: first.wal,
        logs: first.logs,
        snapshots: first.snapshots,
        serverManaged: true,
      );
      await second.host.recover('b-1');
      await hours(second, 3);

      expect(shots(live.wal.read('b-1').entries), isNotEmpty);
      expect(snapshotOf(second.battle), equals(snapshotOf(live.battle)));
      expect(
        second.wal.read('b-1').entries,
        equals(live.wal.read('b-1').entries),
      );
    });
  });
}

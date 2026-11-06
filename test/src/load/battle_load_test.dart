import 'package:battle_host/battle_host.dart';
import 'package:battle_host/load.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';
import '../maps/saint_lo_test.dart';

void main() {
  late MapLibrary maps;

  setUpAll(() {
    maps = MapLibrary(
      source: const DirectoryMapSource(builtMaps),
      terrain: planData.terrain,
    );
  });

  ({SimulationHost host, ManualClock clock, MemorySnapshotStore snapshots})
  hostOf() {
    final clock = ManualClock(DateTime.utc(2026, 11, 6));
    final snapshots = MemorySnapshotStore();
    return (
      host: SimulationHost(
        clock: clock,
        maps: maps,
        definitions: planData,
        reporter: RecordingErrorReporter(),
        snapshots: snapshots,
        rateLimit: RateLimit(perSecond: 1000, burst: 1000),
      ),
      clock: clock,
      snapshots: snapshots,
    );
  }

  Battle started(SimulationHost host, LoadSettings settings, {String? id}) {
    final battle = host.start(
      loadSetup(
        settings,
        battleId: id ?? 'load-1',
        mapId: 'saint_lo',
        definitions: planData,
      ),
    );
    placeLoad(battle, settings);
    return battle;
  }

  group('loadSetup', () {
    test('P-02 splits the units into two teams of sections led by their '
        'commander', () {
      final setup = loadSetup(
        const LoadSettings(units: 37, sectionSize: 8, serverManagedShare: 0.5),
        battleId: 'load-1',
        mapId: 'saint_lo',
        definitions: planData,
      );

      expect(setup.teams.map((team) => team.id), loadTeams);
      final sizes = [
        for (final team in setup.teams)
          [for (final section in team.sections) section.units.length],
      ];
      expect(sizes, [
        [8, 8, 2],
        [8, 8, 3],
      ]);
      final section = setup.teams.first.sections.first;
      expect(section.units.first.type, 'commander');
      expect(section.units.map((unit) => unit.weapon), [
        null,
        'machine_gun',
        'machine_gun',
        null,
        null,
        null,
        null,
        null,
      ]);
      expect(
        setup.teams.first.sections.map((section) => section.serverManaged),
        [false, true, true],
      );
      expect(section.accountId, 'account-${section.id}');
    });
  });

  group('placeLoad', () {
    test('P-02 puts every unit on its own open cell, the teams facing each '
        'other across the middle row', () {
      final (:host, clock: _, snapshots: _) = hostOf();
      const settings = LoadSettings(units: 120);
      final battle = started(host, settings);
      final nav = battle.world.navigation;
      final state = battle.state;

      final cells = [for (final unit in state.units.values) unit.cell!];
      expect(cells.toSet(), hasLength(120));
      for (final unit in state.units.values) {
        expect(unit.location, isA<Deployed>());
        final cell = unit.cell!;
        expect(nav.isWater(cell), isFalse);
        expect(nav.objectsAt(cell), isEmpty);
        final team = state.sections[unit.sectionId]!.team;
        expect(
          team == loadTeams.first ? cell.y < 2500 : cell.y > 2500,
          isTrue,
          reason: '${unit.id} at $cell',
        );
      }
    });
  });

  group('BattleLoad', () {
    test('P-02 plays shots, reloads and moves through the host and times '
        'every second', () async {
      final (:host, :clock, snapshots: _) = hostOf();
      const settings = LoadSettings(
        units: 64,
        duration: Duration(hours: 2),
        seed: 3,
      );
      started(host, settings);

      final report = await BattleLoad(
        host: host,
        clock: clock,
        battleIds: const ['load-1'],
        settings: settings,
      ).run();

      expect(report.shots, greaterThan(100));
      expect(report.moves, greaterThan(0));
      expect(report.reloads, greaterThan(0));
      expect(report.orders, report.shots + report.moves + report.reloads);
      expect(
        report.sent.values.fold(0, (sum, count) => sum + count),
        report.orders,
      );
      expect(report.tickMicros.keys, containsAll([0, 7200]));
      expect(report.hostMicros, greaterThan(0));
      expect(clock.now(), DateTime.utc(2026, 11, 6, 2));
    });

    test('P-02 the same seed gives the same battle, which its log '
        'replays', () async {
      Future<(Battle, LoadReport)> run() async {
        final (:host, :clock, :snapshots) = hostOf();
        const settings = LoadSettings(
          units: 40,
          duration: Duration(minutes: 20),
          seed: 5,
          serverManagedShare: 0.5,
        );
        started(host, settings);
        host.snapshot('load-1');
        await host.settle();
        final report = await BattleLoad(
          host: host,
          clock: clock,
          battleIds: const ['load-1'],
          settings: settings,
        ).run();
        await host.settle();
        return (host['load-1']!, report);
      }

      final (first, report) = await run();
      final (second, _) = await run();

      expect(snapshotOf(second), snapshotOf(first));
      expect(report.orders, greaterThan(0));
    });

    test('P-02 a unit that waits for its weapon goes on once it is '
        'ready', () async {
      final (:host, :clock, snapshots: _) = hostOf();
      const settings = LoadSettings(
        units: 20,
        machineGuns: 0,
        burstShare: 1,
        duration: Duration(seconds: 30),
      );
      started(host, settings);

      final report = await BattleLoad(
        host: host,
        clock: clock,
        battleIds: const ['load-1'],
        settings: settings,
      ).run();

      // Each rifle fires at its rate, so a burst lasts more than a second.
      expect(report.sent.keys.where((second) => second > 1), isNotEmpty);
    });

    test('P-02 skips units off the field, a battle that does not run and '
        'a battle that ended', () async {
      final (:host, :clock, snapshots: _) = hostOf();
      const settings = LoadSettings(units: 40, duration: Duration(hours: 1));
      started(host, settings).change((state) {
        var next = state;
        for (final unit in state.units.values) {
          next = next.withUnit(unit.copyWith(location: const Stored()));
        }
        return next;
      });
      started(host, settings, id: 'load-2').change(
        (state) => state.withVictory(
          VictoryState(
            relicOwners: state.victory!.relicOwners,
            teams: state.victory!.teams,
            winner: const BattleWon(team: 'team-1', kind: VictoryKind.lastHq),
          ),
        ),
      );
      final load = BattleLoad(
        host: host,
        clock: clock,
        battleIds: const ['load-1', 'load-2', 'load-3'],
        settings: settings,
      );
      final report = await load.run();

      expect(report.orders, 0);
    });

    test('P-02 a unit with no open cell ahead tries again later', () async {
      final (:host, :clock, snapshots: _) = hostOf();
      const settings = LoadSettings(
        units: 2,
        burstShare: 0,
        duration: Duration(hours: 2),
      );
      final battle = started(host, settings);
      final nav = battle.world.navigation;
      final edge = [
        for (var x = 0; x < nav.width; x++) CellRef(x, nav.depth - 1),
      ].firstWhere((cell) => !nav.isWater(cell) && nav.objectsAt(cell).isEmpty);
      battle.change(
        (state) => state
            .withUnit(state.units['team-1-s1-u1']!.copyWith(cell: edge))
            .withUnit(
              state.units['team-2-s1-u1']!.copyWith(location: const Stored()),
            ),
      );

      final report = await BattleLoad(
        host: host,
        clock: clock,
        battleIds: const ['load-1'],
        settings: settings,
      ).run();

      expect(report.moves, 0);
    });
  });
}

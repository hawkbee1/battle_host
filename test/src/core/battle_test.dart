import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

void main() {
  late SharedMap map;

  setUp(() {
    map = SharedMap.load(
      id: 'valley',
      host: HostMapLoader(planData.terrain).load(valley),
      terrain: planData.terrain,
    );
  });

  Battle start([BattleSetup? setup]) => Battle.start(
    setup: setup ?? valleySetup(),
    map: map,
    definitions: planData,
  );

  group('Battle.start', () {
    test('HQ-01 places each HQ at the starting point of its team count', () {
      final two = start();
      final three = start(valleySetup(teams: 3));

      expect(
        two.state.teams.values.map((team) => team.hq.cell),
        equals(const [CellRef(0, 0), CellRef(11, 0)]),
      );
      expect(
        three.state.teams.values.map((team) => team.hq.cell),
        equals(const [CellRef(0, 0), CellRef(11, 0), CellRef(0, 7)]),
      );
      for (final team in three.state.teams.values) {
        expect(team.hq.health.current, equals(planData.battle.hq.hp));
        expect(team.hq.pool.value, equals(planData.battle.hq.apMax));
        expect(team.eliminated, isFalse);
      }
    });

    test(
      'RELIC-02 places the relics at their starting cells, with no owner',
      () {
        final relics = start().state.relics.values.toList();

        expect(relics.map((relic) => relic.id), [
          for (var i = 1; i <= 6; i++) 'relic-$i',
        ]);
        expect(relics.last.cell, equals(const CellRef(9, 6, surface: 'sky')));
        for (final relic in relics) {
          expect(relic.owner, isNull);
          expect(relic.capturePot, isNull);
          expect(relic.pushPot, isNull);
        }
      },
    );

    test('UNIT-31 every unit starts in storage with full AP and HP and base '
        'morale (decision 212)', () {
      final battle = start();

      expect(battle.state.units, hasLength(5));
      for (final unit in battle.state.units.values) {
        expect(unit.location, isA<Stored>());
        expect(unit.pool.value, equals(unit.type.stats.apMax));
        expect(unit.pool.recoveryPerHour, equals(1));
        expect(unit.health.current, equals(unit.type.stats.hp));
        expect(unit.morale, equals(planData.combat.morale.base));
      }
    });

    test('UNIT-18 a unit plays its evolved type and keeps its XP and section '
        '(UNIT-30)', () {
      final battle = start();
      final jeep = battle.state.units['jeep-1']!;
      final base = planData.units.unitTypes['jeep']!;

      expect(jeep.type.stats.hp, greaterThan(base.stats.hp));
      expect(jeep.health.current, equals(jeep.type.stats.hp));
      expect(jeep.tree.steps[EvolvableStat.hp], equals(5));
      expect(jeep.xp.earned, equals(1600));
      expect(jeep.sectionId, equals('s-1'));
      expect(battle.state.units['soldier-2']!.tree.steps, isEmpty);
      final section = battle.state.sections['s-1']!;
      expect((
        section.accountId,
        section.team,
        section.money,
        section.xp,
      ), equals(('a-1', 'team-1', 500, 120.0)));
      expect(section.lockedUntil, isNull);
    });

    test('decision 172 plays with its own settings, checked against the '
        'shared definitions', () {
      final settings = BattleSettings.parse(
        File('$planPath/data/battle.yaml')
            .readAsStringSync()
            .replaceFirst('recovery_per_hour: 1', 'recovery_per_hour: 4'),
      );
      final battle = start(valleySetup(settings: settings));

      expect(battle.settings, same(settings));
      expect(battle.state.units['soldier-1']!.pool.recoveryPerHour, equals(4));
      expect(planData.battle.ap.recoveryPerHour, equals(1));
    });

    test('refuses settings the definitions refuse', () {
      final settings = BattleSettings.parse(
        File('$planPath/data/battle.yaml').readAsStringSync().replaceFirst(
          RegExp(r'teams:\s*\n\s*count: \d+'),
          'teams:\n  count: 1',
        ),
      );

      expect(
        () => start(valleySetup(settings: settings)),
        throwsA(isA<GameDataException>()),
      );
    });

    test('refuses a team count the map has no starting points for', () {
      expect(() => start(valleySetup(teams: 4)), throwsArgumentError);
    });

    test('refuses an unknown unit type and a repeated ID', () {
      BattleSetup withUnits(List<UnitSetup> units, {String section = 's-2'}) =>
          BattleSetup(
            battleId: 'b',
            mapId: 'valley',
            seed: 1,
            settings: planData.battle,
            teams: [
              const TeamSetup(
                id: 'red',
                sections: [SectionSetup(id: 's-1', accountId: 'a', units: [])],
              ),
              TeamSetup(
                id: 'blue',
                sections: [
                  SectionSetup(id: section, accountId: 'b', units: units),
                ],
              ),
            ],
          );

      expect(
        () => start(withUnits(const [UnitSetup(id: 'u', type: 'dragon')])),
        throwsArgumentError,
      );
      expect(
        () => start(
          withUnits(const [
            UnitSetup(id: 'u', type: 'soldier'),
            UnitSetup(id: 'u', type: 'medic'),
          ]),
        ),
        throwsArgumentError,
      );
      expect(
        () => start(withUnits(const [], section: 's-1')),
        throwsArgumentError,
      );
      expect(
        () => start(
          valleySetup().copyTeams((teams) => [teams.first, teams.first]),
        ),
        throwsArgumentError,
      );
    });
  });

  group(UnitState, () {
    test('copies itself with the values given changed', () {
      final unit = start().state.units['soldier-1']!;

      final hurt = unit.copyWith(
        location: const Deployed(),
        health: unit.health.damaged(10),
        morale: 40,
      );

      expect(hurt.location, isA<Deployed>());
      expect(hurt.health.current, equals(unit.health.current - 10));
      expect(hurt.morale, equals(40));
      expect(hurt.pool, same(unit.pool));
      expect((hurt.id, hurt.sectionId, hurt.type), (unit.id, 's-1', unit.type));
    });
  });

  group('Battle.advanceTo', () {
    test('COMBAT-02 gives the lazy AP of every unit and HQ at any time', () {
      final battle = start()
        ..change((state) {
          var next = state;
          for (final unit in state.units.values) {
            next = next.withUnit(
              unit.copyWith(
                pool: ApPool(
                  max: unit.pool.max,
                  recoveryPerHour: unit.pool.recoveryPerHour,
                  value: 0,
                  updatedAt: Duration.zero,
                ),
              ),
            );
          }
          return next;
        })
        ..advanceTo(const Duration(hours: 7, minutes: 30));
      for (final id in battle.state.units.keys) {
        expect(battle.apOf(id), equals(7.5), reason: id);
      }
      battle.advanceTo(const Duration(days: 2));
      for (final id in battle.state.units.keys) {
        expect(battle.apOf(id), equals(30), reason: 'COMBAT-01 cap, $id');
      }
      expect(battle.hqApOf('team-1'), equals(planData.battle.hq.apMax));
    });

    test('decision 3 costs nothing for idle units: a day passes with the '
        'state untouched', () {
      final battle = start();
      final before = battle.state;

      for (var hour = 1; hour <= 24; hour++) {
        battle.advanceTo(Duration(hours: hour));
      }

      expect(battle.state, same(before));
      expect(battle.time, equals(const Duration(days: 1)));
      expect(battle.timersFired, isZero);
    });

    test('HQ-35 fires a lock end at its time, a day later', () {
      final battle = start()
        ..change(
          (state) => state.withSection(
            state.sections['s-1']!.lockedTo(const Duration(days: 1)),
          ),
        )
        ..schedule(const Duration(days: 1), const SectionUnlocks('s-1'))
        ..advanceTo(const Duration(hours: 23, minutes: 59));
      expect(
        battle.state.sections['s-1']!.lockedUntil,
        equals(const Duration(days: 1)),
      );
      expect(battle.timers, hasLength(1));

      battle.advanceTo(const Duration(days: 3));
      expect(battle.state.sections['s-1']!.lockedUntil, isNull);
      expect(battle.timersFired, equals(1));
      expect(battle.timers, isEmpty);
    });

    test('refuses to go back in time or to schedule in the past', () {
      final battle = start()..advanceTo(const Duration(hours: 1));

      expect(() => battle.advanceTo(Duration.zero), throwsArgumentError);
      expect(
        () => battle.schedule(Duration.zero, const SectionUnlocks('s-1')),
        throwsArgumentError,
      );
    });

    test('fails on a timer whose section is gone', () {
      final battle = start()
        ..schedule(const Duration(minutes: 1), const SectionUnlocks('s-9'));

      expect(
        () => battle.advanceTo(const Duration(hours: 1)),
        throwsStateError,
      );
    });
  });
}

extension on BattleSetup {
  BattleSetup copyTeams(List<TeamSetup> Function(List<TeamSetup>) change) =>
      BattleSetup(
        battleId: battleId,
        mapId: mapId,
        seed: seed,
        settings: settings,
        teams: change(teams),
      );
}

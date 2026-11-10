import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';
import '../../helpers/plain.dart';

void main() {
  group(FogOfWar, () {
    late FogFixture f;

    setUp(() => f = FogFixture());

    /// Puts [id] in storage.
    void store(String id) => f.battle.change(
      (state) => state.withUnit(
        state.units[id]!.copyWith(location: const Stored(), clearCell: true),
      ),
    );

    /// The sets of every section, as a fresh fog of war computes them.
    Map<String, List<List<String>>> fresh(Battle battle) {
      final fog = FogOfWar(
        battle: battle,
        world: battle.orders.world,
        vision: Vision(planData.terrain),
      );
      return {
        for (final section in battle.state.sections.keys)
          section: _sorted(fog.of(section)),
      };
    }

    Map<String, List<List<String>>> kept(Battle battle) => {
      for (final section in battle.state.sections.keys)
        section: _sorted(battle.orders.fog.of(section)),
    };

    group('what a section sees', () {
      test('MAP-29 a section knows its own units, wherever they are, and '
          'no other unit out of its sight', () {
        expect(
          f.units('s-1'),
          equals({
            'commander-1',
            'soldier-1',
            'scout-1',
            'radio-1',
            'artillery-1',
            'truck-1',
          }),
        );
        expect(
          f.units('s-2'),
          equals({'commander-2', 'soldier-2', 'soldier-4'}),
        );
        expect(f.units('s-3'), equals({'soldier-3'}));
      });

      test('MAP-31 COMBAT-11 a unit out of range is not seen', () {
        f
          ..place('soldier-1', const CellRef(20, 15))
          ..place('soldier-2', const CellRef(34, 15));
        expect(f.units('s-1'), contains('soldier-2'));
        expect(f.units('s-2'), contains('soldier-1'));

        f.place('soldier-2', const CellRef(36, 15));
        expect(f.units('s-1'), isNot(contains('soldier-2')));
      });

      test('MAP-31 decision 59 a unit in fog is not seen', () {
        f
          ..place('soldier-1', const CellRef(20, 15))
          ..place('soldier-2', const CellRef(28, 15));
        expect(f.units('s-1'), contains('soldier-2'));

        f.weather('fog');
        expect(f.units('s-1'), isNot(contains('soldier-2')));

        f.place('soldier-2', const CellRef(26, 15));
        expect(f.units('s-1'), contains('soldier-2'));
      });

      test('MAP-27 a unit behind a forest is not seen', () {
        f
          ..place('soldier-1', const CellRef(10, 5))
          ..place('soldier-2', const CellRef(22, 5));
        expect(f.units('s-1'), isNot(contains('soldier-2')));

        // As far, with no wood in between.
        f.place('soldier-2', const CellRef(10, 17));
        expect(f.units('s-1'), contains('soldier-2'));
      });

      test('MAP-26 a unit behind a hill is not seen, nor fired at', () {
        f
          ..place('soldier-1', const CellRef(45, 15))
          ..place('soldier-2', const CellRef(55, 15));
        expect(f.units('s-1'), isNot(contains('soldier-2')));
        expect(
          f
              .send(const Fire(unitId: 'soldier-1', targetId: 'soldier-2'))
              .refusal
              ?.code,
          equals('target_not_seen'),
        );

        // As far, beside the ridge.
        f
          ..place('soldier-1', const CellRef(45, 5))
          ..place('soldier-2', const CellRef(55, 5));
        expect(f.units('s-1'), contains('soldier-2'));
      });

      test('MAP-33 standing higher, a unit sees farther', () {
        f
          ..place('soldier-1', const CellRef(51, 15))
          ..place('soldier-2', const CellRef(69, 15));
        expect(f.units('s-1'), isNot(contains('soldier-2')));

        f
          ..place('soldier-1', const CellRef(50, 15))
          ..place('soldier-2', const CellRef(68, 15));
        expect(f.units('s-1'), contains('soldier-2'));
      });

      test('UNIT-34 decision 184 observing widens the set, until it ends', () {
        f
          ..weather('fog')
          ..place('scout-1', const CellRef(20, 15))
          ..place('soldier-2', const CellRef(33, 15));
        expect(f.units('s-1'), isNot(contains('soldier-2')));

        expect(f.send(const Observe(unitId: 'scout-1')).refusal, isNull);
        expect(f.units('s-1'), contains('soldier-2'));

        f.wait(const Duration(minutes: 31));
        expect(f.units('s-1'), isNot(contains('soldier-2')));
      });

      test('MAP-30 COMBAT-11 a unit fires only at what it sees itself', () {
        f
          ..place('soldier-1', const CellRef(45, 5))
          ..place('scout-1', const CellRef(45, 3))
          ..place('soldier-2', const CellRef(70, 3));
        // The scout sees it, the soldier is too far: the section knows it.
        expect(f.units('s-1'), contains('soldier-2'));
        expect(
          f
              .send(const Fire(unitId: 'soldier-1', targetId: 'soldier-2'))
              .refusal
              ?.code,
          equals('target_not_seen'),
        );
      });
    });

    group('radios', () {
      setUp(() {
        f
          ..place('soldier-2', const CellRef(20, 15))
          ..place('scout-1', const CellRef(40, 15))
          ..place('soldier-3', const CellRef(40, 5));
      });

      test('UNIT-36 MAP-29 a radio relays a scout report in its range to an '
          'allied section, and not one out of its range', () {
        expect(f.units('s-1'), contains('soldier-2'));
        expect(f.units('s-3'), isNot(contains('soldier-2')));

        f.place('radio-1', const CellRef(40, 10));
        expect(f.fog.reportingScouts('team-1'), equals({'scout-1'}));
        expect(f.units('s-3'), contains('soldier-2'));

        f.place('radio-1', const CellRef(60, 10));
        expect(f.fog.reportingScouts('team-1'), isEmpty);
        expect(f.units('s-3'), isNot(contains('soldier-2')));
      });

      test('UNIT-34 a stored scout or one of the other team reports '
          'nothing', () {
        f.place('radio-1', const CellRef(40, 10));
        store('scout-1');

        expect(f.fog.reportingScouts('team-1'), isEmpty);
        expect(f.fog.reportingScouts('team-2'), isEmpty);
      });

      test('decision 21 a unit of an allied section is seen only when one of '
          'the section units sees it', () {
        f
          ..place('radio-1', const CellRef(40, 10))
          ..place('soldier-1', const CellRef(20, 18));
        // The scout sees soldier-1, but reports enemies only.
        expect(f.units('s-3'), isNot(contains('soldier-1')));

        f.place('soldier-3', const CellRef(30, 18));
        expect(f.units('s-3'), contains('soldier-1'));
        expect(f.units('s-1'), contains('soldier-3'));
      });

      test('COMBAT-12 artillery fires at a position a scout of an allied '
          'section reports through a radio of its team', () {
        f
          ..place('artillery-1', const CellRef(0, 15))
          ..place('radio-1', const CellRef(40, 10))
          ..changeSection('radio-1', 's-3')
          ..changeSection('scout-1', 's-3');
        final target = centreOf(f.battle, const CellRef(30, 15));

        expect(
          f.send(FireAtPosition(unitId: 'artillery-1', target: target)).refusal,
          isNull,
        );

        f
          ..place('radio-1', const CellRef(60, 10))
          ..send(const Reload(unitId: 'artillery-1'))
          ..wait(const Duration(minutes: 1))
          ..changeUnit(
            'artillery-1',
            (unit) => unit.copyWith(
              pool: ApPool.full(
                max: unit.pool.max,
                recoveryDelayS: unit.pool.recoveryDelayS,
                at: f.battle.time,
              ),
            ),
          );
        expect(
          f
              .send(FireAtPosition(unitId: 'artillery-1', target: target))
              .refusal
              ?.code,
          equals('position_not_seen'),
        );
      });
    });

    group('what every section knows', () {
      test('MAP-49 decision 232 the relics, its own HQ, and an enemy HQ only '
          'while seen or reported', () {
        expect(
          f.fog.of('s-1').relics,
          equals({for (var i = 1; i <= 5; i++) 'relic-$i'}),
        );
        expect(
          f.fog.of('s-2').relics,
          equals({for (var i = 1; i <= 5; i++) 'relic-$i'}),
        );
        expect(f.fog.of('s-1').hqs, equals({'team-1'}));
        expect(f.fog.of('s-3').hqs, equals({'team-1'}));

        f
          ..place('scout-1', const CellRef(70, 15))
          ..place('radio-1', const CellRef(70, 10));
        expect(f.fog.of('s-1').hqs, equals({'team-1', 'team-2'}));
        expect(f.fog.of('s-3').hqs, equals({'team-1', 'team-2'}));
        expect(f.fog.of('s-2').hqs, equals({'team-2'}));

        // The HQ moves out of sight.
        f.battle.change(
          (state) => state.withTeam(
            state.teams['team-2']!.withHq(
              HqState(
                cell: const CellRef(40, 0),
                health: state.teams['team-2']!.hq.health,
                pool: state.teams['team-2']!.hq.pool,
              ),
            ),
          ),
        );
        expect(f.fog.of('s-1').hqs, equals({'team-1'}));
        expect(f.fog.of('s-3').hqs, equals({'team-1'}));
      });

      test('HQ-18 an eliminated HQ is seen by nobody', () {
        f.place('soldier-1', const CellRef(70, 19));
        expect(f.fog.of('s-1').hqs, contains('team-2'));

        f.battle.change(
          (state) => state.withTeam(
            TeamState(
              id: 'team-2',
              hq: state.teams['team-2']!.hq,
              eliminated: true,
            ),
          ),
        );
        expect(f.fog.of('s-1').hqs, equals({'team-1'}));
      });

      test('throws an $ArgumentError for a section not in the battle', () {
        expect(() => f.fog.of('s-9'), throwsArgumentError);
      });
    });

    group('units leaving the field', () {
      setUp(() {
        f
          ..place('soldier-1', const CellRef(20, 15))
          ..place('soldier-2', const CellRef(25, 15));
      });

      test('HQ-29 a stored unit leaves every set but its own section', () {
        expect(f.units('s-2'), contains('soldier-1'));

        store('soldier-1');
        expect(f.units('s-2'), isNot(contains('soldier-1')));
        expect(f.units('s-1'), contains('soldier-1'));
      });

      test('COMBAT-54 a carried unit sees from its transport and is not seen '
          'on its own', () {
        f
          ..place('truck-1', const CellRef(21, 15))
          ..changeUnit(
            'soldier-1',
            (unit) => unit.copyWith(location: const Carried('truck-1')),
          );
        expect(f.units('s-2'), contains('truck-1'));
        expect(f.units('s-2'), isNot(contains('soldier-1')));
        expect(f.units('s-1'), contains('soldier-2'));
      });

      test('a unit gone from the battle leaves every set', () {
        f.battle.change((state) => state.withoutUnit('soldier-1'));
        expect(f.units('s-2'), isNot(contains('soldier-1')));
        expect(f.units('s-1'), isNot(contains('soldier-1')));
      });

      test('SOC-29 a unit that changes section is known as its new '
          'section unit', () {
        f.changeSection('soldier-2', 's-1');
        expect(f.units('s-1'), contains('soldier-2'));
        expect(f.units('s-2'), isNot(contains('soldier-2')));
      });
    });

    group('sync', () {
      test('runs once per tick of the host, and not when asked not to', () {
        f.place('soldier-2', const CellRef(5, 5));
        f.clock.advance(const Duration(seconds: 1));
        f.host.advance(see: false);
        expect(f.fog.linesChecked, isZero);

        f.wait(const Duration(seconds: 1));
        expect(f.fog.linesChecked, isPositive);
      });

      test('checks nothing again when nothing changed, and only what moved '
          'when one unit moves', () {
        for (final (index, id) in [
          'soldier-1',
          'scout-1',
          'radio-1',
          'soldier-3',
          'soldier-2',
          'soldier-4',
          'commander-2',
        ].indexed) {
          f.place(id, CellRef(20 + index * 2, 12 + index % 3));
        }
        f.wait(const Duration(seconds: 1));
        final first = f.fog.linesChecked;

        f.wait(const Duration(seconds: 1));
        expect(f.fog.linesChecked, equals(first));

        f
          ..place('soldier-4', const CellRef(22, 18))
          ..wait(const Duration(seconds: 1));
        // At most the lines from and to the one unit that moved, and from it
        // to the HQs.
        final units = f.battle.state.units.values.where((u) => u.onField);
        expect(
          f.fog.linesChecked - first,
          lessThanOrEqualTo((units.length - 1) * 2 + 2),
        );
        expect(kept(f.battle), equals(fresh(f.battle)));
      });

      test('MAP-28 an object destroyed opens the lines across it', () {
        f
          ..place('soldier-1', const CellRef(55, 5))
          ..place('soldier-2', const CellRef(65, 5));
        expect(f.units('s-1'), isNot(contains('soldier-2')));

        final worlds = f.battle.orders.worlds;
        worlds.hit(worlds.objectsOn(const CellRef(60, 5)).single, 1000000000);
        expect(f.units('s-1'), contains('soldier-2'));
      });

      test('keeps the sets a fresh fog of war computes, through moves, '
          'storage, weather, craters and observing', () {
        final random = XorshiftRandom(5);
        final ids = f.battle.state.units.keys.toList();
        for (var round = 0; round < 40; round++) {
          final id = ids[(random.nextDouble() * ids.length).floor()];
          final roll = random.nextDouble();
          if (roll < 0.1) {
            store(id);
          } else if (roll < 0.15) {
            f.weather(random.nextDouble() < 0.5 ? 'fog' : 'clear');
          } else if (roll < 0.2) {
            f
              ..place('artillery-1', const CellRef(30, 15))
              ..place('scout-1', const CellRef(34, 15))
              ..send(
                FireAtPosition(
                  unitId: 'artillery-1',
                  target: centreOf(f.battle, const CellRef(38, 15)),
                ),
              );
          } else if (roll < 0.25) {
            f
              ..place('scout-1', const CellRef(30, 14))
              ..send(const Observe(unitId: 'scout-1'));
          } else {
            f.place(
              id,
              CellRef(
                20 + (random.nextDouble() * 50).floor(),
                (random.nextDouble() * plainDepth).floor(),
              ),
            );
          }
          f.wait(const Duration(minutes: 7));
          expect(kept(f.battle), equals(fresh(f.battle)), reason: '$round');
        }
      });
    });

    group('recovery', () {
      test('a recovered host gives the same visible sets as a host that '
          'never stopped', () async {
        f
          ..place('soldier-1', const CellRef(20, 15))
          ..place('scout-1', const CellRef(40, 15))
          ..place('radio-1', const CellRef(40, 10))
          ..place('soldier-3', const CellRef(40, 5))
          ..place('soldier-2', const CellRef(30, 18))
          ..place('soldier-4', const CellRef(45, 2));
        f.host.snapshot('f-1');
        f
          ..send(
            Move(
              unitId: 'soldier-2',
              to: centreOf(f.battle, const CellRef(25, 15)),
            ),
            section: 's-2',
          )
          ..send(const Observe(unitId: 'scout-1'))
          ..wait(const Duration(minutes: 1));
        await f.host.settle();

        final other = f.hostOn(f.wal, f.logs, f.snapshots);
        final recovered = await other.recover('f-1');

        expect(kept(recovered), equals(kept(f.battle)));
        expect(kept(recovered)['s-3']!.first, contains('soldier-2'));
      });
    });
  });
}

/// The units and HQs of [sight], sorted, to compare.
List<List<String>> _sorted(SectionSight sight) => [
  sight.units.toList()..sort(),
  sight.hqs.toList()..sort(),
];

extension on FogFixture {
  void changeUnit(String id, UnitState Function(UnitState unit) change) =>
      battle.change((state) => state.withUnit(change(state.units[id]!)));

  void changeSection(String id, String section) =>
      changeUnit(id, (unit) => unit.copyWith(sectionId: section));
}

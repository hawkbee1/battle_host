import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' show CellRef;
import 'package:battle_protocol/battle_protocol.dart'
    hide CraterDug, ObjectDestroyed;
import 'package:battle_protocol/battle_protocol.dart'
    as wire
    show CraterDug, ObjectDestroyed;
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';
import '../../helpers/plain.dart';
import '../../helpers/view_holder.dart';

void main() {
  group(SectionViews, () {
    late FogFixture f;

    setUp(() {
      f = FogFixture()
        ..place('soldier-1', const CellRef(55, 6))
        ..place('soldier-2', const CellRef(56, 6));
    });

    test('COMBAT-02 the AP view of a unit carries the rate of its recovery '
        'delay, per hour', () {
      final views = SectionViews(f.battle);
      final unit = f.battle.state.units['soldier-1']!;
      final fast = unit.copyWith(
        pool: ApPool(
          max: unit.pool.max,
          recoveryDelayS: 1,
          value: unit.pool.value,
          updatedAt: unit.pool.updatedAt,
        ),
      );

      final slow = views.unit(unit, unit.sectionId).private!.ap;
      final quick = views.unit(fast, unit.sectionId).private!.ap;

      expect(slow.perHour, 1);
      expect(quick.perHour, 3600);
      expect((quick.value, quick.max), (slow.value, slow.max));
    });

    group('roster', () {
      test('ECO-04 ECO-05 lists what a commander buys at the prices of '
          'economy.yaml, in the order of units.yaml: no commander, no guild '
          'camp', () {
        final roster = SectionViews(f.battle).roster();

        expect(roster.units.map((unit) => unit.unitType), [
          'soldier',
          'engineer',
          'scout',
          'medic',
          'artillery',
          'radio',
          'jeep',
          'tank',
          'truck',
          'helicopter',
          'boat',
        ]);
        for (final unit in roster.units) {
          expect(unit.price, planData.economy.priceOf(unit.unitType));
          expect(
            unit.category,
            planData.units.unitTypes[unit.unitType]!.category,
          );
        }
        final radio = roster.units.singleWhere((u) => u.unitType == 'radio');
        expect(radio.category, 'radio');
        expect(radio.weapons, isEmpty);
      });

      test('COMBAT-26 each unit type lists the weapons it may equip', () {
        final roster = SectionViews(f.battle).roster();

        expect(
          roster.units.singleWhere((u) => u.unitType == 'soldier').weapons,
          ['rifle', 'machine_gun', 'anti_tank', 'anti_air'],
        );
        expect(
          roster.units.singleWhere((u) => u.unitType == 'engineer').weapons,
          ['rifle', 'explosive'],
        );
      });

      test('COMBAT-27 lists every weapon type at its price', () {
        final roster = SectionViews(f.battle).roster();

        expect(
          roster.weapons.map((weapon) => weapon.weapon),
          planData.combat.weaponTypes.keys,
        );
        for (final weapon in roster.weapons) {
          expect(weapon.price, planData.economy.priceOf(weapon.weapon));
        }
      });

      test('UNIT-44 the test unit is listed only where the battle allows '
          'test units, at 0 w€', () {
        final without = SectionViews(f.battle).roster();
        final allowed = OrdersFixture(
          settings: planData.settingsWith({'test_units': true}),
        );
        final with_ = SectionViews(allowed.battle).roster();

        expect(
          without.units.map((u) => u.unitType),
          isNot(contains('test_unit')),
        );
        final test = with_.units.singleWhere((u) => u.unitType == 'test_unit');
        expect((test.price, test.category), (0, 'soldier'));
        expect(
          with_.units.map((u) => u.unitType).where((t) => t != 'test_unit'),
          without.units.map((u) => u.unitType),
        );
      });

      test('decision 237 the roster is the same for every section: it holds '
          'nothing of any unit or section', () {
        final views = SectionViews(f.battle);

        expect(views.roster(), equals(views.roster()));
        final text = const JsonProtocolCodec().encodeHostMessage(
          views.roster(),
        );
        for (final id in f.battle.state.units.keys) {
          expect(text, isNot(contains(id)));
        }
        for (final id in f.battle.state.sections.keys) {
          expect(text, isNot(contains(id)));
        }
      });
    });

    test('MAP-08 a late joiner gets the whole delta layer: the craters, the '
        'structures built, the objects damaged and destroyed, as one present '
        'from the start built it from the events', () {
      final worlds = f.battle.orders.worlds;
      final stream = UpdateStream(f.battle);
      final fromStart = ViewHolder();
      stream.subscribe('s-3', fromStart);
      void heard(List<BattleEvent> events) => stream
        ..hear(LogEntry(at: f.battle.time, events: events))
        ..flush();
      final point = SectionViews(f.battle).positionOf(const CellRef(40, 5));
      heard(
        worlds.bombard(
          planData.combat.weaponTypes['artillery']!,
          Vec3(point.x, point.y, point.z),
        ),
      );
      worlds.built('site-1', 'wall', const [CellRef(10, 12)]);
      heard(const [
        StructureBuilt(
          siteId: 'site-1',
          structure: 'wall',
          cells: [Cell(10, 12)],
        ),
      ]);
      heard(worlds.hit(worlds.objectsOn(const CellRef(15, 2)).single, 10));
      heard(worlds.hit(worlds.objectsOn(const CellRef(60, 5)).single, 1000000));

      final late = ViewHolder();
      stream.subscribe('s-3', late);
      final view = late.received.first as SectionView;

      expect(view.world.map((e) => e.runtimeType).toSet(), {
        wire.CraterDug,
        StructureBuilt,
        ObjectDamaged,
        wire.ObjectDestroyed,
      });
      expect(late.craters, isNotEmpty);
      expect(late.craters, equals(fromStart.craters));
      expect(late.built, equals(fromStart.built));
      expect(late.damaged, equals(fromStart.damaged));
      expect(late.destroyed, equals(fromStart.destroyed));
    });

    test(
      'RELIC-16 decision 100 the whole view carries the victory countdown',
      () {
        f.battle.change(
          (state) => state.withVictory(
            VictoryState(
              relicOwners: state.victory!.relicOwners,
              teams: state.victory!.teams,
              hold: const RelicHold(
                team: 'team-2',
                since: Duration(hours: 1),
                winsAt: Duration(hours: 25),
              ),
            ),
          ),
        );
        final holder = ViewHolder();
        f.host.subscribe('f-1', 's-3', holder);

        expect(
          (holder.received.first as SectionView).hold,
          const HoldView(
            team: 'team-2',
            since: Duration(hours: 1),
            winsAt: Duration(hours: 25),
          ),
        );
      },
    );

    test('COMBAT-37 a prisoner is known to its captor as held, and to its own '
        'section with its place', () {
      f.battle.change(
        (state) => state.withUnit(
          state.units['soldier-2']!.copyWith(
            location: const Prisoner('s-1'),
            clearCell: true,
          ),
        ),
      );
      final captor = ViewHolder();
      final owner = ViewHolder();
      f.host
        ..subscribe('f-1', 's-1', captor)
        ..subscribe('f-1', 's-2', owner);

      expect(
        (captor.received.first as SectionView).section.prisoners,
        equals([const JoinedUnit(unitId: 'soldier-2', unitType: 'soldier')]),
      );
      final held = (owner.received.first as SectionView).units.firstWhere(
        (unit) => unit.unitId == 'soldier-2',
      );
      expect(held.private!.place, UnitPlace.prisoner);
      expect(held.position, isNull);
    });
  });
}

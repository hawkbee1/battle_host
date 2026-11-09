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

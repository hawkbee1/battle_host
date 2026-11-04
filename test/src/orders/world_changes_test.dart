import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart'
    hide CraterDug, ObjectDestroyed;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';

void main() {
  late OrdersFixture f;

  setUp(() => f = OrdersFixture());

  const foot = PathMover(apPerM: 1, modes: ['foot']);
  const sky = 'sky';

  List<BattleEvent> eventsOf(Order order) {
    final handled = f.send(order);
    expect(handled.refusal, isNull, reason: '$order');
    return handled.events;
  }

  /// Puts the engineer of [battle] on [cell] with a charge and enough HP
  /// to survive it.
  void armOn(Battle battle, CellRef cell) => battle.change(
    (state) => state.withUnit(
      state.units['engineer-1']!.copyWith(
        location: const Deployed(),
        cell: cell,
        health: const Health(current: 1000, max: 1000),
        weapon: WeaponState.ready(planData.combat.weaponTypes['explosive']!),
      ),
    ),
  );

  /// Has the engineer's charge go off on [cell].
  List<BattleEvent> charge(CellRef cell) {
    armOn(f.battle, cell);
    return eventsOf(
      FireAtPosition(unitId: 'engineer-1', target: centreOf(f.battle, cell)),
    );
  }

  MapObject authored(String type) =>
      f.battle.map.host.objects.values.firstWhere((o) => o.type == type);

  World world() => f.battle.orders.world;

  double? costOf(CellRef from, CellRef to, {PathMover mover = foot}) =>
      f.battle.world.paths.find(mover: mover, from: from, to: to)?.cost;

  group('the delta layer', () {
    test('MAP-09 MAP-28 a tree destroyed by fire stops hiding what is behind '
        'it and never regrows; MAP-44 it changes no path', () {
      const tree = CellRef(1, 4);
      final across = world().sightLine(
        const CellRef(0, 4),
        const CellRef(2, 4),
      );
      final pathBefore = costOf(const CellRef(0, 4), const CellRef(2, 4));
      expect(across.forestCrossedM, greaterThan(0));
      expect(world().coverOn(tree), Cover.partial);

      final events = charge(tree);

      expect(
        events,
        contains(const ObjectDestroyed(object: 'tree', cells: [Cell(1, 4)])),
      );
      expect(
        world()
            .sightLine(const CellRef(0, 4), const CellRef(2, 4))
            .forestCrossedM,
        equals(0),
      );
      expect(world().coverOn(tree), Cover.none);
      expect(costOf(const CellRef(0, 4), const CellRef(2, 4)), pathBefore);
      expect(f.battle.state.delta.destroyed, contains(authored('tree').id));
      expectReplay(f, prepare: (battle) => armOn(battle, tree));
    });

    test('MAP-06 a wall built changes a path and a sight line', () {
      final before = costOf(const CellRef(3, 3), const CellRef(3, 5));
      eventsOf(
        const Build(
          unitId: 'engineer-1',
          structure: 'wall',
          cells: [Cell(3, 4)],
        ),
      );
      f.wait(const Duration(minutes: 5));

      expect(f.battle.world.ownsGrid, isTrue);
      expect(
        costOf(const CellRef(3, 3), const CellRef(3, 5)),
        greaterThan(before!),
      );
      expect(
        world().sightLine(const CellRef(3, 3), const CellRef(3, 5)).obstacles,
        contains(
          isA<ObjectObstacle>().having((o) => o.objectType, 'type', 'wall'),
        ),
      );
      final built = f.battle.state.delta.built['wall@(3, 4)']!;
      expect((built.kind, built.hp), (FeatureKind.object, 200));
      expect(
        f
            .send(
              Move(
                unitId: 'scout-1',
                to: centreOf(f.battle, const CellRef(3, 5)),
              ),
            )
            .refusal,
        isNull,
      );
      expect(f.unit('scout-1').cell, const CellRef(3, 5));
      expectReplay(f);
    });

    test('MAP-07 MAP-46 MAP-09 an artillery shot digs a crater that changes a '
        'path, a sight line and cover', () {
      // This seed's shot lands on the valley.
      f = OrdersFixture(seed: 20);
      final events = eventsOf(
        FireAtPosition(
          unitId: 'artillery-1',
          target: centreOf(f.battle, const CellRef(6, 4)),
        ),
      );

      final dug = events.whereType<CraterDug>().single;
      expect(
        dug.radiusM,
        planData.combat.weaponTypes['artillery']!.splashRadiusM,
      );
      expect(dug.depthM, planData.terrain.craters.depthPerShotM);
      final cell = world().cellAt(dug.at)!;
      final navigation = f.battle.world.navigation;
      final ground = f.battle.map.host.navigation;
      expect(
        navigation.cellAt(cell)!.height,
        lessThan(ground.cellAt(cell)!.height),
      );
      expect(world().coverOn(cell), Cover.partial);
      expect(
        f.battle.world.navigation.craters.single.depthM,
        lessThanOrEqualTo(planData.terrain.craters.maxDepthM),
      );
      final from = CellRef(cell.x - 1, cell.y);
      expect(
        costOf(from, cell),
        isNot(
          Pathfinder(
            map: ground,
            cost: f.battle.map.cost,
            rules: f.battle.world.rules,
          ).find(mover: foot, from: from, to: cell)?.cost,
        ),
      );
      expect(world().sightLine(from, cell).heightAboveTargetM, greaterThan(0));
      expectReplay(f);
    });

    test('MAP-10 an object hit keeps its HP until it is destroyed', () {
      final ladder = authored('ladder');
      final building = authored('building');
      final hit = f.battle.orders.worlds.hit(building, 100);
      expect(
        hit,
        equals([
          ObjectDamaged(
            object: 'building',
            cells: [for (final c in building.cells) Cell(c.x, c.y)],
            hp: building.hp - 100,
          ),
        ]),
      );
      expect(f.battle.state.delta.hp[building.id], building.hp - 100);
      // A charge on its east cell reaches its west cell too, further off.
      final events = charge(building.cells.last);
      expect(
        events.whereType<ObjectDamaged>().single.hp,
        lessThan(building.hp - 100),
      );
      expect(f.battle.orders.worlds.hit(ladder, 0), isEmpty);
    });

    test('MAP-37 a destroyed ladder strands the units on the island', () {
      final ladder = authored('ladder');
      final down = costOf(
        const CellRef(8, 5, surface: sky),
        const CellRef(7, 5),
      );
      expect(down, isNotNull);

      final events = charge(ladder.cells.first);

      expect(
        events,
        contains(
          const ObjectDestroyed(
            object: 'ladder',
            cells: [
              Cell(7, 5),
              Cell(8, 5, island: sky),
            ],
          ),
        ),
      );
      final after = costOf(
        const CellRef(8, 5, surface: sky),
        const CellRef(7, 5),
      );
      expect(after == null || after > down!, isTrue);
    });

    test('RELIC-26 a destroyed reinforced bridge loses the relic on it', () {
      final bridge = authored('reinforced_bridge');
      f.battle.change(
        (state) => state
            .withDelta(state.delta.withChanges(const [], hp: (bridge.id, 1)))
            .withRelic(
              state.relics['relic-2']!.copyWith(cell: bridge.cells.first),
            ),
      );

      final events = charge(bridge.cells.first);

      expect(events, contains(const RelicLost(relicId: 'relic-2')));
      expect(f.battle.state.relics, isNot(contains('relic-2')));
    });

    test('MAP-08 a world loaded from the delta layer is the live one', () {
      f = OrdersFixture(seed: 20);
      eventsOf(
        const Build(
          unitId: 'engineer-1',
          structure: 'wall',
          cells: [Cell(3, 4)],
        ),
      );
      f.wait(const Duration(minutes: 5));
      charge(const CellRef(1, 4));
      eventsOf(
        FireAtPosition(
          unitId: 'artillery-1',
          target: centreOf(f.battle, const CellRef(6, 4)),
        ),
      );

      final loaded = BattleWorld.load(f.battle.map, f.battle.state.delta);
      final live = f.battle.world.navigation;
      expect(loaded.navigation.objects, equals(live.objects));
      expect(loaded.navigation.craters, hasLength(live.craters.length));
      expect(loaded.ownsGrid, isTrue);
      expect(
        BattleWorld.load(f.battle.map, const WorldDelta()).ownsGrid,
        isFalse,
      );
    });

    test('decision 89 an object that is not destructible takes no damage', () {
      final terrain = File('$planPath/data/terrain.yaml').readAsStringSync();
      final definitions = GameData.parse(
        units: File('$planPath/data/units.yaml').readAsStringSync(),
        combat: File('$planPath/data/combat.yaml').readAsStringSync(),
        terrain: terrain.replaceFirst(
          'conceals: forest, destructible: true',
          'conceals: forest, destructible: false',
        ),
        battle: File('$planPath/data/battle.yaml').readAsStringSync(),
        economy: File('$planPath/milestones/economy.yaml').readAsStringSync(),
        medals: File('$planPath/data/medals.yaml').readAsStringSync(),
      );
      final battle = Battle.start(
        setup: ordersSetup(),
        map: f.battle.map,
        definitions: definitions,
      );

      expect(battle.orders.worlds.hit(authored('tree'), 1000), isEmpty);
    });
  });

  group('built structures', () {
    test('MAP-23 a bridge is a construction; a ladder to an island is a '
        'link', () {
      final worlds = f.battle.orders.worlds
        ..built('bridge@(5, 3)', 'bridge', const [CellRef(5, 3)])
        ..built('ladder@(10, 4)', 'ladder', const [
          CellRef(10, 4),
          CellRef(10, 5, surface: sky),
        ]);

      final built = f.battle.state.delta.built;
      expect(built['bridge@(5, 3)']!.kind, FeatureKind.construction);
      expect(built['ladder@(10, 4)']!.kind, FeatureKind.link);
      expect(
        f.battle.world.navigation.constructionsAt(const CellRef(5, 3)),
        contains('bridge'),
      );
      expect(worlds.objectsOn(const CellRef(10, 4)).single.type, 'ladder');
      expect(
        worlds.hit(built['bridge@(5, 3)']!, 1000).single,
        isA<ObjectDestroyed>(),
      );
      expect(worlds.objectsOn(const CellRef(5, 3)), isEmpty);
    });
  });
}

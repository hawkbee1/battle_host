import 'dart:math' as math;

import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_world.dart';
import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_host/src/orders/relics.dart';
import 'package:battle_host/src/orders/world.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart' as wire;
import 'package:battle_rules/battle_rules.dart';

/// The constructions of `terrain.yaml`: they change how a cell is crossed
/// (MAP-23, MAP-21).
const Set<String> constructionTypes = {...bridgeTypes, roadConstruction};

/// {@template world_changes}
/// The changes of a battle's world (M5 Issue 14, MAP-06 to MAP-10, MAP-28,
/// MAP-37, MAP-46): constructions built, objects hit and destroyed, with
/// the HP of `terrain.yaml`, and craters dug by the weapons that deform
/// terrain. Each change goes into the delta layer of the state and into the
/// battle's world, which the paths, sight lines and shot tracing read.
///
/// An object takes a bombard shot's splash damage like a unit, and a
/// first-person shot that stops on it damages it (assumed, Q-MAP-19).
/// {@endtemplate}
final class WorldChanges {
  /// {@macro world_changes}
  new({required this.battle, required this.world, required this.relics})
    : _damage = Damage(battle.definitions.combat);

  /// The battle.
  final Battle battle;

  /// Its world geometry.
  final World world;

  /// Its relics, which a destroyed reinforced bridge may take with it.
  final Relics relics;

  final Damage _damage;

  TerrainData get _terrain => battle.definitions.terrain;
  WorldDelta get _delta => battle.state.delta;

  /// The objects standing on [cell]: the map's and those built, less those
  /// destroyed.
  List<MapObject> objectsOn(CellRef cell) => [
    for (final object in battle.map.objectsByCell[cell] ?? const <MapObject>[])
      if (!_delta.destroyed.contains(object.id)) object,
    for (final object in _delta.built.values)
      if (object.cells.contains(cell) && !_delta.destroyed.contains(object.id))
        object,
  ];

  void _record(WorldDelta delta, List<WorldChange> changes) {
    battle.change((state) => state.withDelta(delta));
    changes.forEach(battle.world.apply);
  }

  /// The [structure] an engineer finished on [cells] as [siteId] joins the
  /// world: a wall or a trap as an object, a bridge or a road as a
  /// construction, a ladder or a bridge to an island as a link.
  void built(String siteId, String structure, List<CellRef> cells) {
    final type = _terrain.objects[structure]!;
    final link =
        cells.length == 2 &&
        (structure == 'ladder' || bridgeTypes.contains(structure));
    final kind = link
        ? FeatureKind.link
        : constructionTypes.contains(structure)
        ? FeatureKind.construction
        : FeatureKind.object;
    final object = MapObject(
      id: siteId,
      type: structure,
      kind: kind,
      cells: List.unmodifiable(cells),
      hp: type.hp,
      armorType: type.armorType,
    );
    final changes = switch (kind) {
      FeatureKind.object => [
        for (final cell in cells) ObjectBuilt(cell, structure),
      ],
      FeatureKind.construction => [
        for (final cell in cells) ConstructionBuilt(cell, structure),
      ],
      FeatureKind.link => [
        LinkBuilt(
          SurfaceLink(
            kind: linkKinds[structure]!,
            from: cells.first,
            to: cells.last,
          ),
        ),
      ],
    };
    _record(_delta.withChanges(changes, built: object), changes);
  }

  /// [object] takes [amount] damage (MAP-10): hit, or destroyed at 0 HP. A
  /// destroyed object leaves the world and never regrows (MAP-09, MAP-28,
  /// MAP-37); a reinforced bridge takes the relic or HQ on it (RELIC-26,
  /// HQ-23). An object that is not destructible takes none.
  List<wire.BattleEvent> hit(MapObject object, double amount) {
    if (amount <= 0 || !_terrain.objects[object.type]!.destructible) {
      return const [];
    }
    final cells = [for (final cell in object.cells) _wire(cell)];
    final hp = (_delta.hp[object.id] ?? object.hp) - amount;
    if (hp > 0) {
      battle.change(
        (state) =>
            state.withDelta(_delta.withChanges(const [], hp: (object.id, hp))),
      );
      return [wire.ObjectDamaged(object: object.type, cells: cells, hp: hp)];
    }
    final changes = switch (object.kind) {
      FeatureKind.object => [
        for (final cell in object.cells) ObjectDestroyed(cell, object.type),
      ],
      FeatureKind.construction => [
        for (final cell in object.cells)
          ConstructionDestroyed(cell, object.type),
      ],
      FeatureKind.link => [
        LinkDestroyed(
          kind: linkKinds[object.type]!,
          from: object.cells.first,
          to: object.cells.last,
        ),
      ],
    };
    _record(_delta.withChanges(changes, destroyed: object.id), changes);
    return [
      wire.ObjectDestroyed(object: object.type, cells: cells),
      if (object.type == 'reinforced_bridge')
        ...relics.bridgeDestroyed(object.cells),
    ];
  }

  /// The splash of [weapon] landed at [point] hits every object within its
  /// radius, the nearer the harder (COMBAT-55); a weapon that deforms
  /// terrain digs a crater there (MAP-07, MAP-46).
  List<wire.BattleEvent> bombard(WeaponType weapon, Vec3 point) {
    final radius = weapon.splashRadiusM!;
    final size = world.cellSizeM;
    final near = <String, MapObject>{};
    for (
      var y = ((point.y - radius) / size).floor();
      y <= ((point.y + radius) / size).floor();
      y++
    ) {
      for (
        var x = ((point.x - radius) / size).floor();
        x <= ((point.x + radius) / size).floor();
        x++
      ) {
        final cell = CellRef(x, y);
        if (battle.world.navigation.cellAt(cell) == null) continue;
        for (final object in objectsOn(cell)) {
          near[object.id] = object;
        }
      }
    }
    final events = <wire.BattleEvent>[
      for (final object in near.values)
        ...hit(
          object,
          _damage.splash(
            weapon,
            DamageTarget(armorType: object.armorType),
            _nearest(object, point),
          ),
        ),
    ];
    final ground = CellRef((point.x / size).floor(), (point.y / size).floor());
    if (weapon.deformsTerrain &&
        battle.world.navigation.cellAt(ground) != null) {
      events.addAll(_dig(weapon, point));
    }
    return events;
  }

  List<wire.BattleEvent> _dig(WeaponType weapon, Vec3 point) {
    final craters = _terrain.craters;
    final crater = Crater(
      centreXM: point.x,
      centreYM: point.y,
      radiusM: weapon.splashRadiusM!,
      // MAP-09: never deeper than max_depth_m.
      depthM: math.min(craters.depthPerShotM, craters.maxDepthM),
    );
    final changes = <WorldChange>[CraterDug(crater)];
    _record(_delta.withChanges(changes), changes);
    return [
      wire.CraterDug(
        at: wire.Position.metres(point.x, point.y, point.z),
        radiusM: crater.radiusM,
        depthM: crater.depthM,
      ),
    ];
  }

  /// A first-person shot of [weapon] stopped at [point]: the object that
  /// blocks sight there takes its hit (COMBAT-14, COMBAT-53); the ground
  /// takes nothing.
  List<wire.BattleEvent> obstacleHit(WeaponType weapon, Vec3 point) {
    final cell = CellRef(
      (point.x / world.cellSizeM).floor(),
      (point.y / world.cellSizeM).floor(),
    );
    final blocking = objectsOn(cell)
        .where((object) => _terrain.objects[object.type]!.blocksLos)
        .firstOrNull;
    if (blocking == null) return const [];
    return hit(
      blocking,
      _damage.hit(weapon, DamageTarget(armorType: blocking.armorType)),
    );
  }

  /// The horizontal distance from [point] to the nearest cell centre of
  /// [object].
  double _nearest(MapObject object, Vec3 point) => object.cells
      .map((cell) {
        final centre = world.pointOf(cell);
        return math.sqrt(
          math.pow(centre.x - point.x, 2) + math.pow(centre.y - point.y, 2),
        );
      })
      .reduce(math.min);

  static wire.Cell _wire(CellRef cell) => wire.Cell(
    cell.x,
    cell.y,
    island: cell.surface == groundSurface ? null : cell.surface,
  );
}

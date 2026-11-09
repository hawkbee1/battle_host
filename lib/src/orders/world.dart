import 'dart:math' as math;

import 'package:battle_host/src/core/battle_world.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart' as wire;
import 'package:battle_rules/battle_rules.dart';

/// {@template world}
/// The geometry of a battle's world on its shared map: the cell under a
/// position, a unit's point, distances, sight lines (MAP-29) and the
/// obstacles that stop a first-person shot (COMBAT-14).
///
/// A unit stands at the centre of its cell, on its surface; a flying unit
/// flies at the altitude limit of decision 142. Built structures join the
/// world with the delta layer (M5.14).
/// {@endtemplate}
final class World implements ObstacleQuery {
  /// {@macro world}
  new({required this.battle, required this.terrain});

  /// The battle's world, changes included.
  final BattleWorld battle;

  /// The terrain data.
  final TerrainData terrain;

  NavigationMap get _nav => battle.navigation;

  /// The side of a cell, in metres.
  double get cellSizeM => _nav.cellSizeM;

  /// The cell under [position]: on a floating island when one covers it
  /// and the position is nearer its surface than the ground's; null off the
  /// map.
  CellRef? cellAt(wire.Position position) {
    final x = (position.x / cellSizeM).floor();
    final y = (position.y / cellSizeM).floor();
    final ground = _nav.cellAt(CellRef(x, y));
    if (ground == null) return null;
    for (final MapEntry(key: name, value: cells) in _nav.islands.entries) {
      final island = cells[(x, y)];
      if (island != null &&
          (position.z - island.height).abs() <
              (position.z - ground.height).abs()) {
        return CellRef(x, y, surface: name);
      }
    }
    return CellRef(x, y);
  }

  /// [cell] on this map's grid; null off the map.
  CellRef? cellOf(wire.Cell cell) {
    final ref = CellRef(cell.x, cell.y, surface: cell.island ?? groundSurface);
    return _nav.cellAt(ref) == null ? null : ref;
  }

  /// The point of a unit on [cell].
  Vec3 pointOf(CellRef cell, {bool flying = false}) => Vec3(
    (cell.x + 0.5) * cellSizeM,
    (cell.y + 0.5) * cellSizeM,
    flying ? battle.rules.altitudeLimitM : _nav.cellAt(cell)!.height,
  );

  /// The horizontal distance between the centres of [a] and [b], in
  /// metres.
  double distanceM(CellRef a, CellRef b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)) * cellSizeM;

  /// The terrain type of [cell].
  String terrainOf(CellRef cell) => _nav.cellAt(cell)!.terrain;

  /// The objects on [cell].
  Set<String> objectsOn(CellRef cell) => _nav.objectsAt(cell);

  /// Whether a target on [cell] has partial cover: an object that conceals
  /// it, a tree, or a crater it stands in (COMBAT-53, MAP-07). Under
  /// orders, full cover is never given: it would leave the 5 % minimum
  /// anyway (decision 135).
  Cover coverOn(CellRef cell) =>
      objectsOn(cell)
              .any((object) => terrain.objects[object]?.conceals != null) ||
          _inCrater(cell)
      ? Cover.partial
      : Cover.none;

  /// Whether [cell] is dug by a crater: craters dig the ground only
  /// (MAP-46).
  bool _inCrater(CellRef cell) =>
      cell.surface == groundSurface &&
      _nav.cellAt(cell)!.height <
          _nav.ground[cell.y * _nav.width + cell.x].height;

  /// The sight line from [from] to [to] (MAP-29): its length, the
  /// observer's terrain and height above the target, and, between the two
  /// cells, the forest it crosses and the terrain and objects that may
  /// block it. A line from or to a flying unit passes over the ground in
  /// between.
  ///
  /// The line runs from [fromHeightM] above the observer's point (the top
  /// of its hit volume) to [toHeightM] above the target's; where the ground
  /// rises above it, a hill blocks it (MAP-26, vision in 3D; decision
  /// 235).
  SightLine sightLine(
    CellRef from,
    CellRef to, {
    bool fromFlying = false,
    bool toFlying = false,
    double fromHeightM = 0,
    double toHeightM = 0,
  }) {
    final between = fromFlying || toFlying
        ? const <CellRef>[]
        : _between(from, to);
    final fromZ = pointOf(from).z + fromHeightM;
    final toZ = pointOf(to).z + toHeightM;
    final length = distanceM(from, to);
    var forest = 0.0;
    var hill = false;
    final obstacles = <SightObstacle>[];
    for (final cell in between) {
      final share = distanceM(from, cell) / length;
      hill = hill || _nav.cellAt(cell)!.height > fromZ + (toZ - fromZ) * share;
      obstacles.add(TerrainObstacle(terrainOf(cell)));
      for (final object in objectsOn(cell)) {
        obstacles.add(ObjectObstacle(object));
        if (terrain.objects[object]?.conceals == 'forest') forest += cellSizeM;
      }
    }
    if (hill) obstacles.add(const GroundObstacle());
    return SightLine(
      distanceM: length,
      observerTerrain: terrainOf(from),
      heightAboveTargetM:
          pointOf(from, flying: fromFlying).z - pointOf(to, flying: toFlying).z,
      forestCrossedM: forest,
      obstacles: obstacles,
    );
  }

  /// The ground cells strictly between [from] and [to] (Bresenham).
  List<CellRef> _between(CellRef from, CellRef to) {
    final cells = <CellRef>[];
    var x = from.x;
    var y = from.y;
    final dx = (to.x - from.x).abs();
    final dy = -(to.y - from.y).abs();
    final sx = from.x < to.x ? 1 : -1;
    final sy = from.y < to.y ? 1 : -1;
    var error = dx + dy;
    while (true) {
      if (x == to.x && y == to.y) break;
      final twice = 2 * error;
      if (twice >= dy) {
        error += dy;
        x += sx;
      }
      if (twice <= dx) {
        error += dx;
        y += sy;
      }
      if (x == to.x && y == to.y) break;
      cells.add(CellRef(x, y));
    }
    return cells;
  }

  /// The first obstacle of a first-person shot (COMBAT-14, COMBAT-53),
  /// marched in steps of a quarter cell: the ground, or a cell whose object
  /// blocks sight up to a cell's height above the ground. Null when the
  /// line leaves the map or meets nothing within [maxDistanceM].
  @override
  double? firstObstacle(Vec3 origin, Vec3 direction, double maxDistanceM) {
    final length = math.sqrt(
      direction.x * direction.x +
          direction.y * direction.y +
          direction.z * direction.z,
    );
    if (length == 0) return null;
    final step = cellSizeM / 4;
    for (var distance = step; distance <= maxDistanceM; distance += step) {
      final x = origin.x + direction.x / length * distance;
      final y = origin.y + direction.y / length * distance;
      final z = origin.z + direction.z / length * distance;
      final cell = CellRef((x / cellSizeM).floor(), (y / cellSizeM).floor());
      final ground = _nav.cellAt(cell);
      if (ground == null) return null;
      if (z < ground.height) return distance;
      final blocks = objectsOn(cell)
          .any((object) => terrain.objects[object]?.blocksLos ?? false);
      if (blocks && z < ground.height + cellSizeM) return distance;
    }
    return null;
  }
}

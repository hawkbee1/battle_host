import 'dart:math' as math;

import 'package:battle_host/src/ports/map_source.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_rules/battle_rules.dart';

/// The construction of `terrain.yaml` that makes a road (MAP-21);
/// `battle_pathfinding` names it `road` by default.
const roadConstruction = 'road_segment';

/// {@template shared_map}
/// One loaded map, shared by every battle on it and every mover of those
/// battles (Flyweight, stack decisions 1 and 7): the [host] data of the
/// loader, and one [grid] of path-search arrays whose searches, one per
/// movement profile, keep only their own memos.
/// {@endtemplate}
final class SharedMap {
  /// {@macro shared_map}
  ///
  /// Throws an [ArgumentError] when `terrain.yaml` has no
  /// [roadConstruction] object.
  factory load({
    required String id,
    required HostMap host,
    required TerrainData terrain,
  }) {
    if (!terrain.objects.containsKey(roadConstruction)) {
      throw ArgumentError.value(
        roadConstruction,
        'terrain',
        'terrain.yaml has no such object',
      );
    }
    final map = host.navigation;
    final highest = [
      ...map.ground.map((cell) => cell.height),
      for (final island in map.islands.values)
        ...island.values.map((cell) => cell.height),
    ].reduce(math.max);
    return SharedMap._(
      id,
      host,
      GroundGrid(
        map: map,
        rules: PathRules(
          roadConstruction: roadConstruction,
          altitudeLimitM: highest + terrain.flyingMaxAboveHighestTerrainM,
        ),
      ),
      MovementCost(terrain).call,
    );
  }

  new _(this.id, this.host, this.grid, this.cost);

  /// The map's ID.
  final String id;

  /// What the host loader made of it.
  final HostMap host;

  /// The ground arrays shared by every search.
  final GroundGrid grid;

  /// The movement cost of the rules core (Strategy, MAP-11 to MAP-19).
  final MovementCostFunction cost;

  final _searches = <(double, String), GroundSearch>{};

  /// The map's objects, constructions and links on each of their cells.
  late final Map<CellRef, List<MapObject>> objectsByCell = () {
    final byCell = <CellRef, List<MapObject>>{};
    for (final object in host.objects.values) {
      for (final cell in object.cells) {
        byCell.putIfAbsent(cell, () => []).add(object);
      }
    }
    return byCell;
  }();

  /// The path rules: the flying altitude limit is the map's highest point
  /// plus `flying_max_above_highest_terrain_m` (decision 142).
  PathRules get rules => grid.rules;

  /// The search of [mover]'s movement profile, made once on the shared
  /// grid.
  GroundSearch searchFor(PathMover mover) => _searches.putIfAbsent((
    mover.apPerM,
    mover.modes.join(','),
  ), () => GroundSearch.on(grid, cost: cost, mover: mover));
}

/// {@template map_library}
/// The maps of one host process, each loaded once from [source] and then
/// shared (Flyweight).
/// {@endtemplate}
final class MapLibrary {
  /// {@macro map_library}
  new({required this.source, required this.terrain});

  /// Where the maps are read.
  final MapSource source;

  /// The `terrain.yaml` data the loader needs.
  final TerrainData terrain;

  final _maps = <String, SharedMap>{};

  /// How many maps are loaded.
  int get loaded => _maps.length;

  /// The map [mapId], loaded on its first use.
  SharedMap load(String mapId) => _maps[mapId] ??= SharedMap.load(
    id: mapId,
    host: HostMapLoader(terrain).load(source.read(mapId)),
    terrain: terrain,
  );
}

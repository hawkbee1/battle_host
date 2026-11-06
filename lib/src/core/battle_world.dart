import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';

/// {@template world_delta}
/// The delta layer of a battle on top of its authored map (MAP-06): the
/// world [changes] in their order, the HP of the objects hit, the objects
/// built and those destroyed. It is part of the battle's state, so of its
/// snapshot, and a late joiner is sent it whole (MAP-08).
///
/// Nothing in it is ever undone: no crater is filled, no destroyed object
/// regrows (MAP-09).
/// {@endtemplate}
final class WorldDelta {
  /// {@macro world_delta}
  const new({
    this.changes = const [],
    this.hp = const {},
    this.built = const {},
    this.destroyed = const {},
  });

  /// The world changes, in their order: what the paths, sight lines and
  /// shot tracing follow.
  final List<WorldChange> changes;

  /// The HP left of each object hit and still standing, by object id
  /// (MAP-10).
  final Map<String, double> hp;

  /// The objects built during the battle, by id (their site id).
  final Map<String, MapObject> built;

  /// The ids of the objects destroyed.
  final Set<String> destroyed;

  /// This layer with [changed], and an object [built], hit to its [hp]
  /// (id and HP left) or [destroyed] (its id).
  WorldDelta withChanges(
    List<WorldChange> changed, {
    MapObject? built,
    (String, double)? hp,
    String? destroyed,
  }) => WorldDelta(
    changes: List.unmodifiable([...changes, ...changed]),
    hp: Map.unmodifiable({
      for (final MapEntry(:key, :value) in this.hp.entries)
        if (key != destroyed) key: value,
      if (hp != null) hp.$1: hp.$2,
    }),
    built: built == null
        ? this.built
        : Map.unmodifiable({...this.built, built.id: built}),
    destroyed: destroyed == null
        ? this.destroyed
        : Set.unmodifiable({...this.destroyed, destroyed}),
  );
}

/// {@template battle_world}
/// The world of one battle: the [shared] map until it first changes, then
/// a navigation model and a ground grid of its own (copy on write, stack
/// decision 1). Each change updates the paths ([paths], a
/// `LivePathfinder`), the long searches, the sight lines and the shot
/// tracing, which all read [navigation] (MAP-07, MAP-28).
/// {@endtemplate}
final class BattleWorld {
  /// {@macro battle_world}
  new(this.shared)
    : paths = LivePathfinder(
        map: shared.host.navigation,
        cost: shared.cost,
        rules: shared.rules,
      );

  /// The world of a battle with the [delta] layer applied on [shared]: a
  /// battle restored from its snapshot (M5.15).
  factory load(SharedMap shared, WorldDelta delta) {
    final world = BattleWorld(shared);
    delta.changes.forEach(world.apply);
    return world;
  }

  /// The map it started from.
  final SharedMap shared;

  /// Path search and checks on the world as it is now.
  final LivePathfinder paths;

  GroundGrid? _grid;
  final _searches = <(double, String), GroundSearch>{};

  /// The navigation model with every change applied.
  NavigationMap get navigation => paths.map;

  /// How objects, constructions and links are crossed.
  PathRules get rules => shared.rules;

  /// Whether its world has changed: it then has a grid of its own.
  bool get ownsGrid => _grid != null;

  /// The long-path search of [mover]'s movement profile: the shared one
  /// until the world changes, then one on the battle's own grid.
  GroundSearch searchFor(PathMover mover) {
    final grid = _grid;
    if (grid == null) return shared.searchFor(mover);
    return _searches.putIfAbsent((
      mover.apPerM,
      mover.modes.join(','),
    ), () => GroundSearch.on(grid, cost: shared.cost, mover: mover));
  }

  /// Applies [change]: the paths forget only the steps it touches, and the
  /// battle's own grid, copied from the shared one on the first change,
  /// reloads only the cells it touches (P-07).
  void apply(WorldChange change) {
    final touched = paths.apply(change);
    (_grid ??= GroundGrid.copy(shared.grid)).apply(paths.map, touched);
  }
}

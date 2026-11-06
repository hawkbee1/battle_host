import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_host/src/core/simulation_host.dart';
import 'package:battle_host/src/hosting/battle_placement.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template host_service}
/// A host process at work (stack decision 1, hosting): its [host] is
/// brought to the clock's time every second ([tick]), and every [poll]
/// it runs the battles placed on it and reports those that ended
/// ([placement]). [stop] snapshots every battle and waits for the uploads
/// before the process ends (stack decision 2).
/// {@endtemplate}
final class HostService {
  /// {@macro host_service}
  new({
    required this.host,
    required this.placement,
    this.poll = const Duration(seconds: 10),
  });

  /// The host process.
  final SimulationHost host;

  /// The battles placed on it.
  final BattlePlacement placement;

  /// How often it looks for battles placed on it and ended ones.
  final Duration poll;

  var _seconds = 0;

  /// Loads the maps it serves, prepares their path searches for every
  /// unit type, the HQ and a pushed relic, so that no battle pays for it in
  /// its first orders (P-02), then runs the battles placed on it.
  Future<void> start() async {
    for (final mapId in placement.mapIds) {
      prepare(host.maps.load(mapId), host.definitions);
    }
    await _sync();
  }

  /// One second: the battles advance; on each [poll], the placement syncs.
  Future<void> tick() async {
    host.advance();
    _seconds++;
    if (_seconds % poll.inSeconds == 0) await _sync();
  }

  Future<void> _sync() async {
    await placement.sync();
    await placement.report();
  }

  /// Snapshots every battle and waits for the uploads under way.
  Future<void> stop() async {
    host.advance();
    for (final battle in host.battles.toList()) {
      host.snapshot(battle.id);
    }
    host.advance();
    await host.settle();
  }
}

/// Prepares the path searches of [map] for every unit type of
/// [definitions] on the ground, the HQ and a pushed relic: the first
/// search of a mover builds its data, shared by every battle on the map
/// (Flyweight, stack decision 7).
void prepare(SharedMap map, GameData definitions) {
  final movers = [
    for (final type in definitions.units.unitTypes.values) Mover.unit(type),
    Mover.hq(definitions.battle.hq),
    Mover.relic(definitions.combat.push),
  ];
  for (final mover in movers) {
    map.searchFor(PathMover(apPerM: mover.apPerM, modes: mover.modes));
  }
}

import 'dart:async';

import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_setup.dart';
import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_host/src/ports/clock.dart';
import 'package:battle_host/src/ports/error_reporter.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template simulation_host}
/// One host process (stack decision 1): several battles, each started from
/// a setup, on maps loaded once and shared ([maps]), with the shared
/// [definitions] of `plan/data`. Time comes from the injected [clock];
/// errors go to the [reporter] (stack decision 6).
/// {@endtemplate}
final class SimulationHost {
  /// {@macro simulation_host}
  new({
    required this.clock,
    required this.maps,
    required this.definitions,
    required this.reporter,
  });

  /// The wall clock.
  final Clock clock;

  /// The maps of this process.
  final MapLibrary maps;

  /// The shared definitions.
  final GameData definitions;

  /// Where errors go.
  final ErrorReporter reporter;

  final _battles = <String, Battle>{};
  final _startedAt = <String, DateTime>{};
  final _failed = <String>{};

  /// The battles running.
  Iterable<Battle> get battles => _battles.values;

  /// The battles stopped by an error.
  Set<String> get failed => Set.unmodifiable(_failed);

  /// The battle [battleId], when it runs.
  Battle? operator [](String battleId) => _battles[battleId];

  /// Starts the battle of [setup] now, on its map.
  ///
  /// Throws an [ArgumentError] for a battle ID already in use, and the
  /// errors of [Battle.start].
  Battle start(BattleSetup setup) {
    if (_battles.containsKey(setup.battleId)) {
      throw ArgumentError.value(setup.battleId, 'battleId', 'already runs');
    }
    final battle = Battle.start(
      setup: setup,
      map: maps.load(setup.mapId),
      definitions: definitions,
    );
    _battles[battle.id] = battle;
    _startedAt[battle.id] = clock.now();
    return battle;
  }

  /// Brings every battle to the clock's time. A battle that fails is
  /// reported and stopped; the others go on.
  void advance() {
    final now = clock.now();
    for (final MapEntry(key: id, value: battle) in _battles.entries.toList()) {
      try {
        battle.advanceTo(now.difference(_startedAt[id]!));
      } on Object catch (error, stackTrace) {
        _battles.remove(id);
        _failed.add(id);
        unawaited(reporter.report(error, stackTrace, battleId: id));
      }
    }
  }
}

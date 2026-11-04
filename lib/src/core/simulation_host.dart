import 'dart:async';

import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_setup.dart';
import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_host/src/orders/command_handler.dart';
import 'package:battle_host/src/orders/command_sinks.dart';
import 'package:battle_host/src/orders/rate_limit.dart';
import 'package:battle_host/src/ports/clock.dart';
import 'package:battle_host/src/ports/error_reporter.dart';
import 'package:battle_host/src/ports/log_sink.dart';
import 'package:battle_protocol/battle_protocol.dart';
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
    LogSink? log,
    RateLimit? rateLimit,
  }) : log = log ?? MemoryLogSink(),
       rateLimit = rateLimit ?? RateLimit();

  /// The wall clock.
  final Clock clock;

  /// The maps of this process.
  final MapLibrary maps;

  /// The shared definitions.
  final GameData definitions;

  /// Where errors go.
  final ErrorReporter reporter;

  /// The battle logs.
  final LogSink log;

  /// The rate limit of every sender.
  final RateLimit rateLimit;

  final _commands = <String, CommandSink>{};

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
    _commands[battle.id] = RateLimitedCommands(
      inner: BattleCommands(battle: battle, log: log),
      limit: rateLimit,
      clock: clock,
    );
    return battle;
  }

  /// Submits [command] to the battle [battleId] from a sender signed in as
  /// [origin], at the clock's time: the one entry of every sender (Facade,
  /// AI-03, AI-09).
  ///
  /// Throws an [ArgumentError] for a battle that does not run.
  HandledOrder submit(
    String battleId,
    Command command, {
    required Origin origin,
  }) {
    final battle =
        _battles[battleId] ??
        (throw ArgumentError.value(battleId, 'battleId', 'does not run'));
    _advance(battleId, battle, clock.now());
    final commands =
        _commands[battleId] ??
        (throw StateError('battle $battleId failed while it caught up'));
    return commands.submit(command, origin: origin);
  }

  /// Brings every battle to the clock's time. A battle that fails is
  /// reported and stopped; the others go on.
  void advance() {
    final now = clock.now();
    for (final MapEntry(key: id, value: battle) in _battles.entries.toList()) {
      _advance(id, battle, now);
    }
  }

  void _advance(String id, Battle battle, DateTime now) {
    try {
      battle.advanceTo(now.difference(_startedAt[id]!));
    } on Object catch (error, stackTrace) {
      _battles.remove(id);
      _commands.remove(id);
      _failed.add(id);
      unawaited(reporter.report(error, stackTrace, battleId: id));
    }
  }
}

import 'dart:async';

import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_setup.dart';
import 'package:battle_host/src/core/journal.dart';
import 'package:battle_host/src/core/replay.dart';
import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_host/src/core/snapshot_codec.dart';
import 'package:battle_host/src/orders/command_handler.dart';
import 'package:battle_host/src/orders/command_sinks.dart';
import 'package:battle_host/src/orders/rate_limit.dart';
import 'package:battle_host/src/ports/clock.dart';
import 'package:battle_host/src/ports/error_reporter.dart';
import 'package:battle_host/src/ports/log_sink.dart';
import 'package:battle_host/src/ports/snapshot_store.dart';
import 'package:battle_host/src/ports/write_ahead_log.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template simulation_host}
/// One host process (stack decision 1): several battles, each started from
/// a setup, on maps loaded once and shared ([maps]), with the shared
/// [definitions] of `plan/data`. Time comes from the injected [clock];
/// errors go to the [reporter] (stack decision 6).
///
/// Every battle's log goes to the write-ahead log [wal], then in batches
/// to the [logs], with a snapshot in the [snapshots] every 5 minutes
/// (stack decision 2, `Journal`); a stopped battle is [recover]ed from
/// them. The stores are in memory unless given.
/// {@endtemplate}
final class SimulationHost {
  /// {@macro simulation_host}
  new({
    required this.clock,
    required this.maps,
    required this.definitions,
    required this.reporter,
    WriteAheadLog? wal,
    LogSink? logs,
    SnapshotStore? snapshots,
    RateLimit? rateLimit,
  }) : wal = wal ?? MemoryWriteAheadLog(),
       logs = logs ?? MemoryLogSink(),
       snapshots = snapshots ?? MemorySnapshotStore(),
       rateLimit = rateLimit ?? RateLimit();

  /// The wall clock.
  final Clock clock;

  /// The maps of this process.
  final MapLibrary maps;

  /// The shared definitions.
  final GameData definitions;

  /// Where errors go.
  final ErrorReporter reporter;

  /// The local write-ahead log of every battle.
  final WriteAheadLog wal;

  /// Where the battle logs are uploaded.
  final LogSink logs;

  /// Where the battle snapshots go.
  final SnapshotStore snapshots;

  /// The rate limit of every sender.
  final RateLimit rateLimit;

  late final _journal = Journal(
    wal: wal,
    logs: logs,
    snapshots: snapshots,
    reporter: reporter,
  );

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

  /// Starts the battle of [setup] now, on its map, and takes its first
  /// snapshot.
  ///
  /// Throws an [ArgumentError] for a battle ID already in use, also by a
  /// battle stopped by an error (it is [recover]ed, not started again),
  /// and the errors of [Battle.start].
  Battle start(BattleSetup setup) {
    _checkFree(setup.battleId);
    if (_failed.contains(setup.battleId)) {
      throw ArgumentError.value(setup.battleId, 'battleId', 'is stopped');
    }
    final battle = Battle.start(
      setup: setup,
      map: maps.load(setup.mapId),
      definitions: definitions,
    );
    final now = clock.now();
    _run(battle, startedAt: now);
    _journal.open(battle, startedAt: now, now: now);
    return battle;
  }

  /// Restores the battle [battleId], which stopped with its host or by an
  /// error (stack decision 2): its latest snapshot, then the batches of its
  /// log uploaded after it and its write-ahead log beyond them, replayed.
  /// The entries not uploaded yet wait for the next upload. It is then
  /// brought to the clock's time: the time it spent stopped counts
  /// (decision 222).
  ///
  /// Throws an [ArgumentError] for a battle that runs; a [StateError] for
  /// a battle with no snapshot, a write-ahead log that starts after the
  /// uploaded log ends, or a replay that diverges from the log; and the
  /// errors of [decodeSnapshot] and [Battle.restore].
  Future<Battle> recover(String battleId) async {
    _checkFree(battleId);
    final snapshot =
        await snapshots.latest(battleId) ??
        (throw StateError('$battleId has no snapshot'));
    final uploaded = await logs.read(battleId, from: snapshot.position);
    final (:memento, :startedAt) = decodeSnapshot(
      snapshot.data,
      definitions: definitions,
    );
    final battle = Battle.restore(
      memento,
      map: maps.load(memento.mapId),
      definitions: definitions,
    );
    final uploadedTo = snapshot.position + uploaded.length;
    final held = wal.read(battleId);
    if (held.from > uploadedTo) {
      throw StateError(
        'the write-ahead log of $battleId starts at ${held.from}, after the '
        'end of its uploaded log at $uploadedTo',
      );
    }
    final unsent = held.entries.sublist(
      (uploadedTo - held.from).clamp(0, held.entries.length),
    );
    replay(battle, [...uploaded, ...unsent], from: snapshot.position);
    _checkFree(battleId);
    _failed.remove(battleId);
    _run(battle, startedAt: startedAt);
    _journal.open(
      battle,
      startedAt: startedAt,
      now: clock.now(),
      from: uploadedTo,
      unsent: unsent,
      snapshotAt: snapshot.position,
    );
    _advance(battleId, battle, clock.now());
    return battle;
  }

  /// Submits [command] to the battle [battleId] from a sender signed in as
  /// [origin], at the clock's time: the one entry of every sender (Facade,
  /// AI-03, AI-09). It returns, and the command is acknowledged, only once
  /// its entry is on disk (stack decision 2).
  ///
  /// Throws an [ArgumentError] for a battle that does not run. A failure to
  /// write the log stops the battle, which is reported, and is rethrown:
  /// the command is not acknowledged.
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
    try {
      return commands.submit(command, origin: origin);
    } on Object catch (error, stackTrace) {
      _fail(battleId, error, stackTrace);
      rethrow;
    }
  }

  /// Brings every battle to the clock's time, then uploads the log batches
  /// and takes the snapshots due (stack decision 2). A battle that fails
  /// is reported and stopped; the others go on.
  void advance() {
    final now = clock.now();
    for (final MapEntry(key: id, value: battle) in _battles.entries.toList()) {
      _advance(id, battle, now);
    }
    _journal.tick(now);
  }

  /// Takes a snapshot of the battle [battleId] now: before a planned stop,
  /// or once a battle is set up. It is kept once its log is uploaded.
  ///
  /// Throws an [ArgumentError] for a battle that does not run.
  void snapshot(String battleId) => _journal.snapshot(battleId);

  /// Completes once every upload and snapshot under way is done: before
  /// the process stops.
  Future<void> settle() => _journal.settle();

  void _checkFree(String battleId) {
    if (_battles.containsKey(battleId)) {
      throw ArgumentError.value(battleId, 'battleId', 'already runs');
    }
  }

  void _run(Battle battle, {required DateTime startedAt}) {
    _battles[battle.id] = battle;
    _startedAt[battle.id] = startedAt;
    _commands[battle.id] = RateLimitedCommands(
      inner: BattleCommands(battle: battle, journal: _journal),
      limit: rateLimit,
      clock: clock,
    );
  }

  void _advance(String id, Battle battle, DateTime now) {
    try {
      battle.advanceTo(now.difference(_startedAt[id]!));
    } on Object catch (error, stackTrace) {
      _fail(id, error, stackTrace);
    }
  }

  void _fail(String id, Object error, StackTrace stackTrace) {
    _battles.remove(id);
    _commands.remove(id);
    _journal.close(id);
    _failed.add(id);
    unawaited(reporter.report(error, stackTrace, battleId: id));
  }
}

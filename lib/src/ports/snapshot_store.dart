import 'dart:typed_data';

/// {@template battle_snapshot}
/// The state of [battleId] after the first [position] entries of its log,
/// at the battle time [time] (Memento, stack decisions 2 and 7): [data]
/// means something only to the battle that wrote it. Every batch of the
/// log before [position] was uploaded before the snapshot was kept, so
/// recovery reads the batches from [position] on.
/// {@endtemplate}
final class BattleSnapshot {
  /// {@macro battle_snapshot}
  const new({
    required this.battleId,
    required this.position,
    required this.time,
    required this.data,
  });

  /// The battle.
  final String battleId;

  /// The number of entries of its log the snapshot holds.
  final int position;

  /// The battle time it was taken at.
  final Duration time;

  /// The battle's state, encoded.
  final Uint8List data;

  /// Whether it comes after [other]: further in the log, or later in the
  /// battle at the same point of the log.
  bool isAfter(BattleSnapshot other) =>
      position > other.position ||
      (position == other.position && time > other.time);
}

/// Where battle snapshots are kept (a port, stack decisions 2 and 7): only
/// the latest of a battle matters, the one recovery starts from.
abstract interface class SnapshotStore {
  /// Keeps [snapshot], which comes after every snapshot of its battle kept
  /// before.
  Future<void> save(BattleSnapshot snapshot);

  /// The latest snapshot of [battleId]; null when it has none.
  Future<BattleSnapshot?> latest(String battleId);
}

/// {@template memory_snapshot_store}
/// Snapshots kept in memory, the latest of each battle: for tests and
/// simulated runs.
/// {@endtemplate}
final class MemorySnapshotStore implements SnapshotStore {
  /// {@macro memory_snapshot_store}
  new();

  final _latest = <String, BattleSnapshot>{};

  @override
  Future<void> save(BattleSnapshot snapshot) async =>
      _latest[snapshot.battleId] = snapshot;

  @override
  Future<BattleSnapshot?> latest(String battleId) async => _latest[battleId];
}

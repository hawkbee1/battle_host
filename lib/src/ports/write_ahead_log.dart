import 'package:battle_protocol/battle_protocol.dart';

/// The entries a write-ahead log holds for one battle: `entries` from the
/// log position `from` (the number of entries of the battle's log before
/// the first one).
typedef HeldEntries = ({int from, List<LogEntry> entries});

/// Where the host writes each entry of a battle log first (a port, stack
/// decision 2): its own disk, synced before [append] returns, so that an
/// order is acknowledged only once it is on disk.
abstract interface class WriteAheadLog {
  /// Appends [entry] at the log position [position] of [battleId] and syncs
  /// it to disk before returning. A position past the end of what is held
  /// (a battle recovered from its uploads onto a new disk) starts the held
  /// log again there.
  ///
  /// Throws a [StateError] for a position before the end of what is held.
  void append(String battleId, int position, LogEntry entry);

  /// The entries held for [battleId]: none, from 0, for a battle it never
  /// held.
  HeldEntries read(String battleId);

  /// Forgets what it holds for [battleId]: a battle this host claims, which
  /// another host may have run since its own entries were written (M6
  /// Issue 6). The battle's uploaded log is its history from then on.
  void discard(String battleId);
}

/// {@template memory_write_ahead_log}
/// A write-ahead log kept in memory, by battle: for tests and simulated
/// runs, where nothing outlives the process.
/// {@endtemplate}
final class MemoryWriteAheadLog implements WriteAheadLog {
  /// {@macro memory_write_ahead_log}
  new();

  final _held = <String, (int, List<LogEntry>)>{};

  @override
  void append(String battleId, int position, LogEntry entry) {
    final (from, entries) = _held[battleId] ?? (0, <LogEntry>[]);
    final end = from + entries.length;
    if (position < end) {
      throw StateError('$battleId already holds position $position');
    }
    _held[battleId] = position == end
        ? (from, entries..add(entry))
        : (position, [entry]);
  }

  @override
  HeldEntries read(String battleId) {
    final (from, entries) = _held[battleId] ?? (0, const <LogEntry>[]);
    return (from: from, entries: List.unmodifiable(entries));
  }

  @override
  void discard(String battleId) => _held.remove(battleId);
}

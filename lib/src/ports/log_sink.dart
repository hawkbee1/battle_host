import 'package:battle_protocol/battle_protocol.dart';

/// {@template log_batch}
/// The [entries] of the log of [battleId] from the log position [from]:
/// what one upload carries (stack decision 2).
/// {@endtemplate}
final class LogBatch {
  /// {@macro log_batch}
  const new({
    required this.battleId,
    required this.from,
    required this.entries,
  });

  /// The battle.
  final String battleId;

  /// The log position of its first entry: the number of entries of the
  /// battle's log before it.
  final int from;

  /// Its entries, in order.
  final List<LogEntry> entries;

  /// The log position after its last entry, where the next batch starts.
  int get end => from + entries.length;
}

/// Where battle logs are kept for good (a port, stack decisions 2 and 7):
/// in batches, each one starting where the one before it ended. Recovery
/// reads them after a snapshot; the statistics read them whole
/// (decision 143).
abstract interface class LogSink {
  /// Keeps [batch]. Uploading a batch again changes nothing, so a failed
  /// upload is retried with the same batch.
  ///
  /// Throws an [ArgumentError] for a batch with no entry.
  Future<void> upload(LogBatch batch);

  /// The entries of the log of [battleId] from the log position [from],
  /// which starts a batch, to the end of the batches that follow it; none
  /// when no batch starts there.
  Future<List<LogEntry>> read(String battleId, {int from = 0});
}

/// {@template memory_log_sink}
/// Battle logs kept in memory, by battle: for tests and simulated runs.
/// {@endtemplate}
final class MemoryLogSink implements LogSink {
  /// {@macro memory_log_sink}
  new();

  final _batches = <String, Map<int, LogBatch>>{};

  /// The batches of [battleId], in their order.
  List<LogBatch> batchesOf(String battleId) =>
      ((_batches[battleId] ?? const {}).values.toList()
            ..sort((a, b) => a.from.compareTo(b.from)))
          .toList(growable: false);

  @override
  Future<void> upload(LogBatch batch) async {
    checkBatch(batch);
    (_batches[batch.battleId] ??= {})[batch.from] = LogBatch(
      battleId: batch.battleId,
      from: batch.from,
      entries: List.unmodifiable(batch.entries),
    );
  }

  @override
  Future<List<LogEntry>> read(String battleId, {int from = 0}) async {
    final batches = _batches[battleId] ?? const {};
    final entries = <LogEntry>[];
    for (var at = batches[from]; at != null; at = batches[at.end]) {
      entries.addAll(at.entries);
    }
    return List.unmodifiable(entries);
  }
}

/// Throws an [ArgumentError] for a [batch] with no entry: every batch
/// moves the log forward.
void checkBatch(LogBatch batch) {
  if (batch.entries.isEmpty) {
    throw ArgumentError.value(batch.from, 'batch', 'has no entry');
  }
}

import 'dart:async';

import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/snapshot_codec.dart';
import 'package:battle_host/src/ports/error_reporter.dart';
import 'package:battle_host/src/ports/log_sink.dart';
import 'package:battle_host/src/ports/snapshot_store.dart';
import 'package:battle_host/src/ports/write_ahead_log.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// {@template journal}
/// The write path of stack decision 2 for the battles of one host:
/// - each entry goes to the write-ahead log, synced, before anything else;
/// - every [uploadEvery] (10 seconds) with new entries, they are sealed
///   into one batch; an interval with none uploads nothing;
/// - every [snapshotEvery] (5 minutes) with new entries, a snapshot of the
///   battle is taken (Memento).
///
/// Batches go to the [logs] one at a time, in order; a failed one is
/// reported and sent again, the same, at the next interval. A snapshot is
/// kept only once every batch before it is uploaded, so recovery reads the
/// batches from the snapshot on and the uploaded log has no gap.
/// {@endtemplate}
final class Journal {
  /// {@macro journal}
  new({
    required this.wal,
    required this.logs,
    required this.snapshots,
    required this.reporter,
    this.uploadEvery = const Duration(seconds: 10),
    this.snapshotEvery = const Duration(minutes: 5),
  });

  /// The local write-ahead log.
  final WriteAheadLog wal;

  /// Where the batches go.
  final LogSink logs;

  /// Where the snapshots go.
  final SnapshotStore snapshots;

  /// Where failed uploads are reported.
  final ErrorReporter reporter;

  /// How often new entries are sealed into a batch.
  final Duration uploadEvery;

  /// How often a battle with new entries is snapshotted.
  final Duration snapshotEvery;

  final _logs = <String, _BattleLog>{};
  final _work = <Future<void>>{};

  /// Starts keeping the log of [battle], which started at the wall time
  /// [startedAt], at the wall time [now].
  ///
  /// A new battle has an empty log, and its first snapshot is taken at
  /// once. A recovered battle has its log uploaded up to [from], then the
  /// [unsent] entries, and its latest snapshot at [snapshotAt]: its next
  /// snapshot is due at once.
  void open(
    Battle battle, {
    required DateTime startedAt,
    required DateTime now,
    int from = 0,
    List<LogEntry> unsent = const [],
    int? snapshotAt,
  }) {
    final log = _logs[battle.id] = _BattleLog(
      battle: battle,
      startedAt: startedAt,
      from: from,
      unsent: [...unsent],
      snapshotAt: snapshotAt ?? 0,
      nextUpload: now.add(uploadEvery),
      nextSnapshot: snapshotAt == null ? now.add(snapshotEvery) : now,
    );
    if (snapshotAt == null) snapshot(battle.id);
    log.seal();
  }

  /// Appends [entry] to the log of [battleId]: to the write-ahead log,
  /// synced to disk, then to the entries waiting for upload.
  ///
  /// Throws an [ArgumentError] for a battle it does not keep, and the
  /// errors of the write-ahead log: then the entry is in no log.
  void append(String battleId, LogEntry entry) {
    final log = _log(battleId);
    wal.append(battleId, log.position, entry);
    log.unsent.add(entry);
  }

  /// Stops keeping the log of [battleId], a battle that stopped: what
  /// waits for upload stays in the write-ahead log only.
  void close(String battleId) => _logs.remove(battleId)?.closed = true;

  /// At the wall time [now]: seals the entries of the intervals that ended
  /// into batches, takes the snapshots due, and sends what can be sent.
  void tick(DateTime now) {
    for (final log in _logs.values) {
      if (!now.isBefore(log.nextUpload)) {
        log
          ..nextUpload = now.add(uploadEvery)
          ..seal();
      }
      if (!now.isBefore(log.nextSnapshot)) {
        log.nextSnapshot = now.add(snapshotEvery);
        if (log.position > log.snapshotAt) _take(log);
      }
      _send(log);
    }
  }

  /// Takes a snapshot of [battleId] now and seals its log there. It is kept
  /// once every batch before it is uploaded.
  ///
  /// Throws an [ArgumentError] for a battle it does not keep.
  void snapshot(String battleId) {
    final log = _log(battleId);
    _take(log);
    _send(log);
  }

  /// Completes once every upload and snapshot under way is done.
  Future<void> settle() async {
    while (_work.isNotEmpty) {
      await Future.wait(_work.toList());
    }
  }

  _BattleLog _log(String battleId) =>
      _logs[battleId] ??
      (throw ArgumentError.value(battleId, 'battleId', 'is not kept'));

  void _take(_BattleLog log) {
    log
      ..seal()
      ..waiting = BattleSnapshot(
        battleId: log.battle.id,
        position: log.position,
        time: log.battle.time,
        data: encodeSnapshot(log.battle.save(), startedAt: log.startedAt),
      )
      ..snapshotAt = log.position;
  }

  void _send(_BattleLog log) {
    if (log.closed) return;
    final id = log.battle.id;
    if (!log.uploading && log.sealed.isNotEmpty) {
      final batch = LogBatch(
        battleId: id,
        from: log.from,
        entries: List.unmodifiable(
          log.unsent.sublist(0, log.sealed.first - log.from),
        ),
      );
      log.uploading = true;
      _track(
        Future.sync(() => logs.upload(batch)).then(
          (_) {
            log
              ..uploading = false
              ..from = batch.end;
            log.unsent.removeRange(0, batch.entries.length);
            log.sealed.removeAt(0);
            _send(log);
          },
          onError: (Object error, StackTrace stackTrace) {
            log.uploading = false;
            _report(error, stackTrace, id);
          },
        ),
      );
    }
    final waiting = log.waiting;
    if (waiting != null && !log.saving && waiting.position <= log.from) {
      log.saving = true;
      _track(
        Future.sync(() => snapshots.save(waiting)).then(
          (_) {
            log.saving = false;
            if (identical(log.waiting, waiting)) log.waiting = null;
            _send(log);
          },
          onError: (Object error, StackTrace stackTrace) {
            log.saving = false;
            _report(error, stackTrace, id);
          },
        ),
      );
    }
  }

  void _track(Future<void> work) {
    _work.add(work);
    unawaited(work.whenComplete(() => _work.remove(work)));
  }

  void _report(Object error, StackTrace stackTrace, String battleId) =>
      unawaited(reporter.report(error, stackTrace, battleId: battleId));
}

/// The log of one battle as the journal keeps it: uploaded up to [from],
/// then the [unsent] entries, sealed into batches at the [sealed] log
/// positions.
final class _BattleLog {
  new({
    required this.battle,
    required this.startedAt,
    required this.from,
    required this.unsent,
    required this.snapshotAt,
    required this.nextUpload,
    required this.nextSnapshot,
  });

  final Battle battle;
  final DateTime startedAt;
  int from;
  final List<LogEntry> unsent;
  final sealed = <int>[];
  int snapshotAt;
  DateTime nextUpload;
  DateTime nextSnapshot;
  BattleSnapshot? waiting;
  bool uploading = false;
  bool saving = false;
  bool closed = false;

  int get position => from + unsent.length;

  /// Ends the batch under way at [position], when it holds an entry.
  void seal() {
    if (position > (sealed.isEmpty ? from : sealed.last)) sealed.add(position);
  }
}

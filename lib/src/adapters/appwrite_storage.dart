import 'dart:io';
import 'dart:typed_data';

import 'package:battle_host/src/adapters/counts.dart';
import 'package:battle_host/src/ports/log_sink.dart';
import 'package:battle_host/src/ports/snapshot_store.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:dart_appwrite/dart_appwrite.dart';

/// The Appwrite Storage bucket of the battle logs
/// (`backend/appwrite.config.json`).
const battleLogsBucket = 'battle_logs';

/// The Appwrite Storage bucket of the battle snapshots.
const battleSnapshotsBucket = 'battle_snapshots';

/// The longest battle ID the Appwrite adapters store: a file ID holds at
/// most 36 characters, and a batch's adds 13 to the battle's.
const maxStoredBattleId = 23;

/// The first bytes of a snapshot file, before compression: `BTSN`.
const _snapshotMagic = [0x42, 0x54, 0x53, 0x4E];

const _codec = BinaryProtocolCodec();

/// One upload of [entries]: a battle log of `battle_protocol`, compressed
/// with gzip (stack decision 2).
Uint8List encodeBatch(List<LogEntry> entries) =>
    Uint8List.fromList(gzip.encode(_codec.encodeLog(entries)));

/// The entries of the upload [data].
///
/// Throws a [FormatException] for data that is not gzip, and a
/// [ProtocolException] for a log the protocol does not read.
List<LogEntry> decodeBatch(Uint8List data) =>
    _codec.decodeLog(Uint8List.fromList(gzip.decode(data)));

/// {@template appwrite_log_sink}
/// Battle logs in Appwrite Storage (Adapter, stack decision 2): one file per
/// batch in [bucketId], [encodeBatch]ed. A batch's file ID is the battle's
/// ID, `-` and the log position of its first entry on 12 digits, so
/// recovery finds the batch that follows one by its ID and needs no
/// query. A batch uploaded again finds its file there and leaves it.
/// {@endtemplate}
final class AppwriteLogSink implements LogSink {
  /// {@macro appwrite_log_sink}
  new(this.storage, {this.bucketId = battleLogsBucket});

  /// The Storage service of a server client.
  final Storage storage;

  /// The bucket.
  final String bucketId;

  /// The file ID of the batch of [battleId] that starts at the log
  /// position [from].
  ///
  /// Throws an [ArgumentError] for a battle ID that does not fit a file ID.
  static String fileId(String battleId, int from) {
    checkFileName(battleId, maxLength: maxStoredBattleId);
    return '$battleId-${from.toString().padLeft(12, '0')}';
  }

  @override
  Future<void> upload(LogBatch batch) async {
    checkBatch(batch);
    final id = fileId(batch.battleId, batch.from);
    try {
      await storage.createFile(
        bucketId: bucketId,
        fileId: id,
        file: InputFile.fromBytes(
          bytes: encodeBatch(batch.entries),
          filename: '$id.btlg.gz',
        ),
      );
    } on AppwriteException catch (error) {
      // 409: this batch was uploaded before; its file is the same.
      if (error.code != 409) rethrow;
    }
  }

  @override
  Future<List<LogEntry>> read(String battleId, {int from = 0}) async {
    final entries = <LogEntry>[];
    for (var at = from; ;) {
      final data = await _download(storage, bucketId, fileId(battleId, at));
      if (data == null) break;
      final batch = decodeBatch(data);
      if (batch.isEmpty) break;
      entries.addAll(batch);
      at += batch.length;
    }
    return List.unmodifiable(entries);
  }
}

/// {@template appwrite_snapshot_store}
/// Battle snapshots in Appwrite Storage (Adapter, stack decision 2): two
/// files per battle in [bucketId], `<battle>-s0` and `<battle>-s1`. A
/// snapshot replaces the older of the two, so the latest one stays whole
/// while the next is written, and a battle never holds more than two. A
/// file holds `BTSN`, the snapshot's log position and battle time, then
/// its data, compressed with gzip.
/// {@endtemplate}
final class AppwriteSnapshotStore implements SnapshotStore {
  /// {@macro appwrite_snapshot_store}
  new(this.storage, {this.bucketId = battleSnapshotsBucket});

  /// The Storage service of a server client.
  final Storage storage;

  /// The bucket.
  final String bucketId;

  /// The slot of each battle's latest snapshot, once known.
  final _latestSlot = <String, int>{};

  static String _fileId(String battleId, int slot) {
    checkFileName(battleId, maxLength: maxStoredBattleId);
    return '$battleId-s$slot';
  }

  @override
  Future<void> save(BattleSnapshot snapshot) async {
    final slot = 1 - (_latestSlot[snapshot.battleId] ?? 1);
    final id = _fileId(snapshot.battleId, slot);
    try {
      await storage.deleteFile(bucketId: bucketId, fileId: id);
    } on AppwriteException catch (error) {
      if (error.code != 404) rethrow;
    }
    final bytes = BytesBuilder(copy: false)..add(_snapshotMagic);
    writeCount(bytes, snapshot.position);
    writeCount(bytes, snapshot.time.inMicroseconds);
    bytes.add(snapshot.data);
    await storage.createFile(
      bucketId: bucketId,
      fileId: id,
      file: InputFile.fromBytes(
        bytes: gzip.encode(bytes.takeBytes()),
        filename: '$id.btsn.gz',
      ),
    );
    _latestSlot[snapshot.battleId] = slot;
  }

  @override
  Future<BattleSnapshot?> latest(String battleId) async {
    BattleSnapshot? latest;
    for (final slot in [0, 1]) {
      final id = _fileId(battleId, slot);
      final data = await _download(storage, bucketId, id);
      if (data == null) continue;
      final snapshot = _decode(battleId, Uint8List.fromList(gzip.decode(data)));
      if (latest == null || snapshot.isAfter(latest)) {
        latest = snapshot;
        _latestSlot[battleId] = slot;
      }
    }
    return latest;
  }

  static BattleSnapshot _decode(String battleId, Uint8List bytes) {
    final position = startsWith(bytes, _snapshotMagic)
        ? readCount(bytes, _snapshotMagic.length)
        : null;
    final time = position == null ? null : readCount(bytes, position.$2);
    if (time == null) {
      throw FormatException('not a snapshot file of $battleId');
    }
    return BattleSnapshot(
      battleId: battleId,
      position: position!.$1,
      time: Duration(microseconds: time.$1),
      data: Uint8List.sublistView(bytes, time.$2),
    );
  }
}

/// The file [fileId] of [bucketId]; null when there is none.
Future<Uint8List?> _download(
  Storage storage,
  String bucketId,
  String fileId,
) async {
  try {
    return await storage.getFileDownload(bucketId: bucketId, fileId: fileId);
  } on AppwriteException catch (error) {
    if (error.code == 404) return null;
    rethrow;
  }
}

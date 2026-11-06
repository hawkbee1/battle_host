import 'dart:io';
import 'dart:typed_data';

import 'package:battle_host/src/adapters/counts.dart';
import 'package:battle_host/src/ports/write_ahead_log.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// The first bytes of a write-ahead log file: `BTWL`.
const _magic = [0x42, 0x54, 0x57, 0x4C];

const _codec = BinaryProtocolCodec();

/// {@template file_write_ahead_log}
/// The write-ahead log on the host's disk (Adapter, stack decision 2): one
/// file per battle in [directory], `<battle>.wal`. It holds `BTWL`, the log
/// position of its first entry, then a battle log of `battle_protocol`
/// (`BTLG`, the version, one frame per entry). Each append is written,
/// then synced to disk (`fsync`) before it returns.
///
/// A host stopped in the middle of an append leaves a torn last frame:
/// reading drops it, and the next append writes over it. That entry was
/// never acknowledged.
/// {@endtemplate}
final class FileWriteAheadLog implements WriteAheadLog {
  /// {@macro file_write_ahead_log}
  new(this.directory);

  /// The folder of the files.
  final String directory;

  final _files = <String, (RandomAccessFile, int)>{};

  @override
  void append(String battleId, int position, LogEntry entry) {
    var (file, end) = _files[battleId] ?? _open(battleId);
    if (position < end) {
      throw StateError('$battleId already holds position $position');
    }
    if (position > end) {
      file.closeSync();
      file = _create(battleId, position);
    }
    file
      ..writeFromSync(_codec.logFrame(entry))
      // `flushSync` is `fsync` on the host's systems.
      ..flushSync();
    _files[battleId] = (file, position + 1);
  }

  @override
  HeldEntries read(String battleId) {
    final file = File(_path(battleId));
    if (!file.existsSync()) return (from: 0, entries: const []);
    final held = _scan(file.readAsBytesSync(), file.path);
    return (from: held.from, entries: _codec.decodeLog(held.log));
  }

  /// Closes the open files.
  void close() {
    for (final (file, _) in _files.values) {
      file.closeSync();
    }
    _files.clear();
  }

  String _path(String battleId) {
    checkFileName(battleId);
    return '$directory/$battleId.wal';
  }

  (RandomAccessFile, int) _open(String battleId) {
    final path = _path(battleId);
    if (!File(path).existsSync()) return (_create(battleId, 0), 0);
    final held = _scan(File(path).readAsBytesSync(), path);
    final file = File(path).openSync(mode: FileMode.append)
      ..truncateSync(held.length)
      ..setPositionSync(held.length);
    return (file, held.from + held.count);
  }

  RandomAccessFile _create(String battleId, int from) {
    final path = _path(battleId);
    Directory(directory).createSync(recursive: true);
    final header = BytesBuilder(copy: false)..add(_magic);
    writeCount(header, from);
    header.add(_codec.logHeader());
    // A new file appears whole or not at all.
    File('$path.new')
      ..writeAsBytesSync(header.takeBytes(), flush: true)
      ..renameSync(path);
    return File(path).openSync(mode: FileMode.append);
  }

  /// The log position of the first entry of the file [bytes] at [path],
  /// its battle log up to the last whole frame, how many frames that is,
  /// and the length of the file up to there.
  static ({int from, Uint8List log, int count, int length}) _scan(
    Uint8List bytes,
    String path,
  ) {
    final from = startsWith(bytes, _magic) ? readCount(bytes, 4) : null;
    final header = _codec.logHeader();
    if (from == null || !startsWith(bytes, header, from.$2)) {
      throw FormatException('not a write-ahead log of version 1: $path');
    }
    final start = from.$2;
    var end = start + header.length;
    var count = 0;
    while (true) {
      final frame = readCount(bytes, end);
      if (frame == null || frame.$2 + frame.$1 > bytes.length) break;
      end = frame.$2 + frame.$1;
      count++;
    }
    return (
      from: from.$1,
      log: Uint8List.sublistView(bytes, start, end),
      count: count,
      length: end,
    );
  }
}

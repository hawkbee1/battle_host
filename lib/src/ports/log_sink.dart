import 'package:battle_protocol/battle_protocol.dart';

/// Where the host writes its battle log (a port, stack decisions 2 and
/// 7): every accepted command with its events, and the events the host
/// makes on its own. The write-ahead log and the uploads implement it in
/// M5.15.
abstract interface class LogSink {
  /// Appends [entry] to the log of [battleId].
  void append(String battleId, LogEntry entry);
}

/// {@template memory_log_sink}
/// A log kept in memory, by battle: for tests and replays.
/// {@endtemplate}
final class MemoryLogSink implements LogSink {
  /// {@macro memory_log_sink}
  new();

  final _logs = <String, List<LogEntry>>{};

  /// The log of [battleId].
  List<LogEntry> logOf(String battleId) =>
      List.unmodifiable(_logs[battleId] ?? const <LogEntry>[]);

  @override
  void append(String battleId, LogEntry entry) =>
      (_logs[battleId] ??= []).add(entry);
}

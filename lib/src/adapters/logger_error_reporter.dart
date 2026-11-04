import 'package:battle_host/src/ports/error_reporter.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template logger_error_reporter}
/// Writes errors to the process's error output (Adapter): the reporter of
/// a host run without a Sentry DSN, in development.
/// {@endtemplate}
final class LoggerErrorReporter implements ErrorReporter {
  /// {@macro logger_error_reporter}
  const new(this._logger);

  final Logger _logger;

  @override
  Future<void> report(
    Object error,
    StackTrace stackTrace, {
    String? battleId,
  }) async {
    _logger.err('${battleId == null ? '' : '[$battleId] '}$error\n$stackTrace');
  }
}

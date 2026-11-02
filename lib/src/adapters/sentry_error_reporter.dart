import 'package:battle_host/src/ports/error_reporter.dart';
import 'package:sentry/sentry.dart';

/// {@template sentry_error_reporter}
/// Reports errors to Sentry (Adapter, stack decision 6), through a hub of
/// its own rather than the global `Sentry`, so nothing else in the process
/// shares it. A report carries the battle ID as a tag and no personal
/// data.
/// {@endtemplate}
final class SentryErrorReporter implements ErrorReporter {
  /// {@macro sentry_error_reporter}
  ///
  /// [dsn] comes from the environment, never from the code. [transport]
  /// replaces Sentry's HTTP transport, for tests.
  factory({
    required String dsn,
    required String environment,
    required String release,
    Transport? transport,
  }) {
    final options = SentryOptions(dsn: dsn)
      ..environment = environment
      ..release = release
      ..sendDefaultPii = false;
    if (transport != null) options.transport = transport;
    return SentryErrorReporter._(Hub(options));
  }

  new _(this._hub);

  final Hub _hub;

  @override
  Future<void> report(
    Object error,
    StackTrace stackTrace, {
    String? battleId,
  }) async {
    await _hub.captureException(
      error,
      stackTrace: stackTrace,
      withScope: (scope) async {
        if (battleId != null) await scope.setTag('battle', battleId);
      },
    );
  }

  /// Sends what is waiting and closes the hub.
  Future<void> close() => _hub.close();
}

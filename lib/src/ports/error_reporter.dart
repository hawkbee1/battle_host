/// Where the host reports its errors (a port, stack decision 7). Only the
/// host and the functions hold the Sentry adapter (stack decision 6); tests
/// use a fake.
abstract interface class ErrorReporter {
  /// Reports [error] with its [stackTrace], and the battle it happened in
  /// when there is one. Reports carry no personal data: IDs only.
  Future<void> report(Object error, StackTrace stackTrace, {String? battleId});
}

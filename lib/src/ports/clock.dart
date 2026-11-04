/// The host's wall clock (a port, stack decision 7). A battle's time is the
/// time since it started, read from this clock, so tests and simulated runs
/// move time by hand.
abstract interface class Clock {
  /// The current time, in UTC.
  DateTime now();
}

/// {@template manual_clock}
/// A clock that moves only when told: for tests and for simulated runs
/// that cover days in seconds.
/// {@endtemplate}
final class ManualClock implements Clock {
  /// {@macro manual_clock}
  new(this._now);

  DateTime _now;

  @override
  DateTime now() => _now;

  /// Moves the clock forward by [step].
  ///
  /// Throws an [ArgumentError] for a negative step: time never goes back.
  void advance(Duration step) {
    if (step.isNegative) {
      throw ArgumentError.value(step, 'step', 'must not be negative');
    }
    _now = _now.add(step);
  }
}

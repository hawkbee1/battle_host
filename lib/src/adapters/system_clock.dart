import 'package:battle_host/src/ports/clock.dart';

/// {@template system_clock}
/// The machine's clock, in UTC (Adapter, stack decision 7).
/// {@endtemplate}
final class SystemClock implements Clock {
  /// {@macro system_clock}
  const new();

  @override
  DateTime now() => DateTime.now().toUtc();
}

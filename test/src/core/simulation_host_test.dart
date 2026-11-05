import 'package:battle_host/battle_host.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

void main() {
  late ManualClock clock;
  late RecordingErrorReporter reporter;
  late SimulationHost host;

  setUp(() {
    clock = ManualClock(DateTime.utc(2026, 11, 2));
    reporter = RecordingErrorReporter();
    host = SimulationHost(
      clock: clock,
      maps: MapLibrary(
        source: MemoryMapSource({'valley': valley}),
        terrain: planData.terrain,
      ),
      definitions: planData,
      reporter: reporter,
    );
  });

  group(SimulationHost, () {
    test('COMBAT-02 a battle advanced by the injected clock gives the lazy '
        'AP of every unit', () {
      final battle = host.start(valleySetup())
        ..change((state) {
          var next = state;
          for (final unit in state.units.values) {
            next = next.withUnit(
              unit.copyWith(
                pool: ApPool(
                  max: unit.pool.max,
                  recoveryPerHour: unit.pool.recoveryPerHour,
                  value: 2,
                  updatedAt: Duration.zero,
                ),
              ),
            );
          }
          return next;
        });

      clock.advance(const Duration(hours: 5));
      host.advance();

      expect(battle.time, equals(const Duration(hours: 5)));
      for (final id in battle.state.units.keys) {
        expect(battle.apOf(id), equals(7), reason: id);
      }
    });

    test('decision 2 holds several battles, each on its own time', () {
      final first = host.start(valleySetup());
      clock.advance(const Duration(hours: 2));
      final second = host.start(valleySetup(battleId: 'b-2'));
      clock.advance(const Duration(hours: 1));

      host.advance();

      expect(host.battles, equals([first, second]));
      expect(host['b-2'], same(second));
      expect(first.time, equals(const Duration(hours: 3)));
      expect(second.time, equals(const Duration(hours: 1)));
    });

    test('refuses a battle ID already running', () {
      host.start(valleySetup());

      expect(() => host.start(valleySetup()), throwsArgumentError);
    });

    test('reports a failing battle and stops it; the others go on', () async {
      host
          .start(valleySetup())
          .schedule(const Duration(minutes: 1), const SectionUnlocks('s-9'));
      final other = host.start(valleySetup(battleId: 'b-2'));

      clock.advance(const Duration(hours: 1));
      host.advance();
      await Future<void>.delayed(Duration.zero);

      expect(host.failed, equals({'b-1'}));
      expect(host['b-1'], isNull);
      expect(host.battles, equals([other]));
      expect(other.time, equals(const Duration(hours: 1)));
      expect(reporter.reports, hasLength(1));
      expect(reporter.reports.single.$1, isA<StateError>());
      expect(reporter.reports.single.$2, equals('b-1'));
      expect(() => host.start(valleySetup()), throwsArgumentError);
    });
  });

  group(ManualClock, () {
    test('refuses to go back', () {
      expect(
        () => clock.advance(const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });
}

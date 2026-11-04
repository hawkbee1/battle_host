import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

class _MockLogger extends Mock implements Logger;

void main() {
  late Logger logger;
  late Directory maps;

  setUpAll(() {
    maps = Directory.systemTemp.createTempSync('maps');
    writeBuiltMap(valley, '${maps.path}/valley');
  });

  tearDownAll(() => maps.deleteSync(recursive: true));

  setUp(() => logger = _MockLogger());

  Future<int> run(
    List<String> args, {
    Map<String, String> environment = const {},
  }) => BattleHostCommandRunner(
    logger: logger,
    environment: environment,
  ).run(args);

  List<String> base() => [
    'run',
    '--plan',
    planPath,
    '--maps',
    maps.path,
    '--map',
    'valley',
  ];

  String summary() =>
      verify(() => logger.info(captureAny())).captured.single as String;

  test('BattleHostCommandRunner writes to the terminal by default', () {
    expect(BattleHostCommandRunner().executableName, equals(executableName));
  });

  group('battle_host run', () {
    test('stack decision 1 starts, loads a map and runs a battle with no '
        'order for a simulated day', () async {
      expect(await run(base()), equals(ExitCode.success.code));

      final line = summary();
      expect(line, contains('battle=simulated-valley map=valley teams=2 '));
      expect(line, contains('units=2 relics=6 simulated_s=86400 timers=0 '));
      expect(line, contains('failed=0 lowest_ap=30.0 '));
    });

    test('takes the days, the seed and the team count', () async {
      expect(
        await run([...base(), '--days', '3', '--seed', '9', '--teams', '3']),
        equals(ExitCode.success.code),
      );

      final line = summary();
      expect(line, contains('teams=3 units=3 '));
      expect(line, contains('simulated_s=259200 '));
    });

    test('reports to Sentry when SENTRY_DSN is set', () async {
      expect(
        await run(
          base(),
          environment: const {
            'SENTRY_DSN': 'https://public@sentry.example.com/1',
            'SENTRY_ENVIRONMENT': 'test',
          },
        ),
        equals(ExitCode.success.code),
      );
    });

    test('refuses a missing option or a value that is not a number', () async {
      expect(await run(['run', '--plan', planPath]), ExitCode.usage.code);
      expect(await run([...base(), '--days', 'two']), ExitCode.usage.code);
      expect(await run([...base(), '--days', '0']), ExitCode.usage.code);
      expect(await run([...base(), '--teams', 'x']), ExitCode.usage.code);
      expect(await run(['fly']), ExitCode.usage.code);
      verify(() => logger.err(any(that: contains('--maps is required'))))
          .called(1);
    });
  });
}

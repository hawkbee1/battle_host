import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:battle_host/battle_host.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

class _MockLogger extends Mock implements Logger;

/// An Appwrite that refuses every connection.
const _appwrite = {
  'APPWRITE_ENDPOINT': 'http://127.0.0.1:9/v1',
  'APPWRITE_PROJECT_ID': 'hawkbee',
  'APPWRITE_API_KEY': 'key',
};

void main() {
  late Logger logger;
  late Directory maps;
  late Directory data;

  setUpAll(() {
    maps = Directory.systemTemp.createTempSync('maps');
    writeBuiltMap(valley, '${maps.path}/valley');
  });

  tearDownAll(() => maps.deleteSync(recursive: true));

  setUp(() {
    logger = _MockLogger();
    data = Directory.systemTemp.createTempSync('wal');
  });

  tearDown(() => data.deleteSync(recursive: true));

  Future<int> serve(
    List<String> args, {
    Map<String, String> environment = _appwrite,
    Future<void> Function()? until,
  }) async {
    final runner = CommandRunner<int>('battle_host', 'test')
      ..addCommand(
        ServeCommand(
          logger: logger,
          environment: environment,
          until: until ?? () async {},
          second: Duration.zero,
        ),
      );
    final code = await runner.run(['serve', ...args]);
    return code!;
  }

  List<String> base() => [
    '--plan',
    planPath,
    '--maps',
    maps.path,
    '--map',
    'valley',
    '--data',
    data.path,
    '--host-id',
    'host-1',
    '--address',
    '127.0.0.1',
  ];

  group('battle_host serve', () {
    test('stack decision 1 serves its maps until it is asked to stop, and '
        'reports what Appwrite refuses', () async {
      final stop = Completer<void>();
      final code = serve([
        ...base(),
        '--poll',
        '1',
        '--port',
        '0',
      ], until: () => stop.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      stop.complete();

      expect(await code, ExitCode.success.code);
      verify(
        () => logger.info(
          'host=host-1 maps=valley address=http://host-1:0 starting',
        ),
      ).called(1);
      verify(
        () => logger.info(any(that: startsWith('host=host-1 listening port='))),
      ).called(1);
      verify(() => logger.info('host=host-1 stopped battles=0 failed=0'))
          .called(1);
      verify(() => logger.err(any())).called(greaterThan(1));
    });

    test('takes its ID from HOSTNAME and reports to Sentry when SENTRY_DSN '
        'is set', () async {
      final args = (base()..removeRange(8, 10))..addAll(['--port', '0']);

      expect(
        await serve(
          args,
          environment: {
            ..._appwrite,
            'HOSTNAME': 'container-7',
            'SENTRY_DSN': 'https://public@sentry.example.com/1',
          },
        ),
        ExitCode.success.code,
      );
      verify(
        () => logger.info(
          'host=container-7 maps=valley address=http://container-7:0 starting',
        ),
      ).called(1);
    });

    test('M6 Issue 6 writes the public address it is given, live behind '
        'the proxy', () async {
      expect(
        await serve([
          ...base(),
          '--port',
          '0',
          '--public-address',
          'https://h1.battleteam.example/',
          '--lease',
          '30',
        ]),
        ExitCode.success.code,
      );
      verify(
        () => logger.info(
          'host=host-1 maps=valley address=https://h1.battleteam.example '
          'starting',
        ),
      ).called(1);
    });

    test('needs its options and Appwrite', () async {
      for (final (args, environment) in [
        (<String>[], _appwrite),
        (base()..removeRange(4, 6), _appwrite),
        (base()..removeRange(8, 10), _appwrite),
        ([...base(), '--poll', '0'], _appwrite),
        ([...base(), '--lease', '10'], _appwrite),
        ([...base(), '--lease', 'x'], _appwrite),
        ([...base(), '--public-address', 'ws://h1:8080'], _appwrite),
        ([...base(), '--public-address', 'http:///v1'], _appwrite),
        ([...base(), '--public-address', 'http://h1?a=1'], _appwrite),
        ([...base(), '--public-address', 'http://h1#a'], _appwrite),
        ([...base(), '--public-address', '::'], _appwrite),
        ([...base(), '--port', 'x'], _appwrite),
        ([...base(), '--port', '70000'], _appwrite),
        (base(), const <String, String>{}),
        (base(), {..._appwrite, 'APPWRITE_API_KEY': ''}),
      ]) {
        await expectLater(
          serve(args, environment: environment),
          throwsA(isA<UsageException>()),
          reason: '$args',
        );
      }
    });
  });
}

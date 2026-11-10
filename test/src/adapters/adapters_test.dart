import 'dart:convert';
import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sentry/sentry.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

class _MockLogger extends Mock implements Logger;

/// Keeps what Sentry would send.
final class _RecordingTransport implements Transport {
  final envelopes = <SentryEnvelope>[];

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    envelopes.add(envelope);
    return SentryId.newId();
  }
}

Future<Map<String, Object?>> _event(SentryEnvelope envelope) async {
  final item = envelope.items.singleWhere(
    (item) => item.header.type == 'event',
  );
  return jsonDecode(utf8.decode(await item.dataFactory()))
      as Map<String, Object?>;
}

void main() {
  group(SystemClock, () {
    test('reads the machine clock in UTC', () {
      final now = const SystemClock().now();

      expect(now.isUtc, isTrue);
      expect(
        now.difference(DateTime.now().toUtc()).inSeconds.abs(),
        lessThan(5),
      );
    });
  });

  group(SentryErrorReporter, () {
    test('stack decision 6 reports an error with its battle and no personal '
        'data', () async {
      final transport = _RecordingTransport();
      final reporter = SentryErrorReporter(
        dsn: 'https://public@sentry.example.com/1',
        environment: 'development',
        release: hostRelease,
        transport: transport,
      );

      await reporter.report(
        StateError('no section s-9 to unlock'),
        StackTrace.current,
        battleId: 'b-1',
      );
      await reporter.report(StateError('outside a battle'), StackTrace.empty);
      await reporter.close();

      expect(transport.envelopes, hasLength(2));
      final event = await _event(transport.envelopes.first);
      expect(event['environment'], equals('development'));
      expect(event['release'], equals(hostRelease));
      expect(event['tags'], equals({'battle': 'b-1'}));
      expect(jsonEncode(event), contains('no section s-9 to unlock'));
      expect(event['user'], isNull);
      final second = await _event(transport.envelopes.last);
      expect(second['tags'], isNull);
    });
  });

  group(LoggerErrorReporter, () {
    test('writes the error and its battle to the error output', () async {
      final logger = _MockLogger();

      await LoggerErrorReporter(logger)
          .report(StateError('broken'), StackTrace.empty, battleId: 'b-1');
      await LoggerErrorReporter(logger)
          .report(StateError('loose'), StackTrace.empty);

      verify(() => logger.err(any(that: startsWith('[b-1] Bad state: broken'))))
          .called(1);
      verify(() => logger.err(any(that: startsWith('Bad state: loose'))))
          .called(1);
    });
  });

  group(DirectoryMapSource, () {
    test('reads a built map from its folder, every tile of it', () {
      final root = Directory.systemTemp.createTempSync('maps');
      addTearDown(() => root.deleteSync(recursive: true));
      writeBuiltMap(valley, '${root.path}/valley');

      final files = DirectoryMapSource(root.path).read('valley');

      expect(files.mapYaml, equals(valley.mapYaml));
      expect(files.tiles.keys, unorderedEquals(valley.tiles.keys));
      for (final MapEntry(key: name, value: tile) in valley.tiles.entries) {
        expect(files.tiles[name]!.heightsPng, equals(tile.heightsPng));
        expect(files.tiles[name]!.terrainPng, equals(tile.terrainPng));
        expect(files.tiles[name]!.objectsYaml, equals(tile.objectsYaml));
      }
    });
  });

  group('readPlan', () {
    test('reads the shared definitions and the default settings', () {
      final data = readPlan(planPath);

      expect(data.units.unitTypes, contains('commander'));
      expect(data.battle.ap.recoveryDelayS, equals(3600));
    });
  });
}

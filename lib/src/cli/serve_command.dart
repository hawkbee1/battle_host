import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:battle_backend/battle_backend.dart';
import 'package:battle_host/src/adapters/appwrite_storage.dart';
import 'package:battle_host/src/adapters/directory_map_source.dart';
import 'package:battle_host/src/adapters/file_write_ahead_log.dart';
import 'package:battle_host/src/adapters/logger_error_reporter.dart';
import 'package:battle_host/src/adapters/plan_files.dart';
import 'package:battle_host/src/adapters/sentry_error_reporter.dart';
import 'package:battle_host/src/adapters/system_clock.dart';
import 'package:battle_host/src/cli/run_command.dart';
import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_host/src/core/simulation_host.dart';
import 'package:battle_host/src/hosting/battle_placement.dart';
import 'package:battle_host/src/hosting/host_service.dart';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template serve_command}
/// `battle_host serve`: the host process of a container (stack decision 1,
/// hosting). It serves the maps `--map` of `--maps`, keeps its write-ahead
/// logs in `--data`, and runs the battles placed on it under `--host-id`
/// (`BattlePlacement`), with their logs and snapshots in Appwrite Storage.
/// It advances them every second until [_until] completes (the executable
/// passes SIGTERM and SIGINT; never by default), then snapshots them.
///
/// Appwrite comes from `APPWRITE_ENDPOINT`, `APPWRITE_PROJECT_ID` and
/// `APPWRITE_API_KEY`; errors go to Sentry when `SENTRY_DSN` is set.
/// {@endtemplate}
final class ServeCommand extends Command<int> {
  /// {@macro serve_command}
  new({
    required this._logger,
    required this._environment,
    this._until,
    this._second = const Duration(seconds: 1),
  }) {
    argParser
      ..addOption('plan', help: 'The plan folder, apps/battle_team/plan.')
      ..addOption('maps', help: 'The folder of the built maps.')
      ..addMultiOption('map', help: 'A map this host serves.')
      ..addOption('data', help: 'The folder of the write-ahead logs.')
      ..addOption(
        'host-id',
        help:
            'The ID of this host in the battles it runs; HOSTNAME by '
            'default.',
      )
      ..addOption(
        'poll',
        defaultsTo: '10',
        help: 'Seconds between two looks at the battles placed here.',
      );
  }

  final Logger _logger;
  final Map<String, String> _environment;
  final Future<void> Function()? _until;
  final Duration _second;

  @override
  String get name => 'serve';

  @override
  String get description =>
      'Runs the battles placed on this host until it is stopped.';

  @override
  Future<int> run() async {
    final args = argResults!;
    String option(String name) =>
        args.option(name) ?? usageException('--$name is required.');
    String variable(String name) => switch (_environment[name]) {
      final String value when value.isNotEmpty => value,
      _ => usageException('$name is required.'),
    };
    final plan = option('plan');
    final maps = option('maps');
    final data = option('data');
    final mapIds = args.multiOption('map').toSet();
    if (mapIds.isEmpty) usageException('--map is required.');
    final hostId =
        args.option('host-id') ??
        _environment['HOSTNAME'] ??
        usageException('--host-id is required.');
    final poll = int.tryParse(args.option('poll')!);
    if (poll == null || poll < 1) {
      usageException('--poll takes a whole number of seconds.');
    }
    final client = Client()
      ..setEndpoint(variable('APPWRITE_ENDPOINT'))
      ..setProject(variable('APPWRITE_PROJECT_ID'))
      ..setKey(variable('APPWRITE_API_KEY'));

    final definitions = readPlan(plan);
    final dsn = _environment['SENTRY_DSN'];
    final sentry = dsn == null || dsn.isEmpty
        ? null
        : SentryErrorReporter(
            dsn: dsn,
            environment: _environment['SENTRY_ENVIRONMENT'] ?? 'development',
            release: hostRelease,
          );
    final reporter = sentry ?? LoggerErrorReporter(_logger);
    final storage = Storage(client);
    final host = SimulationHost(
      clock: const SystemClock(),
      maps: MapLibrary(
        source: DirectoryMapSource(maps),
        terrain: definitions.terrain,
      ),
      definitions: definitions,
      reporter: reporter,
      wal: FileWriteAheadLog(data),
      logs: AppwriteLogSink(storage),
      snapshots: AppwriteSnapshotStore(storage),
    );
    final service = HostService(
      host: host,
      placement: BattlePlacement(
        rows: AppwriteRows(TablesDB(client)),
        host: host,
        hostId: hostId,
        mapIds: mapIds,
        reporter: reporter,
      ),
      poll: Duration(seconds: poll),
    );

    _logger.info('host=$hostId maps=${mapIds.join(',')} starting');
    await _guarded(service.start, reporter.report);
    var stopping = false;
    final stop = _until?.call() ?? Completer<void>().future;
    unawaited(stop.then((_) => stopping = true));
    while (!stopping) {
      await Future<void>.delayed(_second);
      if (!stopping) await _guarded(service.tick, reporter.report);
    }
    await service.stop();
    await sentry?.close();
    _logger.info(
      'host=$hostId stopped battles=${host.battles.length} '
      'failed=${host.failed.length}',
    );
    return ExitCode.success.code;
  }

  /// Runs [work]; an error goes to [report] and the host goes on.
  static Future<void> _guarded(
    Future<void> Function() work,
    Future<void> Function(Object, StackTrace) report,
  ) async {
    try {
      await work();
    } on Object catch (error, stackTrace) {
      await report(error, stackTrace);
    }
  }
}

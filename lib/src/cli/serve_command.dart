import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:battle_backend/battle_backend.dart';
import 'package:battle_host/src/adapters/appwrite_account_check.dart';
import 'package:battle_host/src/adapters/appwrite_storage.dart';
import 'package:battle_host/src/adapters/directory_map_source.dart';
import 'package:battle_host/src/adapters/file_write_ahead_log.dart';
import 'package:battle_host/src/adapters/host_server.dart';
import 'package:battle_host/src/adapters/logger_error_reporter.dart';
import 'package:battle_host/src/adapters/plan_files.dart';
import 'package:battle_host/src/adapters/sentry_error_reporter.dart';
import 'package:battle_host/src/adapters/system_clock.dart';
import 'package:battle_host/src/cli/run_command.dart';
import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_host/src/core/simulation_host.dart';
import 'package:battle_host/src/endpoints/endpoints.dart';
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
/// Players and AI agents reach them on `--address` and `--port`
/// (`HostServer`): JWTs are checked with Appwrite Auth, API keys in the
/// `bt_api_keys` table. Clients find it at `--public-address`, which it
/// writes in its `bt_hosts` row at each poll; the battles of a host whose
/// row is older than `--lease` move to another host of their map (M6
/// Issue 6).
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
        'address',
        defaultsTo: '0.0.0.0',
        help: 'The address the endpoints listen on.',
      )
      ..addOption(
        'port',
        defaultsTo: '8080',
        help:
            'The port of the endpoints: WebSocket and HTTPS behind the proxy.',
      )
      ..addOption(
        'public-address',
        help:
            'The base URL clients reach the endpoints at: https://… behind '
            'the reverse proxy live; http://<host-id>:<port> by default, '
            'its name on the Docker network.',
      )
      ..addOption(
        'poll',
        defaultsTo: '10',
        help: 'Seconds between two looks at the battles placed here.',
      )
      ..addOption(
        'lease',
        defaultsTo: '60',
        help:
            'Seconds after its last look before another host of its maps '
            'takes its battles; more than --poll.',
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
    final lease = int.tryParse(args.option('lease')!);
    if (lease == null || lease <= poll) {
      usageException('--lease takes more seconds than --poll.');
    }
    final port = int.tryParse(args.option('port')!);
    if (port == null || port < 0 || port > 65535) {
      usageException('--port takes a port number.');
    }
    final address = publicAddress(
      args.option('public-address') ?? 'http://$hostId:$port',
    );
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
    final endpoints = Endpoints(
      host: host,
      accounts: AppwriteAccountCheck.connect(
        endpoint: variable('APPWRITE_ENDPOINT'),
        project: variable('APPWRITE_PROJECT_ID'),
        keys: ApiKeys(
          rows: AppwriteRows(TablesDB(client)),
          admins: AppwriteAdmins(Users(client)),
        ),
      ),
    );
    final service = HostService(
      host: host,
      endpoints: endpoints,
      placement: BattlePlacement(
        rows: AppwriteRows(TablesDB(client)),
        host: host,
        hostId: hostId,
        mapIds: mapIds,
        address: address,
        lease: Duration(seconds: lease),
        reporter: reporter,
      ),
      poll: Duration(seconds: poll),
    );

    _logger.info(
      'host=$hostId maps=${mapIds.join(',')} address=$address starting',
    );
    await _guarded(service.start, reporter.report);
    final server = await HostServer.bind(
      endpoints,
      address: args.option('address')!,
      port: port,
    );
    _logger.info('host=$hostId listening port=${server.port}');
    var stopping = false;
    final stop = _until?.call() ?? Completer<void>().future;
    unawaited(stop.then((_) => stopping = true));
    while (!stopping) {
      await Future<void>.delayed(_second);
      if (!stopping) await _guarded(service.tick, reporter.report);
    }
    await server.close();
    await _guarded(service.stop, reporter.report);
    await sentry?.close();
    _logger.info(
      'host=$hostId stopped battles=${host.battles.length} '
      'failed=${host.failed.length}',
    );
    return ExitCode.success.code;
  }

  /// The public address [text], an `http` or `https` URL with a host and
  /// no query, without its trailing slash.
  ///
  /// Throws a [UsageException] for anything else.
  String publicAddress(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      usageException('--public-address takes an http or https URL.');
    }
    final address = uri.toString();
    return address.endsWith('/')
        ? address.substring(0, address.length - 1)
        : address;
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

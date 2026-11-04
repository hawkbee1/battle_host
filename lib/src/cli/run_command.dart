import 'package:args/command_runner.dart';
import 'package:battle_host/src/adapters/directory_map_source.dart';
import 'package:battle_host/src/adapters/logger_error_reporter.dart';
import 'package:battle_host/src/adapters/plan_files.dart';
import 'package:battle_host/src/adapters/sentry_error_reporter.dart';
import 'package:battle_host/src/core/battle_setup.dart';
import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_host/src/core/simulation_host.dart';
import 'package:battle_host/src/ports/clock.dart';
import 'package:mason_logger/mason_logger.dart';

/// The release the host reports to Sentry.
const hostRelease = 'battle_host@0.1.0';

/// {@template run_command}
/// `battle_host run`: starts the process, loads a built map and runs one
/// battle on it with no order for a number of simulated days, on a clock
/// that moves an hour at a time. Each team gets one new section: its
/// commander and the starting money (UNIT-41). Errors go to Sentry when
/// `SENTRY_DSN` is set, to the error output otherwise.
/// {@endtemplate}
final class RunCommand extends Command<int> {
  /// {@macro run_command}
  new({required this._logger, required this._environment}) {
    argParser
      ..addOption('plan', help: 'The plan folder, apps/battle_team/plan.')
      ..addOption('maps', help: 'The folder of the built maps.')
      ..addOption('map', help: 'The ID of the map: its folder in --maps.')
      ..addOption('days', defaultsTo: '1', help: 'Simulated days.')
      ..addOption('seed', defaultsTo: '1', help: 'The seed of the battle.')
      ..addOption(
        'teams',
        help: 'Team count; the smallest the map supports by default.',
      );
  }

  final Logger _logger;
  final Map<String, String> _environment;

  @override
  String get name => 'run';

  @override
  String get description => 'Runs one battle with no order for simulated days.';

  @override
  Future<int> run() async {
    final args = argResults!;
    String option(String name) =>
        args.option(name) ?? usageException('--$name is required.');
    final plan = option('plan');
    final maps = option('maps');
    final mapId = option('map');
    final days = int.tryParse(option('days'));
    final seed = int.tryParse(option('seed'));
    final teamsOption = args.option('teams');
    final teams = teamsOption == null ? null : int.tryParse(teamsOption);
    if (days == null ||
        days < 1 ||
        seed == null ||
        teamsOption != null && teams == null) {
      usageException('--days, --seed and --teams take whole numbers.');
    }

    final watch = Stopwatch()..start();
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
    final clock = ManualClock(DateTime.utc(2026));
    final host = SimulationHost(
      clock: clock,
      maps: MapLibrary(
        source: DirectoryMapSource(maps),
        terrain: definitions.terrain,
      ),
      definitions: definitions,
      reporter: reporter,
    );
    final map = host.maps.load(mapId);
    final counts = map.host.hqStarts.keys.toList()..sort();
    final teamCount = teams ?? counts.first;
    final commander = definitions.units.unitTypes.values.firstWhere(
      (type) => type.category == 'commander',
    );
    final battle = host.start(
      BattleSetup(
        battleId: 'simulated-$mapId',
        mapId: mapId,
        seed: seed,
        settings: definitions.battle,
        teams: [
          for (var team = 1; team <= teamCount; team++)
            TeamSetup(
              id: 'team-$team',
              sections: [
                SectionSetup(
                  id: 'section-$team',
                  accountId: 'server',
                  money: definitions.economy.minStartingMoney,
                  units: [UnitSetup(id: 'commander-$team', type: commander.id)],
                ),
              ],
            ),
        ],
      ),
    );
    for (var hour = 0; hour < days * 24; hour++) {
      clock.advance(const Duration(hours: 1));
      host.advance();
    }
    await sentry?.close();
    watch.stop();
    final lowestAp = battle.state.units.keys
        .map(battle.apOf)
        .reduce((a, b) => a < b ? a : b);
    _logger.info(
      'battle=${battle.id} map=$mapId teams=$teamCount '
      'units=${battle.state.units.length} '
      'relics=${battle.state.relics.length} '
      'simulated_s=${battle.time.inSeconds} timers=${battle.timersFired} '
      'failed=${host.failed.length} '
      'lowest_ap=$lowestAp wall_ms=${watch.elapsedMilliseconds}',
    );
    return ExitCode.success.code;
  }
}

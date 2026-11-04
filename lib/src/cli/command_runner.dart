import 'package:args/command_runner.dart';
import 'package:battle_host/src/cli/run_command.dart';
import 'package:mason_logger/mason_logger.dart';

/// The name of the executable.
const executableName = 'battle_host';

/// {@template battle_host_command_runner}
/// The command line of the simulation host.
/// {@endtemplate}
final class BattleHostCommandRunner extends CommandRunner<int> {
  /// {@macro battle_host_command_runner}
  new({Logger? logger, Map<String, String> environment = const {}})
    : _logger = logger ?? Logger(),
      super(executableName, 'The simulation host of Battle Team.') {
    addCommand(RunCommand(logger: _logger, environment: environment));
  }

  final Logger _logger;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      return await runCommand(parse(args)) ?? ExitCode.success.code;
    } on UsageException catch (error) {
      _logger
        ..err(error.message)
        ..info('')
        ..info(error.usage);
      return ExitCode.usage.code;
    }
  }
}

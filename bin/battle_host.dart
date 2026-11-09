import 'dart:async';
import 'dart:io';

import 'package:battle_host/battle_host.dart';

Future<void> main(List<String> args) async {
  final status = await BattleHostCommandRunner(
    environment: Platform.environment,
    until: _stopSignal,
  ).run(args);
  await Future.wait<void>([stdout.close(), stderr.close()]);
  exit(status);
}

/// Completes when the process is asked to stop: on SIGTERM (`docker stop`)
/// or SIGINT. Signals are watched on the main isolate only.
Future<void> _stopSignal() {
  final stopped = Completer<void>();
  final watches = [
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint])
      signal.watch().listen((_) {
        if (!stopped.isCompleted) stopped.complete();
      }),
  ];
  return stopped.future.whenComplete(() async {
    for (final watch in watches) {
      await watch.cancel();
    }
  });
}

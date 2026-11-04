import 'dart:io';

import 'package:battle_host/battle_host.dart';

Future<void> main(List<String> args) async {
  final status = await BattleHostCommandRunner(
    environment: Platform.environment,
  ).run(args);
  await Future.wait<void>([stdout.close(), stderr.close()]);
  exit(status);
}

@Tags(['appwrite', 'skip_very_good_optimization'])
library;

import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:test/test.dart';

import '../helpers/stores.dart';

/// The contracts of the stores on the local Appwrite (Liskov, stack
/// decision 7), in the buckets of `backend/appwrite.config.json`.
void main() {
  final environment = Platform.environment;
  final storage = Storage(
    Client()
        .setEndpoint(
          environment['APPWRITE_ENDPOINT'] ?? 'http://appwrite-traefik/v1',
        )
        .setProject(environment['APPWRITE_PROJECT_ID'] ?? 'hawkbee')
        .setKey(environment['APPWRITE_API_KEY'] ?? ''),
  );
  // The files stay in the buckets: each run takes battle IDs of its own.
  final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);

  group(AppwriteLogSink, () {
    logSinkContract(() => AppwriteLogSink(storage), ids: BattleIds('l$run'));
  });

  group(AppwriteSnapshotStore, () {
    snapshotStoreContract(
      () => AppwriteSnapshotStore(storage),
      ids: BattleIds('s$run'),
    );
  });
}

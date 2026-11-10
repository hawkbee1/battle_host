// Sets up a playtest battle on the local Appwrite: a 1 × 1 km map, team blue
// against team red, one beginner player each (a commander and the war's
// starting money, SOC-15). Once a host runs the battle, blue spends its
// money on four soldiers and a scout and deploys its section, as a player
// would, through the host's socket. The battle_team app then opens straight
// into it as blue (`lib/main_playtest.dart`).
//
// The battle is a testing battle (M7.2): `--fast`, on by default, gives it
// `test_units` and a recovery delay of 1 s (AP come back every second, so a
// soldier moves continuously), and blue's opening buys a test unit (10,000
// AP, every action, price 0). `--no-fast` plays the rules as written: one AP
// an hour, no test unit.
//
// Needs a host serving the map, for example in factory1:
//   dart run battle_host:battle_host serve --plan ../../apps/battle_team/plan \
//     --maps ../battle_map/maps/built --map saint_lo_1km --data build/playtest \
//     --host-id playtest --port 8091 --public-address http://localhost:8091
// or the compose host host-saint-lo-1, which serves saint_lo_1km too (see
// docs/battle_team/playtest.md, "With the Docker host"). Then, from
// packages/battle_host:
//   APPWRITE_API_KEY=<tooling key> dart run tool/playtest.dart [--no-fast]
//
// It writes the blue player's sign-in and the battle to
// apps/battle_team/env/playtest.json (not committed). Each run starts a new
// war and battle, and closes the playtest battles still running.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:battle_backend/battle_backend.dart';
import 'package:battle_client/battle_client.dart' as client;
import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:hawkbee_schema/hawkbee_schema.dart';

const _map = 'saint_lo_1km';
const _envFile = '../../apps/battle_team/env/playtest.json';

/// The settings of a fast playtest battle (decisions 238, 239): a testing
/// battle with a 1 s recovery delay.
const _fastSettings = <String, Object?>{
  'ap': {'recovery_delay_s': 1},
  'test_units': true,
};
const _players = {
  'blue': ('bt-blue', 'blue@battleteam.local', 'Blue'),
  'red': ('bt-red', 'red@battleteam.local', 'Red'),
};

Future<void> main(List<String> args) async {
  final fast = !args.contains('--no-fast');
  final environment = Platform.environment;
  final endpoint =
      environment['APPWRITE_ENDPOINT'] ?? 'http://appwrite-traefik/v1';
  final project = environment['APPWRITE_PROJECT_ID'] ?? 'hawkbee';
  final key = environment['APPWRITE_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('Set APPWRITE_API_KEY (users and tables scopes).');
    exit(64);
  }
  final appwrite = Client()
      .setEndpoint(endpoint)
      .setProject(project)
      .setKey(key);
  final users = Users(appwrite);
  final rows = AppwriteRows(TablesDB(appwrite));
  final random = Random.secure();

  // The players: a fresh password each run.
  final passwords = <String, String>{};
  for (final MapEntry(key: team, value: (id, email, name))
      in _players.entries) {
    final password = _password(random);
    passwords[team] = password;
    try {
      await users.create(
        userId: id,
        email: email,
        password: password,
        name: name,
      );
      print('created the account $email');
    } on AppwriteException catch (error) {
      if (error.code != 409) rethrow;
      await users.updatePassword(userId: id, password: password);
      print('reset the password of $email');
    }
  }

  // The playtest battles still running are closed.
  for (final (:id, :data) in await rows.find(AppwriteIds.battlesTableId, {
    'status': BattleStatus.running.name,
    'map_id': _map,
  })) {
    await rows.put(
      AppwriteIds.battlesTableId,
      id,
      BattleRow.fromData(
        id,
        data,
      ).copyWith(status: BattleStatus.closed).toData(),
    );
    print('closed the battle $id');
  }

  // A war, its two sections, and its battle started, blue and red.
  final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final warId = 'pt-$run';
  final battleId = 'pt-$run-1';
  final wars = Wars(
    rows: rows,
    admins: const _PlaytestAdmin(),
    data: readPlan('../../apps/battle_team/plan'),
  );
  await wars.create(caller: 'playtest', warId: warId);
  final sections = <String, String>{};
  for (final MapEntry(key: team, value: (id, _, _)) in _players.entries) {
    sections[team] = (await wars.join(caller: id, warId: warId)).id;
  }
  await wars.plan(
    caller: 'playtest',
    warId: warId,
    battleId: battleId,
    mapId: _map,
    seed: random.nextInt(1 << 31),
    settings: fast ? _fastSettings : const {},
  );
  final started = await wars.start(caller: 'playtest', battleId: battleId);
  await rows.put(
    AppwriteIds.battlesTableId,
    battleId,
    started
        .copyWith(
          teams: {
            for (final MapEntry(key: team, value: section) in sections.entries)
              team: [section],
          },
        )
        .toData(),
  );
  print(
    'started the battle $battleId on $_map: blue against red'
    '${fast ? ' (fast: 1 s recovery delay, test units)' : ''}',
  );

  // Blue's opening, once a host runs the battle.
  stdout.write('waiting for a host to claim it');
  for (var tries = 0; ; tries++) {
    final row = BattleRow.fromData(
      battleId,
      (await rows.get(AppwriteIds.battlesTableId, battleId))!,
    );
    if (row.host != null) break;
    if (tries == 60) {
      stdout.writeln();
      stderr.writeln(
        'No host claimed $battleId within a minute: start one serving '
        '$_map, then run this again.',
      );
      exit(1);
    }
    stdout.write('.');
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  stdout.writeln();
  await _open(
    battleId: battleId,
    testUnit: fast,
    finder: client.AppwriteHostFinder(
      endpoint: Uri.parse(endpoint),
      project: project,
    ),
    jwt: () async => (await users.createJWT(userId: _players['blue']!.$1)).jwt,
  );

  final (_, blueEmail, _) = _players['blue']!;
  final settings = {
    'BT_PLAYTEST_EMAIL': blueEmail,
    'BT_PLAYTEST_PASSWORD': passwords['blue'],
    'BT_PLAYTEST_BATTLE': battleId,
  };
  File(_envFile).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(settings)}\n',
  );
  print('wrote $_envFile');
}

/// Blue buys four soldiers and a scout with its starting money, and a test
/// unit when the battle allows it ([testUnit]), then deploys every unit it
/// holds in the HQ.
Future<void> _open({
  required String battleId,
  required bool testUnit,
  required client.AppwriteHostFinder finder,
  required Future<String> Function() jwt,
}) async {
  final blue = client.BattleClient(
    battleId: battleId,
    transport: const client.WebSocketTransport(),
    address: (credential) => finder.socketOf(battleId, credential),
    credential: () async => client.Credential.jwt(await jwt()),
    clock: const client.SystemClock(),
    random: Random.secure(),
  );
  final signedIn = blue.statuses.firstWhere(
    (status) => status == client.ClientStatus.signedIn,
  );
  blue.start();
  await signedIn.timeout(const Duration(seconds: 30));
  Future<void> send(Order order) async {
    final answer = await blue.send(order).timeout(const Duration(seconds: 10));
    final result = answer.accepted ? 'accepted' : answer.refusal;
    print('  ${order.runtimeType}: $result');
  }

  final types = [
    'soldier',
    'soldier',
    'soldier',
    'soldier',
    'scout',
    if (testUnit) 'test_unit',
  ];
  for (final type in types) {
    await send(BuyUnit(unitType: type));
  }
  final stored = [
    for (final unit in blue.view.units.values)
      if (unit.private?.place == UnitPlace.stored) unit.unitId,
  ];
  for (final unitId in stored) {
    await send(Deploy(unitId: unitId));
  }
  for (final unit in blue.view.units.values) {
    final at = unit.position;
    print(
      '  ${unit.unitId} (${unit.unitType}): '
      '${at == null ? 'not on the field' : '(${at.x}, ${at.y}) m'}',
    );
  }
  await blue.close();
  finder.close();
}

String _password(Random random) {
  const letters = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return [for (var i = 0; i < 20; i++) letters[random.nextInt(letters.length)]]
      .join();
}

/// The tool runs with the tooling key: it is the admin.
final class _PlaytestAdmin implements Admins {
  const new();

  @override
  Future<bool> isAdmin(String accountId) async => true;
}

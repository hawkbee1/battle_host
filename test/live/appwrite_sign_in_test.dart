@Tags(['appwrite', 'skip_very_good_optimization'])
library;

import 'dart:io';

import 'package:battle_backend/battle_backend.dart';
import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:test/test.dart';

import '../helpers/endpoints.dart';
import '../helpers/fixtures.dart';
import '../helpers/orders.dart';

/// The sign-in on the local Appwrite (M6 Issue 5): JWTs of Appwrite Auth
/// and keys in `bt_api_keys`. The key in `APPWRITE_API_KEY` needs the
/// scopes `users.read`, `users.write`, `rows.read` and `rows.write`. The
/// test creates two users and deletes them at the end.
void main() {
  final environment = Platform.environment;
  final endpoint =
      environment['APPWRITE_ENDPOINT'] ?? 'http://appwrite-traefik/v1';
  final project = environment['APPWRITE_PROJECT_ID'] ?? 'hawkbee';
  final client = Client()
      .setEndpoint(endpoint)
      .setProject(project)
      .setKey(environment['APPWRITE_API_KEY'] ?? '');
  final users = Users(client);
  final keys = ApiKeys(
    rows: AppwriteRows(TablesDB(client)),
    admins: AppwriteAdmins(users),
  );
  final check = AppwriteAccountCheck.connect(
    endpoint: endpoint,
    project: project,
    keys: keys,
  );
  final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final accounts = ['m65a$run', 'm65b$run'];

  setUpAll(() async {
    for (final id in accounts) {
      await users.create(userId: id, name: 'M6.5 sign-in test');
    }
  });

  tearDownAll(() async {
    for (final id in accounts) {
      await users.delete(userId: id);
    }
  });

  group(AppwriteAccountCheck, () {
    accountCheckContract(
      () async => _LiveFixture(check, users, keys),
      accounts: accounts,
    );
  });

  test('stack decision 3 a player signs in to a battle with a JWT of the '
      'local Appwrite', () async {
    final host = SimulationHost(
      clock: ManualClock(DateTime.utc(2026, 11, 8)),
      maps: MapLibrary(
        source: MemoryMapSource({'valley': valley}),
        terrain: planData.terrain,
      ),
      definitions: planData,
      reporter: RecordingErrorReporter(),
    );
    deploy(host.start(ordersSetup(accountTwo: accounts.first)));
    final endpoints = Endpoints(host: host, accounts: check);
    final socket = FakeSocket();
    final token = (await users.createJWT(userId: accounts.first)).jwt;

    final connection = endpoints.open(socket)
      ..receive(
        frameOf(
          SignIn(battleId: 'b-1', kind: CredentialKind.jwt, credential: token),
        ),
      );
    await connection.settled;
    await pumpEventQueue();

    expect(
      socket.messages.first,
      isA<SignInAccepted>()
          .having((m) => m.accountId, 'accountId', accounts.first)
          .having((m) => m.sectionId, 'sectionId', 's-2'),
    );
  });
}

final class _LiveFixture implements AccountFixture {
  new(this.check, this._users, this._keys);

  @override
  final AccountCheck check;

  final Users _users;
  final ApiKeys _keys;

  @override
  Future<String> jwtOf(String accountId) async =>
      (await _users.createJWT(userId: accountId)).jwt;

  @override
  Future<String> keyOf(String accountId) => _keys.create(caller: accountId);

  @override
  Future<void> revoke(String accountId) =>
      _keys.revoke(caller: accountId, accountId: accountId);
}

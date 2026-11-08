@Tags(['appwrite', 'skip_very_good_optimization'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:battle_backend/battle_backend.dart';
import 'package:battle_client/battle_client.dart' as client;
import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:hawkbee_schema/hawkbee_schema.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../src/hosting/battle_placement_test.dart';

/// The client's clock.
final class _Clock implements client.Clock {
  @override
  DateTime now() => DateTime.now().toUtc();
}

/// Reaching a battle's host on the local Appwrite (M6 Issue 6): the
/// placement writes `bt_hosts` and `bt_battles`, the client asks the
/// deployed `bt_battle_host` function with a JWT of Appwrite Auth, and the
/// hosts run on the loopback interface. The key in `APPWRITE_API_KEY`
/// needs `users.read`, `users.write`, `rows.read` and `rows.write`. The
/// test creates two users, a war, two sections and a battle on the map
/// `valley`, and deletes them at the end; snapshots and logs stay in
/// memory.
void main() {
  final environment = Platform.environment;
  final endpoint =
      environment['APPWRITE_ENDPOINT'] ?? 'http://appwrite-traefik/v1';
  final project = environment['APPWRITE_PROJECT_ID'] ?? 'hawkbee';
  final appwrite = Client()
      .setEndpoint(endpoint)
      .setProject(project)
      .setKey(environment['APPWRITE_API_KEY'] ?? '');
  final users = Users(appwrite);
  final rows = AppwriteRows(TablesDB(appwrite));
  final accounts = AppwriteAccountCheck.connect(
    endpoint: endpoint,
    project: project,
    keys: ApiKeys(rows: rows, admins: AppwriteAdmins(users)),
  );
  final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  String id(String name) => 'm66$name$run';
  final created = <(String, String)>[];
  final servers = <HostServer>[];

  Future<void> put(String table, String rowId, RowData data) async {
    await rows.put(table, rowId, data);
    created.add((table, rowId));
  }

  setUpAll(() async {
    for (final user in [id('u1'), id('u2')]) {
      await users.create(userId: user, name: 'M6.6 host address test');
    }
    final source = await warRows();
    final copies = {
      AppwriteIds.warsTableId: {'w-1': id('w')},
      AppwriteIds.sectionsTableId: {'s-1': id('s1'), 's-2': id('s2')},
    };
    for (final MapEntry(key: table, value: ids) in copies.entries) {
      for (final MapEntry(key: from, value: to) in ids.entries) {
        final data = {...?(await source.get(table, from))};
        if (table == AppwriteIds.sectionsTableId) {
          data
            ..['war_id'] = id('w')
            ..['account_id'] = from == 's-1' ? id('u1') : id('u2')
            ..['guild_id'] = null;
        }
        await put(table, to, data);
      }
    }
    await put(
      AppwriteIds.battlesTableId,
      id('b'),
      BattleRow(
        id: id('b'),
        warId: id('w'),
        mapId: 'valley',
        seed: 3,
        status: BattleStatus.running,
        teams: {
          'team-1': [id('s1')],
          'team-2': [id('s2')],
        },
      ).toData(),
    );
  });

  tearDownAll(() async {
    for (final server in servers) {
      await server.close();
    }
    for (final (table, rowId) in created.reversed) {
      await rows.delete(table, rowId);
    }
    for (final hostId in [id('ha'), id('hb')]) {
      await rows.delete(AppwriteIds.hostsTableId, hostId);
    }
    for (final user in [id('u1'), id('u2')]) {
      await users.delete(userId: user);
    }
  });

  test('M6 Issue 6 a client given only a battle ID signs in to its host, '
      'and reaches it again on another container', () async {
    final snapshots = MemorySnapshotStore();
    final logs = MemoryLogSink();

    Future<(SimulationHost, HostServer, BattlePlacement)> container(
      String hostId,
    ) async {
      final host = hostOn(snapshots: snapshots, logs: logs);
      final server = await HostServer.bind(
        Endpoints(host: host, accounts: accounts),
        address: InternetAddress.loopbackIPv4,
        port: 0,
        closeGrace: const Duration(milliseconds: 100),
      );
      servers.add(server);
      final placement = BattlePlacement(
        rows: rows,
        host: host,
        hostId: hostId,
        mapIds: const {'valley'},
        address: 'http://127.0.0.1:${server.port}',
        reporter: RecordingErrorReporter(),
      );
      await placement.sync();
      return (host, server, placement);
    }

    final finder = client.AppwriteHostFinder(
      endpoint: Uri.parse(endpoint),
      project: project,
    );
    final connected = <Uri>[];
    final battleClient = client.BattleClient(
      battleId: id('b'),
      transport: _Recording(connected),
      address: (credential) => finder.socketOf(id('b'), credential),
      credential: () async =>
          client.Credential.jwt((await users.createJWT(userId: id('u2'))).jwt),
      clock: _Clock(),
      random: Random(6),
      settings: const client.ClientSettings(
        backoff: client.Backoff(
          first: Duration(milliseconds: 200),
          max: Duration(seconds: 2),
        ),
      ),
    );
    addTearDown(() async {
      await battleClient.close();
      finder.close();
    });
    Future<void> signedIn() => battleClient.statuses
        .firstWhere((status) => status == client.ClientStatus.signedIn)
        .timeout(const Duration(seconds: 30));

    final (a, aServer, aPlacement) = await container(id('ha'));
    expect(a[id('b')], isNotNull);
    final first = signedIn();
    battleClient.start();
    await first;
    expect(connected.single.port, aServer.port);
    expect(battleClient.seat!.sectionId, id('s2'));

    final again = signedIn();
    await aServer.close();
    await HostService(host: a, placement: aPlacement).stop();
    final (b, bServer, _) = await container(id('hb'));
    await again;

    expect(b[id('b')], isNotNull);
    expect(connected.last.port, bServer.port);
    final answer = await battleClient
        .send(const Reload(unitId: 'c-2'))
        .timeout(const Duration(seconds: 10));
    expect(answer.requestId, isPositive);
  });
}

final class _Recording implements client.Transport {
  new(this.uris);

  final List<Uri> uris;

  @override
  Future<client.TransportSocket> connect(Uri uri) {
    uris.add(uri);
    return const client.WebSocketTransport().connect(uri);
  }
}

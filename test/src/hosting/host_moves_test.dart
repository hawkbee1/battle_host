import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:battle_backend/battle_backend.dart';
import 'package:battle_client/battle_client.dart' as client;
import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';
import 'battle_placement_test.dart';

/// The client's clock.
final class _Clock implements client.Clock {
  final _clock = ManualClock(DateTime.utc(2026, 11, 6));

  @override
  DateTime now() => _clock.now();
}

/// The WebSocket transport, counting where it connects.
final class _Counting implements client.Transport {
  final uris = <Uri>[];

  @override
  Future<client.TransportSocket> connect(Uri uri) {
    uris.add(uri);
    return const client.WebSocketTransport().connect(uri);
  }
}

/// One host process of the map `valley` on the loopback interface, as a
/// container runs it (`battle_host serve`): its simulation, endpoints and
/// placement, on the shared tables and uploads.
final class _Container {
  new _(this.host, this.endpoints, this.server, this.placement);

  static Future<_Container> start(
    String hostId, {
    required Rows rows,
    required MemorySnapshotStore snapshots,
    required MemoryLogSink logs,
    required AccountCheck accounts,
    Duration clockAhead = Duration.zero,
  }) async {
    final host = hostOn(snapshots: snapshots, logs: logs);
    (host.clock as ManualClock).advance(clockAhead);
    final endpoints = Endpoints(host: host, accounts: accounts);
    final server = await HostServer.bind(
      endpoints,
      address: InternetAddress.loopbackIPv4,
      port: 0,
      closeGrace: const Duration(milliseconds: 100),
    );
    final placement = BattlePlacement(
      rows: rows,
      host: host,
      hostId: hostId,
      mapIds: const {'valley'},
      address: 'http://127.0.0.1:${server.port}',
      reporter: RecordingErrorReporter(),
    );
    await placement.sync();
    return _Container._(host, endpoints, server, placement);
  }

  final SimulationHost host;
  final Endpoints endpoints;
  final HostServer server;
  final BattlePlacement placement;

  /// A planned stop: the last snapshots, then it lets go of its battles.
  Future<void> stop() async {
    await server.close();
    await HostService(host: host, placement: placement).stop();
  }

  /// A crash: its sockets drop, its rows stay as they were.
  Future<void> crash() => server.close();
}

/// M6 Issue 6 on the loopback interface: a client given only a battle ID
/// finds its host through `bt_battle_host`'s logic (`BattleHosts`) over
/// the same tables, and follows the battle to another container.
void main() {
  late MemoryRows rows;
  late MemorySnapshotStore snapshots;
  late MemoryLogSink logs;
  late MemoryAccountCheck accounts;
  late _Counting transport;
  late client.BattleClient battleClient;
  final containers = <_Container>[];

  Future<_Container> container(
    String hostId, {
    Duration clockAhead = Duration.zero,
  }) async {
    final started = await _Container.start(
      hostId,
      rows: rows,
      snapshots: snapshots,
      logs: logs,
      accounts: accounts,
      clockAhead: clockAhead,
    );
    containers.add(started);
    return started;
  }

  setUp(() async {
    rows = await warRows();
    snapshots = MemorySnapshotStore();
    logs = MemoryLogSink();
    accounts = MemoryAccountCheck(jwts: const {'jwt-2': 'a-2'});
    transport = _Counting();
    final hosts = BattleHosts(rows: rows, keys: accounts.keys);
    battleClient = client.BattleClient(
      battleId: 'b-1',
      transport: transport,
      address: (credential) async => client.socketAddress(
        await hosts.addressOf(
          battleId: 'b-1',
          caller: (await accounts.jwt(credential.secret))!,
        ),
      ),
      credential: () async => const client.Credential.jwt('jwt-2'),
      clock: _Clock(),
      random: Random(3),
      settings: const client.ClientSettings(
        backoff: client.Backoff(
          first: Duration(milliseconds: 20),
          max: Duration(milliseconds: 200),
        ),
      ),
    );
  });

  tearDown(() async {
    await battleClient.close();
    for (final each in containers) {
      await each.server.close();
    }
    containers.clear();
  });

  Future<void> signedIn() => battleClient.statuses
      .firstWhere((status) => status == client.ClientStatus.signedIn)
      .timeout(const Duration(seconds: 10));

  /// A command to the battle, answered by the host that runs it.
  Future<client.CommandAnswer> reload() => battleClient
      .send(const Reload(unitId: 'c-2'))
      .timeout(const Duration(seconds: 10));

  test('M6 Issue 6 a client given only a battle ID opens a socket to its '
      'host and signs in', () async {
    final a = await container('host-a');
    final first = signedIn();
    battleClient.start();
    await first;

    expect(transport.uris.single.port, a.server.port);
    expect(battleClient.seat!.sectionId, 's-2');
    await reload();
    expect(
      a.host.wal.read('b-1').entries.last.command?.order,
      const Reload(unitId: 'c-2'),
    );
  });

  test('M6 Issue 6 a host restarted on another container: the client '
      'reaches the battle again', () async {
    final a = await container('host-a');
    final first = signedIn();
    battleClient.start();
    await first;

    final again = signedIn();
    await a.stop();
    final b = await container('host-b');
    await again;

    expect(transport.uris.last.port, b.server.port);
    expect(b.host['b-1'], isNotNull);
    expect(a.host['b-1'], isNull);
    expect(battleClient.view.isWhole, isTrue);
    expect(battleClient.view.units.keys, contains('c-2'));
    await reload();
    expect(
      b.host.wal.read('b-1').entries.last.command?.order,
      const Reload(unitId: 'c-2'),
    );
  });

  test('M6 Issue 6 a host that crashed: once its lease ends another '
      'container takes the battle, and the client follows it', () async {
    final a = await container('host-a');
    final first = signedIn();
    battleClient.start();
    await first;
    await a.host.settle();

    final again = signedIn();
    await a.crash();
    // Within the lease, the battle stays with its host.
    final early = await container(
      'host-b',
      clockAhead: const Duration(seconds: 30),
    );
    expect(early.host['b-1'], isNull);
    final late = await container(
      'host-c',
      clockAhead: const Duration(minutes: 1),
    );
    await again;

    expect(late.host['b-1'], isNotNull);
    expect(transport.uris.last.port, late.server.port);
    await reload();
    expect(
      late.host.wal.read('b-1').entries.last.command?.order,
      const Reload(unitId: 'c-2'),
    );
  });
}

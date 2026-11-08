import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:battle_client/battle_client.dart' as client;
import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

import '../../helpers/orders.dart';

const _binary = BinaryProtocolCodec();

/// The client's clock on the host's [ManualClock].
final class _Clock implements client.Clock {
  new(this._clock);

  final ManualClock _clock;

  @override
  DateTime now() => _clock.now();
}

/// The WebSocket transport, whose socket drops right after a command goes
/// out when [dropNext]: the host gets the command, the client never gets
/// its answer.
final class _Dropping implements client.Transport {
  bool dropNext = false;
  int connections = 0;

  @override
  Future<client.TransportSocket> connect(Uri uri) async {
    connections++;
    return _DroppingSocket(
      this,
      await const client.WebSocketTransport().connect(uri),
    );
  }
}

final class _DroppingSocket implements client.TransportSocket {
  new(this._owner, this._inner);

  final _Dropping _owner;
  final client.TransportSocket _inner;
  var _dropped = false;

  @override
  Stream<Uint8List> get frames => _inner.frames.where((_) => !_dropped);

  @override
  void send(Uint8List frame) {
    _inner.send(frame);
    if (_owner.dropNext && _binary.decodeClientMessage(frame) is SendCommand) {
      _owner.dropNext = false;
      _dropped = true;
      unawaited(_inner.close());
    }
  }

  @override
  Future<void> close() => _inner.close();
}

final class _Recorder implements SectionSubscriber {
  final messages = <HostMessage>[];

  @override
  void send(HostMessage message) => messages.add(message);
}

/// `battle_client` against the endpoints on the loopback interface (M6
/// Issue 7, M6 conventions).
void main() {
  late OrdersFixture f;
  late MemoryAccountCheck accounts;
  late HostServer server;
  final clients = <client.BattleClient>[];

  setUp(() async {
    f = OrdersFixture();
    accounts = MemoryAccountCheck(jwts: const {'jwt-2': 'a-2'});
    server = await HostServer.bind(
      Endpoints(host: f.host, accounts: accounts),
      address: InternetAddress.loopbackIPv4,
      port: 0,
      closeGrace: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    for (final each in clients) {
      await each.close();
    }
    clients.clear();
    await server.close();
  });

  client.BattleClient connect(
    client.Transport transport,
    client.Credential credential,
  ) {
    final battleClient = client.BattleClient(
      battleId: 'b-1',
      transport: transport,
      address: (_) async =>
          Uri.parse('ws://127.0.0.1:${server.port}/v1/socket'),
      credential: () async => credential,
      clock: _Clock(f.clock),
      random: Random(5),
      settings: const client.ClientSettings(
        backoff: client.Backoff(
          first: Duration(milliseconds: 20),
          max: Duration(milliseconds: 100),
        ),
      ),
    );
    clients.add(battleClient);
    return battleClient;
  }

  /// The host's whole view of [sectionId] now.
  SectionView hostView(String sectionId) {
    final recorder = _Recorder();
    f.host
      ..subscribe('b-1', sectionId, recorder)
      ..unsubscribe('b-1', recorder);
    return recorder.messages.first as SectionView;
  }

  void expectSameView(client.HeldView view, SectionView host) {
    expect(view.units, equals({for (final u in host.units) u.unitId: u}));
    expect(view.hqs, equals({for (final h in host.hqs) h.team: h}));
    expect(view.relics.values, orderedEquals(host.relics));
    expect(view.section, equals(host.section));
    expect(view.hold, equals(host.hold));
    expect(view.world, orderedEquals(host.world));
  }

  test(
    'stack decision 3 a socket dropped with a command in flight: after '
    'reconnection the command is carried out once and the view is whole',
    () async {
      final transport = _Dropping();
      final battleClient = connect(
        transport,
        const client.Credential.jwt('jwt-2'),
      );
      final signedIn = battleClient.statuses.firstWhere(
        (status) => status == client.ClientStatus.signedIn,
      );
      battleClient.start();
      await signedIn;
      final before = f.entries.length;

      transport.dropNext = true;
      final answer = await battleClient
          .send(const Reload(unitId: 'soldier-2'))
          .timeout(const Duration(seconds: 10));

      final logged = f.entries
          .sublist(before)
          .where(
            (entry) =>
                entry.command?.order == const Reload(unitId: 'soldier-2'),
          )
          .toList();
      expect(transport.connections, equals(2));
      expect(logged, hasLength(1));
      expect(answer.seq, equals(logged.single.command!.seq));
      expect(battleClient.unanswered, isEmpty);
      expect(battleClient.view.isWhole, isTrue);
      expectSameView(battleClient.view, hostView('s-2'));
    },
  );

  test('AI-03 AI-04 the example agent signs in with an API key and fires at '
      'the nearest enemy its section sees', () async {
    final key = await accounts.keys.create(caller: 'a-2');
    final battleClient = connect(
      const client.WebSocketTransport(),
      client.Credential.apiKey(key),
    );
    final agent = client.NearestEnemyAgent(battleClient);
    final subscription = agent.start();
    final answered = battleClient.messages.firstWhere(
      (message) => message is CommandAccepted || message is CommandRefused,
    );
    battleClient.start();
    await answered.timeout(const Duration(seconds: 10));
    await subscription.cancel();

    final fired = f.entries.where((entry) => entry.command?.order is Fire);
    expect(fired, isNotEmpty);
    expect(fired.first.command!.origin, equals(Origin.ai));
    expect(fired.first.command!.sender.sectionId, equals('s-2'));
    final target = (fired.first.command!.order as Fire).targetId;
    expect(f.battle.state.units[target]!.sectionId, isNot('s-2'));
  });
}

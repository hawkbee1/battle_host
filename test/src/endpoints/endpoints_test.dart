import 'dart:async';
import 'dart:typed_data';

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/endpoints.dart';
import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';

const _s2 = Sender(accountId: 'a-2', sectionId: 's-2');

SignIn _jwt(String token, {String battleId = 'b-1'}) =>
    SignIn(battleId: battleId, kind: CredentialKind.jwt, credential: token);

SignIn _key(String key, {String battleId = 'b-1'}) =>
    SignIn(battleId: battleId, kind: CredentialKind.apiKey, credential: key);

void main() {
  late OrdersFixture f;
  late MemoryAccountCheck accounts;
  late Endpoints endpoints;

  Endpoints endpointsOn(
    SimulationHost host, {
    EndpointSettings settings = const EndpointSettings(),
  }) => Endpoints(host: host, accounts: accounts, settings: settings);

  setUp(() {
    f = OrdersFixture();
    accounts = MemoryAccountCheck(
      jwts: const {'jwt-1': 'a-1', 'jwt-2': 'a-2', 'jwt-9': 'a-9'},
    );
    endpoints = endpointsOn(f.host);
  });

  Future<void> settle(Connection connection) async {
    await connection.settled;
    await pumpEventQueue();
  }

  Future<(Connection, FakeSocket)> connect(
    Object first, {
    Endpoints? on,
  }) async {
    final socket = FakeSocket();
    final connection = (on ?? endpoints).open(socket)..receive(first);
    await settle(connection);
    return (connection, socket);
  }

  Future<List<HostMessage>> say(
    Connection connection,
    FakeSocket socket,
    ClientMessage message, {
    bool json = false,
  }) async {
    final before = socket.frames.length;
    connection.receive(frameOf(message, json: json));
    await settle(connection);
    return socket.messages.sublist(before);
  }

  SendCommand order(int requestId, Order order, {Sender sender = _s2}) =>
      SendCommand(
        requestId: requestId,
        command: Command(sender: sender, sentAt: f.battle.time, order: order),
      );

  /// Leaves [unitId] three rounds in its magazine, so that it may reload.
  void spend(String unitId) => f.changeUnit(
    unitId,
    (unit) => unit.copyWith(
      weapon: WeaponState(
        weapon: unit.weapon.weapon,
        rounds: 3,
        loaded: true,
        busyUntil: Duration.zero,
        nextShotAt: Duration.zero,
      ),
    ),
  );

  group('sign-in on the socket (stack decisions 3 and 6)', () {
    test('HQ-07 decision 220 a player signs in with a JWT: the socket is '
        'bound to its section, which gets its whole view, then the server '
        'logs the player in', () async {
      final (connection, socket) = await connect(frameOf(_jwt('jwt-2')));

      expect(connection.stage, equals(ConnectionStage.signedIn));
      expect(
        socket.messages.first,
        equals(
          SignInAccepted(
            accountId: 'a-2',
            sectionId: 's-2',
            team: 'team-2',
            battleTime: f.battle.time,
          ),
        ),
      );
      expect(socket.messages[1], isA<SectionView>());
      final login = f.entries.last;
      expect(login.command!.order, equals(const EnterBattle()));
      expect(login.command!.sender, equals(_s2));
      expect(login.command!.origin, equals(Origin.server));
      expect(
        login.events,
        contains(isA<ManagerChanged>()),
        reason: 'the first player of team 2 to log in manages its HQ',
      );
      expect(socket.closes, isEmpty);
    });

    test('AI-04 decision 158 an AI agent signs in with its API key', () async {
      final key = await accounts.keys.create(caller: 'a-2');

      final (connection, socket) = await connect(frameOf(_key(key)));

      expect(socket.messages.first, isA<SignInAccepted>());
      expect(connection.seat!.origin, equals(Origin.ai));
      expect(connection.apiKey, equals(key));
    });

    test('refuses a bad JWT, a key revoked, a battle not on this host and '
        'a battle the account has no section in, and closes', () async {
      final key = await accounts.keys.create(caller: 'a-2');
      await accounts.keys.revoke(caller: 'a-2', accountId: 'a-2');

      for (final (signIn, reason) in [
        (_jwt('forged'), SignInRefusal.invalidCredential),
        (_key(key), SignInRefusal.invalidCredential),
        (_key('not a key'), SignInRefusal.invalidCredential),
        (_jwt('jwt-2', battleId: 'b-9'), SignInRefusal.battleNotFound),
        (_jwt('jwt-9'), SignInRefusal.noSection),
      ]) {
        final (connection, socket) = await connect(frameOf(signIn));

        expect(socket.messages, equals([SignInRefused(reason)]));
        expect(socket.closes, equals([CloseCode.normal]));
        expect(connection.stage, equals(ConnectionStage.closed));
      }
      expect(endpoints.connections, isEmpty);
    });

    test('an unknown protocol version gets a goodbye, in the encoding it '
        'came in', () async {
      final (_, binary) = await connect(Uint8List.fromList([2, 0]));
      final (_, text) = await connect('{"v":2}');

      for (final socket in [binary, text]) {
        expect(
          socket.messages,
          equals([const Goodbye(GoodbyeReason.unsupportedVersion)]),
        );
        expect(socket.closes, equals([CloseCode.normal]));
      }
      expect(text.frames.single, isA<String>());
    });

    test('a frame it does not read, a message before the sign-in and a '
        'frame too large close the socket', () async {
      final small = endpointsOn(
        f.host,
        settings: const EndpointSettings(maxMessage: 64),
      );
      final cases = [
        (Uint8List.fromList([1, 99]), CloseCode.protocolError),
        ('not json', CloseCode.protocolError),
        (42, CloseCode.protocolError),
        (frameOf(const Heartbeat()), CloseCode.protocolError),
        (Uint8List(65), CloseCode.tooBig),
        ('x' * 65, CloseCode.tooBig),
      ];
      for (final (frame, code) in cases) {
        final (_, socket) = await connect(frame, on: small);

        expect(socket.closes, equals([code]), reason: '$frame');
        expect(socket.frames, isEmpty);
      }
    });

    test('a second sign-in closes the socket; a closed socket reads '
        'nothing more', () async {
      final (connection, socket) = await connect(frameOf(_jwt('jwt-2')));

      await say(connection, socket, _jwt('jwt-2'));
      expect(socket.closes, equals([CloseCode.protocolError]));

      final before = f.entries.length;
      await say(
        connection,
        socket,
        order(1, const Reload(unitId: 'soldier-2')),
      );
      connection.close(CloseCode.goingAway);
      expect(f.entries, hasLength(before));
      expect(socket.closes, hasLength(1));
    });

    test('a client that signs in with JSON text is answered in JSON', () async {
      final (connection, socket) = await connect(
        frameOf(_jwt('jwt-2'), json: true),
      );

      expect(socket.frames, everyElement(isA<String>()));
      expect(socket.messages.first, isA<SignInAccepted>());
      spend('soldier-2');
      final answers = await say(
        connection,
        socket,
        order(1, const Reload(unitId: 'soldier-2')),
        json: true,
      );
      expect(answers.last, isA<CommandAccepted>());
      expect(socket.frames, everyElement(isA<String>()));
    });
  });

  group('commands', () {
    test('AI-05 decision 162 an order over the socket is logged with the '
        'origin player, and its answer carries its sequence number', () async {
      final (connection, socket) = await connect(frameOf(_jwt('jwt-2')));
      spend('soldier-2');

      final answers = await say(
        connection,
        socket,
        order(7, const Reload(unitId: 'soldier-2')),
      );

      final logged = f.entries.last.command!;
      expect(logged.order, equals(const Reload(unitId: 'soldier-2')));
      expect(logged.origin, equals(Origin.player));
      expect(
        answers.last,
        equals(CommandAccepted(requestId: 7, seq: logged.seq!)),
      );
    });

    test('the sender is the signed-in account and its section, whatever '
        'the client wrote: a command for another section is refused', () async {
      final (connection, socket) = await connect(frameOf(_jwt('jwt-2')));
      spend('soldier-2');
      const other = Sender(accountId: 'a-1', sectionId: 's-1');

      final mine = await say(
        connection,
        socket,
        order(1, const Reload(unitId: 'soldier-2'), sender: other),
      );
      expect(mine.last, isA<CommandAccepted>());
      expect(f.entries.last.command!.sender, equals(_s2));

      final theirs = await say(
        connection,
        socket,
        order(2, const Reload(unitId: 'jeep-1'), sender: other),
      );
      expect(
        theirs.last,
        equals(const CommandRefused(requestId: 2, reason: 'not_your_unit')),
      );
      expect(f.entries.last.command!.sender, equals(_s2));

      final login = await say(
        connection,
        socket,
        order(3, const EnterBattle()),
      );
      expect(
        login.last,
        isA<CommandRefused>(),
        reason: 'only the server tells that a player logs in',
      );
    });

    test('a command resent with a request ID already answered gets the '
        'first answer again and is carried out once, on the socket and '
        'over HTTPS', () async {
      final key = await accounts.keys.create(caller: 'a-2');
      final (connection, socket) = await connect(frameOf(_key(key)));
      spend('soldier-2');
      final sent = order(5, const Reload(unitId: 'soldier-2'));

      final first = await say(connection, socket, sent);
      final logged = f.entries.length;
      final again = await say(connection, socket, sent);
      final call = await endpoints.call(
        'b-1',
        authorization: 'Bearer $key',
        body: const JsonProtocolCodec().encodeClientMessage(sent),
      );

      expect(again, equals([first.last]));
      expect(call.message, equals(first.last));
      expect(f.entries, hasLength(logged));
    });

    test("AI-03 decision 157 a section's machine-gun burst is not "
        'throttled; a flood is', () async {
      f = OrdersFixture(rateLimit: RateLimit());
      endpoints = endpointsOn(f.host);
      final machineGun = planData.combat.weaponTypes['machine_gun']!;
      for (final unit in ['commander-1', 'soldier-1']) {
        f.changeUnit(
          unit,
          (state) => state.copyWith(weapon: WeaponState.ready(machineGun)),
        );
      }
      f.changeUnit(
        'soldier-2',
        (unit) =>
            unit.copyWith(health: const Health(current: 100000, max: 100000)),
      );
      final (one, socketOne) = await connect(frameOf(_jwt('jwt-1')));
      const s1 = Sender(accountId: 'a-1', sectionId: 's-1');
      final answers = <HostMessage>[];
      var id = 0;
      // The whole section acts at once, then its two machine guns empty
      // their AP pools at 500 rounds a minute.
      for (final unit in ordersPlaces.keys.where((u) => !u.endsWith('-2'))) {
        if (unit.endsWith('-3')) continue;
        answers.addAll(
          await say(
            one,
            socketOne,
            order(++id, Reload(unitId: unit), sender: s1),
          ),
        );
      }
      for (var shot = 0; shot < 30; shot++) {
        for (final unit in ['commander-1', 'soldier-1']) {
          answers.addAll(
            await say(
              one,
              socketOne,
              order(
                ++id,
                Fire(unitId: unit, targetId: 'soldier-2'),
                sender: s1,
              ),
            ),
          );
        }
        f.clock.advance(const Duration(milliseconds: 125));
      }
      final refusals = answers.whereType<CommandRefused>().map((a) => a.reason);
      expect(refusals, isNot(contains('rate_limited')));
      expect(answers.whereType<CommandAccepted>().length, greaterThan(60));

      final (two, socketTwo) = await connect(frameOf(_jwt('jwt-2')));
      final flood = <HostMessage>[];
      for (var i = 0; i < 2000; i++) {
        flood.addAll(
          await say(
            two,
            socketTwo,
            order(i, const Reload(unitId: 'soldier-2')),
          ),
        );
        f.clock.advance(const Duration(microseconds: 500));
      }
      final throttled = flood
          .whereType<CommandRefused>()
          .where((answer) => answer.reason == 'rate_limited')
          .length;
      final handled = flood.where(
        (m) => m is CommandAccepted || m is CommandRefused,
      );
      expect(throttled, greaterThan(1400));
      expect(handled.length - throttled, lessThanOrEqualTo(511));
    });

    test('Endpoints.command answers nothing for a battle that no longer '
        'runs here', () {
      const seat = Seat(
        battleId: 'b-9',
        accountId: 'a-2',
        sectionId: 's-2',
        team: 'team-2',
        origin: Origin.player,
      );

      expect(
        endpoints.command(
          seat,
          1,
          order(1, const Reload(unitId: 'soldier-2')).command,
        ),
        isNull,
      );
    });
  });

  group('a socket over time', () {
    test('AI-02 a socket that closes changes nothing in the battle: the '
        "section's units stay passive", () async {
      final (connection, socket) = await connect(frameOf(_jwt('jwt-2')));
      final units = {
        for (final id in ['commander-2', 'soldier-2', 'soldier-3'])
          id: f.unit(id),
      };
      final logged = f.entries.length;

      connection.closedByClient();
      final frames = socket.frames.length;
      f
        ..send(const Fire(unitId: 'commander-1', targetId: 'soldier-3'))
        ..wait(const Duration(hours: 2));

      expect(endpoints.connections, isEmpty);
      expect(socket.frames, hasLength(frames));
      expect(
        f.entries.skip(logged).where((e) => e.command?.sender == _s2),
        isEmpty,
      );
      for (final MapEntry(key: id, value: before) in units.entries) {
        expect(f.unit(id).cell, equals(before.cell));
        expect(f.unit(id).location, equals(before.location));
      }
      connection.closedByClient();
      expect(socket.closes, isEmpty);
    });

    test('heartbeats keep a socket open; one silent for a minute gets a '
        'goodbye, signed in or not', () async {
      final (connection, socket) = await connect(frameOf(_jwt('jwt-2')));
      final lurker = FakeSocket();
      endpoints.open(lurker);

      f.clock.advance(const Duration(seconds: 59));
      await say(connection, socket, const Heartbeat());
      f.clock.advance(const Duration(seconds: 1));
      await endpoints.tick();
      await pumpEventQueue();
      expect(lurker.messages, equals([const Goodbye(GoodbyeReason.idle)]));
      expect(lurker.closes, equals([CloseCode.normal]));
      expect(connection.stage, equals(ConnectionStage.signedIn));

      f.clock.advance(const Duration(seconds: 58));
      await endpoints.tick();
      expect(connection.stage, equals(ConnectionStage.signedIn));
      f.clock.advance(const Duration(seconds: 1));
      await endpoints.tick();
      await pumpEventQueue();
      expect(socket.messages.last, equals(const Goodbye(GoodbyeReason.idle)));
      expect(socket.closes, equals([CloseCode.normal]));
    });

    test('a resync request gets the whole view again', () async {
      final (connection, socket) = await connect(frameOf(_jwt('jwt-2')));

      final again = await say(connection, socket, const ResyncRequest());

      expect(again, equals([socket.messages[1]]));
    });

    test('a slow client is dropped past its queue bound, and catches up '
        'with its whole view when it comes back', () async {
      endpoints = endpointsOn(
        f.host,
        settings: const EndpointSettings(queueBound: 200),
      );
      final (connection, socket) = await connect(frameOf(_jwt('jwt-2')));
      final held = socket.held = Completer<void>();
      final before = socket.frames.length;

      for (var i = 0; i < 3; i++) {
        await say(connection, socket, const ResyncRequest());
      }
      expect(connection.stage, equals(ConnectionStage.closed));
      held.complete();
      await pumpEventQueue();

      final sent = socket.messages.sublist(before);
      expect(sent.first, isA<SectionView>());
      expect(sent.last, equals(const Goodbye(GoodbyeReason.slowClient)));
      expect(sent, hasLength(2));
      expect(socket.closes, equals([CloseCode.normal]));

      final (_, back) = await connect(frameOf(_jwt('jwt-2')));
      expect(back.messages[1], isA<SectionView>());
    });

    test('a lone message is never too large for the queue', () async {
      endpoints = endpointsOn(
        f.host,
        settings: const EndpointSettings(queueBound: 200),
      );

      final (connection, socket) = await connect(frameOf(_jwt('jwt-2')));

      expect(connection.stage, equals(ConnectionStage.signedIn));
      expect(socket.messages[1], isA<SectionView>());
      expect((socket.frames[1] as Uint8List).length, greaterThan(200));
    });

    test('a socket whose writes fail is forgotten', () async {
      final socket = BrokenSocket();
      final connection = endpoints.open(socket)
        ..receive(frameOf(_jwt('jwt-2')));
      await settle(connection);

      expect(connection.stage, equals(ConnectionStage.closed));
      expect(endpoints.connections, isEmpty);
    });

    test('decision 161 a socket signed in with a key that is revoked gets '
        'a goodbye at the next key check', () async {
      endpoints = endpointsOn(
        f.host,
        settings: const EndpointSettings(keyCheck: Duration(seconds: 30)),
      );
      final key = await accounts.keys.create(caller: 'a-2');
      final (_, agent) = await connect(frameOf(_key(key)));
      final (player, _) = await connect(frameOf(_jwt('jwt-1')));

      f.clock.advance(const Duration(seconds: 20));
      await endpoints.tick();
      await accounts.keys.revoke(caller: 'a-2', accountId: 'a-2');
      f.clock.advance(const Duration(seconds: 9));
      await endpoints.tick();
      await pumpEventQueue();
      expect(agent.closes, isEmpty);

      f.clock.advance(const Duration(seconds: 1));
      await endpoints.tick();
      await pumpEventQueue();
      expect(agent.messages.last, const Goodbye(GoodbyeReason.keyRevoked));
      expect(agent.closes, equals([CloseCode.normal]));
      expect(player.stage, equals(ConnectionStage.signedIn));
    });

    test('a battle that ended says goodbye after its last update', () async {
      final (_, socket) = await connect(frameOf(_jwt('jwt-2')));
      f.battle.change(
        (state) => state.withVictory(
          VictoryState(
            relicOwners: state.victory!.relicOwners,
            teams: state.victory!.teams,
            winner: const BattleWon(team: 'team-1', kind: VictoryKind.lastHq),
          ),
        ),
      );

      await endpoints.tick();
      await pumpEventQueue();

      expect(socket.messages.last, const Goodbye(GoodbyeReason.battleEnded));
      expect(socket.closes, equals([CloseCode.normal]));
    });

    test('closeAll closes every socket: the host stops', () async {
      final (_, one) = await connect(frameOf(_jwt('jwt-1')));
      final (_, two) = await connect(frameOf(_jwt('jwt-2')));

      endpoints.closeAll();

      expect(one.closes, equals([CloseCode.goingAway]));
      expect(two.closes, equals([CloseCode.goingAway]));
      expect(endpoints.connections, isEmpty);
    });
  });

  group('a battle that fails', () {
    late BreakableWal wal;
    late RecordingErrorReporter reporter;
    late SimulationHost host;

    setUp(() {
      wal = BreakableWal();
      reporter = RecordingErrorReporter();
      host = SimulationHost(
        clock: ManualClock(DateTime.utc(2026, 11, 8)),
        maps: MapLibrary(
          source: MemoryMapSource({'valley': valley}),
          terrain: planData.terrain,
        ),
        definitions: planData,
        reporter: reporter,
        wal: wal,
      );
      deploy(host.start(ordersSetup()));
      endpoints = endpointsOn(host);
    });

    test('a command whose entry is not written is not acknowledged; the '
        "battle's other sockets close at once or at the next tick", () async {
      final (one, first) = await connect(frameOf(_jwt('jwt-1')));
      final (two, second) = await connect(frameOf(_jwt('jwt-2')));
      final (_, third) = await connect(frameOf(_jwt('jwt-2')));
      final answered = first.frames.length;

      wal.broken = true;
      await say(
        one,
        first,
        order(
          1,
          const Reload(unitId: 'jeep-1'),
          sender: const Sender(accountId: 'a-1', sectionId: 's-1'),
        ),
      );
      expect(first.frames, hasLength(answered));
      expect(first.closes, equals([CloseCode.internalError]));
      expect(reporter.reports, isNotEmpty);

      await say(two, second, order(1, const Reload(unitId: 'soldier-2')));
      expect(second.closes, equals([CloseCode.goingAway]));

      await endpoints.tick();
      expect(third.closes, equals([CloseCode.goingAway]));

      final (_, late) = await connect(frameOf(_jwt('jwt-2')));
      expect(
        late.messages,
        equals([const SignInRefused(SignInRefusal.battleNotFound)]),
      );
    });

    test('a battle gone while a client signs in refuses the sign-in', () async {
      final slow = _SlowAccounts();
      endpoints = Endpoints(host: host, accounts: slow);
      final socket = FakeSocket();
      final connection = endpoints.open(socket)
        ..receive(frameOf(_jwt('jwt-2')));
      await pumpEventQueue();

      wal.broken = true;
      expect(
        () => host.submit(
          'b-1',
          const Command(
            sender: Sender(accountId: 'a-1', sectionId: 's-1'),
            sentAt: Duration.zero,
            order: Reload(unitId: 'jeep-1'),
          ),
          origin: Origin.player,
        ),
        throwsStateError,
      );
      slow.answer.complete('a-2');
      await settle(connection);

      expect(
        socket.messages,
        equals([const SignInRefused(SignInRefusal.battleNotFound)]),
      );
    });

    test('a socket closed while it signs in is not signed in', () async {
      final slow = _SlowAccounts();
      endpoints = Endpoints(host: host, accounts: slow);
      final socket = FakeSocket();
      final connection = endpoints.open(socket)
        ..receive(frameOf(_jwt('jwt-2')));
      await pumpEventQueue();

      connection.closedByClient();
      slow.answer.complete('a-2');
      await settle(connection);

      expect(connection.seat, isNull);
      expect(socket.frames, isEmpty);
    });
  });

  group('HTTPS (decisions 158, 161, 162)', () {
    late String key;

    setUp(() async => key = await accounts.keys.create(caller: 'a-2'));

    Future<CallAnswer> call(
      ClientMessage message, {
      String? authorization,
      String battleId = 'b-1',
    }) => endpoints.call(
      battleId,
      authorization: authorization ?? 'Bearer $key',
      body: const JsonProtocolCodec().encodeClientMessage(message),
    );

    test('AI-04 AI-05 decision 162 a command with an API key as a bearer '
        'token is logged with the origin ai', () async {
      spend('soldier-2');

      final answer = await call(order(1, const Reload(unitId: 'soldier-2')));

      final logged = f.entries.last.command!;
      expect(answer.status, equals(200));
      expect(answer.message, CommandAccepted(requestId: 1, seq: logged.seq!));
      expect(logged.origin, equals(Origin.ai));
      expect(logged.sender, equals(_s2));
    });

    test('decision 161 a key revoked between two calls is refused on the '
        'next one', () async {
      final first = await call(order(1, const Reload(unitId: 'soldier-2')));
      await accounts.keys.revoke(caller: 'a-2', accountId: 'a-2');
      final second = await call(order(2, const Reload(unitId: 'soldier-2')));

      expect(first.status, equals(200));
      expect(second.status, equals(401));
      expect(
        second.message,
        const SignInRefused(SignInRefusal.invalidCredential),
      );
    });

    test(
      'refuses a call without a key, with a JWT, to a battle not here, '
      'for an account with no section, and a body it does not read',
      () async {
        final stranger = await accounts.keys.create(caller: 'a-9');
        final command = order(1, const Reload(unitId: 'soldier-2'));
        final json = const JsonProtocolCodec().encodeClientMessage(command);

        for (final (answer, status) in [
          (await call(command, authorization: ''), 401),
          (await call(command, authorization: 'Bearer jwt-2'), 401),
          (await call(command, battleId: 'b-9'), 404),
          (await call(command, authorization: 'Bearer $stranger'), 403),
          (await call(const Heartbeat()), 400),
          (
            await endpoints.call(
              'b-1',
              authorization: 'Bearer $key',
              body: '[',
            ),
            400,
          ),
          (
            await endpoints.call(
              'b-1',
              authorization: 'Bearer $key',
              body: json.replaceFirst('"v":1', '"v":2'),
            ),
            400,
          ),
        ]) {
          expect(answer.status, equals(status), reason: '${answer.message}');
        }
        expect(
          (await endpoints.call(
            'b-1',
            authorization: 'Bearer $key',
            body: json.replaceFirst('"v":1', '"v":2'),
          )).message,
          const Goodbye(GoodbyeReason.unsupportedVersion),
        );
        expect(
          (await endpoints.call(
            'b-1',
            authorization: 'Bearer $key',
            body: '[',
          )).error,
          isNotNull,
        );
      },
    );

    test('AI-03 a call over the rate limit is 429', () async {
      f = OrdersFixture(rateLimit: RateLimit(perSecond: 1, burst: 1));
      endpoints = endpointsOn(f.host);

      await call(order(1, const Reload(unitId: 'soldier-2')));
      final second = await call(order(2, const Reload(unitId: 'soldier-2')));

      expect(second.status, equals(429));
      expect(
        second.message,
        const CommandRefused(requestId: 2, reason: 'rate_limited'),
      );
    });
  });
}

/// An [AccountCheck] that answers when the test says so.
final class _SlowAccounts implements AccountCheck {
  final answer = Completer<String?>();

  @override
  Future<String?> jwt(String token) => answer.future;

  @override
  Future<String?> apiKey(String key) => answer.future;
}

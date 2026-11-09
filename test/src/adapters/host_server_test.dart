import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

import '../../helpers/endpoints.dart';
import '../../helpers/fixtures.dart';
import '../../helpers/orders.dart';

const _json = JsonProtocolCodec();

/// An [AccountCheck] that fails as an unreachable Appwrite would.
final class _DownAccounts implements AccountCheck {
  @override
  Future<String?> jwt(String token) async => throw const SocketException('');

  @override
  Future<String?> apiKey(String key) async => throw const SocketException('');
}

/// The endpoints on the loopback interface (M6 conventions).
void main() {
  late OrdersFixture f;
  late MemoryAccountCheck accounts;
  late HostServer server;
  late HttpClient http;

  Future<HostServer> serve({
    AccountCheck? on,
    EndpointSettings settings = const EndpointSettings(),
  }) => HostServer.bind(
    Endpoints(host: f.host, accounts: on ?? accounts, settings: settings),
    address: InternetAddress.loopbackIPv4,
    port: 0,
    closeGrace: const Duration(milliseconds: 100),
  );

  setUp(() async {
    f = OrdersFixture();
    accounts = MemoryAccountCheck(jwts: const {'jwt-2': 'a-2'});
    server = await serve();
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.close();
  });

  Uri at(String path, {String scheme = 'http'}) =>
      Uri.parse('$scheme://127.0.0.1:${server.port}$path');

  Future<(int, String)> post(
    String path,
    List<int> body, {
    String? authorization,
    bool chunked = false,
  }) async {
    final request = await http.postUrl(at(path));
    if (authorization != null) {
      request.headers.set(HttpHeaders.authorizationHeader, authorization);
    }
    if (chunked) {
      request.headers.chunkedTransferEncoding = true;
    } else {
      request.contentLength = body.length;
    }
    request.add(body);
    final response = await request.close();
    return (response.statusCode, await utf8.decodeStream(response));
  }

  Future<int> get(String path) async {
    final response = await (await http.getUrl(at(path))).close();
    await response.drain<void>();
    return response.statusCode;
  }

  group('the WebSocket', () {
    test('HQ-07 AI-05 a player signs in with a JWT, gets its view and sends '
        'an order logged with the origin player', () async {
      final socket = await WebSocket.connect(
        at('/v1/socket', scheme: 'ws').toString(),
      );
      final messages = StreamIterator(
        socket.map((frame) => hostMessageOf(frame as Object)),
      );
      socket.add(
        frameOf(
          const SignIn(
            battleId: 'b-1',
            kind: CredentialKind.jwt,
            credential: 'jwt-2',
          ),
        ),
      );

      expect(await messages.moveNext(), isTrue);
      expect(messages.current, isA<SignInAccepted>());
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, isA<SectionView>());

      socket.add(
        frameOf(
          SendCommand(
            requestId: 1,
            command: Command(
              sender: const Sender(accountId: 'a-2', sectionId: 's-2'),
              sentAt: f.battle.time,
              order: const Reload(unitId: 'soldier-2'),
            ),
          ),
        ),
      );
      while (await messages.moveNext()) {
        if (messages.current is CommandAccepted ||
            messages.current is CommandRefused) {
          break;
        }
      }
      expect(f.entries.last.command!.origin, equals(Origin.player));

      await socket.close();
      await messages.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.endpoints.connections, isEmpty);
    });

    test('JSON in text frames is answered in JSON', () async {
      final socket = await WebSocket.connect(
        at('/v1/socket', scheme: 'ws').toString(),
      );
      socket.add('{"v":2}');

      final frame = await socket.first;

      expect(frame, isA<String>());
      expect(
        hostMessageOf(frame as Object),
        const Goodbye(GoodbyeReason.unsupportedVersion),
      );
    });

    test('a client that stops reading is cut', () async {
      await server.close();
      server = await serve(settings: const EndpointSettings(queueBound: 4096));
      final socket = await WebSocket.connect(
        at('/v1/socket', scheme: 'ws').toString(),
      );
      final reading = socket.listen((_) {})..pause();
      socket.add(
        frameOf(
          const SignIn(
            battleId: 'b-1',
            kind: CredentialKind.jwt,
            credential: 'jwt-2',
          ),
        ),
      );
      final resync = frameOf(const ResyncRequest());
      for (
        var i = 0;
        i < 20000 && server.endpoints.connections.isNotEmpty;
        i++
      ) {
        socket.add(resync);
        if (i % 200 == 0) await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(server.endpoints.connections, isEmpty);
      await reading.cancel();
    });

    test('a client that breaks the WebSocket protocol is forgotten', () async {
      final raw = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final answer = StreamIterator(raw);
      raw.write(
        'GET /v1/socket HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\n\r\n',
      );
      expect(await answer.moveNext(), isTrue);
      expect(utf8.decode(answer.current), startsWith('HTTP/1.1 101'));
      expect(server.endpoints.connections, hasLength(1));

      // A frame with reserved bits set and no mask.
      raw.add([0xF2, 0x01, 0x00]);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(server.endpoints.connections, isEmpty);
      await answer.cancel();
      raw.destroy();
    });

    test('a request that is not an upgrade is refused', () async {
      expect(await get('/v1/socket'), equals(426));
    });
  });

  group('HTTPS', () {
    test('AI-04 AI-05 decision 162 a command with an API key is logged '
        'with the origin ai', () async {
      final key = await accounts.keys.create(caller: 'a-2');
      final body = _json.encodeClientMessage(
        SendCommand(
          requestId: 3,
          command: Command(
            sender: const Sender(accountId: 'a-2', sectionId: 's-2'),
            sentAt: f.battle.time,
            order: const Reload(unitId: 'soldier-2'),
          ),
        ),
      );

      final (status, answer) = await post(
        '/v1/battles/b-1/commands',
        utf8.encode(body),
        authorization: 'Bearer $key',
      );

      expect(status, equals(200));
      expect(_json.decodeHostMessage(answer), isA<HostMessage>());
      expect(f.entries.last.command!.origin, equals(Origin.ai));

      final (refused, why) = await post(
        '/v1/battles/b-1/commands',
        utf8.encode(body),
      );
      expect(refused, equals(401));
      expect(
        _json.decodeHostMessage(why),
        const SignInRefused(SignInRefusal.invalidCredential),
      );
    });

    test('answers 400 with an error for a body it does not read', () async {
      final key = await accounts.keys.create(caller: 'a-2');

      final (status, body) = await post(
        '/v1/battles/b-1/commands',
        utf8.encode('['),
        authorization: 'Bearer $key',
      );

      expect(status, equals(400));
      expect(jsonDecode(body), contains('error'));
    });

    test(
      'refuses an unknown path, another method and a body too large',
      () async {
        final large = Uint8List(256 * 1024 + 1);

        expect(await get('/v1/nothing'), equals(404));
        expect(await get('/v1/battles/b-1/commands'), equals(405));
        expect((await post('/v1/battles/b-1/commands', large)).$1, 413);
        expect(
          (await post('/v1/battles/b-1/commands', large, chunked: true)).$1,
          413,
        );
      },
    );

    test('answers 500 when the host fails, and reports it', () async {
      await server.close();
      server = await serve(on: _DownAccounts());
      final body = _json.encodeClientMessage(
        const SendCommand(
          requestId: 1,
          command: Command(
            sender: Sender(accountId: 'a-2', sectionId: 's-2'),
            sentAt: Duration.zero,
            order: Reload(unitId: 'soldier-2'),
          ),
        ),
      );

      final (status, _) = await post(
        '/v1/battles/b-1/commands',
        utf8.encode(body),
        authorization: 'Bearer btk_${'A' * 43}',
      );

      expect(status, equals(500));
      expect(
        (f.host.reporter as RecordingErrorReporter).reports.single.$1,
        isA<SocketException>(),
      );
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:battle_host/src/endpoints/connection.dart';
import 'package:battle_host/src/endpoints/endpoints.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:crypto/crypto.dart';

/// {@template host_server}
/// The endpoints of a host process on `dart:io` (Adapter, stack decision
/// 3): one HTTP server, behind the reverse proxy that ends TLS live.
/// - `GET /v1/socket`: the WebSocket of players and AI agents.
/// - `POST /v1/battles/<battle>/commands`: one command in JSON, with the
///   API key as a bearer token.
///
/// It only moves bytes: [endpoints] does the rest.
/// {@endtemplate}
final class HostServer {
  new _(this.endpoints, this._server, this._closeGrace);

  /// Serves [endpoints] on [address] and [port] (0 picks a free port).
  /// A socket closed with a write held up by its client is cut after
  /// [closeGrace].
  static Future<HostServer> bind(
    Endpoints endpoints, {
    required Object address,
    required int port,
    Duration closeGrace = const Duration(seconds: 5),
  }) async {
    final server = HostServer._(
      endpoints,
      await HttpServer.bind(address, port),
      closeGrace,
    );
    server._server.listen((request) => unawaited(server._handle(request)));
    return server;
  }

  /// The endpoints served.
  final Endpoints endpoints;

  final HttpServer _server;
  final Duration _closeGrace;

  /// The port it listens on.
  int get port => _server.port;

  static final _commands = RegExp(r'^/v1/battles/([A-Za-z0-9_-]+)/commands$');

  /// The GUID of the WebSocket handshake (RFC 6455, 1.3).
  static const _guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  /// Stops listening and closes every socket.
  Future<void> close() async {
    endpoints.closeAll();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/v1/socket') return await _upgrade(request);
      final battleId = _commands.firstMatch(path)?.group(1);
      if (battleId == null) return await _status(request, 404);
      if (request.method != 'POST') return await _status(request, 405);
      final body = await _body(request);
      if (body == null) return await _status(request, 413);
      final answer = await endpoints.call(
        battleId,
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
        body: body,
      );
      request.response
        ..statusCode = answer.status
        ..headers.contentType = ContentType.json
        ..write(switch (answer) {
          CallAnswer(:final message?) =>
            const JsonProtocolCodec().encodeHostMessage(message),
          CallAnswer(:final error) => jsonEncode({'error': error}),
        });
      await request.response.close();
    } on Object catch (error, stackTrace) {
      await endpoints.host.reporter.report(error, stackTrace);
      await _status(request, 500);
    }
  }

  /// The body as UTF-8 text; null when it is larger than a client message
  /// may be.
  Future<String?> _body(HttpRequest request) async {
    final limit = endpoints.settings.maxMessage;
    if (request.contentLength > limit) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > limit) return null;
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  static Future<void> _status(HttpRequest request, int status) async {
    try {
      request.response.statusCode = status;
      await request.response.close();
    } on Object {
      // The response had started, or its client is gone.
    }
  }

  /// The WebSocket handshake by hand, so that the host holds the raw
  /// socket and can cut a client that stopped reading.
  Future<void> _upgrade(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      return await _status(request, 426);
    }
    final key = request.headers.value('Sec-WebSocket-Key')!;
    request.response
      ..statusCode = HttpStatus.switchingProtocols
      ..headers.set(HttpHeaders.connectionHeader, 'Upgrade')
      ..headers.set(HttpHeaders.upgradeHeader, 'websocket')
      ..headers.set(
        'Sec-WebSocket-Accept',
        base64.encode(sha1.convert(utf8.encode('$key$_guid')).bytes),
      );
    final raw = await request.response.detachSocket();
    final webSocket = WebSocket.fromUpgradedSocket(raw, serverSide: true);
    final connection = endpoints.open(
      _WebSocketClient(webSocket, raw, _closeGrace),
    );
    webSocket.listen(
      (frame) => connection.receive(
        frame is String ? frame : Uint8List.fromList(frame as List<int>),
      ),
      onDone: connection.closedByClient,
      // dart:io ends the stream on a protocol error; a socket error ends the
      // connection the same way.
      onError: connection.closedByClient,
      cancelOnError: true,
    );
  }
}

/// A [ClientSocket] on a `dart:io` WebSocket and its raw socket.
final class _WebSocketClient implements ClientSocket {
  new(this._webSocket, this._raw, this._grace);

  final WebSocket _webSocket;
  final Socket _raw;
  final Duration _grace;

  /// Completes once the socket took [frame]: a client that does not read
  /// fills the system's buffers, then holds the write back.
  @override
  Future<void> write(Object frame) => _webSocket.addStream(Stream.value(frame));

  /// Closes with [code]; a client that still holds a write back is cut
  /// after the grace period.
  @override
  void close(int code) {
    try {
      unawaited(_webSocket.close(code).catchError((Object _) => null));
    } on Object {
      // A write is held up (the sink is bound): the socket is cut below.
    }
    Timer(_grace, _raw.destroy);
  }
}

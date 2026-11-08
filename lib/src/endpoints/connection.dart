import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:battle_host/src/endpoints/endpoints.dart';
import 'package:battle_host/src/stream/update_stream.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// A client's socket (a port, stack decision 7): the WebSocket adapter
/// implements it, and tests use fakes. A frame is a [Uint8List] (binary)
/// or a [String] (text).
abstract interface class ClientSocket {
  /// Writes [frame]; completes once the socket took it, so a client that
  /// reads slowly holds the next write back.
  Future<void> write(Object frame);

  /// Closes the socket with the WebSocket close [code].
  void close(int code);
}

/// The WebSocket close codes the host uses (RFC 6455, 7.4.1).
abstract final class CloseCode {
  /// After a goodbye or a refused sign-in.
  static const normal = 1000;

  /// The battle no longer runs here, or the host stops.
  static const goingAway = 1001;

  /// A frame the protocol does not read, or a message out of turn.
  static const protocolError = 1002;

  /// A frame larger than the host reads.
  static const tooBig = 1009;

  /// The host failed: the client may come back.
  static const internalError = 1011;
}

/// Where a connection stands.
enum ConnectionStage {
  /// Waiting for its sign-in.
  signingIn,

  /// Signed in: bound to an account and its section in a battle.
  signedIn,

  /// Closing after a last message, or closed.
  closed,
}

/// {@template connection}
/// One client's socket at the host (M6 Issue 5): a player's app or an AI
/// agent. Its first message signs in; the socket is then bound to the
/// account and its section ([seat]), receives the section's whole view
/// and updates (it is the section's [SectionSubscriber]), and sends
/// commands, resync requests and heartbeats. It answers in the encoding
/// its sign-in came in: binary frames, or JSON in text frames.
///
/// Its messages wait in a queue while the socket writes the one before. A
/// client that reads so slowly that more than the queue bound of
/// [EndpointSettings] waits behind the oldest waiting message is dropped:
/// it gets a goodbye ([GoodbyeReason.slowClient]) and catches up with its
/// whole view when it comes back. The oldest message does not count, so a
/// whole view always goes out, however large.
///
/// A connection that closes, for whatever reason, changes nothing in the
/// battle: the section's units stay passive (AI-02).
/// {@endtemplate}
final class Connection implements SectionSubscriber {
  /// {@macro connection}
  new(this._endpoints, this.socket) : heardAt = _endpoints.clock.now();

  final Endpoints _endpoints;

  /// The socket.
  final ClientSocket socket;

  /// Where it stands.
  ConnectionStage stage = ConnectionStage.signingIn;

  /// When it last heard from its client: an idle one is closed.
  DateTime heardAt;

  /// Its account and section in the battle, once signed in.
  Seat? seat;

  /// The API key it signed in with, checked again from time to time
  /// (decision 161); null for a JWT.
  String? get apiKey => _apiKey;
  String? _apiKey;

  var _json = false;
  var _inbox = Future<void>.value();
  final _queue = Queue<Object>();
  var _queued = 0;
  var _writing = false;
  int? _closeWith;

  static const _binary = BinaryProtocolCodec();
  static const _text = JsonProtocolCodec();

  /// Completes once every frame received so far is handled.
  Future<void> get settled => _inbox;

  /// Handles [frame], received from the client, after the ones before it.
  void receive(Object frame) => _inbox = _inbox.then((_) => _handle(frame));

  /// The client closed the socket, or it broke with [error]: the section
  /// is no longer sent anything.
  void closedByClient([Object? error]) {
    if (stage == ConnectionStage.closed && _closeWith == null) return;
    _closeWith = null;
    _end();
  }

  Future<void> _handle(Object frame) async {
    if (stage == ConnectionStage.closed) return;
    heardAt = _endpoints.clock.now();
    final settings = _endpoints.settings;
    final size = switch (frame) {
      final String text => text.length,
      final Uint8List bytes => bytes.length,
      _ => 0,
    };
    if (size > settings.maxMessage) return close(CloseCode.tooBig);
    final ClientMessage message;
    try {
      message = switch (frame) {
        final String text => _text.decodeClientMessage(text),
        final Uint8List bytes => _binary.decodeClientMessage(bytes),
        _ => throw const ProtocolException('not a frame'),
      };
    } on UnsupportedVersionException {
      _json = frame is String;
      return goodbye(GoodbyeReason.unsupportedVersion);
    } on ProtocolException {
      return close(CloseCode.protocolError);
    }
    try {
      switch ((stage, message)) {
        case (ConnectionStage.signingIn, final SignIn signIn):
          _json = frame is String;
          await _signIn(signIn);
        case (
          ConnectionStage.signedIn,
          SendCommand(:final requestId, :final command),
        ):
          final answer = _endpoints.command(seat!, requestId, command);
          answer == null ? close(CloseCode.goingAway) : send(answer);
        case (ConnectionStage.signedIn, ResyncRequest()):
          _endpoints.resync(this);
        case (ConnectionStage.signedIn, Heartbeat()):
          break;
        default:
          close(CloseCode.protocolError);
      }
    } on Object catch (error, stackTrace) {
      // The host reported a battle that failed; anything else is reported
      // here. The client may come back.
      await _endpoints.host.reporter.report(error, stackTrace);
      close(CloseCode.internalError);
    }
  }

  Future<void> _signIn(SignIn signIn) async {
    final (seat, refusal) = await _endpoints.seat(
      signIn.battleId,
      signIn.kind,
      signIn.credential,
    );
    if (stage == ConnectionStage.closed) return;
    if (seat == null) return _last(SignInRefused(refusal!));
    this.seat = seat;
    if (signIn.kind == CredentialKind.apiKey) _apiKey = signIn.credential;
    stage = ConnectionStage.signedIn;
    _endpoints.enter(this);
  }

  /// Sends [message] to the client, after the messages waiting.
  @override
  void send(HostMessage message) {
    if (stage == ConnectionStage.closed) return;
    final frame = _json
        ? _text.encodeHostMessage(message)
        : _binary.encodeHostMessage(message);
    _queue.add(frame);
    _queued += _sizeOf(frame);
    final behind = _queued - _sizeOf(_queue.first);
    if (behind > _endpoints.settings.queueBound) {
      _queue.clear();
      _queued = 0;
      return goodbye(GoodbyeReason.slowClient);
    }
    unawaited(_pump());
  }

  /// Says goodbye for [reason], after the messages waiting, and closes.
  void goodbye(GoodbyeReason reason) => _last(Goodbye(reason));

  /// Closes the socket now with [code], dropping what waits.
  void close(int code) {
    if (stage == ConnectionStage.closed && _closeWith == null) return;
    _queue.clear();
    _queued = 0;
    _closeWith = null;
    _end();
    socket.close(code);
  }

  void _last(HostMessage message) {
    if (stage == ConnectionStage.closed) return;
    send(message);
    _closeWith = CloseCode.normal;
    _end();
    unawaited(_pump());
  }

  void _end() {
    stage = ConnectionStage.closed;
    _endpoints.forget(this);
  }

  Future<void> _pump() async {
    if (_writing) return;
    _writing = true;
    try {
      while (_queue.isNotEmpty) {
        final frame = _queue.removeFirst();
        _queued -= _sizeOf(frame);
        await socket.write(frame);
      }
    } on Object {
      // The socket broke: its client is gone.
      _queue.clear();
      _queued = 0;
      _end();
    } finally {
      _writing = false;
    }
    if (_closeWith case final code?) {
      _closeWith = null;
      socket.close(code);
    }
  }

  static int _sizeOf(Object frame) =>
      frame is String ? frame.length : (frame as Uint8List).length;
}

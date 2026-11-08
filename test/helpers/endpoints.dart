import 'dart:async';
import 'dart:typed_data';

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

const _binary = BinaryProtocolCodec();
const _json = JsonProtocolCodec();

/// [message] as a client frame: binary, or JSON text when [json].
Object frameOf(ClientMessage message, {bool json = false}) => json
    ? _json.encodeClientMessage(message)
    : _binary.encodeClientMessage(message);

/// The host message of the frame [frame].
HostMessage hostMessageOf(Object frame) => frame is String
    ? _json.decodeHostMessage(frame)
    : _binary.decodeHostMessage(frame as Uint8List);

/// A socket in memory: what the host wrote and how it closed. While
/// [held], writes wait, as on a client that stopped reading.
final class FakeSocket implements ClientSocket {
  /// The frames written.
  final frames = <Object>[];

  /// The close codes, in order.
  final closes = <int>[];

  /// Holds the writes back until it completes.
  Completer<void>? held;

  /// The messages written.
  List<HostMessage> get messages => frames.map(hostMessageOf).toList();

  @override
  Future<void> write(Object frame) async {
    if (held case final hold?) await hold.future;
    frames.add(frame);
  }

  @override
  void close(int code) => closes.add(code);
}

/// A socket whose writes fail: its client is gone.
final class BrokenSocket implements ClientSocket {
  /// The close codes, in order.
  final closes = <int>[];

  @override
  Future<void> write(Object frame) async => throw const SocketLikeException();

  @override
  void close(int code) => closes.add(code);
}

/// What a broken socket throws.
final class SocketLikeException implements Exception {
  /// A broken pipe.
  const new();
}

/// A write-ahead log in memory that fails once [broken].
final class BreakableWal implements WriteAheadLog {
  final _inner = MemoryWriteAheadLog();

  /// Whether appends fail.
  bool broken = false;

  @override
  void append(String battleId, int position, LogEntry entry) {
    if (broken) throw StateError('disk full');
    _inner.append(battleId, position, entry);
  }

  @override
  HeldEntries read(String battleId) => _inner.read(battleId);
}

/// What an [AccountCheck] under test knows: a valid JWT and an API key
/// for an account, and how to expire or revoke them.
abstract interface class AccountFixture {
  /// The check.
  AccountCheck get check;

  /// A valid JWT of [accountId].
  Future<String> jwtOf(String accountId);

  /// A new API key of [accountId].
  Future<String> keyOf(String accountId);

  /// Revokes the key of [accountId].
  Future<void> revoke(String accountId);
}

/// The contract of an [AccountCheck] (Liskov, stack decision 7), on the
/// fixtures [make] gives, with [accounts] that exist.
void accountCheckContract(
  Future<AccountFixture> Function() make, {
  required List<String> accounts,
}) {
  late AccountFixture f;

  setUp(() async => f = await make());

  test('stack decision 3 a JWT gives its account', () async {
    final token = await f.jwtOf(accounts.first);

    expect(await f.check.jwt(token), equals(accounts.first));
  });

  test('stack decision 3 a JWT that is not valid gives no account', () async {
    expect(await f.check.jwt('not.a.jwt'), isNull);
    expect(await f.check.jwt(''), isNull);
  });

  test('AI-04 decision 158 an API key gives its account by its hash', () async {
    final first = await f.keyOf(accounts.first);
    final second = await f.keyOf(accounts.last);

    expect(await f.check.apiKey(first), equals(accounts.first));
    expect(await f.check.apiKey(second), equals(accounts.last));
  });

  test('AI-04 a key that is not one, or unknown, gives no account', () async {
    expect(await f.check.apiKey('not a key'), isNull);
    expect(
      await f.check.apiKey('btk_${'A' * 43}'),
      isNull,
      reason: 'a key of the right form that nobody holds',
    );
  });

  test(
    'decision 161 a revoked key gives no account from its next check',
    () async {
      final key = await f.keyOf(accounts.first);
      expect(await f.check.apiKey(key), equals(accounts.first));

      await f.revoke(accounts.first);

      expect(await f.check.apiKey(key), isNull);
    },
  );

  test("decision 158 a new key replaces the account's previous one", () async {
    final old = await f.keyOf(accounts.first);
    final current = await f.keyOf(accounts.first);

    expect(await f.check.apiKey(old), isNull);
    expect(await f.check.apiKey(current), equals(accounts.first));
  });
}

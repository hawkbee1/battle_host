import 'package:battle_backend/battle_backend.dart';
import 'package:battle_host/battle_host.dart';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:dart_appwrite/models.dart' as models;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/endpoints.dart';

class _MockAccount extends Mock implements Account;

class _MockUser extends Mock implements models.User;

final class _MemoryFixture implements AccountFixture {
  @override
  final MemoryAccountCheck check = MemoryAccountCheck();

  @override
  Future<String> jwtOf(String accountId) async {
    final token = 'jwt-$accountId';
    check.jwts[token] = accountId;
    return token;
  }

  @override
  Future<String> keyOf(String accountId) =>
      check.keys.create(caller: accountId);

  @override
  Future<void> revoke(String accountId) =>
      check.keys.revoke(caller: accountId, accountId: accountId);
}

/// The Appwrite adapter over a fake `Account` (Appwrite Auth answers a
/// JWT it knows with its user, and refuses any other with 401) and the
/// key rows in memory.
final class _AppwriteFixture implements AccountFixture {
  final _tokens = <String, String>{};
  final _keys = ApiKeys(rows: MemoryRows(), admins: const _Nobody());

  @override
  late final AppwriteAccountCheck check = AppwriteAccountCheck(
    keys: _keys,
    accountOf: (token) {
      final account = _MockAccount();
      when(account.get).thenAnswer((_) async {
        final id =
            _tokens[token] ??
            (throw AppwriteException('Invalid token', 401, 'user_jwt_invalid'));
        final user = _MockUser();
        when(() => user.$id).thenReturn(id);
        return user;
      });
      return account;
    },
  );

  @override
  Future<String> jwtOf(String accountId) async {
    final token = 'eyJ.$accountId';
    _tokens[token] = accountId;
    return token;
  }

  @override
  Future<String> keyOf(String accountId) => _keys.create(caller: accountId);

  @override
  Future<void> revoke(String accountId) =>
      _keys.revoke(caller: accountId, accountId: accountId);
}

final class _Nobody implements Admins {
  const new();

  @override
  Future<bool> isAdmin(String accountId) async => false;
}

void main() {
  group(MemoryAccountCheck, () {
    accountCheckContract(
      () async => _MemoryFixture(),
      accounts: const ['a-1', 'a-2'],
    );

    test("reads keys only: nobody revokes another account's key", () async {
      final check = MemoryAccountCheck();
      await check.keys.create(caller: 'a-1');

      await expectLater(
        check.keys.revoke(caller: 'a-2', accountId: 'a-1'),
        throwsA(isA<Refused>()),
      );
    });
  });

  group(AppwriteAccountCheck, () {
    accountCheckContract(
      () async => _AppwriteFixture(),
      accounts: const ['a-1', 'a-2'],
    );

    AppwriteAccountCheck failing(AppwriteException error) =>
        AppwriteAccountCheck(
          keys: ApiKeys(rows: MemoryRows(), admins: const _Nobody()),
          accountOf: (_) {
            final account = _MockAccount();
            when(account.get).thenThrow(error);
            return account;
          },
        );

    test('a malformed JWT (400) gives no account', () async {
      expect(await failing(AppwriteException('bad', 400)).jwt('x'), isNull);
    });

    test('an error of Appwrite itself is not a refusal: it is rethrown', () {
      expect(
        failing(AppwriteException('down', 503)).jwt('x'),
        throwsA(isA<AppwriteException>()),
      );
    });

    test('connects to an instance: the JWT goes to Appwrite Auth', () {
      final check = AppwriteAccountCheck.connect(
        endpoint: 'http://127.0.0.1:9/v1',
        project: 'hawkbee',
        keys: ApiKeys(rows: MemoryRows(), admins: const _Nobody()),
      );

      expect(check.jwt('eyJ.a-1'), throwsA(isA<AppwriteException>()));
    });
  });
}

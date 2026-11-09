import 'package:battle_backend/battle_backend.dart';

/// Who a client is (a port, stack decision 7): the sign-in of the host's
/// endpoints (stack decisions 3 and 6, M6 Issue 5). The fake and the
/// Appwrite adapter pass one contract suite (Liskov).
abstract interface class AccountCheck {
  /// The account of the player's Appwrite JWT [token]; null when it is not
  /// valid or has expired.
  Future<String?> jwt(String token);

  /// The account of the API [key] (AI-04, decision 158), resolved by its
  /// hash; null for a key that is not one, unknown or revoked (decision
  /// 161).
  Future<String?> apiKey(String key);
}

/// {@template memory_account_check}
/// An [AccountCheck] in memory, for tests and local runs: the JWTs it
/// knows ([jwts], token to account), and the API keys of [keys], on its
/// own rows in memory unless given.
/// {@endtemplate}
final class MemoryAccountCheck implements AccountCheck {
  /// {@macro memory_account_check}
  new({Map<String, String> jwts = const {}, ApiKeys? keys})
    : jwts = {...jwts},
      keys = keys ?? ApiKeys(rows: MemoryRows(), admins: const _NoAdmins());

  /// The valid JWTs, token to account; a test issues and expires them.
  final Map<String, String> jwts;

  /// The API keys.
  final ApiKeys keys;

  @override
  Future<String?> jwt(String token) async => jwts[token];

  @override
  Future<String?> apiKey(String key) => keys.accountOf(key);
}

/// Nobody is an admin: the host only reads keys.
final class _NoAdmins implements Admins {
  const new();

  @override
  Future<bool> isAdmin(String accountId) async => false;
}

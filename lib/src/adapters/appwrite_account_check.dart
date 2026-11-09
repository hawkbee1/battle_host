import 'package:battle_backend/battle_backend.dart';
import 'package:battle_host/src/ports/account_check.dart';
import 'package:dart_appwrite/dart_appwrite.dart';

/// {@template appwrite_account_check}
/// An [AccountCheck] on Appwrite (Adapter, stack decision 6): a JWT is
/// checked once with Appwrite Auth, by reading the account it opens
/// ([accountOf], `Account.get` on a client that carries it); an API key is
/// looked up by its hash in [keys], on the `bt_api_keys` table.
/// {@endtemplate}
final class AppwriteAccountCheck implements AccountCheck {
  /// {@macro appwrite_account_check}
  new({required this.keys, required this.accountOf});

  /// The check on the instance at [endpoint], in [project], with the keys
  /// of [keys].
  factory connect({
    required String endpoint,
    required String project,
    required ApiKeys keys,
  }) => AppwriteAccountCheck(
    keys: keys,
    accountOf: (token) => Account(
      Client()
        ..setEndpoint(endpoint)
        ..setProject(project)
        ..setJWT(token),
    ),
  );

  /// The API keys.
  final ApiKeys keys;

  /// The Account service of a client signed in with a JWT.
  final Account Function(String token) accountOf;

  /// Appwrite refuses a JWT that is malformed (400), not valid or expired
  /// (401). Any other error is Appwrite's, not the client's: it is
  /// rethrown.
  @override
  Future<String?> jwt(String token) async {
    try {
      return (await accountOf(token).get()).$id;
    } on AppwriteException catch (error) {
      if (error.code == 400 || error.code == 401) return null;
      rethrow;
    }
  }

  @override
  Future<String?> apiKey(String key) => keys.accountOf(key);
}

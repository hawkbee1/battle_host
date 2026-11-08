import 'dart:collection';

import 'package:battle_protocol/battle_protocol.dart';

/// Who asked: a battle, an account, and the request ID it chose.
typedef RequestKey = (String battleId, String accountId, int requestId);

/// {@template request_memory}
/// The answers the host gave to commands, by battle, account and the
/// request ID the client chose (M6 Issue 5): a command resent with an ID
/// already answered gets the first answer again and is not carried out
/// twice. The same memory serves the socket and HTTPS, so a command first
/// sent on one and resent on the other is carried out once.
///
/// An answer is kept for [keep] after it was given: a client resends what
/// got no answer once it is back (M6 Issue 7), and its sign-in JWT lasts
/// 15 minutes (stack decision 3). Its size is bounded by the rate limit
/// (each sender's orders in [keep]). It is not battle state: a restarted
/// host has none.
/// {@endtemplate}
final class RequestMemory {
  /// {@macro request_memory}
  new({this.keep = const Duration(minutes: 15)});

  /// How long an answer is kept.
  final Duration keep;

  final _answers = <RequestKey, HostMessage>{};
  final _given = Queue<(RequestKey, DateTime)>();

  /// How many answers are kept.
  int get length => _answers.length;

  /// The answer given to [key], if it is still kept at [now].
  HostMessage? recall(RequestKey key, DateTime now) {
    _forget(now);
    return _answers[key];
  }

  /// Keeps [answer] to [key], given at [now].
  void remember(RequestKey key, HostMessage answer, DateTime now) {
    _forget(now);
    _answers[key] = answer;
    _given.add((key, now));
  }

  void _forget(DateTime now) {
    while (_given.isNotEmpty && now.difference(_given.first.$2) >= keep) {
      _answers.remove(_given.removeFirst().$1);
    }
  }
}

import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/orders/command_handler.dart';
import 'package:battle_host/src/orders/rate_limit.dart';
import 'package:battle_host/src/orders/refusal.dart';
import 'package:battle_host/src/ports/clock.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// Where commands go (a port, stack decision 7): one entry for every
/// sender (players, AI agents, the server and the bridge).
abstract interface class CommandSink {
  /// Submits [command] from a sender signed in as [origin] (decisions 162
  /// and 166).
  HandledOrder submit(Command command, {required Origin origin});
}

/// {@template battle_commands}
/// The commands of one battle (Facade): its handler, with origin tagging
/// and logging around it (Decorator, decisions 162 and 166): each command
/// gets the origin of its sign-in and the battle's next sequence number,
/// then is [record]ed with its events. The battle's own events are
/// recorded as they happen.
///
/// A command is acknowledged ([submit] returns) only once its entry is in
/// the write-ahead log, synced to disk (stack decision 2).
/// {@endtemplate}
final class BattleCommands implements CommandSink {
  /// {@macro battle_commands}
  new({required this.battle, required this.record}) {
    battle.onEntry = record;
  }

  /// The battle.
  final Battle battle;

  /// Where its entries go: its log, then its update stream.
  final void Function(LogEntry entry) record;

  @override
  HandledOrder submit(Command command, {required Origin origin}) {
    final stamped = command.stamped(origin: origin, seq: battle.takeSeq());
    final handled = battle.orders.handle(stamped);
    record(LogEntry(at: battle.time, command: stamped, events: handled.events));
    return HandledOrder(
      events: handled.events,
      refusal: handled.refusal,
      seq: stamped.seq,
    );
  }
}

/// {@template rate_limited_commands}
/// A rate limit per sender in front of [inner] (Decorator, AI-03): the
/// same for players and AI agents, to stop floods. The server's own
/// commands (logins, its sections) are not limited. A command over the
/// limit is refused before it gets a sequence number, and is not logged.
/// {@endtemplate}
final class RateLimitedCommands implements CommandSink {
  /// {@macro rate_limited_commands}
  new({required this.inner, required this.limit, required this.clock});

  /// The sink behind the limit.
  final CommandSink inner;

  /// The limit.
  final RateLimit limit;

  /// The wall clock.
  final Clock clock;

  @override
  HandledOrder submit(Command command, {required Origin origin}) =>
      origin == Origin.server ||
          limit.take(command.sender.accountId, clock.now())
      ? inner.submit(command, origin: origin)
      : const HandledOrder(events: [], refusal: RateRefused());
}

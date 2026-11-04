import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/orders/command_handler.dart';
import 'package:battle_host/src/orders/rate_limit.dart';
import 'package:battle_host/src/orders/refusal.dart';
import 'package:battle_host/src/ports/clock.dart';
import 'package:battle_host/src/ports/log_sink.dart';
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
/// then goes to the log with its events. The battle's own events go to
/// the log as they happen.
/// {@endtemplate}
final class BattleCommands implements CommandSink {
  /// {@macro battle_commands}
  new({required this.battle, required this.log}) {
    battle.onEvents = (at, events) =>
        log.append(battle.id, LogEntry(at: at, events: events));
  }

  /// The battle.
  final Battle battle;

  /// Its log.
  final LogSink log;

  @override
  HandledOrder submit(Command command, {required Origin origin}) {
    final stamped = command.stamped(origin: origin, seq: battle.takeSeq());
    final handled = battle.orders.handle(stamped);
    log.append(
      battle.id,
      LogEntry(at: battle.time, command: stamped, events: handled.events),
    );
    return handled;
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

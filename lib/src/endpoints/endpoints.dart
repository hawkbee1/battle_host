import 'package:battle_host/src/core/simulation_host.dart';
import 'package:battle_host/src/endpoints/connection.dart';
import 'package:battle_host/src/endpoints/request_memory.dart';
import 'package:battle_host/src/ports/account_check.dart';
import 'package:battle_host/src/ports/clock.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// {@template endpoint_settings}
/// The host's values for its endpoints (stack decision 3, M6 Issue 5):
/// they are the host's, not rules.
/// {@endtemplate}
final class EndpointSettings {
  /// {@macro endpoint_settings}
  const new({
    this.idleTimeout = const Duration(seconds: 60),
    this.keyCheck = const Duration(seconds: 60),
    this.queueBound = 1 << 20,
    this.maxMessage = 256 << 10,
  });

  /// A socket that sends nothing, not even a heartbeat, for this long is
  /// closed ([GoodbyeReason.idle]); a client sends a heartbeat every 20
  /// seconds. A socket that never signs in is closed after it too.
  final Duration idleTimeout;

  /// How often the API keys of the sockets signed in with one are checked
  /// again: a revoked key's socket is closed
  /// ([GoodbyeReason.keyRevoked], decision 161).
  final Duration keyCheck;

  /// The bytes that may wait for a slow client behind the message being
  /// written and the oldest one waiting: past them, the client is dropped
  /// ([GoodbyeReason.slowClient]).
  final int queueBound;

  /// The largest message a client may send, in bytes (characters in
  /// JSON): a move order with a long client path fits.
  final int maxMessage;
}

/// {@template seat}
/// Where a signed-in client sits: its [accountId] and the account's
/// section [sectionId] of [team] in [battleId]. Its commands are logged
/// with [origin]: `player` for a JWT, `ai` for an API key (decision 162).
/// {@endtemplate}
final class Seat {
  /// {@macro seat}
  const new({
    required this.battleId,
    required this.accountId,
    required this.sectionId,
    required this.team,
    required this.origin,
  });

  /// The battle.
  final String battleId;

  /// The signed-in account.
  final String accountId;

  /// Its section in the battle.
  final String sectionId;

  /// The section's team.
  final String team;

  /// The origin of its commands.
  final Origin origin;

  /// The sender of its commands, whatever a client wrote.
  Sender get sender => Sender(accountId: accountId, sectionId: sectionId);
}

/// {@template call_answer}
/// The answer to one HTTPS call: its HTTP [status], and a protocol
/// [message] or, for a request the protocol does not read, an [error].
/// {@endtemplate}
final class CallAnswer {
  /// {@macro call_answer}
  const new(this.status, {this.message, this.error});

  /// The HTTP status.
  final int status;

  /// The message, in JSON.
  final HostMessage? message;

  /// What is wrong with the request.
  final String? error;
}

/// {@template endpoints}
/// The network side of a host process (Facade, stack decisions 3 and 6, M6
/// Issue 5), free of sockets: the WebSocket and HTTPS adapters call it, so
/// the sign-in, the request-ID memory and the queues are tested without a
/// socket. Players and AI agents hold [Connection]s; AI agents and the
/// server may also send single commands over HTTPS ([call]). Both feed
/// [SimulationHost.submit].
///
/// - Sign-in ([seat]): a JWT checked once with Appwrite, or an API key
///   resolved by its hash ([accounts]); the account must have a section in
///   the battle. A socket's sign-in is the account logging in to the
///   battle: the server's `EnterBattle` (HQ-07, decision 220).
/// - The sender of a command is the signed-in account and its section,
///   whatever the client wrote; its origin is the sign-in's (AI-05).
/// - A command resent with a request ID already answered gets the first
///   answer again ([memory]).
/// - The rate limit is the host's, one per sender, the same for players
///   and AI agents (AI-03).
/// {@endtemplate}
final class Endpoints {
  /// {@macro endpoints}
  new({
    required this.host,
    required this.accounts,
    this.settings = const EndpointSettings(),
    RequestMemory? memory,
  }) : memory = memory ?? RequestMemory(),
       _keysCheckedAt = host.clock.now();

  /// The host process.
  final SimulationHost host;

  /// Who a client is.
  final AccountCheck accounts;

  /// The endpoints' values.
  final EndpointSettings settings;

  /// The answers given, by request ID.
  final RequestMemory memory;

  final _connections = <Connection>{};
  DateTime _keysCheckedAt;

  /// The wall clock.
  Clock get clock => host.clock;

  /// The sockets open.
  Set<Connection> get connections => Set.unmodifiable(_connections);

  /// A socket opened by a client: it waits for its sign-in.
  Connection open(ClientSocket socket) {
    final connection = Connection(this, socket);
    _connections.add(connection);
    return connection;
  }

  /// [connection] closed: its section is no longer sent anything.
  void forget(Connection connection) {
    _connections.remove(connection);
    if (connection.seat case Seat(:final battleId)) {
      host.unsubscribe(battleId, connection);
    }
  }

  /// Where a client that signs in to [battleId] with [credential] of
  /// [kind] sits, or why it is refused.
  Future<(Seat?, SignInRefusal?)> seat(
    String battleId,
    CredentialKind kind,
    String credential,
  ) async {
    if (host[battleId] == null) return (null, SignInRefusal.battleNotFound);
    final account = switch (kind) {
      CredentialKind.jwt => await accounts.jwt(credential),
      CredentialKind.apiKey => await accounts.apiKey(credential),
    };
    if (account == null) return (null, SignInRefusal.invalidCredential);
    final battle = host[battleId];
    if (battle == null) return (null, SignInRefusal.battleNotFound);
    final section = battle.state.sections.values
        .where((section) => section.accountId == account)
        .firstOrNull;
    if (section == null) return (null, SignInRefusal.noSection);
    return (
      Seat(
        battleId: battleId,
        accountId: account,
        sectionId: section.id,
        team: section.team,
        origin: switch (kind) {
          CredentialKind.jwt => Origin.player,
          CredentialKind.apiKey => Origin.ai,
        },
      ),
      null,
    );
  }

  /// [connection] signed in: it is told so, gets its section's whole view
  /// and its waiting alerts, then the server logs the account in to the
  /// battle (HQ-07, decision 220), after the subscription so that the
  /// alerts go out once (decision 233).
  void enter(Connection connection) {
    final seat = connection.seat!;
    final battle = host[seat.battleId]!;
    connection.send(
      SignInAccepted(
        accountId: seat.accountId,
        sectionId: seat.sectionId,
        team: seat.team,
        battleTime: battle.time,
      ),
    );
    host
      ..subscribe(seat.battleId, seat.sectionId, connection)
      ..submit(
        seat.battleId,
        Command(
          sender: seat.sender,
          sentAt: battle.time,
          order: const EnterBattle(),
        ),
        origin: Origin.server,
      );
  }

  /// [connection] asks for its whole view again.
  void resync(Connection connection) {
    final seat = connection.seat!;
    host
      ..unsubscribe(seat.battleId, connection)
      ..subscribe(seat.battleId, seat.sectionId, connection);
  }

  /// Carries out [command] for [seat], as its request [requestId]: the
  /// answer, the first one again for a request already answered; null
  /// when the battle no longer runs here.
  ///
  /// It returns once the command's entry is on disk (M5.15). A failure to
  /// write the log stops the battle and is rethrown: the command is not
  /// acknowledged.
  HostMessage? command(Seat seat, int requestId, Command command) {
    if (host[seat.battleId] == null) return null;
    final key = (seat.battleId, seat.accountId, requestId);
    if (memory.recall(key, clock.now()) case final answer?) return answer;
    final handled = host.submit(
      seat.battleId,
      Command(
        sender: seat.sender,
        sentAt: command.sentAt,
        order: command.order,
      ),
      origin: seat.origin,
    );
    final answer = switch (handled.refusal) {
      final refusal? => CommandRefused(
        requestId: requestId,
        reason: refusal.code,
      ),
      null => CommandAccepted(requestId: requestId, seq: handled.seq!),
    };
    memory.remember(key, answer, clock.now());
    return answer;
  }

  /// One HTTPS call to [battleId]: a [SendCommand] in JSON ([body]), with
  /// the API key as a bearer token in [authorization]. The key is checked
  /// on every call, so a revoked key is refused on the next one (decision
  /// 161).
  ///
  /// Statuses: 200 with the answer; 429 when the rate limit refused it;
  /// 400 for a body that is not a command in a version the host reads;
  /// 401, 403 and 404 for a refused sign-in.
  Future<CallAnswer> call(
    String battleId, {
    required String? authorization,
    required String body,
  }) async {
    final key = _bearer(authorization);
    if (key == null) return _refused(SignInRefusal.invalidCredential);
    final ClientMessage message;
    try {
      message = const JsonProtocolCodec().decodeClientMessage(body);
    } on UnsupportedVersionException {
      return const CallAnswer(
        400,
        message: Goodbye(GoodbyeReason.unsupportedVersion),
      );
    } on ProtocolException catch (error) {
      return CallAnswer(400, error: error.message);
    }
    if (message is! SendCommand) {
      return const CallAnswer(400, error: 'not a command');
    }
    final (seat, refusal) = await this.seat(
      battleId,
      CredentialKind.apiKey,
      key,
    );
    if (seat == null) return _refused(refusal!);
    // The seat was just found: its battle runs.
    final answer = command(seat, message.requestId, message.command)!;
    return switch (answer) {
      CommandRefused(reason: 'rate_limited') => CallAnswer(
        429,
        message: answer,
      ),
      _ => CallAnswer(200, message: answer),
    };
  }

  static String? _bearer(String? authorization) => switch (authorization) {
    final String header when header.startsWith('Bearer ') =>
      header.substring(7).trim(),
    _ => null,
  };

  static CallAnswer _refused(SignInRefusal refusal) =>
      CallAnswer(switch (refusal) {
        SignInRefusal.invalidCredential => 401,
        SignInRefusal.noSection => 403,
        SignInRefusal.battleNotFound => 404,
      }, message: SignInRefused(refusal));

  /// Once a second, after the host's tick: closes the sockets that were
  /// idle too long, those of a battle that ended (after its last update)
  /// or no longer runs here, and, every [EndpointSettings.keyCheck], those
  /// whose API key was revoked.
  Future<void> tick() async {
    final now = clock.now();
    for (final connection in _connections.toList()) {
      if (now.difference(connection.heardAt) >= settings.idleTimeout) {
        connection.goodbye(GoodbyeReason.idle);
        continue;
      }
      final seat = connection.seat;
      if (seat == null) continue;
      final battle = host[seat.battleId];
      if (battle == null) {
        connection.close(CloseCode.goingAway);
      } else if (battle.state.ended) {
        connection.goodbye(GoodbyeReason.battleEnded);
      }
    }
    if (now.difference(_keysCheckedAt) < settings.keyCheck) return;
    _keysCheckedAt = now;
    for (final connection in _connections.toList()) {
      if (connection.apiKey case final key?) {
        if (await accounts.apiKey(key) == null) {
          connection.goodbye(GoodbyeReason.keyRevoked);
        }
      }
    }
  }

  /// Closes every socket: the host stops, and its clients come back to it
  /// or to the host that runs their battle next.
  void closeAll() {
    for (final connection in _connections.toList()) {
      connection.close(CloseCode.goingAway);
    }
  }
}

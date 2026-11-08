import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// {@template pending_alerts}
/// The relic alerts the players of a battle have not received yet
/// (RELIC-10, decision 233): when a relic changes owner, each player of the
/// previous owner team who is connected is alerted at once, and each of
/// the others on their next connection, once.
///
/// Delivery state, not battle state: it is kept in the battle's snapshot,
/// and a recovered host rebuilds what came after the snapshot from the
/// replayed entries ([hear], nobody connected). A player's connection is
/// its `EnterBattle` entry (HQ-07), which clears its alerts. After a crash,
/// a player who was connected when a relic changed owner since the last
/// snapshot, and has not connected again since, receives that alert once
/// more: an alert is never lost.
/// {@endtemplate}
final class PendingAlerts {
  /// {@macro pending_alerts}
  new([Map<String, List<RelicAlert>> pending = const {}])
    : _pending = {
        for (final MapEntry(:key, :value) in pending.entries) key: [...value],
      };

  final Map<String, List<RelicAlert>> _pending;

  /// The alerts waiting, by account.
  Map<String, List<RelicAlert>> get pending => {
    for (final MapEntry(:key, :value) in _pending.entries)
      if (value.isNotEmpty) key: List.unmodifiable(value),
  };

  /// What [entry] means for the alerts, on [state]: a relic that changed
  /// owner alerts every player of its previous owner team, at once when
  /// [connected], else on their next connection; a player's `EnterBattle`
  /// is a connection. Returns the alerts to deliver now, with their
  /// accounts.
  List<(String, RelicAlert)> hear(
    LogEntry entry,
    BattleState state, {
    Set<String> connected = const {},
  }) {
    final now = <(String, RelicAlert)>[];
    if (entry.command case Command(order: EnterBattle(), :final sender)) {
      now.addAll(
        take(sender.accountId).map((alert) => (sender.accountId, alert)),
      );
    }
    for (final event in entry.events) {
      if (event case RelicCaptured(
        :final relicId,
        :final team,
        previousOwner: final previous?,
      )) {
        final alert = RelicAlert(at: entry.at, relicId: relicId, team: team);
        for (final section in state.sections.values) {
          if (section.team != previous) continue;
          if (connected.contains(section.accountId)) {
            now.add((section.accountId, alert));
          } else {
            (_pending[section.accountId] ??= []).add(alert);
          }
        }
      }
    }
    return [
      for (final (account, alert) in now)
        if (connected.contains(account)) (account, alert),
    ];
  }

  /// The alerts waiting for [accountId], which it receives now: they are
  /// no longer waiting.
  List<RelicAlert> take(String accountId) => _pending.remove(accountId) ?? [];
}

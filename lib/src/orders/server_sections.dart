import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/orders/command_handler.dart';
import 'package:battle_host/src/orders/rewards.dart';
import 'package:battle_host/src/orders/world.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template server_sections}
/// The sections the server runs (AI-06 to AI-09; decisions 159, 160, 163 to
/// 166, 196): sections like any other, whose orders the server gives
/// through the command handler with the origin `server`.
///
/// Each of their units has a fire check, a timer every `check_interval_s`
/// ([ServerFireCheck]): when it is due, a unit on the field that sees an
/// enemy unit within its weapon's range fires at the nearest with
/// `fire_chance`, drawn with the battle's random. The shot is a `Fire`
/// order, carried out and logged like any other (AI-08). Nothing is drawn
/// when an enemy comes into range.
///
/// A listener (Observer): a unit that joins such a section, bought or
/// turned, gets its own check. A unit that leaves it, or dies, has none
/// after the one due.
/// {@endtemplate}
final class ServerSections implements BattleListener {
  /// {@macro server_sections}
  new({required this.battle, required this.world, required this.orders})
    : _check = ServerFireCheck(battle.settings.serverManaged);

  /// The battle.
  final Battle battle;

  /// Its world geometry.
  final World world;

  /// Its command handler, which carries the orders out.
  final CommandHandler orders;

  final ServerFireCheck _check;

  BattleState get _state => battle.state;
  Duration get _now => battle.time;

  static bool _runs(UnitState? unit, BattleState state) =>
      unit != null && state.sections[unit.sectionId]!.serverManaged;

  @override
  List<BattleEvent> hear(List<BattleEvent> events, BattleState before) {
    for (final event in events) {
      final joined = switch (event) {
        UnitPurchased(:final unitId) => [unitId],
        Attacked(:final impacts) => [
          for (final impact in impacts)
            if (impact.result == ImpactResult.defected) impact.targetId,
        ],
        _ => const <String>[],
      };
      for (final unitId in joined) {
        if (_runs(_state.units[unitId], _state) &&
            !_runs(before.units[unitId], before)) {
          battle.schedule(_now + _check.interval, ServerCheck(unitId));
        }
      }
    }
    return const [];
  }

  /// The fire check of [unitId] due now (AI-07): the order it gives, if
  /// any, with its events. The next check is due an interval later, while
  /// the unit is in a server-managed section of a team still in the
  /// battle.
  (Command?, List<BattleEvent>) check(String unitId) {
    final unit = _state.units[unitId];
    if (unit == null || !_runs(unit, _state) || _state.ended) {
      return (null, const []);
    }
    final section = _state.sections[unit.sectionId]!;
    if (_state.teams[section.team]!.eliminated) return (null, const []);
    battle.schedule(_now + _check.interval, ServerCheck(unitId));
    final target = unit.location is Deployed ? _target(unit) : null;
    if (target == null || !_check.fires(battle.random)) {
      return (null, const []);
    }
    final command = Command(
      sender: Sender(accountId: section.accountId, sectionId: section.id),
      sentAt: _now,
      order: Fire(unitId: unitId, targetId: target),
      origin: Origin.server,
      seq: battle.takeSeq(),
    );
    return (command, orders.handle(command).events);
  }

  /// The nearest enemy unit [unit] sees within its weapon's range; the
  /// first by ID among those as near.
  String? _target(UnitState unit) {
    final range = unit.weapon.weapon?.rangeM;
    if (range == null) return null;
    final team = _state.sections[unit.sectionId]!.team;
    String? nearest;
    var best = double.infinity;
    for (final other in _state.units.values) {
      if (other.location is! Deployed ||
          _state.sections[other.sectionId]!.team == team ||
          world.distanceM(unit.cell!, other.cell!) > range) {
        continue;
      }
      final distance = orders.shotDistance(unit, other.id);
      if (distance == null) continue;
      if (distance < best ||
          (distance == best && other.id.compareTo(nearest!) < 0)) {
        nearest = other.id;
        best = distance;
      }
    }
    return nearest;
  }
}

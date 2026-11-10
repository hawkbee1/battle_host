import 'dart:math' as math;

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// A section's view as a client keeps it: its whole view, then each update
/// applied, as `battle_client` will (M6 Issue 7). Unit HP follow the hits
/// and heals of the events; a unit's other public values come with it.
final class ViewHolder implements SectionSubscriber {
  final received = <HostMessage>[];
  final units = <String, UnitView>{};
  final hqs = <String, HqView>{};
  final relics = <String, RelicView>{};
  SectionPrivate? section;
  Roster? roster;
  (String, Duration)? hold;
  final craters = <(int, int, double, double)>[];
  final built = <String, String>{};
  final damaged = <String, double>{};
  final destroyed = <String>{};

  @override
  void send(HostMessage message) {
    received.add(message);
    switch (message) {
      case SectionView():
        units
          ..clear()
          ..addEntries(message.units.map((u) => MapEntry(u.unitId, u)));
        hqs
          ..clear()
          ..addEntries(message.hqs.map((h) => MapEntry(h.team, h)));
        relics
          ..clear()
          ..addEntries(message.relics.map((r) => MapEntry(r.relicId, r)));
        section = message.section;
        hold = switch (message.hold) {
          final hold? => (hold.team, hold.winsAt),
          null => null,
        };
        craters.clear();
        built.clear();
        damaged.clear();
        destroyed.clear();
        message.world.forEach(_world);
      case TickUpdate():
        for (final UnitPosition(:unitId, :position) in message.moved) {
          units[unitId] = _with(units[unitId]!, position: position);
        }
        for (final unit in [...message.appeared, ...message.ownUnits]) {
          units[unit.unitId] = unit;
        }
        message.gone.forEach(units.remove);
        message.events.forEach(_event);
        for (final burst in message.bursts) {
          burst.impacts.forEach(_hit);
        }
        for (final fired in message.fired) {
          fired.impacts.forEach(_hit);
        }
        for (final hit in message.unseenHits) {
          _damage(hit.targetId, hit.damage);
        }
        section = message.section ?? section;
        for (final hq in message.hqs) {
          hqs[hq.team] = hq;
        }
        message.hqsGone.forEach(hqs.remove);
        for (final relic in message.relics) {
          relics[relic.relicId] = relic;
        }
      case Roster():
        roster = message;
      case SignInAccepted() ||
          SignInRefused() ||
          CommandAccepted() ||
          CommandRefused() ||
          RelicAlert() ||
          Goodbye():
        break;
    }
  }

  void _event(BattleEvent event) {
    switch (event) {
      case Attacked(:final impacts):
        impacts.forEach(_hit);
      case UnitHealed(targetId: final id, :final hp) ||
          Repaired(targetId: final id, :final hp):
        if (units[id] case final unit?) units[id] = _with(unit, hp: hp);
      case VictoryHoldStarted(:final team, :final winsAt):
        hold = (team, winsAt);
      case VictoryHoldReset():
        hold = null;
      case StructureBuilt() ||
          ObjectDamaged() ||
          ObjectDestroyed() ||
          CraterDug():
        _world(event);
      default:
        break;
    }
  }

  void _hit(Impact impact) => _damage(impact.targetId, impact.damage);

  void _damage(String unitId, double damage) {
    final unit = units[unitId];
    if (unit == null || unit.private != null) return;
    units[unitId] = _with(unit, hp: math.max(0, unit.hp - damage));
  }

  void _world(BattleEvent event) {
    switch (event) {
      case CraterDug(:final at, :final radiusM, :final depthM):
        craters.add((at.xCm, at.yCm, radiusM, depthM));
      case StructureBuilt(:final siteId, :final structure):
        built[siteId] = structure;
      case ObjectDamaged(:final object, :final cells, :final hp):
        damaged['$object$cells'] = hp;
      case ObjectDestroyed(:final object, :final cells):
        damaged.remove('$object$cells');
        destroyed.add('$object$cells');
      default:
        throw StateError('not a world event: $event');
    }
  }

  static UnitView _with(UnitView unit, {Position? position, double? hp}) =>
      UnitView(
        unitId: unit.unitId,
        unitType: unit.unitType,
        sectionId: unit.sectionId,
        team: unit.team,
        hp: hp ?? unit.hp,
        maxHp: unit.maxHp,
        position: position ?? unit.position,
        flying: unit.flying,
        weapon: unit.weapon,
        private: unit.private,
      );

  /// What the client holds, to compare two clients.
  List<Object?> get held => [
    {for (final MapEntry(:key, :value) in units.entries) key: value},
    {for (final MapEntry(:key, :value) in hqs.entries) key: value},
    {for (final MapEntry(:key, :value) in relics.entries) key: value},
    section,
    hold,
    craters.toList(),
    {...built},
    {...damaged},
    {...destroyed},
  ];
}

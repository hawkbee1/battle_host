import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/orders/section_orders.dart';
import 'package:battle_host/src/orders/world.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// Hears the events of a battle with its state before them, and makes
/// what follows from them (Observer, stack decision 7).
abstract interface class BattleListener {
  /// What follows from [events], which changed the state from [before]:
  /// the state changes it makes, and the events they give.
  List<BattleEvent> hear(List<BattleEvent> events, BattleState before);
}

/// {@template rewards}
/// The XP and money earned on the events that give them (UNIT-05 to
/// UNIT-10, UNIT-14, ECO-02, ECO-03, ECO-18; decisions 201, 202): hits and
/// kills, constructions, repairs, heals, HQ hits and destruction. A section
/// that loses its last unit besides its commander gets its money floor
/// (ECO-13).
///
/// A target taken prisoner or turned is out of its team like a dead one:
/// it earns the kill (assumed, Q-UNIT-24). An HQ earns money, not XP
/// (assumed, Q-UNIT-25).
/// {@endtemplate}
final class Rewards implements BattleListener {
  /// {@macro rewards}
  new({required this.battle, required this.world})
    : _xp = XpRules(battle.definitions.units.progression),
      _money = MoneyRules(battle.definitions.economy);

  /// The battle.
  final Battle battle;

  /// Its world geometry.
  final World world;

  final XpRules _xp;
  final MoneyRules _money;

  BattleState get _state => battle.state;

  @override
  List<BattleEvent> hear(List<BattleEvent> events, BattleState before) {
    for (final event in events) {
      switch (event) {
        case Attacked():
          _attacked(event, before);
        case StructureBuilt(:final siteId, :final cells):
          final builder = before.units.values.firstWhere(
            (unit) => unit.work?.workId == siteId,
          );
          final at = world.pointOf(world.cellOf(cells.first)!);
          _award(builder.id, RoleActionXp(FromBuild(xM: at.x, yM: at.y)));
          _pay(builder.sectionId, const ConstructionEarning());
        case Repaired(:final targetId):
          final repairer = before.units.values.firstWhere(
            (unit) =>
                unit.work?.workId == targetId && unit.work!.structure == null,
          );
          _award(repairer.id, RoleActionXp(FromTarget(targetId)));
        case UnitHealed(:final unitId, :final targetId):
          final healer = _state.units[unitId]!;
          _award(unitId, RoleActionXp(FromTarget(targetId)));
          _pay(healer.sectionId, HealEarning(healer.type));
        case RelicCaptured(:final relicId):
          // UNIT-07, decision 179: shared by the AP each unit put in.
          final pot = before.relics[relicId]!.capturePot!;
          for (final MapEntry(key: unitId, value: xp)
              in _xp.captureShares(pot).entries) {
            _gain(unitId, xp);
          }
        case BattleEnded(:final winner):
          // UNIT-11: every unit of the winning team.
          for (final unit in _state.units.values.toList()) {
            if (_state.sections[unit.sectionId]!.team == winner) {
              _gain(unit.id, _xp.victoryXp);
            }
          }
        case _:
          break;
      }
    }
    _safetyNet(before);
    return const [];
  }

  void _attacked(Attacked attack, BattleState before) {
    final attackerXp = before.units[attack.attackerId]!.xp.earned;
    for (final impact in attack.impacts) {
      final out = impact.result != ImpactResult.damaged;
      if (impact.targetType == 'hq') {
        _pay(attack.sectionId, HqHitEarning(own: impact.friendly));
        if (out) {
          _pay(attack.sectionId, HqDestroyedEarning(own: impact.friendly));
        }
        continue;
      }
      final targetXp = before.units[impact.targetId]!.xp.earned;
      // Decision 201: the shot that kills earns its kill unshrunk by its
      // own hit.
      final history = _state.units[attack.attackerId]?.xpHistory;
      _award(
        attack.attackerId,
        HitXp(
          targetId: impact.targetId,
          attackerXp: attackerXp,
          targetXp: targetXp,
          friendly: impact.friendly,
        ),
      );
      _pay(attack.sectionId, HitEarning(ally: impact.friendly));
      if (!out) continue;
      _award(
        attack.attackerId,
        KillXp(
          targetId: impact.targetId,
          attackerXp: attackerXp,
          targetXp: targetXp,
          friendly: impact.friendly,
        ),
        history: history,
      );
      _pay(attack.sectionId, KillEarning(ally: impact.friendly));
    }
  }

  /// Gives [unitId] the XP of [event], less its section's share (UNIT-14),
  /// priced against its awards [history] (its own by default) and added to
  /// them. A unit that died of its own shot earns nothing.
  void _award(String unitId, XpEvent event, {XpHistory? history}) {
    final unit = _state.units[unitId];
    if (unit == null) return;
    final priced = _xp.earn(
      event,
      history: history ?? unit.xpHistory ?? XpHistory(),
      at: battle.time,
    );
    final award = XpAward(
      xp: priced.xp,
      history: history == null
          ? priced.history
          : XpHistory([
              ...?unit.xpHistory?.awards,
              ...priced.history.awards.skip(history.awards.length),
            ]),
    );
    final split = _xp.split(award.xp);
    final section = _state.sections[unit.sectionId]!;
    battle.change(
      (state) => state
          .withUnit(
            unit.copyWith(
              xp: unit.xp.gained(split.unit),
              xpHistory: award.history,
            ),
          )
          .withSection(section.withWallet(xp: section.xp + split.section)),
    );
  }

  /// Gives [unitId] [xp] that no repeat shrinks, less its section's share.
  void _gain(String unitId, double xp) {
    final unit = _state.units[unitId];
    if (unit == null) return;
    final split = _xp.split(xp);
    final section = _state.sections[unit.sectionId]!;
    battle.change(
      (state) => state
          .withUnit(unit.copyWith(xp: unit.xp.gained(split.unit)))
          .withSection(section.withWallet(xp: section.xp + split.section)),
    );
  }

  void _pay(String sectionId, Earning earning) {
    final amount = _money.earned(earning);
    if (amount == 0) return;
    final section = _state.sections[sectionId]!;
    battle.change(
      (state) =>
          state.withSection(section.withWallet(money: section.money + amount)),
    );
  }

  /// ECO-13: a section that lost a unit and owns none left besides its
  /// commander gets `max(money, minStartingMoney)`.
  void _safetyNet(BattleState before) {
    for (final section in _state.sections.values) {
      bool own(UnitState unit) => unit.sectionId == section.id;
      final lost = before.units.values.any((unit) {
        final now = _state.units[unit.id];
        return own(unit) && (now == null || !own(now));
      });
      if (!lost) continue;
      final left = _state.units.values
          .where((unit) => own(unit) && unit.type.category != commanderCategory)
          .length;
      battle.change(
        (state) => state.withSection(
          section.withWallet(
            money: _money.afterUnitLost(
              section.money,
              unitsLeft: left,
              warMinStartingMoney: battle.minStartingMoney,
            ),
          ),
        ),
      );
    }
  }
}

/// {@template storage_locks}
/// The 24-hour lock of a section whose last unit left the field, however
/// it left: stored, recalled, killed, taken prisoner or turned (HQ-35,
/// SOC-09, decisions 120, 204). The storage forced by its commander's
/// death starts none (decision 125).
/// {@endtemplate}
final class StorageLocks implements BattleListener {
  /// {@macro storage_locks}
  new(this.battle)
    : _storage = StorageRules(
        battle: battle.settings,
        morale: battle.definitions.combat.morale,
      );

  /// The battle.
  final Battle battle;

  final StorageRules _storage;

  @override
  List<BattleEvent> hear(List<BattleEvent> events, BattleState before) {
    final state = battle.state;
    final locked = <BattleEvent>[];
    for (final section in state.sections.values) {
      if (state.teams[section.team]!.eliminated) continue;
      bool onField(UnitState unit) =>
          unit.sectionId == section.id && unit.onField && unit.type.storable;
      if (!before.units.values.any(onField)) continue;
      final until = _storage.lockAfter(
        at: battle.time,
        units: [
          for (final unit in state.units.values)
            if (unit.sectionId == section.id) (unit.type, unit.location),
        ],
        byCommanderDeath: _commanderDied(events, before, section.id),
      );
      if (until == null) continue;
      battle
        ..change((state) => state.withSection(section.lockedTo(until)))
        ..schedule(until, SectionUnlocks(section.id));
      locked.add(SectionLocked(sectionId: section.id, until: until));
    }
    return locked;
  }

  /// Whether [events] killed the commander of [sectionId], by a shot or a
  /// crush (UNIT-28).
  static bool _commanderDied(
    List<BattleEvent> events,
    BattleState before,
    String sectionId,
  ) {
    bool commander(String unitId) {
      final unit = before.units[unitId];
      return unit != null &&
          unit.sectionId == sectionId &&
          unit.type.category == commanderCategory;
    }

    return events.any(
      (event) => switch (event) {
        Attacked(:final impacts) => impacts.any(
          (impact) =>
              impact.result == ImpactResult.killed &&
              commander(impact.targetId),
        ),
        Crushed(:final unitId) => commander(unitId),
        _ => false,
      },
    );
  }
}

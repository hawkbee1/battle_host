import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template unit_state}
/// A unit as of its last update: where it is, its AP pool, health and
/// morale. AP are lazy (stack decision 1): [pool] holds the value at its
/// last update and the battle's recovery rate, and gives the AP at any
/// later time (COMBAT-02). Morale has no rate: it changes only through
/// events (COMBAT-47), so [morale] holds until the next one.
/// {@endtemplate}
final class UnitState {
  /// {@macro unit_state}
  const new({
    required this.id,
    required this.sectionId,
    required this.type,
    required this.tree,
    required this.xp,
    required this.location,
    required this.pool,
    required this.health,
    required this.morale,
  });

  /// The unit.
  final String id;

  /// Its section.
  final String sectionId;

  /// The type it plays: its base type evolved by [tree] (UNIT-18).
  final UnitType type;

  /// Its bought nodes.
  final SkillTree tree;

  /// Its XP.
  final UnitXp xp;

  /// Where it is (State, stack decision 7).
  final UnitLocation location;

  /// Its AP pool.
  final ApPool pool;

  /// Its hit points.
  final Health health;

  /// Its morale.
  final double morale;

  /// This unit with the values given changed.
  UnitState copyWith({
    UnitLocation? location,
    ApPool? pool,
    Health? health,
    double? morale,
  }) => UnitState(
    id: id,
    sectionId: sectionId,
    type: type,
    tree: tree,
    xp: xp,
    location: location ?? this.location,
    pool: pool ?? this.pool,
    health: health ?? this.health,
    morale: morale ?? this.morale,
  );
}

/// {@template section_state}
/// A section in the battle: its commander's account, its team, its money,
/// its section XP and the end of its full storage lock (HQ-35), if any.
/// {@endtemplate}
final class SectionState {
  /// {@macro section_state}
  const new({
    required this.id,
    required this.accountId,
    required this.team,
    required this.money,
    required this.xp,
    this.lockedUntil,
  });

  /// The section.
  final String id;

  /// Its commander's account.
  final String accountId;

  /// Its team.
  final String team;

  /// Its money, in whole w€.
  final int money;

  /// Its section XP.
  final double xp;

  /// The battle time its lock ends; null when it is not locked.
  final Duration? lockedUntil;

  /// This section with its lock set to [until], or lifted when null.
  SectionState lockedTo(Duration? until) => SectionState(
    id: id,
    accountId: accountId,
    team: team,
    money: money,
    xp: xp,
    lockedUntil: until,
  );
}

/// {@template hq_state}
/// A team's HQ: its [cell], its hit points and its own AP pool (HQ-14,
/// HQ-22).
/// {@endtemplate}
final class HqState {
  /// {@macro hq_state}
  const new({required this.cell, required this.health, required this.pool});

  /// Where it stands.
  final CellRef cell;

  /// Its hit points.
  final Health health;

  /// Its AP pool.
  final ApPool pool;
}

/// {@template team_state}
/// A team: its HQ and whether it is eliminated (HQ-18).
/// {@endtemplate}
final class TeamState {
  /// {@macro team_state}
  const new({required this.id, required this.hq, this.eliminated = false});

  /// The team.
  final String id;

  /// Its HQ.
  final HqState hq;

  /// Whether it is out of the battle.
  final bool eliminated;
}

/// {@template relic_state}
/// A relic: its [cell], its owner and its pots (RELIC-05, RELIC-24).
/// {@endtemplate}
final class RelicState {
  /// {@macro relic_state}
  const new({
    required this.id,
    required this.cell,
    this.owner,
    this.capturePot,
    this.pushPot,
  });

  /// The relic.
  final String id;

  /// Where it stands.
  final CellRef cell;

  /// The team that owns it; null before its first capture.
  final String? owner;

  /// The capture under way, if any.
  final CapturePot? capturePot;

  /// Its owner's push pot, if any.
  final PushPot? pushPot;
}

/// {@template battle_state}
/// Everything a battle holds in memory (decision 3), immutable: each
/// change makes a new state that shares what did not change.
/// {@endtemplate}
final class BattleState {
  /// {@macro battle_state}
  const new({
    required this.units,
    required this.sections,
    required this.teams,
    required this.relics,
  });

  /// The units, by ID.
  final Map<String, UnitState> units;

  /// The sections, by ID.
  final Map<String, SectionState> sections;

  /// The teams, by ID, in the order of their HQ starting points.
  final Map<String, TeamState> teams;

  /// The relics, by ID.
  final Map<String, RelicState> relics;

  /// This state with [unit] in place of the unit of its ID.
  BattleState withUnit(UnitState unit) => BattleState(
    units: Map.unmodifiable({...units, unit.id: unit}),
    sections: sections,
    teams: teams,
    relics: relics,
  );

  /// This state with [section] in place of the section of its ID.
  BattleState withSection(SectionState section) => BattleState(
    units: units,
    sections: Map.unmodifiable({...sections, section.id: section}),
    teams: teams,
    relics: relics,
  );
}

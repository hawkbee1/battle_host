import 'package:battle_rules/battle_rules.dart';

/// {@template unit_setup}
/// A unit a section brings to a battle: its [id], its [type] (a key of
/// `units.yaml`), the nodes it bought ([tree]) and its [xp], all kept from
/// the battles before in the war (UNIT-30).
/// {@endtemplate}
final class UnitSetup {
  /// {@macro unit_setup}
  const new({
    required this.id,
    required this.type,
    this.tree,
    this.xp = const UnitXp(),
  });

  /// The unit.
  final String id;

  /// Its unit type.
  final String type;

  /// Its bought nodes; null when it bought none.
  final SkillTree? tree;

  /// Its XP.
  final UnitXp xp;
}

/// {@template section_setup}
/// A section in a battle: its [id], its commander's [accountId], its
/// [money], its section [xp] and its [units], kept between the battles of
/// a war (UNIT-30).
/// {@endtemplate}
final class SectionSetup {
  /// {@macro section_setup}
  const new({
    required this.id,
    required this.accountId,
    required this.units,
    this.money = 0,
    this.xp = 0,
  });

  /// The section.
  final String id;

  /// Its commander's account.
  final String accountId;

  /// Its money, in whole w€.
  final int money;

  /// Its section XP (UNIT-14).
  final double xp;

  /// Its units, the commander included.
  final List<UnitSetup> units;
}

/// {@template team_setup}
/// A team of a battle and its sections, as `create_battle` formed them
/// (SOC-20, decision 103).
/// {@endtemplate}
final class TeamSetup {
  /// {@macro team_setup}
  const new({required this.id, required this.sections});

  /// The team.
  final String id;

  /// Its sections.
  final List<SectionSetup> sections;
}

/// {@template battle_setup}
/// What a battle starts from: its [battleId], its map [mapId], the [seed]
/// of its random, its own [settings] (decision 172) and its [teams].
/// {@endtemplate}
final class BattleSetup {
  /// {@macro battle_setup}
  const new({
    required this.battleId,
    required this.mapId,
    required this.seed,
    required this.settings,
    required this.teams,
  });

  /// The battle.
  final String battleId;

  /// Its map.
  final String mapId;

  /// The seed of its random (stack decision 1).
  final int seed;

  /// Its settings, which an admin chose from `battle.yaml`.
  final BattleSettings settings;

  /// Its teams, in the order of the map's HQ starting points.
  final List<TeamSetup> teams;
}

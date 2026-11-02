import 'dart:io';

import 'package:battle_rules/battle_rules.dart';

/// The shared definitions of the plan folder [plan]
/// (`apps/battle_team/plan`), read from disk (Adapter): `data/*.yaml` and
/// `milestones/economy.yaml`, with `data/battle.yaml` as the default
/// battle settings.
GameData readPlan(String plan) {
  String read(String path) => File('$plan/$path').readAsStringSync();
  return GameData.parse(
    units: read('data/units.yaml'),
    combat: read('data/combat.yaml'),
    terrain: read('data/terrain.yaml'),
    battle: read('data/battle.yaml'),
    economy: read('milestones/economy.yaml'),
    medals: read('data/medals.yaml'),
  );
}

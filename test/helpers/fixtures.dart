import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_rules/battle_rules.dart';

/// The plan folder of the hawkbee checkout: tests read the real game data
/// from it (stack decision 7).
const planPath = '../../apps/battle_team/plan';

/// The source of `battle_map`'s test map: 12 × 8 cells, 2 or 3 teams, six
/// relics, one of them on the floating island `sky`.
const valleySource = '../battle_map/test/fixtures/valley';

/// The shared definitions of the plan.
final GameData planData = readPlan(planPath);

/// The valley map, built by `battle_map`'s builder.
final BuiltMapFiles valley = () {
  final map = MapData.fromSource(
    mapYaml: File('$valleySource/$mapFile').readAsStringSync(),
    heightsPng: File('$valleySource/heights.png').readAsBytesSync(),
    terrainPng: File('$valleySource/terrain.png').readAsBytesSync(),
    objectsYaml: File('$valleySource/$objectsFile').readAsStringSync(),
  );
  return (buildMap(map, planData) as MapBuilt).files;
}();

/// Maps in memory, counting how often each is read.
final class MemoryMapSource implements MapSource {
  new(this.maps);

  final Map<String, BuiltMapFiles> maps;
  final reads = <String, int>{};

  @override
  BuiltMapFiles read(String mapId) {
    reads[mapId] = (reads[mapId] ?? 0) + 1;
    return maps[mapId]!;
  }
}

/// Keeps the errors reported.
final class RecordingErrorReporter implements ErrorReporter {
  final reports = <(Object, String?)>[];

  @override
  Future<void> report(
    Object error,
    StackTrace stackTrace, {
    String? battleId,
  }) async => reports.add((error, battleId));
}

/// A battle of [teams] teams on the valley, each with one section: a
/// commander, a soldier and, in the first team, an evolved jeep.
BattleSetup valleySetup({
  String battleId = 'b-1',
  int teams = 2,
  BattleSettings? settings,
}) => BattleSetup(
  battleId: battleId,
  mapId: 'valley',
  seed: 7,
  settings: settings ?? planData.battle,
  teams: [
    for (var t = 1; t <= teams; t++)
      TeamSetup(
        id: 'team-$t',
        sections: [
          SectionSetup(
            id: 's-$t',
            accountId: 'a-$t',
            money: 500,
            xp: 120,
            units: [
              UnitSetup(id: 'commander-$t', type: 'commander'),
              UnitSetup(id: 'soldier-$t', type: 'soldier'),
              if (t == 1)
                UnitSetup(
                  id: 'jeep-1',
                  type: 'jeep',
                  tree: SkillTree({EvolvableStat.hp: 5}),
                  xp: const UnitXp(earned: 1600, unspent: 100),
                ),
            ],
          ),
        ],
      ),
  ],
);

/// Writes [files] into [folder] as the map builder does.
void writeBuiltMap(BuiltMapFiles files, String folder) {
  File('$folder/$mapFile')
    ..createSync(recursive: true)
    ..writeAsStringSync(files.mapYaml);
  for (final MapEntry(key: name, value: tile) in files.tiles.entries) {
    final tileFolder = '$folder/tiles/$name';
    Directory(tileFolder).createSync(recursive: true);
    File('$tileFolder/heights.png').writeAsBytesSync(tile.heightsPng);
    File('$tileFolder/terrain.png').writeAsBytesSync(tile.terrainPng);
    File('$tileFolder/$objectsFile').writeAsStringSync(tile.objectsYaml);
  }
}

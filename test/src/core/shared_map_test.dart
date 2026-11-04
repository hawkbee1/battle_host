import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_rules/battle_rules.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

void main() {
  group(MapLibrary, () {
    test('stack decision 1 two battles on one map share its copy', () {
      final source = MemoryMapSource({'valley': valley});
      final host = SimulationHost(
        clock: ManualClock(DateTime.utc(2026)),
        maps: MapLibrary(source: source, terrain: planData.terrain),
        definitions: planData,
        reporter: RecordingErrorReporter(),
      );

      final first = host.start(valleySetup());
      final second = host.start(valleySetup(battleId: 'b-2', teams: 3));

      expect(second.map, same(first.map));
      expect(source.reads, equals({'valley': 1}));
      expect(host.maps.loaded, equals(1));
    });
  });

  group(SharedMap, () {
    late SharedMap map;

    setUp(() {
      map = SharedMap.load(
        id: 'valley',
        host: HostMapLoader(planData.terrain).load(valley),
        terrain: planData.terrain,
      );
    });

    test('MAP-04 shares one grid between the searches of every movement '
        'profile', () {
      const foot = PathMover(apPerM: 1, modes: ['foot']);
      const wheeled = PathMover(apPerM: 0.1, modes: ['wheeled']);

      final search = map.searchFor(foot);

      expect(map.searchFor(foot), same(search));
      expect(map.searchFor(wheeled).grid, same(search.grid));
      expect(map.grid.searches, equals(2));
      expect(
        search.exact(const CellRef(0, 0), const CellRef(11, 0))?.cells.last,
        equals(const CellRef(11, 0)),
      );
    });

    test('MAP-21 knows the road construction of terrain.yaml', () {
      expect(map.rules.roadConstruction, equals(roadConstruction));
      expect(planData.terrain.objects, contains(roadConstruction));
    });

    test('decision 142 caps flying at the highest point of the map plus the '
        'margin of terrain.yaml', () {
      final navigation = map.host.navigation;
      final heights = [
        ...navigation.ground.map((cell) => cell.height),
        for (final island in navigation.islands.values)
          ...island.values.map((cell) => cell.height),
      ];
      final highest = heights.reduce((a, b) => a > b ? a : b);

      expect(
        map.rules.altitudeLimitM,
        equals(highest + planData.terrain.flyingMaxAboveHighestTerrainM),
      );
      expect(navigation.islands, isNotEmpty);
    });

    test('refuses terrain data without the road construction', () {
      final terrain = TerrainData.parse(
        File('$planPath/data/terrain.yaml')
            .readAsStringSync()
            .replaceFirst('$roadConstruction:', 'road_piece:'),
      );

      expect(
        () => SharedMap.load(id: 'valley', host: map.host, terrain: terrain),
        throwsArgumentError,
      );
    });
  });
}

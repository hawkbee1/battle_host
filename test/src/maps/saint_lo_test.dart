import 'package:battle_host/battle_host.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

/// The built maps of `battle_map`, among them the first map from real data.
const builtMaps = '../battle_map/maps/built';

void main() {
  group('saint_lo', () {
    late SharedMap map;

    setUpAll(() {
      map = MapLibrary(
        source: const DirectoryMapSource(builtMaps),
        terrain: planData.terrain,
      ).load('saint_lo');
    });

    test('MAP-05 the first map from real data loads in the host from its '
        'tiles', () {
      final navigation = map.host.navigation;

      expect(map.id, 'saint_lo');
      expect((navigation.width, navigation.depth), (1000, 5000));
      expect(navigation.cellSizeM, 10);
      expect(map.host.objects.length, greaterThan(200000));
      // The flying limit is above the valley's highest point.
      expect(map.rules.altitudeLimitM, greaterThan(100));
    });

    test('HQ-01 RELIC-02 a battle of five teams starts on it', () {
      final setup = valleySetup(teams: 5);
      final battle = Battle.start(
        setup: BattleSetup(
          battleId: setup.battleId,
          mapId: 'saint_lo',
          seed: setup.seed,
          settings: setup.settings,
          teams: setup.teams,
        ),
        map: map,
        definitions: planData,
      );

      expect(
        battle.state.teams.values.map((team) => team.hq.cell),
        map.host.hqStarts[5],
      );
      expect(
        battle.state.relics.values.map((relic) => relic.cell),
        map.host.relicStarts,
      );
      expect(map.host.hqStarts[5]!.first, const CellRef(499, 149));
    });
  });
}

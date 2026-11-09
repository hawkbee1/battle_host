import 'dart:typed_data';

import 'package:battle_host/battle_host.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

import 'fixtures.dart';

/// The width of [plain], in 10 m cells.
const plainWidth = 80;

/// The depth of [plain], in 10 m cells.
const plainDepth = 20;

/// The trees of [plain]'s wood: x 15 to 17, y 0 to 9.
bool inWood(int x, int y) => x >= 15 && x <= 17 && y < 10;

/// The ridge of [plain]: x 50, y 10 to 19, 20 m high, on grass.
bool onRidge(int x, int y) => x == 50 && y >= 10;

/// The height of [plain]'s ridge, in metres.
const ridgeHeightM = 20;

/// A flat grass plain of 800 × 200 m for the fog of war: a wood on its
/// north-west, a grass ridge on its south-east, a building at (60, 5).
final BuiltMapFiles plain = () {
  final heights = Uint16List(plainWidth * plainDepth);
  for (var y = 0; y < plainDepth; y++) {
    for (var x = 0; x < plainWidth; x++) {
      if (onRidge(x, y)) heights[y * plainWidth + x] = ridgeHeightM;
    }
  }
  final trees = [
    for (var y = 0; y < plainDepth; y++)
      for (var x = 0; x < plainWidth; x++)
        if (inWood(x, y)) '  - {type: tree, cells: [[$x, $y]]}',
  ];
  final map = MapData(
    spec: MapSpec.parse('''
version: 1
name: plain
cell_size_m: 10
tile_size: 40
terrain_index: [grass, forest_floor]
teams:
  2: [[0, 19], [79, 19]]
relics: [[40, 0], [42, 0], [44, 0], [46, 0], [48, 0]]
'''),
    width: plainWidth,
    depth: plainDepth,
    heights: heights,
    terrain: Uint8List.fromList([
      for (var y = 0; y < plainDepth; y++)
        for (var x = 0; x < plainWidth; x++)
          if (inWood(x, y)) 1 else 0,
    ]),
    features: MapFeatures.parse(
      [
        'objects:',
        ...trees,
        '  - {type: building, cells: [[60, 5]]}',
      ].join('\n'),
    ),
  );
  return switch (buildMap(map, planData)) {
    MapBuilt(:final files) => files,
    MapRefused(:final problems) => throw StateError(
      problems
          .map((problem) => '${problem.cell}: ${problem.message}')
          .join('\n'),
    ),
  };
}();

/// Two teams on [plain]. Team 1 has two sections: `s-1` (a commander, a
/// soldier, a scout, a radio, an artillery piece and a truck) and its ally
/// `s-3` (a soldier); team 2 has `s-2` (a commander and two soldiers).
BattleSetup plainSetup() => BattleSetup(
  battleId: 'f-1',
  mapId: 'plain',
  seed: 3,
  settings: planData.battle,
  teams: const [
    TeamSetup(
      id: 'team-1',
      sections: [
        SectionSetup(
          id: 's-1',
          accountId: 'a-1',
          units: [
            UnitSetup(id: 'commander-1', type: 'commander'),
            UnitSetup(id: 'soldier-1', type: 'soldier'),
            UnitSetup(id: 'scout-1', type: 'scout'),
            UnitSetup(id: 'radio-1', type: 'radio'),
            UnitSetup(id: 'artillery-1', type: 'artillery'),
            UnitSetup(id: 'truck-1', type: 'truck'),
          ],
        ),
        SectionSetup(
          id: 's-3',
          accountId: 'a-3',
          units: [UnitSetup(id: 'soldier-3', type: 'soldier')],
        ),
      ],
    ),
    TeamSetup(
      id: 'team-2',
      sections: [
        SectionSetup(
          id: 's-2',
          accountId: 'a-2',
          units: [
            UnitSetup(id: 'commander-2', type: 'commander'),
            UnitSetup(id: 'soldier-2', type: 'soldier'),
            UnitSetup(id: 'soldier-4', type: 'soldier'),
          ],
        ),
      ],
    ),
  ],
);

/// The units of [plainSetup] on the field at first, far apart; the
/// others stay in storage until a test places them.
const plainPlaces = {
  'commander-1': CellRef(0, 0),
  'commander-2': CellRef(79, 0),
};

/// A host running the battle of [plainSetup] on [plain], the units of
/// [plainPlaces] deployed, with its log.
final class FogFixture {
  /// A fixture whose host keeps its log in [wal], when given.
  new({MemoryWriteAheadLog? wal}) : wal = wal ?? MemoryWriteAheadLog() {
    host = hostOn(this.wal, logs, snapshots);
    battle = host.start(plainSetup());
    battle.change((state) {
      var next = state;
      for (final MapEntry(key: id, value: cell) in plainPlaces.entries) {
        next = next.withUnit(
          next.units[id]!.copyWith(location: const Deployed(), cell: cell),
        );
      }
      return next;
    });
  }

  /// A host on [plain] with the stores given and this fixture's clock.
  SimulationHost hostOn(
    WriteAheadLog wal,
    LogSink logs,
    SnapshotStore snapshots,
  ) => SimulationHost(
    clock: clock,
    maps: MapLibrary(
      source: MemoryMapSource({'plain': plain}),
      terrain: planData.terrain,
    ),
    definitions: planData,
    reporter: RecordingErrorReporter(),
    wal: wal,
    logs: logs,
    snapshots: snapshots,
    rateLimit: RateLimit(perSecond: 1000, burst: 1000),
  );

  final clock = ManualClock(DateTime.utc(2026, 11, 8, 8));
  final MemoryWriteAheadLog wal;
  final logs = MemoryLogSink();
  final snapshots = MemorySnapshotStore();
  late final SimulationHost host;
  late final Battle battle;

  /// The fog of war of the battle.
  FogOfWar get fog => battle.orders.fog;

  /// The units [section] knows.
  Set<String> units(String section) => fog.of(section).units;

  /// Puts the unit [id] on [cell], on the field.
  void place(String id, CellRef cell) => battle.change(
    (state) => state.withUnit(
      state.units[id]!.copyWith(location: const Deployed(), cell: cell),
    ),
  );

  /// Sets the weather.
  void weather(String weather) => battle.change(
    (state) => BattleState(
      victory: state.victory,
      units: state.units,
      sections: state.sections,
      teams: state.teams,
      relics: state.relics,
      delta: state.delta,
      weather: weather,
    ),
  );

  /// Sends [order] from [section], by its account.
  HandledOrder send(Order order, {String section = 's-1'}) => host.submit(
    'f-1',
    Command(
      sender: Sender(
        accountId: 'a-${section.substring(2)}',
        sectionId: section,
      ),
      sentAt: battle.time,
      order: order,
    ),
    origin: Origin.player,
  );

  /// Moves the clock by [step] and runs the host's tick.
  void wait(Duration step) {
    clock.advance(step);
    host.advance();
  }
}

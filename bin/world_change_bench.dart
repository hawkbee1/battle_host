import 'dart:math' as math;

import 'package:battle_host/battle_host.dart';
import 'package:battle_map/battle_map.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_rules/battle_rules.dart';

/// P-07 on the host (M5 Issue 14): the time to apply one world change to a
/// battle's world on a 1,000 × 5,000-cell synthetic map (10 × 50 km), its
/// long-path searches prepared. The first change copies the shared grid
/// (copy on write); the next ones only touch their cells. Prints one
/// machine-readable line.
///
/// ```sh
/// dart run bin/world_change_bench.dart [plan folder]
/// dart compile exe bin/world_change_bench.dart -o /tmp/bench && /tmp/bench
/// ```
void main(List<String> args) {
  final plan = readPlan(args.isEmpty ? '../../apps/battle_team/plan' : args[0]);
  const width = 1000;
  const depth = 5000;
  final shared = SharedMap.load(
    id: 'synthetic',
    host: HostMap(
      navigation: syntheticMap(width: width, depth: depth, seed: 1),
      objects: const {},
      hqStarts: const {},
      relicStarts: const [],
    ),
    terrain: plan.terrain,
  );
  final soldier = Mover.unit(plan.units.unitTypes['soldier']!);
  final mover = PathMover(apPerM: soldier.apPerM, modes: soldier.modes);
  final world = BattleWorld(shared);
  final warm = Stopwatch()..start();
  world.searchFor(mover).fast(const CellRef(10, 10), const CellRef(500, 2000));
  warm.stop();

  final random = math.Random(1);
  WorldChange next(int change) => switch (change % 3) {
    0 => CraterDug(
      Crater(
        centreXM: random.nextDouble() * width * 10,
        centreYM: random.nextDouble() * depth * 10,
        radiusM: 8,
        depthM: plan.terrain.craters.depthPerShotM,
      ),
    ),
    1 => ObjectBuilt(
      CellRef(random.nextInt(width), random.nextInt(depth)),
      'wall',
    ),
    _ => ConstructionBuilt(
      CellRef(random.nextInt(width), random.nextInt(depth)),
      roadConstruction,
    ),
  };
  final first = Stopwatch()..start();
  world.apply(next(0));
  first.stop();
  final times = <int>[];
  for (var change = 1; change <= 200; change++) {
    final watch = Stopwatch()..start();
    world.apply(next(change));
    watch.stop();
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  final mean = times.reduce((a, b) => a + b) / times.length;
  // ignore: avoid_print, the benchmark's output.
  print(
    'bench=host_world_change cells=${width * depth} '
    'warm_ms=${warm.elapsedMilliseconds} '
    'first_change_ms=${first.elapsedMilliseconds} changes=${times.length} '
    'mean_us=${mean.round()} p50_us=${times[times.length ~/ 2]} '
    'p95_us=${times[times.length * 95 ~/ 100]} max_us=${times.last}',
  );
}

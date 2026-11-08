import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';
import 'package:battle_host/battle_host.dart';
import 'package:battle_host/load.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// P-01, P-02 and P-03 on the host (M5 Issue 19): battles of the load
/// script on one map, in one process, over simulated time. Prints one
/// machine-readable line per measure:
///
/// - `bench=host_load`: the host's CPU per second of battle time (mean over
///   the seconds with work, p50, p99, the busiest second and when), in all
///   and per simulated day, and the orders sent and taken;
/// - `bench=host_fog`: the fog of war's CPU per one-second tick (the first
///   one, which computes every set, the mean, p50, p99, p99.9, the
///   busiest tick and the busiest after the first, and when), the sight
///   lines it checked and its CPU per simulated day (M6 Issue 3);
/// - `bench=host_memory`: the process's resident memory before the map,
///   with the map, with the battles placed, and at the end;
/// - `bench=host_log`: the log of the first battle: entries, bytes an entry,
///   uploads, their size compressed, and its snapshot's size;
/// - `bench=host_paths`: P-01 with the search data shared by every mover
///   of the map: 2 km paths and paths across the map.
///
/// ```sh
/// dart compile exe bin/load_test.dart -o /tmp/load_test
/// /tmp/load_test --maps ../battle_map/maps/built --map saint_lo
/// ```
Future<void> main(List<String> args) async {
  final options =
      (ArgParser()
            ..addOption('plan', defaultsTo: '../../apps/battle_team/plan')
            ..addOption('maps', defaultsTo: '../battle_map/maps/built')
            ..addOption('map', defaultsTo: 'saint_lo')
            ..addOption('units', defaultsTo: '1000')
            ..addOption('battles', defaultsTo: '1')
            ..addOption('hours', defaultsTo: '24')
            ..addOption('server-managed', defaultsTo: '0')
            ..addOption('seed', defaultsTo: '1')
            ..addOption('wal', help: 'A folder for file write-ahead logs.'))
          .parse(args);
  int whole(String name) => int.parse(options.option(name)!);
  final settings = LoadSettings(
    units: whole('units'),
    seed: whole('seed'),
    serverManagedShare: double.parse(options.option('server-managed')!),
    duration: Duration(hours: whole('hours')),
  );
  final mapId = options.option('map')!;
  final walFolder = options.option('wal');

  final rssStart = _rssMb();
  final plan = readPlan(options.option('plan')!);
  final maps = MapLibrary(
    source: DirectoryMapSource(options.option('maps')!),
    terrain: plan.terrain,
  );
  final mapWatch = Stopwatch()..start();
  final map = maps.load(mapId);
  mapWatch.stop();
  final rssMap = _rssMb();
  final prepareWatch = Stopwatch()..start();
  prepare(map, plan);
  prepareWatch.stop();
  final rssPrepared = _rssMb();

  final clock = ManualClock(DateTime.utc(2026, 11, 6));
  final logs = MemoryLogSink();
  final snapshots = MemorySnapshotStore();
  final host = SimulationHost(
    clock: clock,
    maps: maps,
    definitions: plan,
    reporter: _PrintReporter(),
    wal: walFolder == null ? null : FileWriteAheadLog(walFolder),
    logs: logs,
    snapshots: snapshots,
    rateLimit: RateLimit(perSecond: 1000000, burst: 1000000),
  );
  final ids = [for (var b = 1; b <= whole('battles'); b++) 'load-$b'];
  final rssBattles = <int>[];
  for (final (index, id) in ids.indexed) {
    final battleSettings = LoadSettings(
      units: settings.units,
      seed: settings.seed + index,
      serverManagedShare: settings.serverManagedShare,
      duration: settings.duration,
    );
    final battle = host.start(
      loadSetup(battleSettings, battleId: id, mapId: mapId, definitions: plan),
    );
    placeLoad(battle, battleSettings);
    host.snapshot(id);
    await host.settle();
    rssBattles.add(_rssMb());
  }

  final load = BattleLoad(
    host: host,
    clock: clock,
    battleIds: ids,
    settings: settings,
  );
  final wall = Stopwatch()..start();
  final report = await load.run();
  wall.stop();
  await host.settle();
  final rssEnd = _rssMb();

  final ticks = report.tickMicros.values.toList()..sort();
  final busiest = report.tickMicros.entries.reduce(
    (a, b) => b.value > a.value ? b : a,
  );
  final days = settings.duration.inSeconds / 86400;
  _print(
    'bench=host_load map=$mapId battles=${ids.length} '
    'units=${settings.units} server_managed=${settings.serverManagedShare} '
    'hours=${settings.duration.inHours} '
    'wal=${walFolder == null ? 'memory' : 'file'} '
    'orders=${report.orders} shots=${report.shots} moves=${report.moves} '
    'delayed=${report.delayed} '
    'refused=${_pairs(report.refused)} '
    'seconds_with_work=${ticks.length} '
    'tick_mean_us=${(report.hostMicros / ticks.length).round()} '
    'tick_p50_us=${ticks[ticks.length ~/ 2]} '
    'tick_p99_us=${ticks[ticks.length * 99 ~/ 100]} '
    'tick_max_us=${busiest.value} tick_max_at_s=${busiest.key} '
    'first_minute_ms=${_sum(report, 0, 60) ~/ 1000} '
    'host_cpu_s=${(report.hostMicros / 1e6).toStringAsFixed(1)} '
    'host_cpu_s_per_day=${(report.hostMicros / 1e6 / days).toStringAsFixed(1)} '
    'wall_s=${(wall.elapsedMilliseconds / 1000).toStringAsFixed(1)}',
  );
  final fog = report.fogMicros.values.toList()..sort();
  final fogPeak = report.fogMicros.entries.reduce(
    (a, b) => b.value > a.value ? b : a,
  );
  final fogLater = report.fogMicros.entries
      .where((tick) => tick.key > 0)
      .reduce((a, b) => b.value > a.value ? b : a);
  final fogTotal = fog.fold(0, (sum, time) => sum + time);
  _print(
    'bench=host_fog ticks=${fog.length} '
    'first_tick_us=${report.fogMicros[0]} '
    'mean_us=${(fogTotal / fog.length).round()} '
    'p50_us=${fog[fog.length ~/ 2]} p99_us=${fog[fog.length * 99 ~/ 100]} '
    'p999_us=${fog[fog.length * 999 ~/ 1000]} '
    'max_us=${fogPeak.value} max_at_s=${fogPeak.key} '
    'max_after_first_us=${fogLater.value} max_after_first_at_s=${fogLater.key} '
    'lines=${report.fogLines} '
    'cpu_s_per_day=${(fogTotal / 1e6 / days).toStringAsFixed(1)}',
  );
  _print(
    'bench=host_burst reloads=${report.reloads} '
    'busiest_second_orders=${report.sent[busiest.key] ?? 0} '
    'max_orders_in_a_second=${report.sent.values.fold(0, math.max)} '
    'first_seconds_ms_orders=${_firstSeconds(report)}',
  );
  _print(
    'bench=host_memory rss_start_mb=$rssStart rss_map_mb=$rssMap '
    'map_load_ms=${mapWatch.elapsedMilliseconds} '
    'rss_prepared_mb=$rssPrepared '
    'prepare_ms=${prepareWatch.elapsedMilliseconds} '
    'rss_after_each_battle_mb=${rssBattles.join(',')} rss_end_mb=$rssEnd',
  );

  final first = ids.first;
  final batches = logs.batchesOf(first);
  final entries = batches.fold(0, (sum, batch) => sum + batch.entries.length);
  final events = batches.fold(
    0,
    (sum, batch) =>
        sum + batch.entries.fold(0, (sum, entry) => sum + entry.events.length),
  );
  final raw = batches.fold(
    0,
    (sum, batch) =>
        sum + const BinaryProtocolCodec().encodeLog(batch.entries).length,
  );
  final sizes = [for (final batch in batches) encodeBatch(batch.entries).length]
    ..sort();
  final uploaded = sizes.fold(0, (sum, size) => sum + size);
  final snapshotRaw = encodeSnapshot(
    host[first]!.save(),
    startedAt: DateTime.utc(2026, 11, 6),
  );
  _print(
    'bench=host_log battle=$first entries=$entries events=$events '
    'bytes_per_entry=${(raw / entries).round()} log_mb=${_mb(raw)} '
    'uploads=${sizes.length} upload_bytes_mean=${uploaded ~/ sizes.length} '
    'upload_bytes_p50=${sizes[sizes.length ~/ 2]} '
    'upload_bytes_max=${sizes.last} '
    'uploaded_mb=${_mb(uploaded)} snapshot_kb=${snapshotRaw.length ~/ 1024} '
    'snapshot_gz_kb=${gzip.encode(snapshotRaw).length ~/ 1024}',
  );

  _paths(host[first]!, plan);
}

/// P-01 on the battle's world: the search data shared by its movers.
void _paths(Battle battle, GameData plan) {
  final nav = battle.world.navigation;
  final random = math.Random(1);
  bool open(CellRef cell) =>
      nav.cellAt(cell) != null &&
      !nav.isWater(cell) &&
      nav.objectsAt(cell).isEmpty;
  CellRef openCell(int y) {
    while (true) {
      final cell = CellRef(random.nextInt(nav.width), y);
      if (open(cell)) return cell;
    }
  }

  for (final type in ['soldier', 'jeep', 'tank']) {
    final unit = Mover.unit(plan.units.unitTypes[type]!);
    final search = battle.world.searchFor(
      PathMover(apPerM: unit.apPerM, modes: unit.modes),
    );
    final prepare = Stopwatch()..start();
    search.fast(openCell(2500), openCell(2600));
    prepare.stop();
    final short = <int>[];
    var found = 0;
    for (var run = 0; run < 20; run++) {
      final y = 500 + random.nextInt(nav.depth - 1000);
      final from = openCell(y);
      final watch = Stopwatch()..start();
      final path = search.fast(from, openCell(y + 200));
      watch.stop();
      short.add(watch.elapsedMilliseconds);
      if (path != null) found++;
    }
    short.sort();
    final acrossMs = <int>[];
    FoundPath? long;
    for (var run = 0; run < 3; run++) {
      final across = Stopwatch()..start();
      long = search.fast(openCell(50), openCell(nav.depth - 50));
      across.stop();
      acrossMs.add(across.elapsedMilliseconds);
    }
    _print(
      'bench=host_paths mover=$type prepare_ms=${prepare.elapsedMilliseconds} '
      'paths_2km=${short.length} found=$found '
      'p50_ms=${short[short.length ~/ 2]} '
      'max_ms=${short.last} across_ms=${acrossMs.join(',')} '
      'across_found=${long != null} rss_mb=${_rssMb()}',
    );
  }
}

int _sum(LoadReport report, int from, int to) => [
  for (var second = from; second < to; second++) report.tickMicros[second] ?? 0,
].fold(0, (sum, time) => sum + time);

String _pairs(Map<String, int> counts) =>
    counts.entries.map((count) => '${count.key}:${count.value}').join(',');

/// The host's milliseconds and the orders sent in each of the first 30
/// seconds.
String _firstSeconds(LoadReport report) => [
  for (var second = 0; second < 30; second++)
    '${(report.tickMicros[second] ?? 0) ~/ 1000}/${report.sent[second] ?? 0}',
].join(',');

int _rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(2);

// ignore: avoid_print, the benchmark's output.
void _print(String line) => print(line);

final class _PrintReporter implements ErrorReporter {
  new();

  @override
  Future<void> report(
    Object error,
    StackTrace stackTrace, {
    String? battleId,
  }) async => stderr.writeln('$battleId: $error\n$stackTrace');
}

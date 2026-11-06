import 'dart:math' as math;

import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_setup.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/core/simulation_host.dart';
import 'package:battle_host/src/core/timer_queue.dart';
import 'package:battle_host/src/orders/command_handler.dart';
import 'package:battle_host/src/ports/clock.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template load_settings}
/// The shape of a load-test battle (P-02, M5 Issue 19): [units] in two
/// teams, in sections of [sectionSize] (stack decision 3) led by their
/// commander, [machineGuns] of each section's soldiers with a machine gun
/// and the others with their rifle. The teams stand in two lines [gapM]
/// apart across the middle of the map. A [burstShare] of the units open
/// fire together at the start (stack decision 1, bursts). The last
/// [serverManagedShare] of each team's sections are run by the server
/// (AI-06). The script runs for [duration] from the [seed].
/// {@endtemplate}
final class LoadSettings {
  /// {@macro load_settings}
  const new({
    this.units = 1000,
    this.sectionSize = 16,
    this.machineGuns = 2,
    this.gapM = 100,
    this.burstShare = 0.4,
    this.serverManagedShare = 0,
    this.seed = 1,
    this.duration = const Duration(days: 1),
  });

  /// The units of the battle, commanders included.
  final int units;

  /// The units of a full section.
  final int sectionSize;

  /// The soldiers of a section that carry a machine gun.
  final int machineGuns;

  /// The distance between the two lines, in metres.
  final double gapM;

  /// The share of units that open fire together at the start.
  final double burstShare;

  /// The share of each team's sections the server runs.
  final double serverManagedShare;

  /// The seed of the battle and of the script.
  final int seed;

  /// The battle time the script runs for.
  final Duration duration;
}

/// The two teams of a load-test battle.
const loadTeams = ['team-1', 'team-2'];

/// The setup of the load-test battle [battleId] on [mapId]: two teams of
/// sections of [LoadSettings.sectionSize] units, the last one smaller to
/// reach [LoadSettings.units]. Each section has its own account, so its
/// orders are its player's.
BattleSetup loadSetup(
  LoadSettings settings, {
  required String battleId,
  required String mapId,
  required GameData definitions,
}) {
  final perTeam = [settings.units ~/ 2, settings.units - settings.units ~/ 2];
  return BattleSetup(
    battleId: battleId,
    mapId: mapId,
    seed: settings.seed,
    settings: definitions.battle,
    teams: [
      for (final (team, units) in perTeam.indexed)
        _teamSetup(settings, loadTeams[team], units),
    ],
  );
}

TeamSetup _teamSetup(LoadSettings settings, String team, int units) {
  final count = (units / settings.sectionSize).ceil();
  final managed = (count * settings.serverManagedShare).round();
  return TeamSetup(
    id: team,
    sections: [
      for (var section = 0; section < count; section++)
        _sectionSetup(
          settings,
          id: '$team-s${section + 1}',
          units: math.min(
            settings.sectionSize,
            units - section * settings.sectionSize,
          ),
          serverManaged: section >= count - managed,
        ),
    ],
  );
}

SectionSetup _sectionSetup(
  LoadSettings settings, {
  required String id,
  required int units,
  required bool serverManaged,
}) => SectionSetup(
  id: id,
  accountId: 'account-$id',
  serverManaged: serverManaged,
  units: [
    for (var unit = 0; unit < units; unit++)
      UnitSetup(
        id: '$id-u${unit + 1}',
        type: unit == 0 ? 'commander' : 'soldier',
        weapon: unit > 0 && unit <= settings.machineGuns ? 'machine_gun' : null,
      ),
  ],
);

/// Puts every unit of [battle], set up by [loadSetup], on the field by
/// hand, as a battle long under way would have them: `team-1` in a line
/// facing `team-2`, [LoadSettings.gapM] apart across the middle row of the
/// map, each section in a block of cells a cell apart. A unit goes to the
/// nearest free cell of open ground (no water, no object) to its place.
void placeLoad(Battle battle, LoadSettings settings) {
  final nav = battle.world.navigation;
  final gap = (settings.gapM / nav.cellSizeM).round();
  final middle = nav.depth ~/ 2;
  final taken = <CellRef>{};
  battle.change((state) {
    var next = state;
    for (final (index, team) in loadTeams.indexed) {
      final sections = [
        for (final section in state.sections.values)
          if (section.team == team) section.id,
      ];
      final away = index == 0 ? -1 : 1;
      final frontY = middle + away * (gap ~/ 2 + gap % 2 * index);
      final side = math.sqrt(settings.sectionSize).ceil();
      final width = sections.length * (side * 2 + 2);
      for (final (column, sectionId) in sections.indexed) {
        final units = [
          for (final unit in state.units.values)
            if (unit.sectionId == sectionId) unit,
        ];
        for (final (place, unit) in units.indexed) {
          final want = CellRef(
            nav.width ~/ 2 -
                width ~/ 2 +
                column * (side * 2 + 2) +
                place % side * 2,
            frontY + away * (place ~/ side) * 2,
          );
          final cell = _freeNear(nav, want, taken);
          taken.add(cell);
          next = next.withUnit(
            unit.copyWith(location: const Deployed(), cell: cell),
          );
        }
      }
    }
    return next;
  });
}

CellRef _freeNear(NavigationMap nav, CellRef want, Set<CellRef> taken) {
  for (var radius = 0; ; radius++) {
    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        if (math.max(dx.abs(), dy.abs()) != radius) continue;
        final cell = CellRef(want.x + dx, want.y + dy);
        if (_open(nav, cell) && !taken.contains(cell)) return cell;
      }
    }
  }
}

bool _open(NavigationMap nav, CellRef cell) =>
    nav.cellAt(cell) != null &&
    !nav.isWater(cell) &&
    nav.objectsAt(cell).isEmpty;

/// What the script wants a unit to do next.
enum _Goal { fire, burst, move }

/// {@template load_report}
/// What a load-test run did: the orders it sent and how the host took
/// them, and the time the host spent ([hostMicros], each one-second tick
/// of battle time with any work in [tickMicros]).
/// {@endtemplate}
final class LoadReport {
  /// {@macro load_report}
  const new({
    required this.orders,
    required this.shots,
    required this.moves,
    required this.reloads,
    required this.sent,
    required this.delayed,
    required this.refused,
    required this.tickMicros,
  });

  /// The orders sent.
  final int orders;

  /// The `Fire` orders sent.
  final int shots;

  /// The `Move` orders sent.
  final int moves;

  /// The `Reload` orders sent, once a magazine is empty.
  final int reloads;

  /// The orders sent in each second of battle time that had any, by
  /// second.
  final Map<int, int> sent;

  /// The orders that waited before they were carried out.
  final int delayed;

  /// The orders refused, by the code of their reason.
  final Map<String, int> refused;

  /// The time the host spent in each second of battle time that had any
  /// work, by second, in microseconds.
  final Map<int, int> tickMicros;

  /// The time the host spent in all, in microseconds.
  int get hostMicros => tickMicros.values.fold(0, (sum, time) => sum + time);
}

/// {@template battle_load}
/// The load script of one battle (P-02, M5 Issue 19), in the manner of the
/// scenario harness of M4 Issue 11 (seeded, timed orders, one summary) at
/// the scale of a whole battle. Its units play the AP budget of stack
/// decision 1: half their orders are shots at the nearest enemy they can
/// see, half are 10 m moves towards the enemy line, each sent once the unit
/// has the AP for it; the [LoadSettings.burstShare] of them first spend
/// their whole pool on shots. Sections the server runs get no order from
/// the script: their fire checks give theirs (AI-07).
///
/// Every order goes through [SimulationHost.submit], as a player's would.
/// The host's time, in `submit` and `advance` only, is measured per second
/// of battle time; the script's own choices are not.
/// {@endtemplate}
final class BattleLoad {
  /// {@macro battle_load}
  new({
    required this.host,
    required this.clock,
    required this.battleIds,
    required this.settings,
  }) : _random = XorshiftRandom(settings.seed),
       _start = clock.now();

  /// The host running the battles.
  final SimulationHost host;

  /// Its clock, which the script moves.
  final ManualClock clock;

  /// The battles the script plays, started and placed.
  final List<String> battleIds;

  /// The shape of the battles.
  final LoadSettings settings;

  final XorshiftRandom _random;
  final DateTime _start;
  final _due = TimerQueue<(String, String)>();
  final _goals = <(String, String), _Goal>{};
  final _ticks = <int, int>{};
  var _orders = 0;
  var _shots = 0;
  var _moves = 0;
  var _reloads = 0;
  final _sent = <int, int>{};
  var _delayed = 0;
  final _refused = <String, int>{};

  /// Runs the script for [LoadSettings.duration]: the host advances every
  /// second, and each unit acts when it is due. It lets the uploads under
  /// way go on every 10 seconds of battle time, as a running host would.
  Future<LoadReport> run() async {
    _plan();
    final end = settings.duration;
    var second = Duration.zero;
    while (true) {
      final due = _due.nextAt;
      final next = due != null && due < second ? due : second;
      if (next > end) break;
      clock.advance(_start.add(next).difference(clock.now()));
      if (next == second) {
        _timed(next, host.advance);
        second += const Duration(seconds: 1);
        if (second.inSeconds % 10 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      for (var due = _due.popDue(next); due != null; due = _due.popDue(next)) {
        _act(due.$2, next);
      }
    }
    return LoadReport(
      orders: _orders,
      shots: _shots,
      moves: _moves,
      reloads: _reloads,
      sent: Map.unmodifiable(_sent),
      delayed: _delayed,
      refused: Map.unmodifiable(_refused),
      tickMicros: Map.unmodifiable(_ticks),
    );
  }

  T _timed<T>(Duration at, T Function() work) {
    final watch = Stopwatch()..start();
    final result = work();
    watch.stop();
    _ticks.update(
      at.inSeconds,
      (time) => time + watch.elapsedMicroseconds,
      ifAbsent: () => watch.elapsedMicroseconds,
    );
    return result;
  }

  void _plan() {
    for (final battleId in battleIds) {
      final state = host[battleId]?.state;
      if (state == null) continue;
      final units = [
        for (final unit in state.units.values)
          if (!state.sections[unit.sectionId]!.serverManaged) unit.id,
      ];
      final burst = (units.length * settings.burstShare).round();
      final order = [...units];
      for (var index = order.length - 1; index > 0; index--) {
        final other = (_random.nextDouble() * (index + 1)).floor();
        final swapped = order[index];
        order[index] = order[other];
        order[other] = swapped;
      }
      for (final (index, unitId) in order.indexed) {
        final key = (battleId, unitId);
        if (index < burst) {
          _goals[key] = _Goal.burst;
          _due.schedule(_seconds(_random.nextDouble() * 5), key);
        } else {
          _goals[key] = _coin();
          _due.schedule(_seconds(_random.nextDouble() * 3600), key);
        }
      }
    }
  }

  _Goal _coin() => _random.nextDouble() < 0.5 ? _Goal.fire : _Goal.move;

  static Duration _seconds(double seconds) =>
      Duration(microseconds: (seconds * 1e6).round());

  void _act((String, String) key, Duration now) {
    final (battleId, unitId) = key;
    final battle = host[battleId];
    final unit = battle?.state.units[unitId];
    if (battle == null || unit == null || unit.location is! Deployed) return;
    if (battle.state.ended) return;
    final goal = _goals[key]!;
    final ap = battle.apOf(unitId);
    final target = goal == _Goal.move ? null : _target(battle, unit);
    final weapon = unit.weapon;
    final Order? order = target == null
        ? _step(battle, unit)
        : weapon.rounds == 0
        ? Reload(unitId: unitId)
        : Fire(unitId: unitId, targetId: target);
    final need = switch (order) {
      Fire() => weapon.weapon!.apPerShot,
      Move() => unit.type.stats.apPerM * battle.world.navigation.cellSizeM,
      _ => 0.0,
    };
    if (ap < need) {
      final hours = (need - ap) / battle.settings.ap.recoveryPerHour;
      _due.schedule(now + _seconds(hours * 3600 + 1), key);
      return;
    }
    if (order == null) {
      _goals[key] = _coin();
      _due.schedule(now + const Duration(minutes: 10), key);
      return;
    }
    final section = battle.state.sections[unit.sectionId]!;
    final handled = _timed(
      now,
      () => host.submit(
        battleId,
        Command(
          sender: Sender(accountId: section.accountId, sectionId: section.id),
          sentAt: now,
          order: order,
        ),
        origin: Origin.player,
      ),
    );
    _orders++;
    _sent.update(now.inSeconds, (count) => count + 1, ifAbsent: () => 1);
    switch (order) {
      case Fire():
        _shots++;
      case Move():
        _moves++;
      default:
        _reloads++;
    }
    _next(key, battle, handled, now, goal);
  }

  void _next(
    (String, String) key,
    Battle battle,
    HandledOrder handled,
    Duration now,
    _Goal goal,
  ) {
    final waits = handled.events.whereType<OrderDelayed>().firstOrNull;
    if (handled.refusal case final refusal?) {
      _refused.update(refusal.code, (count) => count + 1, ifAbsent: () => 1);
      _goals[key] = _Goal.move;
      _due.schedule(now + const Duration(minutes: 10), key);
      return;
    }
    if (waits != null) _delayed++;
    final unit = battle.state.units[key.$2];
    var busy = waits?.until ?? now;
    for (final until in [unit?.weapon.nextShotAt, unit?.movingUntil]) {
      if (until != null && until > busy) busy = until;
    }
    if (goal != _Goal.burst || battle.apOf(key.$2) < 1) {
      _goals[key] = _coin();
    }
    _due.schedule(
      busy > now ? busy : now + const Duration(milliseconds: 1),
      key,
    );
  }

  /// The nearest enemy [unit] can fire at: among the ten nearest within
  /// its weapon's range, the first its shot reaches.
  String? _target(Battle battle, UnitState unit) {
    final range = unit.weapon.weapon?.rangeM;
    if (range == null) return null;
    final state = battle.state;
    final world = battle.orders.world;
    final team = state.sections[unit.sectionId]!.team;
    final near =
        <(double, String)>[
            for (final other in state.units.values)
              if (other.location is Deployed &&
                  state.sections[other.sectionId]!.team != team)
                (world.distanceM(unit.cell!, other.cell!), other.id),
          ]
          ..removeWhere((pair) => pair.$1 > range)
          ..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, id) in near.take(10)) {
      if (battle.orders.shotDistance(unit, id) != null) return id;
    }
    return null;
  }

  /// A move of one cell towards the enemy line, to open ground; null when
  /// none is open.
  Move? _step(Battle battle, UnitState unit) {
    final nav = battle.world.navigation;
    final team = battle.state.sections[unit.sectionId]!.team;
    final ahead = team == loadTeams.first ? 1 : -1;
    final cell = unit.cell!;
    for (final dx in const [0, -1, 1]) {
      final to = CellRef(cell.x + dx, cell.y + ahead);
      if (_open(nav, to)) {
        final point = battle.orders.world.pointOf(to);
        return Move(
          unitId: unit.id,
          to: Position.metres(point.x, point.y, point.z),
        );
      }
    }
    return null;
  }
}

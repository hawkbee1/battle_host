import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/orders/command_handler.dart';
import 'package:battle_host/src/orders/rewards.dart';
import 'package:battle_host/src/orders/world.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' hide PathSample;
import 'package:battle_pathfinding/battle_pathfinding.dart'
    as nav
    show PathSample;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template relics}
/// Relics and the end of a battle (M5 Issue 13): pushes along their path
/// with crushing and falls (RELIC-22, RELIC-24, RELIC-25), capture timers
/// and captures lost (RELIC-05, RELIC-08), owner changes and their alerts,
/// the victory hold, eliminations and the battle's end (RELIC-10 to
/// RELIC-18, HQ-18 to HQ-20, HQ-45), and what a destroyed reinforced
/// bridge loses (RELIC-26, HQ-23).
///
/// A listener (Observer): it starts a push when a contribution gives it
/// enough pushers, starts a capture timer when a pot fills, loses a
/// capture an enemy entered, and eliminates a team whose HQ was destroyed.
///
/// A pushed relic stands where its push stops from the moment it starts,
/// like a unit's move: whoever stands on its path then is crushed when it
/// arrives (lazy state, stack decision 1).
/// {@endtemplate}
final class Relics implements BattleListener {
  /// {@macro relics}
  new({required this.battle, required this.world, required this.orders})
    : _victory = VictoryRules(battle.settings.victory),
      _capture = CaptureRules(battle.settings.capture),
      _storage = StorageRules(
        battle: battle.settings,
        morale: battle.definitions.combat.morale,
      ),
      _pushing = PushingRules(
        push: battle.definitions.combat.push,
        cost: MovementCost(battle.definitions.terrain),
      );

  /// The battle.
  final Battle battle;

  /// Its world geometry.
  final World world;

  /// Its command handler, which kills units.
  final CommandHandler orders;

  final VictoryRules _victory;
  final CaptureRules _capture;
  final StorageRules _storage;
  final PushingRules _pushing;

  BattleState get _state => battle.state;
  Duration get _now => battle.time;

  void _putRelic(RelicState relic) =>
      battle.change((state) => state.withRelic(relic));

  String _teamOf(UnitState unit) => _state.sections[unit.sectionId]!.team;

  @override
  List<BattleEvent> hear(List<BattleEvent> events, BattleState before) {
    if (_state.ended) return const [];
    final more = <BattleEvent>[];
    for (final event in events) {
      switch (event) {
        case AddedToPush(:final relicId, :final unitId):
          final relic = _state.relics[relicId]!;
          _putRelic(relic.copyWith(pushers: {...relic.pushers, unitId}));
          more.addAll(_startPush(relicId));
        case AddedToCapture(:final relicId, :final capturedAt?)
            when before.relics[relicId]!.capturePot?.fullAt == null:
          battle.schedule(capturedAt, CaptureEnds(relicId));
        case Attacked(:final impacts):
          for (final impact in impacts) {
            if (impact.targetType == 'hq' &&
                impact.result == ImpactResult.killed) {
              more.addAll(
                _eliminate(
                  impact.targetId.substring(3),
                  EliminationCause.hqDestroyed,
                ),
              );
            }
          }
        case _:
          break;
      }
    }
    return [...more, ..._capturesLost()];
  }

  // Pushes (RELIC-22, RELIC-24, RELIC-25, RELIC-28).

  List<BattleEvent> _startPush(String relicId) {
    final relic = _state.relics[relicId]!;
    final path = relic.pushPath;
    final pot = relic.pushPot;
    if (relic.push != null || path == null || pot == null || pot.ap == 0) {
      return const [];
    }
    final mover = Mover.relic(battle.definitions.combat.push);
    final pathMover = PathMover(apPerM: mover.apPerM, modes: mover.modes);
    final checked = battle.world.paths.check(mover: pathMover, path: path);
    // RELIC-28: a relic with no path stays stuck.
    if (checked is! PathPasses) return const [];
    final landing = checked.falls.firstOrNull;
    final end = landing == null ? path.length - 1 : path.indexOf(landing);
    final along = orders.alongOf(pathMover, path.sublist(0, end + 1));
    final samples = _samples(checked.samples);
    // A unit is met where the relic enters its cell.
    final inPath = <(String, int)>[
      for (var i = 1; i <= end; i++)
        if (path[i] != landing)
          for (final unit in _state.units.values)
            if (unit.onField && unit.cell == path[i]) (unit.id, i),
    ];
    final pushers = relic.pushers
        .where((id) => _state.units[id]?.onField ?? false)
        .length;
    final full = _pushing.move(
      pot: pot,
      pushers: pushers,
      path: _upTo(samples, along[end]),
      start: _now,
      unitsInPathAtM: [for (final (_, i) in inPath) along[i - 1]],
    );
    // RELIC-24: a fall is free, but it still needs its pushers.
    if (full.stop == PushStop.tooFewPushers) return const [];
    // The relic stops on the last cell it reaches.
    var reached = 0;
    while (reached < end && along[reached + 1] <= full.distanceM + 1e-9) {
      reached++;
    }
    if (reached == 0) return const [];
    final met = [
      for (final entry in inPath)
        if (entry.$2 <= reached) entry,
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    final move = _pushing.move(
      pot: pot,
      pushers: pushers,
      path: _upTo(samples, along[reached]),
      start: _now,
      unitsInPathAtM: [for (final (_, i) in met) along[i - 1]],
    );
    final push = RelicPush(
      cell: path[reached],
      reached: reached,
      endsAt: move.endsAt,
      pot: move.pot,
      crushed: [for (final (id, _) in met.take(move.crushed)) id],
      landing: reached == end ? landing : null,
    );
    _putRelic(relic.copyWith(cell: push.cell, push: () => push));
    battle.schedule(push.endsAt, RelicArrives(relicId));
    return [MoveStarted(moverId: relicId, arrivesAt: push.endsAt)];
  }

  /// The samples of the first [metres] of a path.
  static List<PathSample> _upTo(List<PathSample> samples, double metres) {
    final kept = <PathSample>[];
    var along = 0.0;
    for (final sample in samples) {
      if (along >= metres - 1e-9) break;
      kept.add(sample);
      along += sample.lengthM;
    }
    return kept;
  }

  List<PathSample> _samples(Iterable<nav.PathSample> samples) => [
    for (final sample in samples)
      PathSample(
        terrainType: sample.terrainType,
        slopeDegrees: sample.slopeDegrees,
        lengthM: sample.lengthM,
      ),
  ];

  /// Ends the push of [relicId] due now: the units in its way are crushed
  /// and, after a fall, those under it (decision 138); a fall empties its
  /// pot (decision 176). It goes on while its pot and path allow.
  List<BattleEvent> finishPush(String relicId) {
    final relic = _state.relics[relicId];
    final push = relic?.push;
    if (relic == null || push == null || push.endsAt != _now) {
      return const [];
    }
    final events = <BattleEvent>[];
    final landing = push.landing;
    final victims = [
      ...push.crushed,
      if (landing != null)
        for (final unit in _state.units.values)
          if (unit.onField && unit.cell == landing) unit.id,
    ];
    for (final id in victims) {
      events.addAll(orders.crush(id, by: relicId));
    }
    final pot = landing == null ? push.pot : push.pot.fallen();
    final rest = relic.pushPath!.sublist(push.reached);
    final moving = pot.ap > 0 && landing == null && rest.length > 1;
    _putRelic(
      _state.relics[relicId]!.copyWith(
        pushPot: () => pot,
        pushPath: () => moving ? rest : null,
        pushers: pot.ap > 0 ? null : const {},
        push: () => null,
      ),
    );
    return [...events, ..._startPush(relicId)];
  }

  // Captures (RELIC-05, RELIC-08, RELIC-10 to RELIC-12).

  /// RELIC-08: an enemy of the capturing team inside the radius loses its
  /// capture and its pot.
  List<BattleEvent> _capturesLost() {
    final radius = battle.settings.capture.radiusM;
    final lost = <BattleEvent>[];
    for (final relic in _state.relics.values) {
      final pot = relic.capturePot;
      if (pot == null || !pot.isUnderWay) continue;
      final enemy = _state.units.values.any(
        (unit) =>
            unit.onField &&
            _teamOf(unit) != pot.team &&
            unit.cell!.surface == relic.cell.surface &&
            world.distanceM(unit.cell!, relic.cell) <= radius,
      );
      if (!enemy) continue;
      _putRelic(relic.copyWith(capturePot: () => null));
      lost.add(CaptureLost(relicId: relic.id, team: pot.team));
    }
    return lost;
  }

  /// Ends the capture of [relicId] due now: its team owns it (RELIC-11).
  /// It empties the push pot of the previous owner (decision 176).
  List<BattleEvent> finishCapture(String relicId) {
    final relic = _state.relics[relicId];
    final pot = relic?.capturePot;
    if (relic == null ||
        pot == null ||
        _state.ended ||
        _capture.capturedAt(pot) != _now) {
      return const [];
    }
    // Its owner never captures it (`already_owned`): another team's
    // capture empties the push pot and stops any push.
    final team = pot.team;
    _putRelic(
      relic.copyWith(
        owner: team,
        capturePot: () => null,
        pushPot: () => relic.pushPot?.capturedBy(team),
        pushPath: () => null,
        pushers: const {},
        push: () => null,
      ),
    );
    return _apply(
      _victory.captured(
        _state.victory!,
        relicId: relicId,
        team: team,
        at: _now,
      ),
    );
  }

  // Eliminations and lost bridges (HQ-18 to HQ-20, HQ-23, RELIC-26).

  List<BattleEvent> _eliminate(String team, EliminationCause cause) {
    if (!_state.victory!.teams.contains(team)) return const [];
    return _apply(
      _victory.hqLost(_state.victory!, team: team, cause: cause, at: _now),
    );
  }

  /// A reinforced bridge on [cells] was destroyed: a relic on it leaves the
  /// battle, and an HQ on it is lost with its team (decision 116).
  List<BattleEvent> bridgeDestroyed(List<CellRef> cells) {
    if (_state.ended) return const [];
    final events = <BattleEvent>[];
    for (final relic in _state.relics.values.toList()) {
      if (!cells.contains(relic.cell)) continue;
      battle.change((state) => state.withoutRelic(relic.id));
      events.addAll(
        _apply(
          _victory.relicLost(_state.victory!, relicId: relic.id, at: _now),
        ),
      );
    }
    for (final team in _state.teams.values) {
      if (!team.eliminated && cells.contains(team.hq.cell)) {
        events.addAll(_eliminate(team.id, EliminationCause.hqLostWithBridge));
      }
    }
    return events;
  }

  // Victory (RELIC-14 to RELIC-18, HQ-45, UNIT-11).

  /// Checks the hold due now: its team wins (RELIC-14).
  List<BattleEvent> holdDue() =>
      _state.ended ? const [] : _apply(_victory.at(_state.victory!, _now));

  /// Applies [update]: its events become the battle's, a hold schedules
  /// its end, an eliminated team's units are stored (HQ-20, decision
  /// 208), and a win ends the battle.
  List<BattleEvent> _apply(VictoryUpdate update) {
    final eliminated = [..._state.eliminated];
    final events = <BattleEvent>[];
    battle.change((state) => state.withVictory(update.state));
    for (final event in update.events) {
      switch (event) {
        case RelicOwnerChanged(
          :final relicId,
          :final team,
          :final previousOwner,
        ):
          events.add(
            RelicCaptured(
              relicId: relicId,
              team: team,
              previousOwner: previousOwner,
            ),
          );
        case RelicLeftBattle(:final relicId, :final previousOwner):
          events.add(RelicLost(relicId: relicId, previousOwner: previousOwner));
        case HoldStarted(:final hold):
          battle.schedule(hold.winsAt, const HoldEnds());
          events.add(VictoryHoldStarted(team: hold.team, winsAt: hold.winsAt));
        case HoldReset(:final team):
          events.add(VictoryHoldReset(team: team));
        case TeamEliminated(:final team, :final cause):
          eliminated.add(team);
          events
            ..add(
              Eliminated(
                team: team,
                loss: switch (cause) {
                  EliminationCause.hqDestroyed => HqLoss.destroyed,
                  EliminationCause.hqLostWithBridge => HqLoss.lostWithBridge,
                },
              ),
            )
            ..addAll(_storeTeam(team));
        case BattleWon(:final team, :final kind):
          events.add(
            BattleEnded(
              winner: team,
              kind: switch (kind) {
                VictoryKind.lastHq => WinKind.lastHq,
                VictoryKind.relics => WinKind.relics,
              },
              eliminated: List.unmodifiable(eliminated),
            ),
          );
      }
    }
    battle.change(
      (state) => state.withVictory(state.victory!, eliminated: eliminated),
    );
    return events;
  }

  List<BattleEvent> _storeTeam(String team) {
    battle.change((state) => state.withTeam(state.teams[team]!.out));
    final events = <BattleEvent>[];
    for (final unit in _state.units.values.toList()) {
      if (_teamOf(unit) != team || !unit.onField) continue;
      battle.change(
        (state) => state.withUnit(
          unit.copyWith(
            location: _storage.atElimination(unit.location),
            flying: false,
            clearCell: true,
            clearMove: true,
            clearWork: true,
            clearObservation: true,
          ),
        ),
      );
      events.add(UnitStored(unitId: unit.id));
    }
    return events;
  }
}

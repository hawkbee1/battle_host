import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/orders/order_chain.dart';
import 'package:battle_host/src/orders/refusal.dart';
import 'package:battle_host/src/orders/world.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' hide PathSample;
import 'package:battle_pathfinding/battle_pathfinding.dart'
    as nav
    show PathSample;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// The ID of [team]'s HQ as a target or a mover.
String hqId(String team) => 'hq-$team';

/// The category of a guild camp, which never reaches a floating island
/// (MAP-38, decision 88).
const _encampment = 'encampment';

/// The category of a section's commander (UNIT-24).
const _commander = 'commander';

/// A route: its cells, and its samples priced by the movement cost.
typedef _Route = ({List<CellRef> cells, List<PathSample> samples});

/// The host's own reasons to refuse an order, beside those of the rules
/// core.
enum HostRule {
  /// The position or cell is off the map.
  offMap,

  /// No path reaches the goal.
  noPath,

  /// The client's path does not start where the mover stands.
  pathNotFromMover,

  /// A carried unit does not move on its own.
  carried,

  /// Its loaded weapon forbids moving (`move_while_loaded`).
  weaponLoaded,

  /// A scout cannot move while it observes (UNIT-34).
  observing,

  /// The battle has no such target.
  unknownTarget,

  /// The target is out of the weapon's range.
  outOfRange,

  /// The unit does not see its target itself (COMBAT-11).
  targetNotSeen,

  /// The weapon cannot hit a flying target (COMBAT-25).
  cannotHitFlying,

  /// The weapon does not fire at a position (COMBAT-12, COMBAT-55).
  notIndirect,

  /// Nobody of the section sees the position and no scout reports it
  /// through a radio (COMBAT-12).
  positionNotSeen,

  /// The weapon is not aimed in first person (decision 183).
  notAimed,

  /// The battle has no such dropped weapon.
  unknownDropped,

  /// The unit is not where the weapon lies (COMBAT-30).
  notOnTheSpot,

  /// The unit cannot fly.
  cannotFly,

  /// It is not flying.
  notFlying,

  /// It is flying already.
  alreadyFlying,

  /// The target is not a transport.
  notATransport,

  /// The unit cannot be carried (UNIT-36: radios).
  notTransportable,

  /// The unit weighs more than the transport takes per unit (UNIT-37).
  tooHeavy,

  /// The transport carries all the weight it can (UNIT-37).
  transportFull,

  /// The unit is not carried.
  notCarried,

  /// The transport is flying.
  transportFlying,

  /// The target is further than the unit reaches.
  tooFar,

  /// An encampment never goes onto a floating island (MAP-38).
  islandUnreachable,

  /// No interrupted build or repair has that ID.
  unknownWork,

  /// The battle has no such relic.
  unknownRelic,

  /// The team owns the relic already.
  alreadyOwned,

  /// The order belongs to a later part of the host (storage, purchases,
  /// prisoners, delegation).
  notAvailableYet,
}

/// {@template command_handler}
/// The command handler of one battle: every order of every sender goes
/// through it (AI-03, AI-09). It runs the chain of checks (sender, right to
/// act, rules, AP), then carries out the order with the rules core and
/// gives its events. An order that waits for AP is checked again at the
/// end of its wait, on the state of that time (deferred from M4.11). No
/// order, no action (AI-01): nothing here acts on its own.
/// {@endtemplate}
final class CommandHandler {
  /// {@macro command_handler}
  new(this.battle)
    : _combat = battle.definitions.combat,
      _terrain = battle.definitions.terrain,
      world = World(map: battle.map, terrain: battle.definitions.terrain);

  /// The battle.
  final Battle battle;

  /// Its world geometry.
  final World world;

  final CombatData _combat;
  final TerrainData _terrain;

  late final _chain = <OrderCheck>[
    const SenderCheck(),
    const RightCheck(),
    RulesCheck(_plan),
    const ApCheck(),
  ];
  late final _armory = Armory(_combat);
  late final _hitChance = HitChance(_combat);
  late final _damage = Damage(_combat);
  late final _zeroHp = ZeroHp(rules: _combat.zeroHp, morale: _combat.morale);
  late final _vision = Vision(_terrain);
  late final _roleActions = RoleActionRules(combat: _combat, terrain: _terrain);
  late final _capture = CaptureRules(battle.settings.capture);
  late final _cost = MovementCost(_terrain);
  late final _pushing = PushingRules(push: _combat.push, cost: _cost);
  late final _firstPerson = FirstPersonShots(_combat);
  late final _levels = SectionLevel(battle.definitions.units.progression);
  late final _teams = TeamRules(
    battle: battle.settings,
    medals: battle.definitions.medals,
  );

  BattleState get _state => battle.state;
  Duration get _now => battle.time;

  /// Carries out [command], stamped with its sequence number, at the
  /// battle's time.
  HandledOrder handle(Command command) {
    final context = OrderCheckContext(command: command, state: _state);
    for (final link in _chain) {
      final refusal = link.check(context);
      if (refusal != null) {
        return HandledOrder(
          refusal: refusal,
          events: [OrderRefused(seq: command.seq!, reason: refusal.code)],
        );
      }
    }
    // The rules and AP links stop every refused plan.
    final plan = context.plan!;
    if (plan case PlanWaits(:final until)) {
      battle.schedule(until, RunOrder(command));
      return HandledOrder(
        events: [OrderDelayed(seq: command.seq!, until: until)],
      );
    }
    return HandledOrder(events: (plan as PlanReady).apply());
  }

  OrderPlan _plan(OrderCheckContext context) {
    final command = context.command;
    final seq = command.seq!;
    return switch (command.order) {
      Move(:final to, :final path) => _move(context.unit!, to, path),
      Fire(:final targetId) => _fire(context.unit!, targetId, seq),
      FireAtPosition(:final target) => _fireAt(context.unit!, target, seq),
      FireAimed(:final aim) => _fireAimed(context.unit!, aim, seq),
      Reload() => _reload(context.unit!, unload: false),
      UnloadWeapon() => _reload(context.unit!, unload: true),
      SwapWeapon(:final weapon) => _swap(context.unit!, weapon),
      PickUpWeapon(:final droppedId) => _pickUp(context.unit!, droppedId, seq),
      Land() => _flight(context.unit!, flying: false),
      TakeOff() => _flight(context.unit!, flying: true),
      Embark(:final transportId) => _embark(context.unit!, transportId),
      Disembark() => _disembark(context.unit!),
      Build(:final structure, :final cells) => _build(
        context.unit!,
        structure,
        cells,
      ),
      Repair(:final targetId) => _repair(context.unit!, targetId),
      Resume(:final workId) => _resume(context.unit!, workId),
      Heal(:final targetId) => _heal(context.unit!, targetId),
      Observe() => _observe(context.unit!),
      Capture(:final relicId) => _captureOrder(context.unit!, relicId),
      Push(:final relicId, :final path) => _push(context.unit!, relicId, path),
      MoveHq(:final to, :final path) => _moveHq(context.section!, to, path),
      EnterBattle() => _enter(context.section!),
      // Storage, purchases, transfers, offers and delegation.
      _ => _rule(HostRule.notAvailableYet),
    };
  }

  // Helpers.

  static OrderPlan _rule(Enum reason) => PlanRefused(RuleRefused(reason));

  static OrderPlan _refusedFor(Enum reason) => reason.name == 'costAboveApMax'
      ? const PlanRefused(ApRefused())
      : _rule(reason);

  OrderPlan _when(Duration at, List<BattleEvent> Function() apply) =>
      at > _now ? PlanWaits(at) : PlanReady(apply);

  String _teamOf(UnitState unit) => _state.sections[unit.sectionId]!.team;

  void _put(UnitState unit) => battle.change((state) => state.withUnit(unit));

  Position _positionOf(CellRef cell, {bool flying = false}) {
    final point = world.pointOf(cell, flying: flying);
    return Position.metres(point.x, point.y, point.z);
  }

  bool _within(UnitState unit, CellRef other, double metres) =>
      unit.cell!.surface == other.surface &&
      world.distanceM(unit.cell!, other) <= metres;

  /// One cell around: where a unit reaches to heal, repair, embark or build
  /// (assumed, see the session log).
  double get _reach => world.cellSizeM * 1.5;

  // Movement (MAP-04, COMBAT-03, COMBAT-06; stack decision 8).

  OrderPlan _move(UnitState unit, Position to, List<Cell>? path) {
    if (unit.location is Carried) return _rule(HostRule.carried);
    if (!unit.weapon.canMoveAt(_now)) return _rule(HostRule.weaponLoaded);
    if (!(unit.observation?.allowsMovingAt(_now) ?? true)) {
      return _rule(HostRule.observing);
    }
    final goal = world.cellAt(to);
    if (goal == null) return _rule(HostRule.offMap);
    // MAP-38: a camp's goal and path stay on the ground; a searched path
    // between two ground cells never leaves it.
    if (unit.type.category == _encampment &&
        (goal.surface != groundSurface ||
            (path?.any((cell) => cell.island != null) ?? false))) {
      return _rule(HostRule.islandUnreachable);
    }
    final mover = Mover.unit(unit.type, flying: unit.flying);
    final route = _route(
      PathMover(apPerM: mover.apPerM, modes: mover.modes),
      unit.cell!,
      goal,
      path,
    );
    if (route case PlanRefused()) return route as OrderPlan;
    final (cells: _, :samples) = route as _Route;
    // The path search prices with the same movement cost: a path it gives
    // is passable.
    final movement = _cost.move(
      mover: mover,
      pool: unit.pool,
      start: _now,
      path: samples,
    )!;
    return PlanReady(() {
      final events = <BattleEvent>[];
      final work = unit.work;
      if (work != null && (work.action.startedAt != null)) {
        events.add(WorkInterrupted(unitId: unit.id, workId: work.workId));
      }
      _put(
        unit.copyWith(
          cell: goal,
          movingUntil: movement.arrivesAt,
          pool: movement.pool,
          work: work?.withAction(work.action.interruptedAt(_now)),
        ),
      );
      for (final carried in _state.units.values.toList()) {
        if (carried.location case Carried(:final transportId)
            when transportId == unit.id) {
          _put(carried.copyWith(cell: goal));
        }
      }
      return events..insert(
        0,
        MoveStarted(moverId: unit.id, arrivesAt: movement.arrivesAt),
      );
    });
  }

  /// The cells and samples of the path from [from] to [goal]: the
  /// client's [path] checked cell by cell, or one searched; a refusal
  /// otherwise.
  Object _route(PathMover mover, CellRef from, CellRef goal, List<Cell>? path) {
    final finder = Pathfinder(
      map: battle.map.host.navigation,
      cost: battle.map.cost,
      rules: battle.map.rules,
    );
    final List<CellRef> route;
    final List<nav.PathSample> samples;
    if (path != null) {
      final cells = [for (final cell in path) world.cellOf(cell)];
      if (cells.contains(null)) return _rule(HostRule.offMap);
      if (cells.isEmpty || cells.first != from || cells.last != goal) {
        return _rule(HostRule.pathNotFromMover);
      }
      switch (finder.check(mover: mover, path: cells.cast<CellRef>())) {
        case PathFails(:final reason):
          return _rule(reason);
        case PathPasses(samples: final passed):
          route = cells.cast<CellRef>();
          samples = passed;
      }
    } else {
      final onGround =
          from.surface == groundSurface &&
          goal.surface == groundSurface &&
          !mover.modes.contains(battle.map.rules.flyingMode);
      final found = onGround
          ? battle.map.searchFor(mover).fast(from, goal)
          : finder.find(mover: mover, from: from, to: goal);
      if (found == null) return _rule(HostRule.noPath);
      route = found.cells;
      samples = found.samples;
    }
    return (
      cells: route,
      samples: [
        for (final sample in samples)
          PathSample(
            terrainType: sample.terrainType,
            slopeDegrees: sample.slopeDegrees,
            lengthM: sample.lengthM,
          ),
      ],
    );
  }

  OrderPlan _moveHq(SectionState section, Position to, List<Cell>? path) {
    final team = _state.teams[section.team]!;
    final goal = world.cellAt(to);
    if (goal == null) return _rule(HostRule.offMap);
    final hq = battle.settings.hq;
    final mover = Mover.hq(hq);
    final pathMover = PathMover(apPerM: mover.apPerM, modes: mover.modes);
    final route = _route(pathMover, team.hq.cell, goal, path);
    if (route case PlanRefused()) return route as OrderPlan;
    final (:cells, :samples) = route as _Route;
    // HQ-12: any unit standing on the path ends the order.
    double? blockedAtM;
    var stop = goal;
    var along = 0.0;
    for (var i = 1; i < cells.length; i++) {
      along += samples[i - 1].lengthM;
      final standing = _state.units.values.any(
        (unit) => unit.onField && unit.cell == cells[i],
      );
      if (standing) {
        blockedAtM = along - samples[i - 1].lengthM;
        stop = cells[i - 1];
        break;
      }
    }
    final moved = moveHq(
      hq: hq,
      cost: _cost,
      pool: team.hq.pool,
      start: _now,
      path: samples,
      unitInPathAtM: blockedAtM,
    )!;
    return PlanReady(() {
      final id = hqId(team.id);
      battle.change(
        (state) => state.withTeam(
          team.withHq(
            HqState(
              cell: stop,
              health: team.hq.health,
              pool: moved.movement.pool,
              movingUntil: moved.movement.arrivesAt,
            ),
          ),
        ),
      );
      return [
        MoveStarted(moverId: id, arrivesAt: moved.movement.arrivesAt),
        if (moved.endedByUnit) MoveStopped(moverId: id, at: _positionOf(stop)),
      ];
    });
  }

  // The HQ manager (HQ-07, decision 220).

  OrderPlan _enter(SectionState section) {
    final team = _state.teams[section.team]!;
    final current = team.managerAccountId;
    final managing = _state.sections.values
        .where((other) => other.accountId == current)
        .firstOrNull;
    return PlanReady(() {
      final manager = _teams.afterLogIn(
        manager: managing == null ? null : _candidate(managing),
        entering: _candidate(section),
        random: battle.random,
      );
      if (manager.playerId == current) return const [];
      battle.change(
        (state) => state.withTeam(team.withManager(manager.playerId)),
      );
      return [ManagerChanged(team: team.id, accountId: manager.playerId)];
    });
  }

  /// The player of [section] as a candidate HQ manager: his medals and the
  /// XP his commander has earned (SOC-29).
  ManagerCandidate _candidate(SectionState section) => ManagerCandidate(
    playerId: section.accountId,
    medals: section.medals,
    commanderXp: _state.units.values
        .where(
          (unit) =>
              unit.sectionId == section.id && unit.type.category == _commander,
        )
        .fold(0, (xp, unit) => xp + unit.xp.earned),
  );

  // Weapons (COMBAT-26 to COMBAT-33, COMBAT-56).

  OrderPlan _reload(UnitState unit, {required bool unload}) {
    final result = unload
        ? _armory.unload(state: unit.weapon, pool: unit.pool, now: _now)
        : _armory.reload(state: unit.weapon, pool: unit.pool, now: _now);
    return switch (result) {
      WeaponRefused(:final reason) => _refusedFor(reason),
      WeaponDone(:final state) => PlanReady(() {
        _put(unit.copyWith(weapon: state));
        return [
          TimeOnlyStarted(
            unitId: unit.id,
            action: unload ? TimeOnly.unloadWeapon : TimeOnly.reload,
            endsAt: state.busyUntil,
          ),
        ];
      }),
    };
  }

  OrderPlan _swap(UnitState unit, String weapon) {
    final section = _state.sections[unit.sectionId]!;
    final hq = _state.teams[section.team]!.hq;
    final result = _armory.swap(
      unit: unit.type,
      state: unit.weapon,
      pool: unit.pool,
      storage: section.storedWeapons,
      weaponId: weapon,
      atStorage: _within(unit, hq.cell, battle.settings.storage.storeRadiusM),
      now: _now,
    );
    return switch (result) {
      WeaponRefused(:final reason) => _refusedFor(reason),
      WeaponDone(:final state, :final storage) => PlanReady(() {
        _put(unit.copyWith(weapon: state));
        battle.change((s) => s.withSection(section.withWeapons(storage!)));
        return [
          WeaponSwapped(
            unitId: unit.id,
            weapon: weapon,
            readyAt: state.busyUntil,
          ),
        ];
      }),
    };
  }

  OrderPlan _pickUp(UnitState unit, String droppedId, int seq) {
    final lying = _state.dropped[droppedId];
    if (lying == null || lying.dropped.isGoneAt(_now)) {
      return _rule(HostRule.unknownDropped);
    }
    if (lying.cell != unit.cell) return _rule(HostRule.notOnTheSpot);
    final result = _armory.pickUp(
      unit: unit.type,
      state: unit.weapon,
      pool: unit.pool,
      dropped: lying.dropped,
      now: _now,
    );
    return switch (result) {
      WeaponRefused(:final reason) => _refusedFor(reason),
      WeaponDone(:final at, :final state, :final pool, :final dropped) => _when(
        at,
        () {
          _put(unit.copyWith(weapon: state, pool: pool));
          battle.change((s) => s.withoutDropped(droppedId));
          return [
            WeaponPickedUp(unitId: unit.id, droppedId: droppedId),
            if (dropped != null) _drop(dropped, unit.cell!, 'w-$seq-own'),
          ];
        },
      ),
    };
  }

  WeaponDropped _drop(DroppedWeapon dropped, CellRef cell, String id) {
    battle.change(
      (state) => state.withDropped(
        DroppedWeaponState(id: id, dropped: dropped, cell: cell),
      ),
    );
    return WeaponDropped(
      droppedId: id,
      weapon: dropped.weapon.id,
      at: _positionOf(cell),
      goneAt: dropped.goneAt,
    );
  }

  // Flight (COMBAT-05, deferred from M4.11).

  OrderPlan _flight(UnitState unit, {required bool flying}) {
    final times = unit.type.flight;
    if (times == null) return _rule(HostRule.cannotFly);
    if (unit.flying == flying) {
      return _rule(flying ? HostRule.alreadyFlying : HostRule.notFlying);
    }
    final endsAt =
        _now +
        Duration(
          microseconds: ((flying ? times.takeOffTimeS : times.landTimeS) * 1e6)
              .round(),
        );
    return PlanReady(() {
      _put(unit.copyWith(movingUntil: endsAt));
      battle.schedule(endsAt, FlightEnds(unit.id, flying: flying));
      return [
        TimeOnlyStarted(
          unitId: unit.id,
          action: flying ? TimeOnly.takeOff : TimeOnly.land,
          endsAt: endsAt,
        ),
      ];
    });
  }

  /// Ends the landing or take-off of [unitId].
  List<BattleEvent> finishFlight(String unitId, {required bool flying}) {
    final unit = _state.units[unitId];
    if (unit != null && unit.onField) _put(unit.copyWith(flying: flying));
    return const [];
  }

  // Transports (UNIT-37, COMBAT-54).

  OrderPlan _embark(UnitState unit, String transportId) {
    final transport = _state.units[transportId];
    if (transport == null || !transport.onField) {
      return _rule(HostRule.unknownTarget);
    }
    if (_teamOf(transport) != _teamOf(unit)) {
      return _rule(ActionRefusal.targetNotFriendly);
    }
    final capacity = transport.type.role.maxTotalWeight;
    if (capacity == null) return _rule(HostRule.notATransport);
    if (!unit.type.role.transportable) return _rule(HostRule.notTransportable);
    if (transport.flying) return _rule(HostRule.transportFlying);
    if (!_within(unit, transport.cell!, _reach)) return _rule(HostRule.tooFar);
    final weight = unit.type.stats.weight;
    if (weight > (transport.type.role.maxUnitWeight ?? capacity)) {
      return _rule(HostRule.tooHeavy);
    }
    final carried = _state.units.values
        .where(
          (other) => switch (other.location) {
            Carried(:final transportId) => transportId == transport.id,
            _ => false,
          },
        )
        .fold<double>(0, (sum, other) => sum + other.type.stats.weight);
    if (carried + weight > capacity) return _rule(HostRule.transportFull);
    return PlanReady(() {
      _put(
        unit.copyWith(location: Carried(transport.id), cell: transport.cell),
      );
      return [Embarked(unitId: unit.id, transportId: transport.id)];
    });
  }

  OrderPlan _disembark(UnitState unit) {
    final location = unit.location;
    if (location is! Carried) return _rule(HostRule.notCarried);
    final transport = _state.units[location.transportId]!;
    if (transport.flying) return _rule(HostRule.transportFlying);
    return PlanReady(() {
      _put(unit.copyWith(location: const Deployed(), cell: transport.cell));
      return [Disembarked(unitId: unit.id, at: _positionOf(transport.cell!))];
    });
  }

  // Role actions (COMBAT-07, COMBAT-09, UNIT-33 to UNIT-35).

  OrderPlan _build(UnitState unit, String structure, List<Cell> cells) {
    final refs = [for (final cell in cells) world.cellOf(cell)];
    if (refs.isEmpty || refs.contains(null)) return _rule(HostRule.offMap);
    final where = refs.cast<CellRef>();
    if (!_within(unit, where.first, _reach)) return _rule(HostRule.tooFar);
    final result = _roleActions.startBuild(
      unit: unit.type,
      structure: structure,
      pool: unit.pool,
      now: _now,
    );
    if (result case ActionRefused(:final reason)) return _refusedFor(reason);
    final TimedActionStarted(:at, :pool, :action) =
        result as TimedActionStarted;
    return _when(at, () {
      final site = '$structure@(${where.first.x}, ${where.first.y})';
      _startWork(
        unit,
        pool,
        Work(workId: site, action: action, structure: structure, cells: where),
      );
      return [
        BuildStarted(
          unitId: unit.id,
          siteId: site,
          structure: structure,
          cells: cells,
          endsAt: action.endsAt!,
        ),
      ];
    });
  }

  void _startWork(UnitState unit, ApPool pool, Work work) {
    _put(unit.copyWith(pool: pool, work: work));
    battle.schedule(work.action.endsAt!, WorkEnds(unit.id));
  }

  ActionTarget? _targetOf(UnitState unit, String targetId) {
    if (targetId.startsWith('hq-')) {
      final team = targetId.substring(3);
      if (!_state.teams.containsKey(team)) return null;
      return ActionTarget(friendly: team == _teamOf(unit), isHq: true);
    }
    final target = _state.units[targetId];
    if (target == null || !target.onField) return null;
    return ActionTarget(friendly: _teamOf(target) == _teamOf(unit));
  }

  OrderPlan _repair(UnitState unit, String targetId) {
    final target = _targetOf(unit, targetId);
    if (target == null) return _rule(HostRule.unknownTarget);
    final repaired = _state.units[targetId];
    if (repaired != null && !_within(unit, repaired.cell!, _reach)) {
      return _rule(HostRule.tooFar);
    }
    final result = _roleActions.startRepair(
      unit: unit.type,
      target: target,
      pool: unit.pool,
      now: _now,
    );
    if (result case ActionRefused(:final reason)) return _refusedFor(reason);
    final TimedActionStarted(:at, :pool, :action) =
        result as TimedActionStarted;
    return _when(at, () {
      _startWork(unit, pool, Work(workId: targetId, action: action));
      return [
        RepairStarted(
          unitId: unit.id,
          targetId: targetId,
          endsAt: action.endsAt!,
        ),
      ];
    });
  }

  OrderPlan _resume(UnitState unit, String workId) {
    final owner = _state.units.values
        .where((other) => other.work?.workId == workId)
        .firstOrNull;
    final work = owner?.work;
    if (owner == null || work == null || work.action.startedAt != null) {
      return _rule(HostRule.unknownWork);
    }
    final result = _roleActions.resume(
      action: work.action,
      pool: unit.pool,
      now: _now,
    );
    if (result case ActionRefused(:final reason)) return _refusedFor(reason);
    final TimedActionStarted(:at, :pool, :action) =
        result as TimedActionStarted;
    return _when(at, () {
      if (owner.id != unit.id) _put(owner.copyWith(clearWork: true));
      _startWork(_state.units[unit.id]!, pool, work.withAction(action));
      return [
        WorkResumed(unitId: unit.id, workId: workId, endsAt: action.endsAt!),
      ];
    });
  }

  /// Ends the build or repair of [unitId] that was due at the battle's
  /// time; a work interrupted since ends nothing.
  List<BattleEvent> finishWork(String unitId) {
    final unit = _state.units[unitId];
    final work = unit?.work;
    if (unit == null || work == null || work.action.endsAt != _now) {
      return const [];
    }
    _put(unit.copyWith(clearWork: true));
    final structure = work.structure;
    if (structure != null) {
      battle.change(
        (state) => state.withStructure(work.workId, structure, work.cells),
      );
      return [
        StructureBuilt(
          siteId: work.workId,
          structure: structure,
          cells: [
            for (final cell in work.cells)
              Cell(
                cell.x,
                cell.y,
                island: cell.surface == groundSurface ? null : cell.surface,
              ),
          ],
        ),
      ];
    }
    final target = _state.units[work.workId];
    if (target == null) return const [];
    final health = target.health.healed(_roleActions.repairHp);
    _put(target.copyWith(health: health));
    return [Repaired(targetId: target.id, hp: health.current)];
  }

  OrderPlan _heal(UnitState unit, String targetId) {
    final target = _targetOf(unit, targetId);
    final healed = _state.units[targetId];
    if (target == null) return _rule(HostRule.unknownTarget);
    if (healed != null && !_within(unit, healed.cell!, _reach)) {
      return _rule(HostRule.tooFar);
    }
    final result = _roleActions.heal(
      unit: unit.type,
      target: target,
      health: healed?.health ?? const Health(current: 0, max: 0),
      pool: unit.pool,
      now: _now,
    );
    if (result case ActionRefused(:final reason)) return _refusedFor(reason);
    final Healed(:at, :pool, :health) = result as Healed;
    return _when(at, () {
      _put(unit.copyWith(pool: pool));
      _put(_state.units[targetId]!.copyWith(health: health));
      return [
        UnitHealed(unitId: unit.id, targetId: targetId, hp: health.current),
      ];
    });
  }

  OrderPlan _observe(UnitState unit) {
    final role = unit.type.role.observe;
    if (role == null || !unit.type.actions.contains(UnitAction.observe)) {
      return _rule(ActionRefusal.notInActions);
    }
    final paid = unit.pool.payWhenReady(role.ap, _now);
    if (paid == null) return const PlanRefused(ApRefused());
    return _when(paid.at, () {
      final observation = Observation(role: role, startedAt: paid.at);
      _put(unit.copyWith(pool: paid.pool, observation: observation));
      return [ObservationStarted(unitId: unit.id, endsAt: observation.endsAt)];
    });
  }

  // Captures and pushes (RELIC-05 to RELIC-08, RELIC-19, RELIC-24).

  OrderPlan _captureOrder(UnitState unit, String relicId) {
    final relic = _state.relics[relicId];
    if (relic == null) return _rule(HostRule.unknownRelic);
    final team = _teamOf(unit);
    if (relic.owner == team) return _rule(HostRule.alreadyOwned);
    final radius = battle.settings.capture.radiusM;
    final occupants = [
      for (final other in _state.units.values)
        if (other.onField && _within(other, relic.cell, radius))
          RadiusOccupant(
            team: _teamOf(other),
            presence: other.location is Carried
                ? Presence.carried
                : other.flying
                ? Presence.flying
                : Presence.onField,
          ),
    ];
    final current = relic.capturePot;
    final pot = current != null && current.team == team
        ? current
        : CapturePot(team: team);
    final result = _capture.contribute(
      unit: unit.type,
      unitId: unit.id,
      pot: pot,
      pool: unit.pool,
      insideRadius: _within(unit, relic.cell, radius),
      occupants: occupants,
      now: _now,
    );
    if (result case ActionRefused(:final reason)) return _refusedFor(reason);
    final CaptureContributed(:at, :pool, pot: filled) =
        result as CaptureContributed;
    return _when(at, () {
      _put(unit.copyWith(pool: pool));
      battle.change(
        (state) => state.withRelic(relic.withPots(capturePot: filled)),
      );
      return [
        AddedToCapture(
          unitId: unit.id,
          relicId: relicId,
          potAp: filled.ap,
          capturedAt: _capture.capturedAt(filled),
        ),
      ];
    });
  }

  OrderPlan _push(UnitState unit, String relicId, List<Cell>? path) {
    final relic = _state.relics[relicId];
    if (relic == null) return _rule(HostRule.unknownRelic);
    if (!_within(unit, relic.cell, battle.settings.capture.radiusM)) {
      return _rule(ActionRefusal.outsideRadius);
    }
    final cells = path == null
        ? null
        : [for (final cell in path) world.cellOf(cell)];
    if (cells != null && cells.contains(null)) return _rule(HostRule.offMap);
    final pot = relic.pushPot ?? PushPot(owner: relic.owner ?? '');
    final result = _pushing.contribute(
      unit: unit.type,
      team: _teamOf(unit),
      pot: pot,
      pool: unit.pool,
      now: _now,
    );
    if (result case ActionRefused(:final reason)) return _refusedFor(reason);
    final PushContributed(:at, :pool, pot: filled) = result as PushContributed;
    return _when(at, () {
      _put(unit.copyWith(pool: pool));
      // Decision 219: the first push while the pot is empty sets the
      // path.
      final chosen = pot.ap == 0 && cells != null
          ? cells.cast<CellRef>()
          : null;
      battle.change(
        (state) =>
            state.withRelic(relic.withPots(pushPot: filled, pushPath: chosen)),
      );
      return [AddedToPush(unitId: unit.id, relicId: relicId, potAp: filled.ap)];
    });
  }

  // Shots (COMBAT-11 to COMBAT-25, COMBAT-36 to COMBAT-41, COMBAT-55).

  OrderPlan _fire(UnitState unit, String targetId, int seq) {
    final weapon = unit.weapon.weapon;
    if (weapon == null) return _rule(WeaponRefusal.noWeapon);
    final (cell, flying, armor, defense) = switch (_targetCell(targetId)) {
      final found? => found,
      null => (null, false, '', 0.0),
    };
    if (cell == null) return _rule(HostRule.unknownTarget);
    if (flying && weapon.airborneFactor == 0) {
      return _rule(HostRule.cannotHitFlying);
    }
    final line = world.sightLine(
      unit.cell!,
      cell,
      fromFlying: unit.flying,
      toFlying: flying,
    );
    if (line.distanceM > weapon.rangeM) return _rule(HostRule.outOfRange);
    if (!_vision.canFireAt(
      unit: unit.type,
      weapon: weapon,
      weather: _state.weather,
      line: line,
      time: _now,
      observation: unit.observation,
    )) {
      return _rule(HostRule.targetNotSeen);
    }
    return _shoot(unit, (shooter) {
      final roll = HitChance.roll(
        _hitChance.of(
          weapon: weapon,
          attack: shooter.type.stats.attack,
          morale: shooter.morale,
          defense: defense,
          targetArmor: armor,
          targetSpeedMps: _speedOf(targetId),
          distanceM: line.distanceM,
          cover: world.coverOn(cell),
        ),
        battle.random,
      );
      final impacts = roll.hits
          ? _hit(shooter, targetId, _damageTo(weapon, targetId, shooter), seq)
          : <Impact>[];
      return (roll.hits, impacts);
    });
  }

  /// The cell of [targetId], whether it flies, its armor and defense.
  (CellRef, bool, String, double)? _targetCell(String targetId) {
    if (targetId.startsWith('hq-')) {
      final team = _state.teams[targetId.substring(3)];
      return team == null ? null : (team.hq.cell, false, 'hq', 0.0);
    }
    final target = _state.units[targetId];
    if (target == null || !target.onField) return null;
    return (
      target.cell!,
      target.flying,
      target.type.armorType,
      target.type.stats.defense,
    );
  }

  double _speedOf(String targetId) {
    final target = _state.units[targetId];
    final moving = target?.movingUntil;
    return target != null && moving != null && moving > _now
        ? target.type.stats.moveSpeed
        : 0;
  }

  double _damageTo(WeaponType weapon, String targetId, UnitState shooter) {
    if (targetId.startsWith('hq-')) {
      return _damage.hit(
        weapon,
        DamageTarget(
          armorType: 'hq',
          friendly: targetId.substring(3) == _teamOf(shooter),
        ),
      );
    }
    final target = _state.units[targetId]!;
    return _damage.hit(
      weapon,
      DamageTarget(
        armorType: target.type.armorType,
        flying: target.flying,
        friendly: _teamOf(target) == _teamOf(shooter),
      ),
    );
  }

  /// Fires [unit]'s weapon now or when it can (rate of fire, AP), then
  /// [resolve] gives whether it hit and what it hurt.
  OrderPlan _shoot(
    UnitState unit,
    (bool, List<Impact>) Function(UnitState shooter) resolve,
  ) {
    final result = _armory.fire(state: unit.weapon, pool: unit.pool, now: _now);
    return switch (result) {
      WeaponRefused(:final reason) => _refusedFor(reason),
      WeaponDone(:final at, :final state, :final pool) => _when(at, () {
        final shooter = unit.copyWith(weapon: state, pool: pool);
        _put(shooter);
        final (hit, impacts) = resolve(shooter);
        final drops = [..._pendingDrops];
        _pendingDrops.clear();
        return [
          Attacked(
            attackerId: unit.id,
            sectionId: unit.sectionId,
            weapon: state.weapon!.id,
            hit: hit,
            impacts: impacts,
          ),
          ...drops,
        ];
      }),
    };
  }

  final _pendingDrops = <WeaponDropped>[];

  /// Deals [amount] to [targetId] for [shooter] and resolves its 0 HP
  /// (COMBAT-36 to COMBAT-43); carried units take their share
  /// (COMBAT-54, UNIT-37).
  List<Impact> _hit(
    UnitState shooter,
    String targetId,
    double amount,
    int seq,
  ) {
    if (targetId.startsWith('hq-')) {
      final team = _state.teams[targetId.substring(3)]!;
      final health = team.hq.health.damaged(amount);
      battle.change(
        (state) => state.withTeam(
          team.withHq(
            HqState(
              cell: team.hq.cell,
              health: health,
              pool: team.hq.pool,
              movingUntil: team.hq.movingUntil,
            ),
          ),
        ),
      );
      return [
        Impact(
          targetId: targetId,
          targetType: 'hq',
          damage: amount,
          friendly: team.id == _teamOf(shooter),
          result: health.isZero ? ImpactResult.killed : ImpactResult.damaged,
        ),
      ];
    }
    final target = _state.units[targetId]!;
    final impacts = [_hurt(shooter, target, amount, seq)];
    final weapon = shooter.weapon.weapon!;
    for (final carried in _state.units.values.toList()) {
      if (carried.location case Carried(:final transportId)
          when transportId == targetId) {
        final share = _damage.carriedHit(
          weapon,
          DamageTarget(
            armorType: carried.type.armorType,
            friendly: _teamOf(carried) == _teamOf(shooter),
          ),
        );
        impacts.add(_hurt(shooter, carried, share, seq));
      }
    }
    return impacts;
  }

  Impact _hurt(UnitState shooter, UnitState target, double amount, int seq) {
    final health = target.health.damaged(amount);
    final friendly = _teamOf(target) == _teamOf(shooter);
    var result = ImpactResult.damaged;
    if (!health.isZero) {
      _put(target.copyWith(health: health));
    } else {
      final section = _state.sections[shooter.sectionId]!;
      final level = _levels.levelFor(section.xp);
      final own = _state.units.values.where(
        (unit) => unit.sectionId == section.id,
      );
      final outcome = _zeroHp.resolve(
        attacker: shooter.type,
        target: target.type,
        targetIsEnemy: !friendly,
        moraleValue: target.morale,
        ap: target.pool.apAt(_now),
        attackerSectionHasRoom: _levels.hasRoom(
          level: level,
          active: own.where((unit) => unit.onField).length,
          owned: own.length,
        ),
        random: battle.random,
      );
      switch (outcome) {
        case ZeroHpOutcome.death:
          result = ImpactResult.killed;
          final dropped = _armory.drop(target.weapon, _now);
          if (dropped != null) {
            _pendingDrops.add(
              _drop(dropped, target.cell!, 'w-$seq-${target.id}'),
            );
          }
          // Commanders resurrect in storage (UNIT-28); the rest of a
          // commander's death is applied with storage (M5.12).
          if (target.type.permadeath) {
            battle.change((state) => state.withoutUnit(target.id));
          } else {
            _put(
              target.copyWith(
                location: const Stored(),
                health: Health.full(target.health.max),
                weapon: const WeaponState.unarmed(),
                clearCell: true,
                clearMove: true,
                clearWork: true,
              ),
            );
          }
        case ZeroHpOutcome.defection:
          result = ImpactResult.defected;
          _put(target.copyWith(sectionId: shooter.sectionId, health: health));
        case ZeroHpOutcome.prisoner:
          result = ImpactResult.prisoner;
          _put(
            target.copyWith(
              location: Prisoner(shooter.sectionId),
              health: health,
              clearCell: true,
              clearMove: true,
              clearWork: true,
            ),
          );
      }
    }
    return Impact(
      targetId: target.id,
      targetType: target.type.id,
      damage: amount,
      friendly: friendly,
      result: result,
    );
  }

  OrderPlan _fireAt(UnitState unit, Position target, int seq) {
    final weapon = unit.weapon.weapon;
    if (weapon == null) return _rule(WeaponRefusal.noWeapon);
    final splash = weapon.splashRadiusM;
    if (!weapon.indirectFire && splash == null) {
      return _rule(HostRule.notIndirect);
    }
    final aimed = world.cellAt(target);
    if (aimed == null) return _rule(HostRule.offMap);
    final distance = world.distanceM(unit.cell!, aimed);
    final section = unit.sectionId;
    bool sees(UnitState observer) => _vision.unitSees(
      unit: observer.type,
      weather: _state.weather,
      line: world.sightLine(observer.cell!, aimed, fromFlying: observer.flying),
      time: _now,
      observation: observer.observation,
    );
    final onField = _state.units.values.where((u) => u.onField).toList();
    final seen = onField.any((u) => u.sectionId == section && sees(u));
    final relayed =
        weapon.indirectFire &&
        onField.any(
          (scout) =>
              scout.type.role.reportsToRadio &&
              _teamOf(scout) == _teamOf(unit) &&
              sees(scout) &&
              onField.any(
                (radio) =>
                    radio.sectionId == section &&
                    radio.type.role.relayRange != null &&
                    _within(radio, scout.cell!, radio.type.role.relayRange!),
              ),
        );
    if (distance > weapon.rangeM) return _rule(HostRule.outOfRange);
    // Artillery fires at what its section sees or a scout reports
    // (COMBAT-12); the explosive charge goes off on a point its engineer
    // sees itself, within its range (decision 152).
    final targetable = weapon.indirectFire
        ? HitChance.canTargetPosition(
            weapon: weapon,
            distanceM: distance,
            seenBySection: seen,
            relayedByRadio: relayed,
          )
        : sees(unit);
    if (!targetable) return _rule(HostRule.positionNotSeen);
    return _shoot(unit, (shooter) {
      final there = onField
          .where((u) => u.cell == aimed && _teamOf(u) != _teamOf(shooter))
          .firstOrNull;
      final roll = weapon.neverMisses
          ? const HitRoll(roll: 0, chance: 1)
          : HitChance.roll(
              _hitChance.of(
                weapon: weapon,
                attack: shooter.type.stats.attack,
                morale: shooter.morale,
                defense: there?.type.stats.defense ?? 0,
                targetArmor: there?.type.armorType ?? 'structure',
                targetSpeedMps: 0,
                distanceM: distance,
              ),
              battle.random,
            );
      final landed = _hitChance.landingPoint(
        weapon: weapon,
        artillery: world.pointOf(shooter.cell!),
        aimed: world.pointOf(aimed),
        roll: roll,
        random: battle.random,
      );
      final impacts = <Impact>[];
      for (final victim in _state.units.values.toList()) {
        if (!victim.onField || victim.location is Carried) continue;
        final point = world.pointOf(victim.cell!, flying: victim.flying);
        final metres = (point - landed).length;
        final amount = _damage.splash(
          weapon,
          DamageTarget(
            armorType: victim.type.armorType,
            flying: victim.flying,
            friendly: _teamOf(victim) == _teamOf(shooter),
          ),
          metres,
        );
        if (amount > 0) {
          impacts.add(_hurt(shooter, _state.units[victim.id]!, amount, seq));
        }
      }
      return (roll.hits, impacts);
    });
  }

  OrderPlan _fireAimed(UnitState unit, Direction aim, int seq) {
    final weapon = unit.weapon.weapon;
    if (weapon == null) return _rule(WeaponRefusal.noWeapon);
    if (weapon.projectileSpeedMps == null) return _rule(HostRule.notAimed);
    return _shoot(unit, (shooter) {
      // The shot leaves from the middle of the shooter's hit volume, which
      // the rules core then skips as the shooter's own.
      final origin =
          world.pointOf(shooter.cell!, flying: shooter.flying) +
          Vec3(0, 0, shooter.type.hitBox.height / 2);
      final targets = <ShotTarget>[
        // A carried unit has no hit volume of its own: it takes a share of
        // its transport's hits (COMBAT-54).
        for (final other in _state.units.values)
          if (other.onField &&
              other.location is! Carried &&
              other.id != shooter.id)
            ShotTarget(
              id: other.id,
              position: world.pointOf(other.cell!, flying: other.flying),
              hitBox: other.type.hitBox,
            ),
        for (final team in _state.teams.values)
          ShotTarget(
            id: hqId(team.id),
            position: world.pointOf(team.hq.cell),
            hitBox: battle.settings.hq.hitBox,
          ),
      ];
      final outcome = _firstPerson.fire(
        weapon: weapon,
        origin: origin,
        aim: Vec3(aim.x, aim.y, aim.z),
        fireTime: _now,
        attack: shooter.type.stats.attack,
        morale: shooter.morale,
        random: battle.random,
        targets: targets,
        obstacles: world,
      );
      return switch (outcome) {
        ShotHitsTarget(:final targetId) => (
          true,
          _hit(shooter, targetId, _damageTo(weapon, targetId, shooter), seq),
        ),
        ShotHitsObstacle() || ShotMisses() => (false, const <Impact>[]),
      };
    });
  }
}

/// {@template handled_order}
/// What the handler did with a command: its events, and its refusal when
/// it was refused.
/// {@endtemplate}
final class HandledOrder {
  /// {@macro handled_order}
  const new({required this.events, this.refusal});

  /// The events of the command.
  final List<BattleEvent> events;

  /// Why it was refused; null when it was not.
  final OrderRefusal? refusal;
}

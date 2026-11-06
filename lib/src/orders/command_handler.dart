import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/orders/order_chain.dart';
import 'package:battle_host/src/orders/refusal.dart';
import 'package:battle_host/src/orders/relics.dart';
import 'package:battle_host/src/orders/rewards.dart';
import 'package:battle_host/src/orders/section_orders.dart';
import 'package:battle_host/src/orders/server_sections.dart';
import 'package:battle_host/src/orders/world.dart';
import 'package:battle_host/src/orders/world_changes.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' hide PathSample;
import 'package:battle_pathfinding/battle_pathfinding.dart'
    as nav
    show PathSample;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// The ID of [team]'s HQ as a target or a mover.
String hqId(String team) => 'hq-$team';

/// A shot's aim: its weapon, the target's cell, armor and defense, and the
/// sight line to it.
typedef _Aim = ({
  WeaponType weapon,
  CellRef cell,
  String armor,
  double defense,
  SightLine line,
});

/// A route: its cells, and its samples priced by the movement cost.
typedef _Route = ({
  List<CellRef> cells,
  List<PathSample> samples,
  List<CellRef> falls,
});

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
      world = World(battle: battle.world, terrain: battle.definitions.terrain);

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

  /// The orders of a section about its units and money.
  late final sections = SectionOrders(battle: battle, world: world);
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
    final before = _state;
    return HandledOrder(events: react(before, (plan as PlanReady).apply()));
  }

  /// Relics, eliminations and the end of the battle.
  late final relics = Relics(battle: battle, world: world, orders: this);

  /// The world's changes: constructions, damaged objects, craters.
  late final worlds = WorldChanges(
    battle: battle,
    world: world,
    relics: relics,
  );

  /// The fire checks of the server-managed sections' units.
  late final servers = ServerSections(
    battle: battle,
    world: world,
    orders: this,
  );

  late final _listeners = <BattleListener>[
    relics,
    Rewards(battle: battle, world: world),
    StorageLocks(battle),
    servers,
  ];

  /// [events], which changed the state from [before], with what follows
  /// from them: pushes, captures and eliminations, then XP and money, then
  /// locks (Observer). Each listener hears the events of those before it.
  List<BattleEvent> react(BattleState before, List<BattleEvent> events) {
    if (events.isEmpty) return events;
    final all = [...events];
    for (final listener in _listeners) {
      all.addAll(listener.hear(List.unmodifiable(all), before));
    }
    return all;
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
      Store() => sections.store(context.unit!, recall: false),
      Recall() => sections.store(context.unit!, recall: true),
      Deploy() => sections.deploy(context.unit!),
      BuyNode(:final stat, :final step) => sections.buyNode(
        context.unit!,
        stat,
        step,
      ),
      BuyUnit(:final unitType) => sections.buyUnit(
        context.section!,
        unitType,
        seq,
      ),
      BuyWeapon(:final weapon) => sections.buyWeapon(context.section!, weapon),
      BuyGuildCamp() => sections.buyCamp(context.section!, seq),
      TransferMoney(:final toSectionId, :final amount) => sections.transfer(
        context.section!,
        toSectionId,
        amount,
      ),
      OfferExchange(:final ownerSectionId, :final released, :final wanted) =>
        sections.offer(
          context.section!,
          ExchangeOffer(
            captorSectionId: context.section!.id,
            ownerSectionId: ownerSectionId,
            released: released,
            wanted: wanted,
          ),
          seq,
        ),
      OfferRansom(:final ownerSectionId, :final released, :final price) =>
        sections.offer(
          context.section!,
          RansomOffer(
            captorSectionId: context.section!.id,
            ownerSectionId: ownerSectionId,
            released: released,
            price: price,
          ),
          seq,
        ),
      AcceptOffer(:final offerId) => sections.answer(
        context.section!,
        offerId,
        refuse: false,
      ),
      RefuseOffer(:final offerId) => sections.answer(
        context.section!,
        offerId,
        refuse: true,
      ),
      DelegateHq(:final accountId) => sections.delegate(
        context.section!,
        command.sender.accountId,
        accountId,
      ),
    };
  }

  // Helpers.

  static OrderPlan _refusedFor(Enum reason) => reason.name == 'costAboveApMax'
      ? const PlanRefused(ApRefused())
      : refused(reason);

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
    if (unit.location is Carried) return refused(HostRule.carried);
    if (!unit.weapon.canMoveAt(_now)) return refused(HostRule.weaponLoaded);
    if (!(unit.observation?.allowsMovingAt(_now) ?? true)) {
      return refused(HostRule.observing);
    }
    final goal = world.cellAt(to);
    if (goal == null) return refused(HostRule.offMap);
    // MAP-38: a camp's goal and path stay on the ground; a searched path
    // between two ground cells never leaves it.
    if (unit.type.category == encampmentCategory &&
        (goal.surface != groundSurface ||
            (path?.any((cell) => cell.island != null) ?? false))) {
      return refused(HostRule.islandUnreachable);
    }
    final mover = Mover.unit(unit.type, flying: unit.flying);
    final route = _route(
      PathMover(apPerM: mover.apPerM, modes: mover.modes),
      unit.cell!,
      goal,
      path,
    );
    if (route case PlanRefused()) return route as OrderPlan;
    final (cells: _, :samples, falls: _) = route as _Route;
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
    final finder = battle.world.paths;
    final List<CellRef> route;
    final List<nav.PathSample> samples;
    final List<CellRef> falls;
    if (path != null) {
      final cells = [for (final cell in path) world.cellOf(cell)];
      if (cells.contains(null)) return refused(HostRule.offMap);
      if (cells.isEmpty || cells.first != from || cells.last != goal) {
        return refused(HostRule.pathNotFromMover);
      }
      switch (finder.check(mover: mover, path: cells.cast<CellRef>())) {
        case PathFails(:final reason):
          return refused(reason);
        case PathPasses(samples: final passed, falls: final fell):
          route = cells.cast<CellRef>();
          samples = passed;
          falls = fell;
      }
    } else {
      final onGround =
          from.surface == groundSurface &&
          goal.surface == groundSurface &&
          !mover.modes.contains(battle.world.rules.flyingMode);
      final found = onGround
          ? battle.world.searchFor(mover).fast(from, goal)
          : finder.find(mover: mover, from: from, to: goal);
      if (found == null) return refused(HostRule.noPath);
      route = found.cells;
      samples = found.samples;
      falls = found.falls;
    }
    return (
      cells: route,
      falls: falls,
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
    if (goal == null) return refused(HostRule.offMap);
    final hq = battle.settings.hq;
    final mover = Mover.hq(hq);
    final pathMover = PathMover(apPerM: mover.apPerM, modes: mover.modes);
    final route = _route(pathMover, team.hq.cell, goal, path);
    if (route case PlanRefused()) return route as OrderPlan;
    final (:cells, :samples, :falls) = route as _Route;
    // HQ-12: any unit standing on the path ends the order; HQ-48: units
    // where it lands after a fall are killed, not in its way.
    final along = alongOf(pathMover, cells);
    double? blockedAtM;
    var stop = goal;
    var stopIndex = cells.length - 1;
    for (var i = 1; i < cells.length; i++) {
      final standing =
          !falls.contains(cells[i]) &&
          _state.units.values.any(
            (unit) => unit.onField && unit.cell == cells[i],
          );
      if (standing) {
        blockedAtM = along[i - 1];
        stop = cells[i - 1];
        stopIndex = i - 1;
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
      final landed = [
        for (final cell in falls)
          if (cells.indexOf(cell) <= stopIndex)
            for (final unit in _state.units.values.toList())
              if (unit.onField && unit.cell == cell) unit.id,
      ];
      return [
        MoveStarted(moverId: id, arrivesAt: moved.movement.arrivesAt),
        if (moved.endedByUnit) MoveStopped(moverId: id, at: _positionOf(stop)),
        for (final unitId in landed) ...crush(unitId, by: id),
      ];
    });
  }

  // The HQ manager (HQ-07, decisions 220, 227): a player who logs in is
  // compared with the holder of the role by rank, not with a delegate.

  OrderPlan _enter(SectionState section) {
    final team = _state.teams[section.team]!;
    final holder = team.holderAccountId;
    final holding = _state.sections.values
        .where((other) => other.accountId == holder)
        .firstOrNull;
    return PlanReady(() {
      final ranked = _teams.afterLogIn(
        holder: holding == null ? null : _candidate(holding),
        entering: _candidate(section),
        random: battle.random,
      );
      if (ranked.playerId == holder) return const [];
      battle.change(
        (state) => state.withTeam(team.withHolder(ranked.playerId)),
      );
      if (ranked.playerId == team.managerAccountId) return const [];
      return [ManagerChanged(team: team.id, accountId: ranked.playerId)];
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
              unit.sectionId == section.id &&
              unit.type.category == commanderCategory,
        )
        .fold(0, (xp, unit) => xp + unit.xp.earned),
  );

  /// The distance along [cells], a path [mover] passes, at which it
  /// reaches each of them: a step gives several samples, a fall none.
  List<double> alongOf(PathMover mover, List<CellRef> cells) {
    final finder = battle.world.paths;
    final along = <double>[0];
    for (var i = 1; i < cells.length; i++) {
      final step = finder.check(mover: mover, path: [cells[i - 1], cells[i]]);
      along.add(
        along.last +
            (step as PathPasses).samples.fold(0.0, (sum, s) => sum + s.lengthM),
      );
    }
    return along;
  }

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
      return refused(HostRule.unknownDropped);
    }
    if (lying.cell != unit.cell) return refused(HostRule.notOnTheSpot);
    final result = _armory.pickUp(
      unit: unit.type,
      state: unit.weapon,
      pool: unit.pool,
      dropped: lying.dropped,
      now: _now,
    );
    return switch (result) {
      WeaponRefused(:final reason) => _refusedFor(reason),
      WeaponDone(:final at, :final state, :final pool, :final dropped) =>
        planAt(at, _now, () {
          _put(unit.copyWith(weapon: state, pool: pool));
          battle.change((s) => s.withoutDropped(droppedId));
          return [
            WeaponPickedUp(unitId: unit.id, droppedId: droppedId),
            if (dropped != null) _drop(dropped, unit.cell!, 'w-$seq-own'),
          ];
        }),
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
    if (times == null) return refused(HostRule.cannotFly);
    if (unit.flying == flying) {
      return refused(flying ? HostRule.alreadyFlying : HostRule.notFlying);
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
      return refused(HostRule.unknownTarget);
    }
    if (_teamOf(transport) != _teamOf(unit)) {
      return refused(ActionRefusal.targetNotFriendly);
    }
    final capacity = transport.type.role.maxTotalWeight;
    if (capacity == null) return refused(HostRule.notATransport);
    if (!unit.type.role.transportable) {
      return refused(HostRule.notTransportable);
    }
    if (transport.flying) return refused(HostRule.transportFlying);
    // HQ-49: a recalled transport takes no passengers.
    if (!(transport.location as OnField).takesPassengers) {
      return refused(HostRule.transportRecalled);
    }
    if (!_within(unit, transport.cell!, _reach)) {
      return refused(HostRule.tooFar);
    }
    final weight = unit.type.stats.weight;
    if (weight > (transport.type.role.maxUnitWeight ?? capacity)) {
      return refused(HostRule.tooHeavy);
    }
    final carried = _state.units.values
        .where(
          (other) => switch (other.location) {
            Carried(:final transportId) => transportId == transport.id,
            _ => false,
          },
        )
        .fold<double>(0, (sum, other) => sum + other.type.stats.weight);
    if (carried + weight > capacity) return refused(HostRule.transportFull);
    return PlanReady(() {
      _put(
        unit.copyWith(location: Carried(transport.id), cell: transport.cell),
      );
      return [Embarked(unitId: unit.id, transportId: transport.id)];
    });
  }

  OrderPlan _disembark(UnitState unit) {
    final location = unit.location;
    if (location is! Carried) return refused(HostRule.notCarried);
    final transport = _state.units[location.transportId]!;
    if (transport.flying) return refused(HostRule.transportFlying);
    return PlanReady(() {
      _put(unit.copyWith(location: const Deployed(), cell: transport.cell));
      return [Disembarked(unitId: unit.id, at: _positionOf(transport.cell!))];
    });
  }

  // Role actions (COMBAT-07, COMBAT-09, UNIT-33 to UNIT-35).

  OrderPlan _build(UnitState unit, String structure, List<Cell> cells) {
    final refs = [for (final cell in cells) world.cellOf(cell)];
    if (refs.isEmpty || refs.contains(null)) return refused(HostRule.offMap);
    final where = refs.cast<CellRef>();
    if (!_within(unit, where.first, _reach)) return refused(HostRule.tooFar);
    final result = _roleActions.startBuild(
      unit: unit.type,
      structure: structure,
      pool: unit.pool,
      now: _now,
    );
    if (result case ActionRefused(:final reason)) return _refusedFor(reason);
    final TimedActionStarted(:at, :pool, :action) =
        result as TimedActionStarted;
    return planAt(at, _now, () {
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
    if (target == null) return refused(HostRule.unknownTarget);
    final repaired = _state.units[targetId];
    if (repaired != null && !_within(unit, repaired.cell!, _reach)) {
      return refused(HostRule.tooFar);
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
    return planAt(at, _now, () {
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
      return refused(HostRule.unknownWork);
    }
    final result = _roleActions.resume(
      action: work.action,
      pool: unit.pool,
      now: _now,
    );
    if (result case ActionRefused(:final reason)) return _refusedFor(reason);
    final TimedActionStarted(:at, :pool, :action) =
        result as TimedActionStarted;
    return planAt(at, _now, () {
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
      worlds.built(work.workId, structure, work.cells);
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
    if (target == null) return refused(HostRule.unknownTarget);
    if (healed != null && !_within(unit, healed.cell!, _reach)) {
      return refused(HostRule.tooFar);
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
    return planAt(at, _now, () {
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
      return refused(ActionRefusal.notInActions);
    }
    final paid = unit.pool.payWhenReady(role.ap, _now);
    if (paid == null) return const PlanRefused(ApRefused());
    return planAt(paid.at, _now, () {
      final observation = Observation(role: role, startedAt: paid.at);
      _put(unit.copyWith(pool: paid.pool, observation: observation));
      return [ObservationStarted(unitId: unit.id, endsAt: observation.endsAt)];
    });
  }

  // Captures and pushes (RELIC-05 to RELIC-08, RELIC-19, RELIC-24).

  OrderPlan _captureOrder(UnitState unit, String relicId) {
    final relic = _state.relics[relicId];
    if (relic == null) return refused(HostRule.unknownRelic);
    final team = _teamOf(unit);
    if (relic.owner == team) return refused(HostRule.alreadyOwned);
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
    return planAt(at, _now, () {
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
    if (relic == null) return refused(HostRule.unknownRelic);
    if (!_within(unit, relic.cell, battle.settings.capture.radiusM)) {
      return refused(ActionRefusal.outsideRadius);
    }
    final cells = path == null
        ? null
        : [for (final cell in path) world.cellOf(cell)];
    if (cells != null && cells.contains(null)) return refused(HostRule.offMap);
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
    return planAt(at, _now, () {
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

  /// The aim of [unit] at [targetId], or why it cannot fire at it: no
  /// weapon, no such target, a flying target its weapon cannot reach, out of
  /// range or not seen (COMBAT-11 to COMBAT-13).
  (_Aim?, Enum?) _aim(UnitState unit, String targetId) {
    final weapon = unit.weapon.weapon;
    if (weapon == null) return (null, WeaponRefusal.noWeapon);
    final (cell, flying, armor, defense) = switch (_targetCell(targetId)) {
      final found? => found,
      null => (null, false, '', 0.0),
    };
    if (cell == null) return (null, HostRule.unknownTarget);
    if (flying && weapon.airborneFactor == 0) {
      return (null, HostRule.cannotHitFlying);
    }
    final line = world.sightLine(
      unit.cell!,
      cell,
      fromFlying: unit.flying,
      toFlying: flying,
    );
    if (line.distanceM > weapon.rangeM) return (null, HostRule.outOfRange);
    if (!_vision.canFireAt(
      unit: unit.type,
      weapon: weapon,
      weather: _state.weather,
      line: line,
      time: _now,
      observation: unit.observation,
    )) {
      return (null, HostRule.targetNotSeen);
    }
    return (
      (weapon: weapon, cell: cell, armor: armor, defense: defense, line: line),
      null,
    );
  }

  /// The distance of a shot of [unit] at [targetId], or null when a `Fire`
  /// order of [unit] at it would be refused for its aim: whether [unit]
  /// sees it within its weapon's range (AI-07).
  double? shotDistance(UnitState unit, String targetId) =>
      _aim(unit, targetId).$1?.line.distanceM;

  OrderPlan _fire(UnitState unit, String targetId, int seq) {
    final (aim, refusal) = _aim(unit, targetId);
    if (aim == null) return refused(refusal!);
    final (:weapon, :cell, :armor, :defense, :line) = aim;
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
      return team == null || team.eliminated
          ? null
          : (team.hq.cell, false, 'hq', 0.0);
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
      WeaponDone(:final at, :final state, :final pool) => planAt(at, _now, () {
        final shooter = unit.copyWith(weapon: state, pool: pool);
        _put(shooter);
        final (hit, impacts) = resolve(shooter);
        final also = [..._pending];
        _pending.clear();
        return [
          Attacked(
            attackerId: unit.id,
            sectionId: unit.sectionId,
            weapon: state.weapon!.id,
            hit: hit,
            impacts: impacts,
          ),
          ...also,
        ];
      }),
    };
  }

  /// What a shot did beside its impacts: weapons dropped, a commander's
  /// section stored.
  final _pending = <BattleEvent>[];

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

  /// [unit] dies now: it drops its weapon as [dropId] (COMBAT-29); a
  /// commander resurrects in storage with his section (UNIT-28, UNIT-29).
  List<BattleEvent> _dies(UnitState unit, String dropId) {
    final dropped = _armory.drop(unit.weapon, _now);
    final events = <BattleEvent>[
      if (dropped != null) _drop(dropped, unit.cell!, dropId),
    ];
    if (unit.type.permadeath) {
      battle.change((state) => state.withoutUnit(unit.id));
    } else {
      events.addAll(sections.commanderDied(unit));
    }
    return events;
  }

  /// The unit [unitId] crushed now by the relic or HQ [by], whatever its
  /// team: it dies (RELIC-25, decision 138). A unit that left the field
  /// since is spared.
  List<BattleEvent> crush(String unitId, {required String by}) {
    final unit = _state.units[unitId];
    if (unit == null || !unit.onField) return const [];
    return [
      Crushed(unitId: unit.id, unitType: unit.type.id, byId: by),
      ..._dies(unit, 'w-$by-${unit.id}-${_now.inSeconds}'),
    ];
  }

  Impact _hurt(UnitState shooter, UnitState target, double amount, int seq) {
    final health = target.health.damaged(amount);
    final friendly = _teamOf(target) == _teamOf(shooter);
    var result = ImpactResult.damaged;
    if (!health.isZero) {
      _put(target.copyWith(health: health));
    } else {
      final outcome = _zeroHp.resolve(
        attacker: shooter.type,
        target: target.type,
        targetIsEnemy: !friendly,
        moraleValue: target.morale,
        ap: target.pool.apAt(_now),
        attackerSectionHasRoom: sections.hasRoom(
          _state.sections[shooter.sectionId]!,
        ),
        random: battle.random,
      );
      switch (outcome) {
        case ZeroHpOutcome.death:
          result = ImpactResult.killed;
          _pending.addAll(_dies(target, 'w-$seq-${target.id}'));
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
    if (weapon == null) return refused(WeaponRefusal.noWeapon);
    final splash = weapon.splashRadiusM;
    if (!weapon.indirectFire && splash == null) {
      return refused(HostRule.notIndirect);
    }
    final aimed = world.cellAt(target);
    if (aimed == null) return refused(HostRule.offMap);
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
    if (distance > weapon.rangeM) return refused(HostRule.outOfRange);
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
    if (!targetable) return refused(HostRule.positionNotSeen);
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
      _pending.addAll(worlds.bombard(weapon, landed));
      return (roll.hits, impacts);
    });
  }

  OrderPlan _fireAimed(UnitState unit, Direction aim, int seq) {
    final weapon = unit.weapon.weapon;
    if (weapon == null) return refused(WeaponRefusal.noWeapon);
    if (weapon.projectileSpeedMps == null) return refused(HostRule.notAimed);
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
          if (!team.eliminated)
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
        ShotHitsObstacle(:final point) => () {
          _pending.addAll(worlds.obstacleHit(weapon, point));
          return (false, const <Impact>[]);
        }(),
        ShotMisses() => (false, const <Impact>[]),
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

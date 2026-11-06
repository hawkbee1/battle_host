import 'package:battle_host/src/core/battle_setup.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/core/battle_world.dart';
import 'package:battle_host/src/core/shared_map.dart';
import 'package:battle_host/src/core/timer_queue.dart';
import 'package:battle_host/src/orders/command_handler.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart';

/// Something a battle must do at a set time.
sealed class BattleTimer {
  const new();
}

/// {@template section_unlocks}
/// The full storage lock of [sectionId] ends (HQ-35): it may deploy again.
/// {@endtemplate}
final class SectionUnlocks extends BattleTimer {
  /// {@macro section_unlocks}
  const new(this.sectionId);

  /// The section.
  final String sectionId;
}

/// {@template run_order}
/// The wait of [command] for AP or its weapon ends: it is checked again on
/// the state of that time, then carried out or refused (COMBAT-06,
/// deferred from M4.11).
/// {@endtemplate}
final class RunOrder extends BattleTimer {
  /// {@macro run_order}
  const new(this.command);

  /// The waiting command.
  final Command command;
}

/// {@template work_ends}
/// The build or repair of [unitId] ends (COMBAT-07).
/// {@endtemplate}
final class WorkEnds extends BattleTimer {
  /// {@macro work_ends}
  const new(this.unitId);

  /// The unit.
  final String unitId;
}

/// {@template recall_ends}
/// The recall of [unitId] ends: it is stored, unless it left the field
/// since (HQ-32).
/// {@endtemplate}
final class RecallEnds extends BattleTimer {
  /// {@macro recall_ends}
  const new(this.unitId);

  /// The unit.
  final String unitId;
}

/// {@template capture_ends}
/// The 30-minute capture of [relicId] ends, unless it was lost since
/// (RELIC-05, RELIC-08).
/// {@endtemplate}
final class CaptureEnds extends BattleTimer {
  /// {@macro capture_ends}
  const new(this.relicId);

  /// The relic.
  final String relicId;
}

/// {@template relic_arrives}
/// The push of [relicId] reaches where it stops (RELIC-24).
/// {@endtemplate}
final class RelicArrives extends BattleTimer {
  /// {@macro relic_arrives}
  const new(this.relicId);

  /// The relic.
  final String relicId;
}

/// {@template hold_ends}
/// A team's relic hold reaches its end: it wins unless it was reset
/// (RELIC-14).
/// {@endtemplate}
final class HoldEnds extends BattleTimer {
  /// {@macro hold_ends}
  const new();
}

/// {@template flight_ends}
/// The landing or take-off of [unitId] ends: it [flying] or not.
/// {@endtemplate}
final class FlightEnds extends BattleTimer {
  /// {@macro flight_ends}
  const new(this.unitId, {required this.flying});

  /// The unit.
  final String unitId;

  /// Whether it flies once done.
  final bool flying;
}

/// {@template server_check}
/// The fire check of [unitId], a unit of a server-managed section, is due
/// (AI-07).
/// {@endtemplate}
final class ServerCheck extends BattleTimer {
  /// {@macro server_check}
  const new(this.unitId);

  /// The unit.
  final String unitId;
}

/// {@template battle_memento}
/// What a snapshot keeps of a battle (Memento, stack decision 7): enough to
/// restore it on its map with the shared definitions. Only `Battle` makes
/// one and reads one back; the host stores it encoded.
/// {@endtemplate}
final class BattleMemento {
  /// {@macro battle_memento}
  const new({
    required this.battleId,
    required this.mapId,
    required this.settings,
    required this.seed,
    required this.randomState,
    required this.minStartingMoney,
    required this.state,
    required this.time,
    required this.nextSeq,
    required this.timers,
    required this.timersFired,
  });

  /// The battle.
  final String battleId;

  /// Its map.
  final String mapId;

  /// Its own settings (decision 172).
  final BattleSettings settings;

  /// The seed of its random.
  final int seed;

  /// The state of its random.
  final List<int> randomState;

  /// The money floor of its war's sections.
  final int minStartingMoney;

  /// Its state.
  final BattleState state;

  /// Its battle time.
  final Duration time;

  /// The sequence number of its next accepted command.
  final int nextSeq;

  /// Its timers, in the order they fire.
  final List<(Duration, BattleTimer)> timers;

  /// The timers it fired.
  final int timersFired;
}

/// {@template battle}
/// One battle in memory (decision 3) on a [map] it shares with the other
/// battles of the process, with its own [settings] (decision 172) and its
/// seeded [random].
///
/// Lazy state with a slow tick (stack decision 1): a unit's AP are read at
/// any time from its last update ([apOf], COMBAT-02), so [advanceTo] does
/// no work for idle units and jumps over time where no timer is due. The
/// 1 Hz work of combat and vision joins it with the orders (M5.11).
/// {@endtemplate}
final class Battle {
  /// {@macro battle}
  ///
  /// Starts the battle of [setup] on [map]: the HQs at the map's starting
  /// points for that many teams (HQ-01), the relics at theirs (RELIC-02),
  /// every unit in storage with full AP and HP and base morale (UNIT-31,
  /// decision 212), playing its evolved type (UNIT-18).
  ///
  /// Throws a [GameDataException] for settings the definitions refuse and
  /// an [ArgumentError] for a team count the map has no starting points
  /// for, an unknown unit type or a repeated ID.
  factory start({
    required BattleSetup setup,
    required SharedMap map,
    required GameData definitions,
  }) {
    final settings = definitions.checkSettings(setup.settings);
    final starts =
        map.host.hqStarts[setup.teams.length] ??
        (throw ArgumentError.value(
          setup.teams.length,
          'teams',
          'the map ${map.id} has no starting points for that many teams',
        ));
    final war = WarRules(battle: settings, morale: definitions.combat.morale);
    final evolution = Evolution(definitions.units.trees);
    final units = <String, UnitState>{};
    final sections = <String, SectionState>{};
    final teams = <String, TeamState>{};
    for (final (index, team) in setup.teams.indexed) {
      _unique(teams, team.id, 'team');
      teams[team.id] = TeamState(
        id: team.id,
        hq: HqState(
          cell: starts[index],
          health: Health.full(settings.hq.hp),
          pool: ApPool.full(
            max: settings.hq.apMax,
            recoveryPerHour: settings.ap.recoveryPerHour,
            at: Duration.zero,
          ),
        ),
      );
      for (final section in team.sections) {
        _unique(sections, section.id, 'section');
        sections[section.id] = SectionState(
          id: section.id,
          accountId: section.accountId,
          team: team.id,
          money: section.money,
          xp: section.xp,
          medals: section.medals,
          guildId: section.guildId,
          guildChief: section.guildChief,
          serverManaged: section.serverManaged,
          storedWeapons: StoredWeapons(List.unmodifiable(section.weapons)),
        );
        for (final weapon in section.weapons) {
          if (!definitions.combat.weaponTypes.containsKey(weapon)) {
            throw ArgumentError.value(weapon, 'weapons', 'no such weapon');
          }
        }
        for (final unit in section.units) {
          _unique(units, unit.id, 'unit');
          final base =
              definitions.units.unitTypes[unit.type] ??
              (throw ArgumentError.value(unit.type, 'type', 'no such unit'));
          final tree = unit.tree ?? SkillTree();
          final type = evolution.evolve(base, tree);
          final start = war.atBattleStart(type);
          final weapon = unit.weapon == null
              ? WeaponState.forNewUnit(type, definitions.combat)
              : WeaponState.ready(
                  definitions.combat.weaponTypes[unit.weapon] ??
                      (throw ArgumentError.value(
                        unit.weapon,
                        'weapon',
                        'no such weapon',
                      )),
                );
          units[unit.id] = UnitState(
            id: unit.id,
            sectionId: section.id,
            type: type,
            tree: tree,
            xp: unit.xp,
            location: start.location,
            pool: start.pool,
            health: start.health,
            morale: start.morale,
            weapon: weapon,
          );
        }
      }
    }
    final battle = Battle._(
      id: setup.battleId,
      map: map,
      definitions: definitions,
      settings: settings,
      random: XorshiftRandom(setup.seed),
      minStartingMoney:
          setup.minStartingMoney ?? definitions.economy.minStartingMoney,
      state: BattleState(
        victory: VictoryRules(settings.victory).start(
          relics: [
            for (var i = 1; i <= map.host.relicStarts.length; i++) 'relic-$i',
          ],
          teams: teams.keys,
        ),
        weather: settings.weather.states.first,
        units: Map.unmodifiable(units),
        sections: Map.unmodifiable(sections),
        teams: Map.unmodifiable(teams),
        relics: Map.unmodifiable({
          for (final (index, cell) in map.host.relicStarts.indexed)
            'relic-${index + 1}': RelicState(
              id: 'relic-${index + 1}',
              cell: cell,
            ),
        }),
      ),
    );
    // AI-07: each unit of a server-managed section has its fire check.
    final check = ServerFireCheck(settings.serverManaged)
        .nextAfter(Duration.zero);
    for (final unit in units.values) {
      if (sections[unit.sectionId]!.serverManaged) {
        battle.schedule(check, ServerCheck(unit.id));
      }
    }
    return battle;
  }

  /// The battle [memento] holds, on [map], the map it names, with the
  /// shared [definitions]: its world rebuilt from its delta layer, its
  /// timers, its random and its sequence numbers where they were (Memento,
  /// stack decisions 2 and 7). It goes on as the battle that was saved
  /// would have.
  ///
  /// Throws an [ArgumentError] for a map that is not the one it names, and
  /// a [GameDataException] for settings the definitions refuse.
  factory restore(
    BattleMemento memento, {
    required SharedMap map,
    required GameData definitions,
  }) {
    if (map.id != memento.mapId) {
      throw ArgumentError.value(map.id, 'map', 'is not ${memento.mapId}');
    }
    final battle =
        Battle._(
            id: memento.battleId,
            map: map,
            definitions: definitions,
            settings: definitions.checkSettings(memento.settings),
            random: XorshiftRandom.resume(
              seed: memento.seed,
              state: memento.randomState,
            ),
            minStartingMoney: memento.minStartingMoney,
            state: memento.state,
          )
          .._time = memento.time
          .._nextSeq = memento.nextSeq
          .._fired = memento.timersFired
          .._world = BattleWorld.load(map, memento.state.delta);
    for (final (at, timer) in memento.timers) {
      battle._timers.schedule(at, timer);
    }
    return battle;
  }

  new _({
    required this.id,
    required this.map,
    required this.definitions,
    required this.settings,
    required this.random,
    required this.minStartingMoney,
    required this._state,
  });

  static void _unique(Map<String, Object> seen, String id, String what) {
    if (seen.containsKey(id)) {
      throw ArgumentError.value(id, what, 'appears twice');
    }
  }

  /// The battle.
  final String id;

  /// Its map, shared with the other battles on it.
  final SharedMap map;

  /// The shared definitions of `plan/data`.
  final GameData definitions;

  /// Its own settings.
  final BattleSettings settings;

  /// Its seeded random (stack decision 1).
  final XorshiftRandom random;

  /// The money floor of its war's sections (SOC-10, ECO-13).
  final int minStartingMoney;

  BattleState _state;
  Duration _time = Duration.zero;
  var _nextSeq = 1;

  BattleWorld? _world;

  /// Its own world: the shared map until it first changes (M5.14).
  BattleWorld get world => _world ??= BattleWorld(map);

  /// The command handler of this battle (Facade for every sender).
  late final CommandHandler orders = CommandHandler(this);

  /// Hears the entries the battle makes on its own, at their time (a
  /// waiting order carried out, a work done, an order of a server-managed
  /// unit's fire check): the host logs them (Observer, stack decision 7).
  void Function(LogEntry entry)? onEntry;

  /// The next sequence number of an accepted command (stack decision 8).
  int takeSeq() => _nextSeq++;
  final _timers = TimerQueue<BattleTimer>();
  var _fired = 0;

  /// The state at [time].
  BattleState get state => _state;

  /// The battle time reached: the time since it started.
  Duration get time => _time;

  /// The timers fired so far.
  int get timersFired => _fired;

  /// The timers waiting, in the order they fire.
  List<(Duration, BattleTimer)> get timers => _timers.pending;

  /// The AP of [unitId] at [time] (COMBAT-01, COMBAT-02).
  double apOf(String unitId) => _state.units[unitId]!.pool.apAt(_time);

  /// The AP of [team]'s HQ at [time] (HQ-14).
  double hqApOf(String team) => _state.teams[team]!.hq.pool.apAt(_time);

  /// Makes the change [change] to the state, at [time].
  void change(BattleState Function(BattleState state) change) =>
      _state = change(_state);

  /// Schedules [timer] at the battle time [at].
  ///
  /// Throws an [ArgumentError] for a time before [time].
  void schedule(Duration at, BattleTimer timer) {
    if (at < _time) throw ArgumentError.value(at, 'at', 'is in the past');
    _timers.schedule(at, timer);
  }

  /// What a snapshot keeps of this battle now (Memento, stack decision 2):
  /// [Battle.restore] gives it back.
  BattleMemento save() => BattleMemento(
    battleId: id,
    mapId: map.id,
    settings: settings,
    seed: random.seed,
    randomState: random.state,
    minStartingMoney: minStartingMoney,
    state: _state,
    time: _time,
    nextSeq: _nextSeq,
    timers: _timers.pending,
    timersFired: _fired,
  );

  /// Brings the battle to the battle time [to], firing the timers due on
  /// the way in their order.
  ///
  /// Throws an [ArgumentError] for a time before [time], and a
  /// [StateError] for a timer whose subject is gone.
  void advanceTo(Duration to) {
    if (to < _time) throw ArgumentError.value(to, 'to', 'is in the past');
    for (var due = _timers.popDue(to); due != null; due = _timers.popDue(to)) {
      final (at, timer) = due;
      _time = at;
      _fire(timer);
      _fired++;
    }
    _time = to;
  }

  void _fire(BattleTimer timer) {
    final before = _state;
    final (command, events) = switch (timer) {
      SectionUnlocks(:final sectionId) => () {
        _state = _state.withSection(
          (_state.sections[sectionId] ??
                  (throw StateError('no section $sectionId to unlock')))
              .lockedTo(null),
        );
        return (null, const <BattleEvent>[]);
      }(),
      // A waiting order hears its own consequences in the handler.
      RunOrder(:final command) => (null, orders.handle(command).events),
      WorkEnds(:final unitId) => (
        null,
        orders.react(before, orders.finishWork(unitId)),
      ),
      RecallEnds(:final unitId) => (
        null,
        orders.react(before, orders.sections.finishRecall(unitId)),
      ),
      CaptureEnds(:final relicId) => (
        null,
        orders.react(before, orders.relics.finishCapture(relicId)),
      ),
      RelicArrives(:final relicId) => (
        null,
        orders.react(before, orders.relics.finishPush(relicId)),
      ),
      HoldEnds() => (null, orders.react(before, orders.relics.holdDue())),
      FlightEnds(:final unitId, :final flying) => (
        null,
        orders.finishFlight(unitId, flying: flying),
      ),
      ServerCheck(:final unitId) => orders.servers.check(unitId),
    };
    if (command != null || events.isNotEmpty) {
      onEntry?.call(LogEntry(at: _time, command: command, events: events));
    }
  }
}

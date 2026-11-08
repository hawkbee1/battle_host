import 'dart:math' as math;

import 'package:battle_host/src/core/battle.dart';
import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/orders/world.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart';
import 'package:battle_rules/battle_rules.dart';

/// {@template section_sight}
/// What one section knows of the battle at a time (MAP-29, MAP-49,
/// decisions 21 and 232): derived from the battle's state, never logged
/// nor kept in a snapshot.
/// {@endtemplate}
final class SectionSight {
  /// {@macro section_sight}
  const new({required this.units, required this.hqs, required this.relics});

  /// The units it knows: its own, wherever they are, and the units on the
  /// field of other sections, allies included, that one of its units sees,
  /// or, for enemies, that a scout of its team reports through a radio in
  /// range (UNIT-34, UNIT-36). Stored units are seen by nobody but their
  /// own section (HQ-29).
  final Set<String> units;

  /// The teams whose HQ it knows: its own, and the enemy HQs one of its
  /// units sees or a scout of its team reports.
  final Set<String> hqs;

  /// The relics, position and owner: every section knows them (MAP-49), as
  /// it knows every team's victory countdown and the whole delta layer.
  final Set<String> relics;
}

/// What a unit's sight depends on: where it stands on the field, if it
/// does, and its sight values. A unit whose key changed is checked again.
typedef _Key = ({
  CellRef? cell,
  bool target,
  bool flying,
  String section,
  double visionRange,
  double bonus,
  double heightM,
});

/// One unit as the fog last saw it: its key, how far it may see at most,
/// and the units and HQs it sees, and the units that see it.
final class _Watch {
  new(this.key);

  _Key key;
  double reach = 0;
  final sees = <String>{};
  final seesHq = <String>{};
  final seenBy = <String>{};
}

/// {@template fog_of_war}
/// The fog of war of one battle: each section's visible set (MAP-29), kept
/// up to date once per tick by [sync], and the scouts' reports through
/// radios, which artillery also aims by (COMBAT-12): one computation,
/// [reportingScouts].
///
/// Units on the field see; carried units see from their transport but are
/// not seen on their own (COMBAT-54; assumed in Q-MAP-25). A unit sees
/// another with the vision rules of M4.5 and its effective stats: range,
/// weather, forest, height, observe (MAP-26 to MAP-35, UNIT-34).
///
/// The cost stays low: the units on the field are kept in a grid of cells,
/// so a unit is only checked against those within its greatest reach, and
/// a sync checks again only the units that moved, appeared, left the field
/// or changed their sight, those near a change of the world, and every
/// unit when the weather changes. The sets are derived state: a fog built
/// on a recovered battle gives the same sets.
/// {@endtemplate}
final class FogOfWar {
  /// {@macro fog_of_war}
  new({required this.battle, required this.world, required this.vision})
    : _bucket = math.max(
        1,
        (_greatestReach(battle.definitions) / world.cellSizeM).ceil(),
      );

  /// The battle.
  final Battle battle;

  /// Its geometry.
  final World world;

  /// The vision rules.
  final Vision vision;

  /// The side of a grid square, in cells: the greatest reach of the base
  /// unit types, so a unit's neighbours are in the squares around its own.
  final int _bucket;

  final _watches = <String, _Watch>{};
  final _grid = <(int, int), Set<String>>{};
  final _members = <String, Set<String>>{};
  final _hqs = <String, CellRef?>{};
  final _hqSeenBy = <String, Set<String>>{};
  var _reporters = <String, Set<String>>{};
  final _sights = <String, SectionSight>{};

  BattleState? _state;
  Duration? _changesAt;
  var _reachMax = 0.0;
  var _lines = 0;

  /// The sight lines checked since the fog was made: what [sync] costs.
  int get linesChecked => _lines;

  static double _greatestReach(GameData definitions) {
    var greatest = 0.0;
    for (final type in definitions.units.unitTypes.values) {
      greatest = math.max(
        greatest,
        type.stats.visionRange + (type.role.observe?.visionBonusM ?? 0),
      );
    }
    return greatest + definitions.terrain.vision.heightBonusMaxM;
  }

  /// What [sectionId] knows now (MAP-29, MAP-49).
  ///
  /// Throws an [ArgumentError] for a section not in the battle.
  SectionSight of(String sectionId) {
    if (!battle.state.sections.containsKey(sectionId)) {
      throw ArgumentError.value(sectionId, 'sectionId', 'not in the battle');
    }
    sync();
    return _sights[sectionId] ??= _build(sectionId);
  }

  /// The scouts of [team] on the field that report what they see: those
  /// within the relay range of a radio of the team on the field, whatever
  /// its section (UNIT-34, UNIT-36). Their reports reach every section of
  /// the team, and artillery may fire at a position they see (COMBAT-12).
  Set<String> reportingScouts(String team) {
    final state = battle.state;
    bool ofTeam(UnitState unit) =>
        unit.onField && state.sections[unit.sectionId]!.team == team;
    final radios = [
      for (final unit in state.units.values)
        if (unit.type.role.relayRange != null && ofTeam(unit)) unit,
    ];
    return {
      for (final scout in state.units.values)
        if (scout.type.role.reportsToRadio &&
            scout.location is Deployed &&
            ofTeam(scout) &&
            radios.any(
              (radio) =>
                  radio.cell!.surface == scout.cell!.surface &&
                  world.distanceM(radio.cell!, scout.cell!) <=
                      radio.type.role.relayRange!,
            ))
          scout.id,
    };
  }

  /// Whether [observer] sees the ground at [cell] (COMBAT-12): where
  /// artillery may aim.
  bool seesGround(UnitState observer, CellRef cell) => vision.unitSees(
    unit: observer.type,
    weather: battle.state.weather,
    line: world.sightLine(
      observer.cell!,
      cell,
      fromFlying: observer.flying,
      fromHeightM: observer.type.hitBox.height,
    ),
    time: battle.time,
    observation: observer.observation,
  );

  /// Brings the visible sets to the battle's state and time: once per tick
  /// (stack decision 1), and before they are read.
  void sync() {
    final state = battle.state;
    final time = battle.time;
    // Only an observation that starts or ends changes sight with time.
    if (identical(state, _state) &&
        (_changesAt == null || time < _changesAt!)) {
      return;
    }
    final touched = battle.world.takeTouched();
    final all = _state == null || state.weather != _state!.weather;
    _state = state;
    _changesAt = null;
    final stale = <String>{};

    final reporters = {
      for (final team in state.teams.keys) team: reportingScouts(team),
    };
    for (final team in state.teams.keys) {
      if (!_sameSet(reporters[team]!, _reporters[team])) {
        stale.addAll(_sectionsOf(team));
      }
    }
    _reporters = reporters;

    final dirty = <String>{};
    for (final id in _watches.keys.toList()) {
      if (!state.units.containsKey(id)) _remove(id, stale);
    }
    for (final unit in state.units.values) {
      final key = _keyOf(unit, time);
      if (unit.observation case final observation?) {
        for (final at in [observation.startedAt, observation.endsAt]) {
          if (at > time && (_changesAt == null || at < _changesAt!)) {
            _changesAt = at;
          }
        }
      }
      final watch = _watches[unit.id];
      if (watch == null) {
        _watches[unit.id] = _Watch(key);
        _place(unit.id, key);
        stale.add(key.section);
        dirty.add(unit.id);
      } else if (all || watch.key != key) {
        _drop(unit.id, stale);
        _unplace(unit.id, watch.key);
        stale.add(watch.key.section);
        watch.key = key;
        _place(unit.id, key);
        stale.add(key.section);
        dirty.add(unit.id);
      }
    }
    _reachMax = 0;
    for (final watch in _watches.values) {
      watch.reach = _reachOf(watch.key);
      _reachMax = math.max(_reachMax, watch.reach);
    }
    if (!all && touched.isNotEmpty) {
      for (final id in _near(touched, _reachMax)) {
        if (dirty.add(id)) _drop(id, stale);
      }
    }

    final movedHqs = <String>{};
    for (final MapEntry(key: team, value: hq) in state.teams.entries) {
      final cell = hq.eliminated ? null : hq.hq.cell;
      if (all || !_hqs.containsKey(team) || _hqs[team] != cell) {
        for (final observer in _hqSeenBy.remove(team) ?? const <String>{}) {
          _watches[observer]!.seesHq.remove(team);
          _seen(observer, stale);
        }
        _hqs[team] = cell;
        movedHqs.add(team);
      }
    }

    for (final id in dirty) {
      final watch = _watches[id]!;
      final cell = watch.key.cell;
      if (cell == null) continue;
      for (final other in _around(cell, watch.reach)) {
        if (other != id) _check(id, other, stale);
      }
      for (final team in _hqs.keys) {
        _checkHq(id, team, stale);
      }
      if (!watch.key.target) continue;
      for (final observer in _around(cell, _reachMax)) {
        if (!dirty.contains(observer)) _check(observer, id, stale);
      }
    }
    for (final team in movedHqs) {
      final cell = _hqs[team];
      if (cell == null) continue;
      for (final observer in _around(cell, _reachMax)) {
        if (!dirty.contains(observer)) _checkHq(observer, team, stale);
      }
    }
    stale.forEach(_sights.remove);
  }

  _Key _keyOf(UnitState unit, Duration time) => (
    cell: unit.onField ? unit.cell : null,
    target: unit.location is Deployed,
    flying: unit.flying,
    section: unit.sectionId,
    visionRange: unit.type.stats.visionRange,
    bonus: unit.observation?.bonusAt(time) ?? 0,
    heightM: unit.type.hitBox.height,
  );

  /// The farthest [key] may see: its effective vision on the line most in
  /// its favour, with no forest and the whole height bonus (MAP-31 to
  /// MAP-33).
  double _reachOf(_Key key) {
    final cell = key.cell;
    if (cell == null) return 0;
    final terrain = vision.terrain;
    return (key.visionRange + key.bonus) *
            terrain.weather[_state!.weather]! *
            terrain.terrainTypes[world.terrainOf(cell)]!.visionFactor +
        terrain.vision.heightBonusMaxM;
  }

  void _check(String observerId, String targetId, Set<String> stale) {
    final observer = _watches[observerId]!;
    final target = _watches[targetId]!;
    final from = observer.key.cell;
    final to = target.key.cell;
    if (from == null ||
        to == null ||
        !target.key.target ||
        observer.key.section == target.key.section ||
        world.distanceM(from, to) > observer.reach) {
      return;
    }
    if (_sees(
      observer.key,
      to,
      flying: target.key.flying,
      heightM: target.key.heightM,
    )) {
      observer.sees.add(targetId);
      target.seenBy.add(observerId);
      _seen(observerId, stale);
    }
  }

  void _checkHq(String observerId, String team, Set<String> stale) {
    final observer = _watches[observerId]!;
    final from = observer.key.cell;
    final to = _hqs[team];
    if (from == null ||
        to == null ||
        _teamOfSection(observer.key.section) == team ||
        world.distanceM(from, to) > observer.reach) {
      return;
    }
    if (_sees(
      observer.key,
      to,
      flying: false,
      heightM: battle.settings.hq.hitBox.height,
    )) {
      observer.seesHq.add(team);
      (_hqSeenBy[team] ??= {}).add(observerId);
      _seen(observerId, stale);
    }
  }

  bool _sees(
    _Key observer,
    CellRef to, {
    required bool flying,
    required double heightM,
  }) {
    _lines++;
    return vision.sees(
      visionRange: observer.visionRange,
      observeBonusM: observer.bonus,
      weather: _state!.weather,
      line: world.sightLine(
        observer.cell!,
        to,
        fromFlying: observer.flying,
        toFlying: flying,
        fromHeightM: observer.heightM,
        toHeightM: heightM,
      ),
    );
  }

  /// What [observerId] sees changed: its section's set, and every section
  /// of its team when it reports.
  void _seen(String observerId, Set<String> stale) {
    final section = _watches[observerId]!.key.section;
    stale.add(section);
    final team = _teamOfSection(section);
    if (_reporters[team]?.contains(observerId) ?? false) {
      stale.addAll(_sectionsOf(team));
    }
  }

  /// Forgets what [id] sees and who sees it.
  void _drop(String id, Set<String> stale) {
    final watch = _watches[id]!;
    if (watch.sees.isNotEmpty || watch.seesHq.isNotEmpty) _seen(id, stale);
    for (final target in watch.sees) {
      _watches[target]!.seenBy.remove(id);
    }
    for (final team in watch.seesHq) {
      _hqSeenBy[team]!.remove(id);
    }
    for (final observer in watch.seenBy) {
      _watches[observer]!.sees.remove(id);
      _seen(observer, stale);
    }
    watch.sees.clear();
    watch.seesHq.clear();
    watch.seenBy.clear();
  }

  void _remove(String id, Set<String> stale) {
    final watch = _watches[id]!;
    _drop(id, stale);
    _unplace(id, watch.key);
    stale.add(watch.key.section);
    _watches.remove(id);
  }

  (int, int) _square(CellRef cell) => (cell.x ~/ _bucket, cell.y ~/ _bucket);

  void _place(String id, _Key key) {
    (_members[key.section] ??= {}).add(id);
    final cell = key.cell;
    if (cell != null) (_grid[_square(cell)] ??= {}).add(id);
  }

  void _unplace(String id, _Key key) {
    _members[key.section]!.remove(id);
    final cell = key.cell;
    if (cell != null) _grid[_square(cell)]!.remove(id);
  }

  /// The units on the field in the grid squares within [metres] of [cell].
  Iterable<String> _around(CellRef cell, double metres) =>
      _inBox(cell.x, cell.y, cell.x, cell.y, metres);

  /// The units on the field within [metres] of the box around [cells].
  Iterable<String> _near(Set<CellRef> cells, double metres) {
    final xs = [for (final cell in cells) cell.x];
    final ys = [for (final cell in cells) cell.y];
    return _inBox(
      xs.reduce(math.min),
      ys.reduce(math.min),
      xs.reduce(math.max),
      ys.reduce(math.max),
      metres,
    );
  }

  Iterable<String> _inBox(
    int minX,
    int minY,
    int maxX,
    int maxY,
    double metres,
  ) sync* {
    final cells = (metres / world.cellSizeM).ceil();
    final (fromX, fromY) = _square(
      CellRef(math.max(0, minX - cells), math.max(0, minY - cells)),
    );
    final (toX, toY) = _square(CellRef(maxX + cells, maxY + cells));
    for (var y = fromY; y <= toY; y++) {
      for (var x = fromX; x <= toX; x++) {
        final square = _grid[(x, y)];
        if (square != null) yield* square.toList();
      }
    }
  }

  String _teamOfSection(String section) => _state!.sections[section]!.team;

  Iterable<String> _sectionsOf(String team) => [
    for (final section in _state!.sections.values)
      if (section.team == team) section.id,
  ];

  static bool _sameSet(Set<String> a, Set<String>? b) =>
      b != null && a.length == b.length && a.containsAll(b);

  SectionSight _build(String sectionId) {
    final team = _teamOfSection(sectionId);
    final units = <String>{...?_members[sectionId]};
    final hqs = <String>{team};
    for (final id in _members[sectionId] ?? const <String>{}) {
      final watch = _watches[id]!;
      units.addAll(watch.sees);
      hqs.addAll(watch.seesHq);
    }
    for (final id in _reporters[team]!) {
      final watch = _watches[id]!;
      for (final target in watch.sees) {
        if (_teamOfSection(_watches[target]!.key.section) != team) {
          units.add(target);
        }
      }
      hqs.addAll(watch.seesHq);
    }
    return SectionSight(
      units: Set.unmodifiable(units),
      hqs: Set.unmodifiable(hqs),
      relics: Set.unmodifiable(_state!.relics.keys),
    );
  }
}
